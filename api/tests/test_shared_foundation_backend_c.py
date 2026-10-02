"""Tests for task 20261002-shared-foundation (Backend C, step 7).

Properties proved (each would catch a regression of the bug it names):
  1. Dockerfile: the uvicorn CMD carries --no-proxy-headers, so uvicorn never
     rewrites the TCP peer from X-Forwarded-For and the trusted-peer rule in
     get_client_ip cannot silently diverge from the image.
  2. get_client_ip end to end through the app: a real request from the trusted
     test peer is rate-limited per cf-connecting-ip; the pure-function matrix
     (untrusted peer, malformed header, X-Real-IP, client None) lives in
     test_security_hardening.py section 5.
  3. WebSocket: disconnect(user_id, ws) is identity-aware (unit with fakes and
     end to end through the real route: a second socket for the same user stays
     registered and receives a frame after the first one ends); the replaced
     socket is never closed; evict_suspended closes only suspended users with
     code 1008, ignores junk ids, never raises on a DB error; the heartbeat
     loop calls it.
  4. public_guard: run_public before configure raises; configure rejects bad
     values and conflicting re-configure; against a REAL uvicorn server, 30
     concurrent slow public calls -> only concurrency+max_waiting run, the rest
     are shed with 429 busy + Retry-After quickly, no 5xx ever, while
     GET /app/capabilities and a WebSocket echo each finish within 1 s; a
     statement timeout maps to 429 busy, is counted, and is reported as exactly
     ONE aggregated WARNING (never ERROR, no per-request line); the key-less
     global limiter is shared across client IPs and cleared by reset_for_tests.
  5. verify_password / auth: Apple/Google-created accounts (empty hash_pass)
     get 401 from /login and /auth/mfa/disable (never 500) with no ERROR line;
     the wrong-password body is identical for empty-hash and real-hash
     accounts; the correct password still works.
  6. R-SCHED / R-ROUTE grep checks for the SF jobs and routes, and no bare word
     ERROR inside SF's INFO/WARNING log text.

Every database touch is against the scratch database: the test asserts
SHOW port = 55432 first and aborts otherwise.

Run with: cd api && ../.venv/bin/python tests/test_shared_foundation_backend_c.py
"""
import _pathfix  # noqa: F401

import asyncio
import inspect
import json
import logging
import os
import re
import socket
import sys
import threading
import time
import urllib.request
import uuid
import urllib.error

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi import FastAPI, HTTPException, Request  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.auth.passwords import verify_password  # noqa: E402
from backend import public_guard  # noqa: E402
from backend.observability import feature_summary  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
import backend.interactions.websockets as ws_module  # noqa: E402

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(API_DIR)
PASSED, FAILED = [], []


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


def q(sql, params=(), fetch=True):
    db = DBManager()
    try:
        db.cur.execute(sql, params)
        rows = db.cur.fetchall() if fetch and db.cur.description else None
        db.conn.commit()
        return rows
    finally:
        db.close()


def make_user(suspended=False, hash_pass="x"):
    uid = str(uuid.uuid4())
    q("INSERT INTO users (_id, username, email, hash_pass, suspended_at) VALUES (%s,%s,%s,%s,%s)",
      (uid, f"sfc_{uid[:8]}", f"sfc_{uid[:8]}@example.com", hash_pass,
       "2020-01-01" if suspended else None), fetch=False)
    return uid


def session_cookie(uid):
    sm = SessionManager()
    try:
        return sm.create_session(uid)
    finally:
        sm.close()


def drop_users(uids):
    for u in uids:
        q("DELETE FROM messages WHERE from_user = %s", (u,), fetch=False)
        q("DELETE FROM sessions WHERE user_id = %s", (u,), fetch=False) if _has_sessions_table() else None
        q("DELETE FROM users WHERE _id = %s", (u,), fetch=False)


_SESS = None


def _has_sessions_table():
    global _SESS
    if _SESS is None:
        _SESS = bool(q("SELECT 1 FROM information_schema.columns WHERE table_name='sessions' AND column_name='user_id'"))
    return _SESS


