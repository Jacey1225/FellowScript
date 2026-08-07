"""Tests for the WebSocket from_user spoofing fix (security audit finding 2,
CRITICAL): api/backend/interactions/websockets.py's ConnectionManager.send_msg
/send_sig trusted payload['from_user'] verbatim from the client's JSON frame,
and routes/messaging.py's websocket_endpoint only authenticated the *handshake*
(session_user == path user_id), never re-stamping from_user on each frame. Any
connected user could impersonate any other user_id in DMs/group chat/call
signaling, and bypass block enforcement (which keys off from_user).

The fix: websocket_endpoint now overwrites payload['from_user'] = session_user
(the authenticated identity from the handshake) before every dispatch, so the
client-supplied value is never trusted:

    payload["from_user"] = session_user   # routes/messaging.py

This proves, using only a single live WebSocket connection per case (the
starlette TestClient runs each websocket_connect() on its own event-loop
thread, so cross-socket "push to another live connection" delivery can't be
exercised reliably from a synchronous test process — persisted DB state is
the reliable, deterministic signal for what ConnectionManager actually
received and acted on):

  1. A connected user's frame claiming a forged from_user is persisted to the
     DB under their TRUE authenticated identity, not the spoofed one — proof
     ConnectionManager never receives the raw client-supplied value.
  2. Block enforcement (keyed off from_user) evaluates the TRUE sender, so it
     cannot be bypassed by claiming to be a different, non-blocked identity.
  3. Unit-level: the exact overwrite line in websocket_endpoint is exercised
     directly against ConnectionManager.send_msg via monkeypatching, proving
     the dispatched payload's from_user is always the handshake identity
     regardless of what the client frame claims — for every dispatch, not
     just the one persisted-message code path.

Run with: cd api && ../.venv/bin/python tests/test_websocket_from_user_spoofing.py
"""
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

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def cookie_header(token: str):
    return {"cookie": f"session={token}"} if token else {}


def signup(client, username):
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    })
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (uid, uid))
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def main():
    import main as main_module
    with TestClient(main_module.app) as client:
        uid_a, token_a = signup(client, f"wsspoof_a_{uuid.uuid4().hex[:8]}")
        uid_b, _        = signup(client, f"wsspoof_b_{uuid.uuid4().hex[:8]}")  # the identity A will try to impersonate
        uid_c, token_c = signup(client, f"wsspoof_c_{uuid.uuid4().hex[:8]}")  # DM recipient (kept offline on purpose)

        try:
            print("=== 1. A connects as self and sends a frame claiming from_user=B (impersonation attempt) ===")
            marker_text = f"forged-{uuid.uuid4().hex[:8]}"
            with client.websocket_connect(f"/message/ws/{uid_a}", headers=cookie_header(token_a)) as ws_a:
                ws_a.send_json({
                    "from_user": uid_b,          # forged — A claims to be B
                    "to_users":  [uid_c],
                    "text":      marker_text,
                    "group_id":  None,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                })
                time.sleep(0.3)  # let the server-side coroutine process + persist the frame

            db = DBManager()
            try:
                db.cur.execute(
                    "SELECT from_user FROM messages WHERE text = %s ORDER BY timestamp DESC LIMIT 1",
                    (marker_text,),
                )
                row = db.cur.fetchone()
                check("message was persisted", row is not None, str(row))
                if row:
                    check("persisted from_user is the TRUE authenticated sender (A), not the spoofed value",
                          str(row[0]) == uid_a, str(row))
                    check("persisted from_user is NOT the spoofed identity (B)",
                          str(row[0]) != uid_b, str(row))
            finally:
                db.close()

            print("\n=== 2. Block enforcement is keyed off the TRUE sender, not a spoofed identity ===")
            # C blocks A. A then sends a DM to C, again forging from_user=B
            # (whom C has NOT blocked). If ConnectionManager still trusted
            # the spoofed from_user for the block lookup, the message would
            # be delivered/persisted anyway (B isn't blocked). Because the
            # from_user overwrite happens before ConnectionManager ever sees
            # the payload, the lookup runs against A (who IS blocked by C),
            # and the DM must be dropped before it's ever saved.
            r = client.post(f"/blocks/{uid_c}/{uid_a}", headers=cookie_header(token_c))
            check("C blocks A -> 2xx", r.status_code < 300, str(r.status_code) + " " + r.text)

            blocked_marker = f"blocked-{uuid.uuid4().hex[:8]}"
            with client.websocket_connect(f"/message/ws/{uid_a}", headers=cookie_header(token_a)) as ws_a:
                ws_a.send_json({
                    "from_user": uid_b,  # still forged, to prove the block check isn't fooled by it
                    "to_users":  [uid_c],
                    "text":      blocked_marker,
                    "group_id":  None,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                })
                time.sleep(0.3)

            db = DBManager()
            try:
                db.cur.execute("SELECT 1 FROM messages WHERE text = %s", (blocked_marker,))
                check("blocked DM (with spoofed from_user) was never persisted — block check used the true sender",
                      db.cur.fetchone() is None)
            finally:
                db.close()

        finally:
            print("\n=== cleanup ===")
            cleanup(uid_a, uid_b, uid_c)

    print("\n=== 3. Unit-level: websocket_endpoint always overwrites from_user before dispatch ===")
    # Exercise the fixed line directly against a captured ConnectionManager
    # call, independent of any live-socket timing/threading concerns above.
    import asyncio
    import routes.messaging as messaging_module

    captured = {}

    class FakeConnectionManager:
        async def connect(self, user_id, ws):
            pass

        async def disconnect(self, user_id):
            pass

        async def send_msg(self, payload):
            captured["msg"] = dict(payload)
            raise _StopLoop()

        async def send_sig(self, payload):
            captured["sig"] = dict(payload)
            raise _StopLoop()

    class _StopLoop(Exception):
        pass

    class FakeWebSocket:
        def __init__(self, frames):
            self._frames = list(frames)

        async def receive_json(self):
            if not self._frames:
                raise messaging_module.WebSocketDisconnect()
            return self._frames.pop(0)

    async def run_case(frame, expect_key):
        orig_manager = messaging_module.manager
        orig_auth = messaging_module.authenticate_ws
        messaging_module.manager = FakeConnectionManager()

        async def fake_auth(ws):
            return "REAL_SESSION_USER"

        messaging_module.authenticate_ws = fake_auth
        try:
            ws = FakeWebSocket([frame])
            try:
                await messaging_module.websocket_endpoint(ws, "REAL_SESSION_USER")
            except _StopLoop:
                pass
            return captured.get(expect_key)
        finally:
            messaging_module.manager = orig_manager
            messaging_module.authenticate_ws = orig_auth

    chat_result = asyncio.run(run_case(
        {"type": "chat", "from_user": "SPOOFED_USER", "to_users": ["x"], "text": "hi", "group_id": None, "timestamp": "1"},
        "msg",
    ))
    check("chat dispatch: from_user forced to session identity regardless of client value",
          chat_result is not None and chat_result.get("from_user") == "REAL_SESSION_USER", str(chat_result))

    sig_result = asyncio.run(run_case(
        {"type": "call-invite", "from_user": "SPOOFED_USER", "to_users": ["x"]},
        "sig",
    ))
    check("signal dispatch (call-invite): from_user forced to session identity regardless of client value",
          sig_result is not None and sig_result.get("from_user") == "REAL_SESSION_USER", str(sig_result))

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
