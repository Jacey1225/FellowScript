# API Overview

The backend exposes a REST API via FastAPI running on port 8000. All endpoints accept and return JSON. WebSocket connections use the `/ws/{user_id}` prefix.

Base URL: `http://<ec2-host>:8000`

---

## Authentication

| Method | Route | Description |
|---|---|---|
| POST | `/signup` | Register with `username`, `email`, `plain_pass`. Returns user object + sets `user_id` cookie. |
| POST | `/login` | Authenticate with `username`, `plain_pass`. Returns user object + sets `user_id` cookie. |
| POST | `/auth/google` | Exchange a Google ID token for a session. Find-or-create user. |
| POST | `/auth/apple` | Verify an Apple identity JWT. Find-or-create user. |

All signup paths automatically create a `plan_type='free'` subscription row for the new user.

---

## Users

| Method | Route | Description |
|---|---|---|
| GET | `/user/{user_id}` | Get user profile (excludes `hash_pass`) |
| PUT | `/user/{user_id}` | Update `username`, `email`, `plain_pass`, or `timezone` (IANA name, e.g. `America/Los_Angeles`; validated, drives the nightly backup schedule) |
| DELETE | `/user/{user_id}` | Permanently delete account and all owned data |

---

## Notes

| Method | Route | Description |
|---|---|---|
| GET | `/notes/{user_id}` | One page (15) of the user's personal notes (excludes replies and group notes), newest first. Keyset-paginated — see below. |
| GET | `/notes/{user_id}/count` | Total count of the user's personal notes: `{ "count": int }`. Unpaginated, for summary displays. |
| GET | `/notes/{user_id}/search?q=` | Keyword search (case-insensitive substring) over the user's personal notes' `title`/`text`, excluding replies and group notes. Returns every match in one response — not keyset-paginated, since the result set is already bounded by the query. Same response shape as `GET /notes/{user_id}` minus the pagination fields. |
| GET | `/notes/{user_id}/note/{note_id}` | Fetch a single note by id, permission-checked (owner or shared group membership). `{user_id}` is the *viewer*, not necessarily the note's owner. Returns `{"error": "cannot find note"}` — identical for a missing note and a not-visible one, so note-id enumeration can't tell them apart — otherwise the note, same per-note shape as `GET /notes/{user_id}` plus a `username` field (the owner's display name, since this route can return a note the caller doesn't own). |
| POST | `/notes/{user_id}` | Create a note. Body: `{ title, text, public, group_id, verses: [[book, ch, v], …] }` |
| PUT | `/notes/{user_id}?note_id=` | Update a note (owner only). Replaces verse list. Bumps `timestamp`. |
| DELETE | `/notes/{user_id}?note_id=` | Delete a note (owner only) |
| POST | `/notes/reply/{note_id}` | Post a reply to a note |

Note responses include `created_at` (immutable creation timestamp) and `timestamp` (last-edited).

### Pagination (`GET /notes/{user_id}` and `GET /groups/{user_id}/{group_id}/notes`)

Both note-listing GETs are capped server-side at 15 notes per request via keyset
(cursor) pagination anchored on `(created_at, _id)`, ordered newest first — not
`OFFSET`, since a note created or deleted between page loads would otherwise
shift row positions and cause the client to skip or re-see notes.

Query params (both optional; supply together or omit both for the first page):

- `cursor_created_at` — `created_at` of the last note from the previous page.
- `cursor_id` — `_id` of the last note from the previous page.

Response shape:

```json
{
  "notes": { "...": "note_id -> note data (personal), or username -> {note_id -> note data} (group)" },
  "next_cursor_created_at": "2026-08-17T12:00:00Z",
  "next_cursor_id": "uuid",
  "has_more": true
}
```

Pass `next_cursor_created_at`/`next_cursor_id` back as `cursor_created_at`/`cursor_id`
to fetch the next page. `has_more` is `true` iff a full page (15) was returned —
`false` means the end of the list has been reached, even though cursor fields
may still be populated.

---

## Highlights

| Method | Route | Description |
|---|---|---|
| GET | `/notes/highlight/{user_id}` | All highlights for the user: `{ "{book}-{ch}-{v}": color }` |
| POST | `/notes/highlight/{user_id}` | Set or update a highlight. Body: `{ book, chapter, verse, color }` |
| DELETE | `/notes/highlight/{user_id}/{key}` | Remove a highlight |

---

## Bookmarks

| Method | Route | Description |
|---|---|---|
| GET | `/notes/bookmark/{user_id}` | All bookmarks: `{ "{book}-{ch}": label }` |
| POST | `/notes/bookmark/{user_id}` | Add or update a bookmark. Body: `{ book, chapter, label }` |
| DELETE | `/notes/bookmark/{user_id}/{key}` | Remove a bookmark |

---

## Groups

| Method | Route | Description |
|---|---|---|
| POST | `/groups/{user_id}` | Create a group |
| GET | `/groups/{user_id}` | List groups the user belongs to |
| PUT | `/groups/{user_id}/{group_id}` | Update group details |
| DELETE | `/groups/{user_id}/{group_id}` | Delete a group (owner only) |
| POST | `/groups/{user_id}/{group_id}/join` | Join a group |
| POST | `/groups/{user_id}/{group_id}/leave` | Leave a group |
| GET | `/groups/{user_id}/{group_id}/notes` | One page (15) of public notes shared in the group, newest first. Keyset-paginated, same contract as `/notes/{user_id}` above (blocked users excluded server-side). |
| GET | `/groups/{user_id}/{group_id}/notes/search?q=` | Keyword search (case-insensitive substring) over the group's notes' `title`/`text`. Returns every match in one response (not keyset-paginated), blocked users excluded server-side. Caller must be a group member. |
| GET | `/groups/{user_id}/{note_id}/{group_id}/replies` | All replies to a note shared in the group. Caller must be a group member. |
| GET | `/groups/{group_id}/highlights` | All highlights in the group |
| POST | `/invites/preview` | Public, per-IP rate limited. Body `{token}`. Returns `{kind, group_name, photo_url, inviter_username, member_count}` for a usable invite link; every unusable token gets the same 404 `{detail:{code:"not_found"}}`. |
| POST | `/invites/{user_id}/redeem` | Join a group via invite token (body `{token}`). Idempotent for existing members. Errors (`detail.code`): `not_found` 404, `expired`/`revoked` 410, `full` 409, `blocked` 403 (generic). |
| POST | `/invites/{user_id}/groups/{group_id}` | Any member creates a link (optional `expires_in_days`, `max_uses` from the configured allowed sets). Returns the plaintext `token`/`url` once only. |
| GET | `/invites/{user_id}/groups/{group_id}` | Active links (metadata only, own links; all for the group creator) plus create options. |
| POST | `/invites/{user_id}/groups/{group_id}/reset` | Revoke every active link the caller may revoke. |
| GET | `/invites/{user_id}/{invite_id}/reveal` | Authenticated, `no-store`, rate limited. Re-shows an active group link (`{invite_id, url}`) to its creator or the group creator. Every failure (unknown, revoked, expired, legacy link created before reveal existed, subscription link, not authorized) is the same 404 `not_found`. List items carry `revealable` (bool). |
| DELETE | `/invites/{user_id}/{invite_id}` | Revoke one link (its creator or the group creator). |

