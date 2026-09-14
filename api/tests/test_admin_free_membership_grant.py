"""Integration test for task 20260914-admin-free-membership: the
require_admin-gated POST /subscriptions/admin/grant-individual endpoint that
gives an is_admin=TRUE user a free, non-billed, active "individual"
membership.

Builds a minimal FastAPI app with only the subscription router (same pattern
as test_free_limits.py) plus a capturing log handler for the admin_audit
logger. Creates throwaway admin/non-admin/bystander users directly in the
local DB, exercises the real endpoint end to end, and cleans up afterward.

Covers the acceptance criteria from
.claude/pipeline/20260914-admin-free-membership/intake-spec.md:
  - require_admin accept/reject: unauthenticated -> 401, authenticated
    non-admin -> 403, admin -> 201.
  - The grant is genuinely active (not a client-side-only flag): resulting
    row has plan_type='individual', provider='admin_comp', status='active',
    price_cents=0, max_members=1, current_period_end NULL (so it can never
    be swept by the EXPIRY_GRACE_DAYS lapse logic in _is_lapsed).
  - FREE_LIMITS is bypassed for the granted admin exactly like a real paying
    subscriber, verified both via the usage-summary endpoint and by actually
    creating notes past the free cap.
  - The endpoint has no client-supplied target field: a smuggled
    user_id/body field is ignored, so an admin session can never be used to
    grant membership to an arbitrary other account (security step 1's
    required constraint 5 / IDOR guard).
  - Idempotency: calling the grant endpoint twice returns the same
    subscription id and never creates a second admin_comp row for that
    admin (security step 1's required constraint 6).
  - Every grant emits one admin_audit logger line (action, admin_id,
    subscription_id), matching routes/monitoring.py's existing pattern.
  - Non-admin users' own subscription/usage flow is unaffected by this
    feature (spot-checked: a non-admin's own usage call still reports
    unsubscribed with no side effects from the admin's grant).

Run:  cd api && ../.venv/bin/python tests/test_admin_free_membership_grant.py
"""

import _pathfix  # noqa: F401

import logging
import uuid

from fastapi import FastAPI
from fastapi.testclient import TestClient

from db import DBManager
from backend.auth.sessions import SessionManager
from routes.notes import notes_router
from routes.subscription import subscription_router
from schemas.subscription import ADMIN_COMP_PROVIDER

app = FastAPI()
for r in (notes_router, subscription_router):
    app.include_router(r)
client = TestClient(app)

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


def make_user(is_admin: bool) -> str:
    uid = str(uuid.uuid4())
    dbm = DBManager()
    try:
        dbm.insertion("users", {
            "_id": uid, "username": f"admin_grant_test_{uid[:8]}",
            "email": f"admin_grant_test_{uid[:8]}@example.com", "hash_pass": "x",
            "is_admin": is_admin,
        })
    finally:
        dbm.close()
    return uid


def make_session(uid: str) -> str:
    sm = SessionManager()
    try:
        return sm.create_session(uid)
    finally:
        sm.close()


def cleanup_user(uid: str):
    dbm = DBManager()
    try:
        dbm.delete("notes", {"user_id": uid})
        dbm.delete("subscriptions", {"user_id": uid})
        dbm.delete("users", {"_id": uid})
    finally:
        dbm.close()


def admin_comp_rows(uid: str) -> list:
    dbm = DBManager()
    try:
        dbm.cur.execute(
            "SELECT _id, plan_type, provider, status, price_cents, max_members, "
            "current_period_end FROM subscriptions WHERE user_id = %s AND provider = %s",
            (uid, ADMIN_COMP_PROVIDER),
        )
        return dbm.cur.fetchall()
    finally:
        dbm.close()


class _CapturingHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records: list[str] = []

    def emit(self, record):
        self.records.append(self.format(record))


GRANT_PATH = "/subscriptions/admin/grant-individual"


def test_auth_boundary(admin_token, non_admin_token):
    print("\n── require_admin accept/reject on the grant endpoint ──")
    client.cookies.clear()
    r = client.post(GRANT_PATH)
    check("unauthenticated -> 401", r.status_code, 401)

    client.cookies.set("session", non_admin_token)
    r = client.post(GRANT_PATH)
    check("authenticated non-admin -> 403", r.status_code, 403)
    client.cookies.clear()


def test_grant_creates_active_individual_membership(admin_token, admin_uid):
    print("\n── admin grant produces a genuinely active $0 individual membership ──")
    client.cookies.set("session", admin_token)
    r = client.post(GRANT_PATH)
    check("admin grant -> 201", r.status_code, 201)
    body = r.json()
    check("plan_type", body["plan_type"], "individual")
    check("provider", body["provider"], ADMIN_COMP_PROVIDER)
    check("status", body["status"], "active")
    check("price_cents", body["price_cents"], 0)
    check("max_members", body["max_members"], 1)

    rows = admin_comp_rows(admin_uid)
    check("exactly one admin_comp row exists for the admin", len(rows), 1)
    check("current_period_end is NULL (never swept by EXPIRY_GRACE_DAYS)",
          rows[0][6], None)
    client.cookies.clear()
    return body["id"]


