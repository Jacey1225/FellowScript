"""Integration test for task 20261008-admin-require-2fa.

require_admin 403s an admin whose mfa_enabled is not True with the structured
detail {"code": "mfa_required", ...}; /auth/mfa/disable refuses admins.

Run:  cd api && ../.venv/bin/python tests/test_admin_require_2fa.py
"""

import _pathfix  # noqa: F401

import logging
import uuid

from fastapi.testclient import TestClient

import main as main_module
from db import DBManager
from backend.auth.sessions import SessionManager
from backend.auth.dependencies import SESSION_COOKIE

client = TestClient(main_module.app)
PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []
USERS = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


def make_user(is_admin, mfa, password="pw-test-123"):
    uid = str(uuid.uuid4())
    hashed = main_module.hash_password(password) if hasattr(main_module, "hash_password") else None
    if hashed is None:
        import bcrypt
        hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    dbm = DBManager()
    try:
        dbm.insertion("users", {
            "_id": uid, "username": f"a2fa_{uid[:8]}", "email": f"a2fa_{uid[:8]}@example.com",
            "hash_pass": hashed, "is_admin": is_admin, "mfa_enabled": mfa,
        })
    finally:
        dbm.close()
    USERS.append(uid)
    return uid


def session(uid):
    sm = SessionManager()
    try:
        return sm.create_session(uid)
    finally:
        sm.close()


def set_mfa(uid, value):
    dbm = DBManager()
    try:
        dbm.update("users", {"mfa_enabled": value}, {"_id": uid})
    finally:
        dbm.close()


def get(path, token):
    client.cookies.clear()
    return client.get(path, cookies={SESSION_COOKIE: token})


def mfa_enabled(uid):
    dbm = DBManager()
    try:
        dbm.cur.execute("SELECT mfa_enabled FROM users WHERE _id=%s", (uid,))
        return dbm.cur.fetchone()[0]
    finally:
        dbm.close()


class Cap(logging.Handler):
    def __init__(self):
        super().__init__()
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


def main():
    admin_no = make_user(True, False)
    admin_ok = make_user(True, True)
    plain = make_user(False, False)
    plain_mfa = make_user(False, True)
    t_no, t_ok, t_plain, t_plain_mfa = map(session, (admin_no, admin_ok, plain, plain_mfa))
    cap = Cap()
    dep_logger = logging.getLogger("backend.auth.dependencies")
    dep_logger.addHandler(cap)
    try:
        # Representative require_admin endpoints.
        for path in ("/admin/users", "/admin/home-messages"):
            print(f"\n-- {path}")
            r = get(path, t_no)
            check("admin without MFA -> 403", r.status_code, 403)
            check("detail.code is mfa_required", (r.json().get("detail") or {}).get("code"), "mfa_required")
            r = get(path, t_ok)
            check("admin with MFA -> 200", r.status_code, 200)
            r = get(path, t_plain)
            check("non-admin -> plain 403", (r.status_code, r.json().get("detail")), (403, "Admin access required"))
            r = get(path, t_plain_mfa)
            check("non-admin with MFA -> plain 403", (r.status_code, r.json().get("detail")), (403, "Admin access required"))
            check("unauthenticated -> 401", client.get(path, cookies={}).status_code, 401)

        print("\n-- per-request (no caching)")
        set_mfa(admin_ok, False)
        check("disabling flips to 403 immediately", get("/admin/users", t_ok).status_code, 403)
        set_mfa(admin_ok, True)
        check("re-enabling restores access immediately", get("/admin/users", t_ok).status_code, 200)

        print("\n-- log redaction")
        denial = [l for l in cap.lines if "mfa_required" in l]
        check("denials logged", len(denial) > 0, True)
        check("log carries user_id only (no cookie/token)", any(t_no in l for l in cap.lines), False)

        print("\n-- /auth/mfa/disable")
        client.cookies.clear()
        r = client.post("/auth/mfa/disable", json={"plain_pass": "pw-test-123"}, cookies={SESSION_COOKIE: t_ok})
        check("admin disable refused (403)", r.status_code, 403)
        check("admin mfa still enabled", mfa_enabled(admin_ok), True)
        r = client.post("/auth/mfa/disable", json={"plain_pass": "wrong"}, cookies={SESSION_COOKIE: t_ok})
        check("admin refused before password check", r.status_code, 403)
        r = client.post("/auth/mfa/disable", json={"plain_pass": "pw-test-123"}, cookies={SESSION_COOKIE: t_plain_mfa})
        check("non-admin disable still works", (r.status_code, r.json()), (200, {"mfa_enabled": False}))
        check("non-admin mfa now off", mfa_enabled(plain_mfa), False)
        r = client.post("/auth/mfa/disable", json={"plain_pass": "wrong"}, cookies={SESSION_COOKIE: t_plain})
        check("non-admin wrong password still 401", r.status_code, 401)
    finally:
        dep_logger.removeHandler(cap)
        dbm = DBManager()
        try:
            for u in USERS:
                dbm.delete("users", {"_id": u})
        finally:
            dbm.close()
    print(f"\n{sum(results)}/{len(results)} passed")
    raise SystemExit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
