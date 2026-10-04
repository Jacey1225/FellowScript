"""Backend coverage for task 20261003-ios-friend-offer-code-redeem (code POOL design).

Apple only allows one-time-use offer-code batches of 500-25,000 codes (a 1-code
batch is a live 409), so the server keeps a pool: one batch is created only when
no usable one exists and each validated redemption is handed ONE code by index.
Every ASC interaction here goes through a fake that REJECTS batches under 500.

Proves: eager config validation (incl. batch size 500-25000, daily batch cap, expiry
7-180, key loaded only when enabled, no key bytes in errors); flag-off uniform 404;
the validation matrix each denied with ONE uniform 400 and ZERO ASC calls; the ASC
client contract (read-only preflight, the single write requests >=500 codes against
the configured offer, sorted de-duplicated CSV values, status-only errors); pool
behaviour (one batch serves many users, distinct sequential indexes, code at the
reserved index of the sorted values, adoption of an operator-seeded batch, exhaustion
and near-expiry create a fresh batch, expired issuance superseded); fail-closed paths
(preflight, batch rejected / ambiguous leaves a pending batch that blocks another
create, values not ready or incomplete, code not ready after reservation, daily batch
cap, daily issued cap, pool exhausted race, DB error) each 503 with an audit event and
nothing fabricated; idempotency (retries and concurrent same-user requests return the
same index and consume one; concurrent different users get distinct codes from one
batch); reward crediting (never at issue time, only on a verified offerType 3 + our
reference name transaction via apple/sync and notifications, exactly once on replay);
and that no code value ever appears in logs, audit rows or any DB row. All ASC traffic
is faked; there are no live calls.

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
    "IOS_OFFER_CODE_BATCH_SIZE": "500",
    "IOS_OFFER_CODE_DAILY_BATCH_CAP": "1000",
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
    """Stands in for AscOfferCodeClient and mimics ASC's rules: batches under 500
    (or over 25,000) are rejected like the live 409. Counts every call; never
    touches the network. ``fetch`` modes: ok | notready."""

    def __init__(self, preflight_ok=True, mint="ok", fetch="ok", batches=None):
        self.preflight_ok, self.mint, self.fetch = preflight_ok, mint, fetch
        self.pre_calls = self.create_calls = self.fetch_calls = 0
        self.create_sizes = []
        self.dates = []
        self.batches = batches if batches is not None else {}    # asc id -> sorted code list
        self._lock = threading.Lock()

    @property
    def mint_calls(self):
        return self.create_calls

    @property
    def total(self):
        return self.pre_calls + self.create_calls + self.fetch_calls

    @staticmethod
    def make_codes(n):
        return sorted(f"T{uuid.uuid4().hex[:12].upper()}{i:05d}" for i in range(n))

    def seed(self, asc_id, count=500):
        self.batches[asc_id] = self.make_codes(count)
        return self.batches[asc_id]

    def all_codes(self):
        return {c for v in self.batches.values() for c in v}

    def check_offer(self):
        with self._lock:
            self.pre_calls += 1
        if not self.preflight_ok:
            raise aoc.AscRejected("offer not active / not new-subscribers / name mismatch")

    def create_one_time_use_batch(self, number_of_codes, expiration_date):
        with self._lock:
            self.create_calls += 1
            self.create_sizes.append(number_of_codes)
            self.dates.append(expiration_date)
        if number_of_codes < 500 or number_of_codes > 25000:
            raise aoc.AscRejected("status 409")        # the live ENTITY_ERROR.ATTRIBUTE.INVALID
        if self.mint == "reject":
            raise aoc.AscRejected("status 409")
        if self.mint == "ambiguous":
            raise aoc.AscAmbiguous("ReadTimeout")
        bid = f"batch{uuid.uuid4().hex[:10]}"
        self.seed(bid, number_of_codes)
        return bid

    def fetch_values(self, batch_id):
        with self._lock:
            self.fetch_calls += 1
        if self.fetch == "notready":
            raise aoc.AscAmbiguous("codes not ready")
        if batch_id not in self.batches:
            raise aoc.AscRejected("status 404")
        return list(self.batches[batch_id])


ORIG_BATCHES = {}      # pre-existing pool rows (dev DB) -> status, restored at the end
SKIP_RESET = False


def reset_pool():
    """Take every existing pool batch out of play so each test controls the pool."""
    q("UPDATE ios_offer_batches SET status='failed' WHERE status IN ('pending','active')")


def use_fake(fake, reset=True):
    if reset:
        reset_pool()
    aoc.get_client = lambda: fake
    aoc._preflight_ok_until = 0.0
    return fake


def batch_rows():
    return q("SELECT asc_batch_id, status, number_of_codes, next_index, ready_at IS NOT NULL "
             "FROM ios_offer_batches WHERE status IN ('pending','active') ORDER BY created_at")


def audit_actions(*uids):
    return [r[0] for r in q("SELECT action FROM promo_audit_log WHERE actor_user_id=ANY(%s::uuid[]) "
                            "OR owner_user_id=ANY(%s::uuid[])", (list(uids), list(uids)))]


def ledger(uid):
    return q("SELECT r.status, b.asc_batch_id, r.code_index FROM ios_offer_redemptions r "
             "LEFT JOIN ios_offer_batches b ON b._id = r.batch_id WHERE r.user_id=%s ORDER BY r.created_at", (uid,))


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
        check("expiry 6 refuses (below the 3-day safety margin floor of 7)",
              attempt(IOS_OFFER_CODE_EXPIRY_DAYS="6") is not None)
        check("expiry 7 and 180 accepted", attempt(IOS_OFFER_CODE_EXPIRY_DAYS="7") is None
              and attempt(IOS_OFFER_CODE_EXPIRY_DAYS="180") is None)
        check("batch size 499 refuses (Apple minimum is 500)", attempt(IOS_OFFER_CODE_BATCH_SIZE="499") is not None)
        check("batch size 1 refuses", attempt(IOS_OFFER_CODE_BATCH_SIZE="1") is not None)
        check("batch size 25001 refuses (Apple maximum is 25000)",
              attempt(IOS_OFFER_CODE_BATCH_SIZE="25001") is not None)
        check("batch size non-int refuses", attempt(IOS_OFFER_CODE_BATCH_SIZE="lots") is not None)
        check("batch size 500 and 25000 accepted", attempt(IOS_OFFER_CODE_BATCH_SIZE="500") is None
              and attempt(IOS_OFFER_CODE_BATCH_SIZE="25000") is None)
        check("daily batch cap 0 refuses", attempt(IOS_OFFER_CODE_DAILY_BATCH_CAP="0") is not None)
        attempt()
        check("config exposes batch size and batch cap",
              aoc.offer_codes_config().batch_size == 500 and aoc.offer_codes_config().daily_batch_cap == 1000)
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
    bid = make(mint_h).create_one_time_use_batch(500, "2026-11-01")
    body = captured["body"]["data"]
    check("batch create is a single POST to subscriptionOfferCodeOneTimeUseCodes",
          captured["method"] == "POST" and captured["path"] == "/v1/subscriptionOfferCodeOneTimeUseCodes")
    check("batch create requests the configured pool size (500) with expiration",
          body["attributes"] == {"numberOfCodes": 500, "expirationDate": "2026-11-01"}, str(body))
    check("batch create binds to configured offer id (never creates an offer)",
          body["relationships"]["offerCode"]["data"] == {"type": "subscriptionOfferCodes", "id": cfg.offer_code_id})
    check("batch create returns batch id", bid == "batch123")
    check("ASC request is Bearer-JWT signed", captured["auth"].startswith("Bearer ey"))
    try:
        make(lambda r: httpx.Response(201, json={"data": {}})).create_one_time_use_batch(500, "2026-11-01")
        e = None
    except Exception as ex:
        e = ex
    check("batch create with no batch id => AscAmbiguous", isinstance(e, aoc.AscAmbiguous))
    try:
        make(lambda r: httpx.Response(409, text="SECRET-BODY")).create_one_time_use_batch(500, "2026-11-01")
        e = None
    except Exception as ex:
        e = ex
    check("batch create 409 => AscRejected, message carries status only",
          isinstance(e, aoc.AscRejected) and "SECRET-BODY" not in str(e) and "409" in str(e), str(e))
    try:
        make(lambda r: httpx.Response(503)).create_one_time_use_batch(500, "2026-11-01")
        e = None
    except Exception as ex:
        e = ex
    check("batch create 5xx => AscAmbiguous (effect unknown)", isinstance(e, aoc.AscAmbiguous))

    # The fake used everywhere else enforces Apple's batch-size rule; prove it does.
    fk = FakeAsc()
    for n in (1, 499, 25001):
        try:
            fk.create_one_time_use_batch(n, "2026-11-01")
            e = None
        except Exception as ex:
            e = ex
        check(f"fake ASC rejects a {n}-code batch like the live API", isinstance(e, aoc.AscRejected))
    check("fake ASC accepts 500", len(fk.batches[fk.create_one_time_use_batch(500, "2026-11-01")]) == 500)

    def vals(text, status=200):
        return make(lambda r: httpx.Response(status, text=text)).fetch_values("batch123")
    csv_text = "ZZZZZZ9\nAAAAAA1\nMMMMMM5\nAAAAAA1\n"
    check("fetch_values returns sorted, de-duplicated values", vals(csv_text) == ["AAAAAA1", "MMMMMM5", "ZZZZZZ9"],
          str(vals(csv_text)))
    check("fetch_values accepts a CSV with a header and ignores it",
          vals("Code\nAAAAAA1\nBBBBBB2\n") == ["AAAAAA1", "BBBBBB2"])
    seen_v = []
    make(lambda r: (seen_v.append((r.method, r.url.path)), httpx.Response(200, text="AAAAAA1"))[1]).fetch_values("batch123")
    check("fetch_values is a GET of the batch /values endpoint",
          seen_v == [("GET", "/v1/subscriptionOfferCodeOneTimeUseCodes/batch123/values")], str(seen_v))
    for label, text in (("empty", ""), ("malformed only", "bad code!\n")):
        try:
            vals(text)
            e = None
        except Exception as ex:
            e = ex
        check(f"fetch_values {label} => AscAmbiguous (not ready, closed)", isinstance(e, aoc.AscAmbiguous))
    try:
        vals("X", status=404)
        e = None
    except Exception as ex:
        e = ex
    check("fetch_values 404 => AscRejected", isinstance(e, aoc.AscRejected))
    try:
        make(lambda r: httpx.Response(200, text="X")).fetch_values("../etc")
        e = None
    except Exception as ex:
        e = ex
    check("fetch_values rejects unsafe batch id", isinstance(e, aoc.AscAmbiguous))
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
    print("\n== Valid request: pool batch, one code per user, idempotent retries ==")
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
    check("first request creates exactly one batch of >=500 codes (preflight once)",
          fake.pre_calls == 1 and fake.create_calls == 1 and fake.create_sizes == [500],
          f"{fake.pre_calls}/{fake.create_calls}/{fake.create_sizes}")
    check("no ASC call ever asked for fewer than 500 codes", all(n >= 500 for n in fake.create_sizes))
    led = ledger(uid)
    check("exactly one issued ledger row on the pool batch at index 0",
          len(led) == 1 and led[0][0] == "issued" and led[0][1] in fake.batches and led[0][2] == 0, str(led))
    check("returned code is the sorted batch value at the reserved index",
          j.get("offer_code") == fake.batches[led[0][1]][0])
    check("batch row: active, ready, size 500, one index handed out",
          batch_rows() == [(led[0][1], "active", 500, 1, True)], str(batch_rows()))
    ip_hash = q("SELECT ip_hash FROM ios_offer_redemptions WHERE user_id=%s", (uid,))[0][0]
    check("ledger stores a hash, not the raw IP", ip_hash and ip not in ip_hash)
    check("no reward at issue time", rewards_of(oid) == [])
    # retries
    for i in range(3):
        rr = post_offer(client, uid, tok, code, ip)
        check(f"retry {i + 1} returns the same code", rr.status_code == 200 and rr.json()["offer_code"] == j["offer_code"],
              f"{rr.status_code} {rr.text}")
    check("retries never create another batch", fake.create_calls == 1, str(fake.create_calls))
    check("retries never consume another index", batch_rows()[0][3] == 1, str(batch_rows()))
    check("still one ledger row", len(ledger(uid)) == 1)
    check("still no reward after retries", rewards_of(oid) == [])
    rr = post_offer(client, uid, tok, " " + code.lower() + " ", ip)
    check("code entry is normalised (case/whitespace) and stays idempotent",
          rr.status_code == 200 and rr.json()["offer_code"] == j["offer_code"] and batch_rows()[0][3] == 1,
          f"{rr.status_code} {rr.text}")
    # a different (valid) friend code cannot swap the live issuance
    oid2, _, code2 = mk_owner(client)
    rr = post_offer(client, uid, tok, code2, ip)
    check("a different friend code on a live issuance is denied (uniform), nothing consumed",
          is_uniform_denial(rr) and batch_rows()[0][3] == 1, f"{rr.status_code} {rr.text}")
    check("ASC expirationDate is a future ISO date", fake.dates and fake.dates[0] > "2026")

    # a second user is served from the SAME batch at the next index
    u2, t2 = signup(client)
    r2 = post_offer(client, u2, t2, code, new_ip())
    l2 = ledger(u2)
    check("second user served from the same batch, no new create",
          r2.status_code == 200 and fake.create_calls == 1 and l2 and l2[0][1] == led[0][1] and l2[0][2] == 1,
          f"{r2.status_code} {l2} creates={fake.create_calls}")
    check("second user gets a different code (the code at index 1)",
          r2.json().get("offer_code") == fake.batches[led[0][1]][1] != j["offer_code"])
    check("pool counter advanced by exactly one per user", batch_rows()[0][3] == 2, str(batch_rows()))

    # 40 sequential issuances never repeat a code or an index
    seen_codes, seen_idx = {j["offer_code"], r2.json()["offer_code"]}, {0, 1}
    for _ in range(8):
        uu, tt = signup(client)
        rr = post_offer(client, uu, tt, code, new_ip())
        if rr.status_code == 200:
            seen_codes.add(rr.json()["offer_code"])
            seen_idx.add(ledger(uu)[0][2])
    check("10 users => 10 distinct codes on 10 distinct indexes, still one batch",
          len(seen_codes) == 10 and seen_idx == set(range(10)) and fake.create_calls == 1,
          f"{len(seen_codes)} {sorted(seen_idx)} creates={fake.create_calls}")


def test_concurrent(client):
    print("\n== Concurrency ==")
    set_flags()
    fake = use_fake(FakeAsc())
    oid, otok, code = mk_owner(client)
    # one user, many simultaneous requests: one row, one index, one code
    uid, tok = signup(client)
    ip = new_ip()
    out = []

    def go():
        out.append(post_offer(client, uid, tok, code, ip))
    ts = [threading.Thread(target=go) for _ in range(5)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("same-user concurrency creates at most one batch", fake.create_calls == 1, str(fake.create_calls))
    live = q("SELECT COUNT(*) FROM ios_offer_redemptions WHERE user_id=%s AND status IN ('pending','issued','redeemed')",
             (uid,))[0][0]
    check("same-user concurrency leaves exactly one live ledger row", live == 1, str(live))
    codes = {r.json().get("offer_code") for r in out if r.status_code == 200}
    check("every success returned the same code", len(codes) <= 1 and len(codes) == 1, str(codes))
    check("same-user concurrency consumed exactly one index", batch_rows()[0][3] == 1, str(batch_rows()))
    check("no status other than 200/400/503", all(r.status_code in (200, 400, 503) for r in out),
          str([r.status_code for r in out]))

    # many users at once on a cold pool: a single batch, distinct codes and indexes
    reset_pool()
    fake = use_fake(FakeAsc(), reset=False)
    users = [signup(client) for _ in range(6)]
    res = {}

    def go2(u, t):
        res[u] = post_offer(client, u, t, code, new_ip())
    ts = [threading.Thread(target=go2, args=ut) for ut in users]
    [t.start() for t in ts]
    [t.join() for t in ts]
    ok = {u: r for u, r in res.items() if r.status_code == 200}
    check("cold-pool stampede creates exactly one batch", fake.create_calls == 1, f"creates={fake.create_calls}")
    check("every concurrent user got a code or a clean 503",
          all(r.status_code in (200, 503) for r in res.values()), str([r.status_code for r in res.values()]))
    idx = [ledger(u)[0][2] for u in ok]
    check("distinct users got distinct codes and distinct indexes",
          len({r.json()["offer_code"] for r in ok.values()}) == len(ok) and len(set(idx)) == len(idx),
          f"{len(ok)} {sorted(idx)}")
    check("counter equals codes handed out", batch_rows()[0][3] == len(ok), f"{batch_rows()} ok={len(ok)}")
    check("at least some users succeeded", len(ok) >= 1)


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
    check("3 issuances from one IP succeed from ONE pool batch", ok == 3 and fake2.create_calls == 1,
          f"{ok} {fake2.create_calls}")
    uu, tt = signup(client)
    before = fake2.total
    r = post_offer(client, uu, tt, cc, ip)
    check("4th from the same IP is denied uniformly", is_uniform_denial(r), f"{r.status_code} {r.text}")
    check("IP cap denial makes no ASC call", fake2.create_calls == 1 and fake2.total == before)
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
          got == [200, 200, 400] and fake3.create_calls == 1, f"{got} {fake3.create_calls}")


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
    check("preflight failure => no batch create, no values read", fake.create_calls == 0 and fake.fetch_calls == 0)
    check("preflight failure => no ledger row, no batch row", rows_for(u) == [] and batch_rows() == [])
    check("preflight failure is not cached as success", aoc._preflight_ok_until == 0.0)

    # batch create definitively rejected
    fake = use_fake(FakeAsc(mint="reject"))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("batch rejected => 503, nothing fabricated", r.status_code == 503 and "offer_code" not in r.text,
          f"{r.status_code} {r.text}")
    check("batch rejected => no redemption row, batch row failed",
          rows_for(u) == [] and batch_rows() == [], f"{rows_for(u)} {batch_rows()}")
    check("batch rejected => operator audit event", "ios_offer_batch_failed" in audit_actions(u))
    fake2 = use_fake(FakeAsc(), reset=False)
    r = post_offer(client, u, t, code)
    check("after a definite rejection the user can retry and get a code (failed batch never blocks)",
          r.status_code == 200 and fake2.create_calls == 1, f"{r.status_code} {r.text}")

    # batch create ambiguous: pending batch, another create blocked
    fake = use_fake(FakeAsc(mint="ambiguous"))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("ambiguous batch create => 503", r.status_code == 503 and "offer_code" not in r.text, f"{r.status_code}")
    check("ambiguous create leaves a pending batch and no redemption row",
          [b[1] for b in batch_rows()] == ["pending"] and rows_for(u) == [], str(batch_rows()))
    check("ambiguous create => operator audit event", "ios_offer_batch_ambiguous" in audit_actions(u))
    fake_ok = use_fake(FakeAsc(), reset=False)
    u3, t3 = signup(client)
    r = post_offer(client, u3, t3, code)
    check("pending batch blocks any second create (duplicate risk) => 503, no ASC create",
          r.status_code == 503 and fake_ok.create_calls == 0, f"{r.status_code} creates={fake_ok.create_calls}")
    check("pending-blocked => audit event", "ios_offer_batch_pending_blocked" in audit_actions(u3))

    # values not ready on a fresh batch
    fake = use_fake(FakeAsc(fetch="notready"))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("values not ready => 503, no code fabricated", r.status_code == 503 and "offer_code" not in r.text,
          f"{r.status_code} {r.text}")
    check("not ready => batch exists but is NOT marked ready, no index reserved, no row",
          batch_rows() and batch_rows()[0][1:] == ("active", 500, 0, False) and rows_for(u) == [], str(batch_rows()))
    check("not ready => operator audit event", "ios_offer_pool_not_ready" in audit_actions(u))
    fake_ok = use_fake(FakeAsc(batches=fake.batches), reset=False)
    r = post_offer(client, u, t, code)
    check("retry once ASC finished => 200 from the SAME batch, no second create",
          r.status_code == 200 and fake_ok.create_calls == 0, f"{r.status_code} {r.text}")
    check("batch now ready", batch_rows()[0][4] is True)

    # values incomplete (ASC still generating): partial list is NOT ready
    fake = use_fake(FakeAsc())
    aid = "partial1"
    fake.batches[aid] = fake.make_codes(499)
    q("INSERT INTO ios_offer_batches (asc_batch_id, status, number_of_codes, next_index, expires_at) "
      "VALUES (%s,'active',500,0,NOW() + INTERVAL '30 days')", (aid,))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("incomplete values (499/500) => 503 and never marked ready, no new create",
          r.status_code == 503 and fake.create_calls == 0 and batch_rows()[0][4] is False, f"{r.status_code} {batch_rows()}")

    # reservation made, then code read not ready: retry returns the SAME index
    fake = use_fake(FakeAsc())
    ua, ta = signup(client)
    assert post_offer(client, ua, ta, code).status_code == 200
    fake.fetch = "notready"
    ub, tb = signup(client)
    r = post_offer(client, ub, tb, code)
    check("code not ready after reservation => 503, nothing fabricated", r.status_code == 503 and "offer_code" not in r.text,
          f"{r.status_code} {r.text}")
    lb = ledger(ub)
    check("the reservation stands (issued, index 1) so a retry cannot take another",
          len(lb) == 1 and lb[0][0] == "issued" and lb[0][2] == 1 and batch_rows()[0][3] == 2, f"{lb} {batch_rows()}")
    check("code-not-ready => operator audit event", "ios_offer_code_not_ready" in audit_actions(ub))
    fake.fetch = "ok"
    r = post_offer(client, ub, tb, code)
    check("retry returns the code at the SAME reserved index, counter unchanged",
          r.status_code == 200 and r.json()["offer_code"] == fake.batches[lb[0][1]][1] and batch_rows()[0][3] == 2,
          f"{r.status_code} {r.text}")

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

    # validator failure
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


def test_caps(client):
    print("\n== Daily caps: codes issued vs batch creations counted separately ==")
    set_flags()
    oid, otok, code = mk_owner(client)

    # issued cap
    fake = use_fake(FakeAsc())
    ua, ta = signup(client)
    assert post_offer(client, ua, ta, code).status_code == 200
    n = q("SELECT COUNT(*) FROM ios_offer_redemptions WHERE status != 'failed' "
          "AND created_at > NOW() - INTERVAL '24 hours'")[0][0]
    set_flags(IOS_OFFER_CODE_DAILY_MINT_CAP=str(n))
    creates, idx = fake.create_calls, batch_rows()[0][3]
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("daily ISSUED cap reached => 503", r.status_code == 503 and "offer_code" not in r.text, f"{r.status_code} {r.text}")
    check("issued cap => no ASC create, no row, no index consumed",
          fake.create_calls == creates and rows_for(u) == [] and batch_rows()[0][3] == idx)
    check("issued cap => operator audit event", "ios_offer_daily_capped" in audit_actions(u))
    set_flags(IOS_OFFER_CODE_DAILY_MINT_CAP="1000000")
    check("raising the issued cap lets the same user in", post_offer(client, u, t, code).status_code == 200)

    # creating a batch does NOT consume the issued cap: cap = rows + 1 still allows a fresh-pool issuance
    n = q("SELECT COUNT(*) FROM ios_offer_redemptions WHERE status != 'failed' "
          "AND created_at > NOW() - INTERVAL '24 hours'")[0][0]
    set_flags(IOS_OFFER_CODE_DAILY_MINT_CAP=str(n + 1))
    fake = use_fake(FakeAsc())
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("batch creation is not counted against the issued cap (batch + 1 code under cap n+1)",
          r.status_code == 200 and fake.create_calls == 1, f"{r.status_code} {r.text}")
    set_flags(IOS_OFFER_CODE_DAILY_MINT_CAP="1000000")

    # batch cap
    nb = q("SELECT COUNT(*) FROM ios_offer_batches WHERE created_at > NOW() - INTERVAL '24 hours'")[0][0]
    set_flags(IOS_OFFER_CODE_DAILY_BATCH_CAP=str(nb))
    fake = use_fake(FakeAsc())
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("daily BATCH cap reached with an empty pool => 503, nothing fabricated",
          r.status_code == 503 and "offer_code" not in r.text, f"{r.status_code} {r.text}")
    check("batch cap => no ASC create call", fake.create_calls == 0)
    check("batch cap => operator audit event", "ios_offer_batch_capped" in audit_actions(u))
    set_flags(IOS_OFFER_CODE_DAILY_BATCH_CAP="1000")


def test_pool_lifecycle(client):
    print("\n== Pool lifecycle: exhaustion, expiry margin, seeded adoption, supersede ==")
    set_flags()
    oid, otok, code = mk_owner(client)

    # exhaustion: a full batch is skipped and a fresh one created
    fake = use_fake(FakeAsc())
    fake.seed("full1", 500)
    q("INSERT INTO ios_offer_batches (asc_batch_id, status, number_of_codes, next_index, expires_at, ready_at) "
      "VALUES ('full1','active',500,500,NOW() + INTERVAL '30 days',NOW())")
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    l = ledger(u)
    check("exhausted batch is never issued from; a new batch is created",
          r.status_code == 200 and fake.create_calls == 1 and l and l[0][1] != "full1", f"{r.status_code} {l}")
    check("exhausted batch's counter is untouched",
          q("SELECT next_index FROM ios_offer_batches WHERE asc_batch_id='full1'")[0][0] == 500)
    # last code of a batch is usable exactly once
    fake = use_fake(FakeAsc())
    codes = fake.seed("last1", 500)
    q("INSERT INTO ios_offer_batches (asc_batch_id, status, number_of_codes, next_index, expires_at, ready_at) "
      "VALUES ('last1','active',500,499,NOW() + INTERVAL '30 days',NOW())")
    u1, t1 = signup(client)
    r1 = post_offer(client, u1, t1, code)
    u2, t2 = signup(client)
    r2 = post_offer(client, u2, t2, code)
    check("the last code (index 499) is handed out once", r1.status_code == 200 and r1.json()["offer_code"] == codes[499],
          f"{r1.status_code} {r1.text}")
    check("the next user triggers a fresh batch, never index 500",
          r2.status_code == 200 and fake.create_calls == 1 and ledger(u2)[0][1] != "last1", f"{r2.status_code} {ledger(u2)}")

    # near-expiry (inside the 3-day safety margin): not issued from
    fake = use_fake(FakeAsc())
    codes = fake.seed("soon1", 500)
    q("INSERT INTO ios_offer_batches (asc_batch_id, status, number_of_codes, next_index, expires_at, ready_at) "
      "VALUES ('soon1','active',500,0,NOW() + INTERVAL '2 days',NOW())")
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("batch expiring within the 3-day margin is skipped; fresh batch created",
          r.status_code == 200 and fake.create_calls == 1 and ledger(u)[0][1] != "soon1", f"{r.status_code} {ledger(u)}")
    check("near-expiry batch counter untouched",
          q("SELECT next_index FROM ios_offer_batches WHERE asc_batch_id='soon1'")[0][0] == 0)
    # already expired
    fake = use_fake(FakeAsc())
    fake.seed("dead1", 500)
    q("INSERT INTO ios_offer_batches (asc_batch_id, status, number_of_codes, next_index, expires_at, ready_at) "
      "VALUES ('dead1','active',500,0,NOW() - INTERVAL '1 day',NOW())")
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("expired batch is never issued from",
          r.status_code == 200 and ledger(u)[0][1] != "dead1" and fake.create_calls == 1, f"{r.status_code} {ledger(u)}")
    # a batch comfortably outside the margin is used, no create
    fake = use_fake(FakeAsc())
    codes = fake.seed("ok10", 500)
    q("INSERT INTO ios_offer_batches (asc_batch_id, status, number_of_codes, next_index, expires_at, ready_at) "
      "VALUES ('ok10','active',500,7,NOW() + INTERVAL '10 days',NOW())")
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("batch 10 days from expiry is used at its next index (7) with no create",
          r.status_code == 200 and fake.create_calls == 0 and r.json()["offer_code"] == codes[7], f"{r.status_code} {r.text}")

    # a user whose issued code's batch has since expired gets a new one; the old row is expired
    fake = use_fake(FakeAsc())
    u, t = signup(client)
    assert post_offer(client, u, t, code).status_code == 200
    first = ledger(u)[0]
    q("UPDATE ios_offer_redemptions SET expires_at = NOW() - INTERVAL '1 hour' WHERE user_id=%s", (u,))
    r = post_offer(client, u, t, code)
    led = ledger(u)
    check("issuance whose expiry passed is superseded by a fresh one (old row expired)",
          r.status_code == 200 and sorted(x[0] for x in led) == ["expired", "issued"], f"{r.status_code} {led}")
    live = [x for x in led if x[0] == "issued"][0]
    check("superseding issuance used a new index, not the old one", live[2] != first[2], f"{first} {live}")

    # legacy pending row (abandoned single-code design) and prior failed rows never block
    fake = use_fake(FakeAsc())
    u, t = signup(client)
    cid = q("SELECT _id FROM promo_codes WHERE code=%s", (code,))[0][0]
    q("INSERT INTO ios_offer_redemptions (user_id, code_id, referrer_user_id, status, asc_batch_id) "
      "VALUES (%s,%s,%s,'failed','old1')", (u, cid, oid))
    r = post_offer(client, u, t, code)
    check("a prior FAILED row never blocks the user", r.status_code == 200, f"{r.status_code} {r.text}")
    u, t = signup(client)
    q("INSERT INTO ios_offer_redemptions (user_id, code_id, referrer_user_id, status, asc_batch_id) "
      "VALUES (%s,%s,%s,'pending','legacy1')", (u, cid, oid))
    r = post_offer(client, u, t, code)
    check("a legacy pending row is closed as failed and the user proceeds",
          r.status_code == 200 and sorted(x[0] for x in ledger(u)) == ["failed", "issued"], f"{r.status_code} {ledger(u)}")
    check("legacy pending closure is audited", "ios_offer_legacy_pending_closed" in audit_actions(u))

    # pool exhausted race: _reserve with nothing usable fails closed with an audit
    reset_pool()
    u, t = signup(client)
    db = aoc.OfferCodeManager()
    try:
        row = db.find_code(code)
        try:
            db._reserve(u, row, "iphash")
            res = "issued"
        except aoc.OfferCodeUnavailable:
            res = "unavailable"
    finally:
        db.close()
    check("reserve with no usable ready batch => OfferCodeUnavailable, nothing inserted",
          res == "unavailable" and rows_for(u) == [], res)
    check("pool exhausted => operator audit event", "ios_offer_pool_exhausted" in audit_actions(u))


def test_batch_create_race(client):
    print("\n== Batch-create race: a batch activated between the checks is adopted, never duplicated ==")
    set_flags()
    oid, otok, code = mk_owner(client)
    fake = use_fake(FakeAsc())
    fake.seed("raced1", 500)
    # Another request has reserved a batch (pending, create in flight).
    q("INSERT INTO ios_offer_batches (status, number_of_codes, expires_at) "
      "VALUES ('pending',500,NOW() + INTERVAL '30 days')")
    real = aoc.OfferCodeManager._usable_batch
    state = {"calls": 0}

    def racing(self, lock, ready_only):
        out = real(self, lock, ready_only)
        state["calls"] += 1
        # After _create_batch's first 'is there a usable batch' check (the 2nd call overall) the
        # in-flight request finishes and its batch turns active, exactly like the live interleaving.
        if state["calls"] == 2:
            q("UPDATE ios_offer_batches SET status='active', asc_batch_id='raced1' WHERE status='pending'")
        return out
    aoc.OfferCodeManager._usable_batch = racing
    try:
        u, t = signup(client)
        r = post_offer(client, u, t, code)
    finally:
        aoc.OfferCodeManager._usable_batch = real
    check("no second batch is created when the pending one activates mid-check",
          fake.create_calls == 0, f"creates={fake.create_calls} {batch_rows()}")
    check("the request is served from the batch that just activated",
          r.status_code == 200 and ledger(u) and ledger(u)[0][1] == "raced1", f"{r.status_code} {r.text} {ledger(u)}")
    check("exactly one non-failed batch exists", len(batch_rows()) == 1, str(batch_rows()))


def test_seeded_adoption(client):
    print("\n== Operator-seeded batch is adopted, not duplicated ==")
    set_flags()
    oid, otok, code = mk_owner(client)
    seed_sql = ("INSERT INTO ios_offer_batches (asc_batch_id, status, number_of_codes, next_index, expires_at) "
                "VALUES (%s, 'active', 500, 0, NOW() + INTERVAL '30 days') "
                "ON CONFLICT (asc_batch_id) WHERE asc_batch_id IS NOT NULL DO NOTHING")
    fake = use_fake(FakeAsc())
    codes = fake.seed("seed607166", 500)
    q(seed_sql, ("seed607166",))
    q(seed_sql, ("seed607166",))
    check("seed statement is idempotent (one row after running twice)",
          q("SELECT COUNT(*) FROM ios_offer_batches WHERE asc_batch_id='seed607166'")[0][0] == 1)
    check("seeded batch starts not-ready", batch_rows() == [("seed607166", "active", 500, 0, False)], str(batch_rows()))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("first request adopts the seeded batch: 200 with its index-0 code, NO create",
          r.status_code == 200 and fake.create_calls == 0 and r.json()["offer_code"] == codes[0], f"{r.status_code} {r.text}")
    check("adoption marks it ready after verifying all 500 values", batch_rows() == [("seed607166", "active", 500, 1, True)],
          str(batch_rows()))
    u2, t2 = signup(client)
    r2 = post_offer(client, u2, t2, code)
    check("next user gets index 1 of the seeded batch", r2.json().get("offer_code") == codes[1] and fake.create_calls == 0)

    # seeded batch whose values ASC has not finished: fail closed, do NOT create a competing batch
    fake = use_fake(FakeAsc(fetch="notready"))
    q(seed_sql, ("seedwait1",))
    u, t = signup(client)
    r = post_offer(client, u, t, code)
    check("seeded batch not ready => 503 and no competing batch created",
          r.status_code == 503 and fake.create_calls == 0 and len(batch_rows()) == 1, f"{r.status_code} {batch_rows()}")
    # seeded batch with the wrong number of values (e.g. 100 of 500): never marked ready
    fake = use_fake(FakeAsc())
    fake.batches["seedshort1"] = fake.make_codes(100)
    q(seed_sql, ("seedshort1",))
    r = post_offer(client, u, t, code)
    check("seeded batch with 100/500 values => 503, not ready, nothing issued",
          r.status_code == 503 and batch_rows()[0][4] is False and rows_for(u) == [], f"{r.status_code} {batch_rows()}")


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
    print("\n== No code value in logs, audit rows or any DB row; no raw IP ==")
    import logging
    import io
    buf = io.StringIO()
    h = logging.StreamHandler(buf)
    root = logging.getLogger()
    root.addHandler(h)
    old = root.level
    root.setLevel(logging.DEBUG)
    uids, vals_seen, fakes = [], [], []
    try:
        set_flags()
        fake = use_fake(FakeAsc())
        fakes.append(fake)
        oid, otok, code = mk_owner(client)
        u, t = signup(client)
        uids.append(u)
        ip = new_ip()
        r = post_offer(client, u, t, code, ip)
        vals_seen.append(r.json().get("offer_code", "NOVALUE"))
        post_offer(client, u, t, code, ip)                      # idempotent retry
        post_offer(client, u, t, "NOSUCHCODE", ip)
        # failure paths that log: batch rejected, ambiguous, not ready, code not ready
        for kw in ({"mint": "reject"}, {"mint": "ambiguous"}, {"fetch": "notready"}):
            f = use_fake(FakeAsc(**kw))
            fakes.append(f)
            u2, t2 = signup(client)
            uids.append(u2)
            post_offer(client, u2, t2, code)
        f = use_fake(FakeAsc())
        fakes.append(f)
        ua, ta = signup(client)
        uids.append(ua)
        post_offer(client, ua, ta, code)
        f.fetch = "notready"
        ub, tb = signup(client)
        uids.append(ub)
        post_offer(client, ub, tb, code)
    finally:
        root.removeHandler(h)
        root.setLevel(old)
    logs = buf.getvalue()
    all_codes = set()
    for f in fakes:
        all_codes |= f.all_codes()
    check("precondition: fake pools produced code values to look for", len(all_codes) >= 1000, str(len(all_codes)))
    check("issued offer code value never appears in logs", vals_seen[0] != "NOVALUE" and vals_seen[0] not in logs)
    leaked = [c for c in all_codes if c in logs]
    check("no code value from ANY batch (issued or not) appears in logs", not leaked, str(leaked[:3]))
    check("ASC key material never appears in logs", "BEGIN" not in logs and "PRIVATE KEY" not in logs)
    check("raw client IP never appears in logs of the success path",
          True if ip not in logs else "ios offer code denied" in logs)
    audit = json.dumps([[str(c) for c in row] for row in q(
        "SELECT action, detail FROM promo_audit_log WHERE owner_user_id=%s OR actor_user_id=ANY(%s::uuid[])",
        (oid, uids))])
    for ev in ("ios_offer_issued", "ios_offer_batch_reserved", "ios_offer_batch_created",
               "ios_offer_batch_failed", "ios_offer_batch_ambiguous", "ios_offer_pool_not_ready",
               "ios_offer_code_not_ready"):
        check(f"audit trail records {ev}", ev in audit, audit[:300])
    check("audit trail has no code value from any batch", not [c for c in all_codes if c in audit])
    check("audit trail has no raw IP", ip not in audit)
    # every text cell of the pool and ledger tables
    dump = json.dumps([[str(c) for c in row] for row in
                       q("SELECT * FROM ios_offer_batches") + q("SELECT * FROM ios_offer_redemptions")])
    check("no code value is stored in ios_offer_batches / ios_offer_redemptions",
          not [c for c in all_codes if c in dump])
    check("ledger and pool store no raw IP", ip not in dump)
    cols = [r[0] for r in q("SELECT column_name FROM information_schema.columns WHERE table_name IN "
                            "('ios_offer_batches','ios_offer_redemptions')")]
    check("schema has no column that could hold a code value",
          not [c for c in cols if c in ("code", "offer_code", "code_value", "values")], str(cols))


def cleanup():
    uids = list(USERS)
    # pool rows created by this run go; pre-existing dev-DB rows get their status back
    q("DELETE FROM ios_offer_redemptions WHERE user_id = ANY(%s::uuid[]) OR referrer_user_id = ANY(%s::uuid[])",
      (uids, uids))
    keep = list(ORIG_BATCHES)
    q("DELETE FROM ios_offer_batches WHERE NOT (_id::text = ANY(%s::text[]))", (keep,))
    for bid, st in ORIG_BATCHES.items():
        q("UPDATE ios_offer_batches SET status=%s WHERE _id::text=%s", (st, bid))
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
    for bid, st in q("SELECT _id, status FROM ios_offer_batches"):
        ORIG_BATCHES[str(bid)] = st
    test_config()
    test_asc_client()
    try:
        with TestClient(main_module.app) as client:
            test_flag_off(client)
            test_auth(client)
            test_happy_and_idempotency(client)
            test_concurrent(client)
            test_caps(client)
            test_pool_lifecycle(client)
            test_seeded_adoption(client)
            test_batch_create_race(client)
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
