"""Plan helper for tests whose subject is not the free-plan limits.

Since task 20261002-free-plan-limits-ui, free users are capped to one active
session, cannot request session summaries and cannot submit an Explorer listing.
Tests that exercise those flows for another reason (error handling, response
shape, moderation) give their throwaway user a paid plan with ``grant_paid``.
``subscriptions.user_id`` is ON DELETE CASCADE, so deleting the user in the
test's own cleanup also removes the plan row; no extra cleanup is needed.
"""
import uuid

from db import DBManager


def grant_paid(uid: str, provider: str = "stripe", plan_type: str = "individual") -> str:
    sub_id = str(uuid.uuid4())
    db = DBManager()
    try:
        # Idempotent: a user already on a paid plan keeps it. (Signup attaches a
        # plan_type='free' row, which does not count as paid, so that is replaced.)
        db.cur.execute(
            "SELECT s._id FROM users u JOIN subscriptions s ON s._id = u.subscription_id "
            "WHERE u._id = %s AND s.plan_type != 'free' AND s.status IN ('trialing', 'active')", (uid,))
        row = db.cur.fetchone()
        if row:
            return str(row[0])
        db.insertion("subscriptions", {
            "_id": sub_id, "user_id": uid, "plan_type": plan_type,
            "provider": provider, "status": "active",
        })
        db.update("users", {"subscription_id": sub_id}, {"_id": uid})
    finally:
        db.close()
    return sub_id
