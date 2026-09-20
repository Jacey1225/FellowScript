# Community

The Messaging sidebar (`MessagingSidebar`) handles all social features: group chat, direct messages, and friend management. It appears in the right panel of the Reader when the Messages icon is selected.

---

## Group Chat

When a user belongs to a study group, the messaging sidebar shows:
- **Group message history** — past messages loaded on mount
- **Real-time messages** — delivered via WebSocket (`/ws/{user_id}`)
- **Message input** — text field + send button at the bottom

Group messages are visible to all group members.

---

## Direct Messages

The sidebar also surfaces 1-on-1 DM threads. Selecting a friend from the list opens a private thread visible only to the two participants. DMs are routed through the same WebSocket connection with a `type: "dm"` payload.

---

## Friends

The friends panel shows:
- **Friend list** — all accepted friends with DM button
- **Incoming requests** — friend requests awaiting response (Accept / Decline)
- **Add friend** — send a request by username

All friend actions go through `GET/POST /friends/{user_id}/…` REST endpoints; no WebSocket is needed for friend management.

---

## Groups

Users can create or join study groups:
- **Create group** — sets the user as owner (`groups.creator_id`, stamped from the authenticated caller, never client-supplied); group gets a UUID and title
- **Join group** — adds the user to `groups.members`
- **Leave group** — removes only the leaving user from the group's member list; the group, its title, and everyone else's access, notes, messages, devotions, and sessions are unaffected. If the last remaining member leaves, the now-empty group is auto-deleted. A distinct, owner-only **Delete group** action (below) is what actually removes a group outright — leaving never does that for anyone but yourself.
- **Delete group** — permanently deletes the group for every member, including its notes, messages, devotions, and sessions. Only the group's recorded creator may do this; for a group with no recorded creator (predates the `creator_id` column, or the creator's account was deleted), any current member may. Denied (403) to anyone else.
- **Group selector** — the compact dropdown in the Notes sidebar tab bar also switches the messaging sidebar to the selected group

