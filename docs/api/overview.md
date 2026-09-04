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
| GET | `/friends/{user_id}/activity` | Friend-activity read surface for the dashboard's Friend Activity hero card: each friend's most recent public note preview + last-active timestamp (block-respecting both directions), plus a bounded "check in" nudge candidate pool (up to 5 friends gone longest without a direct message). Highlights are not previewed (no privacy flag exists for them yet). |

### `GET /friends/{user_id}/activity`

**Response:** `200` with
```json
{
  "friends_active": [
    {"friend_id": "uuid", "username": "str", "last_active_at": "iso8601 | null",
     "note_preview": {"note_id": "uuid", "title": "str", "text": "str", "timestamp": "iso8601"} | null}
  ],
  "check_in_candidates": [
    {"friend_id": "uuid", "username": "str", "days_since_contact": "int | null"}
  ]
}
```
`friends_active` is ordered most-recently-active first. `check_in_candidates` is ordered longest-since-contact first, capped at 5 entries (or the friend count, whichever is smaller), and is an empty list only when the user has no friends — the client picks among these candidates rather than the whole friend list, to keep the nudge targeted at genuinely-neglected friends.

---

## Messaging (WebSocket)

Connect: `ws://<host>:8000/ws/{user_id}`

Messages are JSON payloads with a `type` field:

| Type | Direction | Description |
|---|---|---|
| `group_message` | send / receive | Group chat message |
| `dm` | send / receive | Direct message to another user |
| `activity` | receive | Member activity broadcast (reading, highlighting, noting) |

REST history: `GET /messages/{group_id}` returns past messages for a group.

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

**Replacement pending**: a backend activity-tracked/fixed-notification system
(reminders derived from real note/highlight activity, plus a cross-user
"friend went active" push) is being built as a follow-up step in the same
task and will be documented here once it lands.

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