class LogCatcher(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.records = []

    def emit(self, record):
        self.records.append((record.levelname, record.name, record.getMessage()))


def catching(name=""):
    h = LogCatcher()
    lg = logging.getLogger(name)
    lg.addHandler(h)
    return lg, h


class FakeWS:
    def __init__(self):
        self.closed_code = None
        self.sent = []

    async def accept(self):
        pass

    async def send_json(self, data):
        self.sent.append(data)

    async def close(self, code=1000):
        self.closed_code = code


# ── 1. Dockerfile ─────────────────────────────────────────────────────────────

def test_dockerfile():
    print("Dockerfile")
    text = open(os.path.join(REPO_DIR, "Dockerfile")).read()
    cmds = [ln for ln in text.splitlines() if ln.strip().startswith("CMD")]
    check("exactly one CMD", len(cmds) == 1, cmds)
    cmd = cmds[0] if cmds else ""
    check("CMD runs uvicorn main:app", '"uvicorn"' in cmd and '"main:app"' in cmd, cmd)
    check("CMD carries --no-proxy-headers (code and image cannot diverge)",
          '"--no-proxy-headers"' in cmd, cmd)
    check("CMD still binds --host 0.0.0.0 (untouched)", '"--host", "0.0.0.0"' in cmd, cmd)
    check("single uvicorn worker (in-process flag cache and limiters assume it)",
          "--workers" not in cmd, cmd)
    conf = os.path.join(REPO_DIR, "ops", "nginx", "real-ip.conf")
    check("ops/nginx/real-ip.conf is prepared", os.path.isfile(conf))


# ── 2. get_client_ip through the app ─────────────────────────────────────────

def test_client_ip_rate_limit_key():
    print("client ip as rate-limit key (through the app)")
    from backend.rate_limiting import get_client_ip
    app = FastAPI()
    app.state.limiter = limiter
    from slowapi.errors import RateLimitExceeded
    from slowapi import _rate_limit_exceeded_handler
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    @app.get("/ip")
    @limiter.limit("3/minute")
    def ip(request: Request):
        return {"ip": get_client_ip(request)}

    limiter.reset()
    with TestClient(app) as c:
        a = [c.get("/ip", headers={"cf-connecting-ip": "203.0.113.50"}).status_code for _ in range(4)]
        b = c.get("/ip", headers={"cf-connecting-ip": "203.0.113.51"}).status_code
        check("same visitor is limited on the 4th call", a == [200, 200, 200, 429], a)
        check("a different visitor behind the same peer is not limited", b == 200, b)
        r = c.get("/ip", headers={"cf-connecting-ip": "not-an-ip"})
        check("malformed header falls back to the peer, request still served", r.status_code == 200
              and r.json()["ip"] == "testclient", r.text)
    limiter.reset()


# ── 3. WebSocket identity + evict_suspended ──────────────────────────────────

async def _unit_disconnect():
    mgr = ConnectionManager()
    try:
        uid = str(uuid.uuid4())
        a, b = FakeWS(), FakeWS()
        await mgr.connect(uid, a)
        await mgr.connect(uid, b)  # B replaces A
        check("replaced socket A is NOT closed", a.closed_code is None, a.closed_code)
        await mgr.disconnect(uid, a)  # A's receive loop ends
        check("A ending leaves B registered", mgr.active_connections.get(uid) is b)
        check("A ending leaves B's last_seen", uid in mgr.last_seen)
        await mgr.disconnect(uid, FakeWS())
        check("a stranger socket does not evict B", mgr.active_connections.get(uid) is b)
        await mgr.disconnect(uid, b)
        check("B ending removes the entry and last_seen",
              uid not in mgr.active_connections and uid not in mgr.last_seen)
        await mgr.connect(uid, a)
        await mgr.disconnect(uid)
        check("disconnect without a socket keeps the unconditional removal", uid not in mgr.active_connections)
        await mgr.disconnect(uid, a)
        check("disconnect for an unknown user never raises", True)
    finally:
        mgr.close()


async def _unit_evict():
    mgr = ConnectionManager()
    try:
        sus, ok = make_user(suspended=True), make_user()
        wa, wb, wj = FakeWS(), FakeWS(), FakeWS()
        mgr.active_connections.clear()
        for uid, w in ((sus, wa), (ok, wb), ("not-a-uuid", wj)):
            await mgr.connect(uid, w)
        await mgr.evict_suspended()
        check("suspended user's socket closed with 1008", wa.closed_code == 1008, wa.closed_code)
        check("suspended user unregistered", sus not in mgr.active_connections and sus not in mgr.last_seen)
        check("non-suspended user untouched", wb.closed_code is None and mgr.active_connections.get(ok) is wb)
        check("junk id ignored without error", wj.closed_code is None and "not-a-uuid" in mgr.active_connections)

        mgr.active_connections.clear()
        await mgr.connect(sus, FakeWS())

        def boom(ids):
            raise RuntimeError("db down")
        original = mgr._suspended_user_ids
        mgr._suspended_user_ids = boom
        lg, h = catching("backend.interactions.websockets")
        try:
            await mgr.evict_suspended()
            check("DB failure never raises", True)
            check("DB failure logs WARNING not ERROR",
                  h.records and all(r[0] == "WARNING" for r in h.records), h.records)
            check("DB failure keeps the socket for the next tick", sus in mgr.active_connections)
        finally:
            lg.removeHandler(h)
            mgr._suspended_user_ids = original
        empty = ConnectionManager.__new__(ConnectionManager)
        empty.active_connections = {}
        await ConnectionManager.evict_suspended(empty)
        check("no sockets -> returns without a DB call", True)
        drop_users([sus, ok])
    finally:
        mgr.close()


def test_websocket_units():
    print("websocket manager")
    asyncio.run(_unit_disconnect())
    asyncio.run(_unit_evict())
    src = inspect.getsource(ConnectionManager._heartbeat_loop)
    check("heartbeat loop calls evict_suspended", "evict_suspended" in src)
    check("heartbeat loop rate-limits it (once per minute)",
          "SUSPEND_CHECK_INTERVAL" in src and ConnectionManager.SUSPEND_CHECK_INTERVAL == 60,
          ConnectionManager.SUSPEND_CHECK_INTERVAL)
    msrc = open(os.path.join(API_DIR, "routes", "messaging.py")).read()
    check("route passes the socket to disconnect", "manager.disconnect(user_id, websocket)" in msrc)


def test_websocket_identity_end_to_end(client):
    print("websocket identity end to end (real route)")
    from routes.messaging import manager
    uid, other = make_user(), make_user()
    # Setup: the main-chat send guard requires friendship for a DM.
    q("INSERT INTO user_friends (user_id, friend_id) VALUES (%s, %s), (%s, %s) ON CONFLICT DO NOTHING",
      (uid, other, other, uid), fetch=False)
    hdr = lambda u: {"cookie": f"session={session_cookie(u)}"}  # noqa: E731
    try:
        with client.websocket_connect(f"/message/ws/{uid}", headers=hdr(uid)) as ws_a:
            ws_a.send_json({"type": "pong"})
            deadline = time.time() + 3
            while uid not in manager.active_connections and time.time() < deadline:
                time.sleep(0.02)
            server_a = manager.active_connections.get(uid)
            check("A registered", server_a is not None)
            with client.websocket_connect(f"/message/ws/{uid}", headers=hdr(uid)) as ws_b:
                ws_b.send_json({"type": "pong"})
                deadline = time.time() + 3
                while manager.active_connections.get(uid) is server_a and time.time() < deadline:
                    time.sleep(0.02)
                server_b = manager.active_connections.get(uid)
                check("B replaced A in the registry", server_b is not None and server_b is not server_a)
                ws_a.close()
                time.sleep(0.6)  # A's finally-block disconnect(uid, A) runs
                check("A ending leaves B registered (the build-78 flap bug)",
                      manager.active_connections.get(uid) is server_b)
                got = {}

                def recv():
                    try:
                        got["frame"] = ws_b.receive_json()
                    except Exception as e:  # noqa: BLE001
                        got["err"] = repr(e)

                t = threading.Thread(target=recv, daemon=True)
                t.start()
                text = f"sfc-{uuid.uuid4().hex[:8]}"
                with client.websocket_connect(f"/message/ws/{other}", headers=hdr(other)) as ws_c:
                    ws_c.send_json({"to_users": [uid], "text": text, "group_id": None,
                                    "timestamp": "2026-10-02T00:00:00+00:00"})
                    t.join(5)
                check("B still receives frames after A ended",
                      got.get("frame", {}).get("text") == text, got)
    finally:
        drop_users([uid, other])


# ── 4. public_guard ──────────────────────────────────────────────────────────

def _slow(seconds):
    time.sleep(seconds)
    return "done"


def test_public_guard_units():
    print("public_guard (units)")
    public_guard.reset_for_tests()
    try:
        asyncio.run(public_guard.run_public(_slow, 0))
        check("run_public before configure raises RuntimeError", False, "no exception")
    except RuntimeError:
        check("run_public before configure raises RuntimeError", True)
    for bad in ((0, 1), (1, -1), (True, 1), ("2", 1), (2, 1.5)):
        try:
            public_guard.configure(*bad)
            check(f"configure{bad} rejected", False)
        except ValueError:
            check(f"configure{bad} rejected", True)
    public_guard.configure(2, 3)
    public_guard.configure(2, 3)
    check("same-value re-configure is a no-op", True)
    try:
        public_guard.configure(3, 3)
        check("different-value re-configure raises", False)
    except RuntimeError:
        check("different-value re-configure raises", True)
    check("run_public works once configured", asyncio.run(public_guard.run_public(_slow, 0)) == "done")

    # Statement timeout inside run_public -> 429 busy, counted, one aggregate WARNING.
    public_guard.reset_for_tests()
    public_guard.configure(2, 3)
    feature_summary.snapshot_and_reset()

    def timing_out():
        with public_guard.public_connection(50) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT pg_sleep(2)")

    def one():
        try:
            asyncio.run(public_guard.run_public(timing_out))
            return None
        except HTTPException as e:
            return e

    lg, h = catching("")
    try:
        t0 = time.time()
        errs = [one() for _ in range(3)]
        elapsed = time.time() - t0
    finally:
        logging.getLogger("").removeHandler(h)
    check("statement timeout maps to 429", all(e is not None and e.status_code == 429 for e in errs), errs)
    check("timeout body is {'code': 'busy'}", all(e.detail == {"code": "busy"} for e in errs if e))
    check("timeout carries Retry-After 1-5", all(e.headers.get("Retry-After") in {"1", "2", "3", "4", "5"} for e in errs if e))
    check("the 50 ms timeout fired (not the 2 s sleep)", elapsed < 3, elapsed)
    snap = feature_summary.snapshot_and_reset()
    check("public_timeout and public_429 counters incremented", snap.get("public_timeout") == 3
          and snap.get("public_429") == 3, snap)
    check("no log line at all inside the window (no per-request line)",
          not [r for r in h.records if r[1] == "backend.public_guard"], h.records)
    public_guard._timeout_window_start -= 61  # a full minute has passed
    lg, h2 = catching("")
    try:
        public_guard._maybe_report_timeouts()
        public_guard._maybe_report_timeouts()
    finally:
        logging.getLogger("").removeHandler(h2)
    pg = [r for r in h2.records if r[1] == "backend.public_guard"]
    check("exactly ONE aggregated WARNING with the count", len(pg) == 1 and pg[0][0] == "WARNING"
          and "3" in pg[0][2], pg)
    check("no ERROR line", not [r for r in h2.records if r[0] == "ERROR"], h2.records)
    check("aggregate message avoids the bare word ERROR", "error" not in pg[0][2].lower() if pg else False, pg)

    # Key-less global limiter.
    public_guard.reset_for_tests()
    app = FastAPI()
    app.state.limiter = limiter
    from slowapi.errors import RateLimitExceeded
    from slowapi import _rate_limit_exceeded_handler
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    @app.get("/g")
    @public_guard.global_limit("2/minute")
    def g(request: Request):
        return {"ok": True}

    with TestClient(app) as c:
        codes = [c.get("/g", headers={"cf-connecting-ip": f"203.0.113.{i}"}).status_code for i in range(1, 4)]
        check("global limit ignores the client ip (3rd distinct visitor limited)", codes == [200, 200, 429], codes)
        public_guard.reset_for_tests()
        after = c.get("/g", headers={"cf-connecting-ip": "203.0.113.9"}).status_code
        check("reset_for_tests clears the global limiter", after == 200, after)
    public_guard.reset_for_tests()


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def test_public_guard_under_load():
    print("public_guard under load (real uvicorn server)")
    import uvicorn
    from websockets.sync.client import connect as ws_connect

    # A minimal app wired with the REAL capabilities router: main.app's lifespan
    # starts the process-wide scheduler singleton, which cannot be started a
    # second time after the TestClient sections have closed their loop.
    from routes.app_capabilities import capabilities_router
    app = FastAPI()
    app.state.limiter = limiter
    app.include_router(capabilities_router)

    async def slow_public(request: Request):
        return {"v": await public_guard.run_public(_slow, 2.0)}

    from fastapi import WebSocket

    async def echo(websocket: WebSocket):
        await websocket.accept()
        while True:
            try:
                data = await websocket.receive_text()
            except Exception:  # noqa: BLE001
                return
            await websocket.send_text(data)

    app.add_api_route("/_sf_test/slow", slow_public, methods=["GET"])
    app.add_api_websocket_route("/_sf_test/echo", echo)

    public_guard.reset_for_tests()
    public_guard.configure(2, 3)
    uid = make_user()
    cookie = session_cookie(uid)
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    server.install_signal_handlers = lambda: None
    th = threading.Thread(target=server.run, daemon=True)
    th.start()
    deadline = time.time() + 30
    while not server.started and time.time() < deadline:
        time.sleep(0.05)
    check("server started", server.started)
    base = f"http://127.0.0.1:{port}"
    results, lock = [], threading.Lock()

    def call():
        t0 = time.time()
        try:
            with urllib.request.urlopen(base + "/_sf_test/slow", timeout=30) as r:
                rec = (r.status, dict(r.headers), r.read().decode(), time.time() - t0)
        except urllib.error.HTTPError as e:
            rec = (e.code, dict(e.headers), e.read().decode(), time.time() - t0)
        with lock:
            results.append(rec)

    try:
        threads = [threading.Thread(target=call) for _ in range(30)]
        for t in threads:
            t.start()
        time.sleep(0.5)  # admitted calls are now sleeping on the dedicated limiter

        t0 = time.time()
        req = urllib.request.Request(base + "/app/capabilities", headers={"Cookie": f"session={cookie}"})
        with urllib.request.urlopen(req, timeout=10) as r:
            cap_status, cap_body = r.status, json.loads(r.read())
        cap_elapsed = time.time() - t0
        check("GET /app/capabilities answers 200 while the public pool is saturated",
              cap_status == 200 and cap_body.get("v") == 1, (cap_status, cap_body))
        check("capabilities completes within 1 s under load", cap_elapsed < 1.0, cap_elapsed)

        t0 = time.time()
        with ws_connect(f"ws://127.0.0.1:{port}/_sf_test/echo", open_timeout=5) as ws:
            ws.send("ping-sfc")
            echoed = ws.recv(timeout=5)
        ws_elapsed = time.time() - t0
        check("WebSocket echo returns the frame", echoed == "ping-sfc", echoed)
        check("WebSocket echo completes within 1 s under load", ws_elapsed < 1.0, ws_elapsed)

        for t in threads:
            t.join(40)
        statuses = sorted(r[0] for r in results)
        check("all 30 calls completed", len(results) == 30, len(results))
        check("no 5xx status ever appears", not [s for s in statuses if s >= 500], statuses)
        ok = [r for r in results if r[0] == 200]
        shed = [r for r in results if r[0] == 429]
        check("concurrency 2 + max_waiting 3 -> exactly 5 admitted", len(ok) == 5, statuses)
        check("the other 25 are shed with 429", len(shed) == 25, statuses)
        check("every 429 says busy", all('"busy"' in r[2] for r in shed), [r[2] for r in shed][:2])
        check("every 429 carries Retry-After 1-5",
              all(r[1].get("retry-after", r[1].get("Retry-After")) in {"1", "2", "3", "4", "5"} for r in shed),
              [r[1] for r in shed][:2])
        check("shed calls return quickly (< 1 s, not after the 2 s work)",
              all(r[3] < 1.0 for r in shed), sorted(round(r[3], 2) for r in shed)[-3:])
        feature_summary.snapshot_and_reset()
    finally:
        server.should_exit = True
        th.join(20)
        public_guard.reset_for_tests()
        drop_users([uid])
    check("server stopped cleanly", not th.is_alive())


# ── 5. password helper and auth routes ───────────────────────────────────────

def test_verify_password_unit():
    print("verify_password (unit)")
    import bcrypt
    good = bcrypt.hashpw(b"correct horse", bcrypt.gensalt(4)).decode()
    check("correct password", verify_password("correct horse", good) is True)
    check("wrong password", verify_password("nope", good) is False)
    for label, bad in (("empty hash", ""), ("None hash", None), ("junk hash", "not-a-bcrypt-hash"),
                       ("bytes hash", b"x"), ("truncated hash", good[:20])):
        try:
            check(f"{label} -> False, no exception", verify_password("x", bad) is False)
        except Exception as e:  # noqa: BLE001
            check(f"{label} -> False, no exception", False, repr(e))
    lg, h = catching("")
    try:
        verify_password("secret-plain", "")
    finally:
        logging.getLogger("").removeHandler(h)
    check("never logs", not h.records, h.records)


def test_auth_routes(client):
    print("/login and /auth/mfa/disable with empty-hash accounts")
    limiter.reset()
    apple = make_user(hash_pass="")        # Apple/Google-created account
    uname = f"sfc_real_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={"username": uname, "email": f"{uname}@example.com",
                                     "plain_pass": "TestPass123!", "terms_accepted": True})
    check("setup: signup of a password account", r.status_code == 201, r.status_code)
    real_uid = r.json()["user_id"]
    apple_user = q("SELECT username FROM users WHERE _id=%s", (apple,))[0][0]
    lg, h = catching("")
    try:
        r_apple = client.post("/login", json={"username": apple_user, "plain_pass": "anything"})
        r_wrong = client.post("/login", json={"username": uname, "plain_pass": "WrongPass999!"})
        r_empty_pw = client.post("/login", json={"username": apple_user, "plain_pass": ""})
        cookie = {"session": session_cookie(apple)}
        r_mfa = client.post("/auth/mfa/disable", json={"plain_pass": "anything"}, cookies=cookie)
        r_mfa_empty = client.post("/auth/mfa/disable", json={"plain_pass": ""}, cookies=cookie)
    finally:
        logging.getLogger("").removeHandler(h)
    check("Apple-created account /login -> 401 (not 500)", r_apple.status_code == 401, r_apple.status_code)
    check("empty plain_pass on empty-hash account -> 401", r_empty_pw.status_code == 401, r_empty_pw.status_code)
    check("wrong-password body identical for empty-hash and real-hash accounts",
          r_apple.status_code == r_wrong.status_code == 401 and r_apple.json() == r_wrong.json(),
          (r_apple.text, r_wrong.text))
    check("body is the generic 'Incorrect password'", r_apple.json() == {"detail": "Incorrect password"}, r_apple.text)
    check("/auth/mfa/disable on empty-hash account -> 401 not 500", r_mfa.status_code == 401, r_mfa.status_code)
    check("/auth/mfa/disable with empty plain_pass -> 401", r_mfa_empty.status_code == 401, r_mfa_empty.status_code)
    check("mfa/disable body identical to login's", r_mfa.json() == r_apple.json(), r_mfa.text)
    check("no ERROR line from any of those calls", not [x for x in h.records if x[0] == "ERROR"],
          [x for x in h.records if x[0] == "ERROR"])
    r_ok = client.post("/login", json={"username": uname, "plain_pass": "TestPass123!"})
    check("correct password still logs in", r_ok.status_code == 200, r_ok.status_code)
    real_cookie = {"session": r_ok.cookies.get("session") or session_cookie(real_uid)}
    r_bad_mfa = client.post("/auth/mfa/disable", json={"plain_pass": "WrongPass999!"}, cookies=real_cookie)
    check("mfa/disable wrong password -> 401", r_bad_mfa.status_code == 401, r_bad_mfa.status_code)
    r_ok_mfa = client.post("/auth/mfa/disable", json={"plain_pass": "TestPass123!"}, cookies=real_cookie)
    check("mfa/disable correct password -> 200", r_ok_mfa.status_code == 200
          and r_ok_mfa.json().get("mfa_enabled") is False, (r_ok_mfa.status_code, r_ok_mfa.text))
    r_gone = client.post("/login", json={"username": f"nobody_{uuid.uuid4().hex[:8]}", "plain_pass": "x"})
    check("unknown username unchanged (404)", r_gone.status_code == 404, r_gone.status_code)
    client.delete(f"/user/{real_uid}", cookies=real_cookie)
    drop_users([apple, real_uid])
    limiter.reset()


