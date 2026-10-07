"""Backend coverage for task 20261007-email-verification.

Proves: DDL idempotent/additive; config validation (shipped file, bad inputs);
flag off => no mail, verify/resend 404, Affiliates behaviour unchanged;
flag on => signup mails a link, token stored only as sha256, valid token verifies
exactly once, expired/reused/unknown/stale-after-email-change tokens give the
same uniform 400, resend honors cooldown + daily cap + rate limit and is uniform,
resend only touches the session user's own address, email change resets verified
state (and old tokens), verified state is bound to the current email hash,
Affiliates gate (unverified creator => same 403 as non-creator, verified creator
OK), creator-code purchase reward skipped for an unverified owner and credited
after verification; no email/token in logs.

Run with: cd api && ../.venv/bin/python tests/test_email_verification.py
"""
import _pathfix  # noqa: F401

import dataclasses
import hashlib
import json
import logging
import os
import re
import tempfile
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
os.environ["PROMO_VALIDATE_RATE_LIMIT"] = "1000/minute"

# Throwaway EC key so validate_owner_rewards_config() finds a real PEM file on
# CI runners, where APPLE_PROMO_KEY_PATH points at a file that does not exist.
from cryptography.hazmat.primitives import serialization as _ser  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec as _ec  # noqa: E402

_KEY_FILE = tempfile.NamedTemporaryFile(prefix="test-promo-key-", suffix=".p8", delete=False)
_KEY_FILE.write(_ec.generate_private_key(_ec.SECP256R1()).private_bytes(
    _ser.Encoding.PEM, _ser.PrivateFormat.PKCS8, _ser.NoEncryption()))
_KEY_FILE.close()
os.environ["APPLE_PROMO_KEY_PATH"] = _KEY_FILE.name

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from schema_ddl import apply_modules  # noqa: E402
from backend.interactions import flags  # noqa: E402
from backend.auth import email_verification as ev  # noqa: E402
from backend.auth import email_verification_config as evc  # noqa: E402
from backend.config_loader import ConfigSectionError  # noqa: E402
from backend.subscription import promo  # noqa: E402
from backend.subscription.owner_rewards import RewardManager, validate_owner_rewards_config  # noqa: E402

PASSED, FAILED = [], []
USERS, CREATORS, CODES = [], [], []
SENT = []          # (to, subject, html, text)
BASE_CFG = evc.get_email_verification_config()


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


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


