# FellowScript — Database Schema Tree

Tables ordered **outside-in**: create from Level 0 upward.
Each arrow (→) lists the tables a given table depends on.

Reviewed against `api/db.py::create_tables` (readability #10, compliance
sweep 20260830-fellowscript-full-sweep) — the previous version predated
several feature additions (subscriptions, agents/agent_heartbeats/
agent_messages, moderation/monitoring, sessions/MFA/password-reset) and
described a `group_members`/`devotion_participants`/`devotion_verses`/
`devotion_prompts`/`agent_conversations` shape that no longer exists:
group membership is a `groups.users TEXT[]` array column (no join table),
and a devotion's participants/verses/prompts are `TEXT[]` columns directly
on `devotions`, not child tables.

---

## Level 0 — No foreign keys (create first)

```
users
groups
log_group_cursors      # CloudWatch watchdog cursor, unscoped to any user
error_detections       # CloudWatch watchdog findings, unscoped to any user
```

---

## Level 1 — Depend only on Level 0

```
user_friends           → users, users
admin_role_audit       → users (actor_user_id, target_user_id; ON DELETE SET NULL, append-only grant/revoke trail)
friend_requests        → users, users
blocked_users          → users, users
highlights             → users
bookmarks              → users
notes *                → users, groups
messages               → users, groups
devotions †            → users (creator_id)
agents                 → users
subscriptions          → users
device_tokens          → users
user_activity          → users
sessions               → users
password_reset_tokens  → users
mfa_codes              → users
content_reports        → users, users (reporter_id, reported_user_id)
error_detection_reports → error_detections
```

> **\* notes** has a self-referencing FK (`parent_note_id → notes`) for replies.
> PostgreSQL resolves this automatically — no special handling needed.

> **† devotions.group_id** is plain `TEXT` (a group id *or* a DM room key
> `userA|userB`), not an FK to `groups` — a devotion session isn't always
> group-scoped. `participants`/`verses`/`prompts` are `TEXT[]` columns on
> this same row, not separate child tables.

> **users.subscription_id** is an FK to `subscriptions`, added via `ALTER
> TABLE` *after* `subscriptions` exists (to avoid a circular create-time FK)
> — the reverse direction of every other Level-1 relationship above, same
> idea as `notes`' self-reference.

---

## Level 2 — Depend on Level 1 (create after Level 1)

```
note_verses            → notes
message_recipients     → messages, users
agent_heartbeats       → agents, users
agent_messages         → agents, users, agent_chats (chat_id, nullable = legacy)
agent_chats            → agents, users (flag agent_chats; DDL module schema_ddl/agent_chats.py; summary TEXT + summary_through_ts TIMESTAMPTZ added for flag agent_chat_memory, server-side only)
subscription_request   → subscriptions, users
```

---

## Level 3 — Depend on Level 2

```
agentic_context         → agent_heartbeats, users, notes
```

> **agentic_context.note_id** is nullable (rows written before this column
> existed have no note to point at) and `ON DELETE CASCADE`s with the note —
> deleting a note (any path: the notes route, account deletion, or the
> Guideline 1.2 moderation CLI) also removes its trace from the agent's
> future "previous context" prompts.

---

## DDL modules (api/schema_ddl/, applied after everything above)

<!-- shared-foundation (20261002-shared-foundation) -->
`create_tables` ends by applying the modules named in `db.DDL_MODULES`, in order, in the same
transaction (one name per line; an unknown module raises and stops the boot; the runner sets
`lock_timeout` to 30 s first). Tables created there:

