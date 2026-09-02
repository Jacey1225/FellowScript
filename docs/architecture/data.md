# Data

All user-generated data lives in **PostgreSQL**. Bible text is served from a pre-parsed JSON file bundled with the backend. There are no PDF sources parsed at runtime.

---

## Bible Text

The full Bible (KJV/ESV) is stored as a static JSON file loaded into memory on startup. The `api/` backend reads from this file to serve book/chapter/verse lookups. It is never written to at runtime.

---

## Postgres Schema

### `users`

| Column | Type | Notes |
|---|---|---|
| `_id` | UUID PK | User identifier |
| `username` | TEXT | Unique display name |
| `email` | TEXT | |
| `hash_pass` | TEXT | bcrypt hash; empty string for OAuth-only accounts |
| `apple_sub` | TEXT | Stable Apple `sub` claim for Sign in with Apple |
| `google_sub` | TEXT | Stable Google `sub` claim |
| `subscription_id` | UUID FK → `subscriptions` | Current plan; always set (free plan row created on signup) |
| `timezone` | TEXT | IANA name (e.g. `America/Los_Angeles`), default `'UTC'`. User-editable in Account settings; drives the nightly backup schedule below |
| `mfa_enabled` | BOOLEAN | Default `false`. Web-only email-code 2FA toggle — when true, `/login` pauses for a code instead of issuing a session immediately |
| `terms_accepted_at` | TIMESTAMPTZ | Server-stamped on signup/first login via a given provider; never client-supplied |
| `terms_version` | TEXT | Which `CURRENT_TERMS_VERSION` (`schemas/users.py`) was accepted; a mismatch on login triggers a `terms_reaccept_required` soft gate |
| `suspended_at` | TIMESTAMPTZ | Guideline 1.2 moderation eject — set only by `backend/moderation/admin_actions.py`, never by the normal profile-update path. A suspended account 403s on every auth route |
| `needs_profile_completion` | BOOLEAN | Default `false`. Set `true` when a first-ever Apple sign-in is missing `full_name`/`email` — Apple only ever supplies these once per Apple ID + app, so a missed grant can't be recovered later. Cleared the next time the client sets a real `username`/`email` via `PUT /user/{id}` |
| `is_admin` | BOOLEAN | Default `false`. Staff/admin flag checked by `require_admin` (`backend/auth/dependencies.py`) to gate admin-only surfaces, e.g. `/monitoring/detections*`. Seeded (idempotently, by live email lookup — never a hardcoded id) for exactly one account in `db.py::create_tables`; not editable via any user-facing endpoint |

---

### `subscriptions`

| Column | Type | Notes |
|---|---|---|
| `_id` | UUID PK | |
| `user_id` | UUID FK → `users` ON DELETE CASCADE | |
| `plan_type` | TEXT | `'free'`, `'group'` |
| `provider` | TEXT | `'none'`, `'stripe'`, `'apple'` |
| `status` | TEXT | `'active'`, `'trialing'`, `'canceled'` |
| `price_cents` | INTEGER | 0 for free plan; derived from `max_members` via `GROUP_PRICE_CENTS` for a group plan |
| `max_members` | INTEGER | 1 for free; 1-8 for group — the host-selected member count, chosen at signup or changed later via a plan update |
| `current_period_end` | TIMESTAMPTZ | NULL for free plan (never expires) |
| `stripe_subscription_id` | TEXT | |
| `apple_original_transaction_id` | TEXT | |
| `card_brand`, `card_last4` | TEXT | Display-only; no raw card data stored |

Every new user receives a `plan_type='free'` row on signup. Free plans are excluded from `is_subscribed()` checks so free-tier limits still apply.

