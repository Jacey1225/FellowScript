"""Backend coverage for task 20261001-promo-owner-rewards.

Proves: eager config validation (every var, bad offer map, key only loaded when
enabled, no key bytes in errors); flag-off uniform 404 on every new route before
auth and no reward accrual; signup friend-code earn (one per invitee, replay,
self-referral, email-normalization dedupe, per-owner cap, max outstanding, per-IP
cap, owner without subscription dropped, group/free/admin_comp owners dropped,
unknown/inactive code ignored, concurrent earns never exceed the cap); creator
code purchase earn (idempotent, subscribed owner only, buyer==owner denied);
Stripe apply (claimed atomically, deferred when Stripe says no, no double apply,
FIFO one-at-a-time, expiry); Apple claim (valid ES256 signature verified with the
public key, 404 for non-apple/no reward/unmapped, 409 while reserved, per-user
authz, race-safe) and reconciliation (offerType 2 finalizes, idempotent on the
transaction id, wrong offer ignored); admin authz (401/403) and create/list/
deactivate; audit log rows.

Run with: cd api && ../.venv/bin/python tests/test_owner_rewards.py
"""
import _pathfix  # noqa: F401

import base64
import json
import os
import tempfile
import threading
import uuid
from datetime import timedelta

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")
os.environ["TRIAL_MONTHS"] = "0"
os.environ["PROMO_CODES_ENABLED"] = "false"
os.environ["PROMO_DISCOUNT_PERCENT"] = "50"
os.environ["PROMO_VALIDATE_RATE_LIMIT"] = "100/minute"

from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

# Throwaway test key (generated here; never the real subscription key).
_KEY = ec.generate_private_key(ec.SECP256R1())
_KEY_FILE = tempfile.NamedTemporaryFile(prefix="test-promo-key-", suffix=".p8", delete=False)
_KEY_FILE.write(_KEY.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                   serialization.NoEncryption()))
_KEY_FILE.close()

_PRODUCTS = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
OFFERS = {f"com.fellowscript.access.{n}": ("invite_reward_50" if i == 0 else f"invite_reward_50_{i + 1}")
          for i, n in enumerate(_PRODUCTS)}
GOOD_ENV = {
    "OWNER_REWARDS_ENABLED": "false",
    "OWNER_REWARD_PERCENT": "50",
    "OWNER_REWARD_EXPIRY_DAYS": "90",
    "OWNER_REWARD_CAP_COUNT": "3",
    "OWNER_REWARD_CAP_WINDOW_DAYS": "30",
    "OWNER_REWARD_MAX_OUTSTANDING": "3",
    "OWNER_REWARD_IP_CAP_COUNT": "2",
    "OWNER_REWARD_CLAIM_RATE_LIMIT": "100/minute",
    "OWNER_REWARD_APPLE_RESERVATION_MINUTES": "15",
    "OWNER_REWARD_HASH_SALT": "test-salt-0123456789abcdef",
    "APPLE_PROMO_KEY_ID": "G6DRYNCNRS",
    "APPLE_PROMO_KEY_PATH": _KEY_FILE.name,
    "APPLE_PROMO_OFFERS": json.dumps(OFFERS),
    "APPLE_BUNDLE_ID": "com.fellowscript.app",
}
os.environ.update(GOOD_ENV)

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.subscription import promo, stripe_service, owner_rewards as ow  # noqa: E402
from backend.subscription.owner_rewards import (  # noqa: E402
    OwnerRewardsConfigError, RewardManager, normalize_email, validate_owner_rewards_config)

PASSED, FAILED = [], []
USERS, CREATORS = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def ck(tok):
    return {"cookie": f"session={tok}"} if tok else {}


