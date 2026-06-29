# FellowScript — Database Schema Tree

Tables ordered **outside-in**: create from Level 0 upward.
Each arrow (→) lists the tables a given table depends on.

---

## Level 0 — No foreign keys (create first)

```
users
groups
```

---

## Level 1 — Depend only on Level 0

```
user_friends          → users, users
friend_requests       → users, users
highlights            → users
bookmarks             → users
group_members         → users, groups
notes *               → users, groups
messages              → users, groups
devotions             → users, groups
agent_conversations   → users
```

> **\* notes** has a self-referencing FK (`parent_note_id → notes`) for replies.
> PostgreSQL resolves this automatically — no special handling needed.

---

## Level 2 — Depend on Level 1 (create last)

```
note_verses           → notes
message_recipients    → messages, users
devotion_participants → devotions, users
devotion_verses       → devotions
devotion_prompts      → devotions
agent_messages        → agent_conversations
```

---

## Full dependency map

```
users ──────────────────────────────────────────────────────────┐
│                                                               │
├── user_friends                                                │
├── friend_requests                                             │
├── highlights                                                  │
├── bookmarks                                                   │
├── agent_conversations                                         │
│     └── agent_messages                                        │
│                                                               │
groups ─────────────────────────────────────────────────────────┤
│                                                               │
├── group_members  ◄─────────────────────── users              │
│                                                               │
├── notes  ◄──────────────────────────────── users             │
│     └── note_verses                                           │
│                                                               │
├── messages  ◄───────────────────────────── users             │
│     └── message_recipients  ◄────────────── users            │
│                                                               │
└── devotions  ◄──────────────────────────── users             │
      ├── devotion_participants  ◄─────────── users             │
      ├── devotion_verses                                        │
      └── devotion_prompts                                      │
```

---

## Creation order (safe sequence)

| Step | Table                  |
|------|------------------------|
| 1    | `users`                |
| 2    | `groups`               |
| 3    | `user_friends`         |
| 4    | `friend_requests`      |
| 5    | `highlights`           |
| 6    | `bookmarks`            |
| 7    | `group_members`        |
| 8    | `notes`                |
| 9    | `messages`             |
| 10   | `devotions`            |
| 11   | `agent_conversations`  |
| 12   | `note_verses`          |
| 13   | `message_recipients`   |
| 14   | `devotion_participants` |
| 15   | `devotion_verses`      |
| 16   | `devotion_prompts`     |
| 17   | `agent_messages`       |
