# Account

The Account page (`/account`) lets users manage their profile, view their subscription, and delete their account. It is available on both the web and iOS clients.

---

## Sections

### Profile
- Displays `username` and `email`
- Edit form for updating either field, resetting password, or setting **Timezone** — a searchable list of IANA names (e.g. `America/Los_Angeles`) on both platforms: an antd `Select` on web, a `.searchable` `List` sheet (`TimeZonePickerSheet`) on iOS, sourced from `Intl.supportedValuesOf('timeZone')` / `TimeZone.knownTimeZoneIdentifiers` respectively
- Changes go to `PUT /user/{user_id}`
- Timezone determines when the nightly data backup runs for that user — always their own local 3am, not a fixed server time (see [Data → Nightly Backup Database](../architecture/data.md))

### Subscription Card (`SubscriptionCard`)

| State | Display |
|---|---|
| Free plan | "Free Plan" header, active badge, usage limits, upgrade prompt |
| Paid (group) | Plan name, billing period, card brand + last 4, cancel option |

There is only one paid tier — **Group** (1-8 members), priced by member count. There is no
separate "individual" plan; a 1-member group plan covers that case.

Upgrade prompt: "Upgrade to unlock unlimited notes, AI check-ins, and notifications."

Clicking **Upgrade** on web opens a Stripe Checkout session (`POST /subscriptions/stripe/checkout`). On iOS, tapping the plan tile triggers StoreKit 2 (`StoreKitManager`).