```
feature_flags           # module "flags": name PK, state off|canary|on, canary_user_ids UUID[], updated_at, updated_by (text, no FK); 8 rows seeded off
pending_s3_deletes      # module "outbox": key PK, enqueued_at, attempts, last_attempt_at (S3 keys awaiting deletion; no FK)
group_listings          # module "listings": _id PK (internal), public_id (10-char base62, UNIQUE), group_id UNIQUE FK groups ON DELETE CASCADE,
                        #   status draft|pending_review|published|unpublished|hidden|rejected, accepting_requests (default FALSE), title (80, own snapshot),
                        #   summary, description_blocks JSONB, description_text (app-maintained), facet arrays + country/region/city/church_name,
                        #   banner_key/photo_key/banner_alt (reserved, unused), search_tsv (generated, 'simple'), consent_version/consented_at/adult_attested,
                        #   approved_at, reviewed_by/at, reject_reason_code, hidden_at/reason, published_at, created_at, updated_at; fs_arr_text() IMMUTABLE helper
group_listing_media     # module "listings": created EMPTY (listing_id FK CASCADE, object_key UNIQUE, kind, size_bytes, width, height, alt_text, status)
# <!-- THR (20261001-message-threads) -->
threads                 # module "threads": _id PK DEFAULT gen_random_uuid(), group_id FK groups ON DELETE CASCADE, root_message_id FK messages ON DELETE SET NULL
                        #   (partial UNIQUE where not null: one thread per root), root_preview, root_author_id FK users SET NULL, title VARCHAR(80), created_by FK users SET NULL,
                        #   created_at, last_activity_at; INDEX (group_id, last_activity_at DESC, _id DESC)
thread_messages         # module "threads": _id PK, thread_id FK threads CASCADE, from_user FK users SET NULL, text, attachment_kind/key/meta, created_at,
                        #   seq (default nextval('messages_seq')), deleted_at, deleted_by FK users SET NULL; INDEX (thread_id, created_at DESC, seq DESC, _id DESC),
                        #   partial INDEX on deleted_by
thread_followers        # module "threads": PK (thread_id FK threads CASCADE, user_id FK users CASCADE); INDEX (user_id)
# <!-- /THR -->
# <!-- JRQ (20261001-explorer-join-requests) -->
group_join_requests     # module "join_requests": id UUID PK DEFAULT gen_random_uuid(), group_id FK groups ON DELETE CASCADE, user_id FK users ON DELETE CASCADE,
                        #   status pending|approved|denied|withdrawn|expired (CHECK), note, block_reapply, created_at, decided_at, decided_by FK users SET NULL, owner_notified_at;
                        #   partial UNIQUE (group_id, user_id) WHERE status = 'pending'; INDEX (group_id, status, created_at), (user_id, created_at),
                        #   (group_id, user_id, created_at DESC), (status, created_at), partial (decided_by); no FK to group_listings
# <!-- /JRQ -->
# <!-- HMS (20261002-home-announcement-headline) -->
home_messages           # module "home_messages": _id UUID PK DEFAULT gen_random_uuid(), text VARCHAR(500), enabled (default FALSE), starts_at/ends_at TIMESTAMPTZ (CHECK end > start),
                        #   priority INT, destination TEXT (CHECK 'none', reserved), created_at, updated_at, created_by/updated_by (text, no FK)
# <!-- /HMS -->
```

---

## Full dependency map

```
users ──────────────────────────────────────────────────────────────────┐
│                                                                        │
├── user_friends                                                        │
├── friend_requests                                                     │
├── blocked_users                                                       │
├── highlights                                                          │
├── bookmarks                                                           │
├── device_tokens                                                       │
├── user_activity                                                       │
├── sessions                                                            │
├── password_reset_tokens                                               │
├── mfa_codes                                                           │
├── content_reports                                                     │
├── agents                                                              │
│     ├── agent_heartbeats ◄────────────────────────── users            │
│     │     └── agentic_context ◄──── notes                             │
│     └── agent_messages ◄─────────────────────────── users             │
├── subscriptions ◄──────────────────── users.subscription_id (reverse) │
│     └── subscription_request ◄───────────────────── users             │
│                                                                        │
groups ─────────────────────────────────────────────────────────────────┤
│                                                                        │
├── notes  ◄──────────────────────────────── users                     │
│     └── note_verses                                                   │
│                                                                        │
└── messages  ◄───────────────────────────── users                     │
      └── message_recipients  ◄────────────── users                    │

devotions  ◄──────────────────────────────── users (creator_id only;
                                               group_id is free-text, not FK)

error_detections (unscoped)
└── error_detection_reports

log_group_cursors (unscoped, no children)
```

---

## Creation order (matches `create_tables`'s actual statement order)

| Step | Table                     |
|------|---------------------------|
| 1    | `users`                   |
| 2    | `groups`                  |
| 3    | `user_friends`            |
| 4    | `friend_requests`         |
| 5    | `blocked_users`           |
| 6    | `highlights`              |
| 7    | `bookmarks`               |
| 8    | `notes`                   |
| 9    | `messages`                |
| 10   | `devotions`               |
| 11   | `agents`                  |
| 12   | `subscriptions`           |
| 13   | *(ALTER)* `users.subscription_id` |
| 14   | `note_verses`             |
| 15   | `message_recipients`      |
| 16   | `agent_heartbeats`        |
| 17   | `agent_messages`          |
| 18   | `device_tokens`           |
| 19   | `user_activity`           |
| 20   | `agentic_context`         |
| 21   | `subscription_request`    |
| 22   | `sessions`                |
| 23   | `password_reset_tokens`   |

> 2026-09-29: `groups.photo_key` (ALTER, right after `groups.creator_id`) and `group_mutes` (`user_id`→users, `group_id`→groups, both ON DELETE CASCADE) are created immediately after `groups`, before `user_friends`.
| 24   | `mfa_codes`               |
| 25   | `content_reports`         |
| 26   | `log_group_cursors`       |
| 27   | `error_detections`        |
| 28   | `error_detection_reports` |

(A legacy `notifications` table is dropped, not created — see the comment
above `DROP TABLE IF EXISTS notifications` in `create_tables`.)

The separate `fellowscript_backup` database (`create_backup_tables`) is a
deliberately FK-light, denormalized mirror of `users`/`notes`/`note_verses`/
`highlights`/`bookmarks` for the nightly backup job — not part of this tree.
