import uuid
from db import DBManager
from schemas.subscription import (
    SubscriptionCreate,
    SubscriptionUpdate,
    PLAN_CONFIG,
)


class SubscriptionsManager(DBManager):
    """CRUD for subscription plans, their members, and group join requests.

    Membership is a pointer on the users row: a plan's members are the users
    whose ``users.subscription_id`` equals the plan id, and the host is
    ``subscriptions.user_id``. Group join requests live in ``subscription_request``.
    """

    # ── Serialisation ─────────────────────────────────────────────────────────

    def _to_dict(self, sub_id, data: dict) -> dict:
        """Normalise a subscriptions row (UUIDs/timestamps) into a JSON-safe dict."""
        return {
            "id":                        str(sub_id),
            "user_id":                   str(data.get("user_id") or ""),
            "plan_type":                 data.get("plan_type"),
            "provider":                  data.get("provider"),
            "stripe_customer_id":        data.get("stripe_customer_id") or "",
            "default_payment_method_id": data.get("default_payment_method_id") or "",
            "card_brand":                data.get("card_brand") or "",
            "card_last4":                data.get("card_last4") or "",
            "status":                    data.get("status"),
            "price_cents":               data.get("price_cents"),
            "max_members":               data.get("max_members"),
            "current_period_end":        str(data.get("current_period_end") or ""),
            "created_at":                str(data.get("created_at") or ""),
        }

    # ── Plans: CRUD ───────────────────────────────────────────────────────────

    def create_subscription(self, sub: SubscriptionCreate) -> str:
        """Start a new plan and enroll the host as its first member.

        Price and member cap are derived server-side from ``plan_type``.

        Returns:
            str: the new subscription's id.
        """
        cfg    = PLAN_CONFIG.get(sub.plan_type, PLAN_CONFIG["individual"])
        sub_id = str(uuid.uuid4())
        self.insertion("subscriptions", {
            "_id":                       sub_id,
            "user_id":                   sub.user_id,
            "plan_type":                 sub.plan_type,
            "provider":                  sub.provider,
            "stripe_customer_id":        sub.stripe_customer_id,
            "default_payment_method_id": sub.default_payment_method_id,
            "card_brand":                sub.card_brand,
            "card_last4":                sub.card_last4,
            "status":                    "active",
            "price_cents":               cfg["price_cents"],
            "max_members":               cfg["max_members"],
        })
        # The host is the plan's first member.
        self.update("users", {"subscription_id": sub_id}, {"_id": sub.user_id})
        return sub_id

    def get_subscription(self, subscription_id: str) -> dict | None:
        """Return a single plan, or ``None`` if it does not exist."""
        result = self.lookup("subscriptions", {"_id": subscription_id})
        if not result:
            return None
        sid, data = list(result.items())[0]
        return self._to_dict(sid, data)

    def get_user_subscription(self, user_id: str) -> dict | None:
        """Return the plan the given user currently belongs to, or ``None``."""
        self.cur.execute("SELECT subscription_id FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        if not row or not row[0]:
            return None
        return self.get_subscription(str(row[0]))

    def update_subscription(self, subscription_id: str, upd: SubscriptionUpdate) -> bool:
        """Apply a partial update. Changing ``plan_type`` re-derives price/cap.

        Returns:
            bool: False if the plan does not exist, True otherwise.
        """
        if not self.lookup("subscriptions", {"_id": subscription_id}):
            return False
        values = {k: v for k, v in upd.model_dump().items() if v is not None}
        if "plan_type" in values:
            cfg = PLAN_CONFIG.get(values["plan_type"], PLAN_CONFIG["individual"])
            values["price_cents"] = cfg["price_cents"]
            values["max_members"] = cfg["max_members"]
        if values:
            self.update("subscriptions", values, {"_id": subscription_id})
        return True

    def delete_subscription(self, subscription_id: str) -> None:
        """Cancel a plan: detach all members, then delete it (requests cascade)."""
        # ON DELETE SET NULL would clear these, but do it explicitly so the intent
        # is clear and it holds even without the FK.
        self.cur.execute(
            "UPDATE users SET subscription_id = NULL WHERE subscription_id = %s",
            (subscription_id,),
        )
        self.conn.commit()
        self.delete("subscriptions", {"_id": subscription_id})

    # ── Members: read / delete ────────────────────────────────────────────────

    def get_members(self, subscription_id: str) -> list[dict]:
        """Return every user enrolled in the plan (host included)."""
        self.cur.execute(
            "SELECT _id, username, email FROM users WHERE subscription_id = %s",
            (subscription_id,),
        )
        return [
            {"user_id": str(r[0]), "username": r[1], "email": r[2]}
            for r in self.cur.fetchall()
        ]

    def remove_member(self, subscription_id: str, user_id: str) -> dict | None:
        """Remove a member from a group plan (host removes, or member leaves).

        Returns:
            dict | None: ``{"error": str}`` if the plan is missing or the target
                is the host; ``None`` on success.
        """
        result = self.lookup("subscriptions", {"_id": subscription_id})
        if not result:
            return {"error": "Subscription not found"}
        _, sdata = list(result.items())[0]
        if str(sdata.get("user_id")) == user_id:
            return {"error": "The host cannot leave their own plan; delete it instead"}
        self.cur.execute(
            "UPDATE users SET subscription_id = NULL "
            "WHERE _id = %s AND subscription_id = %s",
            (user_id, subscription_id),
        )
        self.conn.commit()
        return None

    def _member_count(self, subscription_id: str) -> int:
        self.cur.execute(
            "SELECT COUNT(*) FROM users WHERE subscription_id = %s",
            (subscription_id,),
        )
        row = self.cur.fetchone()
        return row[0] if row else 0

    # ── Group join requests: CRUD ─────────────────────────────────────────────

    def create_request(self, subscription_id: str, from_user_id: str) -> dict | None:
        """A user requests to join a host's group plan.

        Returns:
            dict | None: ``{"error": str}`` when the plan is missing/not a group,
                the plan is full, or the user is already the host/a member;
                ``None`` on success.
        """
        result = self.lookup("subscriptions", {"_id": subscription_id})
        if not result:
            return {"error": "Subscription not found"}
        _, sdata = list(result.items())[0]
        if sdata.get("plan_type") != "group":
            return {"error": "Only group plans accept join requests"}
        if str(sdata.get("user_id")) == from_user_id:
            return {"error": "Host is already on the plan"}
        if self._member_count(subscription_id) >= (sdata.get("max_members") or 1):
            return {"error": "Plan is full"}
        # Already a member of this exact plan?
        self.cur.execute("SELECT subscription_id FROM users WHERE _id = %s", (from_user_id,))
        row = self.cur.fetchone()
        if row and row[0] and str(row[0]) == subscription_id:
            return {"error": "Already a member of this plan"}
        self.insertion("subscription_request", {
            "subscription_id": subscription_id,
            "from_user_id":    from_user_id,
        })
        return None

    def get_requests(self, subscription_id: str) -> list[dict]:
        """List pending join requests for a plan (for the host to review)."""
        self.cur.execute(
            "SELECT u._id, u.username, u.email FROM users u "
            "JOIN subscription_request sr ON u._id = sr.from_user_id "
            "WHERE sr.subscription_id = %s ORDER BY sr.created_at",
            (subscription_id,),
        )
        return [
            {"user_id": str(r[0]), "username": r[1], "email": r[2]}
            for r in self.cur.fetchall()
        ]

    def get_user_requests(self, user_id: str) -> list[dict]:
        """List the plans a user has an outstanding join request for."""
        self.cur.execute(
            "SELECT s._id, s.plan_type, s.user_id FROM subscriptions s "
            "JOIN subscription_request sr ON s._id = sr.subscription_id "
            "WHERE sr.from_user_id = %s ORDER BY sr.created_at",
            (user_id,),
        )
        return [
            {"subscription_id": str(r[0]), "plan_type": r[1], "host_id": str(r[2])}
            for r in self.cur.fetchall()
        ]

    def accept_request(self, subscription_id: str, from_user_id: str) -> dict | None:
        """Host accepts a pending request, enrolling the user in the plan.

        Enforces the plan's member cap.

        Returns:
            dict | None: ``{"error": str}`` if the plan is missing, no such
                request exists, or the plan is full; ``None`` on success.
        """
        result = self.lookup("subscriptions", {"_id": subscription_id})
        if not result:
            return {"error": "Subscription not found"}
        _, sdata = list(result.items())[0]
        self.cur.execute(
            "SELECT 1 FROM subscription_request "
            "WHERE subscription_id = %s AND from_user_id = %s",
            (subscription_id, from_user_id),
        )
        if not self.cur.fetchone():
            return {"error": "No pending request from this user"}
        if self._member_count(subscription_id) >= (sdata.get("max_members") or 1):
            return {"error": "Plan is full"}
        self.update("users", {"subscription_id": subscription_id}, {"_id": from_user_id})
        self.delete("subscription_request", {
            "subscription_id": subscription_id,
            "from_user_id":    from_user_id,
        })
        return None

    def delete_request(self, subscription_id: str, from_user_id: str) -> None:
        """Decline (host) or cancel (requester) a pending join request."""
        self.delete("subscription_request", {
            "subscription_id": subscription_id,
            "from_user_id":    from_user_id,
        })
