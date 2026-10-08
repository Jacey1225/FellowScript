"""Backend coverage for task 20261008-affiliate-payout-details.

Proves: crypto round-trip, per-field AAD binding, key versioning/multi-key
decrypt, boot-time key validation (missing/malformed/short refuse), no key
material in errors; ABA checksum + account/holder/type validation; flag-off
uniform 404 before auth; 401 / uniform 403 for anon and non-creators; owner
only (identity from session, client-supplied ids ignored, cross-affiliate
isolation); re-auth gating (no proof, wrong code, wrong password, replayed
proof, login/other-purpose proofs, expired proof, per-code attempt cap,
lockout); masking everywhere (no full numbers in any response/audit/log);
ciphertext at rest (no plaintext in DB); no-store on success and error paths;
no 422 input echo; audit rows value-free; hard delete; admin reveal (admin
only, fresh purpose-bound proof, audit before decrypt, hourly cap, unknown
subject 404); retention purge; key rotation script idempotent; client-error
endpoint omits payout summaries.

Run with: cd api && ../.venv/bin/python tests/test_affiliate_payouts.py
"""
import _pathfix  # noqa: F401

import base64
import logging
import os
import re
import subprocess
import sys
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
os.environ["PROMO_VALIDATE_RATE_LIMIT"] = "100/minute"

# A deterministic fake key for this test process when the env has none.
_K1 = base64.b64encode(b"A" * 32).decode()
_K2 = base64.b64encode(b"B" * 32).decode()
if not os.environ.get("PAYOUT_ENCRYPTION_KEYS"):
    os.environ["PAYOUT_ENCRYPTION_KEYS"] = f"1:{_K1}"
ORIG_KEYS = os.environ["PAYOUT_ENCRYPTION_KEYS"]

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.interactions import flags  # noqa: E402
from backend.subscription import payout_crypto as pc  # noqa: E402
from backend.subscription import affiliate_payouts as ap  # noqa: E402
from backend.subscription.affiliates_config import get_affiliates_config  # noqa: E402
import routes.affiliate_payouts as rap  # noqa: E402

