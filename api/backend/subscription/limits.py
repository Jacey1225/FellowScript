"""Free-tier usage gateway.

Users without an active subscription are capped on how many notes and agent
events (heartbeats) they can create. Subscribed users (individual or group,
trialing or active) are unlimited and skip counting.

Enforcement lives here and is called from the create routes, so the caps hold
for every client (web and iOS) — the server is the source of truth.

The former `agent_notifications` gated resource (a cap on user-authored
"agentic" notifications) was removed along with that subsystem — see
.claude/pipeline/20260826-activity-based-notifications.
"""

from db import DBManager
from schemas.subscription import FREE_LIMITS, NOTES_WINDOW_DAYS, EXPIRY_GRACE_DAYS


class LimitsManager(DBManager):
    """Counts a user's usage and decides whether a new create is allowed."""

    # ── Subscription state ────────────────────────────────────────────────────

    def is_subscribed(self, user_id: str) -> bool:
        """True if the user belongs to a plan that grants unlimited access.

        A user is subscribed when their ``users.subscription_id`` points at a
        plan in ``trialing`` or ``active`` status (individual or group). Canceled
        or expired plans are deleted and the pointer nulled, but we filter on
        status defensively.
        """
        # Exclude plans whose paid period lapsed beyond the grace window, matching
        # SubscriptionsManager.get_subscription so the usage view and the plan card
        # agree even before the scheduler sweep removes the stale row.
        self.cur.execute(
            "SELECT 1 FROM users u "
            "JOIN subscriptions s ON s._id = u.subscription_id "
            "WHERE u._id = %s AND s.status IN ('trialing', 'active') "
            "  AND s.plan_type != 'free' "
            "  AND (s.current_period_end IS NULL "
            "       OR s.current_period_end >= now() - (%s || ' days')::interval)",
            (user_id, EXPIRY_GRACE_DAYS),
        )
        return self.cur.fetchone() is not None

    # ── Per-resource usage counts ─────────────────────────────────────────────

    def _count(self, resource: str, user_id: str) -> int:
        """Current usage of ``resource`` for the user (window/table per resource)."""
        if resource == "notes":
            self.cur.execute(
                "SELECT COUNT(*) FROM notes "
                "WHERE user_id = %s AND timestamp >= now() - (%s || ' days')::interval",
                (user_id, NOTES_WINDOW_DAYS),
            )
        elif resource == "agent_events":
            self.cur.execute(
                "SELECT COUNT(*) FROM agent_heartbeats WHERE user_id = %s",
                (user_id,),
            )
        else:
            return 0
        row = self.cur.fetchone()
        return row[0] if row else 0

    # ── Decisions ─────────────────────────────────────────────────────────────

    def check(self, user_id: str, resource: str) -> dict:
        """Whether the user may create one more of ``resource`` right now.

        Returns a dict the route can both act on and hand back to the client:
        ``{"allowed", "unlimited", "used", "limit", "remaining", "resource"}``.
        Subscribed users are always allowed and reported as ``unlimited``.
        """
        limit = FREE_LIMITS.get(resource, 0)
        if self.is_subscribed(user_id):
            return {
                "resource": resource, "allowed": True, "unlimited": True,
                "used": 0, "limit": limit, "remaining": None,
            }
        used = self._count(resource, user_id)
        return {
            "resource": resource,
            "allowed": used < limit,
            "unlimited": False,
            "used": used,
            "limit": limit,
            "remaining": max(0, limit - used),
        }

    def usage_summary(self, user_id: str) -> dict:
        """Full usage snapshot for all gated resources (drives the client UI)."""
        subscribed = self.is_subscribed(user_id)
        plan_type = "free"
        if subscribed:
            self.cur.execute(
                "SELECT s.plan_type FROM users u "
                "JOIN subscriptions s ON s._id = u.subscription_id WHERE u._id = %s",
                (user_id,),
            )
            row = self.cur.fetchone()
            plan_type = (row[0] if row else "") or "free"

        resources = {}
        for resource, limit in FREE_LIMITS.items():
            if subscribed:
                resources[resource] = {
                    "unlimited": True, "used": 0, "limit": limit, "remaining": None,
                }
            else:
                used = self._count(resource, user_id)
                resources[resource] = {
                    "unlimited": False, "used": used, "limit": limit,
                    "remaining": max(0, limit - used),
                }
        return {
            "subscribed": subscribed,
            "plan_type": plan_type,
            "window_days": NOTES_WINDOW_DAYS,
            "resources": resources,
        }


def check_limit(user_id: str, resource: str) -> dict:
    """Route-layer helper: run a single limit check on its own connection.

    Keeps the create handlers thin — they call this, then map a disallowed
    result to a 403. Always closes the connection.
    """
    # No user id → let the route's own validation handle it, don't 500 here.
    if not user_id:
        return {"resource": resource, "allowed": True, "unlimited": False,
                "used": 0, "limit": FREE_LIMITS.get(resource, 0), "remaining": None}
    manager = LimitsManager()
    try:
        return manager.check(user_id, resource)
    finally:
        manager.close()
