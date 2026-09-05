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
- **Create group** — sets the user as owner; group gets a UUID and title
- **Join group** — adds the user to `groups.members`
- **Leave group** — removes the user from the group
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

## Real-Time Behavior

The WebSocket connection (`/ws/{user_id}`) handles:

| Event type | Direction | Action |
|---|---|---|
| `group_message` | send/receive | Broadcast to all group members |
| `dm` | send/receive | Route to a single recipient |
| `activity` | receive | Member is reading / highlighting / noting (broadcast by server) |

The connection is established when the Reader mounts and torn down on unmount.
