"""Tests for the WebSocket connection-manager hardening fix (task
20260808-ios-backend-integration-audit, step 8 backend finding, fixed in
api/backend/interactions/websockets.py and api/routes/messaging.py).

Before the fix:

  1. ConnectionManager.send_msg/send_sig called `await ws.send_json(...)` on a
     cached recipient WebSocket with no exception handling. A recipient socket
     can go stale (the peer dropped without a clean close frame reaching the
     server yet) while still sitting in `active_connections`. The resulting
     exception propagated out of send_msg/send_sig into the CALLER's (the
     sender's, a completely different, healthy connection's)
     websocket_endpoint loop — one silently-dead client-side socket could
     crash an unrelated sender's connection.

  2. routes/messaging.py's websocket_endpoint only called
     `manager.disconnect(user_id)` inside `except WebSocketDisconnect`. Any
     OTHER exception escaping the receive loop (including the one above, or a
     malformed receive_json() frame) left the dead entry in
     `active_connections` forever — every subsequent message to that user hit
     the same failure.

This proves, using real ConnectionManager + real Postgres (message
persistence) with fake WebSocket objects standing in for the two client
sockets (a live TestClient can't reliably assert "message delivered to a
DIFFERENT already-open connection" — see test_websocket_from_user_spoofing.py's
docstring for the same rationale), that:

  A. A send failure to one recipient's stale socket does NOT raise out of
     send_msg — the call completes normally.
  B. That stale socket is evicted from active_connections (so it isn't
     retried forever).
  C. The OTHER, healthy recipient still receives their message via WebSocket
     (proving one bad connection doesn't block delivery to everyone else).
  D. The evicted recipient falls through to the offline-APNs-push path
     (delivery still happens once they reconnect, instead of the message
     silently vanishing for them).
  E. The same eviction/no-raise behavior holds for send_sig (call signaling).
  F. websocket_endpoint's cleanup (`manager.disconnect`) now runs on ANY
     exception escaping the receive loop, not just a clean WebSocketDisconnect
     — proven at the unit level against a fake manager/websocket, mirroring
     test_websocket_from_user_spoofing.py's "part 3" harness style.

Run with: cd api && ../.venv/bin/python tests/test_websocket_connection_manager_hardening.py
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


class HealthyFakeWebSocket:
    """Stands in for a live, working recipient socket."""

    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


class StaleFakeWebSocket:
    """Stands in for a recipient socket that's still registered in
    active_connections but whose underlying connection has actually dropped —
    the exact class of failure this fix guards against."""

    async def send_json(self, payload):
        raise ConnectionResetError("stale socket: connection reset by peer")


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


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


async def test_send_msg_eviction_and_fallback():
    print("=== A-D. send_msg: stale recipient doesn't raise, is evicted, healthy "
          "recipient still delivered, stale recipient falls through to push ===")

    sender_id  = make_test_user("wshard_sender")
    healthy_id = make_test_user("wshard_healthy")
    stale_id   = make_test_user("wshard_stale")

    pushed = []

    async def fake_send_push(token, title, body):
        pushed.append((token, title, body))
        return True

    orig_send_push = ws_module.send_push
    ws_module.send_push = fake_send_push

    manager = ConnectionManager()
    try:
        healthy_ws = HealthyFakeWebSocket()
        stale_ws   = StaleFakeWebSocket()
        manager.active_connections[healthy_id] = healthy_ws
        manager.active_connections[stale_id]   = stale_ws

        # Give the stale recipient a device token so we can prove the
        # eviction path falls through to the offline-push branch.
        manager.insertion("device_tokens", {"user_id": stale_id, "token": "fake-apns-token"})

        marker = f"hardening-{uuid.uuid4().hex[:8]}"
        payload = {
            "from_user": sender_id,
            "to_users":  [healthy_id, stale_id],
            "text":      marker,
            "group_id":  None,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

        raised = False
        try:
            await manager.send_msg(payload)
        except Exception as e:  # noqa: BLE001 — exactly what we're proving does NOT happen
            raised = True
            check("send_msg did not raise despite one recipient's socket failing", False, repr(e))

        if not raised:
            check("send_msg did not raise despite one recipient's socket failing", True)

        check("healthy recipient received the WebSocket frame",
              len(healthy_ws.sent) == 1 and healthy_ws.sent[0].get("text") == marker,
              str(healthy_ws.sent))

        check("stale recipient's dead socket was evicted from active_connections",
              stale_id not in manager.active_connections,
              str(manager.active_connections.keys()))

        check("healthy recipient's socket was NOT evicted",
              healthy_id in manager.active_connections)

        check("evicted stale recipient fell through to the offline APNs push path",
              len(pushed) == 1 and pushed[0][0] == "fake-apns-token",
              str(pushed))

        # Message must still be persisted for both recipients regardless of
        # delivery-channel outcome (DB is the source of truth on next fetch).
        db = DBManager()
        try:
            db.cur.execute("SELECT _id FROM messages WHERE text = %s", (marker,))
            row = db.cur.fetchone()
            check("message was persisted despite one recipient's live-delivery failure", row is not None)
            if row:
                msg_id = str(row[0])
                db.cur.execute("SELECT user_id FROM message_recipients WHERE message_id = %s", (msg_id,))
                recipients = {str(r[0]) for r in db.cur.fetchall()}
                check("both recipients (including the one whose socket failed) are recorded",
                      recipients == {healthy_id, stale_id}, str(recipients))
        finally:
            db.close()

    finally:
        manager.close()
        ws_module.send_push = orig_send_push
        cleanup(sender_id, healthy_id, stale_id)


async def test_send_sig_eviction():
    print("\n=== E. send_sig: same no-raise + eviction behavior for call signaling ===")

    healthy_id = make_test_user("wshard_sig_healthy")
    stale_id   = make_test_user("wshard_sig_stale")

    manager = ConnectionManager()
    try:
        healthy_ws = HealthyFakeWebSocket()
        stale_ws   = StaleFakeWebSocket()
        manager.active_connections[healthy_id] = healthy_ws
        manager.active_connections[stale_id]   = stale_ws

        payload = {"type": "call-invite", "to_users": [healthy_id, stale_id]}

        raised = False
        try:
            await manager.send_sig(payload)
        except Exception as e:  # noqa: BLE001
            raised = True
            check("send_sig did not raise despite one recipient's socket failing", False, repr(e))
        if not raised:
            check("send_sig did not raise despite one recipient's socket failing", True)

        check("send_sig: healthy recipient received the signal frame",
              len(healthy_ws.sent) == 1 and healthy_ws.sent[0] == payload, str(healthy_ws.sent))
        check("send_sig: stale recipient's dead socket was evicted",
              stale_id not in manager.active_connections)
    finally:
        manager.close()
        cleanup(healthy_id, stale_id)


async def test_websocket_endpoint_disconnect_runs_on_any_exception():
    print("\n=== F. websocket_endpoint: manager.disconnect() runs on ANY exception "
          "escaping the receive loop, not just WebSocketDisconnect ===")

    import routes.messaging as messaging_module

    disconnect_calls = []

    class FakeManagerRaisesGenericError:
        async def connect(self, user_id, ws):
            pass

        async def disconnect(self, user_id):
            disconnect_calls.append(user_id)

        async def send_msg(self, payload):
            # Simulate an unexpected, non-WebSocketDisconnect failure escaping
            # the dispatch call (e.g. a malformed payload, a DB error) —
            # exactly the case the old `except WebSocketDisconnect: pass`
            # (with cleanup only in that branch) did NOT clean up after.
            raise RuntimeError("simulated unexpected dispatch failure")

        async def send_sig(self, payload):
            raise RuntimeError("simulated unexpected dispatch failure")

    class FakeWebSocket:
        def __init__(self, frames):
            self._frames = list(frames)

        async def receive_json(self):
            if not self._frames:
                raise messaging_module.WebSocketDisconnect()
            return self._frames.pop(0)

    orig_manager = messaging_module.manager
    orig_auth = messaging_module.authenticate_ws
    messaging_module.manager = FakeManagerRaisesGenericError()

    async def fake_auth(ws):
        return "REAL_SESSION_USER"

    messaging_module.authenticate_ws = fake_auth

    try:
        ws = FakeWebSocket([{
            "type": "chat", "from_user": "irrelevant", "to_users": ["x"],
            "text": "hi", "group_id": None, "timestamp": "1",
        }])
        raised_unhandled = False
        try:
            await messaging_module.websocket_endpoint(ws, "REAL_SESSION_USER")
        except RuntimeError:
            # The dispatch error itself is expected to propagate (this test
            # isn't about swallowing it) — what matters is whether cleanup
            # still ran via `finally` before/while it propagates.
            pass
        except Exception as e:  # noqa: BLE001
            raised_unhandled = True
            check("websocket_endpoint did not raise an unexpected exception type", False, repr(e))

        if not raised_unhandled:
            check("websocket_endpoint propagated the dispatch RuntimeError as expected", True)

        check("manager.disconnect() ran even though the failure was a generic "
              "RuntimeError, not a WebSocketDisconnect (the finally-block fix)",
              disconnect_calls == ["REAL_SESSION_USER"], str(disconnect_calls))
    finally:
        messaging_module.manager = orig_manager
        messaging_module.authenticate_ws = orig_auth


def main():
    asyncio.run(test_send_msg_eviction_and_fallback())
    asyncio.run(test_send_sig_eviction())
    asyncio.run(test_websocket_endpoint_disconnect_runs_on_any_exception())

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
