# Chat @mentions

Feature flag: `chat_mentions` (seeded off, canary allowed, listed in `GET /app/capabilities` under `features`).
Applies to DMs, group chat and group threads. Stored `text` always contains the literal `@<username>`, so builds
without the feature show a plain `@Name`.

## The `mentions` field

Send (WebSocket frame, main chat or `thread_message`), optional:

```json
"mentions": [{"user_id": "3f2b...-uuid", "start": 6, "length": 9}]
```

- `start` and `length` are UTF-16 code units into the sent text. `length` covers `@` plus the username.
- Sorted by `start`, no overlap, at most 10 entries, one entry per user.
- The slice must equal `"@" + username` of the mentioned user exactly. The mentioned user must be a current member
  (DM: the other party), not the sender, not suspended and not blocked in either direction.
- Not allowed on `shared_verse` or `shared_note` messages.
- Flag off for the sender: the key is ignored and the message is a plain message.

Rejections are sent to the sender's own socket and nothing is saved: `{"type":"error","reason":"mention_invalid"}`
for any validation failure and `{"type":"error","reason":"mentions_too_many"}` above 10 entries.

Received (ack, live frame, restore frame, history pages, thread read, pinned list) the key is added only when the
message has mentions and the viewer's flag is on. Each entry also carries the user's current `username` (omitted for a
deleted account):

```json
"mentions": [{"user_id": "3f2b...-uuid", "start": 6, "length": 9, "username": "Matthew"}]
```

Pinned previews keep only mentions that fit inside the truncated text. Reply quote snippets carry no mentions.
Stored values are ids and offsets only (`messages.mentions`, `thread_messages.mentions`, JSONB, NULL when none); they
are cleared with the message text by the purge sweeper.

## Member list for the picker

`GET /groups/{user_id}/{group_id}/mention-members` returns `{"members": [{"user_id", "username"}]}`: live members
without the caller, blocked users and suspended users, sorted by username. `404` when the flag is off, `403` for a
non-member.

## Push

A mentioned user gets one push titled `<sender> mentioned you` (body: the usual message preview; data adds
`"mention": true`). It is sent even when the group is muted, the user is online, or (threads) the user does not follow
the thread. The global "messages" notification preference, blocks, a missing device token and a message deleted before
sending still suppress it.

### Mention push rate limit

Only the extra mention push is limited, never the message. A message that mentions someone is always validated,
stored and delivered over the websocket. The limits (code constants in `message_mentions.py`, applied on the main
chat, DM and thread paths, additive to and independent of the thread send limit):

- per sender to recipient pair: at most 1 mention push per 10 seconds (`PAIR_MAX_PUSHES`, `PAIR_WINDOW_SECONDS`)
- per sender across all recipients: at most 20 mention pushes per 60 seconds (`SENDER_MAX_PUSHES`, `SENDER_WINDOW_SECONDS`)

When a mention push is suppressed by the limit (logged with ids only), the recipient is handled as for an ordinary
message, not as a mention: a user who muted the group gets no push, an online user gets only the websocket frame,
and in a thread only an offline follower who has not muted the group gets the ordinary push (title is the sender
name, no `mention` key). Suppressed attempts are not counted, so they do not extend the window. The limiter is an
in-memory sliding window per backend process (one container today); it resets on restart and is not shared between
processes. Memory is bounded: each key holds at most its limit in timestamps and expired keys are swept out
periodically.

## Rollout

1. Deploy the backend with the flag off. `create_tables` runs at startup and adds
   `ALTER TABLE messages ADD COLUMN IF NOT EXISTS mentions JSONB` and
   `ALTER TABLE thread_messages ADD COLUMN IF NOT EXISTS mentions JSONB` (additive, nullable, idempotent).
2. Ship clients.
3. Flip `chat_mentions` (canary first). No new environment variable.

Edits are not supported today; if added, an edit must re-validate mentions as a whole and push only users not
mentioned before.
