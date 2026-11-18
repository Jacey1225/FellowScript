"""Dynamic group membership pricing (any seat count 1..MAX_MEMBERS; $5/seat, 10% off from 2 seats) — price table, Stripe/Apple
mapping, and plan creation/update all agree on price_cents/max_members.

Run:  cd api && ../.venv/bin/python tests/test_group_pricing.py
"""

import _pathfix  # noqa: F401

import uuid

from db import DBManager
from schemas.subscription import MIN_MEMBERS, MAX_MEMBERS, SEAT_PRICING, price_for
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
    1: 500, 2: 900, 3: 1350, 4: 1800, 5: 2250, 6: 2700, 7: 3150, 8: 3600,
    9: 4050, 10: 4500, 15: 6750, 20: 9000, 100: 45000,
}


def test_price_table():
    print("\n=== price_for() matches the formula (500/seat, 10% off from 2 seats) ===")
    for count, cents in EXPECTED_PRICES.items():
        check(f"price_for({count})", price_for(count), cents)
    check("config values", (SEAT_PRICING["base_per_seat_cents"], SEAT_PRICING["group_discount_percent"],
                            SEAT_PRICING["discount_start_seats"]), (500, 10, 2))
    check("MIN_MEMBERS", MIN_MEMBERS, 1)
    check("MAX_MEMBERS (abuse guard)", MAX_MEMBERS, 100)
    check("1 seat gets no discount", price_for(1), 500)
    check("2 seats = 2*500*0.9", price_for(2), 900)
    check("strictly increasing 1..MAX", all(price_for(i) < price_for(i + 1) for i in range(1, MAX_MEMBERS)), True)
    check("per-seat price never above base", all(price_for(i) <= 500 * i for i in range(1, MAX_MEMBERS + 1)), True)


