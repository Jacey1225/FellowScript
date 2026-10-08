"""Integration test for task 20261002-admin-user-actions: the require_admin-gated
/admin/users routes (list/search/paginate, grant-admin, revoke-admin), the
self-revoke and last-admin guards (including a concurrent race), the
admin_role_audit trail, the admin seed not re-promoting a revoked admin, and
rate limiting.

Scratch database only (port 55432, or 5432 under GITHUB_ACTIONS=true).
Run:  cd api && ../.venv/bin/python tests/test_admin_users.py
"""
import _pathfix  # noqa: F401

import os
import sys
import threading
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import db as db_module  # noqa: E402
import main as main_module  # noqa: E402
from backend.auth.admin_users import AdminUsersError, AdminUsersManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from db import DBManager  # noqa: E402

PASSED, FAILED = [], []
TAG = uuid.uuid4().hex[:8]
USERS: list[str] = []


def check(label, got, want):
    ok = got == want
    (PASSED if ok else FAILED).append(label)
    print(f"  {'OK  ' if ok else 'FAIL'} {label}" + ("" if ok else f"  -- got {got!r}, want {want!r}"))


def sql(query, params=()):
    d = DBManager()
    try:
        d.cur.execute(query, params)
        rows = d.cur.fetchall() if d.cur.description else None
        d.conn.commit()
        return rows
    finally:
        d.close()


def require_scratch_db():
    port = sql("SHOW port")[0][0]
    if not (port == "55432" or (port == "5432" and os.environ.get("GITHUB_ACTIONS") == "true")):
        raise SystemExit(f"refusing to continue: not the scratch database (port {port})")
    print(f"  OK   running against scratch DB port {port}")


def make_user(label, is_admin=False):
    uid = str(uuid.uuid4())
    sql("INSERT INTO users (_id, username, email, hash_pass, is_admin) VALUES (%s,%s,%s,'secret-hash',%s)",
        (uid, f"au{TAG}_{label}", f"au{TAG}_{label}@example.com", is_admin))
    USERS.append(uid)
    return uid


def session_for(uid):
    sm = SessionManager()
    try:
        return sm.create_session(uid)
    finally:
        sm.close()


def is_admin(uid):
    return sql("SELECT is_admin FROM users WHERE _id=%s", (uid,))[0][0]


def audit_rows(target):
    return sql("SELECT actor_user_id::text, action, previous_value, new_value FROM admin_role_audit "
               "WHERE target_user_id=%s ORDER BY ts", (target,))


def as_user(client, uid):
    client.cookies.clear()
    if uid:
        client.cookies.set("session", session_for(uid))


def main():
    require_scratch_db()
    run_create_tables()  # idempotent; ensures admin_role_audit exists on a fresh scratch DB
    client = TestClient(main_module.app)
    limiter.reset()

    # Isolate the admin population so last-admin behaviour is deterministic.
    other_admins = [r[0] for r in sql("SELECT _id::text FROM users WHERE is_admin")]
    sql("UPDATE users SET is_admin = FALSE WHERE is_admin")
    try:
        run(client)
    finally:
        for uid in other_admins:
            sql("UPDATE users SET is_admin = TRUE WHERE _id=%s", (uid,))
        for uid in USERS:
            sql("DELETE FROM users WHERE _id=%s", (uid,))
        sql("DELETE FROM admin_role_audit WHERE actor_user_id IS NULL AND target_user_id IS NULL")


