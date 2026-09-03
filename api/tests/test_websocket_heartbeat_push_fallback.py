"""Tests for the WebSocket liveness-heartbeat fix (task
20260902-chat-push-notification-failure, backend step 1,
api/backend/interactions/websockets.py ConnectionManager +
api/routes/messaging.py websocket_endpoint).

Root cause this task fixed: ConnectionManager.send_msg treated the mere
presence of an `active_connections[uid]` entry as proof a recipient was
online. It isn't -- a TCP-level `ws.send_json()` can succeed into a
backgrounded/suspended (or killed, or network-dropped) client that will
never surface the frame as a notification, so send_msg's `ws truthy` check
never fell through to the existing offline-APNs-push branch for those
recipients. The fix adds a periodic background liveness probe
(`run_heartbeat_check`, fed by `touch()` on every inbound frame and by the
probe's own `send_json` raising) that proactively evicts anything that
hasn't proven it's alive within `HEARTBEAT_TIMEOUT`, so a *subsequent*
send_msg call correctly falls through to push for that recipient.

The existing test_websocket_connection_manager_hardening.py::
test_send_msg_eviction_and_fallback already proves the evict-then-push
fallback works when a live send *raises*. It does NOT prove anything about a
send that succeeds into a dead/backgrounded socket -- exactly the gap this
file closes, per the intake spec's explicit acceptance criteria:

  A. A recipient whose socket is registered but stale (accepts writes
     silently, like a backgrounded/suspended client, and has produced no
     inbound frame -- no `touch()` -- within HEARTBEAT_TIMEOUT) is evicted by
     `run_heartbeat_check` even though its `send_json` never raised, for both
     a DM and a group payload shape.
  B. Once evicted by the heartbeat, a subsequent send_msg call for that
     recipient falls through to the offline APNs push path -- for both a DM
     and a group payload shape.
  C. A recipient who was NEVER connected at all (the plain "always offline"
     case, not merely evicted) still gets pushed, for both a DM and a group
     payload shape -- proving the heartbeat mechanism didn't regress the
     pre-existing never-connected-offline path.
  D. A recipient with a genuinely fresh, actively-connected socket (recent
     `touch()`, ping succeeds) is NOT evicted by the heartbeat, and continues
     to receive the live WebSocket frame with no redundant/duplicate push --
     the over-notification regression the intake spec's acceptance criteria
     explicitly calls out.
  E. The sender continues to receive neither a WS echo nor a push for their
     own group message even when the heartbeat has just run (regression
     guard for 20260902-group-chat-message-duplication's self-echo fix,
     re-verified in combination with the new heartbeat mechanism).
  F. `touch()` only records proof of life for a currently-registered
     connection (a no-op for an unknown/already-evicted user_id) --
     `run_heartbeat_check` itself does not resurrect anything an eviction (or
     a `disconnect()`) has already removed.
  G. `start_heartbeat()` is idempotent -- calling it twice does not spawn a
     second background loop task.

Run with: cd api && ../.venv/bin/python tests/test_websocket_heartbeat_push_fallback.py
"""
import asyncio
import os
import sys
import time
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


class SilentAcceptFakeWebSocket:
    """Stands in for a recipient socket that's still registered and whose
    `send_json` calls succeed at the TCP-write level -- exactly what a
    backgrounded/suspended-but-not-yet-torn-down client looks like from the
    server's side -- but which never produces an inbound frame of its own
    (no `touch()`), so it can only be told apart from a genuinely live
    connection by the heartbeat's liveness timeout, not by a raised
    exception."""

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
        db.insertion("groups", {"_id": group_id, "title": "heartbeat-test-group", "users": users})
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

    async def fake_send_push(token, title, body):
        pushed.append((token, title, body))
        return True

    orig = ws_module.send_push
    ws_module.send_push = fake_send_push
    return pushed, orig


