"""Tests for the group-chat message-duplication fix (task
20260902-group-chat-message-duplication, backend step 1,
api/backend/interactions/websockets.py ConnectionManager.send_msg).

Before the fix:

  The iOS client sends `to_users` for a group message as the FULL group
  member list, including the sender (ChatThreadView.swift's
  `sendMessage()` / `contact.toUsers`). send_msg's per-recipient live
  WebSocket delivery loop (`for uid in to_users:`) had no guard against
  `uid == from_user_id`, so it delivered a live WS frame back to the
  sender's OWN socket — the sender's own just-sent message was echoed back
  to them as an inbound frame, duplicating it in their own thread (on top
  of their optimistic local echo). The only existing `uid != from_user_id`
  check was scoped solely to the offline-push branch, not the live-delivery
  branch, so it did nothing to prevent this.

This proves, using a real ConnectionManager + real Postgres (message
persistence) with fake WebSocket objects standing in for the sender's own
socket and two other group members (a live TestClient can't reliably
assert "message NOT delivered to a specific already-open connection" --
see test_websocket_connection_manager_hardening.py's docstring for the
same rationale), that:

  A. When `to_users` includes the sender (the exact shape the iOS client
     sends for a group message), the SENDER's own socket receives ZERO
     frames -- no self-echo.
  B. The other two (non-sender) group members each receive the frame
     exactly once.
  C. The message is written to `messages` exactly once (not a double
     INSERT -- the self-echo bug was a fan-out issue, never a persistence
     issue, and the fix must not change that).
  D. The sender does NOT get an offline APNs push either (the pre-existing
     `uid != from_user_id` push guard stays correct/is unaffected by this
     fix).
  E. A 1:1 DM (`to_users` excluding the sender, as the client already
     sends today) is completely unaffected: the single recipient still
     gets exactly one frame.
  F. An offline (non-sender) recipient still falls through to the APNs
     push path -- the new sender-skip does not accidentally swallow
     delivery to a genuinely offline OTHER member.

Run with: cd api && ../.venv/bin/python tests/test_group_chat_self_echo_dedup.py
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
    """Stands in for a live, working recipient socket that records every
    frame it's sent, so tests can assert exactly zero/one deliveries."""

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
        db.insertion("groups", {"_id": group_id, "title": "dupfix-test-group", "users": users})
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


