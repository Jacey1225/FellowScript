"""Stripe subscriber price migration for the 2026-10-01 price cut
(task 20261001-subscription-price-cut).

NEVER run by build gates. The orchestrator/operator runs it by hand, dry-run
first. Run from the ``api/`` directory:

    python scripts/stripe_price_migration.py                  # dry run (default, read-only)
    python scripts/stripe_price_migration.py --apply          # test-mode key: perform changes
    python scripts/stripe_price_migration.py --apply --confirm-live   # live (sk_live_) key
    python scripts/stripe_price_migration.py --print-db-sql   # emit the price_cents backfill SQL

What it does
------------
Checkout builds inline ``price_data`` (no pre-created Price objects), so every
subscription's item points at an ad-hoc Price. For each Stripe subscription in
``active`` / ``trialing`` / ``past_due`` that was created by our checkout
(``metadata.member_count`` present), it compares the item's ``unit_amount``
with the table and:

* ``unit_amount == NEW``  -> already migrated: no-op (idempotent re-run).
* ``unit_amount == OLD``  -> ``Subscription.modify`` swapping the item to an
  inline ``price_data`` at the NEW amount (same product, usd, monthly),
  ``proration_behavior="none"``: no credit, no charge now; the new amount is
  billed from the NEXT renewal. Billing anchor and the current paid period are
  untouched. Percent-based coupons/discounts are left alone and so
  auto-adjust.
* anything else (custom amount, multi-item, non-usd, non-monthly, missing or
  bad metadata) -> skipped and reported; never modified.

Safety: dry-run unless ``--apply``; a live key additionally needs
``--confirm-live``; each modify carries a deterministic idempotency key; every
per-subscription outcome is logged (ids and amounts only). The Stripe secret
is read from ``STRIPE_SECRET_KEY`` (api/.env via python-dotenv, the same path
the app uses) and is never printed; only the key mode (test/live) is shown.

The DB ``subscriptions.price_cents`` column is NOT changed by Stripe events
(the webhook only syncs status/period), so it is backfilled separately with
the SQL from ``--print-db-sql`` (idempotent; run via psql on the server).
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from schemas.subscription import GROUP_PRICE_CENTS, MIN_MEMBERS, MAX_MEMBERS  # noqa: E402

# Prices in force before the 2026-10-01 cut (the code table, not Apple's).
OLD_PRICE_CENTS: dict[int, int] = {
    1: 1000, 2: 1799, 3: 2699, 4: 3599, 5: 4499, 6: 5399, 7: 6299, 8: 7199,
}
MIGRATE_STATUSES = ("active", "trialing", "past_due")

NOOP = "noop_already_new"
MIGRATE = "migrate"
SKIP = "skip"


def classify(unit_amount, member_count: int) -> str:
    """Pure decision for one subscription item."""
    if unit_amount == GROUP_PRICE_CENTS[member_count]:
        return NOOP
    if unit_amount == OLD_PRICE_CENTS[member_count]:
        return MIGRATE
    return SKIP


def _member_count(sub) -> int | None:
    raw = (sub.get("metadata") or {}).get("member_count")
    try:
        n = int(raw)
    except (TypeError, ValueError):
        return None
    return n if MIN_MEMBERS <= n <= MAX_MEMBERS else None


def plan_subscription(sub) -> dict:
    """Return ``{action, reason, member_count, item_id, product, old, new}`` for one
    Stripe subscription. Pure: no network."""
    out = {"sub_id": sub.get("id"), "action": SKIP, "reason": "", "member_count": None,
           "item_id": None, "product": None, "old": None, "new": None}
    if sub.get("status") not in MIGRATE_STATUSES:
        out["reason"] = f"status {sub.get('status')}"
        return out
    n = _member_count(sub)
    if n is None:
        out["reason"] = "no valid metadata.member_count (not created by our checkout)"
        return out
    out["member_count"] = n
    items = (sub.get("items") or {}).get("data") or []
    if len(items) != 1:
        out["reason"] = f"{len(items)} items (expected exactly 1)"
        return out
    item = items[0]
    price = item.get("price") or {}
    rec = price.get("recurring") or {}
    if price.get("currency") != "usd" or rec.get("interval") != "month" or rec.get("interval_count", 1) != 1:
        out["reason"] = "price is not usd/monthly"
        return out
    product = price.get("product")
    if not isinstance(product, str):
        out["reason"] = "price.product is not an id string"
        return out
    out.update(item_id=item.get("id"), product=product, old=price.get("unit_amount"),
               new=GROUP_PRICE_CENTS[n])
    action = classify(price.get("unit_amount"), n)
    out["action"] = action
    if action == SKIP:
        out["reason"] = f"unit_amount {price.get('unit_amount')} matches neither old nor new table"
    return out


def modify_kwargs(plan: dict) -> dict:
    """Exact ``Subscription.modify`` arguments for a ``migrate`` plan."""
    return {
        "items": [{
            "id": plan["item_id"],
            "price_data": {
                "currency": "usd",
                "product": plan["product"],
                "unit_amount": plan["new"],
                "recurring": {"interval": "month"},
            },
        }],
        "proration_behavior": "none",
        "idempotency_key": f"price-cut-20261001:{plan['sub_id']}:{plan['new']}",
    }


def _iter(listing):
    return listing.auto_paging_iter() if hasattr(listing, "auto_paging_iter") else iter(listing)


def run(stripe_mod, apply: bool, log=print) -> dict:
    """Walk all subscriptions; modify only when ``apply``. Returns counters."""
    counts = {"noop": 0, "migrate": 0, "migrated": 0, "skip": 0, "error": 0}
    for sub in _iter(stripe_mod.Subscription.list(status="all", limit=100)):
        plan = plan_subscription(sub)
        sid = plan["sub_id"]
        if plan["action"] == NOOP:
            counts["noop"] += 1
            log(f"NOOP    {sid} members={plan['member_count']} already {plan['new']}")
        elif plan["action"] == SKIP:
            counts["skip"] += 1
            if plan["reason"].startswith("status"):
                continue  # canceled/incomplete/etc: not interesting, not logged per-row
            log(f"SKIP    {sid} {plan['reason']}")
        else:
            counts["migrate"] += 1
            msg = f"members={plan['member_count']} {plan['old']} -> {plan['new']}"
            if not apply:
                log(f"WOULD   {sid} {msg}")
                continue
            try:
                stripe_mod.Subscription.modify(sid, **modify_kwargs(plan))
                counts["migrated"] += 1
                log(f"MIGRATED {sid} {msg}")
            except Exception as e:  # report and continue; re-run retries the failures
                counts["error"] += 1
                log(f"ERROR   {sid} {msg} ({type(e).__name__})")
    return counts


def db_backfill_sql() -> str:
    """Idempotent SQL aligning ``subscriptions.price_cents`` with the new table."""
    whens = " ".join(f"WHEN {n} THEN {c}" for n, c in sorted(GROUP_PRICE_CENTS.items()))
    case = f"CASE max_members {whens} END"
    return (
        f"UPDATE subscriptions SET price_cents = {case}\n"
        f" WHERE plan_type = 'group' AND max_members BETWEEN {MIN_MEMBERS} AND {MAX_MEMBERS}\n"
        f"   AND price_cents <> {case};"
    )


def _load_key() -> str:
    try:
        from dotenv import load_dotenv
        load_dotenv(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"))
    except ImportError:
        pass
    key = os.getenv("STRIPE_SECRET_KEY", "").strip()
    if not (key.startswith("sk_live_") or key.startswith("sk_test_")):
        raise SystemExit("STRIPE_SECRET_KEY is missing or not an sk_live_/sk_test_ key.")
    return key


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--apply", action="store_true", help="perform changes (default: dry run)")
    ap.add_argument("--confirm-live", action="store_true", help="required with --apply for an sk_live_ key")
    ap.add_argument("--print-db-sql", action="store_true", help="print the price_cents backfill SQL and exit")
    args = ap.parse_args(argv)
    if args.print_db_sql:
        print(db_backfill_sql())
        return 0
    key = _load_key()
    live = key.startswith("sk_live_")
    if args.apply and live and not args.confirm_live:
        raise SystemExit("Refusing: live key with --apply needs --confirm-live.")
    import stripe
    stripe.api_key = key
    print(f"mode={'APPLY' if args.apply else 'DRY-RUN'} key={'live' if live else 'test'}")
    counts = run(stripe, apply=args.apply)
    print(f"summary: {counts}")
    return 1 if counts["error"] else 0


if __name__ == "__main__":
    sys.exit(main())
