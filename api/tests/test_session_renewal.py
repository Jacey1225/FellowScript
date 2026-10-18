"""Sliding session renewal, 90-day hard cap, purge job, and invalidation.

Task 20261017-chat-ws-reconnect-stuck. Covers: sliding expiry on REST use,
Set-Cookie re-issue with the renewed lifetime, the hard cap from created_at,
expired-session non-revival (REST and websocket), the websocket NOT renewing,
the scheduled purge, login cookie max_age deriving from SESSION_TTL_SECONDS,
and logout / password-reset invalidation.

Scratch database only: locally refuses any connection to port 5432 (dev DB);
CI runs its Postgres service container on 5432 (GITHUB_ACTIONS=true).
Run with: cd api && ../.venv/bin/python tests/test_session_renewal.py
"""
import asyncio
import os
import sys
import uuid

import _pathfix  # noqa: F401,E402

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import psycopg2  # noqa: E402
from psycopg2 import extensions as _pgext  # noqa: E402

_IN_CI = os.environ.get("GITHUB_ACTIONS") == "true"
_real_connect = psycopg2._connect


def _guarded_connect(dsn, *a, **k):
    port = str(_pgext.parse_dsn(dsn).get("port", "5432"))
    if port == "5432" and not _IN_CI:
        raise RuntimeError("test guard: refusing to connect to port 5432 (dev DB)")
    return _real_connect(dsn, *a, **k)


psycopg2._connect = _guarded_connect

from fastapi.testclient import TestClient  # noqa: E402
from starlette.websockets import WebSocketDisconnect  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth import sessions as sess  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.auth.password_reset import PasswordResetManager  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402

PASSED, FAILED = [], []
DAY = 86400


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


def sql(query, params=()):
    d = DBManager()
    try:
        d.cur.execute(query, params)
        rows = d.cur.fetchall() if d.cur.description else None
        d.conn.commit()
        return rows
    finally:
        d.close()


def remaining(token):
    """Seconds until the session row expires (negative if expired), None if row gone."""
    rows = sql("SELECT EXTRACT(EPOCH FROM (expires_at - NOW())) FROM sessions WHERE token_hash = %s",
               (sess._hash_token(token),))
    return float(rows[0][0]) if rows else None


def set_times(token, created_days_ago, expires_in_days):
    sql("UPDATE sessions SET created_at = NOW() - make_interval(secs => %s),"
        " expires_at = NOW() + make_interval(secs => %s) WHERE token_hash = %s",
        (created_days_ago * DAY, expires_in_days * DAY, sess._hash_token(token)))


def new_session(uid):
    sm = SessionManager()
    try:
        return sm.create_session(uid)
    finally:
        sm.close()


def cookie(token):
    return {"cookie": f"session={token}"}


def max_age_of(resp):
    """Max-Age of the session Set-Cookie on this response, or None if absent."""
    for h in resp.headers.get_list("set-cookie"):
        if h.startswith("session="):
            for part in h.split(";"):
                if part.strip().lower().startswith("max-age="):
                    return int(part.split("=")[1])
    return None