There is a single paid tier (`'group'`) covering 1-8 members at a fixed per-count price (`schemas/subscription.py`'s `GROUP_PRICE_CENTS`) — the old separate `'individual'` plan_type was folded into this as the 1-member case (identical $10 price). Apple StoreKit needs one fixed-price product per member count (`com.fellowscript.access.one` … `com.fellowscript.access.eight`) since IAP can't compute an arbitrary price; Stripe Checkout computes the price inline for any count via `price_data`, no pre-created Products needed.

---

### `notes`

| Column | Type | Notes |
|---|---|---|
| `_id` | UUID PK | |
| `user_id` | UUID FK → `users` | Deleted with user |
| `title` | VARCHAR(255) | |
| `text` | TEXT | HTML (rich text) |
| `public` | BOOLEAN | Visible to study group when true |
| `group_id` | UUID FK → `groups` ON DELETE SET NULL | |
| `is_reply` | BOOLEAN | True for note replies |
| `parent_note_id` | UUID FK → `notes` ON DELETE CASCADE | |
| `timestamp` | TIMESTAMPTZ | Bumped on every edit (last-modified) |
| `created_at` | TIMESTAMPTZ | Set at INSERT only; never updated |

Notes are always sorted by `created_at DESC` on the frontend.

---

### `note_verses`

Verse references linked to a note (many-to-one).

| Column | Type |
|---|---|
| `note_id` | UUID FK → `notes` ON DELETE CASCADE |
| `position` | INTEGER |
| `book` | TEXT |
| `chapter` | TEXT |
| `verse` | TEXT |

---

### `highlights`

| Column | Type | Notes |
|---|---|---|
| `user_id` | UUID FK → `users` | Composite PK with `key` |
| `key` | TEXT | `"{book}-{chapter}-{verse}"` |
| `color` | TEXT | Hex color string |

---

### `bookmarks`

| Column | Type | Notes |
|---|---|---|
| `user_id` | UUID FK → `users` | Composite PK with `key` |
| `key` | TEXT | `"{book}-{chapter}"` |
| `label` | TEXT | Optional display label |

---

### `groups`

| Column | Type |
|---|---|
| `_id` | UUID PK |
| `title` | TEXT |
| `members` | UUID[] |
| `highlights` | JSONB |

---

### `messages`

| Column | Type | Notes |
|---|---|---|
| `_id` | UUID PK DEFAULT gen_random_uuid() | |
| `from_user` | UUID FK → `users` (SET NULL on delete) | Nulled when author is deleted |
| `group_id` | UUID FK → `groups` | |
| `content` | TEXT | |
| `is_dm` | BOOLEAN | |
| `timestamp` | TIMESTAMPTZ | |

---

### `notifications` (removed)

The `notifications` table backed the former user-authored ("agentic")
notification subsystem and was dropped outright (2026-08-26) once that
subsystem was fully removed — nothing reads or writes it anymore. A
replacement activity-tracking table/mechanism for the new fixed-notification
system is being added as a follow-up step in the same task; this section will
be updated to describe it once it lands.

---

### `devotions`

| Column | Type | Notes |
|---|---|---|
| `_id` | UUID PK | |
| `creator_id` | UUID FK → `users` (SET NULL on delete) | Nulled when creator is deleted |
| `title` | TEXT | |
| `participants` | UUID[] | |

---

### `agents` / `agent_heartbeats`

| Table | Key columns |
|---|---|
| `agents` | `_id`, `user_id FK→users ON DELETE CASCADE`, `config JSONB` |
| `agent_heartbeats` | `_id`, `user_id FK→users ON DELETE CASCADE`, `last_fired TIMESTAMPTZ`, `group_id FK→groups ON DELETE SET NULL` (nullable — 2026-09-02) |
| `agentic_context` | `_id`, `heartbeat_id FK→agent_heartbeats ON DELETE CASCADE`, `user_id FK→users ON DELETE CASCADE`, `note_id FK→notes ON DELETE CASCADE` (nullable), `context TEXT[]` |

`agentic_context` gives each heartbeat continuity with its own past output: every time `AgentManager.commit_hb_response()` generates a note, it saves a summary here keyed by `heartbeat_id`, and the next fire for that same heartbeat includes prior summaries in its prompt as "Previous context from past responses." Context is scoped per-heartbeat — heartbeats don't share history with each other, and manually-written notes never feed into this loop. `note_id` links each summary to the note it was distilled from; deleting that note (from any path — the notes route, account deletion, or the moderation CLI) cascades away its context row too, so a deleted note stops appearing in future prompts.

`agent_heartbeats.group_id` (2026-09-02) optionally ties a scheduled event to one of the user's groups, set via the iOS/web event-setup UI's gold group-picker button. `add_heartbeat`/`update_heartbeat` validate a submitted `group_id` against the caller's own `GroupsManager.is_member()` before persisting it (mirroring `notes.py`'s create/update IDOR guard), and `ON DELETE SET NULL` lets a heartbeat survive as ungrouped if its group is later deleted. When a grouped heartbeat fires, `commit_hb_response` reads `group_id` off the heartbeat row itself (not the LLM's response) and threads it into the note it generates, so the note is visible to other group members via the existing group-notes read path; an ungrouped heartbeat's note is unaffected.

---

### `password_reset_tokens` / `mfa_codes`

| Table | Key columns |
|---|---|
| `password_reset_tokens` | `_id`, `user_id FK→users ON DELETE CASCADE`, `token_hash`, `expires_at` (30 min), `used` |
| `mfa_codes` | `_id`, `user_id FK→users ON DELETE CASCADE`, `code_hash`, `expires_at` (10 min), `used` |

Same hash-at-rest pattern as `sessions`: only a sha256 hash of the emailed token/code is ever stored, so a database leak alone can't be replayed. Both are single-use (`used` flips to `true` on a successful verify) and are never purged proactively — expired/used rows are inert and harmless to leave in place at this scale.

---

### `content_reports` / `blocked_users` (Guideline 1.2)

| Table | Key columns |
|---|---|
| `content_reports` | `_id`, `reporter_id FK→users`, `reported_user_id FK→users`, `content_type` (`note`/`message`/`devotion_prompt`/`group_title`/`user`), `content_id` (nullable — polymorphic, no single FK target), `content_snippet` (frozen at report time), `reason`, `detail`, `status` (`open`/`actioned`/`dismissed`), `created_at`, `resolved_at` |
| `blocked_users` | `blocker_id FK→users`, `blocked_id FK→users`, `created_at` — composite PK `(blocker_id, blocked_id)` |

`content_snippet` is denormalized deliberately: if the operator doesn't check the report email until hours later and the author has since edited or deleted the content, the report still shows what was actually reported. Blocking a user auto-inserts a `content_reports` row (`content_type='user'`, `reason='blocked'`) so there's one unified queue rather than a separate notification path. See `backend/moderation/` above for the filter, reporting, blocking, and admin-resolution logic; `backend/moderation/admin_actions.py`'s `resolve` command is how reports get actioned within the 24-hour commitment in the Terms of Service.

---

### `log_group_cursors` / `error_detections` / `error_detection_reports`

| Table | Key columns |
|---|---|
| `log_group_cursors` | `log_group_name TEXT PK`, `last_seen_time TIMESTAMPTZ`, `updated_at` |
| `error_detections` | `_id UUID PK`, `log_group_name`, `log_stream_name`, `event_timestamp`, `message`, `matched_signal`, `context JSONB`, `detected_at`, `status TEXT DEFAULT 'new'` |
| `error_detection_reports` | `_id UUID PK`, `detection_id UUID UNIQUE REFERENCES error_detections(_id) ON DELETE CASCADE`, `root_cause`, `remediation_narrative`, `model`, `generated_at TIMESTAMPTZ` |

Populated by the watchdog job (`backend/monitoring/watchdog.py`, see [Backend → Background Scheduler](backend.md#background-scheduler)). `log_group_cursors` is a per-log-group watermark so consecutive polls never re-process or skip events. `error_detections.context` holds the assembled surrounding-log-lines + log-analyzer output for a hit; `status` starts at `'new'` and moves to `'diagnosed'` once the debugging agent (`backend/monitoring/debug_agent.py`) has produced a report for it.

`error_detection_reports` holds the debugging agent's diagnostic write-up (root cause + remediation narrative) for a detection — one row per detection (`detection_id` is `UNIQUE`; a rerun upserts in place rather than accumulating history). Populated automatically right after a detection persists (one OpenRouter call per detected error, not per poll cycle) and on-demand via `POST /monitoring/detections/{id}/report` (see [API → Monitoring](../api/overview.md#monitoring-error-detections)). Cascades away with its parent `error_detections` row.

Indexed on `(detected_at DESC)` and `(log_group_name, detected_at DESC)` for the list feed's default ordering and log-group filter.

---

## Account Deletion

`DELETE /user/{user_id}` manually handles tables whose FK to `users` lacks `ON DELETE CASCADE`:

1. `DELETE FROM notes WHERE user_id = ?` — removes owned notes (cascades to `note_verses`)
2. `UPDATE messages SET from_user = NULL WHERE from_user = ?` — preserves group chat history
3. `UPDATE devotions SET creator_id = NULL WHERE creator_id = ?` — preserves devotion plans
4. `DELETE FROM users WHERE _id = ?` — remaining children with CASCADE delete automatically

The `fellowscript_backup` database (see [Nightly Backup Database](#nightly-backup-database) above) has no FK relationship to the primary DB, so it isn't touched by any of the above — `delete_user` purges the user's row and mirrored notes/verses/highlights/bookmarks there explicitly as a separate step, so account deletion honors the Privacy Policy's promise that data is removed from all systems, not just the primary DB.

---

## Nightly Backup Database

A second, separate Postgres database (`fellowscript_backup`, same instance, owned by the `fellowscript` role) mirrors each user's recent data. A scheduler job checks every minute for any user whose `timezone` puts their local clock at 03:00, and only that user's data is copied at that moment — so the backup runs at each user's own local 3am, not a single fixed server time.

Per user, per run:

- `users` — profile row (username, email, timezone), always refreshed
- `notes` — rows with `timestamp` in the last 24h (covers new *and* edited notes)
- `note_verses` — verses belonging to whichever notes were just copied
- `highlights`, `bookmarks` — full current set each run (these tables have no modification timestamp to filter on, and are small enough that a full re-sync is cheap)

The backup tables are intentionally FK-light (no foreign keys to each other) so a backup write can never fail due to referential integrity — the goal is a resilient destination, not a fully normalized mirror. Not yet covered: agents, agent heartbeats, subscriptions, messages, and groups — a possible follow-up. (The `notifications` table this list previously included was dropped outright, 2026-08-26 — see above.)

Implementation: `backend/backup/manager.py` (`BackupManager`), scheduled from `backend/interactions/scheduler.py`.

---

## Migrations

New columns are added via idempotent `ALTER TABLE … ADD COLUMN IF NOT EXISTS` statements at the top of `create_tables()` in `db.py`. These run on every server startup and are safe to re-run against a live database.
