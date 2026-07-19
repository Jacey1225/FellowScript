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
| PUT | `/user/{user_id}` | Update `username`, `email`, or `plain_pass` |
| DELETE | `/user/{user_id}` | Permanently delete account and all owned data |

---

## Notes

| Method | Route | Description |
|---|---|---|
| GET | `/notes/{user_id}` | All personal notes for the user (excludes replies and group notes) |
| POST | `/notes/{user_id}` | Create a note. Body: `{ title, text, public, group_id, verses: [[book, ch, v], …] }` |
| PUT | `/notes/{user_id}?note_id=` | Update a note (owner only). Replaces verse list. Bumps `timestamp`. |
| DELETE | `/notes/{user_id}?note_id=` | Delete a note (owner only) |
| POST | `/notes/reply/{note_id}` | Post a reply to a note |

Note responses include `created_at` (immutable creation timestamp) and `timestamp` (last-edited).

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
| GET | `/groups/{group_id}/notes` | All public notes in the group |
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
| POST | `/subscriptions/stripe/checkout` | Create a Stripe Checkout session (web) |
| POST | `/subscriptions/stripe/webhook` | Stripe webhook handler |
| POST | `/subscriptions/apple/validate` | Validate Apple IAP receipt (iOS) |
| POST | `/subscriptions/apple/webhook` | Apple App Store Server Notification handler |

---

## Notifications

| Method | Route | Description |
|---|---|---|
| GET | `/notifications/{user_id}` | List notifications |
| PUT | `/notifications/{user_id}/{notif_id}` | Mark as read |

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
