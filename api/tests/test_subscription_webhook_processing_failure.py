"""Regression test for task 20260808-ios-backend-integration-audit, backend
step 14's fix to POST /subscriptions/stripe/webhook and
POST /subscriptions/apple/notifications.

Before the fix, both handlers wrapped their event-processing dispatch in
`except Exception: logger.error(...)` with NO re-raise, then unconditionally
returned `{"received": True}` (200). Stripe and Apple both treat a 200
response as "delivered, do not retry" — so a transient DB failure while
applying a renewal/cancellation/payment-failure event was silently and
PERMANENTLY discarded: the processor believes the status change was applied,
the sender never retries, and the row is left stale forever with only a log
line as evidence. This is incident #1's silent-swallow-into-false-success
pattern, on the payment webhook ingestion path.

The fix re-raises as HTTPException(500) after logging, so the processor's
real automatic retry schedule actually re-delivers the event once the
transient failure clears — safe because every handler on both paths is
idempotent (upsert/update/cancel by processor id).

This test proves the fix end to end against the REAL app (real subscription
router, real Postgres) — not just that a 500 is returned, but that the
underlying row is (a) left untouched while the failure is live and (b) is
correctly brought up to date by the exact retry Stripe/Apple would perform
once it's cleared. Money-relevant directions are covered both ways:
  - Stripe `invoice.payment_failed` dropped silently would leave a card-declined
    user showing as fully paid/active forever (a lost payment-failure signal).
  - Stripe `customer.subscription.deleted` dropped silently would leave a
    customer who cancelled/was refunded in Stripe still shown as an active
    paying member of a group plan forever (the user keeps access with no
    money moving, and correctly-cancelled seats are never freed).
  - Apple `EXPIRED` (App Store Server Notification) dropped silently would
    leave a lapsed Apple subscriber's plan row intact forever (paid access
    granted with no corresponding active StoreKit subscription).

Run:  cd api && ../.venv/bin/python tests/test_subscription_webhook_processing_failure.py
"""
import _pathfix  # noqa: F401

import os
import sys
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from db import DBManager  # noqa: E402
import backend.subscription.subscriptions as subs_mod  # noqa: E402
from backend.subscription import apple_service, stripe_service  # noqa: E402
from routes.subscription import subscription_router  # noqa: E402

app = FastAPI()
app.include_router(subscription_router)
client = TestClient(app)

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def make_user_with_sub(provider: str, status: str, stripe_sub_id: str = "", apple_txn: str = ""):
    uid = str(uuid.uuid4())
    uname = f"webhook_test_{uid[:8]}"
    sub_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": uname,
                               "email": f"{uname}@example.com", "hash_pass": "x"})
        db.insertion("subscriptions", {
            "_id": sub_id, "user_id": uid, "plan_type": "group",
            "provider": provider, "status": status,
            "stripe_subscription_id": stripe_sub_id,
            "apple_original_transaction_id": apple_txn,
        })
        db.update("users", {"subscription_id": sub_id}, {"_id": uid})
    finally:
        db.close()
    return uid, sub_id


def sub_status(sub_id: str):
    """Raw Postgres read — bypass the app entirely."""
    db = DBManager()
    try:
        db.cur.execute("SELECT status FROM subscriptions WHERE _id=%s", (sub_id,))
        row = db.cur.fetchone()
        return row[0] if row else "<row gone>"
    finally:
        db.close()


def cleanup(uid: str):
    db = DBManager()
    try:
        db.delete("subscriptions", {"user_id": uid})
        db.delete("users", {"_id": uid})
    finally:
        db.close()


def patch_flaky(cls, method_name: str):
    """Replace cls.method_name with a version that raises until unflaked,
    then delegates to the real implementation. Returns (unpatch, unflake)."""
    original = getattr(cls, method_name)
    state = {"should_fail": True}

    def flaky(self, *a, **kw):
        if state["should_fail"]:
            raise RuntimeError(f"simulated transient DB failure in {method_name}")
        return original(self, *a, **kw)

    setattr(cls, method_name, flaky)

    def unflake():
        state["should_fail"] = False

    def unpatch():
        setattr(cls, method_name, original)

    return unflake, unpatch


def test_stripe_payment_failed_not_silently_dropped():
    print("\n=== Stripe: invoice.payment_failed processing failure -> 500, not silently 200'd ===")
    stripe_sub_id = f"sub_{uuid.uuid4().hex[:12]}"
    uid, sub_id = make_user_with_sub("stripe", "active", stripe_sub_id=stripe_sub_id)

    event = {"type": "invoice.payment_failed", "data": {"object": {"subscription": stripe_sub_id}}}
    orig_construct_event = stripe_service.construct_event
    stripe_service.construct_event = lambda payload, sig: event
    unflake, unpatch = patch_flaky(subs_mod.SubscriptionsManager, "update_status_from_stripe")
    try:
        before = sub_status(sub_id)
        check("baseline status is 'active'", before == "active", before)

        r = client.post("/subscriptions/stripe/webhook", content=b"{}", headers={"stripe-signature": "x"})
        check("processing failure surfaces 500, not a false 200", r.status_code == 500, f"{r.status_code} {r.text}")
        check("row left untouched while failure is live (not silently marked past_due)",
              sub_status(sub_id) == "active", sub_status(sub_id))

        # Simulate Stripe's real retry: same event re-delivered once the
        # transient failure clears.
        unflake()
        r2 = client.post("/subscriptions/stripe/webhook", content=b"{}", headers={"stripe-signature": "x"})
        check("retried delivery after recovery -> 200", r2.status_code == 200, f"{r2.status_code} {r2.text}")
        check("retry actually applied the payment-failure status",
              sub_status(sub_id) == "past_due", sub_status(sub_id))
    finally:
        unpatch()
        stripe_service.construct_event = orig_construct_event
        cleanup(uid)