async def test_dm_stale_registered_socket_evicted_by_heartbeat_then_pushed():
    print("=== A/B (DM). A registered-but-stale (silently-accepting, un-touched) "
          "socket is evicted by run_heartbeat_check on timeout, then a "
          "subsequent DM send_msg falls through to push ===")

    sender_id = make_test_user("hb_dm_sender")
    stale_id  = make_test_user("hb_dm_stale")

    pushed, orig_send_push = _install_fake_push()

    manager = ConnectionManager()
    try:
        stale_ws = SilentAcceptFakeWebSocket()
        manager.active_connections[stale_id] = stale_ws
        # Simulate a backgrounded client: registered well outside the
        # liveness window, with no inbound frame (no touch()) since then.
        manager.last_seen[stale_id] = time.monotonic() - (manager.HEARTBEAT_TIMEOUT + 5)
        manager.insertion("device_tokens", {"user_id": stale_id, "token": "hb-dm-token"})

        await manager.run_heartbeat_check()

        check("heartbeat probe was actually sent to the stale socket before eviction",
              len(stale_ws.sent) == 1 and stale_ws.sent[0] == {"type": "ping"},
              str(stale_ws.sent))
        check("stale-but-silently-accepting DM socket WAS evicted by the heartbeat timeout "
              "(not merely by a raised send)",
              stale_id not in manager.active_connections, str(manager.active_connections.keys()))
        check("evicted user's last_seen entry was cleaned up too",
              stale_id not in manager.last_seen)

        marker = f"hb-dm-{uuid.uuid4().hex[:8]}"
        payload = {
            "from_user": sender_id,
            "to_users":  [stale_id],
            "text":      marker,
            "group_id":  None,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        await manager.send_msg(payload)

        check("post-heartbeat-eviction DM send_msg fell through to the offline APNs push path",
              len(pushed) == 1 and pushed[0][0] == "hb-dm-token", str(pushed))
    finally:
        manager.close()
        ws_module.send_push = orig_send_push
        cleanup(sender_id, stale_id)


async def test_group_stale_registered_socket_evicted_by_heartbeat_then_pushed():
    print("\n=== A/B/D/E (group). Mixed group: heartbeat evicts only the stale "
          "member; foreground member still gets the live WS frame with no "
          "push; evicted member falls through to push; sender gets neither ===")

    sender_id   = make_test_user("hb_grp_sender")
    fresh_id    = make_test_user("hb_grp_fresh")
    stale_id    = make_test_user("hb_grp_stale")
    group_id    = str(uuid.uuid4())
    make_test_group(group_id, [sender_id, fresh_id, stale_id])

    pushed, orig_send_push = _install_fake_push()

    manager = ConnectionManager()
    try:
        sender_ws = SilentAcceptFakeWebSocket()
        fresh_ws  = SilentAcceptFakeWebSocket()
        stale_ws  = SilentAcceptFakeWebSocket()
        manager.active_connections[sender_id] = sender_ws
        manager.active_connections[fresh_id]  = fresh_ws
        manager.active_connections[stale_id]  = stale_ws

        # fresh_id: a genuinely foreground, actively-connected user who just
        # hasn't sent a frame in the last instant -- must survive the
        # heartbeat with plenty of margin (this is the "must not
        # over-notify/over-evict a quiet-but-live user" acceptance
        # criterion).
        manager.last_seen[sender_id] = time.monotonic()
        manager.last_seen[fresh_id]  = time.monotonic()
        # stale_id: registered, but nothing proving liveness since well
        # before the timeout window -- e.g. backgrounded without a clean
        # disconnect frame reaching the server.
        manager.last_seen[stale_id]  = time.monotonic() - (manager.HEARTBEAT_TIMEOUT + 5)

        manager.insertion("device_tokens", {"user_id": stale_id, "token": "hb-grp-token"})

        await manager.run_heartbeat_check()

        check("fresh (recently-touched) group member's socket was NOT evicted by the heartbeat",
              fresh_id in manager.active_connections, str(manager.active_connections.keys()))
        check("sender's own socket was NOT evicted by the heartbeat",
              sender_id in manager.active_connections, str(manager.active_connections.keys()))
        check("stale group member's socket WAS evicted by the heartbeat timeout",
              stale_id not in manager.active_connections, str(manager.active_connections.keys()))

        # The heartbeat probe itself legitimately sent a `{"type": "ping"}`
        # control frame to every still-registered socket (sender, fresh, and
        # stale, before stale's eviction) -- that's expected liveness-probe
        # traffic, not an application message, and the iOS client's
        # receiveLoop harmlessly no-ops on a frame with no "text" key. Clear
        # the recorded frames now so the assertions below cleanly test only
        # what send_msg itself delivers, not the heartbeat's own probe noise.
        sender_ws.sent.clear()
        fresh_ws.sent.clear()
        stale_ws.sent.clear()

        marker = f"hb-grp-{uuid.uuid4().hex[:8]}"
        payload = {
            "from_user": sender_id,
            # Mirrors ChatThreadView.swift's contact.toUsers: full member
            # list including the sender.
            "to_users":  [sender_id, fresh_id, stale_id],
            "text":      marker,
            "group_id":  group_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        await manager.send_msg(payload)

        check("sender received zero WS frames (self-echo regression guard for "
              "20260902-group-chat-message-duplication, re-verified alongside the new "
              "heartbeat mechanism -- the only push below belongs to the evicted stale "
              "member, proven by the exact-count check that follows)",
              len(sender_ws.sent) == 0, str(sender_ws.sent))
        check("foreground (fresh) member received the live WS frame exactly once, with no "
              "redundant push (no over-notification regression)",
              len(fresh_ws.sent) == 1 and fresh_ws.sent[0].get("text") == marker,
              str(fresh_ws.sent))
        check("heartbeat-evicted stale member received no WS frame (already evicted) "
              "and instead fell through to push",
              len(stale_ws.sent) == 0, str(stale_ws.sent))
        check("heartbeat-evicted stale member's push fired exactly once with their token",
              len(pushed) == 1 and pushed[0][0] == "hb-grp-token", str(pushed))
    finally:
        manager.close()
        ws_module.send_push = orig_send_push
        cleanup(sender_id, fresh_id, stale_id, group_ids=[group_id])


async def test_never_connected_offline_dm_and_group_still_push():
    print("\n=== C. Plain 'never connected' offline case (no heartbeat eviction "
          "involved at all) still pushes correctly, for both DM and group ===")

    sender_id      = make_test_user("hb_never_sender")
    dm_offline     = make_test_user("hb_never_dm_offline")
    group_offline  = make_test_user("hb_never_grp_offline")
    group_id       = str(uuid.uuid4())
    make_test_group(group_id, [sender_id, group_offline])

    pushed, orig_send_push = _install_fake_push()

    manager = ConnectionManager()
    try:
        # Neither offline user is ever added to active_connections/last_seen
        # -- the plain "app never opened a socket at all" case, distinct
        # from the heartbeat-eviction cases above.
        manager.insertion("device_tokens", {"user_id": dm_offline, "token": "never-dm-token"})
        manager.insertion("device_tokens", {"user_id": group_offline, "token": "never-grp-token"})

        dm_marker = f"never-dm-{uuid.uuid4().hex[:8]}"
        await manager.send_msg({
            "from_user": sender_id, "to_users": [dm_offline], "text": dm_marker,
            "group_id": None, "timestamp": datetime.now(timezone.utc).isoformat(),
        })
        check("never-connected DM recipient was pushed",
              any(p[0] == "never-dm-token" for p in pushed), str(pushed))

        grp_marker = f"never-grp-{uuid.uuid4().hex[:8]}"
        await manager.send_msg({
            "from_user": sender_id, "to_users": [sender_id, group_offline], "text": grp_marker,
            "group_id": group_id, "timestamp": datetime.now(timezone.utc).isoformat(),
        })
        check("never-connected group recipient was pushed",
              any(p[0] == "never-grp-token" for p in pushed), str(pushed))
        check("exactly two pushes total (no duplicate/extra push fired)",
              len(pushed) == 2, str(pushed))
    finally:
        manager.close()
        ws_module.send_push = orig_send_push
        cleanup(sender_id, dm_offline, group_offline, group_ids=[group_id])


async def test_touch_is_noop_for_unknown_user():
    print("\n=== F. touch() only records proof of life for a currently-registered "
          "connection -- no-op for an unknown/already-evicted user_id ===")

    manager = ConnectionManager()
    try:
        ghost_id = str(uuid.uuid4())
        manager.touch(ghost_id)
        check("touch() did not resurrect/register an unknown user_id",
              ghost_id not in manager.active_connections and ghost_id not in manager.last_seen)

        real_id = str(uuid.uuid4())
        manager.active_connections[real_id] = SilentAcceptFakeWebSocket()
        before = time.monotonic() - 1000
        manager.last_seen[real_id] = before
        manager.touch(real_id)
        check("touch() updated last_seen for an actually-registered connection",
              manager.last_seen[real_id] > before)
    finally:
        manager.close()


async def test_start_heartbeat_is_idempotent():
    print("\n=== G. start_heartbeat() is idempotent -- a second call does not "
          "spawn a second background loop task ===")

    manager = ConnectionManager()
    try:
        manager.start_heartbeat()
        first_task = manager._heartbeat_task
        manager.start_heartbeat()
        second_task = manager._heartbeat_task
        check("calling start_heartbeat() twice reuses the same background task, not a second one",
              first_task is second_task and first_task is not None)
    finally:
        if manager._heartbeat_task is not None:
            manager._heartbeat_task.cancel()
        manager.close()


def main():
    asyncio.run(test_dm_stale_registered_socket_evicted_by_heartbeat_then_pushed())
    asyncio.run(test_group_stale_registered_socket_evicted_by_heartbeat_then_pushed())
    asyncio.run(test_never_connected_offline_dm_and_group_still_push())
    asyncio.run(test_touch_is_noop_for_unknown_user())
    asyncio.run(test_start_heartbeat_is_idempotent())

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
