"""Tests for task 20260916-chat-push-deep-link, backend step 1
(api/backend/interactions/websockets.py, ConnectionManager.send_msg's
offline-recipient push branch).

Before the fix: `send_push(token, sender_name, body)` carried no `data` at
all, so a tapped chat-message push had nothing for the client to resolve a
specific conversation from -- it always fell through to the app's default
homepage. This proves the new payload shape (architecture's
payload_shape/discriminator decision) end to end:

  A. Offline GROUP-message push data is exactly
     {"group_id": <the message's own group_id>, "action": "message"}.
  B. Offline DM-message push data synthesizes the same sorted "uidA|uidB"
     room-key string the client's own ChatThreadViewModel.roomKey/
     useSessions.js already produce (group_id is None on the DM path), so
     AppState.openSession(groupId:) can resolve it unmodified -- and that
     synthesis is order-independent (same key regardless of who's uid vs.
     from_user_id).
  C. No message text/content rides along in the push data payload -- only
     identifiers (group_id/action), per push.py::send_push's own docstring
     and this task's Security Posture Q13 preference.
  D. A recipient who is online (live WS delivery, not push) never triggers
     send_push at all -- the new data-building logic only runs on the
     existing offline branch, unchanged in scope.

Run with: cd api && ../.venv/bin/python tests/test_chat_push_deep_link.py
"""
import asyncio
import os
import sys
import uuid
from datetime import datetime, timezone

import _pathfix  # noqa: F401,E402

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from db import DBManager  # noqa: E402
import backend.interactions.websockets as ws_module  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


class RecordingFakeWebSocket:
    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


def make_test_user(username_prefix: str) -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"{username_prefix}_{uid[:8]}",
            "email": f"{username_prefix}_{uid[:8]}@example.com", "hash_pass": "x",
        })
    finally:
        db.close()
    return uid


def make_test_group(group_id: str, users: list[str]) -> None:
    db = DBManager()
    try:
        db.insertion("groups", {"_id": group_id, "title": "deep-link-test-group", "users": users})
    finally:
        db.close()


def cleanup(*user_ids, group_ids: list[str] | None = None):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
        for gid in (group_ids or []):
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def _install_fake_push():
    pushed = []

    async def fake_send_push(token, title, body, data=None):
        pushed.append((token, title, body, data))
        return True

    orig = ws_module.send_push
    ws_module.send_push = fake_send_push
    return pushed, orig


async def test_offline_group_message_push_carries_group_id_and_action():
    print("=== A. offline GROUP chat-message push data == "
          "{'group_id': <group_id>, 'action': 'message'} ===")

    sender_id = make_test_user("deeplink_group_sender")
    offline_member = make_test_user("deeplink_group_offline")
    group_id = str(uuid.uuid4())
    make_test_group(group_id, [sender_id, offline_member])

    pushed, orig_send_push = _install_fake_push()
    manager = ConnectionManager()
    try:
        manager.insertion("device_tokens", {"user_id": offline_member, "token": "deeplink-group-token"})

        marker = f"deeplink-group-{uuid.uuid4().hex[:8]}"
        payload = {
            "from_user": sender_id,
            "to_users":  [sender_id, offline_member],
            "text":      marker,
            "group_id":  group_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        await manager.send_msg(payload)

        check("exactly one push was sent to the offline group member",
              len(pushed) == 1 and pushed[0][0] == "deeplink-group-token", str(pushed))
        if pushed:
            data = pushed[0][3]
            check("push data payload is exactly {'group_id': group_id, 'action': 'message'}",
                  data == {"group_id": group_id, "action": "message"}, str(data))
            check("push data does not leak the message text/content",
                  marker not in str(data), str(data))
    finally:
        manager.close()
        ws_module.send_push = orig_send_push
        cleanup(sender_id, offline_member, group_ids=[group_id])


async def test_offline_dm_message_push_synthesizes_sorted_room_key():
    print("\n=== B. offline DM chat-message push data synthesizes the sorted "
          "'uidA|uidB' room-key string, order-independent of sender/recipient ===")

    sender_id = make_test_user("deeplink_dm_sender")
    recipient_id = make_test_user("deeplink_dm_recipient")

    pushed, orig_send_push = _install_fake_push()
    manager = ConnectionManager()
    try:
        manager.insertion("device_tokens", {"user_id": recipient_id, "token": "deeplink-dm-token"})

        marker = f"deeplink-dm-{uuid.uuid4().hex[:8]}"
        payload = {
            "from_user": sender_id,
            "to_users":  [recipient_id],
            "text":      marker,
            "group_id":  None,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        await manager.send_msg(payload)

        expected_room_key = "|".join(sorted([recipient_id, sender_id]))

        check("exactly one push was sent to the offline DM recipient",
              len(pushed) == 1 and pushed[0][0] == "deeplink-dm-token", str(pushed))
        if pushed:
            data = pushed[0][3]
            check("push data payload's group_id is the sorted 'uidA|uidB' room key, "
                  "not a bare group id or the sender's raw id",
                  data == {"group_id": expected_room_key, "action": "message"}, str(data))
            check("synthesized room key is order-independent (sorted, not sender-then-recipient)",
                  data.get("group_id") == expected_room_key, str(data))
            check("push data does not leak the message text/content",
                  marker not in str(data), str(data))
    finally:
        manager.close()
        ws_module.send_push = orig_send_push
        cleanup(sender_id, recipient_id)


async def test_online_recipient_never_triggers_push_or_data_building():
    print("\n=== D. an ONLINE recipient is delivered live over the socket -- "
          "no push, no data payload built at all ===")

    sender_id = make_test_user("deeplink_online_sender")
    online_recipient = make_test_user("deeplink_online_recipient")

    pushed, orig_send_push = _install_fake_push()
    manager = ConnectionManager()
    try:
        recipient_ws = RecordingFakeWebSocket()
        manager.active_connections[online_recipient] = recipient_ws
        # Registers a device token anyway -- proves the online branch is
        # chosen over push, not that push merely had no token to use.
        manager.insertion("device_tokens", {"user_id": online_recipient, "token": "deeplink-online-token"})

        marker = f"deeplink-online-{uuid.uuid4().hex[:8]}"
        payload = {
            "from_user": sender_id,
            "to_users":  [online_recipient],
            "text":      marker,
            "group_id":  None,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        await manager.send_msg(payload)

        check("online recipient received the live WS frame",
              len(recipient_ws.sent) == 1 and recipient_ws.sent[0].get("text") == marker,
              str(recipient_ws.sent))
        check("no push was sent for an online recipient",
              len(pushed) == 0, str(pushed))
    finally:
        manager.close()
        ws_module.send_push = orig_send_push
        cleanup(sender_id, online_recipient)


def main():
    asyncio.run(test_offline_group_message_push_carries_group_id_and_action())
    asyncio.run(test_offline_dm_message_push_synthesizes_sorted_room_key())
    asyncio.run(test_online_recipient_never_triggers_push_or_data_building())

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