<!-- shared-foundation -->
**Member-list behaviour change (task 20261002-shared-foundation).** `PUT /groups/{user_id}/{group_id}` silently drops ids that are already in the group's stored member list but no longer exist as users (clients that echo the raw array keep working). Any NEW id must be a UUID of an existing, non-suspended user; otherwise the route answers `422 { "detail": { "code": "invalid_member", "message": ... } }`, with an identical body for malformed, unknown and suspended ids. This is a change for build-78 clients: adding a new member who is suspended now returns 422 where it was accepted before. `POST /groups/{user_id}` applies the same check to every supplied member id (the creator's own id always passes). Deleting an account (`DELETE /user/{user_id}`) now removes that id from every group's member list; a group whose last member deletes their account is deleted. Deleting or emptying a group queues its photo and announcement banner objects for deletion (no response change).

**Listed-group guard (task 20261001-explorer-listings).** While a group has a listing in review, published or hidden, `PUT /groups/{user_id}/{group_id}` answers `409 { "detail": { "code": "owner_only", ... } }` for an addition of members by anyone but the group's creator and for any change that removes the creator from the member list. Groups without a listing behave exactly as before (build-78 clients keep working for them). Renaming a listed group never changes its listing.

**Reports (`POST /reports/`).** `content_type` also accepts `group_listing` and `thread_message`. A malformed `content_id` answers `422` (it used to be a 500; `group_listing` ids are 10-character alphanumeric public ids, every other type takes a UUID). Content that cannot be found for a listing or thread type answers `404` and nothing is stored; the five original types keep their lenient behaviour. The stored `content_id` is the canonical internal id.

**Explorer listing moderation.** Reports on a listing send its 10-character `public_id`; the server stores the listing's internal id and a snapshot (title, summary, description, status, public id; at most 5000 characters). A listing report is limited per reporter (`listings.rate_limits.report`, `429` over the limit). When the listing has reports from `report_auto_hide_threshold` distinct reporters it is hidden (reason `reported`) and the owner is emailed. Admin endpoints (`require_admin`): `GET /admin/explorer/listings/queue?status=`, `POST /admin/explorer/listings/{public_id}/approve|reject|hide|restore` (`reject` and `hide` take `{"reason_code": ...}` from the configured lists and email the owner), `DELETE /admin/explorer/listings/{public_id}`. CLI: `python -m backend.admin_listings hide <public_id> [--reason CODE]`, `restore <public_id>`, `hide-all` (rollback lever, reason `bulk`); `python -m backend.moderation.admin_actions resolve <report_id> --remove-content` removes a reported listing and `--eject` also hides the suspended owner's listings at once.

---

## Friends

