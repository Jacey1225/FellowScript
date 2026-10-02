"""Free-tier usage gateway.

Users without an active subscription are capped on how many notes, agent
events (heartbeats), announcements and active sessions they can create, and
are blocked from paid-only features (session summaries, Explorer publish). Subscribed users (individual or group,
trialing or active) are unlimited and skip counting.

Enforcement lives here and is called from the create routes, so the caps hold
for every client (web and iOS) — the server is the source of truth.

The former `agent_notifications` gated resource (a cap on user-authored
"agentic" notifications) was removed along with that subsystem — see
.claude/pipeline/20260826-activity-based-notifications.
"""

from db import DBManager
from schemas.subscription import FREE_NOTE_CHAR_LIMIT, PAID_NOTE_CHAR_LIMIT, FREE_LIMITS, PAID_ONLY_RESOURCES, NOTES_WINDOW_DAYS, ANNOUNCEMENTS_WINDOW_DAYS, EXPIRY_GRACE_DAYS


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
        elif resource == "announcements":
            # Counted by created_at (not publish_at) and includes scheduled
            # and soft-deleted rows, so neither scheduling far ahead nor
            # delete-and-recreate can be used to bypass the cap.
            self.cur.execute(
                "SELECT COUNT(*) FROM group_announcements "
                "WHERE creator_id = %s AND created_at >= now() - (%s || ' days')::interval",
                (user_id, ANNOUNCEMENTS_WINDOW_DAYS),
            )
        elif resource == "sessions":
            # Sessions (devotions table) the user created that have not ended:
            # recurring sessions never end (they roll forward), and a missing
            # time_end is open-ended, so both count as active. No lifetime
            # cap: an ended session stops counting.
            self.cur.execute(
                "SELECT COUNT(*) FROM devotions "
                "WHERE creator_id = %s "
                "AND (recurring = TRUE OR time_end IS NULL OR time_end >= now())",
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

    def lock_session_creation(self, user_id: str) -> None:
        """Serialize a user's session creates/reactivations (session-level
        advisory lock, released when this manager's connection closes). Held
        across check + insert so concurrent requests cannot both pass the cap."""
        self.cur.execute("SELECT pg_advisory_lock(hashtextextended(%s, 0))", ("sessions:" + str(user_id),))

    def check_session_reactivation(self, user_id: str, session_id: str,
                                   new_recurring: bool, new_time_end: str | None) -> dict:
        """Gate a PUT that would turn an ended session of ``user_id`` back into
        an active one (extending ``time_end`` / setting recurring), which would
        otherwise dodge the create cap. Only the ended -> active transition is
        gated, so a free user's existing sessions stay editable."""
        limit = FREE_LIMITS["sessions"]
        ok = {"resource": "sessions", "allowed": True, "unlimited": False,
              "used": 0, "limit": limit, "remaining": limit}
        if self.is_subscribed(user_id):
            return {**ok, "unlimited": True, "remaining": None}
        self.cur.execute(
            "SELECT (recurring = TRUE OR time_end IS NULL OR time_end >= now()) "
            "FROM devotions WHERE _id = %s", (session_id,))
        row = self.cur.fetchone()
        was_active = bool(row and row[0])
        self.cur.execute(
            "SELECT (%s::boolean OR %s::timestamptz IS NULL OR %s::timestamptz >= now())",
            (bool(new_recurring), new_time_end or None, new_time_end or None))
        will_be_active = bool(self.cur.fetchone()[0])
        if was_active or not will_be_active:
            return ok
        self.cur.execute(
            "SELECT COUNT(*) FROM devotions WHERE creator_id = %s AND _id != %s "
            "AND (recurring = TRUE OR time_end IS NULL OR time_end >= now())",
            (user_id, session_id))
        used = self.cur.fetchone()[0]
        return {**ok, "allowed": used < limit, "used": used, "remaining": max(0, limit - used)}

    def check_paid_only(self, user_id: str, resource: str) -> dict:
        """Gate for a feature with no free allowance (``PAID_ONLY_RESOURCES``).

        Fails closed: an unknown resource name, or a lookup error (propagates),
        blocks. Subscribed users (incl. admin comp, trialing, grace) pass.
        Body shape matches ``check`` plus ``paid_only: True`` so clients reuse
        one detector keyed on ``resource``.
        """
        blocked_for_free = PAID_ONLY_RESOURCES.get(resource, True)
        subscribed = self.is_subscribed(user_id)
        allowed = subscribed or not blocked_for_free
        return {
            "resource": resource, "allowed": allowed, "unlimited": subscribed,
            "used": 0, "limit": 0, "remaining": None if subscribed else 0,
            "paid_only": True,
        }

    def check_note_chars(self, user_id: str, new_len: int, old_len: int | None = None) -> dict:
        """Whether a note write leaving ``text`` at ``new_len`` chars is allowed.

        Rule (grandfathering): reject iff ``new_len > limit`` AND (``old_len``
        is None, i.e. a create, OR ``new_len > old_len``). Shrinking or
        same-length edits of an already over-cap note are always allowed, so a
        downgraded user is never locked out of trimming their own text.
        ``limit`` is FREE_NOTE_CHAR_LIMIT for free users and
        PAID_NOTE_CHAR_LIMIT for subscribed users. Fails closed:
        any error in the plan lookup propagates (the write is not performed).
        Body shape matches ``check`` so clients reuse their 403 handling.
        """
        subscribed = self.is_subscribed(user_id)
        limit = PAID_NOTE_CHAR_LIMIT if subscribed else FREE_NOTE_CHAR_LIMIT
        over = new_len > limit and (old_len is None or new_len > old_len)
        return {
            "resource": "note_chars",
            "allowed": not over,
            "unlimited": False,
            "used": new_len,
            "limit": limit,
            "remaining": max(0, limit - new_len),
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
            "announcements_window_days": ANNOUNCEMENTS_WINDOW_DAYS,
            "resources": resources,
            # Features with no free allowance: ``allowed`` is what this user
            # may do right now; ``free_allowed`` is the plan rule itself.
            "paid_only": {
                name: {"allowed": subscribed or not blocked, "free_allowed": not blocked}
                for name, blocked in PAID_ONLY_RESOURCES.items()
            },
            # Per-note text length cap. Kept out of "resources" (those are
            # rolling counts). ``limit`` is the caller's per-plan cap (free 30,000,
            # paid 100,000); no plan is unlimited.
            "note_chars": {
                "unlimited": False,
                "limit": PAID_NOTE_CHAR_LIMIT if subscribed else FREE_NOTE_CHAR_LIMIT,
            },
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


def check_paid_only(user_id: str, resource: str) -> dict:
    """Route-layer helper for paid-only gates; own connection, fails closed
    (no empty-user_id pass-through, errors propagate and the action is not run)."""
    manager = LimitsManager()
    try:
        return manager.check_paid_only(user_id, resource)
    finally:
        manager.close()


def check_note_chars(user_id: str, new_len: int, old_len: int | None = None) -> dict:
    """Route-layer helper for the per-note character cap; own connection.

    Unlike ``check_limit`` there is no empty-user_id pass-through: every
    caller has an authenticated user, and this gate fails closed.
    """
    manager = LimitsManager()
    try:
        return manager.check_note_chars(user_id, new_len, old_len)
    finally:
        manager.close()
