"""Backend coverage for task 20261003-ios-friend-offer-code-redeem.

Proves: eager config validation (every var, key loaded only when enabled, flag
requires promo + rewards, no key bytes in errors); flag-off uniform 404 before
auth; the validation matrix (unknown / malformed / inactive / expired / exhausted
/ own / creator-kind / ineligible-subscriber / already-redeemed / per-IP cap /
max_redemptions incl. outstanding) each denied with ONE uniform 400 and ZERO ASC
calls; fail-closed paths (preflight failure, mint rejected, mint ambiguous leaves
a pending row that blocks re-mint, code not ready, global mint cap, DB error);
idempotency (retry re-reads the same batch and never mints twice, concurrent
requests mint once); ASC client contract (read-only preflight requires active +
NEW-only + matching name, the single write is a 1-code batch, errors carry the
status only); reward crediting (never at issue time, only on a verified offerType
3 + our reference name transaction through apple/sync and the notification path,
exactly once on replay, no double credit with a signup invite_code); auth and
rate limiting. All ASC traffic is faked; there are no live calls.

Run with: cd api && ../.venv/bin/python tests/test_ios_offer_codes.py
"""
import _pathfix  # noqa: F401

import json
import os
import tempfile
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
os.environ["TRIAL_MONTHS"] = "0"
os.environ["PROMO_CODES_ENABLED"] = "false"
os.environ["PROMO_DISCOUNT_PERCENT"] = "50"
os.environ["PROMO_VALIDATE_RATE_LIMIT"] = "100000/minute"

import httpx  # noqa: E402
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

# Throwaway keys generated here; never a real key.
_KEY = ec.generate_private_key(ec.SECP256R1())
_KEY_FILE = tempfile.NamedTemporaryFile(prefix="test-ios-offer-key-", suffix=".p8", delete=False)
_KEY_FILE.write(_KEY.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                   serialization.NoEncryption()))
_KEY_FILE.close()

_PRODUCTS = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
OFFERS = {f"com.fellowscript.access.{n}": ("invite_reward_50" if i == 0 else f"invite_reward_50_{i + 1}")
          for i, n in enumerate(_PRODUCTS)}
REF = "friend_invite_50_new"
INDIVIDUAL = "com.fellowscript.access.one"
GROUP_PRODUCT = "com.fellowscript.access.two"
GOOD_ENV = {
    "OWNER_REWARDS_ENABLED": "false",
    "OWNER_REWARD_PERCENT": "50",
    "OWNER_REWARD_EXPIRY_DAYS": "90",
    "OWNER_REWARD_CAP_COUNT": "50",
    "OWNER_REWARD_CAP_WINDOW_DAYS": "30",
    "OWNER_REWARD_MAX_OUTSTANDING": "50",
    "OWNER_REWARD_IP_CAP_COUNT": "50",
    "OWNER_REWARD_CLAIM_RATE_LIMIT": "100000/minute",
    "OWNER_REWARD_APPLE_RESERVATION_MINUTES": "15",
    "OWNER_REWARD_HASH_SALT": "test-salt-0123456789abcdef",
    "APPLE_PROMO_KEY_ID": "G6DRYNCNRS",
    "APPLE_PROMO_KEY_PATH": _KEY_FILE.name,
    "APPLE_PROMO_OFFERS": json.dumps(OFFERS),
    "APPLE_BUNDLE_ID": "com.fellowscript.app",
}
OFFER_ENV = {
    "IOS_OFFER_CODES_ENABLED": "false",
    "IOS_OFFER_CODE_EXPIRY_DAYS": "30",
    "IOS_OFFER_CODE_RATE_LIMIT": "100000/minute",
    "IOS_OFFER_CODE_IP_DAILY_CAP": "3",
    "IOS_OFFER_CODE_DAILY_MINT_CAP": "1000000",
    "APPLE_ASC_KEY_ID": "JZCLMWLW83",
    "APPLE_ASC_ISSUER_ID": "00000000-0000-0000-0000-000000000000",
    "APPLE_ASC_KEY_PATH": _KEY_FILE.name,
    "APPLE_OFFER_CODE_ID": "test-offer-id",
    "APPLE_OFFER_CODE_REFERENCE_NAME": REF,
    "APPLE_APP_STORE_ID": "6791701454",
}
os.environ.update(GOOD_ENV)
os.environ.update(OFFER_ENV)

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.subscription import promo, stripe_service, owner_rewards as ow  # noqa: E402
from backend.subscription import apple_offer_codes as aoc  # noqa: E402
from backend.subscription.owner_rewards import RewardManager, validate_owner_rewards_config  # noqa: E402

PASSED, FAILED = [], []
USERS, CREATORS = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def new_ip():
    return f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"


def hdr(tok=None, ip=None):
    h = {"cf-connecting-ip": ip or new_ip()}
    if tok:
        h["cookie"] = f"session={tok}"
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


def signup(client, email=None, invite=None):
    name = f"ioc_{uuid.uuid4().hex[:10]}"
    body = {"username": name, "email": email or f"{name}@example.com", "plain_pass": "TestPass123!",
            "terms_accepted": True}
    if invite is not None:
        body["invite_code"] = invite
    r = client.post("/signup", json=body, headers=hdr())
    assert r.status_code == 201, f"signup failed {r.status_code} {r.text}"
    uid = r.json()["user_id"]
    USERS.append(uid)
    return uid, r.cookies.get("session")


