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

---

### `subscriptions`

| Column | Type | Notes |
|---|---|---|
| `_id` | UUID PK | |
| `user_id` | UUID FK → `users` ON DELETE CASCADE | |
| `plan_type` | TEXT | `'free'`, `'individual'`, `'group'` |
| `provider` | TEXT | `'none'`, `'stripe'`, `'apple'` |
| `status` | TEXT | `'active'`, `'trialing'`, `'canceled'` |
| `price_cents` | INTEGER | 0 for free plan |
| `max_members` | INTEGER | 1 for individual, N for group |
| `current_period_end` | TIMESTAMPTZ | NULL for free plan (never expires) |
| `stripe_subscription_id` | TEXT | |
| `apple_original_transaction_id` | TEXT | |
| `card_brand`, `card_last4` | TEXT | Display-only; no raw card data stored |

Every new user receives a `plan_type='free'` row on signup. Free plans are excluded from `is_subscribed()` checks so free-tier limits still apply.

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

### `notifications`

| Column | Type |
|---|---|
| `_id` | UUID PK |
| `user_id` | UUID FK → `users` ON DELETE CASCADE |
| `type` | TEXT |
| `message` | TEXT |
| `read` | BOOLEAN |

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
| `agent_heartbeats` | `_id`, `user_id FK→users ON DELETE CASCADE`, `last_fired TIMESTAMPTZ` |

---

## Account Deletion

`DELETE /user/{user_id}` manually handles tables whose FK to `users` lacks `ON DELETE CASCADE`:

1. `DELETE FROM notes WHERE user_id = ?` — removes owned notes (cascades to `note_verses`)
2. `UPDATE messages SET from_user = NULL WHERE from_user = ?` — preserves group chat history
3. `UPDATE devotions SET creator_id = NULL WHERE creator_id = ?` — preserves devotion plans
4. `DELETE FROM users WHERE _id = ?` — remaining children with CASCADE delete automatically

---

## Migrations

New columns are added via idempotent `ALTER TABLE … ADD COLUMN IF NOT EXISTS` statements at the top of `create_tables()` in `db.py`. These run on every server startup and are safe to re-run against a live database.