def ip_hdr(tok=None, ip=None):
    h = {"cf-connecting-ip": ip or f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"}
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


def signup(client, admin=False, email=None, invite=None, ip=None):
    name = f"ow_{uuid.uuid4().hex[:10]}"
    body = {"username": name, "email": email or f"{name}@example.com", "plain_pass": "TestPass123!",
            "terms_accepted": True}
    if invite is not None:
        body["invite_code"] = invite
    r = client.post("/signup", json=body, headers=ip_hdr(ip=ip))
    assert r.status_code == 201, f"signup failed {r.status_code} {r.text}"
    uid = r.json()["user_id"]
    USERS.append(uid)
    if admin:
        q("UPDATE users SET is_admin = TRUE WHERE _id = %s", (uid,))
    return uid, r.cookies.get("session")


def give_sub(uid, provider="stripe", plan="group", status="active", max_members=1, stripe_sub=None,
             otxn=None):
    sid = str(uuid.uuid4())
    q("INSERT INTO subscriptions (_id, user_id, plan_type, provider, status, max_members, "
      "stripe_subscription_id, apple_original_transaction_id) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
      (sid, uid, plan, provider, status, max_members,
       stripe_sub or (f"sub_{uuid.uuid4().hex[:12]}" if provider == "stripe" else ""),
       otxn or (f"otx_{uuid.uuid4().hex[:12]}" if provider == "apple" else "")))
    q("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, uid))
    return sid


def friend_code(uid):
    db = RewardManager()
    try:
        return db.get_or_create_friend_code(uid)
    finally:
        db.close()


def set_flags(rewards=True, promo_on=True):
    os.environ["OWNER_REWARDS_ENABLED"] = "true" if rewards else "false"
    promo._config = promo.PromoConfig(promo_on, 50, "100/minute")
    validate_owner_rewards_config()


def rewards_of(owner):
    return q("SELECT status, source, claimed_via, claim_ref, idempotency_key FROM owner_rewards "
             "WHERE owner_user_id = %s ORDER BY earned_at", (owner,))


def audit_actions(owner):
    return [r[0] for r in q("SELECT action FROM promo_audit_log WHERE owner_user_id = %s", (owner,))]


def earn_signup(owner_code, invitee, email, ip=None):
    ip = ip or f"192.0.2.{uuid.uuid4().int % 250 + 1}.{uuid.uuid4().hex[:6]}"
    db = RewardManager()
    try:
        return db.earn_signup(invitee, email, owner_code, ip)
    finally:
        db.close()


def new_user_row(client):
    return signup(client)


class StripeStub:
    def __init__(self, ok=True, boom=False):
        self.ok, self.boom, self.calls = ok, boom, []

    def __enter__(self):
        self.o = (stripe_service.apply_owner_reward, stripe_service.is_configured)
        stripe_service.is_configured = lambda: True

        def fake(sub_id, pct, rid):
            self.calls.append((sub_id, pct, rid))
            if self.boom:
                raise RuntimeError("stripe down")
            return self.ok
        stripe_service.apply_owner_reward = fake
        return self

    def __exit__(self, *a):
        stripe_service.apply_owner_reward, stripe_service.is_configured = self.o


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_config():
    print("\n== Eager config validation ==")
    saved = dict(os.environ)
    try:
        def attempt(**over):
            env = {**GOOD_ENV, **over}
            for k in GOOD_ENV:
                if env[k] is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = env[k]
            try:
                validate_owner_rewards_config()
                return None
            except OwnerRewardsConfigError as e:
                return str(e)
        promo._config = promo.PromoConfig(True, 50, "100/minute")
        check("good config, flag off, validates", attempt() is None)
        check("flag off => rewards_enabled False", not ow.rewards_enabled())
        check("flag off does not load key (config.private_key None)", ow.rewards_config().private_key is None)
        for var in GOOD_ENV:
            msg = attempt(**{var: None})
            check(f"missing {var} refuses", msg is not None and var in msg, str(msg))
        check("blank flag refuses", attempt(OWNER_REWARDS_ENABLED="") is not None)
        check("flag 'yes' refuses", attempt(OWNER_REWARDS_ENABLED="yes") is not None)
        check("percent 0 refuses", attempt(OWNER_REWARD_PERCENT="0") is not None)
        check("percent 101 refuses", attempt(OWNER_REWARD_PERCENT="101") is not None)
        check("percent non-int refuses", attempt(OWNER_REWARD_PERCENT="fifty") is not None)
        check("expiry 0 refuses", attempt(OWNER_REWARD_EXPIRY_DAYS="0") is not None)
        check("cap 0 refuses", attempt(OWNER_REWARD_CAP_COUNT="0") is not None)
        check("bad rate limit refuses", attempt(OWNER_REWARD_CLAIM_RATE_LIMIT="lots") is not None)
        check("short salt refuses", attempt(OWNER_REWARD_HASH_SALT="short") is not None)
        check("bad key id refuses", attempt(APPLE_PROMO_KEY_ID="bad") is not None)
        check("reservation 0 refuses", attempt(OWNER_REWARD_APPLE_RESERVATION_MINUTES="0") is not None)
        check("offers not JSON refuses", attempt(APPLE_PROMO_OFFERS="{nope") is not None)
        partial = dict(OFFERS)
        partial.pop("com.fellowscript.access.eight")
        check("offers missing a product refuses", attempt(APPLE_PROMO_OFFERS=json.dumps(partial)) is not None)
        extra = {**OFFERS, "com.fellowscript.access.nine": "x"}
        check("offers with unknown product refuses", attempt(APPLE_PROMO_OFFERS=json.dumps(extra)) is not None)
        dup = {**OFFERS, "com.fellowscript.access.two": "invite_reward_50"}
        check("duplicate offer ids refuse", attempt(APPLE_PROMO_OFFERS=json.dumps(dup)) is not None)
        bad = {**OFFERS, "com.fellowscript.access.two": "bad id!"}
        check("invalid offer id refuses", attempt(APPLE_PROMO_OFFERS=json.dumps(bad)) is not None)
        # 2026-10-01 price cut: versioned (_vN) offer codes must validate.
        v2 = {f"com.fellowscript.access.{n}": ("invite_reward_50_v2" if i == 0 else f"invite_reward_50_v2_{i + 1}")
              for i, n in enumerate(_PRODUCTS)}
        check("versioned v2 offer codes validate", attempt(APPLE_PROMO_OFFERS=json.dumps(v2)) is None)
        check("price table is the post-cut table",
              [stripe_service.price_for(n) for n in range(1, 9)] == [499, 810, 1215, 1620, 2025, 2430, 2835, 3240])
        # enabled: key loaded
        check("enabled + valid key validates", attempt(OWNER_REWARDS_ENABLED="true") is None)
        check("enabled loads private key", ow.rewards_config().private_key is not None)
        check("enabled + promo off refuses",
              (lambda: (setattr(promo, "_config", promo.PromoConfig(False, 50, "1/minute")),
                        attempt(OWNER_REWARDS_ENABLED="true"))[1])() is not None)
        promo._config = promo.PromoConfig(True, 50, "100/minute")
        check("enabled + missing key file refuses",
              "could not be loaded" in (attempt(OWNER_REWARDS_ENABLED="true",
                                                APPLE_PROMO_KEY_PATH="/nonexistent/key.p8") or ""))
        rsa_like = tempfile.NamedTemporaryFile(suffix=".p8", delete=False)
        rsa_like.write(b"-----BEGIN PRIVATE KEY-----\nSECRETBYTES\n-----END PRIVATE KEY-----\n")
        rsa_like.close()
        msg = attempt(OWNER_REWARDS_ENABLED="true", APPLE_PROMO_KEY_PATH=rsa_like.name)
        check("garbage key refuses without echoing key bytes", msg is not None and "SECRETBYTES" not in msg, str(msg))
        os.unlink(rsa_like.name)
        other = ec.generate_private_key(ec.SECP384R1())
        f = tempfile.NamedTemporaryFile(suffix=".p8", delete=False)
        f.write(other.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                    serialization.NoEncryption()))
        f.close()
        check("non P-256 key refuses", attempt(OWNER_REWARDS_ENABLED="true", APPLE_PROMO_KEY_PATH=f.name) is not None)
        os.unlink(f.name)
        check("config repr hides private key", "PRIVATE" not in repr(ow.rewards_config()))
    finally:
        os.environ.clear()
        os.environ.update(saved)
        promo._config = promo.PromoConfig(False, 50, "100/minute")
        validate_owner_rewards_config()


def test_helpers():
    print("\n== Pure helpers ==")
    check("normalize strips +tag", normalize_email("A+x@Example.com") == "a@example.com")
    check("normalize gmail dots", normalize_email("a.b.c@gmail.com") == "abc@gmail.com")
    check("normalize googlemail fold", normalize_email("a.b+z@googlemail.com") == "ab@gmail.com")
    check("non-gmail dots kept", normalize_email("a.b@example.com") == "a.b@example.com")
    check("garbage email -> None", normalize_email("nope") is None and normalize_email(None) is None
          and normalize_email("+x@a.com") is None)
    u = str(uuid.uuid4())
    check("applicationUsername stable + non-PII",
          ow.apple_application_username(u) == ow.apple_application_username(u)
          and u not in ow.apple_application_username(u))


def test_flag_off(client, admin, user):
    print("\n== Flag off: uniform 404, no accrual ==")
    set_flags(rewards=False)
    aid, atok = admin
    uid, utok = user
    routes = [
        ("post", "/admin/promo/creator-codes", {"name": "x", "owner_email": "a@b.co"}, atok),
        ("get", "/admin/promo/codes-overview", None, atok),
        ("post", f"/admin/promo/codes/{uuid.uuid4()}/deactivate", None, atok),
        ("post", f"/admin/promo/codes/{uuid.uuid4()}/reactivate", None, atok),
        ("delete", f"/admin/promo/codes/{uuid.uuid4()}", None, atok),
        ("get", f"/rewards/{uid}", None, utok),
        ("post", f"/rewards/{uid}/apple/claim", None, utok),
    ]
    for m, path, body, tok in routes:
        for who, t in (("authed", tok), ("anon", None)):
            r = getattr(client, m)(path, headers=ip_hdr(t), **({"json": body} if body is not None else {}))
            check(f"{m.upper()} {path.split('/')[1:3]} flag off {who} -> 404", r.status_code == 404, str(r.status_code))
    owner, _ = signup(client)
    give_sub(owner)
    code = friend_code(owner)
    inv, _ = signup(client, invite=code)
    check("flag off: signup with friend code ok but no reward", rewards_of(owner) == [])
    ow.credit_signup_reward(inv, "x@example.com", code, "1.2.3.4")
    check("flag off: credit_signup_reward is a no-op", rewards_of(owner) == [])
    # promo off also disables
    set_flags(rewards=True)
    promo._config = promo.PromoConfig(False, 50, "100/minute")
    check("rewards flag on but promo off => disabled", not ow.rewards_enabled())
    check("rewards routes 404 when promo off",
          client.get(f"/rewards/{uid}", headers=ip_hdr(utok)).status_code == 404)
    # never-validated config fails closed
    saved = ow._config
    ow._config = None
    check("unvalidated config => rewards_enabled False", ow.rewards_enabled() is False)
    ow._config = saved
    set_flags(rewards=True)


def test_signup_earn(client):
    print("\n== Signup earn + abuse mitigations ==")
    set_flags(True)
    owner, _ = signup(client)
    give_sub(owner, "apple", otxn="otx_seed_1")
    code = friend_code(owner)
    inv1, _ = signup(client, invite=code)
    rs = rewards_of(owner)
    check("signup with friend code credits exactly one reward", len(rs) == 1 and rs[0][0] == "earned"
          and rs[0][1] == "signup", str(rs))
    check("idempotency key bound to invitee", rs[0][4] == f"signup:{inv1}")
    o, rid, ow_id = earn_signup(code, inv1, "whatever@example.com")
    check("replay for same invitee => duplicate, still 1", o == "duplicate" and len(rewards_of(owner)) == 1, o)
    check("audit has reward_earned", "reward_earned" in audit_actions(owner))
    # invalid / unknown code earns nothing and does not break signup
    before = len(rewards_of(owner))
    signup(client, invite="NOTACODE123")
    signup(client, invite="")
    check("unknown/blank code: signup ok, nothing earned", len(rewards_of(owner)) == before)
    # self referral via same user and same normalized email
    o, *_ = earn_signup(code, owner, "x@example.com")
    check("self-referral (same user) denied", o == "denied_self_referral", o)
    owner_email = q("SELECT email FROM users WHERE _id=%s", (owner,))[0][0]
    other, _ = signup(client)
    o, *_ = earn_signup(code, other, owner_email.replace("@", "+alias@"))
    check("self-referral via +alias of owner email denied", o == "denied_self_referral", o)
    check("audit has denied_self_referral", "reward_denied_self_referral" in audit_actions(owner))
    # email normalization dedupe: gmail dot/plus variants of one inbox => only one reward
    owner2, _ = signup(client)
    give_sub(owner2)
    c2 = friend_code(owner2)
    tag = uuid.uuid4().hex[:8]
    a, _ = signup(client, email=f"dd.{tag}@gmail.com")
    b, _ = signup(client, email=f"d.d{tag}+x@gmail.com")
    o1 = earn_signup(c2, a, f"dd.{tag}@gmail.com", ip="203.0.113.50")[0]
    o2 = earn_signup(c2, b, f"d.d{tag}+x@gmail.com", ip="203.0.113.51")[0]
    check("first gmail variant earns", o1 == "earned", o1)
    check("gmail dot/plus variant of same inbox deduped (no 2nd reward)", o2 == "duplicate", o2)
    check("only one reward for deduped inbox", len(rewards_of(owner2)) == 1)
    # per-IP cap (config 2)
    owner3, _ = signup(client)
    give_sub(owner3)
    c3 = friend_code(owner3)
    ip = f"203.0.113.{uuid.uuid4().int % 200 + 20}"
    outs = []
    for _ in range(3):
        i, _ = signup(client)
        outs.append(earn_signup(c3, i, f"{uuid.uuid4().hex}@example.com", ip=ip)[0])
    check("per-IP cap: 2 earned then skipped_ip_cap", outs == ["earned", "earned", "skipped_ip_cap"], str(outs))
    # per-owner cap (3) and max outstanding (3): 4th skipped
    owner4, _ = signup(client)
    give_sub(owner4)
    c4 = friend_code(owner4)
    outs = []
    for n in range(4):
        i, _ = signup(client)
        outs.append(earn_signup(c4, i, f"{uuid.uuid4().hex}@example.com", ip=f"203.0.114.{n + 1}")[0])
    check("per-owner cap enforced (3 then skipped)", outs[:3] == ["earned"] * 3 and outs[3] in
          ("skipped_cap", "skipped_outstanding"), str(outs))
    check("cap/outstanding skip audited",
          {"reward_skipped_cap", "reward_skipped_outstanding"} & set(audit_actions(owner4)))
    # ineligible owners dropped (not held)
    for label, kw in (("no subscription", None), ("free plan", dict(plan="free", provider="stripe")),
                      ("admin_comp", dict(provider="admin_comp")),
                      ("group plan (max_members 3)", dict(max_members=3)),
                      ("inactive sub", dict(status="canceled"))):
        ow_user, _ = signup(client)
        if kw is not None:
            give_sub(ow_user, **kw)
        cc = friend_code(ow_user)
        i, _ = signup(client)
        o = earn_signup(cc, i, f"{uuid.uuid4().hex}@example.com")[0]
        check(f"owner with {label}: dropped, none held", o == "skipped_no_subscription"
              and rewards_of(ow_user) == [], o)
    check("no-subscription drop audited", "reward_skipped_no_subscription" in
          audit_actions(ow_user))
    # inactive / expired friend code ignored
    owner5, _ = signup(client)
    give_sub(owner5)
    c5 = friend_code(owner5)
    q("UPDATE promo_codes SET active = FALSE WHERE code = %s", (c5,))
    i, _ = signup(client)
    check("inactive friend code earns nothing", earn_signup(c5, i, "z@example.com")[0] == "ignored")
    q("UPDATE promo_codes SET active = TRUE, expires_at = NOW() - INTERVAL '1 day' WHERE code = %s", (c5,))
    check("expired friend code earns nothing", earn_signup(c5, i, "z@example.com")[0] == "ignored")
    # case-insensitive code
    owner6, _ = signup(client)
    give_sub(owner6)
    c6 = friend_code(owner6)
    i, _ = signup(client)
    check("lowercase code still credits", earn_signup(c6.lower(), i, f"{uuid.uuid4().hex}@example.com")[0] == "earned")
    # creator codes never earn through the signup path
    cid = mk_creator_code(client, "e@example.com")
    i, _ = signup(client)
    check("creator code via signup path ignored", earn_signup(cid, i, "q@example.com")[0] == "ignored")
    # Google/Apple signup paths accept invite_code field (schema)
    GoogleAuth, AppleAuth = main_module.GoogleAuth, main_module.AppleAuth
    check("GoogleAuth/AppleAuth carry invite_code",
          "invite_code" in GoogleAuth.model_fields and "invite_code" in AppleAuth.model_fields)


ADMIN_TOK = [None]


def mk_creator_code(client, email, **kw):
    r = client.post("/admin/promo/creator-codes", json={"name": "C", "owner_email": email, **kw},
                    headers=ck(ADMIN_TOK[0]))
    assert r.status_code == 201, r.text
    CREATORS.append(r.json()["creator"]["id"])
    return r.json()["code"]["code"]


def test_concurrent_earn(client):
    print("\n== Concurrent earns respect cap and idempotency ==")
    set_flags(True)
    owner, _ = signup(client)
    give_sub(owner)
    code = friend_code(owner)
    invitees = [signup(client)[0] for _ in range(8)]
    outs, lock = [], threading.Lock()

    def run(i):
        r = earn_signup(code, i, f"{uuid.uuid4().hex}@example.com", ip=f"203.0.115.{uuid.uuid4().int % 250 + 1}")
        with lock:
            outs.append(r[0])
    ts = [threading.Thread(target=run, args=(i,)) for i in invitees]
    [t.start() for t in ts]
    [t.join() for t in ts]
    n = len(rewards_of(owner))
    check("8 concurrent signups, cap 3 => exactly 3 rewards", n == 3, f"{n} {outs}")
    # same invitee in parallel => single reward
    owner2, _ = signup(client)
    give_sub(owner2)
    code2 = friend_code(owner2)
    inv, _ = signup(client)
    outs.clear()
    ts = [threading.Thread(target=lambda: outs.append(
        earn_signup(code2, inv, f"{uuid.uuid4().hex}@example.com", ip="203.0.116.9")[0])) for _ in range(6)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("same invitee 6x in parallel => exactly one reward", len(rewards_of(owner2)) == 1, str(outs))


def test_purchase_earn(client):
    print("\n== Creator-code purchase earn ==")
    set_flags(True)
    owner_uid, _ = signup(client)
    email = q("SELECT email FROM users WHERE _id=%s", (owner_uid,))[0][0]
    code = mk_creator_code(client, email.upper())
    db = RewardManager()
    row = db.find_code(code)
    row_full = db.get_code_by_id(row["id"])
    db.close()
    buyer, _ = signup(client)
    # owner has no subscription => dropped
    ow.credit_purchase_reward(row["id"], buyer, "sess_1")
    check("creator owner without subscription gets nothing", rewards_of(owner_uid) == [])
    check("drop audited", "reward_skipped_no_subscription" in audit_actions(owner_uid))
    give_sub(owner_uid)
    ow.credit_purchase_reward(row["id"], buyer, "sess_2")
    rs = rewards_of(owner_uid)
    check("subscribed creator earns on purchase (case-insensitive email match)", len(rs) == 1 and rs[0][1] == "purchase", str(rs))
    ow.credit_purchase_reward(row["id"], buyer, "sess_2")
    check("webhook replay idempotent", len(rewards_of(owner_uid)) == 1)
    ow.credit_purchase_reward(row["id"], owner_uid, "sess_3")
    check("buyer == owner denied", len(rewards_of(owner_uid)) == 1
          and "reward_denied_self_referral" in audit_actions(owner_uid))
    ow.credit_purchase_reward(str(uuid.uuid4()), buyer, "sess_4")
    check("unknown code id ignored (no raise)", len(rewards_of(owner_uid)) == 1)
    # code with no owner email attached => nothing
    r = client.post("/admin/promo/creators", json={"name": "NoMail"}, headers=ck(ADMIN_TOK[0]))
    CREATORS.append(r.json()["id"])
    r2 = client.post("/admin/promo/codes", json={"code": f"NM{uuid.uuid4().hex[:6]}".upper(),
                                                 "creator_id": r.json()["id"]}, headers=ck(ADMIN_TOK[0]))
    ow.credit_purchase_reward(r2.json()["id"], buyer, "sess_5")
    check("creator code without owner_email earns nothing", len(rewards_of(owner_uid)) == 1)
    # owner email maps to no user
    c_orphan = mk_creator_code(client, f"nobody-{uuid.uuid4().hex[:6]}@example.com")
    db = RewardManager(); oid = db.find_code(c_orphan)["id"]; db.close()
    ow.credit_purchase_reward(oid, buyer, "sess_6")
    check("owner email with no account => skipped, no reward",
          q("SELECT COUNT(*) FROM owner_rewards WHERE code_id=%s", (oid,))[0][0] == 0)
    # inactive creator
    q("UPDATE creators SET active=FALSE WHERE _id=%s", (row["creator_id"],))
    ow.credit_purchase_reward(row["id"], buyer, "sess_7")
    check("inactive creator earns nothing", len(rewards_of(owner_uid)) == 1)
    q("UPDATE creators SET active=TRUE WHERE _id=%s", (row["creator_id"],))
    # flag off => nothing
    set_flags(False)
    ow.credit_purchase_reward(row["id"], buyer, "sess_8")
    check("flag off: purchase earns nothing", len(rewards_of(owner_uid)) == 1)
    set_flags(True)
    # webhook integration: a logged creator-code redemption triggers exactly one earn
    ow2, _ = signup(client)
    e2 = q("SELECT email FROM users WHERE _id=%s", (ow2,))[0][0]
    give_sub(ow2)
    code2 = mk_creator_code(client, e2)
    db = RewardManager(); cid2 = db.find_code(code2)["id"]; db.close()
    buyer2, _ = signup(client)
    sess = f"cs_{uuid.uuid4().hex[:10]}"
    event = {"type": "checkout.session.completed", "data": {"object": {
        "id": sess, "client_reference_id": buyer2, "customer": "cus_x",
        "subscription": f"sub_{uuid.uuid4().hex[:12]}", "invoice": f"in_{uuid.uuid4().hex[:8]}",
        "payment_status": "paid", "total_details": {"amount_discount": 1349},
        "metadata": {"user_id": buyer2, "member_count": "1", "promo_code_id": cid2}}}}
    o = (stripe_service.is_configured, stripe_service.construct_event, stripe_service.retrieve_subscription,
         stripe_service.apply_owner_reward)
    stripe_service.is_configured = lambda: True
    stripe_service.construct_event = lambda payload, sig: event
    stripe_service.retrieve_subscription = lambda sid: {"status": "active", "trial_end": None,
                                                        "current_period_end": 1999999999}
    stripe_service.apply_owner_reward = lambda *a: False   # keep earned; we test earn only
    try:
        for _ in range(2):
            r = client.post("/subscriptions/stripe/webhook", content=b"{}", headers={"stripe-signature": "x"})
        check("webhook 200", r.status_code == 200, f"{r.status_code} {r.text}")
        rs = rewards_of(ow2)
        check("checkout.session.completed w/ creator code earns exactly once across replay",
              len(rs) == 1 and rs[0][1] == "purchase", str(rs))
    finally:
        (stripe_service.is_configured, stripe_service.construct_event, stripe_service.retrieve_subscription,
         stripe_service.apply_owner_reward) = o


def _webhook_event(buyer, code_id, sess=None):
    sess = sess or f"cs_{uuid.uuid4().hex[:10]}"
    return sess, {"type": "checkout.session.completed", "data": {"object": {
        "id": sess, "client_reference_id": buyer, "customer": "cus_x",
        "subscription": f"sub_{uuid.uuid4().hex[:12]}", "invoice": f"in_{uuid.uuid4().hex[:8]}",
        "payment_status": "paid", "total_details": {"amount_discount": 1349},
        "metadata": {"user_id": buyer, "member_count": "1", "promo_code_id": code_id}}}}


class WebhookStubs:
    """Stub Stripe so the real webhook handler runs against the real DB."""
    def __init__(self, event):
        self.event = event

    def __enter__(self):
        self.o = (stripe_service.is_configured, stripe_service.construct_event,
                  stripe_service.retrieve_subscription, stripe_service.apply_owner_reward)
        stripe_service.is_configured = lambda: True
        stripe_service.construct_event = lambda payload, sig: self.event
        stripe_service.retrieve_subscription = lambda sid: {"status": "active", "trial_end": None,
                                                            "current_period_end": 1999999999}
        stripe_service.apply_owner_reward = lambda *a: False   # keep earned; we test earn only
        return self

    def __exit__(self, *a):
        (stripe_service.is_configured, stripe_service.construct_event,
         stripe_service.retrieve_subscription, stripe_service.apply_owner_reward) = self.o


def _post_webhook(client):
    return client.post("/subscriptions/stripe/webhook", content=b"{}", headers={"stripe-signature": "x"})


def test_purchase_retry(client):
    print("\n== Creator-purchase crediting is retry-safe (webhook replay) ==")
    set_flags(True)
    owner_uid, _ = signup(client)
    email = q("SELECT email FROM users WHERE _id=%s", (owner_uid,))[0][0]
    give_sub(owner_uid)
    code = mk_creator_code(client, email)
    db = RewardManager(); cid = db.find_code(code)["id"]; db.close()

    # 1. transient failure at crediting => 500; replay re-attempts and credits once
    buyer, _ = signup(client)
    sess, ev = _webhook_event(buyer, cid)
    real = RewardManager.earn_purchase
    calls = []

    def flaky(self, *a, **k):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("transient db blip")
        return real(self, *a, **k)
    RewardManager.earn_purchase = flaky
    try:
        with WebhookStubs(ev):
            r1 = _post_webhook(client)
            check("transient crediting failure => webhook 500 (Stripe retries)", r1.status_code == 500, r1.text)
            check("redemption durably logged despite the failure",
                  q("SELECT COUNT(*) FROM promo_redemptions WHERE idempotency_key=%s", (sess,))[0][0] == 1)
            check("no reward yet after the failed attempt", rewards_of(owner_uid) == [])
            check("buyer's plan was still recorded (crediting never blocks activation)",
                  q("SELECT COUNT(*) FROM subscriptions WHERE user_id=%s", (buyer,))[0][0] == 1)
            r2 = _post_webhook(client)
            check("replay re-attempts crediting => 200", r2.status_code == 200, r2.text)
            rs = rewards_of(owner_uid)
            check("replay credits the reward exactly once with the purchase idempotency key",
                  len(rs) == 1 and rs[0][4] == f"purchase:{sess}", str(rs))
            r3 = _post_webhook(client)
            check("further replay is a no-op (no double-grant)", r3.status_code == 200 and len(rewards_of(owner_uid)) == 1)
            check("replay of a credited purchase writes no spurious cap/skip audit",
                  not [a for a in audit_actions(owner_uid) if a.startswith("reward_skipped")])
    finally:
        RewardManager.earn_purchase = real

    # 2. credit_purchase_reward no longer swallows infra errors
    real_get = RewardManager.get_code_by_id
    RewardManager.get_code_by_id = lambda self, c: (_ for _ in ()).throw(RuntimeError("db down"))
    try:
        raised = False
        try:
            ow.credit_purchase_reward(cid, buyer, "sess_raise")
        except RuntimeError:
            raised = True
        check("credit_purchase_reward propagates infrastructure errors", raised)
    finally:
        RewardManager.get_code_by_id = real_get
    check("ineligible outcome (buyer == owner) returns normally, grants nothing", (
        ow.credit_purchase_reward(cid, owner_uid, "sess_self") is None) and len(rewards_of(owner_uid)) == 1)

    # 3. permanent/ineligible (owner not subscribed) stays fail-closed: webhook 200, no reward, no retry loop
    owner2, _ = signup(client)
    e2 = q("SELECT email FROM users WHERE _id=%s", (owner2,))[0][0]
    code2 = mk_creator_code(client, e2)
    db = RewardManager(); cid2 = db.find_code(code2)["id"]; db.close()
    buyer2, _ = signup(client)
    sess2, ev2 = _webhook_event(buyer2, cid2)
    with WebhookStubs(ev2):
        r = _post_webhook(client)
        check("ineligible owner => 200 (fail closed, not retried)", r.status_code == 200, r.text)
        check("ineligible owner => no reward", rewards_of(owner2) == [])

    # 4. an over-cap redemption never earns, even on replay
    buyer3, _ = signup(client)
    sess3, ev3 = _webhook_event(buyer3, cid)
    with WebhookStubs(ev3):
        RewardManager.earn_purchase = lambda self, *a, **k: (_ for _ in ()).throw(RuntimeError("blip"))
        try:
            _post_webhook(client)
        finally:
            RewardManager.earn_purchase = real
        q("UPDATE promo_redemptions SET over_cap=TRUE WHERE idempotency_key=%s", (sess3,))
        before = len(rewards_of(owner_uid))
        r = _post_webhook(client)
        check("over-cap redemption replay => 200, no reward", r.status_code == 200
              and len(rewards_of(owner_uid)) == before, f"{r.status_code}")

    # 5. concurrent deliveries of the same event => exactly one reward, all succeed
    owner4, _ = signup(client)
    e4 = q("SELECT email FROM users WHERE _id=%s", (owner4,))[0][0]
    give_sub(owner4)
    code4 = mk_creator_code(client, e4)
    db = RewardManager(); cid4 = db.find_code(code4)["id"]; db.close()
    buyer4, _ = signup(client)
    sess4, ev4 = _webhook_event(buyer4, cid4)
    codes = []
    with WebhookStubs(ev4):
        ts = [threading.Thread(target=lambda: codes.append(_post_webhook(client).status_code)) for _ in range(6)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        # a final replay settles any delivery that lost a race and 500'd for a retry
        final = _post_webhook(client).status_code
    rs = rewards_of(owner4)
    check("6 concurrent deliveries => exactly one reward", len(rs) == 1 and rs[0][4] == f"purchase:{sess4}",
          f"{codes} {rs}")
    check("concurrent deliveries settle to 200", final == 200 and set(codes) <= {200, 500}, f"{codes} {final}")

    # 6. concurrent crediting calls directly (same purchase) => one reward
    owner5, _ = signup(client)
    e5 = q("SELECT email FROM users WHERE _id=%s", (owner5,))[0][0]
    give_sub(owner5)
    code5 = mk_creator_code(client, e5)
    db = RewardManager(); cid5 = db.find_code(code5)["id"]; db.close()
    buyer5, _ = signup(client)
    ts = [threading.Thread(target=ow.credit_purchase_reward, args=(cid5, buyer5, "sess_conc")) for _ in range(8)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("8 concurrent credit calls, same purchase => one reward", len(rewards_of(owner5)) == 1)


def test_stripe_apply(client):
    print("\n== Stripe owner redemption ==")
    set_flags(True)
    owner, _ = signup(client)
    sid = f"sub_{uuid.uuid4().hex[:10]}"
    give_sub(owner, "stripe", stripe_sub=sid)
    code = friend_code(owner)
    # earn two without auto-apply (call earn directly)
    for n in range(2):
        i, _ = signup(client)
        earn_signup(code, i, f"{uuid.uuid4().hex}@example.com", ip=f"203.0.117.{n + 1}")
    check("two earned", [r[0] for r in rewards_of(owner)] == ["earned", "earned"])
    with StripeStub(ok=True) as st:
        db = RewardManager()
        rid = db.apply_stripe_reward(owner)
        db.close()
        rs = rewards_of(owner)
        check("oldest reward applied + claimed", rid and rs[0][0] == "claimed" and rs[0][2] == "stripe"
              and rs[0][3] == sid, str(rs))
        check("Stripe called once with percent+reward id", len(st.calls) == 1 and st.calls[0][1] == 50
              and st.calls[0][2] == rid, str(st.calls))
        check("only one applied at a time (FIFO, 2nd still earned)", rs[1][0] == "earned")
        check("claim audited", "reward_claimed" in audit_actions(owner))
        # concurrent applies for the 2nd reward -> exactly one Stripe call for it
        results = []
        def go():
            d = RewardManager()
            try:
                results.append(d.apply_stripe_reward(owner))
            finally:
                d.close()
        ts = [threading.Thread(target=go) for _ in range(5)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        n_claimed = sum(1 for r in rewards_of(owner) if r[0] == "claimed")
        check("5 concurrent applies: no double-apply (2 claimed total)", n_claimed == 2, str(rewards_of(owner)))
        check("no double Stripe call per reward", len({c[2] for c in st.calls}) == len(st.calls), str(st.calls))
        d = RewardManager()
        check("nothing left => None", d.apply_stripe_reward(owner) is None)
        d.close()
    # deferred (Stripe returns False) leaves reward earned
    owner2, _ = signup(client)
    give_sub(owner2, "stripe")
    c2 = friend_code(owner2)
    i, _ = signup(client)
    earn_signup(c2, i, f"{uuid.uuid4().hex}@example.com")
    with StripeStub(ok=False):
        d = RewardManager()
        check("stripe says no => None", d.apply_stripe_reward(owner2) is None)
        d.close()
    check("deferred leaves reward earned", rewards_of(owner2)[0][0] == "earned")
    check("deferral audited", "reward_apply_deferred" in audit_actions(owner2))
    with StripeStub(boom=True):
        d = RewardManager()
        check("stripe exception => fail closed None", d.apply_stripe_reward(owner2) is None)
        d.close()
    check("exception leaves reward earned", rewards_of(owner2)[0][0] == "earned")
    # apple owner never applied via stripe path
    ao, _ = signup(client)
    give_sub(ao, "apple")
    i, _ = signup(client)
    earn_signup(friend_code(ao), i, f"{uuid.uuid4().hex}@example.com")
    with StripeStub() as st:
        d = RewardManager()
        check("apple owner: stripe apply is a no-op", d.apply_stripe_reward(ao) is None and not st.calls)
        d.close()
    # expiry: past-expiry reward is never applied
    eo, _ = signup(client)
    give_sub(eo, "stripe")
    i, _ = signup(client)
    earn_signup(friend_code(eo), i, f"{uuid.uuid4().hex}@example.com")
    q("UPDATE owner_rewards SET expires_at = NOW() - INTERVAL '1 hour' WHERE owner_user_id=%s", (eo,))
    with StripeStub() as st:
        d = RewardManager()
        check("expired reward not applied", d.apply_stripe_reward(eo) is None and not st.calls)
        d.close()
    check("expired reward marked expired", rewards_of(eo)[0][0] == "expired")
    # signup auto-applies for stripe owner via the hook
    so, _ = signup(client)
    give_sub(so, "stripe")
    with StripeStub() as st:
        i, _ = signup(client, invite=friend_code(so))
        check("signup hook auto-applies Stripe owner reward", rewards_of(so)[0][0] == "claimed" and len(st.calls) == 1,
              str(rewards_of(so)))
    # stripe_service.apply_owner_reward logic with mocked stripe SDK
    test_stripe_service_unit()


def test_stripe_service_unit():
    s = stripe_service
    saved = (s.stripe.Subscription.retrieve, s.stripe.Subscription.modify, s.ensure_owner_reward_coupon)
    mods = []
    s.ensure_owner_reward_coupon = lambda pct: f"c{pct}"
    s.stripe.Subscription.modify = lambda sid, **kw: mods.append((sid, kw))
    try:
        def run(sub):
            s.stripe.Subscription.retrieve = lambda sid: sub
            mods.clear()
            return s.apply_owner_reward("sub_1", 50, "rid1"), list(mods)
        ok, m = run({"status": "active", "metadata": {}})
        check("stripe unit: applies coupon with idempotency key", ok is True and len(m) == 1
              and m[0][1]["discounts"] == [{"coupon": "c50"}] and m[0][1]["idempotency_key"] == "owner-reward-rid1"
              and m[0][1]["metadata"] == {"owner_reward_id": "rid1"}, str(m))
        ok, m = run({"status": "active", "metadata": {"owner_reward_id": "rid1"}, "discount": {"coupon": {"id": "c50"}}})
        check("stripe unit: already applied => True without re-modify", ok is True and m == [])
        ok, m = run({"status": "active", "metadata": {}, "discount": {"coupon": {"id": "other"}}})
        check("stripe unit: other discount => never overwrite", ok is False and m == [])
        ok, m = run({"status": "past_due", "metadata": {}})
        check("stripe unit: inactive => False", ok is False and m == [])
        ok, m = run({"status": "active", "cancel_at_period_end": True, "metadata": {}})
        check("stripe unit: cancelling => False", ok is False and m == [])
    finally:
        s.stripe.Subscription.retrieve, s.stripe.Subscription.modify, s.ensure_owner_reward_coupon = saved
    # coupon terms tamper => fails closed
    sv = (s.stripe.Coupon.retrieve,)
    s.stripe.Coupon.retrieve = lambda cid: {"percent_off": 10, "duration": "forever"}
    try:
        try:
            s.ensure_owner_reward_coupon(50)
            raised = False
        except RuntimeError:
            raised = True
        check("stripe unit: coupon with changed terms raises (fail closed)", raised)
    finally:
        (s.stripe.Coupon.retrieve,) = sv


def verify_sig(sig, product, offer, user, bundle="com.fellowscript.app"):
    msg = "⁣".join([bundle, sig["keyIdentifier"], product, offer, user, sig["nonce"],
                         str(sig["timestamp"])]).encode()
    try:
        _KEY.public_key().verify(base64.b64decode(sig["signature"]), msg, ec.ECDSA(hashes.SHA256()))
        return True
    except Exception:
        return False


def test_apple(client):
    print("\n== Apple claim + reconciliation ==")
    set_flags(True)
    owner, otok = signup(client)
    give_sub(owner, "apple", otxn="otx_a1")
    code = friend_code(owner)
    path = f"/rewards/{owner}/apple/claim"
    r = client.post(path, headers=ip_hdr(otok))
    check("no reward => uniform 404", r.status_code == 404, str(r.status_code))
    i, _ = signup(client)
    earn_signup(code, i, f"{uuid.uuid4().hex}@example.com", ip="203.0.118.1")
    other, otok2 = signup(client)
    check("claim without session => 401/403", client.post(path, headers=ip_hdr()).status_code in (401, 403))
    check("claim for another user => 403", client.post(path, headers=ip_hdr(otok2)).status_code in (401, 403, 404))
    s = client.get(f"/rewards/{owner}", headers=ip_hdr(otok))
    check("summary: earned 1, can_claim_apple", s.status_code == 200 and s.json()["earned"] == 1
          and s.json()["can_claim_apple"] is True and s.json()["provider"] == "apple", s.text)
    check("summary no-store", s.headers.get("cache-control") == "no-store")
    check("summary for another user denied", client.get(f"/rewards/{owner}", headers=ip_hdr(otok2)).status_code
          in (401, 403, 404))
    r = client.post(path, headers=ip_hdr(otok))
    check("claim 200", r.status_code == 200, r.text)
    sig = r.json()
    prod = "com.fellowscript.access.one"
    check("signature fields", sig["keyIdentifier"] == "G6DRYNCNRS" and sig["productIdentifier"] == prod
          and sig["offerIdentifier"] == "invite_reward_50"
          and sig["applicationUsername"] == sig["nonce"], str(sig))
    check("applicationUsername/appAccountToken is a per-claim UUID (not the stable per-user one)",
          sig["applicationUsername"] != ow.apple_application_username(owner))
    check("signature verifies with public key (ES256)", verify_sig(sig, prod, "invite_reward_50", sig["applicationUsername"]))
    check("tampered offer does not verify", not verify_sig(sig, prod, "invite_reward_50_2", sig["applicationUsername"]))
    check("response no-store", r.headers.get("cache-control") == "no-store")
    check("signature body leaks no key material", "PRIVATE" not in r.text)
    rs = rewards_of(owner)
    check("reward still earned (reserved), not claimed", rs[0][0] == "earned")
    nonce_row = q("SELECT apple_nonce, apple_reserved_until FROM owner_rewards WHERE owner_user_id=%s", (owner,))[0]
    check("nonce+reservation recorded", nonce_row[0] == sig["nonce"] and nonce_row[1] is not None)
    r2 = client.post(path, headers=ip_hdr(otok))
    check("second claim while reserved => 409", r2.status_code == 409, str(r2.status_code))
    check("summary: can_claim false while in progress",
          client.get(f"/rewards/{owner}", headers=ip_hdr(otok)).json()["can_claim_apple"] is False)
    # reconcile: wrong offer ignored, wrong offerType ignored, non-apple ignored
    ow.reconcile_apple_offer(owner, {"offerIdentifier": "invite_reward_50_2", "offerType": 2,
                                     "transactionId": "t0", "productId": prod})
    ow.reconcile_apple_offer(owner, {"offerIdentifier": "invite_reward_50", "offerType": 1,
                                     "transactionId": "t0", "productId": prod})
    ow.reconcile_apple_offer(owner, {"transactionId": "t0", "productId": prod})
    ow.reconcile_apple_offer(None, {"offerIdentifier": "invite_reward_50", "offerType": 2, "productId": prod})
    check("mismatched/non-promo/anon payloads do not claim", rewards_of(owner)[0][0] == "earned")
    payload = {"offerIdentifier": "invite_reward_50", "offerType": 2, "transactionId": "t1", "productId": prod,
               "appAccountToken": sig["nonce"].upper()}
    ow.reconcile_apple_offer(owner, {k: v for k, v in payload.items() if k != "appAccountToken"})
    check("promo txn without appAccountToken does not claim (audited unmatched)",
          rewards_of(owner)[0][0] == "earned" and "reward_apple_redeemed_unmatched" in audit_actions(owner))
    ow.reconcile_apple_offer(owner, payload)
    rs = rewards_of(owner)
    check("verified promo transaction finalizes claim", rs[0][0] == "claimed" and rs[0][2] == "apple"
          and rs[0][3] == "t1", str(rs))
    ow.reconcile_apple_offer(owner, payload)
    check("replay of same transaction is a no-op", [r[0] for r in rewards_of(owner)] == ["claimed"])
    # a second reward must not be consumed by a replayed txn
    i2, _ = signup(client)
    earn_signup(code, i2, f"{uuid.uuid4().hex}@example.com", ip="203.0.118.2")
    ow.reconcile_apple_offer(owner, payload)
    check("replayed txn id cannot burn a later reward", [r[0] for r in rewards_of(owner)] == ["claimed", "earned"])
    ow.reconcile_apple_offer(owner, {**payload, "transactionId": "t2"})
    check("second txn carrying an already-finalized nonce => duplicate redemption audited, nothing granted",
          [r[0] for r in rewards_of(owner)] == ["claimed", "earned"]
          and rewards_of(owner)[0][3] == "t1"
          and "reward_apple_duplicate_redemption" in audit_actions(owner))
    ow.reconcile_apple_offer(owner, {**payload, "transactionId": "t3", "appAccountToken": str(uuid.uuid4())})
    check("txn with unknown nonce => unmatched, later reward untouched",
          [r[0] for r in rewards_of(owner)] == ["claimed", "earned"])
    # race: concurrent claims -> one signature, one reservation
    ro, rtok = signup(client)
    give_sub(ro, "apple", otxn="otx_a2")
    i, _ = signup(client)
    earn_signup(friend_code(ro), i, f"{uuid.uuid4().hex}@example.com", ip="203.0.118.3")
    codes = []
    def go():
        codes.append(client.post(f"/rewards/{ro}/apple/claim", headers=ip_hdr(rtok)).status_code)
    ts = [threading.Thread(target=go) for _ in range(5)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("5 concurrent claims: exactly one 200", codes.count(200) == 1 and all(c in (200, 409) for c in codes),
          str(codes))
    # reservation lapse alone must NOT allow re-sign: the old signature may still be redeemable
    q("UPDATE owner_rewards SET apple_reserved_until = NOW() - INTERVAL '1 minute' WHERE owner_user_id=%s", (ro,))
    check("reservation lapsed but signature still live => 409, no second signature",
          client.post(f"/rewards/{ro}/apple/claim", headers=ip_hdr(rtok)).status_code == 409)
    check("summary: still can_claim false after reservation lapse",
          client.get(f"/rewards/{ro}", headers=ip_hdr(rtok)).json()["can_claim_apple"] is False)
    # concurrent claims once the old signature is dead: exactly one new signature
    q("UPDATE owner_rewards SET apple_reserved_until = NOW() - INTERVAL '1 minute', "
      "apple_signature_expires_at = NOW() - INTERVAL '1 minute' WHERE owner_user_id=%s", (ro,))
    pre_nonce = q("SELECT apple_nonce FROM owner_rewards WHERE owner_user_id=%s", (ro,))[0][0]
    codes2 = []
    def go2():
        codes2.append(client.post(f"/rewards/{ro}/apple/claim", headers=ip_hdr(rtok)).status_code)
    ts = [threading.Thread(target=go2) for _ in range(5)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("5 concurrent re-claims after signature death: exactly one 200", codes2.count(200) == 1
          and all(c in (200, 409) for c in codes2), str(codes2))
    check("concurrent re-claim replaced the nonce exactly once",
          q("SELECT apple_nonce FROM owner_rewards WHERE owner_user_id=%s", (ro,))[0][0] != pre_nonce)
    old_nonce = pre_nonce
    q("UPDATE owner_rewards SET apple_reserved_until = NOW() - INTERVAL '1 minute', "
      "apple_signature_expires_at = NOW() - INTERVAL '1 minute' WHERE owner_user_id=%s", (ro,))
    # once the old signature is provably dead, re-sign replaces the ledger nonce
    r3 = client.post(f"/rewards/{ro}/apple/claim", headers=ip_hdr(rtok))
    check("after signature is dead a new claim succeeds", r3.status_code == 200, r3.text)
    new_nonce = r3.json()["nonce"]
    check("ledger nonce replaced by the new one", new_nonce != old_nonce and
          q("SELECT apple_nonce FROM owner_rewards WHERE owner_user_id=%s", (ro,))[0][0] == new_nonce)
    exp = q("SELECT apple_signature_expires_at - NOW() FROM owner_rewards WHERE owner_user_id=%s", (ro,))[0][0]
    check("signature death time is ~25h out (24h validity + skew margin)",
          timedelta(hours=24, minutes=50) < exp <= timedelta(hours=25), str(exp))
    ow.reconcile_apple_offer(ro, {"offerIdentifier": "invite_reward_50", "offerType": 2, "transactionId": "t_stale",
                                  "productId": prod, "appAccountToken": old_nonce})
    check("stale (superseded) nonce cannot finalize", rewards_of(ro)[0][0] == "earned")
    ow.reconcile_apple_offer(ro, {"offerIdentifier": "invite_reward_50", "offerType": 2, "transactionId": "t_cur",
                                  "productId": prod, "appAccountToken": new_nonce})
    check("current nonce finalizes", rewards_of(ro)[0][0] == "claimed" and rewards_of(ro)[0][3] == "t_cur")
    # a reward with a live signature is not expired out from under the user; once dead it can expire
    xo, xtok = signup(client)
    give_sub(xo, "apple", otxn="otx_a5")
    i, _ = signup(client)
    earn_signup(friend_code(xo), i, f"{uuid.uuid4().hex}@example.com", ip="203.0.118.5")
    xs = client.post(f"/rewards/{xo}/apple/claim", headers=ip_hdr(xtok)).json()
    q("UPDATE owner_rewards SET expires_at = NOW() - INTERVAL '1 hour' WHERE owner_user_id=%s", (xo,))
    client.get(f"/rewards/{xo}", headers=ip_hdr(xtok))
    check("expiry deferred while signature live", rewards_of(xo)[0][0] == "earned")
    ow.reconcile_apple_offer(xo, {"offerIdentifier": "invite_reward_50", "offerType": 2, "transactionId": "t_x1",
                                  "productId": prod, "appAccountToken": xs["nonce"]})
    check("past-expiry reward with live signature still finalizes to claimed", rewards_of(xo)[0][0] == "claimed")
    # another user's token never finalizes for me
    f1, f1tok = signup(client)
    give_sub(f1, "apple", otxn="otx_a6")
    i, _ = signup(client)
    earn_signup(friend_code(f1), i, f"{uuid.uuid4().hex}@example.com", ip="203.0.118.6")
    f1s = client.post(f"/rewards/{f1}/apple/claim", headers=ip_hdr(f1tok)).json()
    ow.reconcile_apple_offer(xo, {"offerIdentifier": "invite_reward_50", "offerType": 2, "transactionId": "t_x2",
                                  "productId": prod, "appAccountToken": f1s["nonce"]})
    check("another owner's nonce cannot be finalized by a different user", rewards_of(f1)[0][0] == "earned")
    # concurrent finalizations of the same nonce (different txn ids): exactly one wins
    outs = []
    def fin(n):
        try:
            outs.append(bool(_finalize(f1, f"t_race_{n}", prod, "invite_reward_50", f1s["nonce"])))
        except Exception as e:
            outs.append(type(e).__name__)
    ts = [threading.Thread(target=fin, args=(n,)) for n in range(6)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    rs = rewards_of(f1)
    check("6 concurrent finalizations of one nonce => exactly one claim", outs.count(True) == 1
          and [r[0] for r in rs] == ["claimed"], f"{outs} {rs}")
    check("DB unique index: one reward per apple nonce", q(
        "SELECT COUNT(*) FROM pg_indexes WHERE indexname='uq_owner_rewards_apple_nonce'")[0][0] == 1)
    # stripe owner / no subscription / group => 404
    so, stok = signup(client)
    give_sub(so, "stripe")
    i, _ = signup(client)
    earn_signup(friend_code(so), i, f"{uuid.uuid4().hex}@example.com")
    check("stripe owner cannot use apple claim (404)", client.post(f"/rewards/{so}/apple/claim", headers=ip_hdr(stok)).status_code == 404)
    # expired reward => 404
    eo, etok = signup(client)
    give_sub(eo, "apple", otxn="otx_a3")
    i, _ = signup(client)
    earn_signup(friend_code(eo), i, f"{uuid.uuid4().hex}@example.com")
    q("UPDATE owner_rewards SET expires_at = NOW() - INTERVAL '1 hour' WHERE owner_user_id=%s", (eo,))
    check("expired reward => 404", client.post(f"/rewards/{eo}/apple/claim", headers=ip_hdr(etok)).status_code == 404)
    # unmapped product (config missing mapping) fails closed
    uo, utok = signup(client)
    give_sub(uo, "apple", otxn="otx_a4")
    i, _ = signup(client)
    earn_signup(friend_code(uo), i, f"{uuid.uuid4().hex}@example.com")
    cfg = ow._config
    import dataclasses
    ow._config = dataclasses.replace(cfg, apple_offers={})
    check("unmapped product => 404", client.post(f"/rewards/{uo}/apple/claim", headers=ip_hdr(utok)).status_code == 404)
    ow._config = cfg
    # signing failure => 500, nothing reserved
    saved_sign = ow.apple_service.sign_promotional_offer
    def boom(*a, **k):
        raise ValueError("no")
    ow.apple_service.sign_promotional_offer = boom
    r = client.post(f"/rewards/{uo}/apple/claim", headers=ip_hdr(utok))
    ow.apple_service.sign_promotional_offer = saved_sign
    check("signing error => 500 generic, nothing reserved", r.status_code == 500 and "no" != r.json().get("detail")
          and q("SELECT apple_nonce FROM owner_rewards WHERE owner_user_id=%s", (uo,))[0][0] is None, r.text)
    # sign_promotional_offer rejects wrong key type
    try:
        ow.apple_service.sign_promotional_offer(
            ec.generate_private_key(ec.SECP384R1()), key_id="K", bundle_id="b", product_id="p", offer_id="o",
            application_username="u", nonce="N", timestamp_ms=1)
        rej = False
    except ValueError:
        rej = True
    check("sign_promotional_offer rejects non P-256 key", rej)
    # /apple/sync integration with decoded payload
    sync_owner, stoken = signup(client)
    give_sub(sync_owner, "apple", otxn="otx_sync")
    i, _ = signup(client)
    earn_signup(friend_code(sync_owner), i, f"{uuid.uuid4().hex}@example.com", ip="203.0.118.9")
    sync_sig = client.post(f"/rewards/{sync_owner}/apple/claim", headers=ip_hdr(stoken)).json()
    saved_decode = ow.apple_service.decode_jws
    ow.apple_service.decode_jws = lambda jws: {
        "environment": "Sandbox", "originalTransactionId": "otx_sync", "transactionId": "t_sync_1",
        "productId": prod, "expiresDate": 4102444800000, "offerType": 2, "offerIdentifier": "invite_reward_50",
        "appAccountToken": sync_sig["nonce"]}
    try:
        r = client.post("/subscriptions/apple/sync", json={"user_id": sync_owner, "jws": "x"}, headers=ip_hdr(stoken))
        st = rewards_of(sync_owner)
        check("apple/sync with promo txn claims reserved reward", r.status_code == 200 and st[0][0] == "claimed"
              and st[0][3] == "t_sync_1", f"{r.status_code} {r.text[:200]} {st}")
    finally:
        ow.apple_service.decode_jws = saved_decode


def _finalize(user_id, txn, product, offer, token):
    db = RewardManager()
    try:
        return db.finalize_apple_claim(user_id, txn, product, offer, token)
    finally:
        db.close()


def test_admin(client, admin, user):
    print("\n== Admin routes: authz + CRUD ==")
    set_flags(True)
    aid, atok = admin
    uid, utok = user
    body = {"name": "Admin Created", "owner_email": "Creator.One@Example.com"}
    check("create creator-code anon => 401/403", client.post("/admin/promo/creator-codes", json=body,
          headers=ip_hdr()).status_code in (401, 403))
    check("create creator-code non-admin => 403", client.post("/admin/promo/creator-codes", json=body,
          headers=ip_hdr(utok)).status_code in (401, 403))
    check("overview anon/non-admin denied", client.get("/admin/promo/codes-overview", headers=ip_hdr()).status_code
          in (401, 403) and client.get("/admin/promo/codes-overview", headers=ip_hdr(utok)).status_code in (401, 403))
    r = client.post("/admin/promo/creator-codes", json=body, headers=ip_hdr(atok))
    check("admin creates creator code", r.status_code == 201, r.text)
    out = r.json()
    CREATORS.append(out["creator"]["id"])
    code = out["code"]
    check("email normalized (lowercase) and attached", code["owner_email"] == "creator.one@example.com"
          if "owner_email" in code else True, str(code))
    stored = q("SELECT owner_email, kind FROM promo_codes WHERE _id=%s", (code["id"],))[0]
    check("stored owner_email lowercase, kind creator", stored == ("creator.one@example.com", "creator"), str(stored))
    check("generated code is secure-looking (>=8 chars, no dupes)", len(code["code"]) >= 8)
    codes = {client.post("/admin/promo/creator-codes", json=body, headers=ip_hdr(atok)).json()["code"]["code"]
             for _ in range(5)}
    for c in q("SELECT creator_id FROM promo_codes WHERE owner_email=%s", ("creator.one@example.com",)):
        if str(c[0]) not in CREATORS:
            CREATORS.append(str(c[0]))
    check("generated codes unique across calls", len(codes) == 5)
    for bad in ({"name": "x", "owner_email": "not-an-email"}, {"name": "", "owner_email": "a@b.co"},
                {"name": "x", "owner_email": "a@b.co", "code": "!!"},
                {"name": "x", "owner_email": "a@b.co", "max_redemptions": 0}):
        check(f"invalid body rejected {list(bad.values())[:2]}",
              client.post("/admin/promo/creator-codes", json=bad, headers=ip_hdr(atok)).status_code in (400, 422))
    c1 = client.post("/admin/promo/creator-codes", json={"name": "Dup", "owner_email": "d@example.com", "code": "OWDUP123"},
                     headers=ip_hdr(atok))
    CREATORS.append(c1.json()["creator"]["id"])
    c2 = client.post("/admin/promo/creator-codes", json={"name": "Dup2", "owner_email": "d2@example.com", "code": "owdup123"},
                     headers=ip_hdr(atok))
    check("duplicate code (case-insens) => 409 and no orphan creator", c2.status_code == 409
          and q("SELECT COUNT(*) FROM creators WHERE name='Dup2'")[0][0] == 0, f"{c2.status_code}")
    # overview with counts
    owner, _ = signup(client)
    give_sub(owner)
    inv, _ = signup(client)
    earn_signup(friend_code(owner), inv, f"{uuid.uuid4().hex}@example.com")
    ov = client.get("/admin/promo/codes-overview", headers=ip_hdr(atok))
    check("overview 200 list", ov.status_code == 200 and isinstance(ov.json(), list))
    row = next((x for x in ov.json() if x["id"] == code["id"]), None)
    check("overview row has email, counts", row and row["owner_email"] == "creator.one@example.com"
          and "redemption_count" in row and row["rewards_earned"] == 0 and row["rewards_claimed"] == 0, str(row))
    frow = next((x for x in client.get("/admin/promo/codes-overview?kind=friend&limit=500", headers=ip_hdr(atok)).json()
                 if x["kind"] == "friend" and x["rewards_earned"] >= 1), None)
    check("friend code overview shows reward counts", frow is not None)
    check("kind filter validated", client.get("/admin/promo/codes-overview?kind=bogus",
                                              headers=ip_hdr(atok)).status_code == 422)
    check("kind=creator filter only creators", all(x["kind"] == "creator" for x in
          client.get("/admin/promo/codes-overview?kind=creator", headers=ip_hdr(atok)).json()))
    # deactivate
    d_anon = client.post(f"/admin/promo/codes/{code['id']}/deactivate", headers=ip_hdr())
    d_user = client.post(f"/admin/promo/codes/{code['id']}/deactivate", headers=ip_hdr(utok))
    check("deactivate anon/non-admin denied", d_anon.status_code in (401, 403) and d_user.status_code in (401, 403))
    check("code still active after denied attempts",
          q("SELECT active FROM promo_codes WHERE _id=%s", (code["id"],))[0][0] is True)
    d = client.post(f"/admin/promo/codes/{code['id']}/deactivate", headers=ip_hdr(atok))
    check("admin deactivates", d.status_code == 200 and d.json()["active"] is False, d.text)
    d = client.post(f"/admin/promo/codes/{code['id']}/deactivate", headers=ip_hdr(atok))
    check("deactivate idempotent", d.status_code == 200 and d.json()["active"] is False)
    check("deactivate unknown => 404", client.post(f"/admin/promo/codes/{uuid.uuid4()}/deactivate",
          headers=ip_hdr(atok)).status_code == 404)
    check("deactivate malformed id => 4xx", client.post("/admin/promo/codes/not-a-uuid/deactivate",
          headers=ip_hdr(atok)).status_code in (400, 404, 422))
    acts = [r[0] for r in q("SELECT action FROM promo_audit_log WHERE code_id=%s", (code["id"],))]
    check("create + deactivate audited", "promo_creator_code_create" in acts and "promo_code_deactivate" in acts, str(acts))
    # deactivated creator code no longer earns
    ow3, _ = signup(client)
    e3 = q("SELECT email FROM users WHERE _id=%s", (ow3,))[0][0]
    give_sub(ow3)
    cc = client.post("/admin/promo/creator-codes", json={"name": "Dead", "owner_email": e3}, headers=ip_hdr(atok)).json()
    CREATORS.append(cc["creator"]["id"])
    client.post(f"/admin/promo/codes/{cc['code']['id']}/deactivate", headers=ip_hdr(atok))
    buyer, _ = signup(client)
    ow.credit_purchase_reward(cc["code"]["id"], buyer, "sess_dead")
    # (code row inactive; earn_purchase keys on creator_active, so verify the redemption path cannot reach it)
    db = RewardManager()
    ev = db.evaluate(buyer, cc["code"]["code"], 1, "b@example.com")
    db.close()
    check("deactivated code is not evaluable for buyers", ev is None)
    # existing admin routes remain admin-only with flag on
    check("legacy admin routes still deny non-admin", client.get("/admin/promo/report", headers=ip_hdr(utok)).status_code
          in (401, 403))


def test_awaiting_email(client, admin, user):
    """Task 20261005-creator-promo-awaiting-email: creator codes created without an
    owner email are inactive + flagged, can't be activated or redeemed until an
    email is added, adding an email never auto-activates, removing it deactivates."""
    print("\n== Creator code awaiting owner email (task 20261005) ==")
    set_flags(True)
    aid, atok = admin
    uid, utok = user

    def evaluable(text):
        buyer, _ = signup(client)
        db = RewardManager()
        try:
            return db.evaluate(buyer, text, 1, "b@example.com") is not None
        finally:
            db.close()

    def row(cid):
        return q("SELECT active, owner_email, requires_owner_email FROM promo_codes WHERE _id=%s", (cid,))[0]

    # create without email (omitted and blank both accepted)
    for label, body in (("omitted", {"name": "NoMailA", "notes": "n-a"}),
                        ("blank", {"name": "NoMailB", "notes": "n-b", "owner_email": "  "})):
        r = client.post("/admin/promo/creator-codes", json=body, headers=ip_hdr(atok))
        check(f"create without email ({label}) => 201", r.status_code == 201, r.text)
        out = r.json()
        CREATORS.append(out["creator"]["id"])
        code = out["code"]
        check(f"({label}) code created DEACTIVATED, no email", code["active"] is False
              and code["owner_email"] is None, str(code))
        check(f"({label}) response flags awaiting_email", code.get("awaiting_email") is True, str(code))
        check(f"({label}) name + notes saved", out["creator"]["name"] == body["name"]
              and out["creator"].get("notes") == body["notes"], str(out["creator"]))
        check(f"({label}) DB row inactive + requires_owner_email",
              row(code["id"]) == (False, None, True), str(row(code["id"])))
    cid, text = code["id"], code["code"]

    # custom code string saved
    custom = f"NOMAIL{uuid.uuid4().hex[:6]}".upper()
    r = client.post("/admin/promo/creator-codes", json={"name": "NoMailC", "code": custom}, headers=ip_hdr(atok))
    CREATORS.append(r.json()["creator"]["id"])
    check("custom code string saved without email", r.status_code == 201 and r.json()["code"]["code"] == custom, r.text)

    # exposed as awaiting in overview and list
    ov = {x["id"]: x for x in client.get("/admin/promo/codes-overview", headers=ip_hdr(atok)).json()}
    check("overview exposes awaiting_email true", ov[cid]["awaiting_email"] is True and ov[cid]["active"] is False)
    lst = client.get("/admin/promo/codes", headers=ip_hdr(atok))
    check("list_codes exposes awaiting_email", lst.status_code == 200 and
          any(x["id"] == cid and x["awaiting_email"] is True for x in lst.json()))

    # invalid email format => 422 (create + update), nothing persisted
    bad = client.post("/admin/promo/creator-codes", json={"name": "BadMail", "owner_email": "not-an-email"},
                      headers=ip_hdr(atok))
    check("create with invalid email => 422", bad.status_code in (400, 422), str(bad.status_code))
    check("invalid email create left no creator", q("SELECT COUNT(*) FROM creators WHERE name='BadMail'")[0][0] == 0)
    r = client.patch(f"/admin/promo/codes/{cid}", json={"owner_email": "nope"}, headers=ip_hdr(atok))
    check("PATCH invalid email => 422", r.status_code in (400, 422), str(r.status_code))
    check("invalid email PATCH changed nothing", row(cid) == (False, None, True))

    # activation blocked without email (all three entry points), stays inactive
    for label, call in (
        ("reactivate", lambda: client.post(f"/admin/promo/codes/{cid}/reactivate", headers=ip_hdr(atok))),
        ("PATCH active=true", lambda: client.patch(f"/admin/promo/codes/{cid}", json={"active": True},
                                                   headers=ip_hdr(atok))),
        ("PATCH active=true + blank email", lambda: client.patch(
            f"/admin/promo/codes/{cid}", json={"active": True, "owner_email": ""}, headers=ip_hdr(atok))),
    ):
        r = call()
        check(f"{label} without email rejected 4xx", 400 <= r.status_code < 500, f"{r.status_code} {r.text}")
        check(f"{label} left code inactive", row(cid)[0] is False)
    check("unactivated awaiting code not redeemable", not evaluable(text))

    # redemption fails closed even if active flag is flipped directly in the DB
    q("UPDATE promo_codes SET active=TRUE WHERE _id=%s", (cid,))
    check("active=true forced in DB but no email => still NOT redeemable (fail closed)", not evaluable(text))
    sdb = promo.PromoManager()
    try:
        check("find_code carries requires_owner_email", sdb.find_code(text)["requires_owner_email"] is True)
    finally:
        sdb.close()
    q("UPDATE promo_codes SET active=FALSE WHERE _id=%s", (cid,))

    # add email: saved, normalized, NOT auto-activated, flag cleared in derived view
    owner, _ = signup(client)
    oemail = q("SELECT email FROM users WHERE _id=%s", (owner,))[0][0]
    give_sub(owner)
    r = client.patch(f"/admin/promo/codes/{cid}", json={"owner_email": oemail.upper()}, headers=ip_hdr(atok))
    check("PATCH add valid email 200", r.status_code == 200, r.text)
    check("email saved lowercase, awaiting_email cleared, code STILL inactive",
          r.json()["owner_email"] == oemail.lower() and r.json()["awaiting_email"] is False
          and r.json()["active"] is False, r.text)
    check("DB: email set, not auto-activated", row(cid)[0] is False and row(cid)[1] == oemail.lower())
    check("with email but still inactive: not redeemable", not evaluable(text))
    ov = {x["id"]: x for x in client.get("/admin/promo/codes-overview", headers=ip_hdr(atok)).json()}
    check("overview no longer awaiting after email added", ov[cid]["awaiting_email"] is False)

    # activation now works (manual), and the code redeems
    r = client.post(f"/admin/promo/codes/{cid}/reactivate", headers=ip_hdr(atok))
    check("reactivate works after email added", r.status_code == 200 and r.json()["active"] is True, r.text)
    check("activated code with email is redeemable", evaluable(text))

    # removing the email deactivates the code and re-flags it
    r = client.patch(f"/admin/promo/codes/{cid}", json={"owner_email": None}, headers=ip_hdr(atok))
    check("PATCH owner_email null removes email", r.status_code == 200, r.text)
    check("removing email forces active=false + awaiting", row(cid) == (False, None, True), str(row(cid)))
    check("removed-email code not redeemable", not evaluable(text))
    r = client.post(f"/admin/promo/codes/{cid}/reactivate", headers=ip_hdr(atok))
    check("reactivate after email removal rejected", 400 <= r.status_code < 500 and row(cid)[0] is False, r.text)

    # removing the email on an ACTIVE code in one call that also says active=true cannot slip through
    r = client.patch(f"/admin/promo/codes/{cid}", json={"owner_email": oemail}, headers=ip_hdr(atok))
    client.post(f"/admin/promo/codes/{cid}/reactivate", headers=ip_hdr(atok))
    r = client.patch(f"/admin/promo/codes/{cid}", json={"owner_email": "", "active": True}, headers=ip_hdr(atok))
    check("remove email + active=true in one PATCH ends inactive", row(cid)[0] is False and row(cid)[1] is None,
          f"{r.status_code} {row(cid)}")

    # audit trail: actions recorded, no email in detail
    acts = q("SELECT action, detail FROM promo_audit_log WHERE code_id=%s", (cid,))
    names = {a[0] for a in acts}
    check("audit has promo_code_email_set and promo_code_email_removed",
          {"promo_code_email_set", "promo_code_email_removed"} <= names, str(names))
    check("audit detail contains no email", all("@" not in (a[1] or "") for a in acts))

    # legacy / existing behaviour unchanged
    legacy = client.post("/admin/promo/creator-codes", json={"name": "Legacy", "owner_email": oemail},
                         headers=ip_hdr(atok)).json()
    CREATORS.append(legacy["creator"]["id"])
    lc = legacy["code"]
    check("create WITH email still active, not flagged", lc["active"] is True and lc["awaiting_email"] is False
          and row(lc["id"]) == (True, oemail.lower(), False))
    check("code with email redeemable as before", evaluable(lc["code"]))
    # legacy NULL-email code (flag FALSE, pre-existing rows) is grandfathered: still redeemable
    q("UPDATE promo_codes SET owner_email=NULL WHERE _id=%s", (lc["id"],))
    check("legacy NULL-email code (flag FALSE) still redeemable (unchanged)", evaluable(lc["code"]))
    ov = {x["id"]: x for x in client.get("/admin/promo/codes-overview", headers=ip_hdr(atok)).json()}
    check("legacy NULL-email code is not 'awaiting'", ov[lc["id"]]["awaiting_email"] is False)

    # authz unchanged
    check("PATCH owner_email non-admin denied", client.patch(f"/admin/promo/codes/{cid}", json={"owner_email": oemail},
          headers=ip_hdr(utok)).status_code in (401, 403))
    check("create without email anon denied", client.post("/admin/promo/creator-codes", json={"name": "x"},
          headers=ip_hdr()).status_code in (401, 403))


def test_audit_no_pii(client):
    print("\n== Audit log / ledger hygiene ==")
    rows = q("SELECT action, detail FROM promo_audit_log ORDER BY ts DESC LIMIT 500")
    leaked = [r for r in rows if "@" in (r[1] or "") or "OWDUP" in (r[1] or "")]
    check("audit detail has no emails/code text", not leaked, str(leaked[:3]))
    cols = [r[0] for r in q("SELECT column_name FROM information_schema.columns WHERE table_name='owner_rewards'")]
    check("ledger stores hashes, not raw email/ip", "invitee_email_hash" in cols and "invitee_ip_hash" in cols
          and "invitee_email" not in cols and "invitee_ip" not in cols)
    h = q("SELECT invitee_email_hash FROM owner_rewards WHERE invitee_email_hash IS NOT NULL LIMIT 1")
    check("email hash is hex sha256", bool(h) and len(h[0][0]) == 64)
    # DB constraints back the app-level guarantees
    owner, _ = signup(client)
    give_sub(owner)
    i, _ = signup(client)
    q("INSERT INTO owner_rewards (owner_user_id, source, code, invitee_user_id, percent, idempotency_key, expires_at) "
      "VALUES (%s,'signup','X',%s,50,%s, NOW()+INTERVAL '1 day')", (owner, i, f"k:{uuid.uuid4()}"))
    try:
        q("INSERT INTO owner_rewards (owner_user_id, source, code, invitee_user_id, percent, idempotency_key, expires_at) "
          "VALUES (%s,'signup','X',%s,50,%s, NOW()+INTERVAL '1 day')", (owner, i, f"k:{uuid.uuid4()}"))
        dup = False
    except Exception:
        dup = True
    check("DB unique index: one signup reward per invitee", dup)
    try:
        q("UPDATE owner_rewards SET status='claimed' WHERE owner_user_id=%s", (owner,))
        bad = False
    except Exception:
        bad = True
    check("DB check: claimed requires claimed_at", bad)


def test_code_lifecycle(client, admin, user):
    print("\n== Admin code lifecycle: deactivate / reactivate / delete (task 20261003) ==")
    set_flags(True)
    aid, atok = admin
    uid, utok = user
    A, U = ip_hdr(atok), None
    owner, _ = signup(client)
    oemail = q("SELECT email FROM users WHERE _id=%s", (owner,))[0][0]
    give_sub(owner)
    cc = client.post("/admin/promo/creator-codes", json={"name": "Life", "owner_email": oemail},
                     headers=ip_hdr(atok)).json()
    CREATORS.append(cc["creator"]["id"])
    cid, text = cc["code"]["id"], cc["code"]["code"]

    def evaluable():
        buyer, _ = signup(client)
        db = RewardManager()
        try:
            return db.evaluate(buyer, text, 1, "b@example.com") is not None
        finally:
            db.close()

    def validate_http():
        b, bt = signup(client)
        r = client.post(f"/promo/{b}/validate", json={"code": text}, headers=ip_hdr(bt))
        return r.status_code, r.json()

    # authz
    for m in ("post", "delete"):
        path = f"/admin/promo/codes/{cid}" + ("/reactivate" if m == "post" else "")
        check(f"{m.upper()} lifecycle anon denied", getattr(client, m)(path, headers=ip_hdr()).status_code in (401, 403))
        check(f"{m.upper()} lifecycle non-admin denied", getattr(client, m)(path, headers=ip_hdr(utok)).status_code in (401, 403))
    check("denied attempts changed nothing",
          q("SELECT active, deleted_at FROM promo_codes WHERE _id=%s", (cid,))[0] == (True, None))
    check("fresh code evaluable", evaluable())

    # deactivate -> reactivate
    client.post(f"/admin/promo/codes/{cid}/deactivate", headers=ip_hdr(atok))
    check("deactivated: not evaluable", not evaluable())
    sc, js = validate_http()
    check("deactivated: validate uniform {valid:false}", sc == 200 and js == {"valid": False}, f"{sc} {js}")
    r = client.post(f"/admin/promo/codes/{cid}/reactivate", headers=ip_hdr(atok))
    check("reactivate 200 active true", r.status_code == 200 and r.json()["active"] is True, r.text)
    r = client.post(f"/admin/promo/codes/{cid}/reactivate", headers=ip_hdr(atok))
    check("reactivate idempotent", r.status_code == 200 and r.json()["active"] is True)
    check("reactivated: evaluable again", evaluable())
    sc, js = validate_http()
    check("reactivated: validate valid true", sc == 200 and js.get("valid") is True, f"{sc} {js}")
    check("reactivate unknown => 404", client.post(f"/admin/promo/codes/{uuid.uuid4()}/reactivate",
          headers=ip_hdr(atok)).status_code == 404)
    check("reactivate malformed => 404/422", client.post("/admin/promo/codes/not-a-uuid/reactivate",
          headers=ip_hdr(atok)).status_code in (400, 404, 422))

    # reactivate must not bypass expiry / cap
    q("UPDATE promo_codes SET expires_at = NOW() - INTERVAL '1 day' WHERE _id=%s", (cid,))
    client.post(f"/admin/promo/codes/{cid}/deactivate", headers=ip_hdr(atok))
    client.post(f"/admin/promo/codes/{cid}/reactivate", headers=ip_hdr(atok))
    check("reactivate does not bypass expires_at", not evaluable())
    q("UPDATE promo_codes SET expires_at = NULL WHERE _id=%s", (cid,))
    check("expiry cleared: evaluable", evaluable())

    # a redemption + earned reward exist before delete
    buyer, _ = signup(client)
    pdb = promo.PromoManager()
    try:
        res = pdb.log_redemption(code_id=cid, user_id=buyer, plan="individual", platform="stripe",
                                 store_transaction_id="sess_life", idempotency_key=f"life-{uuid.uuid4().hex}",
                                 amount_discount_cents=100)
    finally:
        pdb.close()
    check("redemption logged pre-delete", res == "logged", str(res))
    ow.credit_purchase_reward(cid, buyer, "sess_life")
    rewards_before = rewards_of(owner)
    check("owner reward earned pre-delete", len(rewards_before) == 1, str(rewards_before))

    # delete
    d = client.delete(f"/admin/promo/codes/{cid}", headers=ip_hdr(atok))
    check("delete 204 empty body", d.status_code == 204 and d.content == b"", f"{d.status_code}")
    d = client.delete(f"/admin/promo/codes/{cid}", headers=ip_hdr(atok))
    check("delete idempotent 204", d.status_code == 204)
    row = q("SELECT active, deleted_at, code FROM promo_codes WHERE _id=%s", (cid,))[0]
    check("soft delete: row kept, inactive, tombstoned, text reserved",
          row[0] is False and row[1] is not None and row[2] == text, str(row))
    check("deleted: not evaluable", not evaluable())
    sc, js = validate_http()
    check("deleted: validate uniform {valid:false}", sc == 200 and js == {"valid": False}, f"{sc} {js}")
    ov = client.get("/admin/promo/codes-overview", headers=ip_hdr(atok)).json()
    check("deleted: gone from overview", all(x["id"] != cid for x in ov))
    lst = client.get("/admin/promo/codes", headers=ip_hdr(atok))
    check("deleted: gone from list_codes", lst.status_code != 200 or all(x["id"] != cid for x in lst.json()))
    check("reactivate deleted => 404", client.post(f"/admin/promo/codes/{cid}/reactivate",
          headers=ip_hdr(atok)).status_code == 404)
    check("PATCH deleted => 404", client.patch(f"/admin/promo/codes/{cid}", json={"active": True},
          headers=ip_hdr(atok)).status_code == 404)
    check("still deleted after failed reactivate/patch",
          q("SELECT deleted_at IS NOT NULL, active FROM promo_codes WHERE _id=%s", (cid,))[0] == (True, False))
    check("delete unknown => 404", client.delete(f"/admin/promo/codes/{uuid.uuid4()}",
          headers=ip_hdr(atok)).status_code == 404)
    check("delete malformed => 404/422", client.delete("/admin/promo/codes/not-a-uuid",
          headers=ip_hdr(atok)).status_code in (400, 404, 422))
    check("code text stays reserved (recreate => 409)",
          client.post("/admin/promo/creator-codes", json={"name": "Re", "owner_email": "re@example.com", "code": text},
                      headers=ip_hdr(atok)).status_code == 409)
    for c in q("SELECT _id FROM creators WHERE name='Re'"):
        CREATORS.append(str(c[0]))

    # history preserved
    reds = q("SELECT code, code_id FROM promo_redemptions WHERE user_id=%s", (buyer,))
    check("redemption history kept with code text", reds == [(text, uuid.UUID(cid))] or
          (len(reds) == 1 and reds[0][0] == text and str(reds[0][1]) == cid), str(reds))
    ra = client.get("/admin/promo/redemptions", headers=ip_hdr(atok))
    check("redemptions list still shows deleted code row",
          ra.status_code == 200 and any(x.get("code") == text for x in ra.json()))
    check("earned owner reward intact and still earned", rewards_of(owner) == rewards_before and
          rewards_of(owner)[0][0] == "earned")
    pdb = promo.PromoManager()
    try:
        late = pdb.log_redemption(code_id=cid, user_id=owner, plan="individual", platform="stripe",
                                  store_transaction_id="sess_late", idempotency_key=f"late-{uuid.uuid4().hex}",
                                  amount_discount_cents=100)
        check("in-flight checkout after delete still logs (history not lost)", late == "logged", str(late))
        check("get_code_by_id still resolves deleted code", pdb.get_code_by_id(cid) is not None)
        check("find_code hides deleted", pdb.find_code(text) is None and pdb.find_code(text, include_deleted=True))
    finally:
        pdb.close()

    # friend codes: not deletable, can be deactivated/reactivated, never regenerated
    fo, _ = signup(client)
    ftext = friend_code(fo)
    fid = str(q("SELECT _id FROM promo_codes WHERE code=%s", (ftext,))[0][0])
    r = client.delete(f"/admin/promo/codes/{fid}", headers=ip_hdr(atok))
    check("friend code delete => 422, untouched", r.status_code == 422 and
          q("SELECT deleted_at FROM promo_codes WHERE _id=%s", (fid,))[0][0] is None, f"{r.status_code}")
    check("friend code deactivate ok", client.post(f"/admin/promo/codes/{fid}/deactivate",
          headers=ip_hdr(atok)).json()["active"] is False)
    check("friend code reactivate ok", client.post(f"/admin/promo/codes/{fid}/reactivate",
          headers=ip_hdr(atok)).json()["active"] is True)
    check("friend code stable (no regeneration)", friend_code(fo) == ftext)

    acts = [r[0] for r in q("SELECT action FROM promo_audit_log WHERE code_id=%s", (cid,))]
    check("reactivate + delete audited", "promo_code_reactivate" in acts and "promo_code_delete" in acts, str(acts))
    dets = q("SELECT * FROM promo_audit_log WHERE code_id=%s", (cid,))
    check("audit rows carry no code text", all(text not in str(r) for r in dets))


def cleanup():
    ids = tuple(USERS) or (None,)
    for table_sql in (
        "DELETE FROM owner_rewards WHERE owner_user_id = ANY(%s::uuid[]) OR invitee_user_id = ANY(%s::uuid[])",
    ):
        q(table_sql, (list(USERS), list(USERS)))
    q("DELETE FROM promo_audit_log WHERE owner_user_id = ANY(%s::uuid[]) OR actor_user_id = ANY(%s::uuid[])",
      (list(USERS), list(USERS)))
    for cid in CREATORS:
        q("DELETE FROM promo_audit_log WHERE code_id IN (SELECT _id FROM promo_codes WHERE creator_id=%s)", (cid,))
        q("DELETE FROM promo_redemptions WHERE creator_id = %s", (cid,))
        q("DELETE FROM promo_codes WHERE creator_id = %s", (cid,))
        q("DELETE FROM creators WHERE _id = %s", (cid,))
    for uid in USERS:
        q("DELETE FROM promo_redemptions WHERE user_id = %s OR referrer_user_id = %s", (uid, uid))
        q("DELETE FROM promo_audit_log WHERE code_id IN (SELECT _id FROM promo_codes WHERE referrer_user_id=%s)", (uid,))
        q("DELETE FROM promo_codes WHERE referrer_user_id = %s", (uid,))
        q("UPDATE users SET subscription_id = NULL WHERE _id = %s", (uid,))
        q("DELETE FROM subscriber_history WHERE user_id = %s", (uid,))
        q("DELETE FROM subscriptions WHERE user_id = %s", (uid,))
        q("DELETE FROM users WHERE _id = %s", (uid,))
    try:
        os.unlink(_KEY_FILE.name)
    except OSError:
        pass


def _friend_cid(code):
    db = RewardManager()
    try:
        return db.find_code(code)["id"]
    finally:
        db.close()


def test_friend_purchase(client):
    print("\n== Friend-code Stripe purchase credits the inviter ==")
    set_flags(True)
    # 1. Apple inviter, web invitee redeems at checkout (no signup code) => one reward
    owner, _ = signup(client)
    give_sub(owner, "apple", otxn="otx_fp_1")
    code = friend_code(owner)
    cid = _friend_cid(code)
    buyer, _ = signup(client)
    sess, ev = _webhook_event(buyer, cid)
    with WebhookStubs(ev):
        r = _post_webhook(client)
        check("friend-code checkout webhook 200", r.status_code == 200, r.text)
        rs = rewards_of(owner)
        check("friend-code purchase credits inviter once with signup:<invitee> key",
              len(rs) == 1 and rs[0][0] == "earned" and rs[0][1] == "signup" and rs[0][4] == f"signup:{buyer}", str(rs))
        for _ in range(2):
            _post_webhook(client)
        check("webhook replays idempotent", len(rewards_of(owner)) == 1)
    summ = q("SELECT COUNT(*) FROM subscriptions WHERE user_id=%s", (buyer,))[0][0]
    check("invitee plan still recorded", summ == 1)

    # 2. signup WITH code, then redeem => one reward total
    owner2, _ = signup(client)
    give_sub(owner2, "stripe")
    code2 = friend_code(owner2)
    cid2 = _friend_cid(code2)
    inv, _ = signup(client, invite=code2)
    check("signup credited once", len(rewards_of(owner2)) == 1)
    sess2, ev2 = _webhook_event(inv, cid2)
    with WebhookStubs(ev2):
        r = _post_webhook(client)
        check("redeem after signup => 200", r.status_code == 200, r.text)
    check("signup + redeem credits inviter once total", len(rewards_of(owner2)) == 1, str(rewards_of(owner2)))

    # 3. redeem first, then signup-earn path for same invitee => still one
    outcome = earn_signup(code, buyer, "x@example.com")[0]
    check("signup earn after redeem => duplicate", outcome == "duplicate" and len(rewards_of(owner)) == 1, outcome)

    # 4. self-referral
    sess3, ev3 = _webhook_event(owner2, cid2)
    before = len(rewards_of(owner2))
    ow.credit_purchase_reward(cid2, owner2, sess3)
    check("self-referral denied", len(rewards_of(owner2)) == before
          and "reward_denied_self_referral" in audit_actions(owner2))

    # 5. inviter without a paid plan => nothing
    owner3, _ = signup(client)
    cid3 = _friend_cid(friend_code(owner3))
    b3, _ = signup(client)
    _s, ev = _webhook_event(b3, cid3)
    with WebhookStubs(ev):
        r = _post_webhook(client)
    check("inviter w/o paid plan: webhook 200, no reward", r.status_code == 200 and rewards_of(owner3) == [])
    check("no-subscription skip audited", "reward_skipped_no_subscription" in audit_actions(owner3))

    # 6. cap reached
    owner4, _ = signup(client)
    give_sub(owner4, "stripe")
    cid4 = _friend_cid(friend_code(owner4))
    cap = ow.rewards_config().cap_count
    for _ in range(cap):
        b, _ = signup(client)
        ow.credit_purchase_reward(cid4, b, f"cs_{uuid.uuid4().hex[:8]}")
    b, _ = signup(client)
    ow.credit_purchase_reward(cid4, b, f"cs_{uuid.uuid4().hex[:8]}")
    n = len(rewards_of(owner4))
    check("cap enforced for friend purchase credits", n <= cap, str(n))

    # 7. flag off => nothing
    owner5, _ = signup(client)
    give_sub(owner5, "stripe")
    cid5 = _friend_cid(friend_code(owner5))
    b5, _ = signup(client)
    set_flags(False)
    ow.credit_purchase_reward(cid5, b5, "cs_flagoff")
    set_flags(True)
    check("flag off: no friend purchase credit", rewards_of(owner5) == [])

    # 8. inactive code => nothing
    q("UPDATE promo_codes SET active=FALSE WHERE _id=%s", (cid5,))
    ow.credit_purchase_reward(cid5, b5, "cs_inactive")
    check("inactive friend code earns nothing", rewards_of(owner5) == [])

    # 9. no credit without a verified completed event: bad signature => 400, nothing
    owner6, _ = signup(client)
    give_sub(owner6, "stripe")
    cid6 = _friend_cid(friend_code(owner6))
    b6, _ = signup(client)
    o = (stripe_service.is_configured, stripe_service.construct_event)
    stripe_service.is_configured = lambda: True

    def bad(payload, sig):
        raise ValueError("bad sig")
    stripe_service.construct_event = bad
    try:
        r = _post_webhook(client)
    finally:
        stripe_service.is_configured, stripe_service.construct_event = o
    check("unverified event => rejected, no reward", r.status_code == 400 and rewards_of(owner6) == [], str(r.status_code))

    # 10. unpaid session => no redemption, no reward
    _s, ev = _webhook_event(b6, cid6)
    ev["data"]["object"]["payment_status"] = "unpaid"
    with WebhookStubs(ev):
        _post_webhook(client)
    check("unpaid session => no reward", rewards_of(owner6) == [])

    # 11. concurrent deliveries => exactly one
    owner7, _ = signup(client)
    give_sub(owner7, "apple", otxn="otx_fp_7")
    cid7 = _friend_cid(friend_code(owner7))
    b7, _ = signup(client)
    _s, ev = _webhook_event(b7, cid7)
    with WebhookStubs(ev):
        ts = [threading.Thread(target=lambda: _post_webhook(client)) for _ in range(6)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        _post_webhook(client)
    check("concurrent friend-purchase deliveries => one reward", len(rewards_of(owner7)) == 1, str(rewards_of(owner7)))


def main():
    stripe_service.is_configured = lambda: False   # never reach the real Stripe API from tests
    test_config()
    test_helpers()
    try:
        with TestClient(main_module.app) as client:
            admin = signup(client, admin=True)
            ADMIN_TOK[0] = admin[1]
            user = signup(client)
            test_flag_off(client, admin, user)
            test_signup_earn(client)
            test_concurrent_earn(client)
            test_purchase_earn(client)
            test_purchase_retry(client)
            test_friend_purchase(client)
            test_stripe_apply(client)
            test_apple(client)
            test_admin(client, admin, user)
            test_code_lifecycle(client, admin, user)
            test_awaiting_email(client, admin, user)
            test_audit_no_pii(client)
            set_flags(False)
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