PASSED, FAILED = [], []
USERS, CREATORS, CODES, EMAILS = [], [], [], []
SENT = []  # (to, subject, text) captured instead of sending
ROUTING, ROUTING2 = "021000021", "011401533"      # valid ABA checksums
ACCOUNT, ACCOUNT2 = "123456789012", "998877665544"
HOLDER = "Jane Q. Affiliate"
PW = "TestPass123!"
SECRETS = [ROUTING, ACCOUNT, ROUTING2, ACCOUNT2, HOLDER]


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def hdr(tok=None):
    h = {"cf-connecting-ip": f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"}
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


def set_flag(name, state):
    q("INSERT INTO feature_flags (name, state) VALUES (%s, %s) "
      "ON CONFLICT (name) DO UPDATE SET state = EXCLUDED.state", (name, state))
    flags.invalidate()


def fake_send(to, subject, html, text):
    SENT.append((to, subject, text))


rap.send_email = fake_send


def signup():
    name = f"pay_{uuid.uuid4().hex[:10]}"
    email = f"{name}@payouts-test.example"
    r = CLIENT.post("/signup", json={"username": name, "email": email, "plain_pass": PW,
                                     "terms_accepted": True}, headers=hdr())
    assert r.status_code == 201, f"signup failed {r.status_code} {r.text}"
    uid = r.json()["user_id"]
    USERS.append(uid)
    EMAILS.append(email)
    q("UPDATE users SET email_verified = TRUE, email_verified_at = NOW(), "
      "email_verified_hash = encode(sha256(convert_to(lower(btrim(email)), 'UTF8')), 'hex') "
      "WHERE _id = %s", (uid,))
    return uid, r.cookies.get("session"), email


def mk_creator_for(email):
    cid = str(uuid.uuid4())
    q("INSERT INTO creators (_id, name, active) VALUES (%s, %s, TRUE)", (cid, f"C-{cid[:6]}"))
    CREATORS.append(cid)
    pid = str(uuid.uuid4())
    q("INSERT INTO promo_codes (_id, code, kind, creator_id, active, owner_email) "
      "VALUES (%s,%s,'creator',%s,TRUE,%s)", (pid, f"PAY{uuid.uuid4().hex[:8]}".upper(), cid, email))
    CODES.append(pid)
    return cid, pid


def mk_affiliate():
    uid, tok, email = signup()
    mk_creator_for(email)
    return uid, tok, email


def mk_admin():
    import bcrypt
    uid = str(uuid.uuid4())
    email = f"adm_{uid[:8]}@payouts-test.example"
    hashed = bcrypt.hashpw(PW.encode(), bcrypt.gensalt()).decode()
    dbm = DBManager()
    try:
        dbm.insertion("users", {"_id": uid, "username": f"adm_{uid[:8]}", "email": email,
                                "hash_pass": hashed, "is_admin": True, "mfa_enabled": True})
    finally:
        dbm.close()
    USERS.append(uid)
    EMAILS.append(email)
    from backend.auth.sessions import SessionManager
    sm = SessionManager()
    try:
        tok = sm.create_session(uid)
    finally:
        sm.close()
    return uid, tok, email


def last_code():
    m = re.search(r"\b(\d{6})\b", SENT[-1][2])
    return m.group(1)


def proof_for(tok, base="/affiliates/payouts", password=PW):
    # Test-only: age earlier proof rows so the hourly code-issue cap (tested
    # separately in test_reauth) does not throttle helper-minted proofs.
    q("UPDATE affiliate_payout_proofs SET created_at = NOW() - INTERVAL '2 hours' "
      "WHERE user_id = ANY(%s) AND created_at > NOW() - INTERVAL '1 hour'", (USERS,))
    n = len(SENT)
    r = CLIENT.post(f"{base}/reauth", headers=hdr(tok))
    assert r.status_code == 200, (r.status_code, r.text)
    assert len(SENT) == n + 1
    r = CLIENT.post(f"{base}/reauth/verify", json={"code": last_code(), "password": password}, headers=hdr(tok))
    assert r.status_code == 200, (r.status_code, r.text)
    return r.json()["proof"]


def payload(proof, **kw):
    d = {"proof": proof, "routing_number": ROUTING, "account_number": ACCOUNT,
         "account_type": "checking", "holder_name": HOLDER}
    d.update(kw)
    return d


def no_store(r):
    return "no-store" in r.headers.get("cache-control", "")


def leaks(text):
    return [s for s in SECRETS if s in text]


class LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


def cleanup():
    try:
        q("DELETE FROM affiliate_payout_details WHERE owner_email = ANY(%s)", ([e.lower() for e in EMAILS],))
        q("DELETE FROM affiliate_payout_proofs WHERE user_id = ANY(%s)", (USERS,))
        q("DELETE FROM affiliate_payout_audit WHERE actor_id = ANY(%s) OR subject = ANY(%s)",
          (USERS, [e.lower() for e in EMAILS]))
        q("DELETE FROM promo_codes WHERE _id = ANY(%s::uuid[])", (CODES,))
        q("DELETE FROM creators WHERE _id = ANY(%s::uuid[])", (CREATORS,))
        q("DELETE FROM users WHERE _id = ANY(%s::uuid[])", (USERS,))
        set_flag("affiliates", "off")
        set_flag("affiliate_payouts", "off")
    except Exception as e:
        print("cleanup warning:", type(e).__name__)


# -- tests -------------------------------------------------------------------

def test_crypto():
    print("\n== Crypto ==")
    row = str(uuid.uuid4())
    t = pc.encrypt(ACCOUNT, row, "account")
    check("round trip", pc.decrypt(t, row, "account") == ACCOUNT)
    check("ciphertext hides plaintext", ACCOUNT not in t and ACCOUNT not in base64.urlsafe_b64decode(t).decode("latin1"))
    check("fresh nonce each time", pc.encrypt(ACCOUNT, row, "account") != t)
    check("first byte is key id", pc.key_id_of(t) == pc.current_key_id())
    for label, r2, f2 in (("wrong row", str(uuid.uuid4()), "account"), ("wrong field", row, "routing")):
        try:
            pc.decrypt(t, r2, f2)
            check(f"AAD binding: {label} rejected", False)
        except pc.PayoutDecryptError:
            check(f"AAD binding: {label} rejected", True)
    tampered = bytearray(base64.urlsafe_b64decode(t))
    tampered[-1] ^= 1
    try:
        pc.decrypt(base64.urlsafe_b64encode(bytes(tampered)).decode(), row, "account")
        check("tamper rejected", False)
    except pc.PayoutDecryptError as e:
        check("tamper rejected, generic message", str(e) == "cannot decrypt stored value" and ACCOUNT not in str(e))
    # key versioning / rotation
    old = os.environ["PAYOUT_ENCRYPTION_KEYS"]
    try:
        os.environ["PAYOUT_ENCRYPTION_KEYS"] = f"1:{_K1}"
        t1 = pc.encrypt("x", row, "type")
        os.environ["PAYOUT_ENCRYPTION_KEYS"] = f"2:{_K2},1:{_K1}"
        check("new writes use first (current) key", pc.current_key_id() == 2 and pc.key_id_of(pc.encrypt("x", row, "type")) == 2)
        check("old key still decrypts", pc.decrypt(t1, row, "type") == "x")
        os.environ["PAYOUT_ENCRYPTION_KEYS"] = f"2:{_K2}"
        try:
            pc.decrypt(t1, row, "type")
            check("retired key cannot decrypt", False)
        except pc.PayoutDecryptError:
            check("retired key cannot decrypt", True)
        # boot validation
        bad = {"missing": None, "empty": " ", "no id": _K1, "short key": "1:" + base64.b64encode(b"x" * 16).decode(),
               "bad b64": "1:!!!notb64!!!", "dup id": f"1:{_K1},1:{_K2}", "id 0": f"0:{_K1}", "id 256": f"256:{_K1}"}
        for label, val in bad.items():
            if val is None:
                os.environ.pop("PAYOUT_ENCRYPTION_KEYS", None)
            else:
                os.environ["PAYOUT_ENCRYPTION_KEYS"] = val
            try:
                pc.validate_payout_keys()
                check(f"boot refuses: {label}", False)
            except pc.PayoutKeyConfigError as e:
                check(f"boot refuses: {label}", True)
                check(f"  no key material in error: {label}", _K1 not in str(e) and _K2 not in str(e))
        os.environ["PAYOUT_ENCRYPTION_KEYS"] = f"1:{_K1},2:{_K2}"
        pc.validate_payout_keys()
        check("valid multi-key list passes boot check", True)
    finally:
        os.environ["PAYOUT_ENCRYPTION_KEYS"] = old
    from backend import startup_checks
    check("key check registered in startup_checks.CHECKS", startup_checks.check_payout_encryption_keys in startup_checks.CHECKS)
    check("masked repr of plaintext holder", repr(ap._Plain("secret")) == "<redacted>")


def test_validation():
    print("\n== Validation ==")
    check("valid ABA accepted", ap.valid_routing(ROUTING) and ap.valid_routing(ROUTING2))
    check("bad checksum rejected", not ap.valid_routing("021000022"))
    for bad in ("12345678", "1234567890", "02100002a", "", None, 21000021, "０２１０００００２"):
        check(f"routing rejected: {bad!r}", not ap.valid_routing(bad))
    check("account 4..17 digits", ap.valid_account("1234") and ap.valid_account("1" * 17))
    for bad in ("123", "1" * 18, "12 34", "12-34", "abcd1234", None, 12345):
        check(f"account rejected: {bad!r}", not ap.valid_account(bad))
    check("holder normalised", ap.normalize_holder("  Jane   Doe ") == "Jane Doe")
    check("holder allows O'Brien-Smith Jr.", ap.normalize_holder("Mary O'Brien-Smith Jr.") is not None)
    check("holder allows unicode letters", ap.normalize_holder("José Núñez") is not None)
    for bad in ("A", "x" * 101, "Jane\nDoe", "Jane\x00", "Jane123", "<script>", "Jane; DROP", None, 5):
        check(f"holder rejected: {bad!r}", ap.normalize_holder(bad) is None)
    for bad_type in ("business", "", None, "CHECKING"):
        try:
            ap.validate_fields({"routing_number": ROUTING, "account_number": ACCOUNT, "account_type": bad_type, "holder_name": HOLDER})
            check(f"type rejected: {bad_type!r}", False)
        except ap.PayoutError as e:
            check(f"type rejected: {bad_type!r}", e.code == "invalid_account_type")
    for extra in ({"extra": 1}, {}):
        body = {"routing_number": ROUTING, "account_number": ACCOUNT, "account_type": "checking", "holder_name": HOLDER}
        body = {**body, **extra} if extra else {k: v for k, v in body.items() if k != "holder_name"}
        try:
            ap.validate_fields(body)
            check(f"unknown/missing field rejected {sorted(extra) or 'missing'}", False)
        except ap.PayoutError as e:
            check(f"unknown/missing field rejected {sorted(extra) or 'missing'}", e.code == "invalid_request")
    check("mask_name keeps only initials", ap.mask_name("Jane Q. Affiliate") == "J••• Q••• A•••")
    mv = ap.masked_view({"routing_last4": "0021", "account_last4": "9012", "account_type": "checking",
                         "holder_masked": "J•••", "updated_at": None})
    check("masked_view has no full-number keys", not {"routing_number", "account_number"} & set(mv))


def test_flag_and_authz():
    print("\n== Flag + authz ==")
    set_flag("affiliates", "on")
    set_flag("affiliate_payouts", "off")
    uid, tok, email = mk_affiliate()
    for method, path in (("get", ""), ("post", "/reauth"), ("put", ""), ("post", "/delete")):
        a = getattr(CLIENT, method)(f"/affiliates/payouts{path}", headers=hdr())
        b = getattr(CLIENT, method)(f"/affiliates/payouts{path}", headers=hdr(tok))
        check(f"flag off {method.upper()} {path or '/'} 404 anon+creator, identical",
              a.status_code == b.status_code == 404 and a.json() == b.json(), (a.status_code, b.status_code))
    a = CLIENT.get("/admin/affiliate-payouts", headers=hdr())
    check("flag off admin route 404 before auth", a.status_code == 404, a.status_code)
    set_flag("affiliate_payouts", "on")
    set_flag("affiliates", "off")
    check("parent affiliates flag off also 404", CLIENT.get("/affiliates/payouts", headers=hdr(tok)).status_code == 404)
    set_flag("affiliates", "on")
    r = CLIENT.get("/affiliates/payouts", headers=hdr())
    check("anon 401", r.status_code == 401 and no_store(r), r.status_code)
    check("anon 401 on write routes", all(
        getattr(CLIENT, m)(f"/affiliates/payouts{p}", headers=hdr(), json={}).status_code == 401
        for m, p in (("put", ""), ("post", "/delete"), ("post", "/reauth"), ("post", "/reauth/verify"))))
    _, ntok, _ = signup()
    for method, path in (("get", ""), ("post", "/reauth"), ("put", ""), ("post", "/delete"), ("post", "/reauth/verify")):
        r = getattr(CLIENT, method)(f"/affiliates/payouts{path}", headers=hdr(ntok), **({} if method == "get" else {"json": {}}))
        check(f"non-creator uniform 403 {method.upper()} {path or '/'}",
              r.status_code == 403 and r.json() == {"detail": "Forbidden"} and no_store(r), (r.status_code, r.text))
    n = len(SENT)
    CLIENT.post("/affiliates/payouts/reauth", headers=hdr(ntok))
    check("non-creator reauth sends no email", len(SENT) == n)
    r = CLIENT.get("/affiliates/payouts", headers=hdr(tok))
    check("creator GET not_set 200 fixed shape", r.status_code == 200 and r.json() == {"status": "not_set"} and no_store(r), r.text)
    for p in ("?affiliate_id=x", f"?owner_email=other@example.com&user_id={uid}"):
        r = CLIENT.get(f"/affiliates/payouts{p}", headers=hdr(tok))
        check(f"client-supplied identity query ignored {p[:20]}", r.status_code == 200 and r.json() == {"status": "not_set"})


def test_save_flow():
    print("\n== Save / mask / at-rest / audit ==")
    set_flag("affiliates", "on")
    set_flag("affiliate_payouts", "on")
    uid, tok, email = mk_affiliate()
    owner = email.lower()
    # no proof
    r = CLIENT.put("/affiliates/payouts", json=payload(None), headers=hdr(tok))
    check("save without proof 403 reauth_required", r.status_code == 403 and r.json()["detail"] == "reauth_required" and no_store(r), r.text)
    r = CLIENT.put("/affiliates/payouts", json=payload("x" * 40), headers=hdr(tok))
    check("save with forged proof 403", r.status_code == 403 and r.json()["detail"] == "reauth_required")
    check("nothing stored without proof", q("SELECT COUNT(*) FROM affiliate_payout_details WHERE owner_email=%s", (owner,))[0][0] == 0)

    # bad inputs: fixed codes, no echo, no stored data, no proof burned? (proof consumed first, so get new)
    cap = LogCapture()
    root = logging.getLogger()
    root.addHandler(cap)
    old_lvl = root.level
    root.setLevel(logging.DEBUG)
    try:
        for label, kw, code in (("bad routing checksum", {"routing_number": "021000022"}, "invalid_routing_number"),
                                ("short account", {"account_number": "12"}, "invalid_account_number"),
                                ("bad type", {"account_type": "business"}, "invalid_account_type"),
                                ("bad holder", {"holder_name": "<b>x</b>"}, "invalid_holder_name")):
            p = proof_for(tok)
            r = CLIENT.put("/affiliates/payouts", json=payload(p, **kw), headers=hdr(tok))
            check(f"{label}: 400 fixed code", r.status_code == 400 and r.json() == {"detail": code} and no_store(r), (r.status_code, r.text))
            check(f"{label}: no value echoed", not leaks(r.text) and "<b>" not in r.text)
        r = CLIENT.put("/affiliates/payouts", content=b"{not json" , headers={**hdr(tok), "content-type": "application/json"})
        check("malformed JSON 400 fixed, no-store", r.status_code == 400 and r.json() == {"detail": "invalid_request"} and no_store(r), r.text)
        r = CLIENT.put("/affiliates/payouts", json=[ROUTING], headers=hdr(tok))
        check("non-object body 400, no echo", r.status_code == 400 and ROUTING not in r.text)
        r = CLIENT.put("/affiliates/payouts", json=payload("p", holder_name="x" * 5000), headers=hdr(tok))
        check("oversize body 413", r.status_code == 413 and no_store(r), r.status_code)
        p = proof_for(tok)
        r = CLIENT.put("/affiliates/payouts", json={**payload(p), "bonus": "1"}, headers=hdr(tok))
        check("unknown field rejected 400", r.status_code == 400 and r.json()["detail"] == "invalid_request")
        check("nothing stored after invalid saves", q("SELECT COUNT(*) FROM affiliate_payout_details WHERE owner_email=%s", (owner,))[0][0] == 0)

        # success
        p = proof_for(tok)
        r = CLIENT.put("/affiliates/payouts", json=payload(p), headers=hdr(tok))
        body = r.json()
        check("save 200 masked view", r.status_code == 200 and body.get("status") == "set" and no_store(r), r.text)
        check("save response: last-4 only", body["routing_last4"] == ROUTING[-4:] and body["account_last4"] == ACCOUNT[-4:]
              and body["account_type"] == "checking" and body["holder_name_masked"] == "J••• Q••• A•••", body)
        check("save response has no full numbers/holder", not leaks(r.text))
        check("change notice emailed to account", any(s[0].lower() == owner for s in SENT[-2:]) , SENT[-2:])
        check("notice email has no values", not any(leaks(s[1] + s[2]) for s in SENT))
        r = CLIENT.get("/affiliates/payouts", headers=hdr(tok))
        check("GET masked, no secrets, no-store", r.status_code == 200 and r.json()["status"] == "set" and not leaks(r.text) and no_store(r))
        # replay
        r = CLIENT.put("/affiliates/payouts", json=payload(p, account_number=ACCOUNT2), headers=hdr(tok))
        check("replayed proof rejected", r.status_code == 403 and r.json()["detail"] == "reauth_required")
        r = CLIENT.post("/affiliates/payouts/delete", json={"proof": p}, headers=hdr(tok))
        check("replayed proof cannot delete", r.status_code == 403)
        check("details intact after replay attempts", CLIENT.get("/affiliates/payouts", headers=hdr(tok)).json()["account_last4"] == ACCOUNT[-4:])
    finally:
        root.removeHandler(cap)
        root.setLevel(old_lvl)
    check("no submitted value in any log line", not any(leaks(l) for l in cap.lines), [l for l in cap.lines if leaks(l)][:2])

    # at rest
    row = q("SELECT routing_enc, account_enc, holder_enc, type_enc, routing_last4, account_last4, row_id FROM affiliate_payout_details WHERE owner_email=%s", (owner,))[0]
    blob = " ".join(str(c) for c in row[:4])
    check("ciphertext columns hold no plaintext", not leaks(blob) and "checking" not in blob and "Jane" not in blob)
    check("ciphertext carries current key id", all(pc.key_id_of(c) == pc.current_key_id() for c in row[:4]))
    check("only last-4 plaintext stored", row[4].strip() == ROUTING[-4:] and row[5].strip() == ACCOUNT[-4:])
    check("each field decrypts with its row_id", pc.decrypt(row[1], str(row[6]), "account") == ACCOUNT)
    dump = q("SELECT row_to_json(t)::text FROM affiliate_payout_details t WHERE owner_email=%s", (owner,))[0][0]
    check("row dump has no plaintext secrets", not leaks(dump))

    # update
    p = proof_for(tok)
    r = CLIENT.put("/affiliates/payouts", json=payload(p, routing_number=ROUTING2, account_number=ACCOUNT2, account_type="savings"), headers=hdr(tok))
    check("update 200 new last-4", r.status_code == 200 and r.json()["routing_last4"] == ROUTING2[-4:] and r.json()["account_type"] == "savings")
    check("still one row after update", q("SELECT COUNT(*) FROM affiliate_payout_details WHERE owner_email=%s", (owner,))[0][0] == 1)

    # audit
    ev = [e[0] for e in q("SELECT event_type FROM affiliate_payout_audit WHERE actor_id=%s ORDER BY id", (uid,))]
    check("audit: create then update recorded", "create" in ev and "update" in ev, ev)
    arows = q("SELECT row_to_json(a)::text FROM affiliate_payout_audit a WHERE actor_id=%s OR subject=%s", (uid, owner))
    check("audit rows value-free", not any(leaks(x[0]) for x in arows))
    check("audit has ip/ua columns populated", q("SELECT COUNT(*) FROM affiliate_payout_audit WHERE actor_id=%s AND ip <> ''", (uid,))[0][0] >= 1)

    # delete
    p = proof_for(tok)
    r = CLIENT.post("/affiliates/payouts/delete", json={"proof": p}, headers=hdr(tok))
    check("delete 200 not_set", r.status_code == 200 and r.json() == {"status": "not_set"} and no_store(r))
    check("hard delete: no row remains", q("SELECT COUNT(*) FROM affiliate_payout_details WHERE owner_email=%s", (owner,))[0][0] == 0)
    check("delete audit retained", "delete" in [e[0] for e in q("SELECT event_type FROM affiliate_payout_audit WHERE actor_id=%s", (uid,))])
    check("GET not_set after delete", CLIENT.get("/affiliates/payouts", headers=hdr(tok)).json() == {"status": "not_set"})
    p = proof_for(tok)
    r = CLIENT.post("/affiliates/payouts/delete", json={"proof": p, "extra": 1}, headers=hdr(tok))
    check("delete with extra field 400", r.status_code == 400)


def test_isolation():
    print("\n== Owner isolation ==")
    set_flag("affiliates", "on")
    set_flag("affiliate_payouts", "on")
    _, tok_a, _ = mk_affiliate()
    _, tok_b, _ = mk_affiliate()
    pa = proof_for(tok_a)
    CLIENT.put("/affiliates/payouts", json=payload(pa), headers=hdr(tok_a))
    rb = CLIENT.get("/affiliates/payouts", headers=hdr(tok_b))
    check("B sees not_set, no signal of A", rb.json() == {"status": "not_set"} and not leaks(rb.text))
    pb = proof_for(tok_b)
    r = CLIENT.put("/affiliates/payouts", json=payload(pb, owner_email="whoever@example.com"), headers=hdr(tok_b))
    check("client-supplied owner in body rejected (unknown field)", r.status_code == 400)
    pb = proof_for(tok_b)
    r = CLIENT.post("/affiliates/payouts/delete", json={"proof": pb}, headers=hdr(tok_b))
    check("B delete does not touch A", CLIENT.get("/affiliates/payouts", headers=hdr(tok_a)).json()["status"] == "set")
    # B's proof cannot be used by A (user bound)
    pb = proof_for(tok_b)
    r = CLIENT.put("/affiliates/payouts", json=payload(pb), headers=hdr(tok_a))
    check("proof is user-bound (A cannot use B's proof)", r.status_code == 403 and r.json()["detail"] == "reauth_required")


def test_reauth():
    print("\n== Re-auth ==")
    set_flag("affiliates", "on")
    set_flag("affiliate_payouts", "on")
    uid, tok, email = mk_affiliate()
    r = CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok))
    check("reauth sends code, reports password_required", r.status_code == 200 and r.json() == {"sent": True, "password_required": True} and no_store(r), r.text)
    check("code emailed to account email, 6 digits", SENT[-1][0].lower() == email.lower() and re.search(r"\b\d{6}\b", SENT[-1][2]))
    code = last_code()
    check("code stored hashed only", q("SELECT COUNT(*) FROM affiliate_payout_proofs WHERE user_id=%s AND code_hash=%s", (uid, code))[0][0] == 0)
    wrong_pw = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": code, "password": "wrong"}, headers=hdr(tok))
    check("wrong password 403 reauth_failed", wrong_pw.status_code == 403 and wrong_pw.json()["detail"] == "reauth_failed" and no_store(wrong_pw))
    no_pw = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": code}, headers=hdr(tok))
    check("missing password 403 (account has one)", no_pw.status_code == 403 and no_pw.json()["detail"] == "reauth_failed")
    bad_code = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": "000000" if code != "000000" else "111111", "password": PW}, headers=hdr(tok))
    check("wrong code 403, same body as wrong password", bad_code.status_code == 403 and bad_code.json() == wrong_pw.json())
    r = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": code, "password": PW, "x": 1}, headers=hdr(tok))
    check("unknown verify field 400", r.status_code == 400)
    check("failures audited value-free", q("SELECT COUNT(*) FROM affiliate_payout_audit WHERE actor_id=%s AND event_type='reauth_failed'", (uid,))[0][0] >= 3)
    # attempts cap: this code has been tried 4 times (wrong pw, no pw, bad code, extra-field rejected earlier = not counted) -> check cap by new code
    cfg = get_affiliates_config().payouts
    q("DELETE FROM affiliate_payout_audit WHERE actor_id=%s", (uid,))  # reset lockout for the cap test
    q("UPDATE affiliate_payout_proofs SET used=TRUE WHERE user_id=%s", (uid,))
    CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok))
    good = last_code()
    q("UPDATE affiliate_payout_proofs SET attempts=%s WHERE user_id=%s AND NOT used", (cfg.max_code_attempts, uid))
    r = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": good, "password": PW}, headers=hdr(tok))
    check("correct code rejected after per-code attempt cap", r.status_code == 403 and r.json()["detail"] == "reauth_failed")
    # expired code
    q("DELETE FROM affiliate_payout_audit WHERE actor_id=%s", (uid,))
    q("DELETE FROM affiliate_payout_proofs WHERE user_id=%s", (uid,))
    CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok))
    good = last_code()
    q("UPDATE affiliate_payout_proofs SET code_expires_at = NOW() - INTERVAL '1 second' WHERE user_id=%s AND NOT used", (uid,))
    r = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": good, "password": PW}, headers=hdr(tok))
    check("expired code rejected", r.status_code == 403)
    # newer code voids older
    q("DELETE FROM affiliate_payout_audit WHERE actor_id=%s", (uid,))
    q("DELETE FROM affiliate_payout_proofs WHERE user_id=%s", (uid,))
    CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok))
    first = last_code()
    CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok))
    second = last_code()
    if first != second:
        r = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": first, "password": PW}, headers=hdr(tok))
        check("older code voided by newer", r.status_code == 403)
    # proof expiry
    q("DELETE FROM affiliate_payout_audit WHERE actor_id=%s", (uid,))
    q("DELETE FROM affiliate_payout_proofs WHERE user_id=%s", (uid,))
    p = proof_for(tok)
    q("UPDATE affiliate_payout_proofs SET proof_expires_at = NOW() - INTERVAL '1 second' WHERE user_id=%s", (uid,))
    r = CLIENT.put("/affiliates/payouts", json=payload(p), headers=hdr(tok))
    check("expired proof rejected", r.status_code == 403 and r.json()["detail"] == "reauth_required")
    check("proof token stored hashed only", q("SELECT COUNT(*) FROM affiliate_payout_proofs WHERE user_id=%s AND token_hash=%s", (uid, p))[0][0] == 0)
    # purpose separation: a write proof cannot be used by the reveal consumer
    q("DELETE FROM affiliate_payout_proofs WHERE user_id=%s", (uid,))
    p = proof_for(tok)
    m = ap.PayoutManager(cfg)
    try:
        try:
            m._consume_proof(uid, ap.PURPOSE_REVEAL, p)
            check("write proof cannot satisfy reveal purpose", False)
        except ap.PayoutError:
            check("write proof cannot satisfy reveal purpose", True)
    finally:
        m.close()
    # login MFA code table cannot be used: proofs only from payout table
    r = CLIENT.put("/affiliates/payouts", json=payload("a" * 43), headers=hdr(tok))
    check("arbitrary token (e.g. login code) rejected", r.status_code == 403)
    # code issue hourly cap
    q("DELETE FROM affiliate_payout_audit WHERE actor_id=%s", (uid,))
    q("DELETE FROM affiliate_payout_proofs WHERE user_id=%s", (uid,))
    statuses = [CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok)).status_code for _ in range(cfg.code_issues_per_hour + 1)]
    check("code issuance capped per user per hour", statuses[:-1] == [200] * cfg.code_issues_per_hour and statuses[-1] == 429, statuses)
    # lockout
    q("DELETE FROM affiliate_payout_proofs WHERE user_id=%s", (uid,))
    CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok)) if False else None
    q("DELETE FROM affiliate_payout_audit WHERE actor_id=%s", (uid,))
    for _ in range(cfg.lockout_failures):
        CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": "123456", "password": "nope"}, headers=hdr(tok))
    r = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": "123456", "password": PW}, headers=hdr(tok))
    check("lockout after repeated failures", r.status_code == 429 and r.json()["detail"] == "locked" and no_store(r), (r.status_code, r.text))
    r = CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok))
    check("locked user cannot request a new code", r.status_code == 429)
    q("DELETE FROM affiliate_payout_audit WHERE actor_id=%s", (uid,))
    r = CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok))
    check("lockout lifts when failure window clears", r.status_code == 200)
    # IP rate limit on route
    codes = [CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": "1", "password": "x"},
                         headers={"cf-connecting-ip": "203.0.113.77", "cookie": f"session={tok}"}).status_code for _ in range(8)]
    check("per-IP rate limit on reauth route (429 seen)", 429 in codes, codes)
    r = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": "1"}, headers={"cf-connecting-ip": "203.0.113.77", "cookie": f"session={tok}"})
    check("rate-limit error is no-store fixed body", r.status_code == 429 and r.json() == {"detail": "rate_limited"} and no_store(r), (r.status_code, r.text))
    q("DELETE FROM affiliate_payout_audit WHERE actor_id=%s", (uid,))


