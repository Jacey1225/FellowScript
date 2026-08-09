"""Debug: does a subscription cancellation propagate backend -> DB -> usage?

Creates a throwaway user with an ACTIVE subscription, verifies they read as
subscribed/unlimited, cancels via the real DELETE route, then re-checks the
usage endpoint + subscription lookup. Prints each stage so we can see exactly
where (if anywhere) the status fails to update. Cleans up after.
"""

import _pathfix  # noqa: F401

import uuid
from fastapi import FastAPI
from fastapi.testclient import TestClient
from db import DBManager
from backend.auth.sessions import SessionManager
from routes.subscription import subscription_router

app = FastAPI()
app.include_router(subscription_router)
client = TestClient(app)


def make_user_with_active_sub():
    uid = str(uuid.uuid4())
    uname = f"cancel_test_{uid[:8]}"
    sub_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": uname,
                               "email": f"{uname}@example.com", "hash_pass": "x"})
        db.insertion("subscriptions", {
            "_id": sub_id, "user_id": uid, "plan_type": "group",
            "provider": "stripe", "status": "active",
        })
        db.update("users", {"subscription_id": sub_id}, {"_id": uid})
    finally:
        db.close()
    # Every route this script exercises requires an authenticated session
    # matching the path user_id (get_current_user / require_match), so mint a
    # real session for this throwaway user and attach it to the client.
    sm = SessionManager()
    try:
        token = sm.create_session(uid)
    finally:
        sm.close()
    client.cookies.set("session", token)
    return uid, uname, sub_id


def db_snapshot(uid, sub_id):
    db = DBManager()
    try:
        db.cur.execute("SELECT subscription_id FROM users WHERE _id=%s", (uid,))
        row = db.cur.fetchone()
        user_sub = str(row[0]) if row and row[0] else None
        db.cur.execute("SELECT status FROM subscriptions WHERE _id=%s", (sub_id,))
        srow = db.cur.fetchone()
        sub_status = srow[0] if srow else "<row gone>"
        return user_sub, sub_status
    finally:
        db.close()


def cleanup(uid):
    db = DBManager()
    try:
        db.delete("subscriptions", {"user_id": uid})
        db.delete("users", {"_id": uid})
    finally:
        db.close()


def main():
    uid, uname, sub_id = make_user_with_active_sub()
    print(f"\nUser {uname} with ACTIVE sub {sub_id[:8]}\n")
    try:
        print("── BEFORE cancel ──")
        print("  DB:", db_snapshot(uid, sub_id))
        print("  GET /subscriptions/user/{id}:", client.get(f"/subscriptions/user/{uid}").status_code)
        print("  usage:", client.get(f"/subscriptions/user/{uid}/usage").json())

        print("\n── DELETE /subscriptions/{sub_id} ──")
        r = client.delete(f"/subscriptions/{sub_id}")
        print("  status:", r.status_code)

        print("\n── AFTER cancel ──")
        user_sub, sub_status = db_snapshot(uid, sub_id)
        print("  DB users.subscription_id:", user_sub, "| subscriptions row status:", sub_status)
        sub_lookup = client.get(f"/subscriptions/user/{uid}")
        print("  GET /subscriptions/user/{id}:", sub_lookup.status_code, "(404 = no plan, correct)")
        usage = client.get(f"/subscriptions/user/{uid}/usage").json()
        print("  usage:", usage)

        ok = (user_sub is None and sub_status == "<row gone>"
              and sub_lookup.status_code == 404
              and usage["subscribed"] is False
              and usage["resources"]["notes"]["unlimited"] is False)
        print("\nRESULT:", "✅ cancellation fully reflected" if ok else "❌ STALE — status did not propagate")
    finally:
        cleanup(uid)
        print(f"Cleaned up {uname}.")


if __name__ == "__main__":
    main()
