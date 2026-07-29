"""Dynamic group membership pricing (1-8 members) — price table, Stripe/Apple
mapping, and plan creation/update all agree on price_cents/max_members.

Run:  cd api && ../.venv/bin/python tests/test_group_pricing.py
"""

import _pathfix  # noqa: F401

import uuid

from db import DBManager
from schemas.subscription import GROUP_PRICE_CENTS, MIN_MEMBERS, MAX_MEMBERS, price_for
from schemas.subscription import SubscriptionCreate, SubscriptionUpdate
from backend.subscription.subscriptions import SubscriptionsManager
from backend.subscription import apple_service
from backend.subscription import stripe_service

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got}, want {want}")


EXPECTED_PRICES = {
    1: 1000, 2: 1799, 3: 2699, 4: 3599, 5: 4499, 6: 5399, 7: 6299, 8: 7199,
}


def test_price_table():
    print("\n=== price_for() matches the exact price table for all 8 counts ===")
    for count, cents in EXPECTED_PRICES.items():
        check(f"price_for({count})", price_for(count), cents)
    check("MIN_MEMBERS", MIN_MEMBERS, 1)
    check("MAX_MEMBERS", MAX_MEMBERS, 8)
    check("out-of-range count falls back to 1-member price", price_for(99), EXPECTED_PRICES[1])


def test_apple_product_mapping():
    print("\n=== Apple product id -> member_count for all 8 products ===")
    for count in range(1, 9):
        product_id = f"com.fellowscript.app.group{count}"
        check(f"member_count_for({product_id})", apple_service.member_count_for(product_id), count)
    check("unknown product id maps to None",
          apple_service.member_count_for("com.fellowscript.app.nonexistent"), None)


def test_checkout_bounds():
    print("\n=== create_checkout_session rejects out-of-range member_count (no network call) ===")
    for bad_count in (0, 9, -1):
        try:
            stripe_service.create_checkout_session("user-x", "x@example.com", bad_count)
            check(f"member_count={bad_count} raises ValueError", "no error raised", "ValueError")
        except ValueError:
            check(f"member_count={bad_count} raises ValueError", True, True)


def test_create_and_update_subscription():
    print("\n=== create_subscription / update_subscription price+cap derivation ===")
    uid = str(uuid.uuid4())
    uname = f"pricing_test_{uid[:8]}"
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": uname,
                                "email": f"{uname}@example.com", "hash_pass": "x"})
    finally:
        db.close()

    mgr = SubscriptionsManager()
    sub_id = None
    try:
        sub_id = mgr.create_subscription(SubscriptionCreate(user_id=uid, member_count=3))
        row = mgr.get_subscription(sub_id)
        check("create_subscription(member_count=3) plan_type", row["plan_type"], "group")
        check("create_subscription(member_count=3) price_cents", row["price_cents"], EXPECTED_PRICES[3])
        check("create_subscription(member_count=3) max_members", row["max_members"], 3)

        mgr.update_subscription(sub_id, SubscriptionUpdate(member_count=7))
        row = mgr.get_subscription(sub_id)
        check("update_subscription(member_count=7) price_cents", row["price_cents"], EXPECTED_PRICES[7])
        check("update_subscription(member_count=7) max_members", row["max_members"], 7)
    finally:
        if sub_id:
            mgr.delete_subscription(sub_id)
        mgr.close()
        cleanup_db = DBManager()
        try:
            cleanup_db.delete("users", {"_id": uid})
        finally:
            cleanup_db.close()


def test_upsert_from_stripe_and_apple():
    print("\n=== upsert_from_stripe / upsert_from_apple derive price from member_count ===")
    uid = str(uuid.uuid4())
    uname = f"pricing_upsert_{uid[:8]}"
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": uname,
                                "email": f"{uname}@example.com", "hash_pass": "x"})
    finally:
        db.close()

    mgr = SubscriptionsManager()
    sub_id = None
    try:
        sub_id = mgr.upsert_from_stripe(
            user_id=uid, member_count=5, customer_id="cus_test", stripe_sub_id="sub_test",
            status="active", trial_end=None, current_period_end=None,
            card={"brand": "visa", "last4": "4242", "exp_month": "01", "exp_year": "2030"},
        )
        row = mgr.get_subscription(sub_id)
        check("upsert_from_stripe(member_count=5) price_cents", row["price_cents"], EXPECTED_PRICES[5])
        check("upsert_from_stripe(member_count=5) max_members", row["max_members"], 5)
        check("upsert_from_stripe plan_type", row["plan_type"], "group")

        sub_id2 = mgr.upsert_from_apple(
            user_id=uid, member_count=8, original_transaction_id="txn_test",
            status="active", current_period_end=None, trial_end=None,
        )
        check("upsert_from_apple reuses the same plan row for this user", sub_id2, sub_id)
        row = mgr.get_subscription(sub_id2)
        check("upsert_from_apple(member_count=8) price_cents", row["price_cents"], EXPECTED_PRICES[8])
        check("upsert_from_apple(member_count=8) max_members", row["max_members"], 8)
        check("upsert_from_apple plan_type", row["plan_type"], "group")
    finally:
        if sub_id:
            mgr.delete_subscription(sub_id)
        mgr.close()
        cleanup_db = DBManager()
        try:
            cleanup_db.delete("users", {"_id": uid})
        finally:
            cleanup_db.close()


def main():
    test_price_table()
    test_apple_product_mapping()
    test_checkout_bounds()
    test_create_and_update_subscription()
    test_upsert_from_stripe_and_apple()

    print(f"\n{'='*60}")
    passed, total = sum(results), len(results)
    if passed == total:
        print(f"RESULT: {passed}/{total} passed")
        print("STATUS: ALL PASS")
    else:
        print(f"RESULT: {passed}/{total} passed")
        print("STATUS: FAIL")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