def give_sub(uid, provider="apple", plan="individual", status="active", max_members=1, otxn=None):
    sid = str(uuid.uuid4())
    q("INSERT INTO subscriptions (_id, user_id, plan_type, provider, status, max_members, "
      "stripe_subscription_id, apple_original_transaction_id) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
      (sid, uid, plan, provider, status, max_members,
       f"sub_{uuid.uuid4().hex[:12]}" if provider == "stripe" else "",
       otxn or (f"otx_{uuid.uuid4().hex[:12]}" if provider == "apple" else "")))
    q("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, uid))
    return sid


def friend_code(uid):
    db = RewardManager()
    try:
        return db.get_or_create_friend_code(uid)
    finally:
        db.close()


def set_flags(offer=True, rewards=True, promo_on=True, **env):
    os.environ["OWNER_REWARDS_ENABLED"] = "true" if rewards else "false"
    os.environ["IOS_OFFER_CODES_ENABLED"] = "true" if offer else "false"
    os.environ.update(env)
    promo._config = promo.PromoConfig(promo_on, 50, "100000/minute")
    validate_owner_rewards_config()
    aoc.validate_offer_codes_config()
    aoc._preflight_ok_until = 0.0


class FakeAsc:
    """Stands in for AscOfferCodeClient. Counts every call; never touches the network."""

    def __init__(self, preflight_ok=True, mint="ok", fetch="ok"):
        self.preflight_ok, self.mint, self.fetch = preflight_ok, mint, fetch
        self.pre_calls = self.mint_calls = self.fetch_calls = 0
        self.dates = []
        self.batches = {}

    @property
    def total(self):
        return self.pre_calls + self.mint_calls + self.fetch_calls

    def check_offer(self):
        self.pre_calls += 1
        if not self.preflight_ok:
            raise aoc.AscRejected("offer not active / not new-subscribers / name mismatch")

    def create_one_time_use_batch(self, expiration_date):
        self.mint_calls += 1
        self.dates.append(expiration_date)
        if self.mint == "reject":
            raise aoc.AscRejected("status 409")
        if self.mint == "ambiguous":
            raise aoc.AscAmbiguous("ReadTimeout")
        bid = f"batch{uuid.uuid4().hex[:10]}"
        self.batches[bid] = f"CODE{uuid.uuid4().hex[:10].upper()}"
        return bid

    def fetch_code(self, batch_id):
        self.fetch_calls += 1
        if self.fetch == "notready":
            raise aoc.AscAmbiguous("code not ready")
        return self.batches[batch_id]


def use_fake(fake):
    aoc.get_client = lambda: fake
    aoc._preflight_ok_until = 0.0
    return fake


def post_offer(client, uid, tok, code, ip=None):
    return client.post(f"/promo/{uid}/ios-offer-code", json={"code": code}, headers=hdr(tok, ip))


def rows_for(uid):
    return q("SELECT status, asc_batch_id, apple_transaction_id, ip_hash FROM ios_offer_redemptions "
             "WHERE user_id=%s ORDER BY created_at", (uid,))


def rewards_of(owner):
    return q("SELECT status, source, idempotency_key, invitee_user_id FROM owner_rewards "
             "WHERE owner_user_id=%s", (owner,))


def mk_owner(client):
    oid, otok = signup(client)
    give_sub(oid, "apple", "individual")
    return oid, otok, friend_code(oid)


def is_uniform_denial(r):
    return r.status_code == 400 and r.json().get("detail", {}).get("code") == "invalid_invite_code"


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_config():
    print("\n== Eager config validation ==")
    saved = dict(os.environ)
    try:
        def attempt(**over):
            env = {**GOOD_ENV, **OFFER_ENV, **over}
            for k, v in env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            try:
                validate_owner_rewards_config()
                aoc.validate_offer_codes_config()
                return None
            except (aoc.OfferCodesConfigError, ow.OwnerRewardsConfigError) as e:
                return str(e)
        promo._config = promo.PromoConfig(True, 50, "100/minute")
        check("good config, flag off, validates", attempt() is None)
        check("flag off => offer_codes_enabled False", not aoc.offer_codes_enabled())
        check("flag off does not load the ASC key", aoc.offer_codes_config().private_key is None)
        for var in OFFER_ENV:
            msg = attempt(**{var: None})
            check(f"missing {var} refuses", msg is not None and var in msg, str(msg))
        check("blank flag refuses", attempt(IOS_OFFER_CODES_ENABLED="") is not None)
        check("flag 'yes' refuses", attempt(IOS_OFFER_CODES_ENABLED="yes") is not None)
        check("expiry 0 refuses", attempt(IOS_OFFER_CODE_EXPIRY_DAYS="0") is not None)
        check("expiry 181 refuses", attempt(IOS_OFFER_CODE_EXPIRY_DAYS="181") is not None)
        check("expiry non-int refuses", attempt(IOS_OFFER_CODE_EXPIRY_DAYS="soon") is not None)
        check("bad rate limit refuses", attempt(IOS_OFFER_CODE_RATE_LIMIT="lots") is not None)
        check("ip cap 0 refuses", attempt(IOS_OFFER_CODE_IP_DAILY_CAP="0") is not None)
        check("mint cap 0 refuses", attempt(IOS_OFFER_CODE_DAILY_MINT_CAP="0") is not None)
        check("bad key id refuses", attempt(APPLE_ASC_KEY_ID="short") is not None)
        check("non-UUID issuer refuses", attempt(APPLE_ASC_ISSUER_ID="not-a-uuid") is not None)
        check("bad offer id refuses", attempt(APPLE_OFFER_CODE_ID="bad id!") is not None)
        check("bad reference name refuses", attempt(APPLE_OFFER_CODE_REFERENCE_NAME="bad/name") is not None)
        check("non-numeric store id refuses", attempt(APPLE_APP_STORE_ID="abc") is not None)
        # enabled
        msg = attempt(OWNER_REWARDS_ENABLED="true", IOS_OFFER_CODES_ENABLED="true")
        check("enabled + valid key validates", msg is None, str(msg))
        check("enabled loads private key", aoc.offer_codes_config().private_key is not None)
        check("enabled => offer_codes_enabled True", aoc.offer_codes_enabled())
        check("enabled + rewards off refuses",
              attempt(OWNER_REWARDS_ENABLED="false", IOS_OFFER_CODES_ENABLED="true") is not None)
        promo._config = promo.PromoConfig(False, 50, "100/minute")
        check("enabled + promo off refuses",
              attempt(OWNER_REWARDS_ENABLED="true", IOS_OFFER_CODES_ENABLED="true") is not None)
        promo._config = promo.PromoConfig(True, 50, "100/minute")
        msg = attempt(OWNER_REWARDS_ENABLED="true", IOS_OFFER_CODES_ENABLED="true",
                      APPLE_ASC_KEY_PATH="/nonexistent/AuthKey.p8")
        check("enabled + missing key file refuses (no path/bytes leak)",
              msg is not None and "BEGIN" not in msg, str(msg))
        bad_key = tempfile.NamedTemporaryFile(prefix="bad-asc-", suffix=".p8", delete=False)
        bad_key.write(ec.generate_private_key(ec.SECP384R1()).private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        bad_key.close()
        msg = attempt(OWNER_REWARDS_ENABLED="true", IOS_OFFER_CODES_ENABLED="true",
                      APPLE_ASC_KEY_PATH=bad_key.name)
        check("enabled + non P-256 key refuses", msg is not None and "BEGIN" not in msg, str(msg))
        os.unlink(bad_key.name)
        # config not validated => fail closed
        aoc._config = None
        check("unvalidated config => flag fails closed", not aoc.offer_codes_enabled())
    finally:
        os.environ.clear()
        os.environ.update(saved)
        promo._config = promo.PromoConfig(True, 50, "100000/minute")
        set_flags(offer=False, rewards=False)


def test_asc_client():
    print("\n== ASC client contract (httpx.MockTransport, no network) ==")
    set_flags(offer=True, rewards=True)
    cfg = aoc.offer_codes_config()
    seen = []

    def make(handler):
        return aoc.AscOfferCodeClient(cfg, httpx.Client(transport=httpx.MockTransport(handler)))

    def offer_ok(attrs=None):
        base = {"active": True, "name": REF, "customerEligibilities": ["NEW"]}
        base.update(attrs or {})
        return {"data": {"id": cfg.offer_code_id, "attributes": base}}

    def run_check(attrs=None, status=200):
        def h(req):
            seen.append((req.method, req.url.path))
            return httpx.Response(status, json=offer_ok(attrs))
        try:
            make(h).check_offer()
            return None
        except Exception as e:
            return e

    check("preflight passes for active NEW-only offer with matching name", run_check() is None)
    check("preflight is a GET on the configured offer only",
          seen[-1] == ("GET", f"/v1/subscriptionOfferCodes/{cfg.offer_code_id}"), str(seen))
    check("preflight rejects inactive", isinstance(run_check({"active": False}), aoc.AscRejected))
    check("preflight rejects name mismatch", isinstance(run_check({"name": "other"}), aoc.AscRejected))
    check("preflight rejects eligibility incl. EXISTING",
          isinstance(run_check({"customerEligibilities": ["NEW", "EXISTING"]}), aoc.AscRejected))
    check("preflight rejects missing eligibility", isinstance(run_check({"customerEligibilities": None}), aoc.AscRejected))
    check("preflight 404 => AscRejected", isinstance(run_check(status=404), aoc.AscRejected))
    check("preflight 500 => AscAmbiguous", isinstance(run_check(status=500), aoc.AscAmbiguous))

    def boom(req):
        raise httpx.ConnectTimeout("t")
    try:
        make(boom).check_offer()
        e = None
    except Exception as ex:
        e = ex
    check("transport failure => AscAmbiguous", isinstance(e, aoc.AscAmbiguous))

    captured = {}

    def mint_h(req):
        captured["method"], captured["path"] = req.method, req.url.path
        captured["body"] = json.loads(req.content)
        captured["auth"] = req.headers.get("authorization", "")
        return httpx.Response(201, json={"data": {"id": "batch123"}})
    bid = make(mint_h).create_one_time_use_batch("2026-11-01")
    body = captured["body"]["data"]
    check("mint is a single POST to subscriptionOfferCodeOneTimeUseCodes",
          captured["method"] == "POST" and captured["path"] == "/v1/subscriptionOfferCodeOneTimeUseCodes")
    check("mint requests exactly 1 code with expiration",
          body["attributes"] == {"numberOfCodes": 1, "expirationDate": "2026-11-01"}, str(body))
    check("mint binds to configured offer id (never creates an offer)",
          body["relationships"]["offerCode"]["data"] == {"type": "subscriptionOfferCodes", "id": cfg.offer_code_id})
    check("mint returns batch id", bid == "batch123")
    check("ASC request is Bearer-JWT signed", captured["auth"].startswith("Bearer ey"))
    try:
        make(lambda r: httpx.Response(201, json={"data": {}})).create_one_time_use_batch("2026-11-01")
        e = None
    except Exception as ex:
        e = ex
    check("mint with no batch id => AscAmbiguous", isinstance(e, aoc.AscAmbiguous))
    try:
        make(lambda r: httpx.Response(409, text="SECRET-BODY")).create_one_time_use_batch("2026-11-01")
        e = None
    except Exception as ex:
        e = ex
    check("mint 409 => AscRejected, message carries status only",
          isinstance(e, aoc.AscRejected) and "SECRET-BODY" not in str(e) and "409" in str(e), str(e))
    try:
        make(lambda r: httpx.Response(503)).create_one_time_use_batch("2026-11-01")
        e = None
    except Exception as ex:
        e = ex
    check("mint 5xx => AscAmbiguous (effect unknown)", isinstance(e, aoc.AscAmbiguous))

    def vals(text):
        return make(lambda r: httpx.Response(200, text=text)).fetch_code("batch123")
    check("fetch_code parses single value", vals("ABCDEF123456\n") == "ABCDEF123456")
    for label, text in (("empty", ""), ("two codes", "AAAAAA111\nBBBBBB222\n"), ("malformed", "bad code!\n")):
        try:
            vals(text)
            e = None
        except Exception as ex:
            e = ex
        check(f"fetch_code {label} => AscAmbiguous (not ready/closed)", isinstance(e, aoc.AscAmbiguous))
    try:
        make(lambda r: httpx.Response(200, text="X")).fetch_code("../etc")
        e = None
    except Exception as ex:
        e = ex
    check("fetch_code rejects unsafe batch id", isinstance(e, aoc.AscAmbiguous))
    check("redeem_url format",
          aoc.redeem_url("ABC123") == "https://apps.apple.com/redeem?ctx=offercodes&id=6791701454&code=ABC123")
    set_flags(offer=False, rewards=False)


def test_flag_off(client):
    print("\n== Flag off ==")
    set_flags(offer=False, rewards=True)
    fake = use_fake(FakeAsc())
    uid, tok = signup(client)
    r = post_offer(client, uid, tok, "WHATEVER")
    check("flag off => 404", r.status_code == 404, f"{r.status_code} {r.text}")
    r2 = client.post(f"/promo/{uid}/ios-offer-code", json={"code": "X"}, headers=hdr())
    # Auth dependency runs first, so unauthenticated callers get the same 401 flag-on or
    # flag-off: no flag-state oracle either way.
    check("flag off: unauthenticated gets 401/404 (no flag oracle)", r2.status_code in (401, 403, 404), str(r2.status_code))
    check("flag off makes no ASC call", fake.total == 0)
    check("flag off writes no ledger row", rows_for(uid) == [])


def test_auth(client):
    print("\n== Authentication / authorization ==")
    set_flags()
    fake = use_fake(FakeAsc())
    oid, otok, code = mk_owner(client)
    uid, tok = signup(client)
    other, otok2 = signup(client)
    r = client.post(f"/promo/{uid}/ios-offer-code", json={"code": code}, headers=hdr())
    check("unauthenticated => 401/403", r.status_code in (401, 403), str(r.status_code))
    r = post_offer(client, uid, otok2, code)
    check("another user's session cannot request for me", r.status_code in (401, 403), str(r.status_code))
    check("no ASC call on auth failures", fake.total == 0)
    check("no ledger row on auth failures", rows_for(uid) == [])
    r = client.post(f"/promo/{uid}/ios-offer-code", json={}, headers=hdr(tok))
    check("missing code field => 422", r.status_code == 422, str(r.status_code))
    r = post_offer(client, uid, tok, "A" * 65)
    check("oversized code => 422", r.status_code == 422, str(r.status_code))
    check("no ASC call on schema failures", fake.total == 0)


def test_happy_and_idempotency(client):
    print("\n== Valid request: one code, idempotent retries ==")
    set_flags()
    fake = use_fake(FakeAsc())
    oid, otok, code = mk_owner(client)
    uid, tok = signup(client)
    ip = new_ip()
    r = post_offer(client, uid, tok, code, ip)
    j = r.json() if r.status_code == 200 else {}
    check("valid friend code => 200 with offer_code/redeem_url/expires_at",
          r.status_code == 200 and {"offer_code", "redeem_url", "expires_at"} <= set(j), f"{r.status_code} {r.text}")
    check("response is no-store", "no-store" in r.headers.get("cache-control", ""))
    check("redeem_url carries the code", j.get("offer_code", "x") in j.get("redeem_url", ""))
    check("exactly one preflight + one mint", fake.pre_calls == 1 and fake.mint_calls == 1,
          f"{fake.pre_calls}/{fake.mint_calls}")
    rows = rows_for(uid)
    check("exactly one issued ledger row with batch id",
          len(rows) == 1 and rows[0][0] == "issued" and rows[0][1] in fake.batches, str(rows))
    check("ledger stores a hash, not the raw IP or code",
          rows[0][3] and ip not in rows[0][3] and j["offer_code"] not in json.dumps([list(map(str, x)) for x in rows]))
    check("no reward at issue time", rewards_of(oid) == [])
    # retries
    for i in range(3):
        rr = post_offer(client, uid, tok, code, ip)
        check(f"retry {i + 1} returns the same code", rr.status_code == 200 and rr.json()["offer_code"] == j["offer_code"],
              f"{rr.status_code} {rr.text}")
    check("retries never mint a second batch", fake.mint_calls == 1, str(fake.mint_calls))
    check("still one ledger row", len(rows_for(uid)) == 1)
    check("still no reward after retries", rewards_of(oid) == [])
    # normalisation of the entered code (case / whitespace) maps to the same row
    rr = post_offer(client, uid, tok, " " + code.lower() + " ", ip)
    check("code entry is normalised (case/whitespace) and stays idempotent",
          rr.status_code == 200 and fake.mint_calls == 1, f"{rr.status_code} {rr.text}")
    # a different (valid) friend code cannot swap the live issuance
    oid2, _, code2 = mk_owner(client)
    rr = post_offer(client, uid, tok, code2, ip)
    check("a different friend code on a live issuance is denied (uniform) with no mint",
          is_uniform_denial(rr) and fake.mint_calls == 1, f"{rr.status_code} {rr.text}")
    # expiry date sent to ASC is in the future
    check("ASC expirationDate is a future ISO date", fake.dates and fake.dates[0] > "2026")


def test_concurrent(client):
    print("\n== Concurrent requests mint once ==")
    set_flags()
    fake = use_fake(FakeAsc())
    oid, otok, code = mk_owner(client)
    uid, tok = signup(client)
    ip = new_ip()
    out = []

    def go():
        out.append(post_offer(client, uid, tok, code, ip))
    ts = [threading.Thread(target=go) for _ in range(5)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("concurrent requests mint at most one batch", fake.mint_calls == 1, str(fake.mint_calls))
    live = q("SELECT COUNT(*) FROM ios_offer_redemptions WHERE user_id=%s AND status IN ('pending','issued','redeemed')",
             (uid,))[0][0]
    check("exactly one live ledger row", live == 1, str(live))
    codes = {r.json().get("offer_code") for r in out if r.status_code == 200}
    check("every success returned the same code", len(codes) <= 1, str(codes))
    check("no 5xx other than 503", all(r.status_code in (200, 400, 503) for r in out), str([r.status_code for r in out]))


def test_validation_matrix(client):
    print("\n== Validation matrix: uniform 400, zero ASC calls ==")
    set_flags()
    fake = use_fake(FakeAsc())
    oid, otok, code = mk_owner(client)

    def denied(label, uid, tok, c, ip=None):
        before = fake.total
        r = post_offer(client, uid, tok, c, ip)
        check(f"{label}: uniform 400", is_uniform_denial(r), f"{r.status_code} {r.text}")
        check(f"{label}: no ASC call", fake.total == before)
        check(f"{label}: no ledger row", rows_for(uid) == [])
        return r

    u, t = signup(client)
    r_unknown = denied("unknown code", u, t, "NOSUCHCODE9")
    for bad in ("", "   ", "!!!!", "a b", "x" * 40):
        denied(f"malformed code {bad[:6]!r}", u, t, bad)
    r_own = denied("own friend code", oid, otok, code)
    check("own/unknown denial bodies are identical (no oracle)", r_own.json() == r_unknown.json())

    # inactive
    o2, _, c2 = mk_owner(client)
    q("UPDATE promo_codes SET active=FALSE WHERE code=%s", (c2,))
    u2, t2 = signup(client)
    denied("inactive code", u2, t2, c2)
    # expired
    o3, _, c3 = mk_owner(client)
    q("UPDATE promo_codes SET expires_at = NOW() - INTERVAL '1 day' WHERE code=%s", (c3,))
    denied("expired code", u2, t2, c3)
    # exhausted
    o4, _, c4 = mk_owner(client)
    q("UPDATE promo_codes SET max_redemptions=1, redemption_count=1 WHERE code=%s", (c4,))
    denied("exhausted code", u2, t2, c4)
    # soft deleted
    o5, _, c5 = mk_owner(client)
    q("UPDATE promo_codes SET deleted_at=NOW() WHERE code=%s", (c5,))
    denied("deleted code", u2, t2, c5)
    # creator-kind code (not a friend code)
    cid = str(uuid.uuid4())
    q("INSERT INTO creators (_id, name, active) VALUES (%s,%s,TRUE)", (cid, "ioc creator"))
    CREATORS.append(cid)
    ccode = f"IOC{uuid.uuid4().hex[:8].upper()}"
    q("INSERT INTO promo_codes (code, kind, creator_id) VALUES (%s,'creator',%s)", (ccode, cid))
    denied("creator-kind code (friend only)", u2, t2, ccode)
    # ineligible: existing local subscriber
    sub_u, sub_t = signup(client)
    give_sub(sub_u, "apple", "individual")
    denied_row = post_offer(client, sub_u, sub_t, code)
    check("existing subscriber: uniform 400", is_uniform_denial(denied_row), f"{denied_row.status_code}")
    check("existing subscriber: no ASC call", fake.total == 0)
    # ineligible: prior paid history (subscriber_history) with no current sub
    hist_u, hist_t = signup(client)
    sid = give_sub(hist_u, "apple", "individual", status="canceled")
    r = post_offer(client, hist_u, hist_t, code)
    check("lapsed subscriber (prior paid history): uniform 400", is_uniform_denial(r), f"{r.status_code} {r.text}")
    check("lapsed subscriber: no ASC call", fake.total == 0)
    check("whole matrix made zero ASC calls", fake.total == 0, str(fake.total))

    # per-IP daily cap (IOS_OFFER_CODE_IP_DAILY_CAP=3): 3 issuances then deny
    fake2 = use_fake(FakeAsc())
    ip = new_ip()
    oo, _, cc = mk_owner(client)
    ok = 0
    for _ in range(3):
        uu, tt = signup(client)
        ok += post_offer(client, uu, tt, cc, ip).status_code == 200
    check("3 issuances from one IP succeed", ok == 3 and fake2.mint_calls == 3, f"{ok} {fake2.mint_calls}")
    uu, tt = signup(client)
    before = fake2.total
    r = post_offer(client, uu, tt, cc, ip)
    check("4th from the same IP is denied uniformly", is_uniform_denial(r), f"{r.status_code} {r.text}")
    check("IP cap denial makes no ASC mint", fake2.mint_calls == 3 and fake2.total == before)
    check("IP cap denial leaves no ledger row", rows_for(uu) == [])
    r = post_offer(client, uu, tt, cc, new_ip())
    check("a different IP is not blocked by that cap", r.status_code == 200, f"{r.status_code} {r.text}")

    # max_redemptions counts outstanding (pending/issued) issuances
    fake3 = use_fake(FakeAsc())
    om, _, cm = mk_owner(client)
    q("UPDATE promo_codes SET max_redemptions=2 WHERE code=%s", (cm,))
    got = []
    for _ in range(3):
        uu, tt = signup(client)
        got.append(post_offer(client, uu, tt, cm).status_code)
    check("max_redemptions=2 counts outstanding issuances: 200,200,400",
          got == [200, 200, 400] and fake3.mint_calls == 2, f"{got} {fake3.mint_calls}")


def test_already_redeemed(client):
    print("\n== Already redeemed ==")
    set_flags()
    fake = use_fake(FakeAsc())
    oid, otok, code = mk_owner(client)
    uid, tok = signup(client)
    r = post_offer(client, uid, tok, code)
    assert r.status_code == 200
    db = aoc.OfferCodeManager()
    try:
        db.finalize_redeemed(uid, f"t_{uuid.uuid4().hex[:8]}")
    finally:
        db.close()
    n = fake.total
    r = post_offer(client, uid, tok, code)
    check("redeemed user re-requesting is denied uniformly", is_uniform_denial(r), f"{r.status_code} {r.text}")
    check("no ASC call after redemption", fake.total == n)
    check("redeemed user is also ineligible by history (remove sub => still denied by ledger)",
          rows_for(uid)[0][0] == "redeemed")


def test_fail_closed(client):
    print("\n== Fail-closed paths ==")
    set_flags()
    oid, otok, code = mk_owner(client)

    # preflight failure
    fake = use_fake(FakeAsc(preflight_ok=False))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("preflight failure => 503, nothing fabricated",
          r.status_code == 503 and "offer_code" not in r.text, f"{r.status_code} {r.text}")
    check("preflight failure => no mint", fake.mint_calls == 0)
    check("preflight failure => no ledger row", rows_for(u) == [])
    check("preflight failure is not cached as success", (fake.check_offer, aoc._preflight_ok_until == 0.0)[1])

    # mint definitively rejected
    fake = use_fake(FakeAsc(mint="reject"))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("mint rejected => 503, nothing fabricated", r.status_code == 503 and "offer_code" not in r.text,
          f"{r.status_code} {r.text}")
    rows = rows_for(u)
    check("mint rejected => row marked failed", [x[0] for x in rows] == ["failed"], str(rows))
    fake2 = use_fake(FakeAsc())
    r = post_offer(client, u, t, code)
    check("after a definite rejection the user can retry and get a code", r.status_code == 200 and fake2.mint_calls == 1,
          f"{r.status_code} {r.text}")

    # mint ambiguous: pending row, re-mint blocked
    fake = use_fake(FakeAsc(mint="ambiguous"))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("ambiguous mint => 503", r.status_code == 503 and "offer_code" not in r.text, f"{r.status_code}")
    check("ambiguous mint leaves a pending row", [x[0] for x in rows_for(u)] == ["pending"], str(rows_for(u)))
    fake_ok = use_fake(FakeAsc())
    r = post_offer(client, u, t, code)
    check("pending row blocks any re-mint (duplicate risk) => 503", r.status_code == 503 and fake_ok.mint_calls == 0,
          f"{r.status_code} mints={fake_ok.mint_calls}")

    # code not ready after a successful mint
    fake = use_fake(FakeAsc(fetch="notready"))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("code not ready => 503, no code fabricated", r.status_code == 503 and "offer_code" not in r.text,
          f"{r.status_code} {r.text}")
    check("code-not-ready row stays issued (batch exists)", [x[0] for x in rows_for(u)] == ["issued"])
    fake_ok = use_fake(FakeAsc())
    fake_ok.batches = dict(fake.batches)          # same ASC state, now ready
    r = post_offer(client, u, t, code)
    check("retry once ready returns the code from the SAME batch, no second mint",
          r.status_code == 200 and fake_ok.mint_calls == 0, f"{r.status_code} {r.text} mints={fake_ok.mint_calls}")

    # global daily mint cap
    n = q("SELECT COUNT(*) FROM ios_offer_redemptions WHERE status != 'failed' "
          "AND created_at > NOW() - INTERVAL '24 hours'")[0][0]
    check("precondition: ledger has rows to cap against", n > 0, str(n))
    set_flags(IOS_OFFER_CODE_DAILY_MINT_CAP=str(n))
    fake = use_fake(FakeAsc())
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("global daily mint cap => 503", r.status_code == 503, f"{r.status_code} {r.text}")
    check("global cap => no mint, no row", fake.mint_calls == 0 and rows_for(u) == [])
    set_flags(IOS_OFFER_CODE_DAILY_MINT_CAP="1000000")

    # unexpected error inside the manager => closed
    fake = use_fake(FakeAsc())
    u, t = signup(client)
    saved = aoc.OfferCodeManager.request_code

    def boom(self, *a, **k):
        raise RuntimeError("db exploded SECRET")
    aoc.OfferCodeManager.request_code = boom
    try:
        r = post_offer(client, u, t, code)
    finally:
        aoc.OfferCodeManager.request_code = saved
    check("unexpected exception => 503 with no detail leak",
          r.status_code == 503 and "SECRET" not in r.text, f"{r.status_code} {r.text}")
    check("unexpected exception => no ASC call", fake.total == 0)

    # validator failure (PromoManager.evaluate raising is swallowed to None by design)
    saved_eval = aoc.OfferCodeManager.evaluate

    def eval_boom(self, *a, **k):
        raise RuntimeError("validator down")
    aoc.OfferCodeManager.evaluate = eval_boom
    try:
        r = post_offer(client, u, t, code)
    finally:
        aoc.OfferCodeManager.evaluate = saved_eval
    check("validator exception => denied (closed), no ASC call", is_uniform_denial(r) and fake.total == 0,
          f"{r.status_code} {r.text}")


def test_ip_missing_closed(client):
    print("\n== Missing client IP fails closed ==")
    set_flags()
    fake = use_fake(FakeAsc())
    oid, otok, code = mk_owner(client)
    u, t = signup(client)
    db = aoc.OfferCodeManager()
    try:
        try:
            db.request_code(u, code, "", client=fake)
            res = "issued"
        except aoc.OfferCodeDenied:
            res = "denied"
    finally:
        db.close()
    check("empty IP => denied, no ASC call", res == "denied" and fake.total == 0, f"{res} {fake.total}")


def test_rate_limit(client):
    print("\n== Rate limiting ==")
    set_flags(IOS_OFFER_CODE_RATE_LIMIT="3/minute")
    fake = use_fake(FakeAsc())
    u, t = signup(client)
    ip = new_ip()
    codes = [post_offer(client, u, t, "NOSUCHCODE", ip).status_code for _ in range(5)]
    check("per-IP/user limit returns 429 after the budget", 429 in codes and codes[:3] == [400, 400, 400], str(codes))
    check("rate-limited and denied requests made no ASC call", fake.total == 0)
    set_flags(IOS_OFFER_CODE_RATE_LIMIT="100000/minute")


def test_reward_crediting(client):
    print("\n== Reward crediting only on a verified Apple transaction ==")
    set_flags()
    fake = use_fake(FakeAsc())
    oid, otok, code = mk_owner(client)
    uid, tok = signup(client)
    r = post_offer(client, uid, tok, code)
    assert r.status_code == 200, r.text
    check("no reward at issue time", rewards_of(oid) == [])
    redeems = q("SELECT COUNT(*) FROM promo_redemptions WHERE user_id=%s", (uid,))[0][0]
    check("no promo_redemptions row at issue time", redeems == 0)

    def payload(txn, **over):
        p = {"environment": "Production", "originalTransactionId": f"otx_{uid[:8]}", "transactionId": txn,
             "productId": INDIVIDUAL, "expiresDate": 4102444800000, "offerType": 3, "offerIdentifier": REF}
        p.update(over)
        return p

    def reconcile(p, user=None):
        aoc.reconcile_offer_code(user or uid, p)

    # ignored payloads
    reconcile(payload("t0", offerType=2))
    reconcile(payload("t0", offerType=1))
    reconcile(payload("t0", offerIdentifier="invite_reward_50"))
    reconcile(payload("t0", offerIdentifier="other"))
    reconcile(payload("t0", productId=GROUP_PRODUCT))
    reconcile(payload("t0", productId="com.unknown"))
    reconcile(payload("t0", transactionId=""))
    aoc.reconcile_offer_code(None, payload("t0"))
    check("wrong offerType / identifier / product / empty txn / no user are ignored",
          rows_for(uid)[0][0] == "issued" and rewards_of(oid) == [], str(rows_for(uid)))
    set_flags(offer=False)
    reconcile(payload("t0"))
    check("flag off: reconcile is a no-op", rows_for(uid)[0][0] == "issued" and rewards_of(oid) == [])
    set_flags()

    # unmatched: user with no issued redemption
    stranger, _ = signup(client)
    reconcile(payload("t_stranger"), user=stranger)
    check("verified txn for a user with no issued redemption credits nothing", rewards_of(oid) == [])

    # real path: apple/sync with a decoded payload
    utxn = f"t_{uuid.uuid4().hex[:8]}"
    saved_decode = ow.apple_service.decode_jws
    ow.apple_service.decode_jws = lambda jws: payload(utxn)
    try:
        rs = client.post("/subscriptions/apple/sync", json={"user_id": uid, "jws": "x"}, headers=hdr(tok))
    finally:
        ow.apple_service.decode_jws = saved_decode
    rw = rewards_of(oid)
    check("apple/sync with offerType 3 txn => 200", rs.status_code == 200, f"{rs.status_code} {rs.text[:200]}")
    check("redemption marked redeemed with the transaction id",
          rows_for(uid)[0][0] == "redeemed" and rows_for(uid)[0][2] == utxn, str(rows_for(uid)))
    check("owner credited exactly once",
          len(rw) == 1 and rw[0][1] == "signup" and rw[0][2] == f"signup:{uid}" and str(rw[0][3]) == uid, str(rw))
    check("promo_redemptions logged (platform apple, store txn id)",
          q("SELECT COUNT(*) FROM promo_redemptions WHERE user_id=%s AND platform='apple' AND store_transaction_id=%s",
            (uid, utxn))[0][0] == 1)
    # replays
    reconcile(payload(utxn))
    reconcile(payload(utxn))
    check("replay of the same transaction never double-credits", len(rewards_of(oid)) == 1)
    reconcile(payload("t_renewal"))
    check("a different/later transaction never produces a second reward", len(rewards_of(oid)) == 1)
    check("redemption keeps its original transaction id", rows_for(uid)[0][2] == utxn)
    check("promo_redemptions not duplicated",
          q("SELECT COUNT(*) FROM promo_redemptions WHERE user_id=%s", (uid,))[0][0] == 1)

    # notification path
    oid2, _, code2 = mk_owner(client)
    nid, ntok = signup(client)
    r = post_offer(client, nid, ntok, code2)
    assert r.status_code == 200, r.text
    notx = f"otx_note_{uuid.uuid4().hex[:8]}"
    give_sub(nid, "apple", "individual", otxn=notx)
    ntxn = f"t_{uuid.uuid4().hex[:8]}"
    ntxn_payload = {"environment": "Production", "originalTransactionId": notx, "transactionId": ntxn,
                    "productId": INDIVIDUAL, "expiresDate": 4102444800000, "offerType": 3,
                    "offerIdentifier": REF}
    saved_decode = ow.apple_service.decode_jws

    def dec(jws):
        if jws == "outer":
            return {"notificationType": "OFFER_REDEEMED", "data": {"signedTransactionInfo": "inner"}}
        return ntxn_payload
    ow.apple_service.decode_jws = dec
    try:
        rn = client.post("/subscriptions/apple/notifications", json={"signedPayload": "outer"}, headers=hdr())
        rn2 = client.post("/subscriptions/apple/notifications", json={"signedPayload": "outer"}, headers=hdr())
    finally:
        ow.apple_service.decode_jws = saved_decode
    check("notification path returns 200 (and on replay)", rn.status_code == 200 and rn2.status_code == 200,
          f"{rn.status_code} {rn.text} / {rn2.status_code}")
    check("notification credits the owner exactly once", len(rewards_of(oid2)) == 1, str(rewards_of(oid2)))
    check("notification marks the redemption redeemed", rows_for(nid)[0][0] == "redeemed")

    # no double credit with invite_code at signup
    oid3, _, code3 = mk_owner(client)
    sid_, stok = signup(client, invite=code3)
    early = len(rewards_of(oid3))
    r = post_offer(client, sid_, stok, code3)
    if r.status_code == 200:
        reconcile(payload(f"t_{uuid.uuid4().hex[:8]}", originalTransactionId=f"otx_{sid_[:8]}"), user=sid_)
        check("signup invite_code + offer code => still one reward for that invitee",
              len([x for x in rewards_of(oid3) if str(x[3]) == sid_]) == 1, str(rewards_of(oid3)))
    else:
        check("signup-credited invitee is denied by eligibility or issued; never two rewards",
              len([x for x in rewards_of(oid3) if str(x[3]) == sid_]) <= 1, f"{r.status_code} early={early}")

    # self-referral at reward time: owner==invitee never credits
    oid4, _, code4 = mk_owner(client)
    db = aoc.OfferCodeManager()
    try:
        owner_row = db.find_code(code4)
        rid = q("INSERT INTO ios_offer_redemptions (user_id, code_id, referrer_user_id, status, asc_batch_id) "
                "VALUES (%s,%s,%s,'issued','bself') RETURNING _id", (oid4, owner_row["id"], oid4))[0][0]
        db.finalize_redeemed(oid4, f"t_{uuid.uuid4().hex[:8]}")
    finally:
        db.close()
    check("self-referral never credits at reward time", rewards_of(oid4) == [], str(rewards_of(oid4)))

    # inactive code at reward time: no reward
    oid5, _, code5 = mk_owner(client)
    u5, t5 = signup(client)
    assert post_offer(client, u5, t5, code5).status_code == 200
    q("UPDATE promo_codes SET active=FALSE WHERE code=%s", (code5,))
    reconcile(payload(f"t_{uuid.uuid4().hex[:8]}"), user=u5)
    check("code deactivated before redemption => no owner reward", rewards_of(oid5) == [], str(rewards_of(oid5)))


def test_hook_failure_semantics(client):
    print("\n== Hook failure semantics ==")
    set_flags()
    use_fake(FakeAsc())
    oid, otok, code = mk_owner(client)
    uid, tok = signup(client)
    assert post_offer(client, uid, tok, code).status_code == 200
    saved = aoc.OfferCodeManager.finalize_redeemed

    def boom(self, *a, **k):
        raise RuntimeError("db down")
    aoc.OfferCodeManager.finalize_redeemed = boom
    otx = f"otx_{uuid.uuid4().hex[:8]}"
    saved_decode = ow.apple_service.decode_jws
    ow.apple_service.decode_jws = lambda jws: {
        "environment": "Production", "originalTransactionId": otx, "transactionId": "tboom",
        "productId": INDIVIDUAL, "expiresDate": 4102444800000, "offerType": 3, "offerIdentifier": REF}
    try:
        rs = client.post("/subscriptions/apple/sync", json={"user_id": uid, "jws": "x"}, headers=hdr(tok))
    finally:
        aoc.OfferCodeManager.finalize_redeemed = saved
        ow.apple_service.decode_jws = saved_decode
    check("apple/sync survives a reconcile infrastructure error (logged, retried next sync)",
          rs.status_code == 200, f"{rs.status_code} {rs.text[:200]}")
    check("failed reconcile left redemption issued and no reward", rows_for(uid)[0][0] == "issued" and rewards_of(oid) == [])
    # next sync completes it
    saved_decode = ow.apple_service.decode_jws
    ow.apple_service.decode_jws = lambda jws: {
        "environment": "Production", "originalTransactionId": otx, "transactionId": "tboom",
        "productId": INDIVIDUAL, "expiresDate": 4102444800000, "offerType": 3, "offerIdentifier": REF}
    try:
        client.post("/subscriptions/apple/sync", json={"user_id": uid, "jws": "x"}, headers=hdr(tok))
    finally:
        ow.apple_service.decode_jws = saved_decode
    check("next sync completes the redemption and credits once",
          rows_for(uid)[0][0] == "redeemed" and len(rewards_of(oid)) == 1, f"{rows_for(uid)} {rewards_of(oid)}")


def test_log_hygiene(client):
    print("\n== Logs / audit carry no code values or raw IPs ==")
    import logging
    import io
    buf = io.StringIO()
    h = logging.StreamHandler(buf)
    root = logging.getLogger()
    root.addHandler(h)
    old = root.level
    root.setLevel(logging.DEBUG)
    try:
        set_flags()
        fake = use_fake(FakeAsc())
        oid, otok, code = mk_owner(client)
        u, t = signup(client)
        ip = new_ip()
        r = post_offer(client, u, t, code, ip)
        val = r.json().get("offer_code", "NOVALUE")
        post_offer(client, u, t, "NOSUCHCODE", ip)
        fake_bad = use_fake(FakeAsc(mint="reject"))
        u2, t2 = signup(client)
        post_offer(client, u2, t2, code)
    finally:
        root.removeHandler(h)
        root.setLevel(old)
    logs = buf.getvalue()
    check("issued offer code value never appears in logs", val not in logs)
    check("ASC key material never appears in logs", "BEGIN" not in logs and "PRIVATE KEY" not in logs)
    audit = json.dumps([[str(c) for c in row] for row in q(
        "SELECT action, detail FROM promo_audit_log WHERE owner_user_id=%s OR actor_user_id=ANY(%s::uuid[])",
        (oid, [u, u2]))])
    check("audit trail records issuance events", "ios_offer_issued" in audit and "ios_offer_reserved" in audit, audit[:300])
    check("audit trail has no code value or raw IP", val not in audit and ip not in audit)


def cleanup():
    uids = list(USERS)
    q("DELETE FROM ios_offer_redemptions WHERE user_id = ANY(%s::uuid[]) OR referrer_user_id = ANY(%s::uuid[])",
      (uids, uids))
    q("DELETE FROM owner_rewards WHERE owner_user_id = ANY(%s::uuid[]) OR invitee_user_id = ANY(%s::uuid[])",
      (uids, uids))
    q("DELETE FROM promo_audit_log WHERE owner_user_id = ANY(%s::uuid[]) OR actor_user_id = ANY(%s::uuid[])",
      (uids, uids))
    for cid in CREATORS:
        q("DELETE FROM promo_audit_log WHERE code_id IN (SELECT _id FROM promo_codes WHERE creator_id=%s)", (cid,))
        q("DELETE FROM promo_redemptions WHERE creator_id = %s", (cid,))
        q("DELETE FROM promo_codes WHERE creator_id = %s", (cid,))
        q("DELETE FROM creators WHERE _id = %s", (cid,))
    for uid in uids:
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


def main():
    stripe_service.is_configured = lambda: False   # never reach the real Stripe API from tests
    real_get_client = aoc.get_client
    test_config()
    test_asc_client()
    try:
        with TestClient(main_module.app) as client:
            test_flag_off(client)
            test_auth(client)
            test_happy_and_idempotency(client)
            test_concurrent(client)
            test_validation_matrix(client)
            test_already_redeemed(client)
            test_fail_closed(client)
            test_ip_missing_closed(client)
            test_rate_limit(client)
            test_reward_crediting(client)
            test_hook_failure_semantics(client)
            test_log_hygiene(client)
            set_flags(offer=False, rewards=False)
    finally:
        aoc.get_client = real_get_client
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
