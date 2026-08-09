"""Debug: does a LAPSED (expired past grace) subscription stop reading as active?

Simulates an Apple plan whose paid period ended long ago and whose EXPIRED
notification never arrived: inserts an 'active' subscription with a past
current_period_end, then checks that reads (usage endpoint + plan lookup) treat
it as expired, and that the scheduler sweep removes the row + detaches the user.
Also verifies a plan still within grace is NOT dropped. Cleans up after.
"""

import _pathfix  # noqa: F401

import uuid
from fastapi import FastAPI
from fastapi.testclient import TestClient
from db import DBManager
from backend.auth.sessions import SessionManager
from routes.subscription import subscription_router
from backend.subscription.subscriptions import SubscriptionsManager

app = FastAPI()
app.include_router(subscription_router)
client = TestClient(app)


def make_user_with_sub(days_past_period: int):
    """User + 'active' sub whose current_period_end is `days_past_period` ago."""
    uid = str(uuid.uuid4())
    uname = f"expiry_test_{uid[:8]}"
    sub_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": uname,
                               "email": f"{uname}@example.com", "hash_pass": "x"})
        db.cur.execute(
            "INSERT INTO subscriptions (_id, user_id, plan_type, provider, status, current_period_end) "
            "VALUES (%s,%s,'group','apple','active', now() - (%s || ' days')::interval)",
            (sub_id, uid, days_past_period),
        )
        db.conn.commit()
        db.update("users", {"subscription_id": sub_id}, {"_id": uid})
    finally:
        db.close()
    # These routes require an authenticated session matching the path user_id
    # (get_current_user / require_match), so mint a real session per scenario's
    # throwaway user and attach it to the shared client.
    sm = SessionManager()
    try:
        token = sm.create_session(uid)
    finally:
        sm.close()
    client.cookies.set("session", token)
    return uid, uname, sub_id


def row_exists(sub_id):
    db = DBManager()
    try:
        db.cur.execute("SELECT 1 FROM subscriptions WHERE _id=%s", (sub_id,))
        return db.cur.fetchone() is not None
    finally:
        db.close()


def cleanup(uid):
    db = DBManager()
    try:
        db.delete("subscriptions", {"user_id": uid})
        db.delete("users", {"_id": uid})
    finally:
        db.close()


def scenario(label, days_past, expect_active):
    uid, uname, sub_id = make_user_with_sub(days_past)
    try:
        sub_code = client.get(f"/subscriptions/user/{uid}").status_code
        usage = client.get(f"/subscriptions/user/{uid}/usage").json()
        reads_active = (sub_code == 200 and usage["subscribed"] is True)
        print(f"\n[{label}] period ended {days_past}d ago (grace 3d)")
        print(f"  read as active? {reads_active}  (expected {expect_active})")
        print(f"    GET /user/{{id}} = {sub_code}, usage.subscribed = {usage['subscribed']}")

        # Run the sweep and see whether the row is removed.
        sm = SubscriptionsManager()
        try:
            removed = sm.reconcile_expired_subscriptions()
        finally:
            sm.close()
        still = row_exists(sub_id)
        print(f"  sweep removed row? {not still}")

        ok = (reads_active == expect_active) and (still == expect_active)
        print("  =>", "✅" if ok else "❌ FAIL")
        return ok
    finally:
        cleanup(uid)


def main():
    r1 = scenario("within grace", 1, expect_active=True)    # 1d past, < 3d grace → keep
    r2 = scenario("lapsed", 10, expect_active=False)         # 10d past → expired + swept
    print("\n" + ("✅ ALL GOOD" if (r1 and r2) else "❌ FAILURES"))


if __name__ == "__main__":
    main()