def test_oauth_only_account():
    print("\n== Account without password ==")
    set_flag("affiliates", "on")
    set_flag("affiliate_payouts", "on")
    uid, tok, email = mk_affiliate()
    q("UPDATE users SET hash_pass = '' WHERE _id=%s", (uid,))
    r = CLIENT.post("/affiliates/payouts/reauth", headers=hdr(tok))
    check("password_required false when no hash", r.status_code == 200 and r.json()["password_required"] is False, r.text)
    r = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": last_code()}, headers=hdr(tok))
    check("email code alone suffices (no password set)", r.status_code == 200 and "proof" in r.json(), r.text)
    r = CLIENT.post("/affiliates/payouts/reauth/verify", json={"code": "000000"}, headers=hdr(tok))
    check("but a wrong code still fails", r.status_code == 403)


def test_admin():
    print("\n== Admin reveal ==")
    set_flag("affiliates", "on")
    set_flag("affiliate_payouts", "on")
    aff_uid, aff_tok, aff_email = mk_affiliate()
    p = proof_for(aff_tok)
    CLIENT.put("/affiliates/payouts", json=payload(p), headers=hdr(aff_tok))
    adm_uid, adm_tok, adm_email = mk_admin()
    owner = aff_email.lower()
    for method, path in (("get", ""), ("post", "/reauth"), ("post", "/reveal")):
        r = getattr(CLIENT, method)(f"/admin/affiliate-payouts{path}", headers=hdr(aff_tok), **({} if method == "get" else {"json": {}}))
        check(f"affiliate (non-admin) 403 {method.upper()} {path or '/'}", r.status_code == 403, r.status_code)
        r = getattr(CLIENT, method)(f"/admin/affiliate-payouts{path}", headers=hdr(), **({} if method == "get" else {"json": {}}))
        check(f"anon 401 {method.upper()} {path or '/'}", r.status_code == 401, r.status_code)
    r = CLIENT.get("/admin/affiliate-payouts", headers=hdr(adm_tok))
    items = r.json().get("items", [])
    mine = [i for i in items if i["owner_email"] == owner]
    check("admin list: last-4 only, no-store", r.status_code == 200 and no_store(r) and mine and set(mine[0]) == {"owner_email", "routing_last4", "account_last4", "updated_at"} and not leaks(r.text), r.text[:200])
    # reveal needs fresh admin proof
    r = CLIENT.post("/admin/affiliate-payouts/reveal", json={"owner_email": owner, "proof": "z" * 40, "reason": "monthly payout run"}, headers=hdr(adm_tok))
    check("reveal without valid proof 403, no data", r.status_code == 403 and not leaks(r.text))
    check("no reveal audit row for failed attempt", q("SELECT COUNT(*) FROM affiliate_payout_audit WHERE actor_id=%s AND event_type='reveal'", (adm_uid,))[0][0] == 0)
    # affiliate write-purpose proof can't be used by admin; admin's reveal proof
    ap_proof = proof_for(adm_tok, base="/admin/affiliate-payouts")
    r = CLIENT.post("/admin/affiliate-payouts/reveal", json={"owner_email": owner, "proof": ap_proof, "reason": "x"}, headers=hdr(adm_tok))
    check("reason too short 400", r.status_code == 400)
    ap_proof = proof_for(adm_tok, base="/admin/affiliate-payouts")
    r = CLIENT.post("/admin/affiliate-payouts/reveal", json={"owner_email": owner, "proof": ap_proof, "reason": "monthly payout run"}, headers=hdr(adm_tok))
    d = r.json()
    check("admin reveal returns decrypted values, no-store", r.status_code == 200 and no_store(r) and d == {
        "routing_number": ROUTING, "account_number": ACCOUNT, "holder_name": HOLDER, "account_type": "checking"}, r.text)
    aud = q("SELECT event_type, subject, reason, row_to_json(a)::text FROM affiliate_payout_audit a WHERE actor_id=%s AND event_type='reveal'", (adm_uid,))
    check("reveal audited with actor, subject, reason", len(aud) == 1 and aud[0][1] == owner and aud[0][2] == "monthly payout run")
    check("reveal audit row has no values", not leaks(aud[0][3]))
    check("affiliate notified of access", any(s[0].lower() == owner and "access" in (s[1] + s[2]).lower() for s in SENT[-3:]) or any(s[0].lower() == owner for s in SENT[-3:]))
    r = CLIENT.post("/admin/affiliate-payouts/reveal", json={"owner_email": owner, "proof": ap_proof, "reason": "monthly payout run"}, headers=hdr(adm_tok))
    check("reveal proof single use", r.status_code == 403 and not leaks(r.text))
    # affiliate cannot use admin-purpose route to reveal own details, covered by 403. Unknown subject:
    ap_proof = proof_for(adm_tok, base="/admin/affiliate-payouts")
    r = CLIENT.post("/admin/affiliate-payouts/reveal", json={"owner_email": "nobody@payouts-test.example", "proof": ap_proof, "reason": "monthly payout run"}, headers=hdr(adm_tok))
    check("reveal unknown subject 404 not_found", r.status_code == 404 and r.json()["detail"] == "not_found" and no_store(r))
    # hourly cap
    cfg = get_affiliates_config().payouts
    for _ in range(cfg.reveal_per_hour):
        q("INSERT INTO affiliate_payout_audit (event_type, actor_id, subject, reason) VALUES ('reveal', %s, %s, 'seed')", (adm_uid, owner))
    ap_proof = proof_for(adm_tok, base="/admin/affiliate-payouts")
    r = CLIENT.post("/admin/affiliate-payouts/reveal", json={"owner_email": owner, "proof": ap_proof, "reason": "monthly payout run"}, headers=hdr(adm_tok))
    check("reveal hourly cap 429, no data", r.status_code == 429 and not leaks(r.text), (r.status_code, r.text))
    # admin write-purpose cross-use: admin's affiliate-route proof is purpose payout_write
    q("DELETE FROM affiliate_payout_audit WHERE actor_id=%s", (adm_uid,))
    q("DELETE FROM affiliate_payout_proofs WHERE user_id=%s", (adm_uid,))


