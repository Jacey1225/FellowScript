"""Task 20261117-web-only-payments: uncapped seats, server-side pricing, and the
double-billing / free-seats guards on the subscription routes.

Proves: checkout prices >8 seats server-side (15 and 20 seats), rejects 0 and
>MAX_MEMBERS with 400 and never reaches Stripe; Apple-billed and already-active
Stripe users get 409 (no session created); PUT member_count reprices Stripe
first (seat change 8->15 passes price_for(15) to Stripe), 409s for Apple/inactive
plans without a DB change, 400s for out-of-range, and a Stripe failure leaves the
stored seat count unchanged (502); POST /subscriptions/ fails closed (410);
join logic honors a 15-seat plan; update_subscription_seats builds the right
Stripe call and refuses odd subscription shapes.

Run:  cd api && ../.venv/bin/python tests/test_web_only_seats.py
"""
import _pathfix  # noqa: F401

import os
import uuid

os.environ["TRIAL_MONTHS"] = "0"

from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from db import DBManager  # noqa: E402
from backend.auth.dependencies import get_current_user  # noqa: E402
from backend.subscription import stripe_service  # noqa: E402
from backend.subscription.subscriptions import SubscriptionsManager  # noqa: E402
from routes.subscription import subscription_router  # noqa: E402
from schemas.subscription import (  # noqa: E402
    MAX_MEMBERS, price_for, legacy_price_for, is_legacy_plan, seat_change_price)

app = FastAPI()
app.include_router(subscription_router)
CURRENT = {"uid": None}
app.dependency_overrides[get_current_user] = lambda: CURRENT["uid"]
client = TestClient(app)

CARD = {"brand": "visa", "last4": "4242", "exp_month": "01", "exp_year": "2030"}
PASSED, FAILED = [], []


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