def test_stripe_subscription_deleted_not_silently_dropped():
    print("\n=== Stripe: customer.subscription.deleted processing failure -> 500, plan not silently kept alive ===")
    stripe_sub_id = f"sub_{uuid.uuid4().hex[:12]}"
    uid, sub_id = make_user_with_sub("stripe", "active", stripe_sub_id=stripe_sub_id)

    event = {"type": "customer.subscription.deleted", "data": {"object": {"id": stripe_sub_id}}}
    orig_construct_event = stripe_service.construct_event
    stripe_service.construct_event = lambda payload, sig: event
    unflake, unpatch = patch_flaky(subs_mod.SubscriptionsManager, "cancel_by_stripe_sub")
    try:
        r = client.post("/subscriptions/stripe/webhook", content=b"{}", headers={"stripe-signature": "x"})
        check("processing failure surfaces 500, not a false 200", r.status_code == 500, f"{r.status_code} {r.text}")
        check("plan row NOT deleted while failure is live (would otherwise leave a cancelled-in-Stripe "
              "user still shown as an active paying member)",
              sub_status(sub_id) == "active", sub_status(sub_id))

        unflake()
        r2 = client.post("/subscriptions/stripe/webhook", content=b"{}", headers={"stripe-signature": "x"})
        check("retried delivery after recovery -> 200", r2.status_code == 200, f"{r2.status_code} {r2.text}")
        check("retry actually removed the plan", sub_status(sub_id) == "<row gone>", sub_status(sub_id))
    finally:
        unpatch()
        stripe_service.construct_event = orig_construct_event
        # Row may already be gone (retry succeeded); cleanup() tolerates that.
        cleanup(uid)


def test_apple_expired_not_silently_dropped():
    print("\n=== Apple: EXPIRED notification processing failure -> 500, plan not silently kept alive ===")
    otxn = f"apple_txn_{uuid.uuid4().hex[:12]}"
    uid, sub_id = make_user_with_sub("apple", "active", apple_txn=otxn)

    def fake_decode_jws(jws):
        if jws == "ENVELOPE":
            return {"notificationType": "EXPIRED", "data": {"signedTransactionInfo": "TXNINFO"}}
        if jws == "TXNINFO":
            return {"originalTransactionId": otxn}
        raise ValueError("unexpected JWS in test")

    orig_decode_jws = apple_service.decode_jws
    apple_service.decode_jws = fake_decode_jws
    unflake, unpatch = patch_flaky(subs_mod.SubscriptionsManager, "cancel_by_apple_txn")
    try:
        r = client.post("/subscriptions/apple/notifications", json={"signedPayload": "ENVELOPE"})
        check("processing failure surfaces 500, not a false 200", r.status_code == 500, f"{r.status_code} {r.text}")
        check("plan row NOT deleted while failure is live (would otherwise leave a lapsed Apple "
              "subscriber with paid access and no corresponding active StoreKit subscription)",
              sub_status(sub_id) == "active", sub_status(sub_id))

        unflake()
        r2 = client.post("/subscriptions/apple/notifications", json={"signedPayload": "ENVELOPE"})
        check("retried delivery after recovery -> 200", r2.status_code == 200, f"{r2.status_code} {r2.text}")
        check("retry actually removed the plan", sub_status(sub_id) == "<row gone>", sub_status(sub_id))
    finally:
        unpatch()
        apple_service.decode_jws = orig_decode_jws
        cleanup(uid)


def test_happy_path_regression():
    print("\n=== Regression: a normal (non-failing) Apple DID_RENEW notification is unaffected ===")
    otxn = f"apple_txn_{uuid.uuid4().hex[:12]}"
    uid, sub_id = make_user_with_sub("apple", "trialing", apple_txn=otxn)

    def fake_decode_jws(jws):
        if jws == "ENVELOPE":
            return {"notificationType": "DID_RENEW", "data": {"signedTransactionInfo": "TXNINFO"}}
        if jws == "TXNINFO":
            return {"originalTransactionId": otxn, "expiresDate": None}
        raise ValueError("unexpected JWS in test")

    orig_decode_jws = apple_service.decode_jws
    apple_service.decode_jws = fake_decode_jws
    try:
        r = client.post("/subscriptions/apple/notifications", json={"signedPayload": "ENVELOPE"})
        check("happy-path notification -> 200 {'received': True}",
              r.status_code == 200 and r.json() == {"received": True}, f"{r.status_code} {r.text}")
        check("status correctly advanced trialing -> active", sub_status(sub_id) == "active", sub_status(sub_id))
    finally:
        apple_service.decode_jws = orig_decode_jws
        cleanup(uid)


def test_bad_signature_still_400():
    print("\n=== Regression: an unverifiable Stripe signature is still rejected 400, not swallowed by the new 500 path ===")

    def boom_construct_event(payload, sig):
        raise ValueError("signature mismatch")

    orig_construct_event = stripe_service.construct_event
    stripe_service.construct_event = boom_construct_event
    try:
        r = client.post("/subscriptions/stripe/webhook", content=b"{}", headers={"stripe-signature": "bad"})
        check("bad signature -> 400 (unchanged by the processing-failure fix)", r.status_code == 400,
              f"{r.status_code} {r.text}")
    finally:
        stripe_service.construct_event = orig_construct_event


def main():
    test_stripe_payment_failed_not_silently_dropped()
    test_stripe_subscription_deleted_not_silently_dropped()
    test_apple_expired_not_silently_dropped()
    test_happy_path_regression()
    test_bad_signature_still_400()

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