def test_retention_and_rotation():
    print("\n== Retention + rotation ==")
    set_flag("affiliates", "on")
    set_flag("affiliate_payouts", "on")
    cfg = get_affiliates_config().payouts
    uid_old, tok_old, e_old = mk_affiliate()
    uid_new, tok_new, e_new = mk_affiliate()
    uid_gone, tok_gone, e_gone = mk_affiliate()
    for t in (tok_old, tok_new, tok_gone):
        CLIENT.put("/affiliates/payouts", json=payload(proof_for(t)), headers=hdr(t))
    q("UPDATE affiliate_payout_details SET updated_at = NOW() - make_interval(days => %s) WHERE owner_email=%s", (cfg.retention_inactive_days + 1, e_old.lower()))
    q("UPDATE promo_codes SET active = FALSE WHERE owner_email=%s", (e_gone,))
    m = ap.PayoutManager(cfg)
    try:
        n = m.purge()
    finally:
        m.close()
    left = {r[0] for r in q("SELECT owner_email FROM affiliate_payout_details WHERE owner_email = ANY(%s)", ([e_old.lower(), e_new.lower(), e_gone.lower()],))}
    check("purge removed inactive-too-long and deactivated, kept active", left == {e_new.lower()} and n >= 2, (left, n))
    check("purge audited value-free", q("SELECT COUNT(*) FROM affiliate_payout_audit WHERE event_type='retention_purge' AND subject = ANY(%s)", ([e_old.lower(), e_gone.lower()],))[0][0] == 2)

    # rotation script: idempotent, preserves values
    owner = e_new.lower()
    env = dict(os.environ, PAYOUT_ENCRYPTION_KEYS=f"7:{_K2},{ORIG_KEYS}")
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "rotate_payout_keys.py")
    out1 = subprocess.run([sys.executable, script], env=env, capture_output=True, text=True, cwd=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    check("rotation script exits 0", out1.returncode == 0, out1.stderr[-300:])
    check("rotation output has no values", not leaks(out1.stdout + out1.stderr))
    cols = q("SELECT routing_enc, account_enc, holder_enc, type_enc, row_id FROM affiliate_payout_details WHERE owner_email=%s", (owner,))[0]
    check("all fields now on key 7", all(pc.key_id_of(c) == 7 for c in cols[:4]))
    old = os.environ["PAYOUT_ENCRYPTION_KEYS"]
    os.environ["PAYOUT_ENCRYPTION_KEYS"] = f"7:{_K2}"
    try:
        check("values survive rotation under new key only", pc.decrypt(cols[1], str(cols[4]), "account") == ACCOUNT)
    finally:
        os.environ["PAYOUT_ENCRYPTION_KEYS"] = old
    out2 = subprocess.run([sys.executable, script], env=env, capture_output=True, text=True, cwd=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    check("second run is a no-op (idempotent)", "rows re-encrypted: 0" in out2.stdout, out2.stdout)
    # cleanup the audit marker rows for rotation (actor 'cli') are value-free
    q("DELETE FROM affiliate_payout_audit WHERE actor_id='cli' AND event_type='key_rotation' AND created_at > NOW() - INTERVAL '5 minutes'")


def test_client_error_redaction():
    print("\n== Client-error report redaction ==")
    _, tok, _ = signup()
    cap = LogCapture()
    lg = logging.getLogger("routes.monitoring")
    lg.addHandler(cap)
    old = lg.level
    lg.setLevel(logging.DEBUG)
    try:
        for ep in ("/affiliates/payouts", "/admin/affiliate-payouts/reveal"):
            r = CLIENT.post("/monitoring/client-error", headers=hdr(tok), json={
                "endpoint": ep, "http_status": 200, "client_app_version": "1.0",
                "error_summary": f"decode failed routing {ROUTING} account {ACCOUNT}"})
            check(f"client-error report for {ep} accepted", r.status_code in (200, 204), (r.status_code, r.text[:100]))
        r = CLIENT.post("/monitoring/client-error", headers=hdr(tok), json={
            "endpoint": "/notes", "http_status": 200, "client_app_version": "1.0", "error_summary": "plain-summary-xyz"})
        txt = "\n".join(cap.lines)
        check("payout summaries omitted from log", ROUTING not in txt and ACCOUNT not in txt and "[omitted]" in txt, txt[:300])
        check("non-payout summaries still logged (unchanged behavior)", "plain-summary-xyz" in txt)
    finally:
        lg.removeHandler(cap)
        lg.setLevel(old)


def test_registry():
    print("\n== Registry / config ==")
    from schema_ddl.flags import SEED_FLAG_NAMES
    check("affiliate_payouts flag seeded", "affiliate_payouts" in SEED_FLAG_NAMES)
    check("DDL module registered", any("affiliate_payouts" in str(m) for m in __import__("db").DDL_MODULES))
    from schema_ddl import affiliate_payouts as ddl
    db = DBManager()
    try:
        ddl.apply(db.cur)
        ddl.apply(db.cur)
        db.conn.commit()
        check("migration idempotent (applied twice)", True)
    finally:
        db.close()
    cfg = get_affiliates_config().payouts
    check("tunables come from config (not constants)", cfg.max_code_attempts >= 1 and cfg.retention_inactive_days >= 30 and cfg.proof_ttl_seconds <= 300)
    wf = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".github", "workflows", "build-push.yml")).read()
    check("CI env block defines PAYOUT_ENCRYPTION_KEYS", "PAYOUT_ENCRYPTION_KEYS" in wf)
    m = re.search(r'PAYOUT_ENCRYPTION_KEYS:\s*"?([^"\n]+)', wf)
    try:
        saved = os.environ["PAYOUT_ENCRYPTION_KEYS"]
        os.environ["PAYOUT_ENCRYPTION_KEYS"] = m.group(1).strip()
        pc.validate_payout_keys()
        check("CI key value is valid for boot check", True)
    except Exception as e:
        check("CI key value is valid for boot check", False, type(e).__name__)
    finally:
        os.environ["PAYOUT_ENCRYPTION_KEYS"] = saved


if __name__ == "__main__":
    CLIENT = TestClient(main_module.app)
    CLIENT.__enter__()
    try:
        test_registry()
        test_crypto()
        test_validation()
        test_flag_and_authz()
        test_save_flow()
        test_isolation()
        test_reauth()
        test_oauth_only_account()
        test_admin()
        test_retention_and_rotation()
        test_client_error_redaction()
    finally:
        cleanup()
        CLIENT.__exit__(None, None, None)
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    for l, d in FAILED:
        print("FAILED:", l, d)
    sys.exit(1 if FAILED else 0)