def run(client):
    admin = make_user("admin", True)
    admin2 = make_user("admin2", True)
    plain = make_user("plain")
    target = make_user("target")
    ghost = str(uuid.uuid4())

    print("\n-- authz on every route --")
    routes = [("GET", "/admin/users"), ("POST", f"/admin/users/{target}/grant-admin"),
              ("POST", f"/admin/users/{target}/revoke-admin")]
    for method, path in routes:
        as_user(client, None)
        check(f"{method} {path} unauthenticated -> 401", client.request(method, path).status_code, 401)
        as_user(client, plain)
        check(f"{method} {path} non-admin -> 403", client.request(method, path).status_code, 403)
    check("non-admin attempts changed nothing", (is_admin(target), audit_rows(target)), (False, []))

    print("\n-- list / search / pagination --")
    as_user(client, admin)
    r = client.get("/admin/users", params={"q": f"au{TAG}_"})
    body = r.json()
    check("list 200", r.status_code, 200)
    check("no-store", r.headers.get("cache-control"), "no-store")
    check("search finds the 4 users", body["total"], 4)
    check("fields are limited", sorted(body["users"][0]), ["email", "id", "is_admin", "username"])
    check("no hash leaked", "secret-hash" in r.text, False)
    check("ordered by username", [u["username"] for u in body["users"]],
          sorted(u["username"] for u in body["users"]))
    r = client.get("/admin/users", params={"q": f"AU{TAG}_TARGET"})
    check("case-insensitive username search", [u["id"] for u in r.json()["users"]], [target])
    r = client.get("/admin/users", params={"q": f"au{TAG}_plain@EXAMPLE"})
    check("case-insensitive partial email search", [u["id"] for u in r.json()["users"]], [plain])
    r = client.get("/admin/users", params={"q": f"au{TAG}_", "page_size": 2, "page": 1})
    p1 = [u["id"] for u in r.json()["users"]]
    r = client.get("/admin/users", params={"q": f"au{TAG}_", "page_size": 2, "page": 2})
    p2 = [u["id"] for u in r.json()["users"]]
    check("pagination gives disjoint full pages", (len(p1), len(p2), set(p1) & set(p2)), (2, 2, set()))
    r = client.get("/admin/users", params={"q": f"au{TAG}_", "page": 3})
    check("page past the end is empty", (r.status_code, r.json()["users"], r.json()["total"]), (200, [], 4))
    r = client.get("/admin/users", params={"page_size": 100000})
    check("page size capped server-side", r.json()["page_size"], 100)
    check("page_size=0 rejected", client.get("/admin/users", params={"page_size": 0}).status_code, 422)
    check("page=0 rejected", client.get("/admin/users", params={"page": 0}).status_code, 422)
    check("over-long search rejected", client.get("/admin/users", params={"q": "a" * 101}).status_code, 422)
    check("NUL in search rejected", client.get("/admin/users", params={"q": "a\x00b"}).status_code, 422)
    r = client.get("/admin/users", params={"q": "%"})
    check("literal % does not wildcard-match everything", r.json()["total"] < body["total"] + 1000 and
          all("%" in (u["username"] + u["email"]) for u in r.json()["users"]), True)
    r = client.get("/admin/users", params={"q": "x'; DROP TABLE users;--"})
    check("injection-ish search is inert", (r.status_code, r.json()["users"]), (200, []))
    check("users table intact", sql("SELECT COUNT(*) FROM users")[0][0] >= 4, True)
    r = client.get("/admin/users", params={"q": f"nomatch{TAG}"})
    check("empty result handled", (r.status_code, r.json()["users"], r.json()["total"]), (200, [], 0))
    limiter.reset()

    print("\n-- grant / revoke --")
    r = client.post(f"/admin/users/{target}/grant-admin")
    check("grant 200 changed", (r.status_code, r.json()), (200, {"id": target, "is_admin": True, "changed": True}))
    check("db reflects grant", is_admin(target), True)
    check("one audit row for grant", audit_rows(target), [(admin, "grant", False, True)])
    as_user(client, target)
    check("granted user passes require_admin immediately", client.get("/admin/users").status_code, 200)
    as_user(client, admin)
    r = client.post(f"/admin/users/{target}/grant-admin")
    check("repeat grant is a no-op", (r.status_code, r.json()["changed"]), (200, False))
    check("no-op writes no audit row", len(audit_rows(target)), 1)
    r = client.post(f"/admin/users/{target}/revoke-admin")
    check("revoke 200 changed", (r.status_code, r.json()["changed"], r.json()["is_admin"]), (200, True, False))
    check("audit has grant then revoke", [a[1] for a in audit_rows(target)], ["grant", "revoke"])
    as_user(client, target)
    check("revoked user loses admin immediately", client.get("/admin/users").status_code, 403)
    as_user(client, admin)
    r = client.post(f"/admin/users/{target}/revoke-admin")
    check("repeat revoke is a no-op", (r.status_code, r.json()["changed"]), (200, False))
    check("unknown target -> 404", client.post(f"/admin/users/{ghost}/grant-admin").status_code, 404)
    check("malformed id -> 404", client.post("/admin/users/not-a-uuid/revoke-admin").status_code, 404)
    limiter.reset()

    print("\n-- guards --")
    r = client.post(f"/admin/users/{admin}/revoke-admin")
    check("self-revoke refused (409)", (r.status_code, is_admin(admin), audit_rows(admin)), (409, True, []))
    sql("UPDATE users SET is_admin = FALSE WHERE _id=%s", (admin2,))
    r = client.post(f"/admin/users/{admin}/revoke-admin")
    check("self-revoke as last admin refused", (r.status_code, is_admin(admin)), (409, True))
    # Last-admin guard (other actor): make admin2 the actor with admin as the only other admin... then
    # revoke admin when admin2 is not admin is a 403; so exercise the manager guard directly.
    sql("UPDATE users SET is_admin = TRUE WHERE _id=%s", (admin2,))
    m = AdminUsersManager()
    try:
        m.set_admin(admin2, admin, False)
    finally:
        m.close()
    m = AdminUsersManager()
    try:
        try:
            m.set_admin(admin, admin2, False)
            check("revoke by demoted actor refused", "no error", "403")
        except AdminUsersError as e:
            check("revoke by demoted actor refused", e.status, 403)
    finally:
        m.close()
    # Now only admin2 is admin; admin (non-admin) cannot act. Re-grant to set up last-admin check.
    m = AdminUsersManager()
    try:
        m.set_admin(admin2, admin, True)
    finally:
        m.close()
    sql("UPDATE users SET is_admin = FALSE WHERE _id=%s", (admin,))  # only admin2 remains
    m = AdminUsersManager()
    try:
        try:
            m.set_admin(admin2, admin2, False)
        except AdminUsersError as e:
            check("sole admin cannot revoke self (self guard first)", e.code, "cannot_revoke_self")
    finally:
        m.close()
    # True last-admin: actor admin2 revokes a target who is the only OTHER admin is allowed (2 admins);
    # the last-admin branch needs actor != target and count<=1, which implies the actor isn't admin
    # (rejected as 403) -- so it is unreachable except through a race, covered below.
    sql("UPDATE users SET is_admin = TRUE WHERE _id IN (%s,%s)", (admin, admin2))

    print("\n-- concurrent mutual revoke --")
    sql("DELETE FROM admin_role_audit WHERE target_user_id IN (%s,%s)", (admin, admin2))
    outcomes = []

    def worker(a, t):
        mgr = AdminUsersManager()
        try:
            mgr.set_admin(a, t, False)
            outcomes.append("ok")
        except AdminUsersError as e:
            outcomes.append(e.code)
        finally:
            mgr.close()

    threads = [threading.Thread(target=worker, args=(admin, admin2)),
               threading.Thread(target=worker, args=(admin2, admin))]
    [t.start() for t in threads]
    [t.join() for t in threads]
    remaining = sql("SELECT COUNT(*) FROM users WHERE _id IN (%s,%s) AND is_admin", (admin, admin2))[0][0]
    check("exactly one of two racing revokes wins", sorted(outcomes), sorted(["ok", "not_admin"]))
    check("one admin remains after the race", remaining, 1)
    check("exactly one revoke audit row from the race",
          sql("SELECT COUNT(*) FROM admin_role_audit WHERE action='revoke' AND target_user_id IN (%s,%s)",
              (admin, admin2))[0][0], 1)
    survivor = admin if is_admin(admin) else admin2
    as_user(client, survivor)
    check("survivor cannot revoke self", client.post(f"/admin/users/{survivor}/revoke-admin").status_code, 409)
    limiter.reset()

    print("\n-- audit survives user deletion --")
    victim = make_user("victim")
    client.post(f"/admin/users/{victim}/grant-admin")
    sql("DELETE FROM users WHERE _id=%s", (victim,))
    rows = sql("SELECT actor_user_id::text, target_user_id FROM admin_role_audit "
               "WHERE actor_user_id=%s AND target_user_id IS NULL AND action='grant'", (survivor,))
    check("audit row retained with target nulled", len(rows) >= 1, True)
    limiter.reset()

    print("\n-- admin seed does not re-promote a revoked admin --")
    seed_email = os.getenv("ADMIN_SEED_EMAIL", "jaceysimps@gmail.com")
    existing = sql("SELECT _id::text, is_admin FROM users WHERE email=%s", (seed_email,))
    seed_uid = existing[0][0] if existing else None
    created_seed = False
    if seed_uid is None:
        seed_uid = str(uuid.uuid4())
        sql("INSERT INTO users (_id, username, email, hash_pass) VALUES (%s,%s,%s,'x')",
            (seed_uid, f"seed_{TAG}", seed_email))
        # Flag-on admin seed only promotes a verified-email account (same hash
        # as backend/auth/email_verification.py::email_hash).
        sql("UPDATE users SET email_verified=TRUE, email_verified_at=NOW(), "
            "email_verified_hash=encode(sha256(convert_to(lower(btrim(email)), 'UTF8')), 'hex') "
            "WHERE _id=%s", (seed_uid,))
        created_seed = True
    prior = sql("SELECT is_admin FROM users WHERE _id=%s", (seed_uid,))[0][0]
    try:
        sql("UPDATE users SET is_admin = FALSE WHERE _id=%s", (seed_uid,))
        sql("DELETE FROM admin_role_audit WHERE target_user_id=%s", (seed_uid,))
        run_create_tables()
        check("seed promotes an un-audited demoted seed admin", is_admin(seed_uid), True)
        sql("UPDATE users SET is_admin = FALSE WHERE _id=%s", (seed_uid,))
        sql("INSERT INTO admin_role_audit (actor_user_id, target_user_id, action, previous_value, new_value) "
            "VALUES (%s,%s,'revoke',TRUE,FALSE)", (survivor, seed_uid))
        run_create_tables()
        check("seed does NOT re-promote after an audited revoke", is_admin(seed_uid), False)
    finally:
        sql("DELETE FROM admin_role_audit WHERE target_user_id=%s", (seed_uid,))
        if created_seed:
            sql("DELETE FROM users WHERE _id=%s", (seed_uid,))
        else:
            sql("UPDATE users SET is_admin=%s WHERE _id=%s", (prior, seed_uid))
    # run_create_tables may have re-seeded survivor state; restore expectations for the rate test.
    sql("UPDATE users SET is_admin = TRUE WHERE _id=%s", (survivor,))

    print("\n-- rate limiting --")
    limiter.reset()
    as_user(client, survivor)
    codes = [client.post(f"/admin/users/{ghost}/grant-admin").status_code for _ in range(11)]
    check("mutations: first 10 pass the limiter, 11th -> 429", (codes[:10] == [404] * 10, codes[10]), (True, 429))
    limiter.reset()
    codes = [client.get("/admin/users", params={"q": f"nomatch{TAG}"}).status_code for _ in range(61)]
    check("list: 61st -> 429", (codes[:60] == [200] * 60, codes[60]), (True, 429))
    limiter.reset()


def run_create_tables():
    conn = db_module._connect()
    cur = conn.cursor()
    try:
        db_module.create_tables(cur)
        conn.commit()
    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    main()
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    sys.exit(1 if FAILED else 0)
