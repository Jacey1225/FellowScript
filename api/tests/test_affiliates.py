"""Backend coverage for task 20261007-affiliates-page (creator Affiliates API).

Proves: flag off (default) => uniform 404 on every route before auth, even for
a valid creator; 401 with no session; 403 {"detail":"Forbidden"} (no data) for a
non-creator, a user with no email match, an inactive code, an inactive creator,
a deleted code, a code awaiting owner email, and a friend code; case-insensitive
owner-email match; creator sees only aggregates (no subscriber ids, emails,
usernames anywhere in the body); cross-creator isolation; multi-code
aggregation; active paying excludes trialing/inactive/free/zero-price and
over-cap redemptions and counts a buyer once; earnings = configured rate x sum
of price_cents (rate comes from config, not code); day/week/month zero-filled
series (new + running total); milestones from config, one-time, persisted and
never regress on churn; client-supplied ids/query params ignored; resource
manifest / file download (manifest key only, traversal-ish keys 404, nosniff);
config loader validation; no subscriber PII in logs.

Run with: cd api && ../.venv/bin/python tests/test_affiliates.py
"""
import _pathfix  # noqa: F401

import dataclasses
import json
import logging
import os
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

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.interactions import flags  # noqa: E402
from backend.subscription import affiliates_config as ac  # noqa: E402
from backend.config_loader import ConfigSectionError  # noqa: E402

PASSED, FAILED = [], []
USERS, CREATORS, CODES = [], [], []
NO_ACCESS_BODY = {"detail": "Forbidden"}


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def ck(tok):
    return {"cookie": f"session={tok}"} if tok else {}


def hdr(tok=None):
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


def set_flag(state):
    q("INSERT INTO feature_flags (name, state) VALUES ('affiliates', %s) "
      "ON CONFLICT (name) DO UPDATE SET state = EXCLUDED.state", (state,))
    flags.invalidate()


def signup(client, email=None):
    name = f"aff_{uuid.uuid4().hex[:10]}"
    email = email or f"{name}@example.com"
    r = client.post("/signup", json={"username": name, "email": email, "plain_pass": "TestPass123!",
                                     "terms_accepted": True}, headers=hdr())
    assert r.status_code == 201, f"signup failed {r.status_code} {r.text}"
    uid = r.json()["user_id"]
    USERS.append(uid)
    # Email-verification flag is on in the shipped config: verification-gated
    # paths require a verified email. Same hash as email_verification.email_hash.
    q("UPDATE users SET email_verified = TRUE, email_verified_at = NOW(), "
      "email_verified_hash = encode(sha256(convert_to(lower(btrim(email)), 'UTF8')), 'hex') "
      "WHERE _id = %s", (uid,))
    return uid, r.cookies.get("session"), name, email


def mk_creator(active=True):
    cid = str(uuid.uuid4())
    q("INSERT INTO creators (_id, name, active) VALUES (%s, %s, %s)", (cid, f"C-{cid[:6]}", active))
    CREATORS.append(cid)
    return cid


def mk_code(creator_id, owner_email, active=True, deleted=False, requires_email=False):
    cid = str(uuid.uuid4())
    code = f"AFF{uuid.uuid4().hex[:8]}".upper()
    q("INSERT INTO promo_codes (_id, code, kind, creator_id, active, owner_email, deleted_at, "
      "requires_owner_email) VALUES (%s,%s,'creator',%s,%s,%s,%s,%s)",
      (cid, code, creator_id, active, owner_email, "2026-01-01" if deleted else None, requires_email))
    CODES.append(cid)
    return cid, code