| Method | Route | Description |
|---|---|---|
| POST | `/friends/{user_id}/request` | Send a friend request |
| GET | `/friends/{user_id}/requests` | Incoming friend requests |
| POST | `/friends/{user_id}/accept/{friend_id}` | Accept a request |
| DELETE | `/friends/{user_id}/{friend_id}` | Remove a friend |
| GET | `/friends/{user_id}` | Friend list |
| GET | `/friends/{user_id}/activity` | Friend-activity read surface for the dashboard's Friend Activity hero card: each friend's most recent group note preview, most recent highlight preview (with real verse text), last-active timestamp + activity type (block-respecting both directions), plus a bounded "check in" nudge candidate pool (up to 5 friends gone longest without a direct message). |
| POST | `/friends/{user_id}/{friend_id}/nudge` | Send a fixed, non-user-authored "come back and study" push notification to a friend. Gated behind `NUDGE_FEATURE_ENABLED` (404 while disabled, as if the route doesn't exist) and rate-limited per sender→recipient pair (`NUDGE_RATE_LIMIT_HOURS`, one nudge per pair per window), plus a coarse `30/minute` per-IP backstop. Triggered client-side from the Dashboard's Friend Activity hero card (one randomly-surfaced check-in candidate) and, as of task `20260922-chat-friend-nudge-button`, from a nudge control on every friend row in the Chat page's friends list (any friend, not just a surfaced candidate) — both surfaces call this same endpoint with an arbitrary `friend_id`. |

### `POST /friends/{user_id}/{friend_id}/nudge`

Task `20260906-friend-nudges`. Confirms friendship and checks block state (both directions) before sending — friend-only, deny-by-default. Delivers via the existing APNs `send_push` pipeline with fixed, templated copy (`"{sender_username} wants you to hop back into FellowScript"`); there is no user-composable message content, consistent with this project's earlier removal of open-ended user-authored notifications (see the Notifications section below).

**Response:** `204` on success (no body).

**Errors:** `403` if `friend_id` isn't a friend of `user_id`, or either direction has blocked the other. `404` if the feature is disabled, or the recipient has no registered device token. `429` if this sender already nudged this recipient within the configured rate-limit window, or the per-IP backstop was tripped. `502` if APNs reported the push as undeliverable. A missing/misconfigured APNs credential surfaces as a `500` (deliberately not swallowed).

### `GET /friends/{user_id}/activity`

**Response:** `200` with
```json
{
  "friends_active": [
    {"friend_id": "uuid", "username": "str", "last_active_at": "iso8601 | null",
     "activity_type": "note_created | note_edited | note_replied | verse_highlighted | null",
     "note_preview": {"note_id": "uuid", "title": "str", "text": "str", "timestamp": "iso8601"} | null,
     "highlight_preview": {"book": "str", "chapter": "int", "verse": "int", "color": "str",
                            "verse_text": "str | null", "timestamp": "iso8601"} | null}
  ],
  "check_in_candidates": [
    {"friend_id": "uuid", "username": "str", "days_since_contact": "int | null"}
  ]
}
```
`friends_active` is ordered most-recently-active first. `activity_type` is the friend's most recent tracked activity type, so the client can label the entry (created/edited/replied/highlighted) without a second request. `note_preview` is only populated from a *group* note the caller shares membership in — a friend's personal notes stay private to them regardless of friendship. `highlight_preview` is populated for any friend's most recent highlight, including its real verse text where resolvable — friendship alone is sufficient grant to see a friend's highlight (a deliberate widening; previously highlights had no visibility to anyone). `check_in_candidates` is ordered longest-since-contact first, capped at 5 entries (or the friend count, whichever is smaller), and is an empty list only when the user has no friends — the client picks among these candidates rather than the whole friend list, to keep the nudge targeted at genuinely-neglected friends.

---

## Messaging (WebSocket)

Connect: `ws://<host>:8000/message/ws/{user_id}`

Messages are JSON payloads with a `type` field:

| Type | Direction | Description |
|---|---|---|
| `group_message` | send / receive | Group chat message |
| `dm` | send / receive | Direct message to another user |
| `activity` | receive | Member activity broadcast (reading, highlighting, noting) |

REST history: `GET /message/messages/{host_user}/?guest_user=...` returns past DMs between two users; group history comes back from `GroupsManager`'s group-read call.

### Message ids, acks and timestamps (task 20261001-chat-pagination, backend 1a)

- Every history row (group and DM) and every delivered chat frame carries `id` (string UUID). It is additive: existing clients ignore it. The frame omits `id` rather than sending null if the server could not read the stored id.
- A sender may add an optional `client_ref` (1-64 characters from `A-Za-z0-9_-`) to a chat payload. When it is valid, the server answers on the sender's own socket only, after the message is stored: `{"type":"ack","client_ref":...,"id":...,"group_id":...,"timestamp":...}` (`group_id` is empty for a DM, `timestamp` is ISO 8601 UTC with microseconds). The ack has no `from_user` or `text`, so it never renders as a bubble. An invalid or missing `client_ref` is ignored: the message is still saved, with no ack.
- Timestamps: the client timestamp stays the primary sort key. A value that does not parse, or is later than now plus `future_timestamp_skew_seconds` (default 300), is stored as the server time. Recipient frames keep the client's original string when it was accepted unchanged; a clamped value is relayed as whole-second `...Z`. Past timestamps are never changed.
- Ties are broken by `messages.seq` (server sequence `messages_seq`; rows from before the migration read as 0), then by id.
- Soft-deleted rows (`deleted_at` set) are excluded from the history reads. Legacy responses are otherwise unchanged.
- Tunables live in `api/config/chat.json`, section `pagination` (all keys required; the server refuses to boot on a bad file). The paged group endpoints below are gated by the `chat_pagination` feature flag.

### Group chat history paging (task 20261001-chat-pagination, backend 1b)

Opt-in and flag-gated (`chat_pagination`, off by default; clients read `GET /app/capabilities` and send `limit` only when it is true).

- `GET /groups/{user_id}/{group_id}?limit=N`: with the flag on for the caller, the response is `{group, members, messages, page}` where `messages` is the newest page, oldest-first, and `host_msgs`/`other_msgs` are omitted. With no `limit`, or with the flag off (or an older server), the response is the legacy `{group, members, host_msgs, other_msgs}` shape; a client treats a missing `page` key as full history. `limit` must be an integer of at least 1 (otherwise `422`, only while the flag is on); a value above `max_page_size` is clamped. `403` for a non-member.
- `GET /groups/{user_id}/{group_id}/messages?limit=&cursor_timestamp=&cursor_seq=&cursor_id=`: one older page, `{messages, page}`. While the flag is off for the caller this answers `404`. Order of checks: session, `user_id` match, flag (`404`), membership (`403`), `limit` and cursor (`422`, before any SQL), then the query. Rate limited by `pagination.rate_limits.messages_page` in `api/config/chat.json`.
- `page` is `{limit, has_more, next_cursor_timestamp, next_cursor_seq, next_cursor_id}`. Pass the three `next_cursor_*` values back as `cursor_timestamp`, `cursor_seq` and `cursor_id` (timestamp and id together or neither; seq optional, default 0). They are null when `has_more` is false.
- Row shape: `{id, from_user (username), mine, text, timestamp (ISO 8601 UTC, microseconds, Z), attachment_kind, attachment_meta, attachment_url}`. `attachment_url` is a fresh short-lived presigned GET (null when there is no stored attachment); the stored key is never returned.
- Pages are ordered `timestamp DESC, seq DESC, id DESC` with a keyset predicate, so inserts and deletes never shift older pages. Only the caller's own messages and those of current, unblocked members are returned (blocking is filtered in SQL, so a page never shrinks), and soft-deleted rows are excluded.

### Direct message history paging (task 20261001-chat-pagination, backend step 4)

Same opt-in contract and page envelope as group paging, behind its own flag `chat_pagination_dm` (off by default; capability `features.chat_pagination_dm`).

- `GET /friends/{user_id}/{friend_id}?limit=N` and `GET /message/messages/{host_user}/?guest_user=...&limit=N` (use `limit=1` for a last-message preview): with the flag on for the caller the response carries `friend` (or the existing `payload` wrapper) plus `messages` and `page` instead of `host_msgs`/`other_msgs`. Without `limit`, or with the flag off, the legacy shape is unchanged.
- `GET /friends/{user_id}/{friend_id}/messages?limit=&cursor_timestamp=&cursor_seq=&cursor_id=`: one older page, `{messages, page}`. `404` while the flag is off, and the same `404` as the legacy read for an unknown or blocked friend; `422` for a bad `limit` or cursor (before any SQL). Rate limited by `pagination.rate_limits.messages_page`.
- Rows use the group row shape (`mine` is true for the caller's own messages). Only messages exchanged between the two users are returned (`group_id IS NULL`, joined through `message_recipients`), and soft-deleted rows are excluded. Index: `idx_messages_dm_page`.

### Attachments (task 20260904-messaging-attachments)

A message may carry an attachment instead of (or alongside) `text` — send/receive payloads gain three optional fields:

```json
{
  "text": "",
  "attachment_kind": "image | video | file | gif | null",
  "attachment_key": "server-issued S3 object key (image/video/file only, request-side) | null",
  "attachment_meta": {"...": "kind-specific -- e.g. gif's provider id/url/width/height, or file's display filename"}
}
```

On receive (live WebSocket delivery, or DM/group history load), the server never hands back the raw stored `attachment_key` — it resolves it to a fresh, short-lived presigned GET at read time instead:

```json
{
  "attachment_kind": "image | video | file | gif | null",
  "attachment_meta": {"...": "..."},
  "attachment_url": "presigned GET url (image/video/file), or null for gif -- gif's url already lives in attachment_meta"
}
```

An attachment_kind outside `image`/`video`/`file`/`gif`, or one missing the reference its kind actually needs, is silently dropped server-side (never persisted) rather than saved with a broken reference.

| Method | Route | Description |
|---|---|---|
| POST | `/message/upload-url/{user_id}` | Self-scoped (caller must be `user_id`). Body: `{"attachment_kind", "content_type", "size_bytes"?}`. Returns a presigned S3 POST policy: `{"url", "fields", "object_key", "expires_in"}` — upload the raw file directly to `url` with `fields` (multipart form), then reference `object_key` as `attachment_key` in the message you send. `400` for an unsupported kind/content-type combination; `503` if attachment uploads aren't configured yet. |
| GET | `/message/gif-search?q=&page_token=` | Authenticated. Proxies a GIF search to the configured provider (GIPHY/Tenor) so the provider API key never reaches the client. A non-empty `q` returns `{"results": [{"id", "url", "preview_url", "width", "height"}]}` (unpaginated), exactly as before. An empty/absent `q` instead requests a page of default/trending browse results (shown in the picker before any query is typed), returning `{"results": [...same shape...], "next_page_token": "opaque string or null", "has_more": bool}` — pass a previous response's `next_page_token` back as `page_token` to fetch the next page; `page_token` is ignored when `q` is non-empty. `next_page_token` normalizes GIPHY's integer offset and Tenor's opaque cursor behind one shape — callers never branch on provider. `502` if the provider call fails, `503` if GIF search isn't configured yet. |

Per-kind upload limits (server-enforced via the presigned POST policy's `content-length-range`, not just advisory): image ≤15MB (`image/jpeg`, `image/png`, `image/webp`, `image/heic`), video ≤250MB (`video/mp4`, `video/quicktime`), file ≤50MB (`application/pdf`, `text/plain`, `.doc`/`.docx`/`.xlsx`). GIFs never upload to our own storage at all — only the provider's id/url is stored.

---

## Subscriptions

| Method | Route | Description |
|---|---|---|
| GET | `/subscriptions/user/{user_id}` | Get current subscription + usage summary |
| POST | `/subscriptions/checkout` | Create a Stripe Checkout session (web). Body: `{user_id, member_count, promo_code?}` (1-8) — price is looked up server-side by count. With `PROMO_CODES_ENABLED` on, an optional `promo_code` is re-validated server-side and applies the first-month coupon; any invalid code returns a uniform `400 {code: "invalid_promo_code"}` and creates no session. Ignored while the flag is off |
| POST | `/subscriptions/stripe/webhook` | Stripe webhook handler |
| POST | `/subscriptions/apple/sync` | Record/refresh a plan from a StoreKit 2 signed transaction (iOS). One of 8 fixed-price products maps to a member count server-side |
| POST | `/subscriptions/apple/notifications` | Apple App Store Server Notification handler |
| PUT | `/subscriptions/{subscription_id}` | Update a plan (host only). Body may include `member_count` to change plan size — re-prices from the same table |
| POST | `/subscriptions/admin/grant-individual` | **Admin-only** (`require_admin`; `401`/`403` semantics as below). No body — the target is always the calling admin, never a client-supplied user. Grants the caller a free, active, individual-tier membership (`plan_type='individual'`, `provider='admin_comp'`, $0, no Stripe/Apple billing) with the same unlimited access a paying individual subscriber gets. Idempotent — calling it again returns the same existing grant rather than creating a duplicate. Never expires (not subject to the `EXPIRY_GRACE_DAYS` lapse sweep). Every grant is recorded in the `admin_audit` log. Returns the resulting subscription, same shape as `GET /{subscription_id}`. |

### Promo codes (creator + friend invite codes)

Feature-flagged by `PROMO_CODES_ENABLED` (default off). While off, every route below answers a uniform `404` (before auth). Details: `docs/architecture/backend.md` "Promo codes".

| Method | Route | Description |
|---|---|---|
| POST | `/promo/{user_id}/validate` | Authenticated, rate-limited (`PROMO_VALIDATE_RATE_LIMIT`, per IP and per user). Body `{code, member_count?}`. Returns `{valid: true, percent_off}` or the identical `{valid: false}` for every failure. Creates nothing, logs nothing |
| POST | `/promo/{user_id}/friend-code` | Authenticated. Get-or-create the caller's personal invite code. Returns `{code, link, percent_off}` |
| POST/GET | `/admin/promo/creators` | **Admin-only.** Create / list creators (`name`, `notes`, `active`) |
| PATCH | `/admin/promo/creators/{id}` | **Admin-only.** Update or deactivate a creator |
| POST/GET | `/admin/promo/codes` | **Admin-only.** Create creator codes (`code`, `creator_id`, optional `max_redemptions`, `expires_at`) / list (`kind`, `creator_id`, paging) |
| PATCH | `/admin/promo/codes/{id}` | **Admin-only.** Activate/deactivate, change cap or expiry |
| GET | `/admin/promo/report` | **Admin-only.** Completed redemptions per creator (+ `over_cap_redemptions`) |
| GET | `/admin/promo/redemptions` | **Admin-only.** Redemption list (`creator_id`, `kind`, paging) |

---

## Notifications

The former user-authored ("agentic") notification management subsystem —
CRUD + AI-trigger + scheduling endpoints under `/notification/{user_id}/...`
— was removed in full (2026-08-26). Only device-token registration remains:

| Method | Route | Description |
|---|---|---|
| POST | `/notification/{user_id}/device-token` | Register/update the caller's APNs device token |

A backend activity-tracked, fixed-notification system now drives every push
in the app — no user-configurable triggers, just a fixed set of jobs
(`backend/interactions/scheduler.py`, see
[Background Scheduler](../architecture/backend.md#background-scheduler)):
a midday nudge, a >24h "guilt" nudge, and a cross-user "friend went active"
push, the last of which names the specific action (create/edit/reply/
highlight) and, for a highlight, includes real verse text resolved from a
bundled Bible-text asset. It fires once per inactive→active transition
(>24h gap), not on every individual note/highlight/reply.

Two more pushes cover session/devotion scheduling (2026-09-04), both to the
session's resolved group/DM members (`DevotionManager.resolve_members`):
`POST /devotions/` sends a "New Session" push to every member except the
creator, immediately on creation; `_fire_due_session_reminders` sends a
"Session Starting" push to every member once the session's `time_start`
arrives, exactly once (see [`devotions.reminder_sent_at`](../architecture/data.md#devotions)).
Both carry `devotion_id`/`group_id` in the payload's `data` for the client
to resolve locally. The iOS client resolves it: tapping either push
(`AppDelegate.userNotificationCenter(_:didReceive:)`) opens that session's
chat thread directly (`AppState.openSession(groupId:)`), splitting a DM room
key (`"uidA|uidB"`) to the other participant or treating any other value as
a real group id — the same cross-tab navigation the Dashboard's Friend
Activity widget already uses.

### Session join-window gating (task `20260920-session-join-window-gating`)

`POST /devotions/join` and `POST /devotions/join-call` now enforce a
time window on top of their existing membership check
(`DevotionManager.is_authorized`): once a caller is authorized, both routes
also call `DevotionManager.is_join_window_open(session)` and 403
(`"This session isn't open yet."`) if the session isn't currently open —
`join-call` checks this before ever creating (or recreating) the billed AWS
Chime meeting, so an out-of-window call never spins one up.

A session is open once the server's own clock (`NOW()` in Postgres, never a
client- or app-server-supplied time) reaches `time_start` minus a
configurable early-join grace period (`SESSION_JOIN_GRACE_MINUTES`, new
required config validated eagerly at startup — see
[Configuration](../architecture/backend.md)), and stays open through
`time_end`; a session with no resolvable `time_start` never opens (fails
closed), while a session with no resolvable `time_end` stays open
indefinitely once started. A session with a live Chime meeting already
attached (`chime_meeting_id` set) is always considered open regardless of
the time window — this is also what lets an already-live call's "ring a
member" invite (`POST /devotions/ring`, below) bypass the window, since a
real Chime meeting can only exist once someone already joined in-window.
The iOS client independently greys out its own Join controls using the same
window (device local time, cosmetic only) so the button reads as disabled
before a request would even be attempted — the server-side check above is
what actually closes a direct-API/clock-manipulation bypass of that UI
state.

### `POST /devotions/ring` (task `20260916-call-ring-members`)

Lets a participant already on a live session's call prompt one or more of
that session's own group members to join. Body: `{ devotion_id, user_id,
target_ids: [...] }` — `user_id` must match the session cookie's caller.
Gated behind `RING_FEATURE_ENABLED` (404 while disabled, as if the route
doesn't exist, same posture as the friend-nudge feature flag above).

Reworked after a security review of the first implementation (see below):
the caller must pass BOTH `DevotionManager.is_authorized` AND
independently appear in `DevotionManager.real_group_roster(group_id)` — a
roster resolved only from the real `groups` table row (or the DM-pair
split for a `"uidA|uidB"`-style `group_id`), never from
`session.creator_id`/`session.participants`, since those two fields are
client-supplied at session creation and aren't validated against real
group membership. Each target must independently be in that same
`real_group_roster(group_id)` set (minus the caller) — `resolve_members`
is no longer used for ring, since it folds those same unverified fields
in. A blank `group_id` resolves to an empty roster, so a session with no
real group behind it denies everyone rather than falling back to
`participants`/`creator_id`.

The whole request is also denied up front — before any target is
evaluated — if the session has no live call attached yet (empty
`chime_meeting_id`, i.e. no one has actually joined/created the Chime
meeting for it via `join-call`): every requested `target_id` comes back
with reason `no_active_call` in that case. Unlike the friend nudge above,
ringing is otherwise not all-or-nothing: every requested `target_id` is
evaluated and reported on its own, so one multi-select ring attempt can
partially succeed. Response:
`{ "results": { target_id: { "sent": bool, "reason": str | null } } }`,
where `reason` is one of `no_active_call`, `invalid_target`,
`not_a_member`, `unreachable`, `rate_limited`, or `send_failed` whenever
`sent` is `false`.

Each `(sender, recipient)` pair has its own cooldown
(`RING_COOLDOWN_MINUTES`, claimed atomically before the send and released
if the send fails), independent of `session_id` — a fresh session can no
longer reset it. (The original design scoped this per-session instead;
that let a sender mint a new session and re-ring the same target with no
effective limit, so it was replaced with this cross-session key.) A
coarse `30/minute` per-IP backstop applies on top, same shared `limiter`
instance as the friend-nudge route. Delivers via the existing APNs
`send_push` pipeline with fixed, non-user-authored copy
(`"{caller_username} wants you to join "{session_title}" now"`, or a
generic fallback if the session has no title) and a `data` payload of
`{"action": "ring", "devotion_id", "group_id"}` — the `action`
discriminator lets the client tell a ring push apart from the plain "New
Session"/"Session Starting" pushes above and route its tap-through
straight into the live join flow instead of just the session detail
screen.

---

## Agent (AI Check-ins)

| Method | Route | Description |
|---|---|---|
| GET | `/agent/{user_id}` | Get agent configuration |
| PUT | `/agent/{user_id}` | Update agent config (frequency, tone, etc.) |
| POST | `/agent/{user_id}/heartbeat` | Trigger a scheduled devotion (enforces free-tier cap) |
| POST | `/agent/{user_id}/{agent_id}/summarize` | Summarize a study session (body: `{session, group_id}`) and save the result as a note titled `Session Summary — {title}`. Enforces the same free-tier `notes` cap as note creation |

Task 20260907-session-summary-wireup wired this endpoint up end-to-end: a
session created with its "Summarize" toggle on (`devotions.summarize`, see
[`devotions`](../architecture/data.md#devotions)) has its client call this
route the moment its Chime call ends (`CallController.end()` in
`ChimeCallView.swift`), using only the ending session's own creator — not
every participant still on the call — to avoid minting one duplicate summary
note per participant. The client silently resolves an `agent_id` (reusing the
user's first existing `FSAgent`, auto-creating one if they have none) rather
than surfacing an agent picker, since an agent's `role` only tints the LLM
prompt server-side. A failed summarize call never blocks or delays leaving
the call — it surfaces afterward as a warm, self-dismissing banner
(`CallController.summarizeNotice`) instead.

Bug fix (task 20260911-session-summary-group-id-crash): the `group_id` in
the request body is whatever `ChatThreadViewModel.roomKey(...)` computed
for the session's thread client-side, which is a real `groups._id` only for
a group session — for a friend-DM session it's the synthetic
`"<uidA>|<uidB>"` composite room key (see
[`devotions`](../architecture/data.md#devotions) / `AppState.openSession`'s
same `"|"` check), never a group row. The route now recognizes that
composite shape and saves the summary as a private note (`group_id: null`)
in that case instead of passing it through to the `uuid`-typed
`notes.group_id` column, which previously 500'd. Any other `group_id` is
checked against real group membership (`_require_group_membership`, same
IDOR guard `add_heartbeat`/`update_heartbeat` use) and rejected with `403`
if the caller doesn't belong to it.

Bug fix (task 20260915-session-summary-note-fixes): two ways a summary note
could end up wrong have been closed off. First, a title-only session (empty
`prompts` AND empty `verses` — e.g. a scheduled call that ended with nothing
actually discussed) now returns `422` and saves no note, instead of calling
the LLM anyway and persisting whatever confused non-answer came back (e.g.
"I don't have information about this session") as if it were a real
summary; having just one of `prompts`/`verses` still counts as summarizable
content. Second, the shared agent system prompt can lead the model to
respond with a `create_note` JSON action block instead of plain prose (the
"Format it as a readable study note" instruction is enough to trigger this);
the route now detects a leaked action block and either salvages its own
`text` field as the summary or, if there's nothing salvageable, fails with
`502` and saves no note — the raw JSON action block itself is never written
into `notes.text`.

---

## Usage / Limits

Free-tier limits are enforced on the server before every create operation. When a cap is reached the route returns:

```
403 { "detail": { "resource": "notes", "used": 5, "limit": 5, "remaining": 0 } }
```

Subscribed users (`plan_type != 'free'`, status `active`/`trialing`) are always allowed.

---

## Filtering & Sorting

| Method | Route | Description |
|---|---|---|
| POST | `/filter/{user_id}` | Filter notes by book, date, title, or user |
| POST | `/sort/{user_id}` | Sort notes by date ascending or descending |

---

## Monitoring (Error Detections)

Read-only feed of CloudWatch error detections collected by the background watchdog job (see [Backend → Background Scheduler](../architecture/backend.md#background-scheduler)). Auth: **admin-only**. All routes require `require_admin` (session auth via the `session` cookie, plus an `is_admin` flag on the resolved `users` row) — `401` for no/invalid session, `403` for an authenticated caller who isn't flagged admin. This replaces the earlier any-authenticated-user placeholder.

| Method | Route | Description |
|---|---|---|
| GET | `/monitoring/detections` | Paginated, filterable list of detections, most recent first. Query params: `log_group_name`, `start_time`, `end_time`, `limit` (1-200, default 50), `offset`, `include_noise` (default `false`). Returns `{ items, total, limit, offset }`; each item omits the assembled `context` blob. By default, rows flagged `status='noise'` — a one-time backfill flagging detections from the 2026-08-14 production OOM incident window, where the watchdog was re-detecting its own/the debug agent's failure logs rather than real distinct application errors — are excluded from the response and from `total`. Pass `include_noise=true` to include them (e.g. for postmortem review); they are never deleted. |
| GET | `/monitoring/detections/{detection_id}` | Full detection record, including assembled `context` (nearby log lines + log-analyzer output). `404` if not found. Unaffected by the `status='noise'` filter above — always returns the record regardless of status, so a specific incident-window detection stays reachable by id. |
| GET | `/monitoring/detections/{detection_id}/report` | The debugging agent's persisted diagnostic report for one detection: `{ id, detection_id, root_cause, remediation_narrative, model, generated_at }`. `404` if the detection or its report doesn't exist yet. |
| POST | `/monitoring/detections/{detection_id}/report` | On-demand (re)generate the debugging agent's report for one detection, overwriting any prior report for it. `404` if the detection doesn't exist, `502` if the upstream OpenRouter call fails. |
| POST | `/monitoring/detections/{detection_id}/report/download-audit` | Audit-only: records that an admin downloaded the (client-assembled) remediation Markdown handoff file for one detection. Returns no detection/report content — just `{ "logged": true }`. `404` if the detection doesn't exist. The admin page calls this immediately before triggering the local file download, since the `.md` itself is built entirely client-side from data already fetched. |

Nothing under `/monitoring` executes, queues, or takes any action against the server — this surface (including the debugging agent) is strictly read-only/reporting. The debugging agent (`backend/monitoring/debug_agent.py`) reads a detection's `message` + `context`, redacts anything shaped like a secret/credential/API key/connection-string password before it reaches the OpenRouter prompt, and produces a root-cause + remediation-narrative write-up — a recommendation for a human operator, never a record of an action taken. It reuses `AgentManager`'s existing OpenRouter credential/wiring (`backend/interactions/agent.py`) rather than a second isolated key. It runs automatically once per newly-persisted detection (from the watchdog's poll cycle) and routes `error_detections.status` to `"diagnosed"` on success; the `POST` route above lets the admin page trigger a rerun.

## Activity Monitoring

A second, separate admin panel (task `20260918-admin-activity-monitoring`, extended by `20260919-activity-monitoring-interactive-charts`) from the CloudWatch console above — average per-user activity and website-visit trends. One endpoint is intentionally public; the rest are **admin-only** (`require_admin`, same `401`/`403` semantics as Monitoring above). The same underlying series is available two ways: pre-rendered matplotlib PNGs (`/plots/*`), or raw JSON (`/data/*`) for a client-side interactive chart.

| Method | Route | Auth | Description |
|---|---|---|---|
| POST | `/activity-monitoring/visits` | None (anonymous) | Visit-logging beacon called by the web frontend on page navigation. Body: `{ device_id, path }` — `device_id` is a client-generated, `localStorage`-persisted UUIDv4 (never a cookie, never IP/User-Agent derived); `path` is length-capped (200 chars) and must not contain a query string. Rate-limited to 30/minute per IP. Always `204`, no body — never reflects stored/aggregate data back to the caller. |
| GET | `/activity-monitoring/plots/visits` | Admin | Raw-visits-vs-unique-device-visitors PNG (`image/png`) for the trailing 30 days. "Unique" is `COUNT(DISTINCT device_id)` per day, so repeat visits from the same device don't inflate it. `Cache-Control: no-store`. |
| GET | `/activity-monitoring/plots/{metric}` | Admin | Average-per-user PNG for one of `notes` / `highlights` / `logins` / `messages`, trailing 30 days. `logins` is derived from `sessions.created_at` (no dedicated login-event table exists). `404` for an unrecognized metric. `Cache-Control: no-store`. |
| GET | `/activity-monitoring/data/visits` | Admin | JSON version of `/plots/visits`: `{ title, series: [{ day, raw, unique }, ...] }` for the same trailing-30-day window. `Cache-Control: no-store`. |
| GET | `/activity-monitoring/data/{metric}` | Admin | JSON version of `/plots/{metric}`: `{ metric, title, ylabel, series: [{ day, value }, ...] }`. Same `metric` validation and `404` behavior as `/plots/{metric}`. `Cache-Control: no-store`. |

Every admin GET above logs one `admin_action` audit line (`action=view_activity_monitoring`) via the same `admin_audit` logger `/monitoring` uses. The average-per-user denominator is the current total user count (not a historically accurate per-day cohort) — a deliberate snapshot-dashboard simplification, not a billing-grade calculation. The `/data/*` endpoints carry exactly the same (day, value) resolution the `/plots/*` images already visually encode — no raw per-row data, device IDs, or per-user breakdowns — so the JSON surface discloses nothing beyond what the PNG already showed. See [Data → `visits`](../architecture/data.md#visits) for the schema.

---

## App capabilities and feature flags (task 20261002-shared-foundation)

<!-- shared-foundation -->
Ships inert: every flag seeds `off`, so nothing user-visible changes until a flag is flipped (only by the owner, never by the build pipeline).

| Method | Route | Auth | Description |
|---|---|---|---|
| GET | `/app/capabilities` | Session (`get_current_user`; no user id in the path) | `{ "v": 1, "features": { <flag>: bool, ... }, "links": { "explore": string \| null }, "terms_current": bool }`, `Cache-Control: no-store`. `features` has one boolean per flag the server exposes, evaluated for the calling user (canary lists applied); `links.explore` is non-null only when `explorer_browse` is on; `terms_current` is true when the user's accepted Terms version equals the current one. No ids, canary lists or state names are returned. `401` without a session. Clients treat any non-200, network error or malformed body as "all features off, `terms_current` true". |
| PUT | `/admin/flags/{name}` | Admin (`require_admin`) | Body `{ "state": "off" \| "canary" \| "on", "canary_user_ids": [uuid, ...] \| omitted }`. Omitting the list keeps the stored one. `404` unknown flag; `422` invalid state, a canary list containing anything that is not an existing user id, or `canary` on `explorer_browse` (off/on only). `401`/`403` for non-admins. Emits one INFO audit line `FLAG_CHANGE name=<n> state=<s> actor=<user_id> canary_count=<k>`. The flag cache is 10 s per process; this route invalidates it immediately. |

Without a deploy the owner can also run `docker exec fellowscript-api python -m backend.admin_flags list` or `... set <name> <off|canary|on> [--canary id,id]` (takes effect within 10 s).

Routes that create new user-generated content for later features answer `403 { "detail": { "code": "terms_reaccept_required" } }` when the user has not accepted the current Terms (`backend/auth/terms.py`).

**Paging convention (shared cursor codec, `backend/interactions/paging.py`).** Keyset lists take `limit`, `cursor_timestamp` (ISO 8601; normalised to UTC `Z` with microseconds), optional `cursor_seq` (integer >= 0) and `cursor_id`; timestamp and id come together or neither; any malformed value answers `422 { "detail": { "code": "invalid_cursor" } }` before any query. Responses are `{ "<items>": [...], "page": { "limit", "has_more", "next_cursor_timestamp", "next_cursor_seq", "next_cursor_id" } }` with the `next_cursor_*` fields null unless `has_more`.

---

## Explorer listings: owner routes (task 20261001-explorer-listings, backend A)

<!-- explorer-listings -->
Ships inert: every route below answers a uniform `404 { "detail": { "code": "not_found" } }` while the `explorer_publish` flag is off for the caller (and nothing user-visible changes). Authenticated routes use `require_match("user_id")`; writes also answer `403 terms_reaccept_required` for a stale Terms version. Listing text is public once published, so it is moderated: every listing goes to `pending_review` and an admin approves it (config `require_approval`), text fields pass the content filter and a youth-term list (listings are for adults 18 and over), and the owner attests to being an adult and consents to publication. A listing is public only while its group's creator exists, is still a member and is not suspended. Reports and admin routes are added in a later step.

| Method | Route | Description |
|---|---|---|
| GET | `/explorer/config` | PUBLIC probe, always `200 { "browse": bool }` (false when `explorer_browse` is off or the flag read fails), `Cache-Control: public, max-age=30`. Never 404. Rate limited per IP plus a global backstop. |
| GET | `/explorer/{user_id}/options` | Vocabularies (denominations, goals, practices, hobbies, age ranges, life stages, languages, gender makeup, meeting formats, frequencies), field limits, `block_types`, country codes, `consent_version`, `support_email`. From `api/config/explorer.json`. |
| GET | `/explorer/{user_id}/groups` | Groups the caller created: `{ "groups": [{ "group_id", "title", "listing": { "public_id", "status", "accepting_requests", "reject_reason_code", "hidden_reason_code" } \| null }], "listing_cap", "listings_used" }`. |
| GET | `/explorer/{user_id}/groups/{group_id}/listing` | The caller's own listing (all fields, `status`, reason codes, consent info). `404` unless the caller created the group, is still a member and is not suspended (same 404 for any other group). |
| PUT | `/explorer/{user_id}/groups/{group_id}/listing` | First call creates the draft (title prefilled from the group title when omitted; cap of 3 listings per owner, `409 listing_cap_reached`), later calls update. Every field optional: omitted = unchanged, `null` = cleared. Fields: `title`, `summary`, `description_blocks` (typed blocks; `text` blocks only for now, restricted Markdown), `denominations`, `goals`, `practices`, `hobbies`, `age_ranges`, `life_stages`, `languages` (slugs from the vocabulary), `free_tags`, `gender_makeup`, `meeting_format`, `frequency`, `country` (ISO 3166-1 alpha-2), `region`, `city`, `church_name`, `accepting_requests`. `422` codes: `invalid_vocab`, `too_many_values`, `too_long`, `invalid_text`, `html_not_allowed`, `links_not_allowed`, `invalid_link`, `link_blocked`, `media_not_supported`, `invalid_block`, `youth_not_supported`, `content_rejected` (with `field`). A change to title, summary, description, church name or free tags sends a published listing back to `pending_review`; filter-only edits do not. Never publishes by itself. |
| POST | `/explorer/{user_id}/groups/{group_id}/listing/submit` | Body `{ "consent": true, "adult_attested": true, "accepting_requests": bool? }` (`422 consent_required` / `adult_attestation_required` / `title_required`). Moves draft, rejected or unpublished to `pending_review` (an unpublished listing whose approved text is unchanged goes straight back to `published`). `accepting_requests` omitted leaves the stored value, which is closed for a new listing. `409 hidden_by_admin` when hidden. |
| POST | `/explorer/{user_id}/groups/{group_id}/listing/unpublish` | `published` or `pending_review` to `unpublished`, immediately. |
| DELETE | `/explorer/{user_id}/groups/{group_id}/listing` | Hard delete (`204`). |

### Explorer public browse API (backend B, signed out)

No session. Answers a uniform `404 { "detail": { "code": "not_found" } }` while `explorer_browse` is off. Per-IP rate limit plus a key-less global backstop; when the dedicated public thread pool is saturated or a query exceeds `public_query_timeout_ms` the answer is `429 { "detail": { "code": "busy" } }` with `Retry-After` (never 5xx). Successful responses carry `Cache-Control: public, max-age=60`. The only identifier is the 10-character `public_id`; responses never contain group ids, user ids, usernames, member lists, emails or invite state. URL shapes are frozen for join-requests and iOS.

| Method | Path | Notes |
|---|---|---|
| GET | `/explorer/filters` | Signed-out filter vocabulary: `{ "vocab": { denominations, goals, practices, hobbies, age_ranges, life_stages, languages, gender_makeup, meeting_formats, frequencies: [{slug,label}] }, "countries": [ISO codes], "size_buckets": [label], "limits": {...}, "support_email" }`. |
| GET | `/explorer/listings` | `{ "listings": [card], "page": { limit, has_more, next_cursor_timestamp, next_cursor_seq: null, next_cursor_id } }`, newest first on `(published_at, public_id)`; `next_cursor_id` is a `public_id`. Query: `q` (text filter, max 80 chars, no relevance sort), facet filters `denominations goals practices hobbies age_ranges life_stages languages` (repeat or comma separate; any value within a facet, all facets must match; max 5 values, max 10 filters), `gender_makeup meeting_format frequency` (one slug), `country` (ISO), `region`/`city` (prefix), `include_full` (default false hides full groups), `limit` (default 12, max 24), `cursor_timestamp` + `cursor_id`. `422 invalid_filter` (with `field`) or `invalid_cursor` before any SQL. No totals. |
| GET | `/explorer/listings/{public_id}` | One listing: the card fields plus `description_blocks` and `requestable`. Unknown, unpublished or hidden: the same 404. |

A card holds `public_id, title, summary`, the facet arrays, `country, region, city, church_name, size_bucket, seats ("open" or "full"), published_at`.

Statuses: `draft`, `pending_review`, `published`, `unpublished`, `hidden`, `rejected`. Deleting the group, the owner leaving, or the owner's account being deleted removes or hides the listing.

---

## Message threads and message delete (task 20261001-message-threads)

<!-- THR (20261001-message-threads) -->
Gated by flags `threads` and `message_delete` (off by default; clients read them from `GET /app/capabilities`). While a flag is off for the caller every route below answers the same `404 { "detail": { "code": "not_found" } }`, as do an unknown id, a non-member, a thread or message of another group and any other denial. All paths need the session user in `{user_id}`.

| Method | Route | Description |
|---|---|---|
| DELETE | `/groups/{user_id}/{group_id}/messages/{message_id}` | Soft-delete your own group message (`message_delete`). Returns `{ "id", "undo_seconds" }`. Not gated by terms. |
| POST | `/groups/{user_id}/{group_id}/messages/{message_id}/restore` | Undo your own delete within `undo_seconds` (10). Returns `{ "id" }`. |
| POST | `/groups/{user_id}/{group_id}/threads` | Start the thread on a message, or open the one that exists. Body `{ "message_id", "title"? }` (blank title is auto-generated, max 80 characters, content filtered: `422`). `201` when created, `200` when it already existed. Returns `{ id, group_id, title, root_preview, root_message_id, root_deleted, reply_count, last_activity_at, created_by (username), created }`. `403 { "code": "terms_reaccept_required" }` when Terms are stale, `409 { "code": "thread_limit" }` at the per-group cap. |
| GET | `/groups/{user_id}/{group_id}/threads?limit=&cursor_timestamp=&cursor_id=` | Threads, most recently active first (default 20, max 50). `{ "threads": [{ id, title, root_preview (null when the root is deleted), root_deleted, reply_count, last_activity_at, created_by }], "page": {...} }`. Keyset on `(last_activity_at, id)`: `next_cursor_seq` is always null and clients omit `cursor_seq` (sending it is `422`). Threads by creators in a block relationship with the caller are excluded. |
| GET | `/groups/{user_id}/{group_id}/threads/{thread_id}/messages?limit=&cursor_timestamp=&cursor_seq=&cursor_id=` | One page of a thread's messages: the same `{ messages, page }` envelope, ordering, cursor rules and row shape as the main chat page (`{id, from_user, mine, text, timestamp, attachment_kind, attachment_meta, attachment_url}`) plus `thread_id` on each row. Only messages by the caller and current, unblocked members. |
| PUT | `/groups/{user_id}/{group_id}/threads/{thread_id}` | Rename (creator only). Body `{ "title" }`. Returns `{ "id", "title" }`. |

Sending is a WebSocket frame on the existing socket: `{ "type": "thread_message", "thread_id", "text", "client_ref"?, "attachment_kind"?, "attachment_key"?, "attachment_meta"? }`. The server derives the group and recipients from `thread_id` and ignores any `group_id`, `to_users` or `from_user` in the frame. The sender gets `{ "type": "ack", "client_ref", "id", "group_id", "thread_id", "timestamp" }`; members get `{ "type": "thread_message", "thread_id", "group_id", "id", "sender", "body", "created_at", "seq", "attachment_kind", "attachment_meta", "attachment_url" }` (no `from_user`, no `text`). Errors arrive as `{ "type": "error", "reason": ... }` with `not_allowed`, `rate_limited`, `terms_reaccept_required`, `message_rejected`, `send_failed` or `message_not_saved`. Other new frames, sent to online members: `{ "type": "message_deleted", id, group_id, deleted_at }` and `{ "type": "message_restored", id, group_id, sender, body, created_at, seq, attachment_* }`. Push for a thread message goes only to followers and carries `{ "action": "thread_message", "group_id", "thread_id" }`.

Reports: `POST /reports/` with `content_type: "thread_message"` takes the thread message's `id`; an unknown id is `404` and stores nothing.
<!-- /THR -->

## Join requests (task 20261001-explorer-join-requests)

<!-- JRQ (20261001-explorer-join-requests) -->
Gated by flag `join_requests` (off by default; clients read it from `GET /app/capabilities` as `features.join_requests`). While the flag is off for the caller every route below answers the same `404 { "detail": { "code": "not_found" } }`, as do an unknown id, a listing that cannot be requested and any caller who is not the group's owner. All paths need the session user in `{user_id}`. Every wait on a row lock is bounded; on timeout the route answers `409 { "code": "busy" }`.

Requester routes:

| Method | Route | Description |
|---|---|---|
| POST | `/join-requests/{user_id}/listings/{public_id}/request` | Ask to join a published listing (public id only, never a group id). Body `{ "note"? }` (plain text, 280 characters, content filtered: `422 invalid_note` or `422 note_rejected`). `201 { "status": "pending", "id", "created_at" }` when created; `200` for an idempotent repeat or `{ "status": "already_member" }` (given only to a member). Needs `explorer_browse` on, an accepting listing whose owner is also inside the flag, and current Terms (`403 { "code": "terms_reaccept_required" }`). `403 { "code": "cannot_request" }` is one generic answer for a block, cooldown after a denial, an owner "do not ask again", a pending or daily cap, or a suspended account. Anything else that cannot be requested is `404`. |
| GET | `/join-requests/{user_id}/requests?public_id=` | Your own requests, newest first: `{ "requests": [{ id, status, created_at, public_id, title, group_id? }], "already_member"? }`. `status` is `pending`, `approved`, `not_approved` (denied and expired look the same) or `withdrawn`. `group_id` appears only for an approved request while you are still a member. `already_member` appears when `public_id` is given. |
| POST | `/join-requests/{user_id}/requests/{request_id}/withdraw` | Withdraw your own pending request. `{ "status": "withdrawn" }`; repeating is `200`; a decided request is `409 not_pending`. |

Owner routes (group owner only: creator, still a member, not suspended; everyone else gets `404`):

| Method | Route | Description |
|---|---|---|
| GET | `/join-requests/{user_id}/groups/{group_id}/requests` | `{ "accepting_requests": bool \| null, "pending_count", "requests": [{ id, applicant_user_id, username, profile_photo_url, note, created_at }] }`, newest first. `accepting_requests` is null when the group has no listing. `applicant_user_id` is for Report and Block only. |
| POST | `/join-requests/{user_id}/groups/{group_id}/requests/{request_id}/approve` | Adds the applicant to the group in one transaction (member cap and blocks re-checked). `{ "status": "approved", "already_member" }`; repeating is `200`. `409 group_full` leaves the request pending; `409 no_longer_available` (blocked or suspended applicant; the request is expired); `409 not_pending`. |
| POST | `/join-requests/{user_id}/groups/{group_id}/requests/{request_id}/deny` | Body `{ "block_reapply"?: bool }`. `{ "status": "denied", "undo_seconds" }`. The applicant is not notified and cannot ask again for the cooldown (14 days), or ever with `block_reapply`. |
| POST | `/join-requests/{user_id}/groups/{group_id}/requests/{request_id}/undo-deny` | Restore your own denial inside `undo_seconds` (10, server clock): `{ "status": "pending" }`, else `409 not_undoable`. |
| PUT | `/join-requests/{user_id}/groups/{group_id}/accepting` | Body `{ "accepting": true\|false }` (strict booleans). Switches intake of NEW requests for the group's listing; pending requests are untouched. `{ "accepting" }`. `404` when the group has no listing. Works while `explorer_browse` is off. |

Push (flag `join_request_push`, evaluated for the owner): the owner gets at most one `join_request` push per group per 30 minutes with generic text, and the applicant gets one when approved; data `{ "action": "join_request", "group_id" }`. Notes, usernames and ids never appear in push text.
<!-- /JRQ -->
