"""Tests for task 20260930-creator-friend-codes step 1 (trial removal):
TRIAL_MONTHS eager config validation, no-trial Stripe checkout params, and a
regression that the Stripe webhook still handles 'trialing' subscriptions.

Run:  cd api && ../.venv/bin/python tests/test_trial_removal_config.py
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
from backend.subscription import stripe_service  # noqa: E402
from backend.subscription.stripe_service import TrialConfigError  # noqa: E402
from routes.subscription import subscription_router  # noqa: E402

app = FastAPI()
app.include_router(subscription_router)
client = TestClient(app)

PASSED, FAILED = [], []
_ORIG_ENV = os.environ.get("TRIAL_MONTHS")
_ORIG_RAW = stripe_service._TRIAL_MONTHS_RAW
_ORIG_PARSED = stripe_service._trial_months


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def set_env(value):
    if value is None:
        os.environ.pop("TRIAL_MONTHS", None)
        stripe_service._TRIAL_MONTHS_RAW = None
    else:
        os.environ["TRIAL_MONTHS"] = value
        stripe_service._TRIAL_MONTHS_RAW = value
    stripe_service._trial_months = None


def restore():
    if _ORIG_ENV is None:
        os.environ.pop("TRIAL_MONTHS", None)
    else:
        os.environ["TRIAL_MONTHS"] = _ORIG_ENV
    stripe_service._TRIAL_MONTHS_RAW = _ORIG_RAW
    stripe_service._trial_months = _ORIG_PARSED


def raises_trial_err(value):
    set_env(value)
    try:
        stripe_service.validate_trial_config()
    except TrialConfigError as e:
        return str(e)
    return None


def test_config_validation():
    print("\n=== validate_trial_config ===")
    msg = raises_trial_err(None)
    check("unset -> TrialConfigError naming TRIAL_MONTHS (no implicit default)",
          msg is not None and "TRIAL_MONTHS" in msg, str(msg))
    check("empty string -> error", raises_trial_err("") is not None)
    check("whitespace -> error", raises_trial_err("   ") is not None)
    msg = raises_trial_err("abc")
    check("non-integer -> error", msg is not None and "integer" in msg, str(msg))
    check("float string -> error", raises_trial_err("1.5") is not None)
    msg = raises_trial_err("-1")
    check("negative -> error", msg is not None and "0 or greater" in msg, str(msg))

    set_env("0")
    stripe_service.validate_trial_config()
    check("'0' valid, trial_months()==0", stripe_service.trial_months() == 0)
    set_env("2")
    stripe_service.validate_trial_config()
    check("'2' valid, trial_months()==2", stripe_service.trial_months() == 2)

    set_env("0")
    stripe_service._trial_months = None
    try:
        stripe_service.trial_months()
        check("trial_months() before validation raises", False, "did not raise")
    except TrialConfigError:
        check("trial_months() before validation raises", True)


class _FakeSession:
    url = "https://stripe.test/session"


def _capture_checkout(months_env, member_count=1):
    set_env(months_env)
    stripe_service.validate_trial_config()
    captured = {}
    orig = stripe_service.stripe.checkout.Session.create

    def fake_create(**kw):
        captured.update(kw)
        return _FakeSession()

    stripe_service.stripe.checkout.Session.create = fake_create
    try:
        url = stripe_service.create_checkout_session("u1", "u@example.com", member_count)
    finally:
        stripe_service.stripe.checkout.Session.create = orig
    return url, captured


def test_checkout_params():
    print("\n=== create_checkout_session trial params ===")
    url, kw = _capture_checkout("0")
    sd = kw["subscription_data"]
    check("TRIAL_MONTHS=0: trial_period_days omitted entirely", "trial_period_days" not in sd, str(sd))
    check("TRIAL_MONTHS=0: returns session url", url == _FakeSession.url)
    check("TRIAL_MONTHS=0: metadata preserved on subscription_data",
          sd.get("metadata") == {"user_id": "u1", "member_count": "1"}, str(sd))
    check("TRIAL_MONTHS=0: mode subscription, price_data unchanged",
          kw["mode"] == "subscription"
          and kw["line_items"][0]["price_data"]["unit_amount"] == stripe_service.price_for(1)
          and kw["line_items"][0]["price_data"]["unit_amount"] == 499,
          str(kw["line_items"]))
    # The schema constant (TRIAL_MONTHS=1) must no longer drive checkout.
    check("schema TRIAL_MONTHS constant does not leak into checkout", "trial_period_days" not in sd)

    _, kw = _capture_checkout("1")
    check("TRIAL_MONTHS=1: trial_period_days == 30",
          kw["subscription_data"].get("trial_period_days") == 30, str(kw["subscription_data"]))
    _, kw = _capture_checkout("3")
    check("TRIAL_MONTHS=3: trial_period_days == 90",
          kw["subscription_data"].get("trial_period_days") == 90)

    set_env("0")
    stripe_service.validate_trial_config()
    try:
        stripe_service.create_checkout_session("u1", "u@example.com", 9)
        check("member_count out of range still ValueError", False, "no raise")
    except ValueError:
        check("member_count out of range still ValueError", True)

    set_env("0")
    stripe_service._trial_months = None
    try:
        stripe_service.create_checkout_session("u1", "u@example.com", 1)
        check("checkout without validated config raises (no silent default)", False, "no raise")
    except TrialConfigError:
        check("checkout without validated config raises (no silent default)", True)


def test_lifespan_boot_validates():
    print("\n=== main.py lifespan wiring ===")
    src = open(os.path.join(os.path.dirname(__file__), "..", "main.py")).read()
    check("main.py lifespan calls validate_trial_config()", "validate_trial_config()" in src)


def _row(sub_id):
    db = DBManager()
    try:
        db.cur.execute("SELECT status, trial_end FROM subscriptions WHERE _id=%s", (sub_id,))
        return db.cur.fetchone()
    finally:
        db.close()


def test_trialing_webhook_regression():
    print("\n=== Stripe webhook still handles 'trialing' ===")
    set_env("0")
    stripe_service.validate_trial_config()
    uid = str(uuid.uuid4())
    uname = f"trial_reg_{uid[:8]}"
    stripe_sub = f"sub_{uuid.uuid4().hex[:12]}"
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": uname,
                               "email": f"{uname}@example.com", "hash_pass": "x"})
    finally:
        db.close()

    orig_construct = stripe_service.construct_event
    orig_retrieve = stripe_service.retrieve_subscription
    state = {"event": None}
    stripe_service.construct_event = lambda payload, sig: state["event"]
    trial_end = 1999999999
    stripe_service.retrieve_subscription = lambda sid: {
        "status": "trialing", "trial_end": trial_end, "current_period_end": trial_end}
    try:
        state["event"] = {"type": "checkout.session.completed", "data": {"object": {
            "client_reference_id": uid, "customer": "cus_x", "subscription": stripe_sub,
            "metadata": {"user_id": uid, "member_count": "1"}}}}
        r = client.post("/subscriptions/stripe/webhook", content=b"{}",
                        headers={"stripe-signature": "x"})
        check("checkout.session.completed w/ trialing sub -> 200", r.status_code == 200, r.text)
        db = DBManager()
        try:
            db.cur.execute("SELECT _id, status, trial_end FROM subscriptions WHERE stripe_subscription_id=%s",
                           (stripe_sub,))
            row = db.cur.fetchone()
        finally:
            db.close()
        check("row stored with status 'trialing' and trial_end set",
              row is not None and row[1] == "trialing" and row[2] is not None, str(row))
        sub_id = str(row[0]) if row else None

        # trialing -> active transition (customer.subscription.updated)
        state["event"] = {"type": "customer.subscription.updated", "data": {"object": {
            "id": stripe_sub, "status": "active", "current_period_end": trial_end + 100,
            "trial_end": None}}}
        r = client.post("/subscriptions/stripe/webhook", content=b"{}",
                        headers={"stripe-signature": "x"})
        check("subscription.updated trialing->active -> 200", r.status_code == 200, r.text)
        check("status now active", sub_id and _row(sub_id)[0] == "active", str(_row(sub_id) if sub_id else None))

        # no-trial purchase path: active at completion, no trial_end
        stripe_sub2 = f"sub_{uuid.uuid4().hex[:12]}"
        stripe_service.retrieve_subscription = lambda sid: {
            "status": "active", "trial_end": None, "current_period_end": trial_end}
        state["event"] = {"type": "checkout.session.completed", "data": {"object": {
            "client_reference_id": uid, "customer": "cus_x", "subscription": stripe_sub2,
            "metadata": {"user_id": uid, "member_count": "1"}}}}
        r = client.post("/subscriptions/stripe/webhook", content=b"{}",
                        headers={"stripe-signature": "x"})
        db = DBManager()
        try:
            db.cur.execute("SELECT status, trial_end FROM subscriptions WHERE stripe_subscription_id=%s",
                           (stripe_sub2,))
            row2 = db.cur.fetchone()
        finally:
            db.close()
        check("no-trial checkout completion -> active, trial_end NULL",
              r.status_code == 200 and row2 is not None and row2[0] == "active" and row2[1] is None, str(row2))
    finally:
        stripe_service.construct_event = orig_construct
        stripe_service.retrieve_subscription = orig_retrieve
        db = DBManager()
        try:
            db.delete("subscriptions", {"user_id": uid})
            db.delete("users", {"_id": uid})
        finally:
            db.close()


def main():
    try:
        test_config_validation()
        test_checkout_params()
        test_lifespan_boot_validates()
        test_trialing_webhook_regression()
    finally:
        restore()
    print(f"\nRESULT: {len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        raise SystemExit(1)
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
