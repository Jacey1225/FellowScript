"""Regression: stripe>=13 objects are not dicts (no ``.get``). The promo
eligibility lookup, coupon checks, webhook event handling and card extraction
must work on real SDK objects, not just dict mocks (CI mocks hid this: creator
codes always answered "That code can't be used")."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")

import stripe
from backend.subscription import stripe_service as ss

fails = 0
def check(name, ok, detail=""):
    global fails
    print(("  OK   " if ok else "  FAIL ") + name + ("" if ok else f" -- {detail}"))
    if not ok:
        fails += 1

def so(d):
    return stripe.StripeObject.construct_from(d, "k")

def lo(items, has_more=False):
    return stripe.ListObject.construct_from({"object": "list", "data": items, "has_more": has_more}, "k")

orig = (stripe.Customer.list, stripe.Subscription.list, stripe.Coupon.retrieve)
try:
    # no customer -> never subscribed
    stripe.Customer.list = lambda **k: lo([])
    check("no Stripe customer -> no history", ss.customer_has_subscription_history("a@b.co") is False)
    # customer with active sub -> history
    stripe.Customer.list = lambda **k: lo([{"id": "cus_1"}])
    stripe.Subscription.list = lambda **k: lo([{"id": "sub_1", "status": "active"}])
    check("customer with active subscription -> history", ss.customer_has_subscription_history("a@b.co") is True)
    stripe.Subscription.list = lambda **k: lo([{"id": "sub_2", "status": "incomplete"}])
    check("only incomplete subscription -> no history", ss.customer_has_subscription_history("a@b.co") is False)
    stripe.Customer.list = lambda **k: lo([], has_more=True)
    check("more than one page -> fails closed (True)", ss.customer_has_subscription_history("a@b.co") is True)
    # coupon terms check
    stripe.Coupon.retrieve = lambda cid: so({"id": cid, "percent_off": 50, "duration": "once"})
    check("existing correct coupon accepted", ss.ensure_promo_coupon(50) == ss.promo_coupon_id(50))
    stripe.Coupon.retrieve = lambda cid: so({"id": cid, "percent_off": 10, "duration": "once"})
    try:
        ss.ensure_promo_coupon(50)
        check("changed coupon terms refused", False)
    except RuntimeError:
        check("changed coupon terms refused", True)
finally:
    stripe.Customer.list, stripe.Subscription.list, stripe.Coupon.retrieve = orig

# webhook event construction returns plain dicts the handlers can .get() on
ev = ss._plain(so({"type": "checkout.session.completed", "data": {"object": {"id": "cs_1", "metadata": {"user_id": "u"}}}}))
check("event is plain dict; obj.get / nested metadata.get work",
      ev["data"]["object"].get("id") == "cs_1" and (ev["data"]["object"].get("metadata") or {}).get("user_id") == "u")

# card extraction from SDK-derived dict and from attribute objects
sub = ss._plain(so({"default_payment_method": {"card": {"brand": "visa", "last4": "4242", "exp_month": 1, "exp_year": 2030}}}))
check("card_from_subscription on plain dict", ss.card_from_subscription(sub) == {"brand": "visa", "last4": "4242", "exp_month": "1", "exp_year": "2030"})
check("card_from_subscription on SDK object", ss.card_from_subscription(so({"default_payment_method": {"card": {"brand": "visa", "last4": "4242", "exp_month": 1, "exp_year": 2030}}}))["last4"] == "4242")
check("card_from_subscription with no PM", ss.card_from_subscription({"default_payment_method": None})["last4"] == "")

print(f"RESULT: {'PASS' if not fails else 'FAIL'} ({fails} failures)")
sys.exit(1 if fails else 0)