**"What's included" disclosure (iOS)** — both the active-subscriber row and the pre-purchase
member-count picker include a tappable "What's included" row (`chevron.down`/`chevron.up`)
that expands in place to list the plan's benefits: unlimited notes, unlimited agent events,
and shared group access for up to the selected/purchased member count. (The former "unlimited
agent notifications" line was removed 2026-08-26 along with the user-authored notification
feature — see the Notifications note below.) Free-tier caps shown in each line are read live
from `AccountViewModel.usage`
(`FSUsage`, mirroring the backend's `FREE_LIMITS`/`NOTES_WINDOW_DAYS`) so they never drift out
of sync with server-enforced limits; a static fallback covers the brief window before usage
loads. Collapsed by default in both states, matching the app's existing progressive-disclosure
pattern (e.g. `seatCountEditRow`).

### Danger Zone

Account deletion requires the user to type their username as confirmation, then press **Delete Account**.

- **Web**: `DELETE /user/{user_id}` is called; on success the user is signed out and redirected to `/signin`.
- **iOS**: `NetworkService.deleteUser(userId:)` is awaited first; `signOut()` is called after on `MainActor` (no race condition).

The delete endpoint manually removes owned notes, nulls message and devotion author fields, then deletes the user row. All remaining related rows (subscriptions, highlights, bookmarks, agents) cascade automatically via FK constraints.

### Events

Each event row lists one scheduled agent heartbeat (recurring AI check-in that generates and
saves a note when it fires). Edit/Delete are reachable via a long-press context menu on both
platforms.

**Manual "execute now" trigger (iOS only, 2026-09-01; force-fire, 2026-09-01).** Each `EventRow`
also has an always-visible yellow play-button that fires that specific heartbeat immediately, via
the same `POST /agent/{user_id}/{agent_id}/{heartbeat_id}/commit_heartbeat` endpoint the
server-side scheduler uses for automatic due-heartbeat firing, but always sending `"force": true`
in the request body. A forced fire **always succeeds** (generates and saves a note) even if the
heartbeat already fired today — by schedule or an earlier manual force-fire — without disturbing
the scheduler's own once-per-day claim: the scheduler still fires each heartbeat at most once per
user-local calendar day regardless of how many forced fires also happen that day. The button
disables itself (with a spinner) while its own request is in flight, so it can't be double-tapped
into firing two overlapping requests for the same heartbeat; server-side, a narrower claim
independent of the daily one also denies a second concurrent forced fire for the same heartbeat
(e.g. two devices tapping at once), rather than letting both through. Firing still counts against
the same weekly free-tier notes cap as any other note-producing action, unlimited per day
otherwise. The button surfaces its outcomes distinctly: success (self-dismissing confirmation
banner, usage refreshed), the same-instant concurrent-forced-fire race (same banner, non-error
styling — proposed copy, see `.claude/pipeline/20260901-heartbeat-manual-force-fire/frontend.json`),
free-tier cap hit (the existing "Free Plan Limit" alert), or any other failure (the existing
"Agent Error" alert). No equivalent control exists on web yet.

**Group tagging (2026-09-02).** The event-setup details step (iOS: `EventSetupSheet`'s
`detailsScreen`; web: the event modal's details step, `evStep === 2`) has a gold pill-button
that drops down a submenu of the user's groups, plus a "No Group" option, styled with the
same filled-gold-pill visual system used elsewhere (iOS: `Theme.goldGradient` on a `Capsule`,
matching `Chat/PillButton.swift`; web: the `--gold`/`--gold-dim`/`--gold-light` gradient
already used by `.note-editor-save`). Selecting a group sets `group_id` on the heartbeat being
created/edited; it round-trips through `add_heartbeat`/`update_heartbeat`/`get_heartbeats` and
is visible again when the event is reopened for editing on either platform. The group list is
sourced from data each platform already fetches elsewhere (iOS: `NetworkService.fetchContacts`;
web: per-id `GET /groups/{user_id}/{group_id}` lookups, mirroring `useNotes.js`'s `loadGroups`)
rather than a new endpoint. Server-side, a submitted `group_id` is validated against the
authenticated user's own group membership before being persisted (mirroring `notes.py`'s
create/update IDOR guard) — a `group_id` for a group the caller doesn't belong to is rejected
with 403 rather than silently trusted. When a grouped heartbeat fires, the note it generates
inherits that `group_id` automatically (sourced from the heartbeat row itself, not from the
LLM's own response) so group members can see it via the existing group-notes read path; an
ungrouped heartbeat continues to fire and produce a personal note exactly as before.

---

## Visual Design (iOS)

The iOS Account page (`FellowScript/FellowScript/Account/AccountView.swift`) uses the same
interactions as above, restyled to match the app's warm-bloom / glass-card visual language
shared with the Dashboard, Chat, Notes, and Note Editor screens. Appearance-only — every
binding, async flow (Subscription's purchase/restore/cancel/leave/seat-edit/join-request
flows, Edit Profile save + timezone picker, Agent/Event create-toggle-delete,
Two-Factor Authentication, Danger Zone's username-match delete gate), sheet, and alert is
unchanged.

**Notifications section removed (2026-08-26).** The Account page previously had its own
"Notifications" card (create/edit/delete a recurring AI-authored reminder, `NotificationSetupSheet`,
a "View All" push to `NotificationsListView`) built on the now-removed user-authored notification
CRUD/trigger endpoints (see `docs/api/overview.md` → Notifications). That whole card, its
view-model state (`notifications`, `createNotification`/`updateNotification`/`deleteNotification`),
and the `FSNotification` model were deleted from the iOS client in the same pass; device-token
registration and push delivery are unaffected. No replacement UI exists yet for the backend's
new activity-tracked reminder system.

- **Container** — the root `List(.insetGrouped)` is replaced with a `ScrollView` +
  `VStack(spacing: 20)`, over `Theme.bgPage` plus two `RadialGradient` blooms (same values as
  `ChatRootView`). Each of the 13 sections is its own `glassCard(cornerRadius: 20)` tile instead
  of a flat `Theme.cardBg` list section; in-card `Divider().background(Theme.borderGoldFaint)`
  replaces native list row separators.
- **Section headers** — the shared `sectionLabel(_:)` component (also used by
  Dashboard/Chat/Bible Reader) replaces the page's own near-duplicate `sectionHeader(_:)` helper.
- **Profile avatar** — upgraded to the gradient-fill recipe used by `ChatRootView.ContactRow`'s
  avatar (translucent gold gradient fill, gold stroke), same size and position.
- **CTAs** — plain-text-link buttons (Subscription's Start/seat-edit Save-Cancel/Change plan
  size/Restore Purchases/manage-plan actions, Edit Profile's Save Changes, Friend Requests'
  Accept, Agents'/Events' "+ New …" rows, Danger Zone's Delete My Account) are
  restyled into a small shared family: a solid gradient CTA pill for primary actions, a ghost
  outline pill for secondary/destructive actions, matching the pill language already shipped in
  Chat's segment toggle and the Note Editor's header chips.
- **Danger Zone** — keeps its distinct red tint, now expressed as a tinted variant of the same
  glass card (`glassCard(tint: Theme.dangerBg, border: [...Theme.borderDanger])`) rather than a
  flat red fill. Sign Out stays in its own separate, neutral (non-danger-tinted) glass card.