def hdr():
    return {"cf-connecting-ip": f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"}


def make_user():
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"seat_{uid[:8]}",
                               "email": f"seat_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
    return uid


def cleanup(uid):
    db = DBManager()
    try:
        db.delete("subscriptions", {"user_id": uid})
        db.delete("users", {"_id": uid})
    finally:
        db.close()


def seats(sub_id):
    m = SubscriptionsManager()
    try:
        return m.get_subscription(sub_id)["max_members"]
    finally:
        m.close()


class Stubs:
    def __init__(self):
        self.sessions, self.modified, self.fail_modify = [], [], False
        self.orig = {}

    def __enter__(self):
        ss = stripe_service
        self.orig = dict(create=ss.stripe.checkout.Session.create, retrieve=ss.stripe.Subscription.retrieve,
                         modify=ss.stripe.Subscription.modify, configured=ss.is_configured)
        ss.stripe.checkout.Session.create = lambda **kw: (self.sessions.append(kw), type("S", (), {"url": "https://stripe.test/s"})())[1]
        ss.stripe.Subscription.retrieve = lambda sid: {"items": {"data": [{"id": "si_1", "price": {"product": "prod_1"}}]},
                                                      "metadata": {"user_id": "u"}}

        def modify(sid, **kw):
            if self.fail_modify:
                raise RuntimeError("stripe down")
            self.modified.append((sid, kw))
        ss.stripe.Subscription.modify = modify
        ss.is_configured = lambda: True
        ss._TRIAL_MONTHS_RAW = "0"
        ss._trial_months = None
        ss.validate_trial_config()
        return self

    def __exit__(self, *a):
        ss = stripe_service
        ss.stripe.checkout.Session.create = self.orig["create"]
        ss.stripe.Subscription.retrieve = self.orig["retrieve"]
        ss.stripe.Subscription.modify = self.orig["modify"]
        ss.is_configured = self.orig["configured"]


def test_checkout(st):
    print("\n=== POST /subscriptions/checkout: uncapped, server-priced, fail closed ===")
    uid = make_user()
    CURRENT["uid"] = uid
    try:
        for n in (9, 15, 20, MAX_MEMBERS):
            st.sessions.clear()
            r = client.post("/subscriptions/checkout", json={"user_id": uid, "member_count": n}, headers=hdr())
            amt = st.sessions[-1]["line_items"][0]["price_data"]["unit_amount"] if st.sessions else None
            check(f"checkout {n} seats -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            check(f"checkout {n} seats unit_amount == price_for({n})", amt == price_for(n), str(amt))
            check(f"checkout {n} seats metadata.member_count", st.sessions[-1]["metadata"]["member_count"] == str(n))
        for bad in (0, -3, MAX_MEMBERS + 1):
            st.sessions.clear()
            r = client.post("/subscriptions/checkout", json={"user_id": uid, "member_count": bad}, headers=hdr())
            check(f"checkout member_count={bad} -> 400, no Stripe session", r.status_code == 400 and not st.sessions,
                  f"{r.status_code} {len(st.sessions)}")
        # client cannot choose a price
        st.sessions.clear()
        client.post("/subscriptions/checkout", json={"user_id": uid, "member_count": 12, "price_cents": 1}, headers=hdr())
        check("client-supplied price ignored", st.sessions and st.sessions[-1]["line_items"][0]["price_data"]["unit_amount"] == price_for(12))
        CURRENT["uid"] = "someone-else"
        r = client.post("/subscriptions/checkout", json={"user_id": uid, "member_count": 2}, headers=hdr())
        check("checkout for another user -> 403", r.status_code == 403, str(r.status_code))
    finally:
        cleanup(uid)


def test_double_billing_guard(st):
    print("\n=== checkout 409 for Apple-billed and already-active Stripe plans ===")
    mgr = SubscriptionsManager()
    a, s, lapsed = make_user(), make_user(), make_user()
    try:
        mgr.upsert_from_apple(user_id=a, member_count=3, original_transaction_id=f"txn_{uuid.uuid4().hex[:10]}",
                              status="active", current_period_end=None, trial_end=None)
        mgr.upsert_from_stripe(user_id=s, member_count=2, customer_id="cus_t", stripe_sub_id=f"sub_{uuid.uuid4().hex[:10]}",
                               status="active", trial_end=None, current_period_end=None, card=CARD)
        mgr.upsert_from_stripe(user_id=lapsed, member_count=2, customer_id="cus_t", stripe_sub_id=f"sub_{uuid.uuid4().hex[:10]}",
                               status="canceled", trial_end=None, current_period_end=None, card=CARD)
        for uid, label, code in ((a, "apple-billed", "apple_subscription_active"), (s, "active stripe", "plan_already_active")):
            CURRENT["uid"] = uid
            st.sessions.clear()
            r = client.post("/subscriptions/checkout", json={"user_id": uid, "member_count": 12}, headers=hdr())
            body = r.json().get("detail", {}) if r.status_code == 409 else {}
            check(f"{label} user -> 409 {code}", r.status_code == 409 and body.get("code") == code, f"{r.status_code} {r.text[:120]}")
            check(f"{label} user: no Stripe session created", not st.sessions)
        CURRENT["uid"] = lapsed
        r = client.post("/subscriptions/checkout", json={"user_id": lapsed, "member_count": 12}, headers=hdr())
        check("canceled stripe plan may check out again", r.status_code == 200, f"{r.status_code} {r.text[:100]}")
    finally:
        mgr.close()
        for u in (a, s, lapsed):
            cleanup(u)


def test_put_seats(st):
    print("\n=== PUT /subscriptions/{id} member_count: Stripe first, never a bare write ===")
    mgr = SubscriptionsManager()
    uid, aid = make_user(), make_user()
    try:
        sub = mgr.upsert_from_stripe(user_id=uid, member_count=8, customer_id="cus_t", stripe_sub_id="sub_seat_t",
                                     status="active", trial_end=None, current_period_end=None, card=CARD)
        CURRENT["uid"] = uid
        r = client.put(f"/subscriptions/{sub}", json={"member_count": 15}, headers=hdr())
        check("8 -> 15 seats -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        check("stored max_members == 15", seats(sub) == 15, str(seats(sub)))
        sid, kw = st.modified[-1] if st.modified else (None, {})
        check("Stripe modified the host's subscription", sid == "sub_seat_t", str(sid))
        item = (kw.get("items") or [{}])[0]
        check("Stripe unit_amount == price_for(15)", item.get("price_data", {}).get("unit_amount") == price_for(15), str(item))
        check("Stripe call prorates", kw.get("proration_behavior") == "create_prorations")
        check("Stripe metadata member_count updated", kw.get("metadata", {}).get("member_count") == "15")

        st.modified.clear()
        for bad in (0, MAX_MEMBERS + 1):
            r = client.put(f"/subscriptions/{sub}", json={"member_count": bad}, headers=hdr())
            check(f"member_count={bad} -> 400, no Stripe call, seats unchanged", r.status_code == 400 and not st.modified and seats(sub) == 15,
                  f"{r.status_code} {seats(sub)}")

        st.fail_modify = True
        r = client.put(f"/subscriptions/{sub}", json={"member_count": 20}, headers=hdr())
        st.fail_modify = False
        check("Stripe failure -> 502 and stored seats unchanged", r.status_code == 502 and seats(sub) == 15, f"{r.status_code} {seats(sub)}")

        CURRENT["uid"] = aid
        r = client.put(f"/subscriptions/{sub}", json={"member_count": 9}, headers=hdr())
        check("non-host cannot change seats -> 403", r.status_code == 403, str(r.status_code))

        asub = mgr.upsert_from_apple(user_id=aid, member_count=2, original_transaction_id=f"txn_{uuid.uuid4().hex[:10]}",
                                     status="active", current_period_end=None, trial_end=None)
        st.modified.clear()
        r = client.put(f"/subscriptions/{asub}", json={"member_count": 40}, headers=hdr())
        check("Apple plan seat change -> 409 (no free seats), unchanged, no Stripe call",
              r.status_code == 409 and seats(asub) == 2 and not st.modified, f"{r.status_code} {seats(asub)}")
    finally:
        mgr.close()
        for u in (uid, aid):
            cleanup(u)


def test_post_create_disabled(st):
    print("\n=== POST /subscriptions/ fails closed ===")
    uid = make_user()
    CURRENT["uid"] = uid
    try:
        r = client.post("/subscriptions/", json={"user_id": uid, "member_count": 50}, headers=hdr())
        check("self-serve create -> 410", r.status_code == 410, f"{r.status_code} {r.text[:80]}")
        db = DBManager()
        try:
            db.cur.execute("SELECT count(*) FROM subscriptions WHERE user_id=%s AND plan_type != 'free'", (uid,))
            n = db.cur.fetchone()[0]
        finally:
            db.close()
        check("no paid plan row was created", n == 0, str(n))
        CURRENT["uid"] = "other"
        r = client.post("/subscriptions/", json={"user_id": uid, "member_count": 2}, headers=hdr())
        check("create for another user -> 403", r.status_code == 403, str(r.status_code))
    finally:
        cleanup(uid)


def test_update_subscription_seats_unit(st):
    print("\n=== stripe_service.update_subscription_seats ===")
    st.modified.clear()
    stripe_service.update_subscription_seats("sub_x", 12)
    sid, kw = st.modified[-1]
    it = kw["items"][0]
    check("existing item id reused, product reused", it["id"] == "si_1" and it["price_data"]["product"] == "prod_1", str(it))
    check("unit_amount == price_for(12), monthly USD", it["price_data"]["unit_amount"] == price_for(12)
          and it["price_data"]["recurring"] == {"interval": "month"} and it["price_data"]["currency"] == "usd")
    for bad in (0, MAX_MEMBERS + 1):
        st.modified.clear()
        try:
            stripe_service.update_subscription_seats("sub_x", bad)
            check(f"{bad} seats raises ValueError", False, "no raise")
        except ValueError:
            check(f"{bad} seats raises ValueError before any Stripe write", not st.modified)
    orig = stripe_service.stripe.Subscription.retrieve
    stripe_service.stripe.Subscription.retrieve = lambda sid: {"items": {"data": [{}, {}]}}
    try:
        stripe_service.update_subscription_seats("sub_x", 3)
        check("two-item subscription refused", False, "no raise")
    except ValueError:
        check("two-item subscription refused", True)
    finally:
        stripe_service.stripe.Subscription.retrieve = orig


def test_legacy_vs_new_schedule(st):
    print("\n=== existing subscribers keep the legacy schedule; new plans use the formula ===")
    check("schedules never coincide for 1..100 (marker is unambiguous)",
          all(legacy_price_for(n) != price_for(n) for n in range(1, 101)))
    check("legacy table 1/2/8 = 499/810/3240, 9 = 3645, 12 = 4860",
          [legacy_price_for(n) for n in (1, 2, 8, 9, 12)] == [499, 810, 3240, 3645, 4860])
    check("row at legacy price is legacy; row at new price is not",
          is_legacy_plan(2, 810) and not is_legacy_plan(2, 900) and is_legacy_plan(2, 1799) and is_legacy_plan(None, None))
    check("seat_change_price: legacy 2@810 -> 3 = 1215; new 2@900 -> 3 = 1350",
          seat_change_price(2, 810, 3) == 1215 and seat_change_price(2, 900, 3) == 1350)
    try:
        seat_change_price(2, 810, 101)
        check("legacy plan above cap raises", False, "no raise")
    except ValueError:
        check("legacy plan above cap raises", True)

    mgr = SubscriptionsManager()
    uid = make_user()
    try:
        sub = mgr.upsert_from_stripe(user_id=uid, member_count=2, customer_id="cus_l", stripe_sub_id="sub_legacy_t",
                                     status="active", trial_end=None, current_period_end=None, card=CARD)
        db = DBManager()
        try:  # simulate a pre-change row (written at the old 2-seat price)
            db.cur.execute("UPDATE subscriptions SET price_cents=810 WHERE _id=%s", (sub,))
            db.conn.commit()
        finally:
            db.close()
        CURRENT["uid"] = uid
        st.modified.clear()
        r = client.put(f"/subscriptions/{sub}", json={"member_count": 8}, headers=hdr())
        sid, kw = st.modified[-1] if st.modified else (None, {})
        amt = (kw.get("items") or [{}])[0].get("price_data", {}).get("unit_amount")
        check("legacy 2 -> 8 seats: 200 and Stripe unit_amount == legacy 3240 (not new 3600)",
              r.status_code == 200 and amt == 3240, f"{r.status_code} {amt}")
        m2 = SubscriptionsManager()
        try:
            check("stored price_cents == 3240 (stays legacy)", m2.get_subscription(sub)["price_cents"] == 3240)
        finally:
            m2.close()
    finally:
        mgr.close()
        cleanup(uid)


def test_seat_quote(st):
    print("\n=== GET /subscriptions/quote?seats=N: server price, legacy aware, Apple blocked, fail closed ===")
    mgr = SubscriptionsManager()
    uid, ap = make_user(), make_user()
    try:
        CURRENT["uid"] = ap
        for n, want in ((1, 500), (2, 900), (20, 9000), (100, price_for(100))):
            r = client.get(f"/subscriptions/quote?seats={n}", headers=hdr())
            j = r.json() if r.status_code == 200 else {}
            check(f"free caller quote {n} == price_for", r.status_code == 200 and j.get("total_cents") == want == price_for(n), r.text)
        keys = {"seats", "unit_cents", "discount_percent", "discount_start_seats", "total_cents", "currency",
                "min_seats", "max_seats", "legacy", "blocked", "blocked_reason"}
        check("stable response keys", set(j) == keys and j["currency"] == "usd" and j["min_seats"] == 1
              and j["max_seats"] == MAX_MEMBERS and not j["legacy"] and not j["blocked"], str(j))
        for bad in ("0", str(MAX_MEMBERS + 1), "-1", "abc"):
            r = client.get(f"/subscriptions/quote?seats={bad}", headers=hdr())
            check(f"quote seats={bad} -> 422", r.status_code == 422, str(r.status_code))
        sub = mgr.upsert_from_stripe(user_id=uid, member_count=2, customer_id="cus_q", stripe_sub_id=f"sub_{uuid.uuid4().hex[:10]}",
                                     status="active", trial_end=None, current_period_end=None, card=CARD)
        CURRENT["uid"] = uid
        r = client.get("/subscriptions/quote?seats=5", headers=hdr())
        check("new-schedule host quote 5 == price_for(5), not legacy",
              r.status_code == 200 and r.json()["total_cents"] == price_for(5) and not r.json()["legacy"], r.text)
        db = DBManager()
        try:
            db.cur.execute("UPDATE subscriptions SET price_cents=810 WHERE _id=%s", (sub,))
            db.conn.commit()
        finally:
            db.close()
        r = client.get("/subscriptions/quote?seats=5", headers=hdr())
        check("legacy host quote 5 == 2025 (not 2250), legacy flag",
              r.status_code == 200 and r.json()["total_cents"] == 2025 and r.json()["legacy"], r.text)
        db = DBManager()
        try:
            db.cur.execute("UPDATE subscriptions SET provider='apple' WHERE _id=%s", (sub,))
            db.conn.commit()
        finally:
            db.close()
        r = client.get("/subscriptions/quote?seats=5", headers=hdr())
        j = r.json()
        check("Apple-billed plan -> blocked, no price", r.status_code == 200 and j["blocked"] and j["total_cents"] is None
              and j["blocked_reason"] == "apple_subscription_active", r.text)
        r = client.post("/subscriptions/checkout", json={"user_id": uid, "member_count": 2}, headers=hdr())
        check("checkout still 409 for Apple plan", r.status_code == 409, str(r.status_code))
    finally:
        mgr.close()
        cleanup(uid)
        cleanup(ap)


def test_join_honors_seats():
    print("\n=== membership capacity follows the purchased seat count (no 8 cap) ===")
    mgr = SubscriptionsManager()
    host = make_user()
    members = [make_user() for _ in range(11)]
    try:
        sub = mgr.upsert_from_stripe(user_id=host, member_count=12, customer_id="cus_t", stripe_sub_id=f"sub_{uuid.uuid4().hex[:10]}",
                                     status="active", trial_end=None, current_period_end=None, card=CARD)
        check("plan stores 12 seats", seats(sub) == 12)
        db = DBManager()
        try:
            for m in members:
                db.cur.execute("UPDATE users SET subscription_id=%s WHERE _id=%s", (sub, m))
            db.conn.commit()
        except Exception as e:  # schema drift should surface, not hide
            db.conn.rollback()
            check("insert 11 members", False, repr(e))
        finally:
            db.close()
        check("get_members returns host + 11 members (12 seats, beyond the old cap)", len(mgr.get_members(sub)) == 12, str(len(mgr.get_members(sub))))
    finally:
        mgr.close()
        db = DBManager()
        try:
            for m in members:
                db.cur.execute("UPDATE users SET subscription_id=NULL WHERE _id=%s", (m,))
            db.conn.commit()
        finally:
            db.close()
        for u in [host] + members:
            cleanup(u)


def main():
    with Stubs() as st:
        test_checkout(st)
        test_double_billing_guard(st)
        test_put_seats(st)
        test_legacy_vs_new_schedule(st)
        test_seat_quote(st)
        test_post_create_disabled(st)
        test_update_subscription_seats_unit(st)
    test_join_honors_seats()
    print(f"\nRESULT: {len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        for f in FAILED:
            print("  X", f)
        raise SystemExit(1)
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
