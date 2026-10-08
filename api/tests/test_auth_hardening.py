"""Backend coverage for task 20261007-auth-hardening.

Two account-takeover fixes, both active only with the email_verification flag ON:
  (1) ADMIN_SEED_EMAIL promotion in db.create_tables requires a verified email
      (deferred to after the email_verification DDL module; never demotes;
      fails closed with no crash when the columns are missing);
  (2) POST /auth/google and POST /auth/apple never link by email to an existing
      account whose email is unverified (generic configured conflict, no cookie,
      no mutation), while sub-match, new-account, verified-link and the
      suspended 403 keep working.
Flag OFF is proved unchanged: same behavior, and the exact SQL statement stream
of create_tables equals the one produced by the HEAD version of db.py.

Scratch database ONLY. db.py hardcodes port 5432, so run with a sitecustomize
shim on PYTHONPATH that forces every psycopg2 connection (including
subprocesses) to 127.0.0.1:55432 and refuses anything else, e.g.:
    PYTHONPATH=<dir containing the shim sitecustomize.py> DB_PASSWORD=... \
      ../.venv/bin/python tests/test_auth_hardening.py
The script itself refuses to run unless SHOW port = 55432 (or 5432 under
GITHUB_ACTIONS=true, as the CI service container). Google tokeninfo and Apple
JWKS/jwt are mocked (no network).

Run with: cd api && ../.venv/bin/python tests/test_auth_hardening.py
"""
import _pathfix  # noqa: F401

import dataclasses
import importlib.util
import json
import logging
import os
import subprocess
import tempfile
import uuid
from unittest.mock import AsyncMock, MagicMock

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")
os.environ.setdefault("CLIENT_ID", "ci-test-google-client-id")
os.environ["TRIAL_MONTHS"] = "0"
os.environ["PROMO_CODES_ENABLED"] = "false"
os.environ["PROMO_DISCOUNT_PERCENT"] = "50"
os.environ["PROMO_VALIDATE_RATE_LIMIT"] = "1000/minute"

import psycopg2.extensions  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth import email_verification as ev  # noqa: E402
from backend.auth import email_verification_config as evc  # noqa: E402
from backend.config_loader import ConfigSectionError  # noqa: E402

PASSED, FAILED = [], []
USERS = []
BASE_CFG = evc.get_email_verification_config()
API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAG = uuid.uuid4().hex[:8]
GOOGLE_AUD = os.environ["CLIENT_ID"]


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def q(sql, params=()):
    d = DBManager()
    try:
        d.cur.execute(sql, params)
        rows = d.cur.fetchall() if d.cur.description else None
        d.conn.commit()
        return rows
    finally:
        d.close()


def require_scratch_db():
    port = q("SHOW port")[0][0]
    ok = port == "55432" or (port == "5432" and os.environ.get("GITHUB_ACTIONS") == "true")
    check("tests run against scratch DB port 55432", ok, port)
    if not ok:
        raise SystemExit("refusing to continue: not the scratch database")


def set_cfg(**kw):
    evc._cfg = dataclasses.replace(BASE_CFG, **kw)


