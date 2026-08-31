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
agent_messages         → agents, users
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