async def test_group_send_does_not_echo_back_to_sender():
    print("=== A-D. group send_msg: to_users includes sender (as the iOS client "
          "actually sends) -- sender gets zero frames, others get exactly one, "
          "single DB write, sender excluded from push too ===")

    sender_id  = make_test_user("dupfix_sender")
    member_a   = make_test_user("dupfix_member_a")
    member_b   = make_test_user("dupfix_member_b")
    group_id   = str(uuid.uuid4())
    make_test_group(group_id, [sender_id, member_a, member_b])

    pushed = []

    async def fake_send_push(token, title, body):
        pushed.append((token, title, body))
        return True

    orig_send_push = ws_module.send_push
    ws_module.send_push = fake_send_push

    manager = ConnectionManager()
    try:
        sender_ws   = RecordingFakeWebSocket()
        member_a_ws = RecordingFakeWebSocket()
        member_b_ws = RecordingFakeWebSocket()
        manager.active_connections[sender_id] = sender_ws
        manager.active_connections[member_a]  = member_a_ws
        manager.active_connections[member_b]  = member_b_ws

        # Even if the sender somehow had a device token, they must not be
        # pushed either -- proves the pre-existing push guard still holds.
        manager.insertion("device_tokens", {"user_id": sender_id, "token": "sender-should-never-be-used"})

        marker = f"group-dedup-{uuid.uuid4().hex[:8]}"
        payload = {
            "from_user": sender_id,
            # Mirrors ChatThreadView.swift's contact.toUsers for a group
            # send: the FULL member list, including the sender.
            "to_users":  [sender_id, member_a, member_b],
            "text":      marker,
            "group_id":  group_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

        await manager.send_msg(payload)

        check("sender's own socket received ZERO frames (no self-echo)",
              len(sender_ws.sent) == 0, str(sender_ws.sent))

        check("member A received the frame exactly once",
              len(member_a_ws.sent) == 1 and member_a_ws.sent[0].get("text") == marker,
              str(member_a_ws.sent))

        check("member B received the frame exactly once",
              len(member_b_ws.sent) == 1 and member_b_ws.sent[0].get("text") == marker,
              str(member_b_ws.sent))

        check("sender was not pushed even though they had a registered device token",
              all(p[0] != "sender-should-never-be-used" for p in pushed), str(pushed))

        db = DBManager()
        try:
            db.cur.execute("SELECT _id FROM messages WHERE text = %s", (marker,))
            rows = db.cur.fetchall()
            check("message was persisted exactly once (not a double-INSERT)",
                  len(rows) == 1, str(rows))
            if rows:
                msg_id = str(rows[0][0])
                db.cur.execute("SELECT user_id FROM message_recipients WHERE message_id = %s", (msg_id,))
                recipients = {str(r[0]) for r in db.cur.fetchall()}
                check("all three group members (including the sender) are recorded as recipients "
                      "-- persistence/recipient-linking is unchanged by this fix, only live WS fan-out",
                      recipients == {sender_id, member_a, member_b}, str(recipients))
        finally:
            db.close()

    finally:
        manager.close()
        ws_module.send_push = orig_send_push
        cleanup(sender_id, member_a, member_b, group_ids=[group_id])


async def test_dm_send_is_unaffected():
    print("\n=== E. 1:1 DM send_msg: to_users already excludes the sender "
          "(as the client sends today) -- single recipient still gets exactly "
          "one frame, unaffected by the new sender-skip guard ===")

    sender_id   = make_test_user("dupfix_dm_sender")
    recipient   = make_test_user("dupfix_dm_recipient")

    manager = ConnectionManager()
    try:
        recipient_ws = RecordingFakeWebSocket()
        manager.active_connections[recipient] = recipient_ws
        # Sender does NOT register a connection here -- a DM sender's own
        # socket is the one making the send_msg call in production, but
        # DMs never include the sender in to_users, so this exercises that
        # the fix doesn't change DM behavior at all.

        marker = f"dm-{uuid.uuid4().hex[:8]}"
        payload = {
            "from_user": sender_id,
            "to_users":  [recipient],
            "text":      marker,
            "group_id":  None,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

        await manager.send_msg(payload)

        check("DM recipient received the frame exactly once",
              len(recipient_ws.sent) == 1 and recipient_ws.sent[0].get("text") == marker,
              str(recipient_ws.sent))
    finally:
        manager.close()
        cleanup(sender_id, recipient)


async def test_offline_other_member_still_gets_push():
    print("\n=== F. group send_msg: a genuinely offline OTHER member still "
          "falls through to the APNs push path -- the sender-skip guard "
          "doesn't over-suppress delivery to anyone but the sender ===")

    sender_id = make_test_user("dupfix_push_sender")
    offline_member = make_test_user("dupfix_push_offline")
    group_id = str(uuid.uuid4())
    make_test_group(group_id, [sender_id, offline_member])

    pushed = []

    async def fake_send_push(token, title, body):
        pushed.append((token, title, body))
        return True

    orig_send_push = ws_module.send_push
    ws_module.send_push = fake_send_push

    manager = ConnectionManager()
    try:
        sender_ws = RecordingFakeWebSocket()
        manager.active_connections[sender_id] = sender_ws
        # offline_member has NO active connection -- simulates them being
        # offline -- but does have a device token.
        manager.insertion("device_tokens", {"user_id": offline_member, "token": "offline-member-token"})

        marker = f"offline-push-{uuid.uuid4().hex[:8]}"
        payload = {
            "from_user": sender_id,
            "to_users":  [sender_id, offline_member],
            "text":      marker,
            "group_id":  group_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

        await manager.send_msg(payload)

        check("sender still received zero frames",
              len(sender_ws.sent) == 0, str(sender_ws.sent))
        check("genuinely offline other member was pushed",
              len(pushed) == 1 and pushed[0][0] == "offline-member-token", str(pushed))
    finally:
        manager.close()
        ws_module.send_push = orig_send_push
        cleanup(sender_id, offline_member, group_ids=[group_id])


def main():
    asyncio.run(test_group_send_does_not_echo_back_to_sender())
    asyncio.run(test_dm_send_is_unaffected())
    asyncio.run(test_offline_other_member_still_gets_push())

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
