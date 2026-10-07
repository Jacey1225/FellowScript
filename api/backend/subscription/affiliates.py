"""Creator affiliate dashboard data (task 20261007-affiliates-page).

Read-mostly aggregation over the existing promo tables. The affiliate is
resolved ONLY from the authenticated session user's account email matched
(case-insensitively, exactly) against ``promo_codes.owner_email``; no id
or code ever comes from the client. Every result is an aggregate (counts,
cents, series, milestone flags): subscriber ids, names and emails are never
selected into the response.

Definitions
  * affiliate codes   non-deleted creator-kind codes whose owner_email equals the
                      caller's email (any code active state; a creator whose
                      codes are all inactive or whose creator row is inactive is
                      refused).
  * referred buyers   distinct promo_redemptions.user_id for those codes, excluding
                      over-cap rows.
  * active paying     a referred buyer whose subscription is status 'active' (not
                      'trialing'), plan_type != 'free' and price_cents > 0.
  * monthly earnings  commission_rate x sum(price_cents) of active paying buyers
                      (plans bill monthly; price_cents is the monthly plan price).
  * activity series   new referred subscriptions (redemptions) per UTC bucket plus
                      the running total, zero-filled, for day/week/month.
  * milestones        tier reached when active paying count >= tier at any read;
                      recorded once in affiliate_milestones and never revoked.
"""
import logging
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP

from db import DBManager
from backend.subscription.affiliates_config import AffiliatesConfig, SERIES_UNITS

logger = logging.getLogger(__name__)

# Fixed SQL fragments keyed by unit: never built from client input.
_UNIT_SQL = {"day": "1 day", "week": "1 week", "month": "1 month"}


class AffiliateManager(DBManager):
    def resolve_affiliate(self, user_id: str) -> dict | None:
        """The caller's affiliate identity, or None (=> 403).

        None unless the session user exists, has an email, and at least one
        non-deleted creator code with that owner email is active on an active
        creator.
        """
        self.cur.execute("SELECT email FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        email = (row[0] or "").strip().lower() if row else ""
        if not email:
            return None
        self.cur.execute(
            "SELECT p._id, p.code, p.active AND c.active AND NOT p.requires_owner_email "
            "FROM promo_codes p JOIN creators c ON c._id = p.creator_id "
            "WHERE p.kind = 'creator' AND p.deleted_at IS NULL "
            "AND p.owner_email IS NOT NULL AND LOWER(p.owner_email) = %s ORDER BY p.created_at",
            (email,))
        codes = [{"id": str(r[0]), "code": r[1], "active": bool(r[2])} for r in self.cur.fetchall()]
        if not any(c["active"] for c in codes):
            return None
        return {"email": email, "codes": codes}

    def _active_paying(self, code_ids: list[str]) -> tuple[int, int]:
        """(count, sum of monthly price cents) of active paying referred buyers."""
        self.cur.execute(
            "SELECT COUNT(*), COALESCE(SUM(price_cents), 0) FROM ("
            " SELECT DISTINCT ON (s.user_id) s.price_cents FROM subscriptions s "
            " WHERE s.user_id IN (SELECT DISTINCT r.user_id FROM promo_redemptions r "
            "                     WHERE r.code_id = ANY(%s::uuid[]) AND NOT r.over_cap AND r.user_id IS NOT NULL) "
            " AND s.status = 'active' AND s.plan_type <> 'free' AND s.price_cents > 0 "
            " ORDER BY s.user_id, s.created_at DESC) x", (code_ids,))
        n, total = self.cur.fetchone()
        return int(n), int(total)

    def _series(self, code_ids: list[str], unit: str, points: int) -> list[dict]:
        step = _UNIT_SQL[unit]
        self.cur.execute(
            f"WITH b AS (SELECT generate_series("
            f" date_trunc('{unit}', NOW() AT TIME ZONE 'UTC') - (%s - 1) * interval '{step}',"
            f" date_trunc('{unit}', NOW() AT TIME ZONE 'UTC'), interval '{step}') AS t), "
            f"c AS (SELECT date_trunc('{unit}', r.created_at AT TIME ZONE 'UTC') AS t, COUNT(*) AS n "
            f" FROM promo_redemptions r WHERE r.code_id = ANY(%s::uuid[]) AND NOT r.over_cap GROUP BY 1) "
            f"SELECT b.t, COALESCE(c.n, 0) FROM b LEFT JOIN c ON c.t = b.t ORDER BY b.t",
            (points, code_ids))
        rows = self.cur.fetchall()
        first = rows[0][0] if rows else None
        self.cur.execute(
            f"SELECT COUNT(*) FROM promo_redemptions r WHERE r.code_id = ANY(%s::uuid[]) AND NOT r.over_cap "
            f"AND (r.created_at AT TIME ZONE 'UTC') < %s", (code_ids, first))
        running = int(self.cur.fetchone()[0]) if first else 0
        out = []
        for t, n in rows:
            running += int(n)
            out.append({"t": t.date().isoformat(), "new": int(n), "total": running})
        return out

    def _record_milestones(self, email: str, count: int, cfg: AffiliatesConfig) -> dict[int, dict]:
        """Persist newly reached tiers (idempotent) and return every earned tier."""
        try:
            for m in cfg.milestones:
                if count >= m.subscribers:
                    self.cur.execute(
                        "INSERT INTO affiliate_milestones (owner_email, tier_subscribers, bonus_cents) "
                        "VALUES (%s, %s, %s) ON CONFLICT (owner_email, tier_subscribers) DO NOTHING",
                        (email, m.subscribers, m.bonus_cents))
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        self.cur.execute(
            "SELECT tier_subscribers, bonus_cents, earned_at FROM affiliate_milestones WHERE owner_email = %s",
            (email,))
        return {int(r[0]): {"bonus_cents": int(r[1]), "earned_at": r[2]} for r in self.cur.fetchall()}

    def overview(self, affiliate: dict, cfg: AffiliatesConfig) -> dict:
        code_ids = [c["id"] for c in affiliate["codes"]]
        count, price_sum = self._active_paying(code_ids)
        earnings = int((Decimal(price_sum) * Decimal(str(cfg.commission_rate))).quantize(Decimal("1"), ROUND_HALF_UP))
        earned = self._record_milestones(affiliate["email"], count, cfg)
        milestones = []
        for m in cfg.milestones:
            e = earned.get(m.subscribers)
            milestones.append({
                "subscribers": m.subscribers,
                "bonus_cents": e["bonus_cents"] if e else m.bonus_cents,
                "earned": e is not None,
                "earned_at": e["earned_at"].astimezone(timezone.utc).date().isoformat() if e else None,
            })
        return {
            "v": 1,
            "codes": [{"code": c["code"], "active": c["active"], "link": cfg.code_link(c["code"])}
                      for c in affiliate["codes"]],
            "metrics": {
                "active_paying_subscribers": count,
                "monthly_earnings_cents": earnings,
                "commission_rate": cfg.commission_rate,
            },
            "series": {u: self._series(code_ids, u, cfg.series_points[u]) for u in SERIES_UNITS},
            "milestones": milestones,
            "generated_at": datetime.now(timezone.utc).isoformat(),
        }