# ── 6. R-SCHED / R-ROUTE greps ───────────────────────────────────────────────

def test_rsched_rroute():
    print("R-SCHED / R-ROUTE")
    from backend.interactions import s3_outbox
    for name, fn in (("run_s3_outbox_job", s3_outbox.run_s3_outbox_job),
                     ("run_feature_summary_job", feature_summary.run_feature_summary_job)):
        check(f"{name} is async def", inspect.iscoroutinefunction(fn))
        src = inspect.getsource(fn)
        check(f"{name} runs sync work via run_in_executor", "run_in_executor(None" in src, src)
        check(f"{name} contains no psycopg2/boto3/cursor call itself",
              not re.search(r"psycopg2|boto3|\.cur\b|cursor\(|s3_client|DBManager", src), src)
    sched = open(os.path.join(API_DIR, "backend", "interactions", "scheduler.py")).read()
    for jid in ("s3_outbox_flush", "feature_summary"):
        m = re.search(r"scheduler\.add_job\([^)]*id=\"%s\"[^)]*\)" % jid, sched, re.S)
        check(f"job {jid} registered with replace_existing=True", bool(m and "replace_existing=True" in m.group(0)))
    check("outbox flush interval is 60 s", s3_outbox.FLUSH_INTERVAL_SECONDS == 60, s3_outbox.FLUSH_INTERVAL_SECONDS)
    for rel in ("routes/app_capabilities.py", "routes/flags_admin.py"):
        src = open(os.path.join(API_DIR, rel)).read()
        check(f"{rel}: no async def route (R-ROUTE)", "async def" not in src)
    from routes import app_capabilities, flags_admin
    for r in list(app_capabilities.capabilities_router.routes) + list(flags_admin.flags_admin_router.routes):
        check(f"route {r.path} endpoint is a plain def", not inspect.iscoroutinefunction(r.endpoint))
    # No bare ERROR inside INFO/WARNING text of SF modules (watchdog rule).
    files = ["backend/interactions/s3_outbox.py", "backend/interactions/lifecycle.py",
             "backend/interactions/flags.py", "backend/public_guard.py",
             "backend/observability/feature_summary.py", "backend/interactions/websockets.py",
             "routes/flags_admin.py", "routes/app_capabilities.py", "backend/config_loader.py",
             "backend/startup_checks.py"]
    bad = []
    for rel in files:
        path = os.path.join(API_DIR, rel)
        if not os.path.exists(path):
            continue
        src = open(path).read()
        for m in re.finditer(r"logger\.(info|warning)\(\s*((?:f?\"[^\"]*\"\s*)+)", src):
            if re.search(r"\bERROR\b", m.group(2)):
                bad.append((rel, m.group(2)[:80]))
    check("no bare word ERROR in SF INFO/WARNING log text", not bad, bad)


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    db = DBManager()
    db.cur.execute("SHOW port")
    port = db.cur.fetchone()[0]
    db.close()
    check("tests run against scratch DB port 55432", (port == "55432" or (port == "5432" and __import__("os").environ.get("GITHUB_ACTIONS") == "true")), port)
    if not (port == "55432" or (port == "5432" and __import__("os").environ.get("GITHUB_ACTIONS") == "true")):
        raise SystemExit("refusing to continue: not the scratch database")
    test_dockerfile()
    test_verify_password_unit()
    test_rsched_rroute()
    test_public_guard_units()
    test_websocket_units()
    test_client_ip_rate_limit_key()
    with TestClient(main_module.app) as client:
        test_auth_routes(client)
        test_websocket_identity_end_to_end(client)
    test_public_guard_under_load()

    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