def test_idempotent_no_duplicate_grants(admin_token, admin_uid, first_sub_id):
    print("\n── calling the grant endpoint again does not duplicate the row ──")
    client.cookies.set("session", admin_token)
    r = client.post(GRANT_PATH)
    check("second grant call -> 201", r.status_code, 201)
    check("second call returns the same subscription id", r.json()["id"], first_sub_id)
    rows = admin_comp_rows(admin_uid)
    check("still exactly one admin_comp row after a second grant call", len(rows), 1)
    client.cookies.clear()


def test_no_client_supplied_target(admin_token, admin_uid, bystander_uid):
    print("\n── smuggled body field cannot redirect the grant to another account ──")
    client.cookies.set("session", admin_token)
    r = client.post(GRANT_PATH, json={"user_id": bystander_uid})
    check("grant with a smuggled user_id body still succeeds", r.status_code, 201)
    check("...but the resulting subscription still belongs to the calling admin",
          r.json()["user_id"], admin_uid)
    check("the bystander account received no admin_comp grant",
          len(admin_comp_rows(bystander_uid)), 0)
    client.cookies.clear()


def test_free_limits_bypassed(admin_token, admin_uid):
    print("\n── FREE_LIMITS bypassed for the granted admin, same as a real subscriber ──")
    client.cookies.set("session", admin_token)
    usage = client.get(f"/subscriptions/user/{admin_uid}/usage").json()
    check("usage reports subscribed", usage["subscribed"], True)
    check("usage reports plan_type=individual", usage["plan_type"], "individual")
    check("notes resource reported unlimited", usage["resources"]["notes"]["unlimited"], True)

    # Prove it's real server-side enforcement, not just a reported flag: create
    # more notes than FREE_LIMITS would ever allow a free-tier user and confirm
    # none are blocked (mirrors test_free_limits.py's own subscribed-user check).
    codes = [
        client.post(f"/notes/{admin_uid}", json={"title": f"n{i}", "text": "b"}).status_code
        for i in range(12)
    ]
    check("all 12 notes accepted past the free-tier cap of 10", codes, [201] * 12)
    client.cookies.clear()


def test_audit_logging(admin_token, admin_uid):
    print("\n── admin_audit logger emits a line on every grant ──")
    audit_logger = logging.getLogger("admin_audit")
    handler = _CapturingHandler()
    handler.setFormatter(logging.Formatter("%(message)s"))
    audit_logger.addHandler(handler)
    prior_level = audit_logger.level
    audit_logger.setLevel(logging.INFO)
    try:
        client.cookies.set("session", admin_token)
        client.post(GRANT_PATH)
        client.cookies.clear()
        joined = "\n".join(handler.records)
        check("grant_individual_membership audit line was emitted",
              "action=grant_individual_membership" in joined and f"admin_id={admin_uid}" in joined,
              True)
    finally:
        audit_logger.removeHandler(handler)
        audit_logger.setLevel(prior_level)


def test_non_admin_flow_unaffected(non_admin_token, non_admin_uid):
    print("\n── non-admin's own subscription flow is unaffected by this feature ──")
    client.cookies.set("session", non_admin_token)
    usage = client.get(f"/subscriptions/user/{non_admin_uid}/usage").json()
    check("non-admin remains unsubscribed", usage["subscribed"], False)
    check("non-admin plan_type is free", usage["plan_type"], "free")
    check("no admin_comp row exists for the non-admin",
          len(admin_comp_rows(non_admin_uid)), 0)
    client.cookies.clear()


if __name__ == "__main__":
    admin_uid = non_admin_uid = bystander_uid = None
    try:
        admin_uid = make_user(is_admin=True)
        non_admin_uid = make_user(is_admin=False)
        bystander_uid = make_user(is_admin=False)
        admin_token = make_session(admin_uid)
        non_admin_token = make_session(non_admin_uid)

        test_auth_boundary(admin_token, non_admin_token)
        first_sub_id = test_grant_creates_active_individual_membership(admin_token, admin_uid)
        test_idempotent_no_duplicate_grants(admin_token, admin_uid, first_sub_id)
        test_no_client_supplied_target(admin_token, admin_uid, bystander_uid)
        test_free_limits_bypassed(admin_token, admin_uid)
        test_audit_logging(admin_token, admin_uid)
        test_non_admin_flow_unaffected(non_admin_token, non_admin_uid)
    finally:
        for uid in (admin_uid, non_admin_uid, bystander_uid):
            if uid:
                cleanup_user(uid)

    total, passed = len(results), sum(results)
    print(f"\n{'='*46}\n  {passed}/{total} checks passed"
          f"  {'✅ ALL GOOD' if passed == total else '❌ FAILURES'}\n{'='*46}")
    raise SystemExit(0 if passed == total else 1)
