# Backend

The backend is a **FastAPI + Postgres** application in `api/`. All code follows a strict three-layer flow:

```
routes/ (HTTP)  ──▶  backend/interactions/ (logic + DB)  ──▶  Postgres
   ▲                          │
   └── schemas/ (Pydantic) ───┘
```

---

## Entry Point — `main.py`

Registers all routers, configures CORS, and handles the three authentication routes directly (password signup/login, Google OAuth, Apple Sign In). Also starts the background scheduler on startup via `lifespan`.

Auth routes in `main.py`:

| Route | Method | Description |
|---|---|---|
| `/signup` | POST | Register with username + password; creates free-plan subscription |
| `/login` | POST | Authenticate with username + password |
| `/auth/google` | POST | Validate Google ID token; find-or-create user |
| `/auth/apple` | POST | Verify Apple JWT (JWKS); find-or-create user |
| `/user/{user_id}` | GET / PUT / DELETE | Read, update, or permanently delete a user account |

---

## Layer 1 — `schemas/`

Pydantic models defining request/response shapes and internal records. One file per domain.

| File | Key models |
|---|---|
| `schemas/users.py` | `User`, `SignUp`, `Login`, `UpdateUser`, `Note` |
| `schemas/message.py` | `Message`, `Group` |
| `schemas/devotion.py` | `DevotionPlan`, `DevotionRequest` |
| `schemas/agent.py` | `AgentConfig`, `AgentEvent` |
| `schemas/notifications.py` | `Notification` |
| `schemas/subscription.py` | `Subscription`, `FREE_LIMITS`, `EXPIRY_GRACE_DAYS` |
| `schemas/filter.py` | `FilterParams` |

---

## Layer 2 — `backend/interactions/`

All business logic lives here in `*Manager` classes that subclass `DBManager`. Routes never touch SQL directly.

| Manager | File | Responsibility |
|---|---|---|
| `GroupsManager` | `groups.py` | Create/join/leave groups, add members |
| `FriendsManager` | `friends.py` | Friend requests, friend list, remove |
| `DevotionManager` | `devotion.py` | Devotion plans, participants, progress |
| `AgentManager` | `agent.py` | AI agent config, heartbeat events |
| `NotificationManager` | `notifications.py` | Create and read notifications |
| `FilterManager` | `filtering.py` | Note filtering by book, date, user, title |
| `SortingManager` | `sorting.py` | Note sorting by timestamp |

`DBManager` (in `db.py`) provides four auto-committing helpers: `insertion`, `lookup`, `update`, `delete`. Raw cursor (`self.cur.execute`) is used for JOINs, array ops, and aggregations.

---

## Layer 3 — `routes/`

Thin `APIRouter` handlers. Each handler: instantiates a manager, calls one method, maps `{"error": ...}` → `HTTPException`, closes the connection in `finally`.

| Router | Prefix | Description |
|---|---|---|
| `notes_router` | `/notes` | Notes CRUD, highlights, bookmarks, replies |
| `ws_router` | `/ws` | WebSocket group chat + DMs |
| `chime_router` | `/messages` | REST message history |
| `group_router` | `/groups` | Group management |
| `friend_router` | `/friends` | Friend management |
| `filter_router` | `/filter` | Note filtering |
| `sorting_router` | `/sort` | Note sorting |
| `devo_router` | `/devotions` | Devotion plans |
| `agent_router` | `/agent` | AI agent config + heartbeats |
| `notification_router` | `/notifications` | Notification read/list |
| `subscription_router` | `/subscriptions` | Subscription lookup, Stripe + Apple webhooks |
| `donation_router` | `/donation` | One-time donation flow |

---

## `backend/subscription/`

A sibling package to `interactions/` dedicated to billing and usage enforcement.

| File | Responsibility |
|---|---|
| `subscriptions.py` | `SubscriptionsManager` — create free plan, get subscription, reconcile expired |
| `limits.py` | `LimitsManager` — `is_subscribed()`, per-resource usage counts, `check()` |
| `stripe_service.py` | Stripe Checkout session creation and webhook handling |
| `apple_service.py` | Apple App Store receipt/notification validation |

Every new user (all three auth paths) gets a `plan_type='free'` subscription row created by `SubscriptionsManager.create_free_plan()`. Free-tier limits are enforced server-side via `check_limit()` before every create route.

---

## `backend/backup/`

A sibling package to `interactions/` for the nightly per-user data backup (see [Data → Nightly Backup Database](data.md) for the schema/scope).

| File | Responsibility |
|---|---|
| `manager.py` | `BackupManager` — holds two DB connections at once (`source`: primary `fellowscript` DB, `dest`: separate `fellowscript_backup` DB). `users_due_now()` finds users whose local time is currently 03:00; `backup_user()` copies that user's recent notes/verses and full highlights/bookmarks into the backup DB via upsert. |

Unlike other managers, `BackupManager` doesn't subclass `DBManager` directly — it composes two `DBManager` instances (constructed via `DBManager(dbname=...)`) since it reads from one database and writes to another.

---

## `db.py` — Schema and `DBManager`

`create_tables()` defines the full Postgres schema in FK-dependency order (Level 0 → Level 2). Additive `ALTER TABLE … ADD COLUMN IF NOT EXISTS` statements at the top of `create_tables()` handle live migrations without dropping data.

### Schema summary (Level 0 → 2)

**Level 0 (no FK)**
- `users` — `_id`, `username`, `email`, `hash_pass`, `apple_sub`, `google_sub`, `subscription_id`, `timezone`
- `groups` — `_id`, `title`, `members UUID[]`, `highlights JSONB`
- `subscriptions` — `_id`, `user_id`, `plan_type`, `provider`, `status`, `price_cents`, `current_period_end`, Stripe/Apple identifiers

**Level 1 (FK → Level 0)**
- `notes` — `_id`, `user_id`, `title`, `text`, `public`, `group_id`, `timestamp`, `created_at`
- `messages` — `_id`, `from_user`, `group_id`, `content`, `is_dm`, `timestamp`
- `highlights` — `(user_id, key)` composite PK, `color`
- `bookmarks` — `(user_id, key)` composite PK, `label`
- `notifications` — `_id`, `user_id`, `type`, `message`, `read`
- `agents` — `_id`, `user_id`, `config JSONB`
- `devotions` — `_id`, `creator_id`, `title`, `participants UUID[]`
- `friend_requests` — `from_user_id`, `to_user_id`
- `friend_list` — `user_id`, `friend_id`

**Level 2 (FK → Level 1)**
- `note_verses` — `note_id`, `position`, `book`, `chapter`, `verse`
- `agent_heartbeats` — `_id`, `user_id`, `last_fired`
- `message_recipients` — `message_id`, `recipient_id`

---

## Background Scheduler

`backend/interactions/scheduler.py` runs on startup (via `lifespan`), using APScheduler. Current jobs:

| Job | Cadence | Does |
|---|---|---|
| `_fire_due_notifications` | every minute | Pushes any notification whose scheduled time-of-day matches now |
| `_run_nightly_backups` | every minute | Copies any user whose *local* time is currently 03:00 into the backup database (see `backend/backup/`) |
| `_reconcile_trials` | every hour | Advances elapsed trials to active, and removes subscriptions whose paid period lapsed past the grace window |

Heartbeat (AI agent event) firing is **not** scheduled server-side — it's driven entirely client-side by iOS's `HeartbeatScheduler.checkAndFire`, which calls the same `commit_heartbeat` endpoint on app foreground.
