# Community

The Community tab shows all members of your current study group, their reading status, and the shared group chat.

---

## Layout

```
┌────────────────────────────┐
│ < Home   FellowScript  [⋮] │
├────────────────────────────┤
│ [Search]   2 Timothy 1     │
│ Highlight: 🟡 🟠 🟢 🔴 🔵  │
├────────────────────────────┤
│ STUDY GROUP                │
├────────────────────────────┤
│ 🟢 JM  James M.            │
│        Reading verse 7  [DM]│  ← Online member with activity + DM button
├────────────────────────────┤
│ 🟢 SR  Sarah R.            │
│        Left a note      [DM]│
├────────────────────────────┤
│ ⚪ DK  David K.            │
│        Highlighted verse 3 [DM]│
├────────────────────────────┤
│ ⚪ ML  Mary L.             │
│        Offline          [DM]│
├────────────────────────────┤
│ Message group...           │  ← Group chat input
└────────────────────────────┘
│  [📖 Read] [📝 Notes] [👥 Community] │
└────────────────────────────┘
```

---

## Member List

Each member row shows:
- **Online indicator** — green dot (online) or grey (offline)
- **Color-coded avatar** with initials
- **Display name**
- **Activity status** — what the member is currently doing (reading a verse, leaving a note, highlighting, offline)
- **DM button** — opens a direct message thread

---

## Group Chat

- A shared message input at the bottom of the Community tab
- All group members can read and post
- Real-time updates via WebSocket

---

## Direct Messages

Tapping **DM** next to a member opens a private 1-on-1 thread separate from the group chat. Messages are only visible to the two participants.

---

## Real-Time Behavior

Member activity statuses (e.g. "Reading verse 7", "Left a note") update in real time so the group can see where everyone is in the scripture. This is powered by the WebSocket layer in `backend/messaging/websockets.py`.