def test_uncapped_and_fail_closed():
    print("\n=== seats above 8 priced by formula; out of range / non-int fails closed ===")
    for count in (9, 15, 20, 50, MAX_MEMBERS):
        check(f"price_for({count}) == round(0.9*500*{count})", price_for(count), (count * 500 * 90 + 50) // 100)
    for bad in (0, -1, MAX_MEMBERS + 1, 99999, True, False, 1.5, "9", None):
        try:
            price_for(bad)
            check(f"price_for({bad!r}) raises ValueError (no fallback price)", "no error", "ValueError")
        except ValueError:
            check(f"price_for({bad!r}) raises ValueError (no fallback price)", True, True)


def test_rounding_half_up():
    print("\n=== rounding is half-up in integer math (monkeypatched config) ===")
    import schemas.subscription as sch
    orig = dict(sch.SEAT_PRICING)
    try:
        # 3 seats * 5 cents * 90% = 13.5 -> 14 (half up); 1 seat * 5 = 5.
        sch.SEAT_PRICING.update(base_per_seat_cents=5, group_discount_percent=10, discount_start_seats=2)
        check("13.5 rounds up to 14", sch.price_for(3), 14)
        sch.SEAT_PRICING.update(base_per_seat_cents=1, group_discount_percent=10)
        check("2*1*0.9=1.8 -> 2", sch.price_for(2), 2)
        sch.SEAT_PRICING.update(discount_start_seats=5)
        check("below discount_start_seats no discount", sch.price_for(4), 4)
        check("at discount_start_seats discounted", sch.price_for(5), 5)  # 4.5 -> 5
    finally:
        sch.SEAT_PRICING.clear()
        sch.SEAT_PRICING.update(orig)


def test_config_validation_fails_closed():
    print("\n=== seat_pricing.json loader fails closed on a bad file ===")
    import json, tempfile
    from pathlib import Path
    import schemas.subscription as sch
    orig_path = sch._SEAT_PRICING_PATH
    good = {"min_members": 1, "max_members": 100, "base_per_seat_cents": 500,
            "group_discount_percent": 10, "discount_start_seats": 2}
    cases = {
        "missing file": None,
        "extra key": {**good, "x": 1},
        "missing key": {k: v for k, v in good.items() if k != "max_members"},
        "string value": {**good, "base_per_seat_cents": "500"},
        "bool value": {**good, "min_members": True},
        "max < min": {**good, "max_members": 0},
        "zero base": {**good, "base_per_seat_cents": 0},
        "discount 100": {**good, "group_discount_percent": 100},
        "negative discount": {**good, "group_discount_percent": -1},
        "start seats 0": {**good, "discount_start_seats": 0},
    }
    try:
        with tempfile.TemporaryDirectory() as d:
            for label, body in cases.items():
                path = Path(d) / "seat_pricing.json"
                if body is None:
                    path = Path(d) / "nope.json"
                else:
                    path.write_text(json.dumps({"seat_pricing": body}))
                sch._SEAT_PRICING_PATH = path
                try:
                    sch._load_seat_pricing()
                    check(f"{label} -> RuntimeError", "loaded", "RuntimeError")
                except RuntimeError:
                    check(f"{label} -> RuntimeError", True, True)
            bad = Path(d) / "junk.json"
            bad.write_text("{not json")
            sch._SEAT_PRICING_PATH = bad
            try:
                sch._load_seat_pricing()
                check("malformed json -> RuntimeError", "loaded", "RuntimeError")
            except RuntimeError:
                check("malformed json -> RuntimeError", True, True)
            ok = Path(d) / "ok.json"
            ok.write_text(json.dumps({"seat_pricing": good}))
            sch._SEAT_PRICING_PATH = ok
            check("valid file loads", sch._load_seat_pricing()["base_per_seat_cents"], 500)
    finally:
        sch._SEAT_PRICING_PATH = orig_path


def test_apple_product_mapping():
    print("\n=== Apple product id -> member_count for all 8 products ===")
    words = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight"}
    for count, word in words.items():
        product_id = f"com.fellowscript.access.{word}"
        check(f"member_count_for({product_id})", apple_service.member_count_for(product_id), count)
    check("unknown product id maps to None",
          apple_service.member_count_for("com.fellowscript.access.nonexistent"), None)


def test_accepted_environment():
    print("\n=== is_accepted_environment gates StoreKit environments ===")
    # Local Xcode .storekit testing transactions (the source of the paid-plan
    # leak on dev devices) must never be treated as a real purchase.
    check("Xcode environment rejected",      apple_service.is_accepted_environment("Xcode"), False)
    check("Xcode (lowercase) rejected",      apple_service.is_accepted_environment("xcode"), False)
    check("Production accepted",             apple_service.is_accepted_environment("Production"), True)
    # Sandbox is accepted by default so App Review / TestFlight IAP still works.
    check("Sandbox accepted by default",     apple_service.is_accepted_environment("Sandbox"), True)
    check("missing environment rejected",    apple_service.is_accepted_environment(None), False)
    check("empty environment rejected",      apple_service.is_accepted_environment(""), False)
    check("unknown environment rejected",    apple_service.is_accepted_environment("Nonsense"), False)


def test_checkout_bounds():
    print("\n=== create_checkout_session rejects out-of-range member_count (no network call) ===")
    stripe_service._TRIAL_MONTHS_RAW = "0"
    stripe_service._trial_months = None
    stripe_service.validate_trial_config()
    for bad_count in (0, MAX_MEMBERS + 1, -1):
        try:
            stripe_service.create_checkout_session("user-x", "x@example.com", bad_count)
            check(f"member_count={bad_count} raises ValueError", "no error raised", "ValueError")
        except ValueError:
            check(f"member_count={bad_count} raises ValueError", True, True)


def test_create_and_update_subscription():  # noqa: C901
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

        mgr.update_subscription(sub_id, SubscriptionUpdate(member_count=15))
        row = mgr.get_subscription(sub_id)
        check("update_subscription(member_count=15) price_cents", row["price_cents"], price_for(15))
        check("update_subscription(member_count=15) max_members", row["max_members"], 15)

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

        sub_id3 = mgr.upsert_from_stripe(
            user_id=uid, member_count=20, customer_id="cus_test", stripe_sub_id="sub_test",
            status="active", trial_end=None, current_period_end=None,
            card={"brand": "visa", "last4": "4242", "exp_month": "01", "exp_year": "2030"},
        )
        row = mgr.get_subscription(sub_id3)
        check("upsert_from_stripe(member_count=20) max_members honors purchased seats (no 8 cap)", row["max_members"], 20)
        check("upsert_from_stripe(member_count=20) price_cents", row["price_cents"], price_for(20))
    finally:
        if sub_id:
            mgr.delete_subscription(sub_id)
        mgr.close()
        cleanup_db = DBManager()
        try:
            cleanup_db.delete("users", {"_id": uid})
        finally:
            cleanup_db.close()


def test_upsert_from_apple_rejects_claimed_transaction():
    """A StoreKit transaction already tied to one account must not silently
    reassign to a different one (e.g. Transaction.currentEntitlements
    reporting the same device-level/sandbox entitlement to whichever
    FellowScript account is currently signed in on every launch)."""
    print("\n=== upsert_from_apple refuses a transaction already claimed by another user ===")
    uid1, uid2 = str(uuid.uuid4()), str(uuid.uuid4())
    db = DBManager()
    try:
        for uid in (uid1, uid2):
            db.insertion("users", {"_id": uid, "username": f"claim_test_{uid[:8]}",
                                    "email": f"claim_test_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()

    mgr = SubscriptionsManager()
    sub_id = None
    try:
        sub_id = mgr.upsert_from_apple(
            user_id=uid1, member_count=1, original_transaction_id="txn_shared",
            status="active", current_period_end=None, trial_end=None,
        )
        check("first claim of a fresh transaction succeeds", sub_id is not None, True)

        result = mgr.upsert_from_apple(
            user_id=uid2, member_count=8, original_transaction_id="txn_shared",
            status="active", current_period_end=None, trial_end=None,
        )
        check("second user claiming the same transaction is refused", result, None)

        row2 = mgr.get_user_subscription(uid2)
        check("the second user's plan is unaffected (still none)", row2, None)

        row1 = mgr.get_subscription(sub_id)
        check("the first user's plan is unaffected by the refused claim", row1["max_members"], 1)
    finally:
        if sub_id:
            mgr.delete_subscription(sub_id)
        mgr.close()
        cleanup_db = DBManager()
        try:
            cleanup_db.delete("users", {"_id": uid1})
            cleanup_db.delete("users", {"_id": uid2})
        finally:
            cleanup_db.close()


def test_free_plan_reported_as_no_subscription():
    """A free-tier plan must be reported as None by get_user_subscription so
    clients render the upgrade UI, not an active 'Group Plan' — the free row
    exists only to anchor usage counting."""
    print("\n=== get_user_subscription returns None for a free-tier user ===")
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"free_test_{uid[:8]}",
                                "email": f"free_test_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()

    mgr = SubscriptionsManager()
    sub_id = None
    try:
        sub_id = mgr.create_free_plan(uid)
        check("create_free_plan created a row", sub_id is not None, True)
        # The raw row exists and is free…
        raw = mgr.get_subscription(sub_id)
        check("the raw free row is plan_type=free", raw["plan_type"], "free")
        # …but the per-user query reports it as no subscription.
        check("get_user_subscription returns None for a free user",
              mgr.get_user_subscription(uid), None)
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
    test_uncapped_and_fail_closed()
    test_rounding_half_up()
    test_config_validation_fails_closed()
    test_apple_product_mapping()
    test_accepted_environment()
    test_free_plan_reported_as_no_subscription()
    test_checkout_bounds()
    test_create_and_update_subscription()
    test_upsert_from_stripe_and_apple()
    test_upsert_from_apple_rejects_claimed_transaction()

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
