"""Backend coverage for task 20260930-creator-friend-codes (promo / creator +
friend invite codes, phase 1 web/Stripe).

Proves: eager config validation; flag-off uniform 404 on every user/admin route
(before auth) and checkout ignoring promo_code; eligibility (case-insensitive,
inactive/expired/exhausted/inactive-creator, own friend code, group plan, prior
paid history local and Stripe, unknown) all yielding the identical
{"valid": false}; auth (401/403) on user and admin routes; admin CRUD + per
creator report + redemption list; friend code idempotent (incl. concurrent);
checkout applies the server-side coupon and 400 invalid_promo_code otherwise;
redemption logged only by checkout.session.completed (paid + discounted +
individual), idempotent on replay, never on validate/checkout creation/abandoned
sessions; self-referral and ineligible buyers not logged; webhook DB failure
-> 500; max_redemptions race-safe under real threads; replay race writes one
row; validate rate limit (429).

Run with: cd api && ../.venv/bin/python tests/test_promo_codes.py
"""
import _pathfix  # noqa: F401

import dataclasses
import os
import threading
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")
# Boot config the lifespan validates; the flag itself is toggled per test below.
os.environ["TRIAL_MONTHS"] = "0"
os.environ["PROMO_CODES_ENABLED"] = "false"
os.environ["PROMO_DISCOUNT_PERCENT"] = "50"
os.environ["PROMO_VALIDATE_RATE_LIMIT"] = "100/minute"

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.subscription import promo, stripe_service  # noqa: E402
from backend.subscription.promo import PromoConfigError, PromoManager  # noqa: E402

PASSED, FAILED = [], []
USERS, CREATORS = [], []
NOT_VALID = {"valid": False}


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def ck(tok):
    return {"cookie": f"session={tok}"} if tok else {}


