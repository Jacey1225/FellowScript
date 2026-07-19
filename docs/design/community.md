# Community

The Messaging sidebar (`MessagingSidebar`) handles all social features: group chat, direct messages, and friend management. It appears in the right panel of the Reader when the Messages icon is selected.

---

## Group Chat

When a user belongs to a study group, the messaging sidebar shows:
- **Group message history** — past messages loaded on mount
- **Real-time messages** — delivered via WebSocket (`/ws/{user_id}`)
- **Message input** — text field + send button at the bottom

Group messages are visible to all group members.

---

## Direct Messages

The sidebar also surfaces 1-on-1 DM threads. Selecting a friend from the list opens a private thread visible only to the two participants. DMs are routed through the same WebSocket connection with a `type: "dm"` payload.

---

## Friends

The friends panel shows:
- **Friend list** — all accepted friends with DM button
- **Incoming requests** — friend requests awaiting response (Accept / Decline)
- **Add friend** — send a request by username

All friend actions go through `GET/POST /friends/{user_id}/…` REST endpoints; no WebSocket is needed for friend management.

---

## Groups

Users can create or join study groups:
- **Create group** — sets the user as owner; group gets a UUID and title
- **Join group** — adds the user to `groups.members`
- **Leave group** — removes the user from the group
- **Group selector** — the compact dropdown in the Notes sidebar tab bar also switches the messaging sidebar to the selected group

Group highlights (members' colored verse highlights) are visible as overlays in the scripture view when a group is selected.

---

## Real-Time Behavior

The WebSocket connection (`/ws/{user_id}`) handles:

| Event type | Direction | Action |
|---|---|---|
| `group_message` | send/receive | Broadcast to all group members |
| `dm` | send/receive | Route to a single recipient |
| `activity` | receive | Member is reading / highlighting / noting (broadcast by server) |

The connection is established when the Reader mounts and torn down on unmount.