def main():
    port = sql("SHOW port")[0][0]
    if not (port == "55432" or (port == "5432" and _IN_CI)):
        raise SystemExit(f"refusing to continue: not the scratch database (port {port})")
    print(f"  OK   running against scratch DB port {port}")

    uids = []
    with TestClient(main_module.app) as client:
        name = f"sr_{uuid.uuid4().hex[:8]}"
        r = client.post("/signup", json={"username": name, "email": f"{name}@example.com",
                                         "plain_pass": "TestPass123!", "terms_accepted": True})
        assert r.status_code == 201, r.text
        uid = r.json()["user_id"]
        uids.append(uid)
        tok0 = r.cookies.get("session")

        try:
            print("=== constants and login cookie ===")
            check("SESSION_TTL_SECONDS derives from SESSION_TTL_DAYS", sess.SESSION_TTL_SECONDS == sess.SESSION_TTL_DAYS * DAY)
            check("hard cap default is 90 days", sess.SESSION_MAX_AGE_DAYS == 90)
            check("signup cookie max_age == SESSION_TTL_SECONDS", max_age_of(r) == sess.SESSION_TTL_SECONDS, str(max_age_of(r)))
            lr = client.post("/login", json={"username": name, "plain_pass": "TestPass123!"})
            check("login cookie max_age == SESSION_TTL_SECONDS", max_age_of(lr) == sess.SESSION_TTL_SECONDS, str(max_age_of(lr)))
            tok = lr.cookies.get("session")

            print("=== sliding renewal + cookie re-issue ===")
            r1 = client.get(f"/user/{uid}", headers=cookie(tok))
            check("fresh session: authenticated request 200", r1.status_code == 200, str(r1.status_code))
            check("fresh session: throttled, no Set-Cookie", max_age_of(r1) is None, str(max_age_of(r1)))

            set_times(tok, created_days_ago=10, expires_in_days=5)  # 20 days of life used
            r2 = client.get(f"/user/{uid}", headers=cookie(tok))
            rem = remaining(tok)
            check("sliding: expiry pushed back to ~30 days", r2.status_code == 200 and abs(rem - 30 * DAY) < 300, str(rem))
            ma = max_age_of(r2)
            check("sliding: Set-Cookie re-issued", ma is not None)
            check("sliding: cookie max_age == renewed remaining lifetime (never beyond row)",
                  ma is not None and abs(ma - rem) < 300 and ma <= rem + 5, f"{ma} vs {rem}")

            print("=== hard cap ===")
            set_times(tok, created_days_ago=80, expires_in_days=1)
            r3 = client.get(f"/user/{uid}", headers=cookie(tok))
            rem = remaining(tok)
            check("cap: expiry clamped to created_at + 90d (~10d left), not +30d",
                  r3.status_code == 200 and abs(rem - 10 * DAY) < 300, str(rem))
            ma = max_age_of(r3)
            check("cap: cookie max_age clamped to the capped lifetime", ma is not None and abs(ma - 10 * DAY) < 300, str(ma))
            set_times(tok, created_days_ago=89.9, expires_in_days=0.05)
            before = remaining(tok)
            r4 = client.get(f"/user/{uid}", headers=cookie(tok))
            check("cap: at the cap, further use does not extend and still authenticates",
                  r4.status_code == 200 and remaining(tok) <= before + 5 and max_age_of(r4) is None, str(remaining(tok)))
            set_times(tok, created_days_ago=91, expires_in_days=-1)
            r5 = client.get(f"/user/{uid}", headers=cookie(tok))
            check("cap: past the cap session is rejected 401", r5.status_code == 401, str(r5.status_code))

            print("=== expired sessions are never revived ===")
            tok_e = new_session(uid)
            set_times(tok_e, created_days_ago=31, expires_in_days=-1)
            before = remaining(tok_e)
            r6 = client.get(f"/user/{uid}", headers=cookie(tok_e))
            check("expired: REST 401", r6.status_code == 401, str(r6.status_code))
            check("expired: no Set-Cookie on rejection", max_age_of(r6) is None)
            check("expired: row expiry untouched", abs(remaining(tok_e) - before) < 5, f"{before} -> {remaining(tok_e)}")
            sm = SessionManager()
            try:
                check("expired: renew() returns None and does not extend", sm.renew(tok_e) is None and remaining(tok_e) < 0)
                check("renew(None) / unknown token is a no-op", sm.renew(None) is None and sm.renew("nope-" + uuid.uuid4().hex) is None)
            finally:
                sm.close()
            try:
                with client.websocket_connect(f"/message/ws/{uid}", headers=cookie(tok_e)):
                    check("expired: websocket handshake rejected", False, "connected")
            except WebSocketDisconnect:
                check("expired: websocket handshake rejected", True)
            check("expired: websocket does not revive the row", remaining(tok_e) < 0)

            print("=== websocket does not renew ===")
            tok_w = new_session(uid)
            set_times(tok_w, created_days_ago=10, expires_in_days=5)
            before = remaining(tok_w)
            with client.websocket_connect(f"/message/ws/{uid}", headers=cookie(tok_w)):
                pass
            check("ws: valid handshake accepted and row expiry unchanged",
                  abs(remaining(tok_w) - before) < 5, f"{before} -> {remaining(tok_w)}")

            print("=== purge job ===")
            tok_p = new_session(uid)
            set_times(tok_p, created_days_ago=40, expires_in_days=-10)
            tok_live = new_session(uid)
            asyncio.run(scheduler_module._purge_expired_auth_sessions())
            check("purge: expired row deleted", remaining(tok_p) is None)
            check("purge: live row kept", remaining(tok_live) is not None and remaining(tok_live) > 0)
            check("purge: previously expired rows gone", remaining(tok_e) is None)
            check("purge: job registered with the scheduler",
                  (scheduler_module.start_scheduler(), scheduler_module.scheduler.get_job("session_purge"))[1] is not None
                  if not scheduler_module.scheduler.running else scheduler_module.scheduler.get_job("session_purge") is not None)

            print("=== logout and password-reset invalidation ===")
            tok_lo = new_session(uid)
            check("logout: session valid before", client.get(f"/user/{uid}", headers=cookie(tok_lo)).status_code == 200)
            lo = client.post("/logout", headers=cookie(tok_lo))
            check("logout: 204", lo.status_code == 204, str(lo.status_code))
            check("logout: session now 401", client.get(f"/user/{uid}", headers=cookie(tok_lo)).status_code == 401)
            check("logout: row deleted", remaining(tok_lo) is None)

            ta, tb = new_session(uid), new_session(uid)
            pr = PasswordResetManager()
            try:
                reset_tok = pr.create_token(uid)
            finally:
                pr.close()
            rc = client.post("/auth/password-reset/confirm", json={"token": reset_tok, "new_password": "NewPass456!x"})
            check("password reset confirm: 200", rc.status_code == 200, f"{rc.status_code} {rc.text[:120]}")
            check("password reset: all sessions invalid (401)",
                  client.get(f"/user/{uid}", headers=cookie(ta)).status_code == 401
                  and client.get(f"/user/{uid}", headers=cookie(tb)).status_code == 401)
            check("password reset: renewal did not resurrect them", remaining(ta) is None and remaining(tb) is None)
        finally:
            for u in uids:
                sql("DELETE FROM users WHERE _id = %s", (u,))

    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    for f in FAILED:
        print("  FAILED:", f)
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