def ip_hdr(tok=None):
    h = {"cf-connecting-ip": f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"}
    h.update(ck(tok))
    return h


def q(sql, params=()):
    db = DBManager()
    try:
        db.cur.execute(sql, params)
        try:
            rows = db.cur.fetchall()
        except Exception:
            rows = None
        db.conn.commit()
        return rows
    finally:
        db.close()


def signup(client, admin=False):
    name = f"pc_{uuid.uuid4().hex[:10]}"
    r = client.post("/signup", json={
        "username": name, "email": f"{name}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True}, headers=ip_hdr())
    assert r.status_code == 201, f"signup failed {r.status_code} {r.text}"
    uid = r.json()["user_id"]
    USERS.append(uid)
    if admin:
        q("UPDATE users SET is_admin = TRUE, mfa_enabled = TRUE WHERE _id = %s", (uid,))
    return uid, r.cookies.get("session")


def set_flag(enabled, rate="100/minute"):
    promo._config = promo.PromoConfig(enabled, 50, rate)


def validate(client, uid, tok, code, member_count=1):
    return client.post(f"/promo/{uid}/validate", json={"code": code, "member_count": member_count},
                       headers=ip_hdr(tok))


def mk_creator(client, admin_tok, name="Creator"):
    r = client.post("/admin/promo/creators", json={"name": name, "notes": "n"}, headers=ck(admin_tok))
    assert r.status_code == 201, r.text
    CREATORS.append(r.json()["id"])
    return r.json()["id"]


def mk_code(client, admin_tok, creator_id, **kw):
    code = f"T{uuid.uuid4().hex[:8]}".upper()
    r = client.post("/admin/promo/codes", json={"code": code, "creator_id": creator_id, **kw},
                    headers=ck(admin_tok))
    assert r.status_code == 201, r.text
    return code, r.json()


def webhook_event(uid, code_id, session_id, *, paid="paid", discount=1349, member_count=1, with_promo=True):
    md = {"user_id": uid, "member_count": str(member_count)}
    if with_promo:
        md["promo_code_id"] = code_id
    return {"type": "checkout.session.completed", "data": {"object": {
        "id": session_id, "client_reference_id": uid, "customer": "cus_x",
        "subscription": f"sub_{uuid.uuid4().hex[:12]}", "invoice": f"in_{uuid.uuid4().hex[:8]}",
        "payment_status": paid, "total_details": {"amount_discount": discount},
        "metadata": md}}}


class Stubs:
    """Patch every Stripe touchpoint; restore on exit."""
    def __init__(self):
        self.event = None
        self.created = []
        self.stripe_history = False

    def __enter__(self):
        self.o = (stripe_service.is_configured, stripe_service.customer_has_subscription_history,
                  stripe_service.ensure_promo_coupon, stripe_service.stripe.checkout.Session.create,
                  stripe_service.construct_event, stripe_service.retrieve_subscription)
        stripe_service.is_configured = lambda: True
        stripe_service.customer_has_subscription_history = lambda email: self.stripe_history
        stripe_service.ensure_promo_coupon = lambda pct: f"promo_{pct}"

        class _S:
            url = "https://stripe.test/s"

        def create(**kw):
            self.created.append(kw)
            return _S()
        stripe_service.stripe.checkout.Session.create = create
        stripe_service.construct_event = lambda payload, sig: self.event
        stripe_service.retrieve_subscription = lambda sid: {
            "status": "active", "trial_end": None, "current_period_end": 1999999999}
        return self

    def __exit__(self, *a):
        (stripe_service.is_configured, stripe_service.customer_has_subscription_history,
         stripe_service.ensure_promo_coupon, stripe_service.stripe.checkout.Session.create,
         stripe_service.construct_event, stripe_service.retrieve_subscription) = self.o

    def post_webhook(self, client, event):
        self.event = event
        return client.post("/subscriptions/stripe/webhook", content=b"{}",
                           headers={"stripe-signature": "x"})


def redemptions_for(code_id):
    return q("SELECT idempotency_key, over_cap, platform, plan, store_transaction_id FROM promo_redemptions "
             "WHERE code_id = %s", (code_id,))


def count_of(code_id):
    return q("SELECT redemption_count FROM promo_codes WHERE _id = %s", (code_id,))[0][0]


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_config_validation():
    print("\n== Eager config validation ==")
    keys = ("PROMO_CODES_ENABLED", "PROMO_DISCOUNT_PERCENT", "PROMO_VALIDATE_RATE_LIMIT")
    saved = {k: os.environ.get(k) for k in keys}
    saved_cfg = promo._config
    good = {"PROMO_CODES_ENABLED": "false", "PROMO_DISCOUNT_PERCENT": "50",
            "PROMO_VALIDATE_RATE_LIMIT": "10/minute"}

    def attempt(**over):
        env = {**good, **over}
        for k in keys:
            if env[k] is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = env[k]
        try:
            promo.validate_promo_config()
            return None
        except PromoConfigError as e:
            return str(e)

    try:
        check("flag unset -> error naming it (no implicit default)",
              "PROMO_CODES_ENABLED" in (attempt(PROMO_CODES_ENABLED=None) or ""))
        check("flag 'yes' -> error", attempt(PROMO_CODES_ENABLED="yes") is not None)
        check("percent unset -> error", "PROMO_DISCOUNT_PERCENT" in (attempt(PROMO_DISCOUNT_PERCENT=None) or ""))
        check("percent non-int -> error", attempt(PROMO_DISCOUNT_PERCENT="abc") is not None)
        check("percent 0 -> error", attempt(PROMO_DISCOUNT_PERCENT="0") is not None)
        check("percent 101 -> error", attempt(PROMO_DISCOUNT_PERCENT="101") is not None)
        check("rate unset -> error", "PROMO_VALIDATE_RATE_LIMIT" in (attempt(PROMO_VALIDATE_RATE_LIMIT=None) or ""))
        check("rate garbage -> error", attempt(PROMO_VALIDATE_RATE_LIMIT="lots") is not None)
        check("good config accepted, flag off", attempt() is None and promo.promo_enabled() is False)
        check("'TRUE' accepted -> enabled", attempt(PROMO_CODES_ENABLED="TRUE") is None and promo.promo_enabled())
        promo._config = None
        check("unvalidated config fails closed (flag off)", promo.promo_enabled() is False)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        promo._config = saved_cfg
    src = open(os.path.join(os.path.dirname(__file__), "..", "main.py")).read()
    check("main.py lifespan calls validate_promo_config()", "validate_promo_config()" in src)
    wf = open(os.path.join(os.path.dirname(__file__), "..", "..", ".github", "workflows", "build-push.yml")).read()
    check("CI env block carries all three PROMO_* vars and TRIAL_MONTHS",
          all(k in wf for k in ("PROMO_CODES_ENABLED", "PROMO_DISCOUNT_PERCENT",
                                "PROMO_VALIDATE_RATE_LIMIT", "TRIAL_MONTHS")))
    check("CI default flag is off", 'PROMO_CODES_ENABLED: "false"' in wf)


def test_flag_off(client, admin, user, stubs):
    print("\n== Flag off: surface absent, checkout unchanged ==")
    set_flag(False)
    aid, atok = admin
    uid, utok = user
    paths = [("post", f"/promo/{uid}/validate", {"code": "X"}), ("post", f"/promo/{uid}/friend-code", None),
             ("post", "/admin/promo/creators", {"name": "x"}), ("get", "/admin/promo/creators", None),
             ("get", "/admin/promo/report", None), ("get", "/admin/promo/redemptions", None),
             ("get", "/admin/promo/codes", None)]
    for method, path, body in paths:
        for label, tok in (("anon", None), ("user", utok), ("admin", atok)):
            kw = {"json": body} if body is not None else {}
            r = getattr(client, method)(path, headers=ip_hdr(tok), **kw)
            check(f"off: {method.upper()} {path.split('/')[1]}/{path.split('/')[-1][:8]} {label} -> 404",
                  r.status_code == 404, f"{r.status_code} {r.text[:80]}")
    # checkout: promo_code ignored, no coupon, no error
    stubs.created.clear()
    r = client.post("/subscriptions/checkout", json={"user_id": uid, "member_count": 1, "promo_code": "ANYTHING"},
                    headers=ip_hdr(utok))
    check("off: checkout with promo_code still 200", r.status_code == 200, f"{r.status_code} {r.text}")
    kw = stubs.created[-1] if stubs.created else {}
    check("off: no discounts and no promo metadata passed to Stripe",
          "discounts" not in kw and "promo_code_id" not in kw.get("metadata", {}), str(kw))
    check("off: no trial_period_days either", "trial_period_days" not in kw.get("subscription_data", {}))


def test_auth(client, admin, user, other):
    print("\n== Auth: 401 / 403 ==")
    set_flag(True)
    aid, atok = admin
    uid, utok = user
    oid, otok = other
    check("validate anon -> 401", client.post(f"/promo/{uid}/validate", json={"code": "X"},
                                              headers=ip_hdr()).status_code == 401)
    check("validate as other user's id -> 403", client.post(f"/promo/{uid}/validate", json={"code": "X"},
                                                            headers=ip_hdr(otok)).status_code == 403)
    check("friend-code anon -> 401", client.post(f"/promo/{uid}/friend-code", headers=ip_hdr()).status_code == 401)
    check("friend-code for other id -> 403",
          client.post(f"/promo/{uid}/friend-code", headers=ip_hdr(otok)).status_code == 403)
    cid = mk_creator(client, atok, "AuthCreator")
    endpoints = [("post", "/admin/promo/creators", {"name": "x"}), ("get", "/admin/promo/creators", None),
                 ("patch", f"/admin/promo/creators/{cid}", {"active": False}),
                 ("post", "/admin/promo/codes", {"code": "ABCDE", "creator_id": cid}),
                 ("get", "/admin/promo/codes", None),
                 ("patch", f"/admin/promo/codes/{uuid.uuid4()}", {"active": False}),
                 ("get", "/admin/promo/report", None), ("get", "/admin/promo/redemptions", None)]
    for method, path, body in endpoints:
        kw = {"json": body} if body is not None else {}
        r_user = getattr(client, method)(path, headers=ck(utok), **kw)
        r_anon = getattr(client, method)(path, **kw)
        check(f"non-admin 403: {method.upper()} {path.replace(cid, '{id}')[:40]}", r_user.status_code == 403,
              str(r_user.status_code))
        check(f"anon 401: {method.upper()} {path.replace(cid, '{id}')[:40]}", r_anon.status_code == 401,
              str(r_anon.status_code))
    check("admin passes authz", client.get("/admin/promo/report", headers=ck(atok)).status_code == 200)


def test_eligibility(client, admin, stubs):
    print("\n== Eligibility: uniform {valid:false}, case-insensitive ==")
    set_flag(True)
    aid, atok = admin
    buyer, btok = signup(client)
    cid = mk_creator(client, atok, "Elig")
    code, row = mk_code(client, atok, cid)

    r = validate(client, buyer, btok, code)
    check("valid creator code -> valid true, percent 50",
          r.status_code == 200 and r.json() == {"valid": True, "percent_off": 50}, r.text)
    check("validate response is no-store", r.headers.get("cache-control") == "no-store")
    r = validate(client, buyer, btok, f"  {code.lower()} ")
    check("case-insensitive + trimmed", r.json().get("valid") is True, r.text)

    unknown = validate(client, buyer, btok, "NOSUCHCODE1").json()
    bad_shape = validate(client, buyer, btok, "!!").json()
    check("unknown code -> exactly {valid:false}", unknown == NOT_VALID, str(unknown))
    check("malformed code -> same body", bad_shape == NOT_VALID, str(bad_shape))
    check("non-string-ish/empty code -> same body", validate(client, buyer, btok, "").json() == NOT_VALID)

    # group plan
    check("group plan (member_count 3) -> not valid", validate(client, buyer, btok, code, 3).json() == NOT_VALID)

    # inactive code
    c2, r2 = mk_code(client, atok, cid)
    client.patch(f"/admin/promo/codes/{r2['id']}", json={"active": False}, headers=ck(atok))
    check("inactive code -> not valid", validate(client, buyer, btok, c2).json() == NOT_VALID)
    # expired
    c3, _ = mk_code(client, atok, cid, expires_at="2020-01-01T00:00:00Z")
    check("expired code -> not valid", validate(client, buyer, btok, c3).json() == NOT_VALID)
    c3b, _ = mk_code(client, atok, cid, expires_at="2099-01-01T00:00:00Z")
    check("future expiry -> valid", validate(client, buyer, btok, c3b).json().get("valid") is True)
    # exhausted
    c4, r4 = mk_code(client, atok, cid, max_redemptions=1)
    q("UPDATE promo_codes SET redemption_count = 1 WHERE _id = %s", (r4["id"],))
    check("exhausted code -> not valid", validate(client, buyer, btok, c4).json() == NOT_VALID)
    # inactive creator
    cid2 = mk_creator(client, atok, "Dormant")
    c5, _ = mk_code(client, atok, cid2)
    client.patch(f"/admin/promo/creators/{cid2}", json={"active": False}, headers=ck(atok))
    check("inactive creator -> not valid", validate(client, buyer, btok, c5).json() == NOT_VALID)

    # friend codes: own code not valid, someone else's valid
    fr, ftok = signup(client)
    own = client.post(f"/promo/{fr}/friend-code", headers=ip_hdr(ftok)).json()["code"]
    check("own friend code -> not valid", validate(client, fr, ftok, own).json() == NOT_VALID)
    check("someone else's friend code -> valid", validate(client, buyer, btok, own).json().get("valid") is True)

    # prior paid history: local subscriber_history
    old, otok = signup(client)
    q("INSERT INTO subscriber_history (user_id, provider) VALUES (%s, 'stripe')", (old,))
    check("prior paid (subscriber_history) -> not valid", validate(client, old, otok, code).json() == NOT_VALID)
    # prior paid history: stripe lookup
    st, sttok = signup(client)
    stubs.stripe_history = True
    check("prior Stripe subscription history -> not valid", validate(client, st, sttok, code).json() == NOT_VALID)
    stubs.stripe_history = False
    # prior redemption
    rd, rdtok = signup(client)
    q("INSERT INTO promo_redemptions (user_id, code_id, code, kind, plan, platform, store_transaction_id, "
      "idempotency_key) VALUES (%s,%s,%s,'creator','individual','web','x',%s)",
      (rd, row["id"], code, f"seed_{uuid.uuid4().hex}"))
    check("prior redemption -> not valid", validate(client, rd, rdtok, code).json() == NOT_VALID)
    # admin_comp grant does not count as paid
    comp, comptok = signup(client)
    sid = str(uuid.uuid4())
    q("INSERT INTO subscriptions (_id, user_id, plan_type, provider, status, max_members) "
      "VALUES (%s,%s,'individual','admin_comp','active',1)", (sid, comp))
    q("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, comp))
    check("admin_comp grant does not block eligibility",
          validate(client, comp, comptok, code).json().get("valid") is True)
    # Stripe error -> fail closed
    er, ertok = signup(client)

    def boom(email):
        raise RuntimeError("stripe down")
    saved = stripe_service.customer_has_subscription_history
    stripe_service.customer_has_subscription_history = boom
    try:
        check("Stripe lookup error -> fail closed (not valid)",
              validate(client, er, ertok, code).json() == NOT_VALID)
    finally:
        stripe_service.customer_has_subscription_history = saved

    check("validate logged no redemption", q("SELECT COUNT(*) FROM promo_redemptions WHERE code_id = %s",
                                             (row["id"],))[0][0] == 1)  # only the seeded row above
    check("validate did not bump redemption_count", count_of(row["id"]) == 0)


def test_friend_code(client):
    print("\n== Friend invite code ==")
    set_flag(True)
    uid, tok = signup(client)
    r1 = client.post(f"/promo/{uid}/friend-code", headers=ip_hdr(tok))
    r2 = client.post(f"/promo/{uid}/friend-code", headers=ip_hdr(tok))
    j1, j2 = r1.json(), r2.json()
    check("friend-code 200 with code/link/percent", r1.status_code == 200 and {"code", "link", "percent_off"} <= set(j1))
    check("idempotent: same code on second call", j1["code"] == j2["code"])
    check("link carries ?code=", j1["link"].endswith(f"/?code={j1['code']}"), j1["link"])
    check("code is 10 chars, unambiguous alphabet",
          len(j1["code"]) == 10 and set(j1["code"]) <= set(promo._FRIEND_ALPHABET))
    check("one friend row stored", q("SELECT COUNT(*) FROM promo_codes WHERE kind='friend' AND referrer_user_id=%s",
                                     (uid,))[0][0] == 1)
    uid2, tok2 = signup(client)
    results = []

    def go():
        pm = PromoManager()
        try:
            results.append(pm.get_or_create_friend_code(uid2))
        finally:
            pm.close()
    ts = [threading.Thread(target=go) for _ in range(8)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("concurrent generate -> one code for all callers", len(results) == 8 and len(set(results)) == 1, str(results))
    check("concurrent generate -> one row",
          q("SELECT COUNT(*) FROM promo_codes WHERE kind='friend' AND referrer_user_id=%s", (uid2,))[0][0] == 1)


def test_admin_crud_and_report(client, admin, stubs):
    print("\n== Admin CRUD + report ==")
    set_flag(True)
    aid, atok = admin
    cid = mk_creator(client, atok, "ReportMe")
    code, row = mk_code(client, atok, cid, max_redemptions=5)
    check("creator code stored uppercase", row["code"] == code and row["kind"] == "creator" and row["creator_id"] == cid)
    r = client.post("/admin/promo/codes", json={"code": code.lower(), "creator_id": cid}, headers=ck(atok))
    check("duplicate code (any case) -> 409", r.status_code == 409, r.text)
    r = client.post("/admin/promo/codes", json={"code": "!!", "creator_id": cid}, headers=ck(atok))
    check("malformed code -> 422", r.status_code == 422, r.text)
    r = client.post("/admin/promo/codes", json={"code": "OKCODE9", "creator_id": str(uuid.uuid4())},
                    headers=ck(atok))
    check("unknown creator -> 404", r.status_code == 404, r.text)
    r = client.post("/admin/promo/codes", json={"code": "OKCODE9", "creator_id": "nope"}, headers=ck(atok))
    check("non-uuid creator id -> 404 (no 500)", r.status_code == 404, r.text)
    r = client.patch(f"/admin/promo/creators/{cid}", json={}, headers=ck(atok))
    check("empty patch -> 422", r.status_code == 422, r.text)
    r = client.post("/admin/promo/codes", json={"code": "OKCODE9", "creator_id": cid, "max_redemptions": 0},
                    headers=ck(atok))
    check("max_redemptions 0 rejected -> 422", r.status_code == 422, r.text)
    r = client.get("/admin/promo/redemptions?kind=bogus", headers=ck(atok))
    check("bad kind filter -> 422", r.status_code == 422)

    # two completed redemptions via webhook by two buyers
    with_codes = []
    for _ in range(2):
        b, btok = signup(client)
        sess = f"cs_{uuid.uuid4().hex}"
        res = stubs.post_webhook(client, webhook_event(b, row["id"], sess))
        with_codes.append((b, sess, res.status_code))
    check("both webhooks 200", all(s == 200 for *_, s in with_codes), str(with_codes))
    rep = client.get("/admin/promo/report", headers=ck(atok)).json()
    mine = [x for x in rep if x["creator_id"] == cid]
    check("report: this creator has 2 redemptions", mine and mine[0]["redemptions"] == 2
          and mine[0]["over_cap_redemptions"] == 0, str(mine))
    lst = client.get(f"/admin/promo/redemptions?creator_id={cid}", headers=ck(atok)).json()
    check("redemption list returns 2 rows w/ required fields",
          len(lst) == 2 and all(x["platform"] == "web" and x["plan"] == "individual" and x["creator_id"] == cid
                                and x["code"] == code and x["store_transaction_id"] and x["user_id"] and x["created_at"]
                                for x in lst), str(lst)[:300])
    check("list limit capped / honored",
          len(client.get(f"/admin/promo/redemptions?creator_id={cid}&limit=1", headers=ck(atok)).json()) == 1)
    r = client.patch(f"/admin/promo/codes/{row['id']}", json={"active": False}, headers=ck(atok))
    check("deactivate code", r.status_code == 200 and r.json()["active"] is False)
    test_creator_edit(client, atok, cid, row)


def test_creator_edit(client, atok, cid, row):
    print("\n== Creator metadata edit ==")
    before = q("SELECT code, kind, redemption_count, max_redemptions, expires_at, active FROM promo_codes WHERE _id=%s", (row['id'],))
    r = client.patch(f"/admin/promo/creators/{cid}", json={"name": "  Renamed  ", "notes": "new notes"},
                     headers=ck(atok))
    check("edit name/notes -> 200, name trimmed", r.status_code == 200 and r.json()["name"] == "Renamed"
          and r.json()["notes"] == "new notes", r.text)
    for label, body in (("whitespace-only name", {"name": "   "}), ("empty name", {"name": ""}),
                        ("name > 120", {"name": "x" * 121}), ("notes > 2000", {"notes": "x" * 2001})):
        check(f"{label} -> 422", client.patch(f"/admin/promo/creators/{cid}", json=body,
                                               headers=ck(atok)).status_code == 422)
    after = q("SELECT code, kind, redemption_count, max_redemptions, expires_at, active FROM promo_codes WHERE _id=%s", (row['id'],))
    check("edit leaves code/redemptions/caps/expiry/active unchanged", before == after, f"{before} vs {after}")
    check("DB: creator name/notes updated", q("SELECT name, notes FROM creators WHERE _id=%s", (cid,))[0] == ("Renamed", "new notes"))


def test_checkout(client, admin, stubs):
    print("\n== Checkout applies coupon server-side ==")
    set_flag(True)
    aid, atok = admin
    buyer, btok = signup(client)
    cid = mk_creator(client, atok, "Checkout")
    code, row = mk_code(client, atok, cid)

    def checkout(uid, tok, **body):
        stubs.created.clear()
        r = client.post("/subscriptions/checkout", json={"user_id": uid, **body}, headers=ip_hdr(tok))
        return r, (stubs.created[-1] if stubs.created else None)

    r, kw = checkout(buyer, btok, member_count=1, promo_code=code.lower())
    check("valid code -> 200", r.status_code == 200, r.text)
    check("coupon passed via discounts (50%, once coupon id)", kw and kw.get("discounts") == [{"coupon": "promo_50"}], str(kw))
    check("promo_code_id stamped in session + subscription metadata",
          kw["metadata"].get("promo_code_id") == row["id"]
          and kw["subscription_data"]["metadata"].get("promo_code_id") == row["id"])
    check("no trial alongside promo", "trial_period_days" not in kw["subscription_data"])
    check("price remains server-authoritative (unit_amount unchanged)",
          kw["line_items"][0]["price_data"]["unit_amount"] == stripe_service.price_for(1)
          == 499)

    r, kw = checkout(buyer, btok, member_count=1)
    check("no code -> 200, no discounts", r.status_code == 200 and "discounts" not in kw, str(kw))
    r, kw = checkout(buyer, btok, member_count=1, promo_code="   ")
    check("blank code treated as none", r.status_code == 200 and "discounts" not in kw)

    for label, kwargs in (("unknown", {"promo_code": "NOPE1234"}), ("group plan", {"promo_code": code, "member_count": 3})):
        kwargs.setdefault("member_count", 1)
        r, kw = checkout(buyer, btok, **kwargs)
        check(f"{label} -> 400 invalid_promo_code, no session created",
              r.status_code == 400 and r.json()["detail"]["code"] == "invalid_promo_code" and kw is None,
              f"{r.status_code} {r.text}")
    own_code = client.post(f"/promo/{buyer}/friend-code", headers=ip_hdr(btok)).json()["code"]
    r, kw = checkout(buyer, btok, member_count=1, promo_code=own_code)
    check("own friend code at checkout -> 400 uniform", r.status_code == 400
          and r.json()["detail"]["code"] == "invalid_promo_code" and kw is None)
    old, otok = signup(client)
    q("INSERT INTO subscriber_history (user_id, provider) VALUES (%s, 'apple')", (old,))
    r, kw = checkout(old, otok, member_count=1, promo_code=code)
    check("existing subscriber at checkout -> 400, no session", r.status_code == 400 and kw is None)
    r, kw = checkout(buyer, btok, member_count=1, promo_code=code) if False else (None, None)

    check("checkout/validate created no redemption rows and no count",
          redemptions_for(row["id"]) == [] and count_of(row["id"]) == 0)
    other, _ = signup(client)
    r = client.post("/subscriptions/checkout", json={"user_id": other, "member_count": 1, "promo_code": code},
                    headers=ip_hdr(btok))
    check("checkout for another user's id -> 403", r.status_code == 403)


def test_webhook_redemption(client, admin, stubs):
    print("\n== Webhook redemption logging ==")
    set_flag(True)
    aid, atok = admin
    cid = mk_creator(client, atok, "Webhook")
    code, row = mk_code(client, atok, cid)
    cid_id = row["id"]

    b, _ = signup(client)
    sess = f"cs_{uuid.uuid4().hex}"
    r = stubs.post_webhook(client, webhook_event(b, cid_id, sess))
    rows = redemptions_for(cid_id)
    check("completed paid discounted checkout -> 200 + exactly one row", r.status_code == 200 and len(rows) == 1, str(rows))
    check("row: platform web, plan individual, key = session id, over_cap false",
          rows and rows[0][0] == sess and rows[0][1] is False and rows[0][2] == "web" and rows[0][3] == "individual")
    check("count incremented to 1", count_of(cid_id) == 1)
    check("subscription still created by same webhook",
          q("SELECT COUNT(*) FROM subscriptions WHERE user_id = %s AND provider = 'stripe'", (b,))[0][0] == 1)

    # replay (identical), and a replay after the plan upsert made buyer "ineligible"
    r1 = stubs.post_webhook(client, webhook_event(b, cid_id, sess))
    r2 = stubs.post_webhook(client, webhook_event(b, cid_id, sess))
    check("replayed webhook -> 200", r1.status_code == 200 and r2.status_code == 200)
    check("replay: still one row, count still 1", len(redemptions_for(cid_id)) == 1 and count_of(cid_id) == 1)

    n_before = len(redemptions_for(cid_id))
    for label, ev in (
        ("unpaid session", lambda u: webhook_event(u, cid_id, f"cs_{uuid.uuid4().hex}", paid="unpaid")),
        ("zero discount", lambda u: webhook_event(u, cid_id, f"cs_{uuid.uuid4().hex}", discount=0)),
        ("group plan session", lambda u: webhook_event(u, cid_id, f"cs_{uuid.uuid4().hex}", member_count=3)),
        ("no promo metadata", lambda u: webhook_event(u, cid_id, f"cs_{uuid.uuid4().hex}", with_promo=False)),
        ("unknown promo code id", lambda u: webhook_event(u, str(uuid.uuid4()), f"cs_{uuid.uuid4().hex}")),
    ):
        u, _ = signup(client)
        r = stubs.post_webhook(client, ev(u))
        check(f"{label} -> 200, nothing logged", r.status_code == 200 and len(redemptions_for(cid_id)) == n_before,
              f"{r.status_code}")
    check("count unchanged by non-redeeming sessions", count_of(cid_id) == 1)

    # ineligible buyer (history) not logged
    old, _ = signup(client)
    q("INSERT INTO subscriber_history (user_id, provider) VALUES (%s, 'stripe')", (old,))
    r = stubs.post_webhook(client, webhook_event(old, cid_id, f"cs_{uuid.uuid4().hex}"))
    check("buyer with paid history -> not logged", r.status_code == 200 and len(redemptions_for(cid_id)) == n_before)

    # self-referral via friend code not logged
    fr, ftok = signup(client)
    fcode = client.post(f"/promo/{fr}/friend-code", headers=ip_hdr(ftok)).json()["code"]
    fid = PromoManager().find_code(fcode)["id"]
    r = stubs.post_webhook(client, webhook_event(fr, fid, f"cs_{uuid.uuid4().hex}"))
    check("self-referral at webhook -> not logged", r.status_code == 200 and redemptions_for(fid) == [])
    # legit friend redemption logs referrer
    buyer2, _ = signup(client)
    r = stubs.post_webhook(client, webhook_event(buyer2, fid, f"cs_{uuid.uuid4().hex}"))
    rr = q("SELECT kind, referrer_user_id, creator_id FROM promo_redemptions WHERE code_id = %s", (fid,))
    check("friend redemption logs kind=friend + referrer id, no creator",
          r.status_code == 200 and len(rr) == 1 and rr[0][0] == "friend" and str(rr[0][1]) == fr and rr[0][2] is None,
          str(rr))

    # failure -> 500 so Stripe retries; then retry succeeds with exactly one row
    b3, _ = signup(client)
    sess3 = f"cs_{uuid.uuid4().hex}"
    orig = PromoManager.log_redemption

    def fail(self, **kw):
        raise RuntimeError("db down")
    PromoManager.log_redemption = fail
    try:
        r = stubs.post_webhook(client, webhook_event(b3, cid_id, sess3))
    finally:
        PromoManager.log_redemption = orig
    check("log failure -> webhook 500 (surfaces for retry)", r.status_code == 500, str(r.status_code))
    check("failed attempt wrote nothing and did not grant plan",
          redemptions_for(cid_id) and all(x[0] != sess3 for x in redemptions_for(cid_id))
          and q("SELECT COUNT(*) FROM subscriptions WHERE user_id = %s AND provider = 'stripe'", (b3,))[0][0] == 0)
    r = stubs.post_webhook(client, webhook_event(b3, cid_id, sess3))
    check("retry after failure -> 200, buyer logged once even though code logic ran before upsert",
          r.status_code == 200 and sum(1 for x in redemptions_for(cid_id) if x[0] == sess3) == 1)


def test_max_redemptions_race(client, admin):
    print("\n== max_redemptions race-safety ==")
    set_flag(True)
    aid, atok = admin
    cid = mk_creator(client, atok, "Race")
    code, row = mk_code(client, atok, cid, max_redemptions=3)
    n = 12
    buyers = [signup(client)[0] for _ in range(n)]
    outcomes = []
    barrier = threading.Barrier(n)

    def go(uid):
        pm = PromoManager()
        try:
            barrier.wait()
            outcomes.append(pm.log_redemption(code_id=row["id"], user_id=uid, plan="individual", platform="web",
                                              store_transaction_id=f"in_{uid[:8]}", idempotency_key=f"cs_{uid}",
                                              amount_discount_cents=100))
        except Exception as e:
            outcomes.append(f"err:{e}")
        finally:
            pm.close()
    ts = [threading.Thread(target=go, args=(u,)) for u in buyers]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("exactly max_redemptions (3) counted 'logged'", outcomes.count("logged") == 3, str(outcomes))
    check("remainder flagged over_cap, none errored", outcomes.count("over_cap") == n - 3, str(outcomes))
    check("redemption_count never exceeds max (== 3)", count_of(row["id"]) == 3)
    rows = redemptions_for(row["id"])
    check("every purchase logged once (12 rows, 9 over_cap)", len(rows) == n and sum(1 for x in rows if x[1]) == n - 3)
    rep = [x for x in client.get("/admin/promo/report", headers=ck(atok)).json() if x["creator_id"] == cid][0]
    check("report separates counted vs over_cap", rep["redemptions"] == 3 and rep["over_cap_redemptions"] == n - 3, str(rep))
    # once exhausted the code stops validating
    nb, nbtok = signup(client)
    check("exhausted code stops validating", validate(client, nb, nbtok, code).json() == NOT_VALID)

    # same-key replay race: one row, one count
    code2, row2 = mk_code(client, atok, cid, max_redemptions=50)
    uid = signup(client)[0]
    outcomes.clear()
    barrier2 = threading.Barrier(8)

    def replay():
        pm = PromoManager()
        try:
            barrier2.wait()
            outcomes.append(pm.log_redemption(code_id=row2["id"], user_id=uid, plan="individual", platform="web",
                                              store_transaction_id="in_same", idempotency_key="cs_same_" + row2["id"],
                                              amount_discount_cents=100))
        except Exception as e:
            outcomes.append(f"err:{e}")
        finally:
            pm.close()
    ts = [threading.Thread(target=replay) for _ in range(8)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("concurrent identical replays: one 'logged', rest 'duplicate'",
          outcomes.count("logged") == 1 and outcomes.count("duplicate") == 7, str(outcomes))
    check("concurrent replays: one row, count == 1",
          len(redemptions_for(row2["id"])) == 1 and count_of(row2["id"]) == 1)


def test_rate_limit(client, admin):
    print("\n== Validate rate limit ==")
    aid, atok = admin
    set_flag(True, rate="3/minute")
    uid, tok = signup(client)
    ip = {"cf-connecting-ip": "203.0.113.77", **ck(tok)}
    codes = [client.post(f"/promo/{uid}/validate", json={"code": f"GUESS{i}"}, headers=ip).status_code
             for i in range(6)]
    check("per-IP: first 3 allowed, then 429", codes[:3] == [200, 200, 200] and 429 in codes[3:], str(codes))
    # a fresh IP, same user -> per-user limiter still trips
    uid2, tok2 = signup(client)
    codes2 = [client.post(f"/promo/{uid2}/validate", json={"code": f"GUESS{i}"}, headers=ip_hdr(tok2)).status_code
              for i in range(6)]
    check("per-user: rotating IPs still gets 429", 429 in codes2, str(codes2))
    set_flag(True)


def cleanup():
    for cid in CREATORS:
        q("DELETE FROM promo_redemptions WHERE creator_id = %s", (cid,))
        q("DELETE FROM promo_codes WHERE creator_id = %s", (cid,))
        q("DELETE FROM creators WHERE _id = %s", (cid,))
    for uid in USERS:
        q("DELETE FROM promo_redemptions WHERE user_id = %s OR referrer_user_id = %s", (uid, uid))
        q("DELETE FROM promo_codes WHERE referrer_user_id = %s", (uid,))
        q("UPDATE users SET subscription_id = NULL WHERE _id = %s", (uid,))
        q("DELETE FROM subscriber_history WHERE user_id = %s", (uid,))
        q("DELETE FROM subscriptions WHERE user_id = %s", (uid,))
        q("DELETE FROM users WHERE _id = %s", (uid,))


def main():
    test_config_validation()
    try:
        with TestClient(main_module.app) as client:
            with Stubs() as stubs:
                admin = signup(client, admin=True)
                user = signup(client)
                other = signup(client)
                test_flag_off(client, admin, user, stubs)
                test_auth(client, admin, user, other)
                test_eligibility(client, admin, stubs)
                test_friend_code(client)
                test_checkout(client, admin, stubs)
                test_webhook_redemption(client, admin, stubs)
                test_admin_crud_and_report(client, admin, stubs)
                test_max_redemptions_race(client, admin)
                test_rate_limit(client, admin)
            # restore the boot config's flag-off state
            set_flag(False)
    finally:
        try:
            cleanup()
        except Exception as e:
            print(f"cleanup warning: {e}")

    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