def hdr():
    return {"cf-connecting-ip": f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"}


class LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines = []

    def emit(self, record):
        try:
            self.lines.append(record.getMessage())
        except Exception:
            self.lines.append(str(record.msg))

    def text(self):
        return "\n".join(self.lines)


def make_user(label, email=None, password=True, verified=False, admin=False, suspended=False,
              google_sub=None, apple_sub=None):
    uid = str(uuid.uuid4())
    email = email or f"ah{TAG}_{label}@example.com"
    q("INSERT INTO users (_id, username, email, hash_pass, is_admin) VALUES (%s,%s,%s,%s,%s)",
      (uid, f"ah{TAG}_{label}", email, "attacker-set-hash" if password else "", admin))
    USERS.append(uid)
    if verified:
        mgr = ev.EmailVerificationManager()
        try:
            mgr.mark_verified(uid, email)
        finally:
            mgr.close()
    if suspended:
        q("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (uid,))
    if google_sub:
        q("UPDATE users SET google_sub = %s WHERE _id = %s", (google_sub, uid))
    if apple_sub:
        q("UPDATE users SET apple_sub = %s WHERE _id = %s", (apple_sub, uid))
    return uid, email


def row(uid, cols="is_admin"):
    return q(f"SELECT {cols} FROM users WHERE _id = %s", (uid,))[0]


# ---------------------------------------------------------------- create_tables helpers

class RecCursor(psycopg2.extensions.cursor):
    log = None

    def execute(self, query, vars=None):
        if RecCursor.log is not None:
            RecCursor.log.append((" ".join(str(query).split()), repr(vars)))
        return super().execute(query, vars)


def run_create_tables(module=db_module, record=False):
    conn = module._connect()
    try:
        RecCursor.log = [] if record else None
        cur = conn.cursor(cursor_factory=RecCursor)
        module.create_tables(cur)
        conn.commit()
        return RecCursor.log
    finally:
        RecCursor.log = None
        conn.close()


def load_head_db():
    src = subprocess.run(["git", "show", "HEAD:api/db.py"], cwd=API_DIR, capture_output=True,
                         text=True, check=True).stdout
    d = tempfile.mkdtemp()
    p = os.path.join(d, "db_head_baseline.py")
    with open(p, "w") as f:
        f.write(src)
    spec = importlib.util.spec_from_file_location("db_head_baseline", p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def seed_env(email):
    os.environ["ADMIN_SEED_EMAIL"] = email


# ---------------------------------------------------------------- admin seed

def test_admin_seed_flag_off():
    print("-- admin seed, flag OFF (unchanged)")
    set_cfg(enabled=False)
    uid, email = make_user("seedoff_unver")
    seed_env(email)
    run_create_tables()
    check("flag off: unverified seed account IS promoted (original behavior)", row(uid)[0] is True, row(uid))

    # revoke guard still honored
    uid2, email2 = make_user("seedoff_revoked")
    q("INSERT INTO admin_role_audit (target_user_id, action, previous_value, new_value) VALUES (%s,'revoke',TRUE,FALSE)", (uid2,))
    seed_env(email2)
    run_create_tables()
    check("flag off: revoke-audit guard still blocks re-promotion", row(uid2)[0] is False, row(uid2))

    # original warning (with email, as before) when no account matches
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    missing = f"nobody{TAG}@example.com"
    seed_env(missing)
    try:
        run_create_tables()
    finally:
        logging.getLogger().removeHandler(cap)
    check("flag off: original no-user warning preserved verbatim (includes email as before)",
          any("Admin seed: no user found with email" in l and missing in l for l in cap.lines), cap.lines[-3:])


def test_flag_off_sql_parity():
    print("-- flag OFF: create_tables SQL stream identical to HEAD")
    set_cfg(enabled=False)
    head = load_head_db()
    uid, email = make_user("parity")
    scenarios = {
        "seed account non-admin": (email, lambda: q("UPDATE users SET is_admin=FALSE WHERE _id=%s", (uid,))),
        "seed account already admin": (email, lambda: q("UPDATE users SET is_admin=TRUE WHERE _id=%s", (uid,))),
        "seed account absent": (f"absent{TAG}@example.com", lambda: None),
    }
    run_create_tables()  # warm up so first-ever DDL differences cannot skew either run
    for name, (seed, prep) in scenarios.items():
        seed_env(seed)
        prep()
        a = run_create_tables(head, record=True)
        prep()
        b = run_create_tables(db_module, record=True)
        check(f"flag off parity ({name}): {len(a)} statements identical to HEAD", a == b,
              f"len head={len(a)} new={len(b)}; first diff="
              f"{next(((x, y) for x, y in zip(a, b) if x != y), None)}")


def test_admin_seed_flag_on():
    print("-- admin seed, flag ON")
    set_cfg(enabled=True)
    admins_before = {r[0] for r in q("SELECT _id::text FROM users WHERE is_admin")}
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    try:
        # unverified not promoted
        uid_u, email_u = make_user("seedon_unver")
        seed_env(email_u)
        run_create_tables()
        check("flag on: unverified seed account NOT promoted", row(uid_u)[0] is False, row(uid_u))

        # verified promoted
        uid_v, email_v = make_user("seedon_ver", verified=True)
        seed_env(email_v)
        run_create_tables()
        check("flag on: verified seed account promoted", row(uid_v)[0] is True, row(uid_v))

        # existing admin never demoted (verified or not)
        uid_a, email_a = make_user("seedon_admin_unver", admin=True)
        seed_env(email_a)
        run_create_tables()
        check("flag on: existing UNVERIFIED admin keeps is_admin (never demoted)", row(uid_a)[0] is True, row(uid_a))
        uid_a2, email_a2 = make_user("seedon_admin_ver", admin=True, verified=True)
        seed_env(email_a2)
        run_create_tables()
        check("flag on: existing verified admin keeps is_admin", row(uid_a2)[0] is True, row(uid_a2))

        # stale verification (email changed after verify) not promoted
        uid_s, email_s = make_user("seedon_stale", verified=True)
        new_email = f"ah{TAG}_changed@example.com"
        q("UPDATE users SET email = %s WHERE _id = %s", (new_email, uid_s))  # hash now stale
        seed_env(new_email)
        run_create_tables()
        check("flag on: stale verified-hash (email changed) NOT promoted", row(uid_s)[0] is False, row(uid_s))

        # verified flag TRUE but hash NULL (tampered/partial) not promoted
        uid_h, email_h = make_user("seedon_nohash")
        q("UPDATE users SET email_verified = TRUE, email_verified_hash = NULL WHERE _id = %s", (uid_h,))
        seed_env(email_h)
        run_create_tables()
        check("flag on: email_verified=TRUE with NULL hash NOT promoted", row(uid_h)[0] is False, row(uid_h))

        # revoke guard retained even when verified
        uid_r, email_r = make_user("seedon_revoked", verified=True)
        q("INSERT INTO admin_role_audit (target_user_id, action, previous_value, new_value) VALUES (%s,'revoke',TRUE,FALSE)", (uid_r,))
        seed_env(email_r)
        run_create_tables()
        check("flag on: revoke-audit guard retained for a verified account", row(uid_r)[0] is False, row(uid_r))

        # case: only the seed email row is touched, no other row promoted
        admins_after = {r[0] for r in q("SELECT _id::text FROM users WHERE is_admin")}
        expected_new = {uid_v, uid_a, uid_a2}
        check("flag on: only the intended accounts gained/kept admin; no unrelated promotion or demotion",
              admins_after - admins_before == expected_new - admins_before and admins_before <= admins_after,
              (admins_after ^ admins_before))
    finally:
        logging.getLogger().removeHandler(cap)
    leaked = [e for e in (email_u, email_v, email_a, email_s, email_h, email_r) if e in cap.text()]
    check("flag on: no seed email appears in any boot log line", not leaked, leaked)
    check("flag on: refusal path logged opaquely", any("Admin seed (verification-gated)" in l for l in cap.lines), cap.lines[-5:])


def test_admin_seed_missing_columns():
    print("-- admin seed, flag ON, columns missing (fail closed, no crash)")
    import schema_ddl
    set_cfg(enabled=True)
    uid, email = make_user("seed_nocols", verified=True)
    seed_env(email)
    # Scenario A: DDL module did not add the columns (patched out) -> gated UPDATE errors.
    q("ALTER TABLE users DROP COLUMN email_verified_hash")
    q("ALTER TABLE users DROP COLUMN email_verified")
    orig = schema_ddl.apply_modules
    schema_ddl.apply_modules = lambda cur, mods: None
    crashed = None
    try:
        try:
            run_create_tables()
        except Exception as e:  # noqa: BLE001
            crashed = e
    finally:
        schema_ddl.apply_modules = orig
    check("missing columns: create_tables does not crash", crashed is None, repr(crashed))
    q("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT FALSE")
    q("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMPTZ")
    q("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_hash VARCHAR(64)")
    check("missing columns: nothing promoted (fail closed)", row(uid)[0] is False, row(uid))

    # transaction not poisoned: the rest of create_tables still ran and committed
    check("missing columns: schema work after the failed check still committed",
          q("SELECT to_regclass('admin_role_audit') IS NOT NULL")[0][0] is True)

    # Scenario B: first-ever flag-on boot (columns absent beforehand, real DDL adds them).
    uid2, email2 = make_user("seed_firstboot")
    q("ALTER TABLE users DROP COLUMN email_verified_hash")
    q("ALTER TABLE users DROP COLUMN email_verified")
    seed_env(email2)
    crashed = None
    try:
        run_create_tables()
    except Exception as e:  # noqa: BLE001
        crashed = e
    check("first flag-on boot (no columns yet): no crash", crashed is None, repr(crashed))
    check("first flag-on boot: columns created by DDL module",
          q("SELECT COUNT(*) FROM information_schema.columns WHERE table_name='users' AND column_name IN ('email_verified','email_verified_hash')")[0][0] == 2)
    check("first flag-on boot: unverified (all rows default FALSE) seed NOT promoted", row(uid2)[0] is False, row(uid2))

    # Scenario C: unreadable config -> fail closed (treated as flag on => gated, no promotion)
    uid3, email3 = make_user("seed_badcfg")
    seed_env(email3)
    real_get = evc.get_email_verification_config

    def boom():
        raise ConfigSectionError("simulated unreadable config")
    evc.get_email_verification_config = boom
    crashed = None
    try:
        try:
            run_create_tables()
        except Exception as e:  # noqa: BLE001
            crashed = e
    finally:
        evc.get_email_verification_config = real_get
    check("unreadable flag config: boot does not crash", crashed is None, repr(crashed))
    check("unreadable flag config: unverified account NOT promoted (fail closed)", row(uid3)[0] is False, row(uid3))


# ---------------------------------------------------------------- OAuth

def google_mock(email, sub, email_verified="true"):
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = {"aud": GOOGLE_AUD, "email": email, "sub": sub,
                              "email_verified": email_verified, "given_name": "Gina"}
    cl = MagicMock()
    cl.get = AsyncMock(return_value=resp)
    cm = MagicMock()
    cm.__aenter__ = AsyncMock(return_value=cl)
    cm.__aexit__ = AsyncMock(return_value=False)
    main_module.httpx.AsyncClient = MagicMock(return_value=cm)


def apple_mock(email, sub, email_verified="true"):
    main_module.jwt.decode = MagicMock(return_value={"sub": sub, "email": email,
                                                     "email_verified": email_verified})
    main_module._apple_jwk_client.get_signing_key_from_jwt = MagicMock(return_value=MagicMock(key="fake"))


def sign_in(client, provider, email, sub, **kw):
    if provider == "google":
        google_mock(email, sub, **kw)
        return client.post("/auth/google", json={"credential": "TOK_GOOGLE_" + TAG}, headers=hdr())
    apple_mock(email, sub, **kw)
    return client.post("/auth/apple", json={"identity_token": "TOK_APPLE_" + TAG}, headers=hdr())


def has_session(r):
    return bool(r.cookies.get("session")) or "set-cookie" in {k.lower() for k in r.headers}


def sub_col(provider):
    return "google_sub" if provider == "google" else "apple_sub"


def test_oauth(client, provider):
    P = provider
    col = sub_col(P)
    print(f"-- /auth/{P}")
    new_sub = lambda: f"{P}-sub-{uuid.uuid4().hex}"  # noqa: E731

    # ---- flag OFF: unchanged (unverified pre-registered account is linked, as before)
    set_cfg(enabled=False)
    uid, email = make_user(f"{P}_off")
    sub = new_sub()
    r = sign_in(client, P, email, sub)
    check(f"{P} flag off: unverified existing account still linked by email (200, same user)",
          r.status_code == 200 and r.json().get("user_id") == uid, (r.status_code, r.text[:120]))
    check(f"{P} flag off: session cookie issued", has_session(r))
    check(f"{P} flag off: provider sub backfilled on existing row", row(uid, col)[0] == sub, row(uid, col))

    # ---- flag ON
    set_cfg(enabled=True)
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    try:
        # unverified existing -> conflict
        uid_u, email_u = make_user(f"{P}_on_unver")
        sub_u = new_sub()
        r = sign_in(client, P, email_u, sub_u)
        check(f"{P} flag on: unverified existing account -> configured conflict status",
              r.status_code == BASE_CFG.oauth_conflict_status == 409, (r.status_code, r.text[:160]))
        check(f"{P} flag on: conflict body is the configured generic message",
              r.json().get("detail") == BASE_CFG.oauth_conflict_message, r.text[:200])
        check(f"{P} flag on: NO session cookie issued on conflict", not has_session(r), dict(r.headers))
        check(f"{P} flag on: conflict does not link (provider sub not written)", row(uid_u, col)[0] in (None, ""), row(uid_u, col))
        check(f"{P} flag on: attacker's hash_pass untouched on conflict", row(uid_u, "hash_pass")[0] == "attacker-set-hash")
        n_before = q("SELECT COUNT(*) FROM users WHERE LOWER(email)=LOWER(%s)", (email_u,))[0][0]
        check(f"{P} flag on: no duplicate account created on conflict", n_before == 1, n_before)

        # identical for a different unverified account and for a passwordless (no hash) unverified account
        uid_u2, email_u2 = make_user(f"{P}_on_unver2", password=False)
        r2 = sign_in(client, P, email_u2, new_sub())
        check(f"{P} flag on: conflict response identical for any unverified existing account (status+body)",
              (r2.status_code, r2.json()) == (r.status_code, r.json()), (r2.status_code, r2.text[:120]))
        check(f"{P} flag on: conflict body does not echo email/sub/provider-account details",
              email_u not in r.text and sub_u not in r.text and email_u2 not in r2.text)

        # verified existing -> link
        uid_v, email_v = make_user(f"{P}_on_ver", verified=True)
        sub_v = new_sub()
        r = sign_in(client, P, email_v, sub_v)
        check(f"{P} flag on: verified existing account is linked (200, same user, session)",
              r.status_code == 200 and r.json().get("user_id") == uid_v and has_session(r), (r.status_code, r.text[:120]))
        check(f"{P} flag on: verified link backfills provider sub", row(uid_v, col)[0] == sub_v)

        # stale verification (email changed after verification) -> conflict
        uid_s, email_s = make_user(f"{P}_on_stale", verified=True)
        email_s2 = f"ah{TAG}_{P}_stale2@example.com"
        q("UPDATE users SET email = %s WHERE _id = %s", (email_s2, uid_s))
        r = sign_in(client, P, email_s2, new_sub())
        check(f"{P} flag on: verification bound to old email hash => conflict, no session",
              r.status_code == 409 and not has_session(r), (r.status_code, r.text[:100]))

        # sub-match on an UNVERIFIED account is unchanged (sub is the stable identity)
        sub_m = new_sub()
        uid_m, email_m = make_user(f"{P}_on_submatch", password=False, **{col: sub_m})
        r = sign_in(client, P, email_m, sub_m)
        check(f"{P} flag on: sub-match sign-in unchanged (200, same user, session)",
              r.status_code == 200 and r.json().get("user_id") == uid_m and has_session(r), (r.status_code, r.text[:120]))
        check(f"{P} flag on: sub-match on passwordless account marks provider-verified", row(uid_m, "email_verified")[0] is True)

        # new account
        new_email = f"ah{TAG}_{P}_brandnew@example.com"
        sub_n = new_sub()
        r = sign_in(client, P, new_email, sub_n)
        ok = r.status_code == 200 and has_session(r)
        if ok:
            USERS.append(r.json()["user_id"])
        check(f"{P} flag on: brand-new account creation unchanged (200, session)", ok, (r.status_code, r.text[:120]))
        check(f"{P} flag on: new provider-created account is marked verified",
              ok and row(r.json()["user_id"], "email_verified")[0] is True)

        # suspended
        uid_x, email_x = make_user(f"{P}_on_susp_ver", verified=True, suspended=True)
        r = sign_in(client, P, email_x, new_sub())
        check(f"{P} flag on: suspended verified existing account -> 403", r.status_code == 403 and not has_session(r), (r.status_code, r.text[:100]))
        sub_xs = new_sub()
        uid_xs, email_xs = make_user(f"{P}_on_susp_sub", suspended=True, password=False, **{col: sub_xs})
        r = sign_in(client, P, email_xs, sub_xs)
        check(f"{P} flag on: suspended sub-match account -> 403", r.status_code == 403 and not has_session(r), (r.status_code, r.text[:100]))
        uid_xu, email_xu = make_user(f"{P}_on_susp_unver", suspended=True)
        r = sign_in(client, P, email_xu, new_sub())
        check(f"{P} flag on: suspended UNVERIFIED existing account -> generic conflict (409), still no session, no 'suspended' disclosure",
              r.status_code == 409 and not has_session(r) and "suspended" not in r.text.lower(), (r.status_code, r.text[:100]))

        # configured status honored (401 alternative)
        set_cfg(enabled=True, oauth_conflict_status=401)
        uid_c, email_c = make_user(f"{P}_on_cfg401")
        r = sign_in(client, P, email_c, new_sub())
        check(f"{P} flag on: conflict status comes from config (401)", r.status_code == 401 and not has_session(r), r.status_code)
        set_cfg(enabled=True)
    finally:
        logging.getLogger().removeHandler(cap)
    text = cap.text()
    leaks = [s for s in (email_u, email_u2, email_v, email_s2, "TOK_GOOGLE_" + TAG, "TOK_APPLE_" + TAG, sub_u, sub_v, sub_m, sub_n,
                         "attacker-set-hash") if s in text]
    check(f"{P} flag on: no email, token, sub or hash in any captured log line", not leaks, leaks)
    check(f"{P} flag on: refusal logged with opaque user id only",
          any("link refused" in l and uid_u in l for l in cap.lines), [l for l in cap.lines if "refused" in l][:2])


def test_config_validation():
    print("-- config validation")
    path = evc.CONFIG_PATH
    good = json.loads(path.read_text())
    check("shipped config ships enabled=true (switched on 2026-10-08)", BASE_CFG.enabled is True)
    check("shipped config has oauth_conflict_status/message",
          BASE_CFG.oauth_conflict_status in (401, 409) and BASE_CFG.oauth_conflict_message.strip() != "")

    def bad(label, mutate):
        d = json.loads(json.dumps(good))
        mutate(d["email_verification"])
        with tempfile.TemporaryDirectory() as td:
            p = evc.Path(td) / "ev.json"
            p.write_text(json.dumps(d))
            old = evc.CONFIG_PATH
            evc.CONFIG_PATH = p
            try:
                evc._cfg = None
                evc.validate_email_verification_config()
                check(label, False, "accepted")
            except ConfigSectionError:
                check(label, True)
            finally:
                evc.CONFIG_PATH = old
                evc._cfg = None
    bad("missing oauth_conflict_status rejected", lambda s: s.pop("oauth_conflict_status"))
    bad("missing oauth_conflict_message rejected", lambda s: s.pop("oauth_conflict_message"))
    bad("oauth_conflict_status 200 rejected", lambda s: s.update(oauth_conflict_status=200))
    bad("oauth_conflict_status 500 rejected", lambda s: s.update(oauth_conflict_status=500))
    bad("oauth_conflict_status wrong type rejected", lambda s: s.update(oauth_conflict_status="409"))
    bad("oauth_conflict_status bool rejected", lambda s: s.update(oauth_conflict_status=True))
    bad("empty oauth_conflict_message rejected", lambda s: s.update(oauth_conflict_message="   "))
    bad("overlong oauth_conflict_message rejected", lambda s: s.update(oauth_conflict_message="x" * 301))
    evc._cfg = None
    evc.validate_email_verification_config()
    set_cfg(enabled=False)
    check("shipped config validates after negative cases", evc.get_email_verification_config() is not None)


def cleanup():
    """Delete every account this script created (FK cascades clear the rest). Leaving
    seeded admins behind would break test_admin_seed_migration's exactly-one-admin check."""
    set_cfg(enabled=False)
    try:
        q("DELETE FROM users WHERE _id = ANY(%s::uuid[]) OR username LIKE %s", (USERS, f"ah{TAG}\\_%"))
    except Exception as e:
        print("cleanup warning:", type(e).__name__)


def main():
    require_scratch_db()
    saved_httpx = main_module.httpx.AsyncClient
    saved_jwt = main_module.jwt.decode
    saved_jwk = main_module._apple_jwk_client.get_signing_key_from_jwt
    saved_seed = os.environ.get("ADMIN_SEED_EMAIL")
    with TestClient(main_module.app) as client:
        try:
            test_config_validation()
            test_admin_seed_flag_off()
            test_flag_off_sql_parity()
            test_admin_seed_flag_on()
            test_admin_seed_missing_columns()
            test_oauth(client, "google")
            test_oauth(client, "apple")
        finally:
            main_module.httpx.AsyncClient = saved_httpx
            main_module.jwt.decode = saved_jwt
            main_module._apple_jwk_client.get_signing_key_from_jwt = saved_jwk
            if saved_seed is None:
                os.environ.pop("ADMIN_SEED_EMAIL", None)
            else:
                os.environ["ADMIN_SEED_EMAIL"] = saved_seed
            cleanup()
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    for l, d in FAILED:
        print("  FAILED:", l, "--", d)
    raise SystemExit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
