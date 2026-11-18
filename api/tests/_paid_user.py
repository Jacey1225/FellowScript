"""Shared helper: make a test user a paying (Stripe, active) member.

AI scheduled devotions (agent_events) are paid-only (task
20261117-scheduled-devotions-paid-only), so any DB-backed test that creates or
fires a heartbeat must run as a subscribed user. Idempotent (a signup's free-plan row is replaced); the subscription row
cascades away with the user.
"""
import uuid

from db import DBManager


def grant_paid(user_id: str) -> None:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT 1 FROM users u JOIN subscriptions s ON s._id = u.subscription_id "
            "WHERE u._id = %s AND s.status IN ('trialing','active') AND s.plan_type != 'free'",
            (user_id,))
        if db.cur.fetchone():
            return
        sub_id = str(uuid.uuid4())
        db.insertion("subscriptions", {
            "_id": sub_id, "user_id": user_id, "plan_type": "individual",
            "provider": "stripe", "status": "active",
        })
        db.update("users", {"subscription_id": sub_id}, {"_id": user_id})
    finally:
        db.close()


from contextlib import contextmanager  # noqa: E402


@contextmanager
def devotion_gate_open():
    """Let the ``agent_events`` (paid-only scheduled devotions) gate pass for everyone
    while every other limit (notably the weekly ``notes`` cap) is still decided by the
    real LimitsManager. The notes cap is otherwise unreachable from a heartbeat route
    or the scheduler, because only paid members can own a heartbeat and paid members
    have no notes cap; this keeps the notes-cap-before-claim ordering regression
    (20260825-heartbeat-notes-limit-bypass) provable. The agent_events gate itself is
    covered by test_scheduled_devotions_paid_only.py and test_free_limits.py.
    """
    from backend.subscription.limits import LimitsManager
    orig = LimitsManager.check

    def check(self, user_id, resource):
        if resource == "agent_events":
            return {"resource": resource, "allowed": True, "unlimited": False,
                    "used": 0, "limit": 1, "remaining": 1}
        return orig(self, user_id, resource)

    LimitsManager.check = check
    try:
        yield
    finally:
        LimitsManager.check = orig
