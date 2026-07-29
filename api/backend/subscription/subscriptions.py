import uuid
from datetime import datetime, timezone, timedelta
from db import DBManager
from schemas.subscription import (
    SubscriptionCreate,
    SubscriptionUpdate,
    price_for,
    TRIAL_MONTHS,
    EXPIRY_GRACE_DAYS,
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
        status    = data.get("status")
        trial_end = data.get("trial_end")
        cpe       = data.get("current_period_end")
        return {
            "id":                        str(sub_id),
            "user_id":                   str(data.get("user_id") or ""),
            "plan_type":                 data.get("plan_type"),
            "provider":                  data.get("provider"),
            "stripe_customer_id":        data.get("stripe_customer_id") or "",
            "default_payment_method_id": data.get("default_payment_method_id") or "",
            "card_brand":                data.get("card_brand") or "",
            "card_last4":                data.get("card_last4") or "",
            "card_exp_month":            data.get("card_exp_month") or "",
            "card_exp_year":             data.get("card_exp_year") or "",
            "status":                    status,
            "price_cents":               data.get("price_cents"),
            "max_members":               data.get("max_members"),
            "trial_end":                 str(trial_end or ""),
            "current_period_end":        str(cpe or ""),
            "created_at":                str(data.get("created_at") or ""),
            # Convenience fields the clients render directly.
            "is_trial":                  status == "trialing",
            "next_billing_date":         str(cpe or ""),
            "trial_days_remaining":      self._days_until(trial_end) if status == "trialing" else 0,
        }

    @staticmethod
    def _days_until(when) -> int:
        """Whole days from now until ``when`` (a tz-aware datetime), floored at 0."""
        if not when:
            return 0
        now = datetime.now(timezone.utc)
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        delta = when - now
        return max(0, delta.days + (1 if delta.seconds or delta.microseconds else 0))

    # ── Plans: CRUD ───────────────────────────────────────────────────────────

    def create_subscription(self, sub: SubscriptionCreate) -> str:
        """Start a new plan on a free trial and enroll the host as first member.

        Price is derived server-side from the requested ``member_count`` (1-8).
        The subscription starts in ``trialing`` status; ``trial_end`` and the
        first ``current_period_end`` (next billing date) are computed by the DB
        as now() + TRIAL_MONTHS, so the billing schedule is anchored to the
        exact creation time. Only non-sensitive billing metadata is persisted.

        Returns:
            str: the new subscription's id.
        """
        price_cents = price_for(sub.member_count)
        sub_id = str(uuid.uuid4())
        # Raw SQL so trial_end / current_period_end use the DB clock and a real
        # calendar-month interval (created_at + N months).
        self.cur.execute(
            "INSERT INTO subscriptions "
            "(_id, user_id, plan_type, provider, stripe_customer_id, default_payment_method_id, "
            " card_brand, card_last4, card_exp_month, card_exp_year, status, price_cents, max_members, "
            " trial_end, current_period_end) "
            "VALUES (%s,%s,'group',%s,%s,%s,%s,%s,%s,%s,'trialing',%s,%s, "
            "        now() + (%s || ' months')::interval, now() + (%s || ' months')::interval)",
            (sub_id, sub.user_id, sub.provider, sub.stripe_customer_id,
             sub.default_payment_method_id, sub.card_brand, sub.card_last4,
             sub.card_exp_month, sub.card_exp_year, price_cents, sub.member_count,
             TRIAL_MONTHS, TRIAL_MONTHS),
        )
        self.conn.commit()
        # The host is the plan's first member.
        self.update("users", {"subscription_id": sub_id}, {"_id": sub.user_id})
        return sub_id

    # ── Stripe billing (web) ──────────────────────────────────────────────────

    def get_user_email(self, user_id: str) -> str:
        self.cur.execute("SELECT email FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        return (row[0] or "") if row else ""

    def get_stripe_sub_id(self, subscription_id: str) -> str:
        self.cur.execute(
            "SELECT stripe_subscription_id FROM subscriptions WHERE _id = %s",
            (subscription_id,),
        )
        row = self.cur.fetchone()
        return (row[0] or "") if row else ""

    def find_id_by_stripe_sub(self, stripe_sub_id: str) -> str | None:
        self.cur.execute(
            "SELECT _id FROM subscriptions WHERE stripe_subscription_id = %s",
            (stripe_sub_id,),
        )
        row = self.cur.fetchone()
        return str(row[0]) if row else None

    def upsert_from_stripe(self, user_id: str, member_count: int, customer_id: str,
                           stripe_sub_id: str, status: str, trial_end, current_period_end,
                           card: dict) -> str:
        """Create or update the user's plan row from Stripe (the source of truth).

        Called from the ``checkout.session.completed`` webhook once payment info is
        confirmed. Enrolls the host and stores only non-sensitive card metadata.
        """
        price_cents = price_for(member_count)
        self.cur.execute("SELECT subscription_id FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        existing_id = str(row[0]) if row and row[0] else None

        if existing_id:
            self.cur.execute(
                "UPDATE subscriptions SET plan_type='group', provider='stripe', stripe_customer_id=%s, "
                "stripe_subscription_id=%s, status=%s, price_cents=%s, max_members=%s, "
                "card_brand=%s, card_last4=%s, card_exp_month=%s, card_exp_year=%s, "
                "trial_end=%s, current_period_end=%s WHERE _id=%s",
                (customer_id, stripe_sub_id, status, price_cents, member_count,
                 card["brand"], card["last4"], card["exp_month"], card["exp_year"],
                 trial_end, current_period_end, existing_id),
            )
            self.conn.commit()
            return existing_id

        sub_id = str(uuid.uuid4())
        self.cur.execute(
            "INSERT INTO subscriptions "
            "(_id, user_id, plan_type, provider, stripe_customer_id, stripe_subscription_id, "
            " status, price_cents, max_members, card_brand, card_last4, card_exp_month, "
            " card_exp_year, trial_end, current_period_end) "
            "VALUES (%s,%s,'group','stripe',%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (sub_id, user_id, customer_id, stripe_sub_id, status,
             price_cents, member_count, card["brand"], card["last4"],
             card["exp_month"], card["exp_year"], trial_end, current_period_end),
        )
        self.conn.commit()
        self.update("users", {"subscription_id": sub_id}, {"_id": user_id})
        return sub_id

    def update_status_from_stripe(self, stripe_sub_id: str, status: str,
                                  current_period_end=None, trial_end=None) -> int:
        """Update a plan's status/dates by Stripe subscription id. Returns rows changed."""
        sets, params = ["status = %s"], [status]
        if current_period_end is not None:
            sets.append("current_period_end = %s"); params.append(current_period_end)
        if trial_end is not None:
            sets.append("trial_end = %s"); params.append(trial_end)
        params.append(stripe_sub_id)
        self.cur.execute(
            f"UPDATE subscriptions SET {', '.join(sets)} WHERE stripe_subscription_id = %s",
            params,
        )
        self.conn.commit()
        return self.cur.rowcount

    def cancel_by_stripe_sub(self, stripe_sub_id: str) -> None:
        """Remove the plan tied to a Stripe subscription (on subscription.deleted)."""
        sid = self.find_id_by_stripe_sub(stripe_sub_id)
        if sid:
            self.delete_subscription(sid)

    # ── Apple StoreKit billing (iOS) ──────────────────────────────────────────

    def find_id_by_apple_txn(self, original_transaction_id: str) -> str | None:
        self.cur.execute(
            "SELECT _id FROM subscriptions WHERE apple_original_transaction_id = %s",
            (original_transaction_id,),
        )
        row = self.cur.fetchone()
        return str(row[0]) if row else None

    def upsert_from_apple(self, user_id: str, member_count: int, original_transaction_id: str,
                          status: str, current_period_end, trial_end) -> str:
        """Create or update the user's plan from a verified Apple transaction.

        Mirrors ``upsert_from_stripe`` but with ``provider='apple'`` and the
        StoreKit original transaction id. Enrolls the host.
        """
        price_cents = price_for(member_count)
        self.cur.execute("SELECT subscription_id FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        existing_id = str(row[0]) if row and row[0] else None

        if existing_id:
            self.cur.execute(
                "UPDATE subscriptions SET plan_type='group', provider='apple', "
                "apple_original_transaction_id=%s, status=%s, price_cents=%s, max_members=%s, "
                "trial_end=%s, current_period_end=%s WHERE _id=%s",
                (original_transaction_id, status, price_cents, member_count,
                 trial_end, current_period_end, existing_id),
            )
            self.conn.commit()
            return existing_id

        sub_id = str(uuid.uuid4())
        self.cur.execute(
            "INSERT INTO subscriptions "
            "(_id, user_id, plan_type, provider, apple_original_transaction_id, status, "
            " price_cents, max_members, trial_end, current_period_end) "
            "VALUES (%s,%s,'group','apple',%s,%s,%s,%s,%s,%s)",
            (sub_id, user_id, original_transaction_id, status,
             price_cents, member_count, trial_end, current_period_end),
        )
        self.conn.commit()
        self.update("users", {"subscription_id": sub_id}, {"_id": user_id})
        return sub_id

    def update_status_by_apple_txn(self, original_transaction_id: str, status: str,
                                   current_period_end=None) -> int:
        """Update status/period by Apple original transaction id (server notifications)."""
        sets, params = ["status = %s"], [status]
        if current_period_end is not None:
            sets.append("current_period_end = %s"); params.append(current_period_end)
        params.append(original_transaction_id)
        self.cur.execute(
            f"UPDATE subscriptions SET {', '.join(sets)} "
            "WHERE apple_original_transaction_id = %s",
            params,
        )
        self.conn.commit()
        return self.cur.rowcount

    def cancel_by_apple_txn(self, original_transaction_id: str) -> None:
        """Remove the plan tied to an Apple transaction (expired/refunded/revoked)."""
        sid = self.find_id_by_apple_txn(original_transaction_id)
        if sid:
            self.delete_subscription(sid)

    def _reconcile(self, subscription_id: str) -> None:
        """Advance an elapsed trial to a billing subscription.

        When now() has passed the current period end, a ``trialing`` plan flips
        to ``active`` and the next billing date rolls forward one month. Called
        lazily on read and in bulk by the scheduler, so the billing state stays
        correct without a live payment processor.
        """
        self.cur.execute(
            "UPDATE subscriptions "
            "SET status = 'active', "
            "    current_period_end = current_period_end + interval '1 month' "
            "WHERE _id = %s AND status = 'trialing' "
            "  AND current_period_end IS NOT NULL AND current_period_end <= now()",
            (subscription_id,),
        )
        self.conn.commit()

    def reconcile_expired_trials(self) -> int:
        """Flip every trial whose free month has elapsed to active (billing).

        Returns the number of subscriptions transitioned. Invoked periodically by
        the scheduler so the backend actively monitors trial → billing.
        """
        self.cur.execute(
            "UPDATE subscriptions "
            "SET status = 'active', "
            "    current_period_end = current_period_end + interval '1 month' "
            "WHERE status = 'trialing' AND trial_end IS NOT NULL AND trial_end <= now()"
        )
        n = self.cur.rowcount
        self.conn.commit()
        return n

    @staticmethod
    def _is_lapsed(data: dict) -> bool:
        """True if the paid period ended more than EXPIRY_GRACE_DAYS ago.

        A lapsed plan is one whose ``current_period_end`` is well past and which
        was never renewed (no processor notification arrived). The grace window
        keeps a healthy plan that is briefly mid-renewal from being treated as
        expired.
        """
        cpe = data.get("current_period_end")
        if not cpe:
            return False
        if cpe.tzinfo is None:
            cpe = cpe.replace(tzinfo=timezone.utc)
        return datetime.now(timezone.utc) > cpe + timedelta(days=EXPIRY_GRACE_DAYS)

    def get_subscription(self, subscription_id: str) -> dict | None:
        """Return a single plan (reconciling an elapsed trial first), or ``None``.

        A plan whose paid period lapsed beyond the grace window is reported as
        ``None`` so every client reflects the true (expired) status even if a
        processor never sent an expiry notification. This is non-destructive —
        the row is cleaned up by ``reconcile_expired_subscriptions`` (scheduler).
        """
        self._reconcile(subscription_id)
        result = self.lookup("subscriptions", {"_id": subscription_id})
        if not result:
            return None
        sid, data = list(result.items())[0]
        if self._is_lapsed(data):
            return None
        return self._to_dict(sid, data)

    def reconcile_expired_subscriptions(self) -> int:
        """Delete plans whose paid period lapsed beyond the grace window.

        The active cleanup behind the lazy check in ``get_subscription``: it
        catches Apple plans cancelled in the App Store whose EXPIRED notification
        never arrived, and any Stripe plan that stopped renewing. Uses
        ``delete_subscription`` so members are detached. Returns the count removed.
        """
        self.cur.execute(
            "SELECT _id FROM subscriptions "
            "WHERE current_period_end IS NOT NULL "
            "  AND current_period_end < now() - (%s || ' days')::interval",
            (EXPIRY_GRACE_DAYS,),
        )
        ids = [str(r[0]) for r in self.cur.fetchall()]
        for sid in ids:
            self.delete_subscription(sid)
        return len(ids)

    def create_free_plan(self, user_id: str) -> str | None:
        """Create a permanent free-tier subscription row for a newly registered user.

        Idempotent — skips creation if the user already has a subscription_id set.
        The free plan has no trial, no billing period, and no expiry; the scheduler
        and lapsed-plan checks both ignore rows with NULL current_period_end.

        Returns:
            The new subscription id, or None if the user was already enrolled.
        """
        self.cur.execute("SELECT subscription_id FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        if row and row[0]:
            return None
        sub_id = str(uuid.uuid4())
        self.cur.execute(
            "INSERT INTO subscriptions "
            "(_id, user_id, plan_type, provider, status, price_cents, max_members) "
            "VALUES (%s, %s, 'free', 'none', 'active', 0, 1)",
            (sub_id, user_id),
        )
        self.conn.commit()
        self.update("users", {"subscription_id": sub_id}, {"_id": user_id})
        return sub_id

    def get_user_subscription(self, user_id: str) -> dict | None:
        """Return the plan the given user currently belongs to, or ``None``."""
        self.cur.execute("SELECT subscription_id FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        if not row or not row[0]:
            return None
        return self.get_subscription(str(row[0]))

    def update_subscription(self, subscription_id: str, upd: SubscriptionUpdate) -> bool:
        """Apply a partial update. Changing ``member_count`` re-derives price/cap.

        Returns:
            bool: False if the plan does not exist, True otherwise.
        """
        if not self.lookup("subscriptions", {"_id": subscription_id}):
            return False
        values = {k: v for k, v in upd.model_dump().items() if v is not None}
        if "member_count" in values:
            member_count = values.pop("member_count")
            values["max_members"] = member_count
            values["price_cents"] = price_for(member_count)
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