def buyer(code_id, code, creator_id, status="active", plan="group", price=1000, over_cap=False,
          days_ago=0, trialing=False, redemptions=1):
    uid, _, name, email = signup(CLIENT)
    sid = str(uuid.uuid4())
    q("INSERT INTO subscriptions (_id, user_id, plan_type, provider, status, max_members, price_cents) "
      "VALUES (%s,%s,%s,'stripe',%s,1,%s)",
      (sid, uid, plan, "trialing" if trialing else status, price))
    q("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, uid))
    for _ in range(redemptions):
        q("INSERT INTO promo_redemptions (user_id, code_id, code, kind, creator_id, plan, platform, "
          "store_transaction_id, idempotency_key, over_cap, created_at) "
          "VALUES (%s,%s,%s,'creator',%s,'group','web',%s,%s,%s, NOW() - %s * interval '1 day')",
          (uid, code_id, code, creator_id, f"tx_{uuid.uuid4().hex}", f"idem_{uuid.uuid4().hex}", over_cap, days_ago))
    return {"uid": uid, "name": name, "email": email, "sid": sid}


def overview(tok, **kw):
    return CLIENT.get("/affiliates/overview", headers=hdr(tok), **kw)


class LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


def cleanup():
    try:
        for t in ("promo_redemptions",):
            q(f"DELETE FROM {t} WHERE creator_id = ANY(%s::uuid[])", (CREATORS,))
        q("DELETE FROM affiliate_milestones WHERE owner_email LIKE %s", ("%@affiliates-test.example",))
        q("DELETE FROM promo_codes WHERE _id = ANY(%s::uuid[])", (CODES,))
        q("DELETE FROM creators WHERE _id = ANY(%s::uuid[])", (CREATORS,))
        q("DELETE FROM subscriptions WHERE user_id = ANY(%s::uuid[])", (USERS,))
        q("DELETE FROM users WHERE _id = ANY(%s::uuid[])", (USERS,))
        set_flag("off")
    except Exception as e:  # cleanup best-effort
        print("cleanup warning:", type(e).__name__)


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_flag_off():
    print("\n== Flag off (default) ==")
    set_flag("off")
    check("flag registered default off", flags.is_enabled("affiliates") is False)
    ce = f"fo-{uuid.uuid4().hex[:8]}@affiliates-test.example"
    _, tok, _, _ = signup(CLIENT, ce)
    cr = mk_creator()
    mk_code(cr, ce)
    for path in ("/affiliates/overview", "/affiliates/resources", "/affiliates/resources/logo-mark/file"):
        r_anon = CLIENT.get(path, headers=hdr())
        r_creator = CLIENT.get(path, headers=hdr(tok))
        check(f"{path} 404 anon", r_anon.status_code == 404, r_anon.status_code)
        check(f"{path} 404 even for valid creator", r_creator.status_code == 404, r_creator.status_code)
        check(f"{path} identical 404 body", r_anon.json() == r_creator.json() == {"detail": "Not found"})


def test_authz():
    print("\n== AuthN/AuthZ (flag on) ==")
    set_flag("on")
    r = CLIENT.get("/affiliates/overview", headers=hdr())
    check("anon 401", r.status_code == 401, r.status_code)
    check("anon 401 on resources", CLIENT.get("/affiliates/resources", headers=hdr()).status_code == 401)
    check("anon 401 on file", CLIENT.get("/affiliates/resources/logo-mark/file", headers=hdr()).status_code == 401)

    _, tok, _, _ = signup(CLIENT)
    for path in ("/affiliates/overview", "/affiliates/resources", "/affiliates/resources/logo-mark/file"):
        r = CLIENT.get(path, headers=hdr(tok))
        check(f"non-creator 403 {path}", r.status_code == 403 and r.json() == NO_ACCESS_BODY, (r.status_code, r.text))

    def denied(label, **code_kw):
        ce = f"d-{uuid.uuid4().hex[:8]}@affiliates-test.example"
        _, t, _, _ = signup(CLIENT, ce)
        creator_active = code_kw.pop("creator_active", True)
        cr = mk_creator(active=creator_active)
        mk_code(cr, ce, **code_kw)
        r = overview(t)
        check(label, r.status_code == 403 and r.json() == NO_ACCESS_BODY, (r.status_code, r.text))

    denied("inactive code => 403", active=False)
    denied("inactive creator => 403", creator_active=False)
    denied("soft-deleted code => 403", deleted=True)
    denied("code awaiting owner email => 403", requires_email=True)

    # code owned by someone else's email
    _, t2, _, _ = signup(CLIENT)
    mk_code(mk_creator(), f"other-{uuid.uuid4().hex[:8]}@affiliates-test.example")
    check("code for another email => 403", overview(t2).status_code == 403)

    # friend code with matching referrer never grants access (kind='creator' only)
    fe = f"fr-{uuid.uuid4().hex[:8]}@affiliates-test.example"
    fuid, ft, _, _ = signup(CLIENT, fe)
    q("INSERT INTO promo_codes (code, kind, referrer_user_id, owner_email) VALUES (%s,'friend',%s,%s)",
      (f"FRD{uuid.uuid4().hex[:8]}".upper(), fuid, fe))
    check("friend code owner => 403", overview(ft).status_code == 403)

    # an email-less account (empty email) must never match
    ue = f"ue-{uuid.uuid4().hex[:8]}@affiliates-test.example"
    uid_, ut, _, _ = signup(CLIENT, ue)
    mk_code(mk_creator(), ue.upper())
    check("case-insensitive email match => 200", overview(ut).status_code == 200)

    # forged/invalid session
    check("bogus session 401", CLIENT.get("/affiliates/overview", headers=hdr("not-a-session")).status_code == 401)


def test_aggregates_and_privacy():
    print("\n== Aggregates, earnings, privacy, isolation ==")
    set_flag("on")
    ce = f"agg-{uuid.uuid4().hex[:8]}@affiliates-test.example"
    cuid, tok, cname, _ = signup(CLIENT, ce)
    cr = mk_creator()
    code_id, code = mk_code(cr, ce)

    b1 = buyer(code_id, code, cr, price=1000)
    b2 = buyer(code_id, code, cr, price=2000)
    b3 = buyer(code_id, code, cr, price=1500, redemptions=3)        # counted once
    buyer(code_id, code, cr, trialing=True, price=1000)              # trialing excluded
    buyer(code_id, code, cr, status="canceled", price=1000)         # not active
    buyer(code_id, code, cr, plan="free", price=1000)               # free excluded
    buyer(code_id, code, cr, price=0)                                # zero price excluded
    buyer(code_id, code, cr, over_cap=True, price=1000)              # over-cap excluded
    subs = [b1, b2, b3]

    r = overview(tok)
    check("creator 200", r.status_code == 200, r.status_code)
    body = r.json()
    m = body["metrics"]
    check("active paying = 3", m["active_paying_subscribers"] == 3, m)
    check("earnings = 0.2 x 4500 = 900", m["monthly_earnings_cents"] == 900, m)
    check("commission_rate echoed 0.2", m["commission_rate"] == 0.2, m)
    check("no-store cache header", r.headers.get("cache-control") == "no-store", r.headers.get("cache-control"))
    check("own code listed with link", body["codes"] == [{"code": code, "active": True,
          "link": f"https://fellowscript.com/?code={code}"}], body["codes"])
    check("top-level keys are the aggregate set",
          set(body) == {"v", "codes", "metrics", "series", "milestones", "generated_at"}, set(body))

    raw = r.text.lower()
    leaked = [s for s in subs for k in ("uid", "name", "email", "sid") if str(s[k]).lower() in raw]
    check("no subscriber id/name/email/sub-id in body", not leaked, leaked)
    check("no email-shaped strings in body", "@" not in raw, [w for w in raw.split('"') if "@" in w][:3])

    # series
    s = body["series"]
    check("series has day/week/month", set(s) == {"day", "week", "month"})
    cfg = ac.get_affiliates_config()
    for unit in ("day", "week", "month"):
        pts = s[unit]
        check(f"{unit} series length from config", len(pts) == cfg.series_points[unit], len(pts))
        check(f"{unit} point shape", all(set(p) == {"t", "new", "total"} for p in pts))
        check(f"{unit} running total monotonic", all(a["total"] <= b["total"] for a, b in zip(pts, pts[1:])))
        check(f"{unit} last total = sum of new (all within window)",
              pts[-1]["total"] == sum(p["new"] for p in pts))
    # day series: all 8 buyer rows today minus over-cap = 7 buyers with 9 redemptions (b3 x3) => 3+... compute
    exp_new = q("SELECT COUNT(*) FROM promo_redemptions WHERE creator_id=%s AND NOT over_cap", (cr,))[0][0]
    check("day final total equals DB non-over-cap redemptions", s["day"][-1]["total"] == exp_new,
          (s["day"][-1], exp_new))
    check("today's bucket has the new redemptions", s["day"][-1]["new"] == exp_new, s["day"][-1])

    # older redemption lands in an older bucket, zero-fill between
    buyer(code_id, code, cr, price=1000, days_ago=5)
    s2 = overview(tok).json()["series"]["day"]
    check("5-days-ago bucket has 1", s2[-6]["new"] == 1, s2[-7:])
    check("gap buckets zero-filled", all(p["new"] == 0 for p in s2[-5:-1]), s2[-6:])
    check("running total includes older", s2[-1]["total"] == exp_new + 1)

    # config-driven rate
    saved = ac._cfg
    try:
        ac._cfg = dataclasses.replace(saved, commission_rate=0.5)
        m2 = overview(tok).json()["metrics"]
        check("earnings follow config rate (0.5)", m2["monthly_earnings_cents"] == int(5500 * 0.5), m2)
    finally:
        ac._cfg = saved

    # client-supplied identity ignored
    other_e = f"oth-{uuid.uuid4().hex[:8]}@affiliates-test.example"
    ouid, otok, _, _ = signup(CLIENT, other_e)
    ocr = mk_creator()
    ocid, ocode = mk_code(ocr, other_e)
    buyer(ocid, ocode, ocr, price=9900)
    for kw in ({"params": {"creator_id": ocr, "code_id": ocid, "code": ocode, "email": other_e, "user_id": ouid}},
               {"headers": {**hdr(tok), "x-user-id": ouid}}):
        r = overview(tok, **kw) if "params" in kw else CLIENT.get("/affiliates/overview", **kw)
        mm = r.json()["metrics"]
        check("client-supplied id/code/email ignored", r.status_code == 200 and mm["active_paying_subscribers"] == 4
              and ocode not in r.text, mm)

    # isolation
    ro = overview(otok).json()
    check("other creator sees only own (1 sub, 9900x.35=3465)",
          ro["metrics"]["active_paying_subscribers"] == 1 and ro["metrics"]["monthly_earnings_cents"] == 3465, ro["metrics"])
    check("other creator never sees first creator's code", code not in json.dumps(ro))
    check("first creator never sees other's code", ocode not in overview(tok).text)
    check("other creator's body has no subscriber emails", "@" not in json.dumps(ro))

    # multi-code aggregation across creators rows for the same email
    cr2 = mk_creator()
    c2id, c2code = mk_code(cr2, ce.upper())
    buyer(c2id, c2code, cr2, price=1000)
    ma = overview(tok).json()
    check("multi-code: aggregated across all caller's codes (4 + 1)",
          ma["metrics"]["active_paying_subscribers"] == 5, ma["metrics"])
    check("multi-code: both codes listed", {c["code"] for c in ma["codes"]} == {code, c2code}, ma["codes"])
    # inactive sibling code stays listed but live code keeps access
    q("UPDATE promo_codes SET active = FALSE WHERE _id = %s", (c2id,))
    mb = overview(tok)
    check("one inactive code, one active => still 200", mb.status_code == 200)


def test_milestones():
    print("\n== Milestones ==")
    set_flag("on")
    saved = ac._cfg
    try:
        ac._cfg = dataclasses.replace(saved, milestones=(ac.Milestone(2, 10000), ac.Milestone(3, 25000),
                                                         ac.Milestone(5, 150000)))
        ce = f"ms-{uuid.uuid4().hex[:8]}@affiliates-test.example"
        _, tok, _, _ = signup(CLIENT, ce)
        cr = mk_creator()
        cid, code = mk_code(cr, ce)
        b = [buyer(cid, code, cr, price=1000) for _ in range(1)]
        ms = overview(tok).json()["milestones"]
        check("below tier 1: none earned", [m["earned"] for m in ms] == [False, False, False], ms)
        check("not-earned has no date and shows configured bonus",
              ms[0]["earned_at"] is None and ms[0]["bonus_cents"] == 10000, ms[0])
        b += [buyer(cid, code, cr, price=1000) for _ in range(2)]
        ms = overview(tok).json()["milestones"]
        check("3 active: tiers 2 and 3 earned, 5 not", [m["earned"] for m in ms] == [True, True, False], ms)
        check("earned has a date", ms[0]["earned_at"] is not None)
        rows = q("SELECT tier_subscribers FROM affiliate_milestones WHERE owner_email = %s ORDER BY 1", (ce,))
        check("two persisted rows", rows == [(2,), (3,)], rows)
        # churn all
        for x in b:
            q("UPDATE subscriptions SET status = 'canceled' WHERE _id = %s", (x["sid"],))
        r = overview(tok).json()
        check("churn: active count drops to 0", r["metrics"]["active_paying_subscribers"] == 0)
        check("churn: earned tiers do not regress", [m["earned"] for m in r["milestones"]] == [True, True, False],
              r["milestones"])
        first_date = ms[0]["earned_at"]
        # re-reach tier: still one row, one-time
        for x in b:
            q("UPDATE subscriptions SET status = 'active' WHERE _id = %s", (x["sid"],))
        overview(tok); overview(tok)
        rows = q("SELECT COUNT(*) FROM affiliate_milestones WHERE owner_email = %s", (ce,))[0][0]
        check("one-time per tier: still 2 rows after repeated reads", rows == 2, rows)
        check("earned_at stable", overview(tok).json()["milestones"][0]["earned_at"] == first_date)
        # persisted keyed by lowercase email: uppercase owner email -> same record
        check("persisted owner_email lowercase", q("SELECT bool_and(owner_email = LOWER(owner_email)) FROM "
              "affiliate_milestones WHERE owner_email = %s", (ce,))[0][0] is True)
        # per-creator isolation of milestones
        oe = f"ms2-{uuid.uuid4().hex[:8]}@affiliates-test.example"
        _, otok, _, _ = signup(CLIENT, oe)
        ocr = mk_creator()
        mk_code(ocr, oe)
        check("other creator has no earned tiers", not any(m["earned"] for m in overview(otok).json()["milestones"]))
    finally:
        ac._cfg = saved
    # default config tiers
    ms = None
    ce = f"msd-{uuid.uuid4().hex[:8]}@affiliates-test.example"
    _, tok, _, _ = signup(CLIENT, ce)
    cr = mk_creator()
    mk_code(cr, ce)
    ms = overview(tok).json()["milestones"]
    check("default milestones 50/$100, 100/$250, 500/$1500",
          [(m["subscribers"], m["bonus_cents"]) for m in ms] == [(50, 10000), (100, 25000), (500, 150000)], ms)


def test_resources():
    print("\n== Resources ==")
    set_flag("on")
    ce = f"res-{uuid.uuid4().hex[:8]}@affiliates-test.example"
    _, tok, _, _ = signup(CLIENT, ce)
    mk_code(mk_creator(), ce)
    r = CLIENT.get("/affiliates/resources", headers=hdr(tok))
    check("resources 200", r.status_code == 200, r.status_code)
    items = r.json()["resources"]
    secs = {i["section"] for i in items}
    check("sections present: logos, guides, ads, qr", {"logos", "guides", "ads", "qr"} <= secs, secs)
    check("items only expose key/section/label/content_type/url",
          all(set(i) == {"key", "section", "label", "content_type", "url"} for i in items))
    check("no filesystem paths in listing", "/Users" not in r.text and "api/assets" not in r.text)
    sample = items[0]
    f = CLIENT.get(sample["url"], headers=hdr(tok))
    check("file download 200", f.status_code == 200 and len(f.content) > 100, f.status_code)
    check("nosniff", f.headers.get("x-content-type-options") == "nosniff")
    check("CSP sandbox", f.headers.get("content-security-policy") == "sandbox")
    check("content type matches manifest", f.headers["content-type"].split(";")[0] == sample["content_type"])
    svgs = [i for i in items if i["content_type"] == "image/svg+xml"]
    if svgs:
        fs = CLIENT.get(svgs[0]["url"], headers=hdr(tok))
        check("svg forced to attachment", "attachment" in fs.headers.get("content-disposition", ""))
    for bad in ("..%2f..%2fdb.py", "unknown-key", "logo-mark%00", "%2e%2e%2fmain.py", "LOGO-MARK"):
        rb = CLIENT.get(f"/affiliates/resources/{bad}/file", headers=hdr(tok))
        check(f"bad key {bad!r} => 404", rb.status_code == 404, rb.status_code)
    # all manifest files exist locally (assets copies)
    cfg = ac.get_affiliates_config()
    missing = [r_.key for r_ in cfg.resources if not (ac.ASSETS_DIR / r_.asset_name).is_file()]
    check("every manifest resource has an asset copy", not missing, missing)
    check("listing count = manifest count", len(items) == len(cfg.resources), (len(items), len(cfg.resources)))


def test_config():
    print("\n== Config validation ==")
    def attempt(mut):
        raw = json.load(open(ac.CONFIG_PATH))
        mut(raw["affiliates"])
        import tempfile
        p = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(raw, p)
        p.close()
        old = ac.CONFIG_PATH
        ac.CONFIG_PATH = __import__("pathlib").Path(p.name)
        try:
            ac._load()
            return None
        except ConfigSectionError as e:
            return str(e)
        finally:
            ac.CONFIG_PATH = old
            os.unlink(p.name)
    check("shipped config loads", attempt(lambda c: None) is None)
    check("commission_rate 0 refused", attempt(lambda c: c.__setitem__("commission_rate", 0)) is not None)
    check("commission_rate 1.5 refused", attempt(lambda c: c.__setitem__("commission_rate", 1.5)) is not None)
    check("missing key refused", attempt(lambda c: c.pop("milestones")) is not None)
    check("unknown key refused", attempt(lambda c: c.__setitem__("surprise", 1)) is not None)
    check("empty milestones refused", attempt(lambda c: c.__setitem__("milestones", [])) is not None)
    check("non-ascending milestones refused",
          attempt(lambda c: c.__setitem__("milestones", [{"subscribers": 5, "bonus_cents": 1},
                                                         {"subscribers": 5, "bonus_cents": 2}])) is not None)
    check("http base url refused", attempt(lambda c: c.__setitem__("public_base_url", "http://x.com")) is not None)
    check("link format without {code} refused", attempt(lambda c: c.__setitem__("code_link_format", "{base}/")) is not None)
    check("bad rate limit refused", attempt(lambda c: c.__setitem__("rate_limit", "lots")) is not None)
    def trav(c): c["resources"][0]["file"] = "../../.env"
    check("path traversal in resource file refused", attempt(trav) is not None)
    def dupkey(c): c["resources"][1]["key"] = c["resources"][0]["key"]
    check("duplicate resource key refused", attempt(dupkey) is not None)
    def badct(c): c["resources"][0]["content_type"] = "text/html"
    check("html content type refused", attempt(badct) is not None)
    cfg = ac.get_affiliates_config()
    check("loaded rate 0.2, 3 tiers", cfg.commission_rate == 0.2 and len(cfg.milestones) == 3)


def test_no_pii_in_logs():
    print("\n== Logs ==")
    set_flag("on")
    cap = LogCapture()
    root = logging.getLogger()
    old_level = root.level
    root.addHandler(cap)
    root.setLevel(logging.DEBUG)
    try:
        ce = f"lg-{uuid.uuid4().hex[:8]}@affiliates-test.example"
        _, tok, _, _ = signup(CLIENT, ce)
        cr = mk_creator()
        cid, code = mk_code(cr, ce)
        s = buyer(cid, code, cr, price=1000)
        cap.lines.clear()
        overview(tok)
        CLIENT.get("/affiliates/resources", headers=hdr(tok))
        _, ntok, nname, nemail = signup(CLIENT)
        cap.lines.clear()
        CLIENT.get("/affiliates/overview", headers=hdr(ntok))
        joined = "\n".join(cap.lines).lower()
        check("no subscriber email/name in logs", s["email"].lower() not in joined and s["name"].lower() not in joined)
        check("no creator email in logs", ce.lower() not in joined)
        check("denied caller's email not in logs", nemail.lower() not in joined)
        check("denial logged without PII", any("affiliates denied" in l for l in cap.lines), cap.lines)
    finally:
        root.removeHandler(cap)
        root.setLevel(old_level)


def test_flag_default_seed():
    print("\n== Registry ==")
    from schema_ddl.flags import SEED_FLAG_NAMES
    check("'affiliates' seeded", "affiliates" in SEED_FLAG_NAMES)
    check("affiliates_milestones module in DDL_MODULES", any("affiliate_milestones" in str(m) for m in __import__("db").DDL_MODULES))


if __name__ == "__main__":
    import sys
    CLIENT = TestClient(main_module.app)
    CLIENT.__enter__()
    try:
        test_flag_default_seed()
        test_flag_off()
        test_authz()
        test_aggregates_and_privacy()
        test_milestones()
        test_resources()
        test_config()
        test_no_pii_in_logs()
    finally:
        cleanup()
        CLIENT.__exit__(None, None, None)
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    for l, d in FAILED:
        print("FAILED:", l, d)
    sys.exit(1 if FAILED else 0)