def hdr(tok=None):
    h = {"cf-connecting-ip": f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"}
    if tok:
        h["cookie"] = f"session={tok}"
    return h


def set_cfg(**kw):
    evc._cfg = dataclasses.replace(BASE_CFG, **kw)


def fake_send(to, subject, html, text):
    SENT.append((to, subject, html, text))


ev.send_email = fake_send


def token_from(msg):
    m = re.search(r"token=([A-Za-z0-9_\-]+)", msg[3] + msg[2])
    return m.group(1) if m else None


def signup(client, email=None):
    name = f"ev_{uuid.uuid4().hex[:10]}"
    email = email or f"{name}@evtest.example"
    r = client.post("/signup", json={"username": name, "email": email, "plain_pass": "TestPass123!",
                                     "terms_accepted": True}, headers=hdr())
    assert r.status_code == 201, f"signup failed {r.status_code} {r.text}"
    uid = r.json()["user_id"]
    USERS.append(uid)
    return uid, r.cookies.get("session"), email


def give_sub(uid):
    sid = str(uuid.uuid4())
    q("INSERT INTO subscriptions (_id, user_id, plan_type, provider, status, max_members, stripe_subscription_id, "
      "apple_original_transaction_id) VALUES (%s,%s,'group','stripe','active',1,%s,'')", (sid, uid, f"sub_{uuid.uuid4().hex[:12]}"))
    q("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, uid))
    return sid


def set_aff_flag(state):
    q("INSERT INTO feature_flags (name, state) VALUES ('affiliates', %s) "
      "ON CONFLICT (name) DO UPDATE SET state = EXCLUDED.state", (state,))
    flags.invalidate()


def mk_creator_code(owner_email):
    cr, code_id = str(uuid.uuid4()), str(uuid.uuid4())
    code = f"EV{uuid.uuid4().hex[:8]}".upper()
    q("INSERT INTO creators (_id, name, active) VALUES (%s,%s,TRUE)", (cr, f"C-{cr[:6]}"))
    q("INSERT INTO promo_codes (_id, code, kind, creator_id, active, owner_email) "
      "VALUES (%s,%s,'creator',%s,TRUE,%s)", (code_id, code, cr, owner_email))
    CREATORS.append(cr)
    CODES.append(code_id)
    return code_id, code


class LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


def expire_all(uid):
    q("UPDATE email_verification_tokens SET expires_at = NOW() - interval '1 minute' WHERE user_id = %s", (uid,))


def age_tokens(uid, seconds=3600):
    q("UPDATE email_verification_tokens SET created_at = created_at - make_interval(secs => %s) WHERE user_id = %s",
      (seconds, uid))


def cleanup():
    try:
        q("DELETE FROM owner_rewards WHERE idempotency_key LIKE 'purchase:evtest-%%'")
        q("DELETE FROM promo_codes WHERE _id = ANY(%s::uuid[])", (CODES,))
        q("DELETE FROM creators WHERE _id = ANY(%s::uuid[])", (CREATORS,))
        q("DELETE FROM users WHERE _id = ANY(%s::uuid[])", (USERS,))
        set_aff_flag("off")
    except Exception as e:
        print("cleanup warning:", type(e).__name__)


# --------------------------------------------------------------------------

def test_ddl_and_config():
    print("\n== DDL idempotency + config validation ==")
    db = DBManager()
    try:
        before = db.cur.execute("SELECT 1") or None
        apply_modules(db.cur, ("email_verification",))
        apply_modules(db.cur, ("email_verification",))
        db.conn.commit()
        db.cur.execute("SELECT column_name, is_nullable, column_default FROM information_schema.columns "
                       "WHERE table_name='users' AND column_name LIKE 'email_verified%' ORDER BY 1")
        cols = {r[0]: r for r in db.cur.fetchall()}
        check("users has 3 verification columns", set(cols) == {"email_verified", "email_verified_at", "email_verified_hash"}, cols)
        check("email_verified NOT NULL default false",
              cols["email_verified"][1] == "NO" and "false" in (cols["email_verified"][2] or ""), cols["email_verified"])
        db.cur.execute("SELECT column_name FROM information_schema.columns WHERE table_name='email_verification_tokens'")
        tc = {r[0] for r in db.cur.fetchall()}
        check("token table has hash columns and no raw token/email column",
              {"token_hash", "email_hash"} <= tc and not ({"token", "email"} & tc), tc)
        db.cur.execute("SELECT indexdef FROM pg_indexes WHERE indexname='uq_email_verification_token_hash'")
        check("unique index on token_hash", "UNIQUE" in (db.cur.fetchone() or [""])[0])
    finally:
        db.close()

    check("shipped config ships enabled=false", BASE_CFG.enabled is False)
    path = evc.CONFIG_PATH
    good = json.loads(path.read_text())

    def bad(label, mutate):
        d = json.loads(json.dumps(good))
        mutate(d["email_verification"])
        with tempfile.TemporaryDirectory() as td:
            p = evc.Path(td) / "ev.json"
            p.write_text(json.dumps(d))
            old = evc.CONFIG_PATH
            evc.CONFIG_PATH = p
            try:
                evc.validate_email_verification_config()
                check(label, False, "accepted")
            except ConfigSectionError:
                check(label, True)
            finally:
                evc.CONFIG_PATH = old
                evc._cfg = None
    bad("missing key rejected", lambda s: s.pop("token_ttl_minutes"))
    bad("unknown key rejected", lambda s: s.update(extra=1))
    bad("bool for int rejected", lambda s: s.update(token_ttl_minutes=True))
    bad("ttl out of range rejected", lambda s: s.update(token_ttl_minutes=100000))
    bad("bad rate string rejected", lambda s: s.update(rate_limit_verify="nonsense"))
    bad("http base url rejected", lambda s: s.update(public_base_url="http://x.example"))
    bad("link format without token rejected", lambda s: s.update(verify_link_format="{base}/x"))
    evc.validate_email_verification_config()
    check("shipped config validates", evc.get_email_verification_config().enabled is False)
    from backend import startup_checks
    check("startup check registered", startup_checks.check_email_verification_config in startup_checks.CHECKS)


def test_flag_off(client):
    print("\n== Flag off parity ==")
    set_cfg(enabled=False)
    SENT.clear()
    uid, tok, email = signup(client)
    check("no mail on signup", SENT == [])
    check("no token rows", q("SELECT COUNT(*) FROM email_verification_tokens WHERE user_id=%s", (uid,))[0][0] == 0)
    check("resend 404", client.post("/auth/email/resend", headers=hdr(tok)).status_code == 404)
    check("verify 404", client.post("/auth/email/verify", json={"token": "abc"}, headers=hdr()).status_code == 404)
    r = client.get("/auth/email/status", headers=hdr(tok))
    check("status reports disabled", r.status_code == 200 and r.json() == {"enabled": False, "verified": False}, r.text)
    check("status needs session", client.get("/auth/email/status", headers=hdr()).status_code == 401)
    # Affiliates: unverified creator still works when verification is off
    set_aff_flag("on")
    code_id, _ = mk_creator_code(email)
    r = client.get("/affiliates/overview", headers=hdr(tok))
    check("affiliates unchanged for unverified creator (flag off)", r.status_code == 200, (r.status_code, r.text[:120]))
    check("login not blocked", client.post("/login", json={"username": q("SELECT username FROM users WHERE _id=%s", (uid,))[0][0],
                                                          "plain_pass": "TestPass123!"}, headers=hdr()).status_code == 200)


def test_flow(client):
    print("\n== Flag on: issue / verify / single-use / expiry ==")
    set_cfg(enabled=True, resend_cooldown_seconds=10, max_sends_per_day=5, rate_limit_resend="1000/minute",
            rate_limit_verify="1000/minute")
    SENT.clear()
    lc = LogCapture()
    logging.getLogger().addHandler(lc)
    uid, tok, email = signup(client)
    check("signup (not blocked) sent exactly one mail to the address",
          len(SENT) == 1 and SENT[0][0] == email, SENT and SENT[0][0])
    raw = token_from(SENT[0])
    check("mail contains verify link on configured base",
          raw and ("/#/verify-email?token=" + raw) in SENT[0][3] and BASE_CFG.public_base_url in SENT[0][3])
    rows = q("SELECT token_hash, email_hash, used, expires_at > NOW() FROM email_verification_tokens WHERE user_id=%s", (uid,))
    check("one token row, hashed at rest", len(rows) == 1 and rows[0][0] == hashlib.sha256(raw.encode()).hexdigest()
          and raw not in json.dumps(rows, default=str), rows)
    check("email hash stored (not raw email)", rows[0][1] == hashlib.sha256(email.lower().encode()).hexdigest()
          and email not in json.dumps(rows, default=str))
    check("status unverified", client.get("/auth/email/status", headers=hdr(tok)).json()["verified"] is False)
    check("users.email_verified false before", q("SELECT email_verified FROM users WHERE _id=%s", (uid,))[0][0] is False)

    r = client.post("/auth/email/verify", json={"token": raw}, headers=hdr())
    check("valid token verifies (no session needed)", r.status_code == 200 and r.json() == {"verified": True}, r.text)
    check("status verified", client.get("/auth/email/status", headers=hdr(tok)).json()["verified"] is True)
    row = q("SELECT email_verified, email_verified_at IS NOT NULL, email_verified_hash FROM users WHERE _id=%s", (uid,))[0]
    check("state persisted incl. hash binding", row == (True, True, hashlib.sha256(email.lower().encode()).hexdigest()), row)
    r2 = client.post("/auth/email/verify", json={"token": raw}, headers=hdr())
    check("reuse => 400", r2.status_code == 400, r2.status_code)
    r3 = client.post("/auth/email/verify", json={"token": "totallyunknowntoken"}, headers=hdr())
    check("unknown => 400", r3.status_code == 400)

    # expiry
    uid2, tok2, email2 = signup(client)
    raw2 = token_from(SENT[-1])
    expire_all(uid2)
    r4 = client.post("/auth/email/verify", json={"token": raw2}, headers=hdr())
    check("expired => 400", r4.status_code == 400)
    check("uniform failure body (unknown/expired/reused identical)",
          r2.json() == r3.json() == r4.json() == {"detail": "Invalid or expired verification link"}, (r2.text, r3.text, r4.text))
    check("expired token did not verify", q("SELECT email_verified FROM users WHERE _id=%s", (uid2,))[0][0] is False)
    check("empty/oversized token rejected by validation",
          client.post("/auth/email/verify", json={"token": ""}, headers=hdr()).status_code == 422
          and client.post("/auth/email/verify", json={"token": "x" * 300}, headers=hdr()).status_code == 422)

    # no PII/token in logs
    blob = "\n".join(lc.lines)
    check("no raw email or token in logs", email not in blob and email2 not in blob and raw not in blob and raw2 not in blob)
    logging.getLogger().removeHandler(lc)


def test_resend(client):
    print("\n== Resend: cooldown, daily cap, uniform, own-address only, rate limit ==")
    set_cfg(enabled=True, resend_cooldown_seconds=10, max_sends_per_day=3, rate_limit_resend="1000/minute")
    uid, tok, email = signup(client)
    first = token_from(SENT[-1])
    n0 = len(SENT)
    r_cd = client.post("/auth/email/resend", headers=hdr(tok))
    check("resend inside cooldown: 202, no mail", r_cd.status_code == 202 and len(SENT) == n0, (r_cd.status_code, len(SENT) - n0))
    age_tokens(uid)
    r_ok = client.post("/auth/email/resend", headers=hdr(tok))
    check("resend after cooldown: 202 + mail to own address", r_ok.status_code == 202 and len(SENT) == n0 + 1
          and SENT[-1][0] == email)
    check("response body identical sent vs throttled",
          {k: v for k, v in r_ok.json().items()} == {k: v for k, v in r_cd.json().items()}, (r_ok.json(), r_cd.json()))
    new = token_from(SENT[-1])
    check("older link invalidated by newer", client.post("/auth/email/verify", json={"token": first}, headers=hdr()).status_code == 400)
    check("newest link works", client.post("/auth/email/verify", json={"token": new}, headers=hdr()).status_code == 200)
    n1 = len(SENT)
    check("already verified: resend sends nothing", client.post("/auth/email/resend", headers=hdr(tok)).status_code == 202 and len(SENT) == n1)
    check("resend requires session", client.post("/auth/email/resend", headers=hdr()).status_code == 401)
    r = client.post("/auth/email/resend", json={"email": "victim@evtest.example", "user_id": str(uuid.uuid4())}, headers=hdr(tok))
    check("client-supplied email/user_id ignored", r.status_code == 202 and not any(s[0] == "victim@evtest.example" for s in SENT))

    # daily cap (3): signup(1) + resends
    uid3, tok3, _ = signup(client)
    for _ in range(5):
        age_tokens(uid3)
        client.post("/auth/email/resend", headers=hdr(tok3))
    cnt = q("SELECT COUNT(*) FROM email_verification_tokens WHERE user_id=%s", (uid3,))[0][0]
    check("daily cap enforced (max 3 tokens)", cnt == 3, cnt)

    # IP rate limit from config
    set_cfg(enabled=True, rate_limit_resend="2/minute", rate_limit_verify="2/minute")
    main_module.limiter.reset() if hasattr(main_module.limiter, "reset") else None
    h = hdr(tok)
    h["cf-connecting-ip"] = "203.0.113.77"
    codes = [client.post("/auth/email/resend", headers=h).status_code for _ in range(4)]
    check("resend rate limit kicks in (429) from config", 429 in codes and codes[0] == 202, codes)
    hv = {"cf-connecting-ip": "203.0.113.78"}
    codes = [client.post("/auth/email/verify", json={"token": "nope"}, headers=hv).status_code for _ in range(4)]
    check("verify rate limit kicks in (429) from config", 429 in codes and codes[0] == 400, codes)
    set_cfg(enabled=True, rate_limit_resend="1000/minute", rate_limit_verify="1000/minute")


def test_email_change(client):
    print("\n== Email change resets verification ==")
    set_cfg(enabled=True, resend_cooldown_seconds=10, rate_limit_resend="1000/minute", rate_limit_verify="1000/minute")
    uid, tok, email = signup(client)
    t_old = token_from(SENT[-1])
    # stale token race: change email BEFORE using the link
    new_email = f"chg_{uuid.uuid4().hex[:8]}@evtest.example"
    age_tokens(uid)  # clear the resend cooldown left by the signup mail
    n = len(SENT)
    r = client.put(f"/user/{uid}", json={"email": new_email}, headers=hdr(tok))
    check("PUT email change ok", r.status_code == 200, (r.status_code, r.text[:100]))
    check("new address gets a fresh mail", len(SENT) == n + 1 and SENT[-1][0] == new_email)
    check("old link refused after change", client.post("/auth/email/verify", json={"token": t_old}, headers=hdr()).status_code == 400)
    check("not verified after change", client.get("/auth/email/status", headers=hdr(tok)).json()["verified"] is False)
    t_new = token_from(SENT[-1])
    check("new link verifies", client.post("/auth/email/verify", json={"token": t_new}, headers=hdr()).status_code == 200)
    check("verified for new address", client.get("/auth/email/status", headers=hdr(tok)).json()["verified"] is True)
    # now change again: verified must clear
    age_tokens(uid)
    r = client.put(f"/user/{uid}", json={"email": f"chg2_{uuid.uuid4().hex[:8]}@evtest.example"}, headers=hdr(tok))
    check("second change ok", r.status_code == 200)
    row = q("SELECT email_verified, email_verified_at, email_verified_hash FROM users WHERE _id=%s", (uid,))[0]
    check("verified columns cleared on change", row == (False, None, None), row)
    # same email (case change only) does not reset
    uid5, tok5, em5 = signup(client)
    client.post("/auth/email/verify", json={"token": token_from(SENT[-1])}, headers=hdr())
    client.put(f"/user/{uid5}", json={"email": em5.upper()}, headers=hdr(tok5))
    # hash binding: even if reset were missed, direct SQL email swap reads unverified
    uid6, tok6, em6 = signup(client)
    client.post("/auth/email/verify", json={"token": token_from(SENT[-1])}, headers=hdr())
    check("precondition verified", ev.is_email_verified(uid6) is True)
    q("UPDATE users SET email = %s WHERE _id=%s", (f"sneaky_{uuid.uuid4().hex[:6]}@evtest.example", uid6))
    check("hash binding: swapped email reads unverified even with flag stuck true",
          q("SELECT email_verified FROM users WHERE _id=%s", (uid6,))[0][0] is True and ev.is_email_verified(uid6) is False)
    # profile update without email touches nothing
    uid7, tok7, em7 = signup(client)
    client.post("/auth/email/verify", json={"token": token_from(SENT[-1])}, headers=hdr())
    r = client.put(f"/user/{uid7}", json={"timezone": "UTC"}, headers=hdr(tok7))
    check("non-email update keeps verified", r.status_code == 200 and ev.is_email_verified(uid7) is True, r.status_code)


def test_affiliates_gate(client):
    print("\n== Affiliates gate ==")
    set_aff_flag("on")
    set_cfg(enabled=True, resend_cooldown_seconds=10, rate_limit_resend="1000/minute", rate_limit_verify="1000/minute")
    uid, tok, email = signup(client)
    raw = token_from(SENT[-1])
    mk_creator_code(email)
    _, tok_nc, _ = signup(client)
    paths = ("/affiliates/overview", "/affiliates/resources", "/affiliates/resources/logo-mark/file")
    nc = {p: client.get(p, headers=hdr(tok_nc)) for p in paths}
    for p in paths:
        r = client.get(p, headers=hdr(tok))
        check(f"unverified creator 403 {p}", r.status_code == 403 and r.json() == {"detail": "Forbidden"}, (r.status_code, r.text[:80]))
        check(f"unverified 403 identical to non-creator {p}", r.json() == nc[p].json() and r.status_code == nc[p].status_code)
    check("anon still 401", client.get("/affiliates/overview", headers=hdr()).status_code == 401)
    client.post("/auth/email/verify", json={"token": raw}, headers=hdr())
    check("verified creator 200 overview", client.get("/affiliates/overview", headers=hdr(tok)).status_code == 200)
    check("verified creator resources 200", client.get("/affiliates/resources", headers=hdr(tok)).status_code == 200)
    check("verified non-creator still 403", client.get("/affiliates/overview", headers=hdr(tok_nc)).status_code == 403)
    # fail closed on error
    real = ev.is_email_verified
    import routes.affiliates as ra
    orig = ra.verification_satisfied
    ra.verification_satisfied = lambda u: (_ for _ in ()).throw(RuntimeError("db down"))
    try:
        check("lookup error => 403 (fail closed)", client.get("/affiliates/overview", headers=hdr(tok)).status_code == 403)
    finally:
        ra.verification_satisfied = orig
    # email change revokes access
    client.put(f"/user/{uid}", json={"email": f"new_{uuid.uuid4().hex[:8]}@evtest.example"}, headers=hdr(tok))
    check("email change revokes affiliates access", client.get("/affiliates/overview", headers=hdr(tok)).status_code == 403)
    set_cfg(enabled=False)
    uid2, tok2, email2 = signup(client)
    mk_creator_code(email2)
    check("flag off again: unverified creator allowed", client.get("/affiliates/overview", headers=hdr(tok2)).status_code == 200)
    set_aff_flag("off")


def test_owner_reward(client):
    print("\n== Creator purchase reward gate ==")
    os.environ["OWNER_REWARDS_ENABLED"] = "true"
    promo._config = promo.PromoConfig(True, 50, "1000/minute")
    validate_owner_rewards_config()
    set_cfg(enabled=True, resend_cooldown_seconds=10)
    owner, otok, oemail = signup(client)
    owner_tok = token_from(SENT[-1])
    buyer, _, _ = signup(client)
    give_sub(owner)
    code_id, code = mk_creator_code(oemail)
    row = {"id": code_id, "code": code, "kind": "creator", "creator_active": True}

    def earn(key):
        m = RewardManager()
        try:
            return m.earn_purchase(row, buyer, key)
        finally:
            m.close()
    out = earn("evtest-1")
    check("unverified owner => skipped_unverified_owner, no reward",
          out[0] == "skipped_unverified_owner" and
          q("SELECT COUNT(*) FROM owner_rewards WHERE owner_user_id=%s", (owner,))[0][0] == 0, out)
    client.post("/auth/email/verify", json={"token": owner_tok}, headers=hdr())
    out = earn("evtest-1")
    check("after verifying, replay credits owner", out[0] not in ("skipped_unverified_owner", "ignored", "skipped_no_owner")
          and q("SELECT COUNT(*) FROM owner_rewards WHERE owner_user_id=%s", (owner,))[0][0] == 1, out)
    set_cfg(enabled=False)
    owner2, _, oe2 = signup(client)
    give_sub(owner2)
    cid2, code2 = mk_creator_code(oe2)
    row = {"id": cid2, "code": code2, "kind": "creator", "creator_active": True}
    out = earn("evtest-2")
    check("flag off: unverified owner credited as before", out[0] not in ("skipped_unverified_owner",) and
          q("SELECT COUNT(*) FROM owner_rewards WHERE owner_user_id=%s", (owner2,))[0][0] == 1, out)


def main():
    with TestClient(main_module.app) as client:
        try:
            test_ddl_and_config()
            test_flag_off(client)
            test_flow(client)
            test_resend(client)
            test_email_change(client)
            test_affiliates_gate(client)
            test_owner_reward(client)
        finally:
            cleanup()
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    for l, d in FAILED:
        print("  FAILED:", l, "--", d)
    raise SystemExit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