Group highlights (members' colored verse highlights) are visible as overlays in the scripture view when a group is selected.

---

## Visual Design (iOS)

**Add-friend / add-group sheets restyled (2026-09-02).** iOS's `AddFriendSheet` and `AddGroupSheet`
(`Chat/ChatRootView.swift`) previously sat on a flat `Theme.bgPage` fill with native `Form`/`Section`
chrome, unlike the rest of the app. Both now use the shared `Theme.warmBloomBackground()` modifier
(the same two-`RadialGradient` wash used app-wide) and a custom `ScrollView` + `widgetCard()` layout
in place of `Form`. `AddFriendSheet` gained a `.medium` presentation detent (previously full-height
with a large empty area below its one field); `AddGroupSheet` gained `[.medium, .large]` so a longer
member list isn't clipped. Appearance-only — `onSend`/`onCreate` wiring, member-row selection
behavior, and existing accessibility labels are unchanged.

**Leave vs. Delete Group made visibly distinct (2026-09-16).** The groups list's swipe actions
(`ChatRootView.groupsList`) previously offered a single trailing "Leave" button that, before the
matching backend fix, actually deleted the whole group for every member. "Leave" now stays a
trailing swipe button with no extra confirmation (it only ever affects the caller). A separate
leading swipe button, "Delete Group," appears only for a caller authorized to delete the group
outright (mirrors the backend's owner check client-side, purely to decide what to show — the
backend re-enforces it independently) and opens a destructive confirmation dialog, the same pattern
already used for blocking a user, before calling the owner-gated delete endpoint.

---

## Attachments (2026-09-04)

The composer (both iOS `ChatThreadView` and web `ChatThread`) has a plus-icon attach affordance
next to the text field. Tapping it opens a single horizontal row of three gold pill buttons
(icon + label, the same treatment used elsewhere in the app) directly above the text field —
not a bottom sheet/modal — with three options:

- **Photo & Video** — the platform's native picker (iOS `PHPickerViewController`; web `<input
  type="file" accept="image/*,video/*">`). The picked file uploads directly to S3 using a
  presigned URL the server issues (`POST /message/upload-url/{user_id}`) — the app's own backend
  never receives the raw bytes. A staged preview chip shows upload progress (plain spinner) above
  the composer; send stays disabled until the upload finishes (or immediately for a GIF, which
  never uploads).
- **File** — same direct-to-S3 flow, native document/file picker.
- **GIF** — a dedicated search sheet (debounced query against `GET /message/gif-search`, a
  server-side proxy to the configured provider) with a scrollable results grid. Selecting a GIF
  stages it immediately — nothing to upload, only the provider's URL/ID is sent with the message.
  Opening the sheet immediately shows a default/trending browse grid (before any query is typed)
  instead of a blank "search for a GIF" prompt; a "Load more" button below the grid pages through
  further browse results one tap at a time (no infinite/auto-triggered scroll). Typing a query
  swaps the grid to (unpaginated) search results; clearing the query instantly reverts to the
  browse grid from already-held client state, with no refetch.

In the thread, each attachment kind renders inside the existing message bubble: images and GIFs
preview inline edge-to-edge, videos show a tap-to-play affordance over a placeholder (never
autoplay), and files show a name + download row. A picked-but-unsent attachment can be removed
with no confirmation prompt (undo-after-the-fact); a failed upload shows a short retry affordance
instead of an automatic retry loop. GIF autoplay/looping is suppressed under
`prefers-reduced-motion`/`accessibilityReduceMotion` in favor of a static frame with its own
tap-to-play control — the one place this feature changes default behavior for reduced motion,
rather than just disabling a decorative transition.

Exactly one attachment is supported per message (no multi-file selection); a caption (`text`) can
still ride alongside it. See `docs/api/overview.md`'s Attachments section for the wire contract.

### Tap-to-expand lightbox (2026-09-05, web + iOS)

Tapping a sent image or GIF attachment in the thread opens it in a full-screen lightbox: a
blurred/dimmed backdrop with the media enlarged and centered, dismissible by tapping the backdrop,
tapping the media itself, or an always-visible close button (no confirmation needed — this isn't a
destructive action). The media scales and fades into view (faster on the way out than in), and the
transition is skipped outright under `prefers-reduced-motion` / iOS's Reduce Motion setting rather
than merely shortened. A GIF opened this way restarts its animation from the first frame rather
than syncing to whatever phase it was already playing inline. There's no pinch/pan zoom in this
pass — the lightbox is a bigger fit-to-screen view, not an interactive zoom/pan viewer — and the
caption/sender label stay in the underlying bubble rather than duplicating into the overlay. Video
attachments are unaffected; they keep their existing tap-to-play behavior.

On iOS the lightbox presents via `fullScreenCover` (covering the tab bar and all chrome) over a
material + warm-tint backdrop matching the app's existing "glass" surfaces elsewhere. It applies at
every current call site (`AttachmentContentView`'s image and GIF branches, used from the one
message-bubble list in `MessageGroupRow`).

---

## Study Sessions & Calls (2026-09-04)

A chat thread can host a live voice/video study session (Amazon Chime SDK) via the session
island shown above the message list (`SessionWidget`). Joining creates/fetches the Chime meeting
and requests an attendee token before connecting. A failure at either of those two steps — e.g.
the server can't reach Chime — used to fail with no visible signal at all. It now surfaces an
inline error message with a **Retry** button directly on the affected session's card; retrying
just re-runs the join flow, and the error clears automatically as soon as a join attempt (retry
or fresh) starts.

---

## Video Call UI Redesign (2026-09-15, task `20260915-video-call-ui-redesign`, iOS)

The active-call screen (`Chat/ChimeCallView.swift`) no longer shows remote participants in a
scrollable grid. Its background is now a translucent, warm-toned blur (`.ultraThinMaterial` over
the app's existing dark/gold gradient wash, built from `Theme.bgPage`/`Theme.gold`) — a deliberate,
documented extension of the app's native-blur surfaces (`DashboardComponents.glassCard`, the Bible
nav dropdown's glass panel), not a break from Chat's own flat-elevation styling, which was always
scoped to Chat surfaces specifically. Each active remote camera renders as a medium circular tile at
a randomized position, sized down as more participants join (152pt for ≤2 down to 84pt for 7+, with
a hard 64pt floor), placed so no two tiles ever overlap and all stay within roughly the central 70%
of the screen, clear of the header and control bar. Tiles animate in/out with an eased fade+scale
(faster on exit) and reposition smoothly when a participant joins/leaves or the device rotates; all
of that motion is skipped in favor of a plain cross-fade under Reduce Motion. The local user's own
self-camera stays exactly where it always was — a small fixed thumbnail, not part of the randomized
field — only re-skinned with the same glass treatment instead of a flat black fill. The mute/camera/
hang-up control bar and call header are unchanged.

New file: `Chat/ChimeCallView+RemoteField.swift` (`RemoteCameraField` — tile placement/animation
logic, split out of `ChimeCallView.swift` per this codebase's existing `+`-suffixed extension-file
convention).

---

## Session Call Background Persistence (2026-09-16, task `20260916-call-background-persistence`, iOS)

A user who backgrounds the app (home screen, another app) during an active session call is no
longer removed from the call. The Chime audio session and microphone keep running while
backgrounded, so the user keeps hearing other participants and can keep speaking without reopening
the app. Local and remote video pause while backgrounded — iOS doesn't allow camera capture in the
background — and local video resumes automatically on return to the foreground if the call is still
connected. If the call genuinely drops while backgrounded (network loss, the meeting ending), the
call screen shows "not connected" rather than a stale "Connected" state when the app is reopened.
This is audio-only background support for a call already joined — no CallKit lock-screen/
incoming-call UI applies here; ending the call still requires reopening the app. (A genuine
CallKit incoming-call UI was added separately, for the *ring* path only — see "Native Incoming-Call
Ring (CallKit/PushKit)" below.)

---

## Ring Group Members (2026-09-16, task `20260916-call-ring-members`, iOS)

A new "Ring" button sits leftmost in the active-call control bar (before Mute/Camera/End). Tapping
it opens a member-picker sheet listing the session's own group roster (minus the caller), split into
"Not Yet Joined" (selectable, shown first) and a visually de-emphasized "Already in Call" section
(still selectable, but never pre-checked — ringing someone already in the call isn't the normal
path). Selecting one or more members and tapping "Ring" sends each of them a push notification
prompting them to join the live call now; each selected row shows its own independent
sending/sent/rate-limited/error outcome rather than one all-or-nothing result, since a multi-select
ring can partially succeed. A rate-limited or failed row can be retried by tapping it again; a
successfully-rung member stays marked "Sent" for the rest of the call, even if the sheet is closed
and reopened, so the same person can't be accidentally re-rung inside their cooldown window. The Ring
button itself is disabled only when there's clearly no one else to ring (e.g. a stale one-person DM);
a real empty roster is instead handled by the sheet's own "No other members to ring." message.

On the recipient's side, tapping a ring push jumps straight into joining the live call, rather than
just opening the session's chat thread the way the older session-reminder push does.

---

## Native Incoming-Call Ring (CallKit/PushKit) (2026-09-17, task `20260916-callkit-voip-ring`, iOS)

Ring delivery now goes through PushKit's VoIP push + CallKit rather than a plain push notification,
gated behind the backend's `RING_VOIP_ENABLED` flag (off by default — the ring feature keeps working
exactly as described above, via the plain push, until that flag is turned on). When enabled, a ring
wakes the recipient's device — even if the app was fully killed — and presents the system's own
full-screen "incoming call" UI, the same kind of screen as a real phone call, rather than a
notification banner. The ring rings for a bounded, server-configured timeout and resolves cleanly on
answer (joins the live call, exactly the same join path a tapped plain-ring-push already used),
decline, or timeout.

Registering for VoIP push happens automatically at app launch, with no separate permission prompt —
unlike ordinary push notifications, PushKit doesn't require the user to grant anything. A recipient
who hasn't registered a VoIP token (e.g. an unsupported device state) fails that ring delivery
visibly in the sender's Ring Members sheet ("Can't ring this device") rather than silently.

This is additive to, not a replacement of, the existing `audio` background mode that keeps an
already-joined call's audio running (see "Session Call Background Persistence" above) — the two cover
different moments (an incoming ring's announcement vs. an already-connected call's audio) and don't
conflict.

A sent message (friend DM or group) that the backend explicitly rejects or fails to save (a
content-filter rejection, a failed database write, or the silent block-drop between two users who
have blocked each other) used to look identical to a successful one: it showed up immediately via
the optimistic local echo, then simply vanished the next time the thread was reopened, once the
server's history reload replaced the message list wholesale and the never-actually-saved message
wasn't in it. The client had no way to distinguish this from a real send — the backend's own
`{"type": "error", ...}` frame carrying the rejection reason was silently dropped, because the
receive loop only ever acted on a frame that had a `text` key.

The receive loop (`ChatThreadView.swift`) now explicitly branches on the frame's `type` field
instead of relying on `text`'s presence as an implicit signal. An error frame is matched to the
oldest still-unconfirmed optimistic send (there is no ack, so a send that's never flagged as
failed is treated as having succeeded) and flags that message. The affected bubble gets an inline
**"Couldn't send — tap to retry"** line beneath it, reusing the exact styling and interaction the
composer's failed-attachment-upload chip already established, rather than a toast, alert, or
raw error dump. Tapping it removes the failed bubble and resends the same text/attachment, with no
confirmation step. A successful send is unaffected either way — it survives thread re-entry (warm
or cold reload) exactly as before.

---

## Unread Conversation Badges (2026-09-13, task `20260913-chat-unread-badges`, iOS)

Friend and group chats now show a red unread indicator, client-local and derived — no per-message
count is fabricated for a row that only ever knows a `lastMessageAt` timestamp. Two locations, both
top-left per the original request:

- **Chat tab icon** (`FloatingTabBar.swift`) — a numeral badge showing the count of unread
  *conversations* (capped `9+`), shown whenever any friend or group has unread messages, in both
  the tab's selected and unselected icon states.
- **Chat list rows** (`ChatRootView.swift`'s `ContactRow`, shared by both friends and groups) — a
  plain dot, no number, since `FSContact` carries no per-conversation message count to show
  honestly.

A conversation counts as unread when its `FSContact.lastMessageAt` is newer than a per-conversation
last-read marker (`AppState.hasUnread(_:)`), stored client-local in `UserDefaults` keyed by
`FSContact.id` — one mechanism for both friends and groups, no special-casing. The marker is set
(`AppState.markRead(_:)`) only when `ChatThreadView` actually opens that specific thread, never
merely from the chat list being visible or the tab being selected; it clears immediately and the
tab-bar count recomputes accordingly. Agent chats (`AgentChatView`) never carry either badge — that
type never flows through this mechanism at all. This is a device-local read state: it does not
survive a reinstall or sync across a user's other devices. Badge appear/disappear uses an eased
spring transition (a quicker exit than entrance), skipped entirely under Reduce Motion; the tab
badge additionally pulses briefly when its count changes in place (e.g. 2 → 3) rather than
flashing a plain text swap.

---

## Session Editing (2026-09-14, task `20260914-session-edit-button`, iOS)

`SessionDetailSheet` now shows an **Edit Session** button next to the existing Delete Session
button, gated by the same author-only `isHost` check (`session.creator_id ==
appState.currentUser?.user_id`) — visible only to the session's creator, not merely disabled for
anyone else. Tapping it opens `SessionCreatorSheet` in a new edit mode (the same component the
"+ new session" flow uses, rather than a forked near-duplicate view), pre-filled with the
session's current title, start date/time, duration (inferred from the existing `time_start`/
`time_end` gap, snapped to the nearest 15/30/45/60m option), verses, discussion prompts, and
recurring toggle. Verses are only editable here — the create flow still has no verses UI at all,
unchanged.

Saving calls the already-implemented `NetworkService.updateSession(userId:sessionId:devotion:)`
(a full-session `PUT /devotions/`, previously wired to no UI path) with the original session's
`id`/`creator_id`/`group_id`/`participants` preserved and only the edited fields changed. Unlike
the create flow's fire-and-forget save, edit mode awaits the request: a failure keeps the sheet
open and shows a "Couldn't Save Changes" alert instead of silently discarding the edit or closing
as if it had succeeded; success dismisses the sheet and refreshes the caller's session list via a
new `onUpdate` callback, mirroring the existing `onDelete` refresh path.

---

## Session Join-Window Gating (2026-09-20, task `20260920-session-join-window-gating`, iOS + backend)

The two Join affordances — `SessionBanner`'s compact **Join** button and `SessionDetailSheet`'s
**Join Audio & Video Call** CTA — are now greyed out and untappable outside a session's opening
window, and enable automatically once it begins (no reload needed): each wraps its button in a
`TimelineView(.periodic(from: .now, by: 1))` so `FSSession.isJoinWindowOpen(now:)` re-evaluates on
a 1-second cadence while the view is on screen.

`isJoinWindowOpen` treats the open window as `[time_start - 10 minutes, time_end]`, evaluated
against **device local time**:

- A missing or unparseable `time_start` fails closed — the button stays disabled rather than ever
  defaulting to "open."
- A missing or unparseable `time_end` is treated as open-ended once a valid `time_start` has
  passed — no duration is guessed.
- The 10-minute early-join grace period is a hardcoded UI convenience value, not read from the
  server.

This client-side check is a UX convenience only, not the real access-control boundary. The actual
enforcement is server-side: `join_devotion` and `join_call` (`api/routes/devotion.py`) now call
`DevotionManager.is_join_window_open(session)`, evaluated against **server/DB time**
(`NOW()` in Postgres, mirroring `scheduler.py`'s existing precedent) and gated by the same
`SESSION_JOIN_GRACE_MINUTES` env var (validated eagerly at startup, default deploy value `10`).
A user with a manually skewed device clock, or one calling the endpoints directly, still gets
rejected with `403 "This session isn't open yet."` — surfaced through the existing
`CallController.joinError` path exactly like any other join failure. If a call is already live
(`chime_meeting_id` set), the server lets any authorized member join regardless of the time
window — the same mechanism that lets a rung member answer an in-progress call past `time_end`;
the two client buttons have no visibility into `chime_meeting_id` and so stay time-gated only,
meaning they can under-claim availability in that one case but never over-claim it.

The ring-invite path (`AppState.joinRingedCall` → `CallController.shared.start`) is untouched —
it has no button of its own to gate, and is covered by the same already-live-call bypass above.

---

## Real-Time Behavior

The WebSocket connection (`/ws/{user_id}`) handles:

| Event type | Direction | Action |
|---|---|---|
| `group_message` | send/receive | Broadcast to all group members |
| `dm` | send/receive | Route to a single recipient |
| `activity` | receive | Member is reading / highlighting / noting (broadcast by server) |

The connection is established when the Reader mounts and torn down on unmount.
