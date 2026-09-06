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
| POST | `/subscriptions/checkout` | Create a Stripe Checkout session (web). Body: `{user_id, member_count}` (1-8) — price is looked up server-side by count |
| POST | `/subscriptions/stripe/webhook` | Stripe webhook handler |
| POST | `/subscriptions/apple/sync` | Record/refresh a plan from a StoreKit 2 signed transaction (iOS). One of 8 fixed-price products maps to a member count server-side |
| POST | `/subscriptions/apple/notifications` | Apple App Store Server Notification handler |
| PUT | `/subscriptions/{subscription_id}` | Update a plan (host only). Body may include `member_count` to change plan size — re-prices from the same table |

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

---

## Agent (AI Check-ins)

| Method | Route | Description |
|---|---|---|
| GET | `/agent/{user_id}` | Get agent configuration |
| PUT | `/agent/{user_id}` | Update agent config (frequency, tone, etc.) |
| POST | `/agent/{user_id}/heartbeat` | Trigger an AI check-in event (enforces free-tier cap) |

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
