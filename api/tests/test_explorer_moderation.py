"""Tests for task 20261001-explorer-listings, step 6 (moderation) -- proved at step 7.

Properties proved (each would catch a regression of the behaviour it names):
  1. Report resolver: a group_listing report is keyed on the 10-char public_id,
     stores the CANONICAL listing UUID in content_reports.content_id (never the
     public_id), snapshots the listing text, attributes the report to the owner,
     answers 404 and stores nothing for an unknown id, 422 for a malformed id.
  2. Auto-hide: 2 distinct reporters leave the listing published; the same
     reporter twice, the owner's own report and dismissed reports never count;
     the 3rd distinct open reporter hides it (reason 'reported'), runs the
     listing_hidden hooks once and emails the owner once; only pending/published
     listings are acted on.
  3. Admin endpoints (/admin/explorer/listings): 401 without a session, 403 for a
     non-admin on every route, queue shape, approve/reject/hide/restore/delete
     transitions with 409 invalid_state, 422 invalid_reason / invalid_status, ONE
     uniform 404 for an unknown vs malformed id, 409 owner_unavailable for a
     suspended owner, strict body (extra field 422), owner email on reject/hide.
  4. CLI in fresh subprocesses: admin_listings hide/restore/hide-all (exit codes,
     reasons, hooks) and admin_actions list/resolve (--remove-content,
     --eject, --dismiss) for group_listing.
  5. Suspended owner: hide_listings_of_owner hides only that owner's
     pending/published listings (owner_suspended, hooks fire, not public) and
     --eject does it at once; restore/approve then refuse (owner_unavailable).
  6. PUT /groups owner-only guard (409 owner_only) applies ONLY while the group
     has pending_review/published/hidden presence; groups with no listing, a draft,
     unpublished or rejected listing keep build-78 behaviour.
  7. Lifecycle: group delete / last-member leave removes the listing; reports about
     a listing survive the listing's deletion (snippet kept); a report is deleted
     with the reporter or the reported account (documented J14 default).
  8. Word lists: every configured youth term and every blocked link host is
     rejected; reject/hide reason codes each have an owner label and are accepted
     only on their own endpoint; profanity is refused.
  9. Per-reporter rate limit: 10 listing reports per window then 429 with nothing
     stored; another reporter and other report types unaffected.
 10. Logging: no listing text, report text, e-mail address or ERROR-level line from
     the report / auto-hide / admin / notify flow, including a failing e-mail.

Scratch database only: SHOW port must be 55432 (asserted first, here and in the
fresh subprocesses). Rows are uuid-derived and removed in finally; feature flags
are restored. Run: cd api && ../.venv/bin/python tests/test_explorer_moderation.py
"""
import _pathfix  # noqa: F401

import html
import logging
import os
import subprocess
import sys
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from backend.interactions import flags, lifecycle, listing_reports, listings, reports  # noqa: E402
from backend.interactions.listings_config import get_listings_config  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from backend.registrations import load_all  # noqa: E402
from backend.moderation import removers  # noqa: E402
from schemas.users import CURRENT_TERMS_VERSION  # noqa: E402

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSED, FAILED = [], []
USERS, GROUPS = [], []
NOT_FOUND = {"detail": {"code": "not_found", "message": "Not found"}}
ADMIN = "/admin/explorer/listings"


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


# -- helpers ------------------------------------------------------------------

def q(sql, params=(), fetch=True):
    db = DBManager()
    try:
        db.cur.execute(sql, params)
        rows = db.cur.fetchall() if fetch and db.cur.description else None
        db.conn.commit()
        return rows
    finally:
        db.close()


def make_user(admin=False, suspended=False):
    uid = str(uuid.uuid4())
    q("INSERT INTO users (_id, username, email, hash_pass, is_admin, suspended_at, terms_version) "
      "VALUES (%s,%s,%s,'x',%s,%s,%s)",
      (uid, f"xm_{uid[:8]}", f"xm_{uid[:8]}@example.com", admin, "2020-01-01" if suspended else None,
       CURRENT_TERMS_VERSION), fetch=False)
    USERS.append(uid)
    return uid


def hdr(uid):
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def make_group(creator, members=None, title="Xm Test Group"):
    gid = str(uuid.uuid4())
    users = [creator] + [m for m in (members or []) if m != creator]
    q("INSERT INTO groups (_id, title, users, creator_id) VALUES (%s,%s,%s,%s)", (gid, title, users, creator),
      fetch=False)
    GROUPS.append(gid)
    return gid


def lrow(gid, cols="status"):
    r = q(f"SELECT {cols} FROM group_listings WHERE group_id = %s", (gid,))
    return r[0] if r else None


def status(gid):
    r = lrow(gid)
    return r[0] if r else None


def pid(gid):
    return lrow(gid, "public_id")[0]


def lid(gid):
    return lrow(gid, "_id::text")[0]


def visible(gid):
    return bool(q(f"SELECT 1 FROM group_listings gl WHERE gl.group_id = %s AND {listings.public_where('gl')}", (gid,)))


def admin_do(fn, *args):
    db = DBManager()
    try:
        out = fn(db.cur, *args)
        db.conn.commit()
        return out
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


def mk_listing(cli, owner, members=None, title="Moderation group", publish=True, admin=None, state=None):
    """Create a listing through the owner API; approve it unless publish=False."""
    gid = make_group(owner, members, title=title)
    ho = hdr(owner)
    limiter.reset()
    r = cli.put(f"/explorer/{owner}/groups/{gid}/listing", json={"title": title, "summary": "We read together"}, headers=ho)
    assert r.status_code == 200, r.text
    if publish:
        limiter.reset()
        r = cli.post(f"/explorer/{owner}/groups/{gid}/listing/submit", json={"consent": True, "adult_attested": True},
                     headers=ho)
        assert r.status_code == 200, r.text
        if state != "pending_review":
            admin_do(listings.admin_approve, pid(gid), admin or owner)
    return gid


def report(cli, reporter, public_id, reason="spam", detail=""):
    limiter.reset()
    return cli.post("/reports/", json={"content_type": "group_listing", "content_id": public_id, "reason": reason,
                                       "detail": detail}, headers=hdr(reporter))


def cleanup():
    for g in GROUPS:
        q("DELETE FROM invites WHERE target_id = %s", (g,), fetch=False)
        q("DELETE FROM messages WHERE group_id = %s", (g,), fetch=False)
        q("DELETE FROM groups WHERE _id = %s", (g,), fetch=False)
    for u in USERS:
        q("DELETE FROM content_reports WHERE reporter_id = %s OR reported_user_id = %s", (u, u), fetch=False)
        q("DELETE FROM users WHERE _id = %s", (u,), fetch=False)


class LogCatcher(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.records = []

    def emit(self, record):
        self.records.append((record.levelname, record.getMessage()))


class catch_logs:
    def __enter__(self):
        self.h = LogCatcher()
        self.root = logging.getLogger()
        self.old = self.root.level
        self.root.setLevel(logging.DEBUG)
        self.root.addHandler(self.h)
        return self.h

    def __exit__(self, *a):
        self.root.removeHandler(self.h)
        self.root.setLevel(self.old)


class Mailbox:
    """Replaces every SES send path so no test touches the network."""

    def __init__(self, fail=False):
        self.sent = []
        self.fail = fail

    def __call__(self, to, subject, html_body, text_body):
        if self.fail:
            from backend.email.ses_client import EmailSendError
            raise EmailSendError("simulated")
        self.sent.append((to, subject, html_body, text_body))

    def to_owner(self, email):
        return [m for m in self.sent if m[0] == email]

    def __enter__(self):
        from backend.email import ses_client
        self._ses, self._rep = ses_client.send_email, reports.send_email
        ses_client.send_email = self
        reports.send_email = self
        return self

    def __exit__(self, *a):
        from backend.email import ses_client
        ses_client.send_email = self._ses
        reports.send_email = self._rep


def email_of(uid):
    return q("SELECT email FROM users WHERE _id = %s", (uid,))[0][0]


def run_cli(module, *args):
    code = ("from db import DBManager\ndb = DBManager()\ndb.cur.execute('SHOW port')\n"
            "p = db.cur.fetchone()[0]\ndb.close()\nimport sys\n"
            "if p != '55432':\n    sys.exit(99)\n"
            f"import runpy\nsys.argv = [{module!r}] + {list(args)!r}\n"
            f"runpy.run_module({module!r}, run_name='__main__')\n")
    return subprocess.run([sys.executable, "-c", code], cwd=API_DIR, capture_output=True, text=True, timeout=180)


def dcode(r):
    d = r.json().get("detail")
    return d.get("code") if isinstance(d, dict) else None


# -- 1. resolver ----------------------------------------------------------------

def test_resolver(cli):
    print("report resolver: group_listing keyed on public_id, canonical UUID stored")
    check("resolver registered for group_listing", "group_listing" in reports.CONTENT_RESOLVERS)
    check("remover registered for group_listing (cold process via load_all)", "group_listing" in removers.CONTENT_REMOVERS)
    check("after-report hook registered", "group_listing" in reports.CONTENT_AFTER_REPORT)
    owner, reporter = make_user(), make_user()
    admin = make_user(admin=True)
    gid = mk_listing(cli, owner, title="Resolver Fellowship", admin=admin)
    with Mailbox():
        r = report(cli, reporter, pid(gid), reason="spam", detail="looks off")
    check("report by public_id -> 201", r.status_code == 201 and "id" in r.json(), (r.status_code, r.text))
    row = q("SELECT content_id::text, content_snippet, reported_user_id::text, reporter_id::text, status "
            "FROM content_reports WHERE _id = %s", (r.json()["id"],))[0]
    check("stored content_id is the canonical listing UUID", row[0] == lid(gid), (row[0], lid(gid)))
    check("stored content_id is NOT the public_id", row[0] != pid(gid))
    check("snapshot holds public_id and title", pid(gid) in row[1] and "Resolver Fellowship" in row[1], row[1][:120])
    check("report is attributed to the listing owner, not client input", row[2] == owner)
    check("report is open and bound to reporter", row[4] == "open" and row[3] == reporter)
    big = "x" * 8000
    db = DBManager()
    try:
        db.cur.execute("UPDATE group_listings SET description_text = %s WHERE group_id = %s", (big, gid))
        res = reports.CONTENT_RESOLVERS["group_listing"](db.cur, pid(gid), "")
        db.conn.rollback()
    finally:
        db.close()
    check("snapshot is capped at 5000 chars", len(res[1]) <= 5000, len(res[1]))
    for label, cid, want in (("unknown public_id", "ZzZzZzZz12", 404), ("short id", "short", 422),
                             ("uuid instead of public_id", lid(gid), 422), ("11 chars", "x" * 11, 422),
                             ("punctuation", "abc-def-gh", 422)):
        before = q("SELECT count(*) FROM content_reports WHERE reporter_id = %s", (reporter,))[0][0]
        with Mailbox():
            r = report(cli, reporter, cid)
        after = q("SELECT count(*) FROM content_reports WHERE reporter_id = %s", (reporter,))[0][0]
        check(f"{label} -> {want} and nothing stored", r.status_code == want and before == after, (r.status_code, r.text))
    limiter.reset()
    r = cli.post("/reports/", json={"content_type": "group_listing", "reason": "x"}, headers=hdr(reporter))
    check("missing content_id -> 422", r.status_code == 422, r.status_code)
    limiter.reset()
    r = cli.post("/reports/", json={"content_type": "group_listing", "content_id": pid(gid), "reason": "x"})
    check("unauthenticated report -> 401", r.status_code == 401, r.status_code)


# -- 2. auto hide ----------------------------------------------------------------

def test_auto_hide(cli):
    print("auto-hide at 3 distinct reporters")
    thr = get_listings_config().report_auto_hide_threshold
    check("threshold is 3", thr == 3, thr)
    owner = make_user()
    admin = make_user(admin=True)
    r1, r2, r3, r4 = make_user(), make_user(), make_user(), make_user()
    gid = mk_listing(cli, owner, title="Auto hide group", admin=admin)
    captured = []
    hook = lambda cur, g, reason: captured.append((g, reason)) or []  # noqa: E731
    lifecycle.register("listing_hidden", hook)
    try:
        with Mailbox() as mb:
            report(cli, r1, pid(gid))
            report(cli, r1, pid(gid), reason="again")
            check("same reporter twice counts once (still published)", status(gid) == "published", status(gid))
            report(cli, owner, pid(gid), reason="self")
            check("the owner's own report never counts", status(gid) == "published")
            report(cli, r2, pid(gid))
            check("2 distinct reporters: still published and visible", status(gid) == "published" and visible(gid))
            check("no owner email below threshold", not mb.to_owner(email_of(owner)))
            r = report(cli, r3, pid(gid))
            check("3rd distinct reporter: report still stored (201)", r.status_code == 201, r.text)
            check("listing hidden with reason 'reported'",
                  lrow(gid, "status, hidden_reason_code") == ("hidden", "reported"), lrow(gid, "status, hidden_reason_code"))
            check("hidden listing is not public", not visible(gid))
            check("listing_hidden hooks ran once with (group, 'reported')", captured.count((gid, "reported")) == 1, captured)
            mails = mb.to_owner(email_of(owner))
            check("owner emailed exactly once", len(mails) == 1, len(mails))
            check("owner email names the reported reason label",
                  html.escape(listing_reports.REASON_LABELS["reported"]) in mails[0][2], mails[0][1])
            check("owner email carries no reporter identity",
                  all(email_of(u) not in mails[0][2] + mails[0][3] for u in (r1, r2, r3)))
            n = len(captured)
            report(cli, r4, pid(gid))
            check("a further report on a hidden listing does not re-run hooks or re-hide", len(captured) == n)

        # dismissed reports do not count; owner reports do not count
        o2, a, b, c = make_user(), make_user(), make_user(), make_user()
        g2 = mk_listing(cli, o2, title="Dismissed group", admin=admin)
        with Mailbox():
            report(cli, a, pid(g2))
            report(cli, b, pid(g2))
            q("UPDATE content_reports SET status = 'dismissed' WHERE content_id = %s", (lid(g2),), fetch=False)
            report(cli, c, pid(g2))
        check("dismissed reports do not count toward the threshold", status(g2) == "published", status(g2))

        # pending_review listings are auto-hidden too; draft/unpublished are not touched
        o3 = make_user()
        g3 = mk_listing(cli, o3, title="Pending group", state="pending_review")
        check("setup: pending_review", status(g3) == "pending_review")
        with Mailbox():
            for u in (make_user(), make_user(), make_user()):
                report(cli, u, pid(g3))
        check("pending_review listing auto-hides too", status(g3) == "hidden")
        o4 = make_user()
        g4 = mk_listing(cli, o4, title="Unpublished group", admin=admin)
        limiter.reset()
        cli.post(f"/explorer/{o4}/groups/{g4}/listing/unpublish", headers=hdr(o4))
        check("setup: unpublished", status(g4) == "unpublished", status(g4))
        with Mailbox() as mb:
            for u in (make_user(), make_user(), make_user()):
                report(cli, u, pid(g4))
        check("an unpublished listing is not acted on by auto-hide (no owner email)",
              status(g4) == "unpublished" and not mb.to_owner(email_of(o4)), status(g4))
        o5 = make_user()
        g5 = mk_listing(cli, o5, title="Draft group", publish=False)
        with Mailbox():
            for u in (make_user(), make_user(), make_user()):
                report(cli, u, pid(g5))
        check("a draft is not acted on by auto-hide", status(g5) == "draft", status(g5))

        # hook failure never fails the report
        o6 = make_user()
        g6 = mk_listing(cli, o6, title="Hook failure", admin=admin)
        real = listings.auto_hide_if_reported

        def boom(*a, **k):
            raise RuntimeError("hook down")
        listings.auto_hide_if_reported = boom
        try:
            with Mailbox():
                with catch_logs() as lg:
                    r = report(cli, make_user(), pid(g6))
        finally:
            listings.auto_hide_if_reported = real
        check("after-report hook failure still stores the report (201)", r.status_code == 201, (r.status_code, r.text))
        check("failure is a WARNING only", any(lv == "WARNING" and "AFTER_REPORT_HOOK_FAILED" in m for lv, m in lg.records)
              and not [m for lv, m in lg.records if lv == "ERROR"], lg.records[:3])
        check("listing unaffected by the failed hook", status(g6) == "published")
    finally:
        lifecycle._registry["listing_hidden"].remove(hook)


# -- 3. admin endpoints -----------------------------------------------------------

def test_admin_endpoints(cli):
    print("admin endpoints: authz, transitions, uniform errors")
    admin, plain = make_user(admin=True), make_user()
    owner = make_user()
    gid = mk_listing(cli, owner, title="Admin & Probe", publish=True, state="pending_review")
    p = pid(gid)
    ha, hp = hdr(admin), hdr(plain)
    routes = [("get", f"{ADMIN}/queue", None), ("post", f"{ADMIN}/{p}/approve", None),
              ("post", f"{ADMIN}/{p}/reject", {"reason_code": "spam"}),
              ("post", f"{ADMIN}/{p}/hide", {"reason_code": "spam"}),
              ("post", f"{ADMIN}/{p}/restore", None), ("delete", f"{ADMIN}/{p}", None)]
    for method, url, body in routes:
        limiter.reset()
        r = getattr(cli, method)(url, **({"json": body} if body is not None else {}))
        check(f"{method.upper()} {url.replace(p, '<id>')} unauthenticated -> 401", r.status_code == 401, r.status_code)
        limiter.reset()
        r = getattr(cli, method)(url, headers=hp, **({"json": body} if body is not None else {}))
        check(f"{method.upper()} {url.replace(p, '<id>')} non-admin -> 403", r.status_code == 403, r.status_code)
    check("non-admin attempts changed nothing", status(gid) == "pending_review")
    check("owner of the listing is not an admin", cli.get(f"{ADMIN}/queue", headers=hdr(owner)).status_code in (403, 429))

    limiter.reset()
    with Mailbox() as mb:
        r = cli.get(f"{ADMIN}/queue", headers=ha)
        items = r.json().get("items", []) if r.status_code == 200 else []
        mine = [i for i in items if i["public_id"] == p]
        check("queue (default pending_review) lists the listing", r.status_code == 200 and len(mine) == 1, (r.status_code, r.text[:200]))
        check("queue item shape", mine and set(mine[0]) == {"public_id", "status", "title", "summary", "group_id", "owner_id",
                                                           "hidden_reason_code", "reject_reason_code", "updated_at",
                                                           "open_reports"}, mine[:1])
        limiter.reset()
        r = cli.get(f"{ADMIN}/queue?status=bogus", headers=ha)
        check("queue invalid status -> 422 invalid_status", r.status_code == 422 and dcode(r) == "invalid_status", r.text)
        limiter.reset()
        r = cli.get(f"{ADMIN}/queue?status=pending_review&limit=1", headers=ha)
        check("queue limit honoured", r.status_code == 200 and len(r.json()["items"]) <= 1)
        limiter.reset()
        r = cli.get(f"{ADMIN}/queue?status=published&limit=1000", headers=ha)
        check("queue limit above max is clamped, not 500", r.status_code == 200 and len(r.json()["items"]) <= 100, r.status_code)

        # uniform 404
        limiter.reset()
        r_unknown = cli.post(f"{ADMIN}/ZzZzZzZz12/approve", headers=ha)
        limiter.reset()
        r_bad = cli.post(f"{ADMIN}/not-an-id/approve", headers=ha)
        limiter.reset()
        r_uuid = cli.post(f"{ADMIN}/{gid}/approve", headers=ha)
        check("unknown / malformed / uuid ids give ONE identical 404",
              r_unknown.status_code == r_bad.status_code == r_uuid.status_code == 404
              and r_unknown.json() == r_bad.json() == r_uuid.json() == NOT_FOUND, (r_unknown.text, r_bad.text, r_uuid.text))
        for method, suffix, body in (("post", "reject", {"reason_code": "spam"}), ("post", "hide", {"reason_code": "spam"}),
                                     ("post", "restore", None), ("delete", "", None)):
            limiter.reset()
            r = getattr(cli, method)(f"{ADMIN}/ZzZzZzZz12" + (f"/{suffix}" if suffix else ""), headers=ha,
                                     **({"json": body} if body else {}))
            check(f"{method} {suffix or 'delete'} on an unknown id -> uniform 404", r.status_code == 404 and r.json() == NOT_FOUND,
                  (r.status_code, r.text))

        # reject path
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/reject", json={"reason_code": "reported"}, headers=ha)
        check("reject with a hide-only code -> 422 invalid_reason", r.status_code == 422 and dcode(r) == "invalid_reason", r.text)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/reject", json={"reason_code": "spam", "extra": 1}, headers=ha)
        check("extra body field -> 422", r.status_code == 422, r.status_code)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/reject", json={}, headers=ha)
        check("missing reason_code -> 422", r.status_code == 422, r.status_code)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/reject", json={"reason_code": "x" * 41}, headers=ha)
        check("over-long reason_code -> 422", r.status_code == 422, r.status_code)
        check("invalid attempts changed nothing", status(gid) == "pending_review")
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/reject", json={"reason_code": "spam"}, headers=ha)
        check("reject -> 200 rejected", r.status_code == 200 and r.json()["status"] == "rejected", r.text)
        check("rejected row stores reason and reviewer", lrow(gid, "reject_reason_code, reviewed_by::text") == ("spam", admin))
        mails = mb.to_owner(email_of(owner))
        check("reject emails the owner once, title escaped",
              len(mails) == 1 and "Admin &amp; Probe" in mails[0][2] and "Admin & Probe" not in mails[0][2], [m[1] for m in mails])
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/reject", json={"reason_code": "spam"}, headers=ha)
        check("reject a rejected listing -> 409 invalid_state", r.status_code == 409 and dcode(r) == "invalid_state", r.text)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/approve", headers=ha)
        check("approve a rejected listing -> 409 invalid_state", r.status_code == 409 and dcode(r) == "invalid_state", r.text)
        check("a failed transition sends no email", len(mb.to_owner(email_of(owner))) == 1)

        # approve -> publish
        limiter.reset()
        admin_do(lambda cur: cur.execute("UPDATE group_listings SET status='pending_review' WHERE group_id=%s", (gid,)))
        r = cli.post(f"{ADMIN}/{p}/approve", headers=ha)
        check("approve -> 200 published and visible", r.status_code == 200 and r.json()["status"] == "published" and visible(gid), r.text)
        check("approve clears reject reason", lrow(gid, "reject_reason_code")[0] is None)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/approve", headers=ha)
        check("approve a published listing -> 409 invalid_state", r.status_code == 409 and dcode(r) == "invalid_state", r.text)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/restore", headers=ha)
        check("restore a published listing -> 409 invalid_state", r.status_code == 409 and dcode(r) == "invalid_state", r.text)

        # hide / restore
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/hide", json={"reason_code": "duplicate"}, headers=ha)
        check("hide with a reject-only code -> 422 invalid_reason", r.status_code == 422 and dcode(r) == "invalid_reason", r.text)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/hide", json={"reason_code": "inappropriate"}, headers=ha)
        check("hide -> 200 hidden, not public", r.status_code == 200 and r.json()["status"] == "hidden" and not visible(gid), r.text)
        check("hidden row stores reason", lrow(gid, "hidden_reason_code")[0] == "inappropriate")
        check("hide emails the owner", len(mb.to_owner(email_of(owner))) == 2)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/hide", json={"reason_code": "spam"}, headers=ha)
        check("hide a hidden listing -> 409 invalid_state", r.status_code == 409 and dcode(r) == "invalid_state", r.text)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/restore", headers=ha)
        check("restore -> 200 published (approved text unchanged)", r.status_code == 200 and r.json()["status"] == "published" and visible(gid), r.text)
        check("restore sends no owner email", len(mb.to_owner(email_of(owner))) == 2)
        for code in ("bulk",):
            limiter.reset()
            r = cli.post(f"{ADMIN}/{p}/hide", json={"reason_code": code}, headers=ha)
            check(f"hide with system code '{code}' is accepted", r.status_code == 200, r.text)
            admin_do(listings.admin_restore, p, admin)

        # suspended owner -> approve/restore refuse
        q("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (owner,), fetch=False)
        admin_do(listings.admin_hide, p, admin, "spam") if status(gid) == "published" else None
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/restore", headers=ha)
        check("restore for a suspended owner -> 409 owner_unavailable", r.status_code == 409 and dcode(r) == "owner_unavailable", r.text)
        q("UPDATE group_listings SET status='pending_review' WHERE group_id=%s", (gid,), fetch=False)
        limiter.reset()
        r = cli.post(f"{ADMIN}/{p}/approve", headers=ha)
        check("approve for a suspended owner -> 409 owner_unavailable", r.status_code == 409 and dcode(r) == "owner_unavailable", r.text)
        q("UPDATE users SET suspended_at = NULL WHERE _id = %s", (owner,), fetch=False)

        # delete
        limiter.reset()
        r = cli.delete(f"{ADMIN}/{p}", headers=ha)
        check("admin delete -> 200 removed, row gone", r.status_code == 200 and r.json()["status"] == "removed" and lrow(gid) is None, r.text)
        check("the group itself survives an admin listing delete", bool(q("SELECT 1 FROM groups WHERE _id = %s", (gid,))))
        limiter.reset()
        r = cli.delete(f"{ADMIN}/{p}", headers=ha)
        check("second delete -> uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, r.text)

    # rate limit: admin limit exists (60/min)
    check("admin rate limit configured", get_listings_config().rate_limits["admin"] == "60/minute")
    limiter.reset()
    codes = [cli.get(f"{ADMIN}/queue", headers=ha).status_code for _ in range(62)]
    check("admin endpoints are rate limited (429 after the window budget)", 429 in codes and codes[0] == 200, codes[-3:])
    limiter.reset()

    # email failure never fails the action
    o2 = make_user()
    g2 = mk_listing(cli, o2, title="Mail failure", state="pending_review")
    with Mailbox(fail=True), catch_logs() as lg:
        r = cli.post(f"{ADMIN}/{pid(g2)}/reject", json={"reason_code": "spam"}, headers=ha)
    check("a failing e-mail still commits the rejection (200)", r.status_code == 200 and status(g2) == "rejected", (r.status_code, r.text))
    check("failure logged as WARNING with ids only (no address, no title)",
          any("LISTING_NOTIFY_SEND_FAILED" in m for _, m in lg.records)
          and not any(email_of(o2) in m or "Mail failure" in m for _, m in lg.records))


# -- 4. CLI ----------------------------------------------------------------------

def test_cli(cli):
    print("CLI in fresh subprocesses: admin_listings and admin_actions")
    admin = make_user(admin=True)
    owner = make_user()
    gid = mk_listing(cli, owner, title="CLI group", admin=admin)
    p = pid(gid)
    r = run_cli("backend.admin_listings", "hide", p)
    check("hide default reason -> exit 0", r.returncode == 0 and "hidden" in r.stdout, (r.returncode, r.stdout, r.stderr[-200:]))
    check("hidden with reason 'other'", lrow(gid, "status, hidden_reason_code") == ("hidden", "other"))
    check("output prints ids and codes only, no title", "CLI group" not in r.stdout + r.stderr)
    r = run_cli("backend.admin_listings", "hide", p)
    check("hide an already hidden listing -> exit 2 'invalid_state'", r.returncode == 2 and "invalid_state" in r.stderr, (r.returncode, r.stderr[-200:]))
    r = run_cli("backend.admin_listings", "restore", p)
    check("restore -> exit 0, published", r.returncode == 0 and status(gid) == "published", (r.returncode, r.stderr[-200:]))
    r = run_cli("backend.admin_listings", "restore", p)
    check("restore a published listing -> exit 2", r.returncode == 2 and "invalid_state" in r.stderr, r.returncode)
    r = run_cli("backend.admin_listings", "hide", p, "--reason", "reported")
    check("hide --reason reported (a configured hide code) -> exit 0", r.returncode == 0 and lrow(gid, "hidden_reason_code")[0] == "reported", r.stderr[-200:])
    admin_do(listings.admin_restore, p, admin)
    r = run_cli("backend.admin_listings", "hide", p, "--reason", "duplicate")
    check("hide --reason with a non-hide code -> exit 2 invalid_reason", r.returncode == 2 and "invalid_reason" in r.stderr and status(gid) == "published", (r.returncode, r.stderr[-200:]))
    r = run_cli("backend.admin_listings", "hide", "ZzZzZzZz12")
    check("hide unknown id -> exit 2 not_found", r.returncode == 2 and "not_found" in r.stderr, (r.returncode, r.stderr[-200:]))
    r = run_cli("backend.admin_listings")
    check("no subcommand -> argparse error, non-zero", r.returncode != 0)

    # hide-all marks bulk and runs hooks (hook proof: a pending join request would expire; here the state + hidden_at)
    o2 = make_user()
    g2 = mk_listing(cli, o2, title="Bulk pending", state="pending_review")
    o3 = make_user()
    g3 = mk_listing(cli, o3, title="Bulk draft", publish=False)
    r = run_cli("backend.admin_listings", "hide-all")
    check("hide-all -> exit 0 and prints counts", r.returncode == 0 and "hidden=" in r.stdout and "failed=0" in r.stdout, (r.returncode, r.stdout, r.stderr[-200:]))
    check("published and pending listings hidden with reason bulk",
          lrow(gid, "status, hidden_reason_code") == ("hidden", "bulk") and lrow(g2, "status, hidden_reason_code") == ("hidden", "bulk"))
    check("bulk hide set hidden_at", lrow(gid, "hidden_at")[0] is not None)
    check("a draft is untouched by hide-all", status(g3) == "draft")
    check("nothing is public after hide-all", not visible(gid) and not visible(g2))
    r = run_cli("backend.admin_listings", "hide-all")
    check("hide-all is idempotent (hidden=0)", r.returncode == 0 and "hidden=0" in r.stdout, r.stdout)
    r = run_cli("backend.admin_listings", "restore", p)
    check("restore after bulk -> published again", r.returncode == 0 and status(gid) == "published", r.stderr[-200:])

    # fresh process hooks: hide-all registered the listing_hidden registry via load_all
    code = ("from backend.registrations import load_all\nload_all()\n"
            "from backend.interactions import reports\nfrom backend.moderation import removers\n"
            "print('group_listing' in reports.CONTENT_RESOLVERS, 'group_listing' in removers.CONTENT_REMOVERS, "
            "'group_listing' in reports.CONTENT_AFTER_REPORT)\n")
    r = subprocess.run([sys.executable, "-c", code], cwd=API_DIR, capture_output=True, text=True, timeout=120)
    check("cold process: resolver, remover and after-report hook all registered by load_all",
          r.stdout.strip() == "True True True", (r.stdout, r.stderr[-200:]))

    # admin_actions
    reporter = make_user()
    with Mailbox():
        rep = report(cli, reporter, p, reason="cli-test")
    rid = rep.json()["id"]
    r = run_cli("backend.moderation.admin_actions", "list")
    check("admin_actions list shows the group_listing report with the UUID content id",
          r.returncode == 0 and rid in r.stdout and "group_listing" in r.stdout and lid(gid) in r.stdout, (r.returncode, r.stdout[-300:], r.stderr[-200:]))
    r = run_cli("backend.moderation.admin_actions", "resolve", rid, "--remove-content")
    check("resolve --remove-content -> exit 0, listing deleted, group survives",
          r.returncode == 0 and lrow(gid) is None and bool(q("SELECT 1 FROM groups WHERE _id = %s", (gid,))), (r.returncode, r.stdout, r.stderr[-200:]))
    check("report marked actioned and kept", q("SELECT status FROM content_reports WHERE _id = %s", (rid,))[0][0] == "actioned")
    r = run_cli("backend.moderation.admin_actions", "resolve", rid, "--remove-content")
    check("removing an already-removed listing is a no-op (exit 0)", r.returncode == 0, (r.returncode, r.stderr[-200:]))

    # dismiss leaves the listing alone
    o4, rp4 = make_user(), make_user()
    g4 = mk_listing(cli, o4, title="Dismiss me", admin=admin)
    with Mailbox():
        rid4 = report(cli, rp4, pid(g4)).json()["id"]
    r = run_cli("backend.moderation.admin_actions", "resolve", rid4, "--dismiss")
    check("resolve --dismiss leaves the listing published", r.returncode == 0 and status(g4) == "published"
          and q("SELECT status FROM content_reports WHERE _id = %s", (rid4,))[0][0] == "dismissed", (r.returncode, r.stderr[-200:]))

    # eject: suspended owner's listing hidden immediately
    o5, rp5 = make_user(), make_user()
    g5 = mk_listing(cli, o5, title="Eject me", admin=admin)
    g5b = mk_listing(cli, o5, title="Eject me too", admin=admin)
    o6 = make_user()
    g6 = mk_listing(cli, o6, title="Bystander", admin=admin)
    with Mailbox():
        rid5 = report(cli, rp5, pid(g5)).json()["id"]
    check("setup: both listings visible", visible(g5) and visible(g5b))
    r = run_cli("backend.moderation.admin_actions", "resolve", rid5, "--eject")
    check("resolve --eject -> exit 0", r.returncode == 0, (r.returncode, r.stdout, r.stderr[-200:]))
    check("owner suspended", q("SELECT suspended_at IS NOT NULL FROM users WHERE _id = %s", (o5,))[0][0])
    check("ALL of the suspended owner's listings are hidden with owner_suspended",
          lrow(g5, "status, hidden_reason_code") == ("hidden", "owner_suspended")
          and lrow(g5b, "status, hidden_reason_code") == ("hidden", "owner_suspended"))
    check("not public", not visible(g5) and not visible(g5b))
    check("another owner's listing is untouched", status(g6) == "published" and visible(g6))
    r2 = cli.post(f"{ADMIN}/{pid(g5)}/restore", headers=hdr(admin))
    check("admin cannot restore a suspended owner's listing (409 owner_unavailable)", r2.status_code == 409 and dcode(r2) == "owner_unavailable", r2.text)
    r = run_cli("backend.moderation.admin_actions", "resolve", "00000000-0000-0000-0000-000000000000", "--remove-content")
    check("resolve unknown report -> exit 1", r.returncode == 1, r.returncode)


# -- 5. suspended owner ----------------------------------------------------------

def test_suspended_owner(cli):
    print("hide_listings_of_owner")
    admin = make_user(admin=True)
    owner, other = make_user(), make_user()
    gp = mk_listing(cli, owner, title="Own published", admin=admin)
    gr = mk_listing(cli, owner, title="Own pending", state="pending_review")
    gd = mk_listing(cli, owner, title="Own draft", publish=False)
    go = mk_listing(cli, other, title="Other published", admin=admin)
    captured = []
    hook = lambda cur, g, reason: captured.append((g, reason)) or []  # noqa: E731
    lifecycle.register("listing_hidden", hook)
    try:
        n = admin_do(listings.hide_listings_of_owner, owner)
        check("returns 2 (published + pending)", n == 2, n)
        check("published and pending hidden owner_suspended",
              lrow(gp, "status, hidden_reason_code") == ("hidden", "owner_suspended")
              and lrow(gr, "status, hidden_reason_code") == ("hidden", "owner_suspended"))
        check("draft untouched", status(gd) == "draft")
        check("other owner untouched", status(go) == "published")
        check("hooks fired once per hidden listing with owner_suspended",
              sorted(captured) == sorted([(gp, "owner_suspended"), (gr, "owner_suspended")]), captured)
        check("second call is a no-op", admin_do(listings.hide_listings_of_owner, owner) == 0)
        check("unknown / junk user ids return 0 (never raise)",
              admin_do(listings.hide_listings_of_owner, str(uuid.uuid4())) == 0 and admin_do(listings.hide_listings_of_owner, "junk") == 0
              and admin_do(listings.hide_listings_of_owner, "") == 0)
        # a listing in a group created by someone else is not hidden when a mere member is suspended
        m = make_user()
        gm = mk_listing(cli, other, [m], title="Member only", admin=admin)
        check("suspending a non-creator member does not hide the listing", admin_do(listings.hide_listings_of_owner, m) == 0 and status(gm) == "published")
    finally:
        lifecycle._registry["listing_hidden"].remove(hook)
    # suspension alone (no hide call) already removes it from public_where
    o2 = make_user()
    g2 = mk_listing(cli, o2, title="Suspended before sweep", admin=admin)
    q("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (o2,), fetch=False)
    check("a suspended owner's published listing is excluded from public_where immediately", status(g2) == "published" and not visible(g2))


# -- 6. PUT /groups guard ---------------------------------------------------------

def test_put_groups_guard(cli):
    print("PUT /groups owner-only guard: listed groups only")
    admin = make_user(admin=True)
    owner, member, newbie = make_user(), make_user(), make_user()
    hm, ho = hdr(member), hdr(owner)

    def put_group(gid, uid, hh, users, title):
        return cli.put(f"/groups/{uid}/{gid}", json={"group_id": gid, "title": title, "users": users}, headers=hh)

    def reset_users(gid):
        q("UPDATE groups SET users = %s WHERE _id = %s", ([owner, member], gid), fetch=False)

    # groups without presence keep build-78 behaviour in every non-presence state
    for state in ("none", "draft", "unpublished", "rejected"):
        gid = make_group(owner, [member], title=f"Guard {state}")
        if state != "none":
            limiter.reset()
            cli.put(f"/explorer/{owner}/groups/{gid}/listing", json={"title": "Guard"}, headers=ho)
            if state in ("unpublished", "rejected"):
                limiter.reset()
                cli.post(f"/explorer/{owner}/groups/{gid}/listing/submit", json={"consent": True, "adult_attested": True}, headers=ho)
                if state == "unpublished":
                    admin_do(listings.admin_approve, pid(gid), admin)
                    limiter.reset()
                    cli.post(f"/explorer/{owner}/groups/{gid}/listing/unpublish", headers=ho)
                else:
                    admin_do(listings.admin_reject, pid(gid), admin, "spam")
            check(f"setup: listing is {state}", status(gid) == state, status(gid))
        r = put_group(gid, member, hm, [owner, member, newbie], f"Guard {state}")
        check(f"{state}: non-creator add allowed (build-78 unchanged)", r.status_code == 200, (r.status_code, r.text))
        check(f"{state}: add persisted", newbie in q("SELECT users FROM groups WHERE _id = %s", (gid,))[0][0])
        r = put_group(gid, member, hm, [member], f"Guard {state}")
        check(f"{state}: creator removal by a member allowed (unchanged)", r.status_code == 200, (r.status_code, r.text))

    # presence states
    for state in ("pending_review", "published", "hidden"):
        owner, member, newbie = make_user(), make_user(), make_user()  # fresh owner: per-owner listing cap
        hm, ho = hdr(member), hdr(owner)
        gid = mk_listing(cli, owner, [member], title=f"Guard {state}", state="pending_review" if state == "pending_review" else None, admin=admin)
        if state == "hidden":
            admin_do(listings.admin_hide, pid(gid), admin, "spam")
        check(f"setup: listing is {state}", status(gid) == state, status(gid))
        r = put_group(gid, member, hm, [owner, member, newbie], f"Guard {state}")
        check(f"{state}: non-creator add -> 409 owner_only", r.status_code == 409 and dcode(r) == "owner_only", (r.status_code, r.text))
        check(f"{state}: rejected add persisted nothing", q("SELECT users FROM groups WHERE _id = %s", (gid,))[0][0] == [owner, member])
        r = put_group(gid, member, hm, [member], f"Guard {state}")
        check(f"{state}: removing the creator -> 409 owner_only", r.status_code == 409 and dcode(r) == "owner_only", (r.status_code, r.text))
        r = put_group(gid, owner, ho, [owner, member, newbie], f"Guard {state}")
        check(f"{state}: the creator may still add members", r.status_code == 200, (r.status_code, r.text))
        reset_users(gid)
        r = put_group(gid, member, hm, [owner, member], f"Renamed by member {state}")
        check(f"{state}: a rename with an unchanged roster by a member still works", r.status_code == 200, (r.status_code, r.text))
        r = put_group(gid, member, hm, [owner], f"Renamed {state}")
        check(f"{state}: a member leaving by removing only themself still works", r.status_code == 200, (r.status_code, r.text))
    # same 409 body is used regardless of state (no oracle for listing status)
    check("409 body is the constant owner_only shape", get_owner_only_body(cli, owner, member, newbie, admin) is True)


def get_owner_only_body(cli, owner, member, newbie, admin):
    gid = mk_listing(cli, owner, [member], title="Body shape", admin=admin)
    r = cli.put(f"/groups/{member}/{gid}", json={"group_id": gid, "title": "Body shape", "users": [owner, member, newbie]},
                headers=hdr(member))
    d = r.json().get("detail")
    return r.status_code == 409 and isinstance(d, dict) and d.get("code") == "owner_only" and "listing" not in str(d).lower()


# -- 7. lifecycle / J14 -------------------------------------------------------------

def test_lifecycle_and_reports(cli):
    print("lifecycle collector and report survival (J14)")
    admin = make_user(admin=True)
    a, b, rp = make_user(), make_user(), make_user()
    g1 = mk_listing(cli, a, [b], title="Delete me", admin=admin)
    with Mailbox():
        rid = report(cli, rp, pid(g1), detail="kept?").json()["id"]
    r = cli.delete(f"/groups/{a}/{g1}", headers=hdr(a))
    check("creator deletes the group (204)", r.status_code == 204, (r.status_code, r.text))
    check("listing removed with the group", lrow(g1) is None)
    row = q("SELECT status, content_snippet, content_id::text FROM content_reports WHERE _id = %s", (rid,))
    check("report about the removed listing survives with its snapshot", row and "Delete me" in row[0][1], row)
    check("report still carries the listing UUID", row and row[0][2] is not None)
    # a report about a deleted listing can still be resolved (remover is a no-op)
    r = run_cli("backend.moderation.admin_actions", "resolve", rid, "--remove-content")
    check("resolving a report whose listing is already gone succeeds", r.returncode == 0, (r.returncode, r.stderr[-200:]))

    c = make_user()
    g2 = mk_listing(cli, c, title="Last member", admin=admin)
    r = cli.post(f"/groups/{c}/{g2}/leave", headers=hdr(c))
    check("last member leaves -> group and listing gone", r.status_code == 204 and lrow(g2) is None)

    # creator leaves with other members: hidden owner_gone, not deleted
    d, e = make_user(), make_user()
    g3 = mk_listing(cli, d, [e], title="Creator leaves", admin=admin)
    cli.post(f"/groups/{d}/{g3}/leave", headers=hdr(d))
    check("creator leaving hides (owner_gone), report path unaffected",
          lrow(g3, "status, hidden_reason_code") == ("hidden", "owner_gone"))
    r2 = cli.post(f"{ADMIN}/{pid(g3)}/restore", headers=hdr(admin))
    check("admin cannot restore a listing whose owner left", r2.status_code == 409 and dcode(r2) == "owner_unavailable", r2.text)

    # J14 default: report deleted with reporter / reported account
    o, rep1, rep2 = make_user(), make_user(), make_user()
    g4 = mk_listing(cli, o, title="Account deletion", admin=admin)
    with Mailbox():
        r_a = report(cli, rep1, pid(g4)).json()["id"]
        r_b = report(cli, rep2, pid(g4)).json()["id"]
    q("DELETE FROM users WHERE _id = %s", (rep1,), fetch=False)
    check("report deleted with the reporter's account (documented default)",
          not q("SELECT 1 FROM content_reports WHERE _id = %s", (r_a,)))
    check("other reporters' reports survive that deletion", bool(q("SELECT 1 FROM content_reports WHERE _id = %s", (r_b,))))
    rr = cli.delete(f"/user/{o}", headers=hdr(o))
    check("owner account delete succeeds with open reports about the listing", rr.status_code in (200, 204), (rr.status_code, rr.text))
    check("listing removed with the deleted owner", lrow(g4) is None)
    check("report deleted with the reported account (documented default)",
          not q("SELECT 1 FROM content_reports WHERE _id = %s", (r_b,)))


# -- 8. word lists ---------------------------------------------------------------------

def test_word_lists(cli):
    print("pre-moderation word lists")
    cfg = get_listings_config()
    owner = make_user()
    gid = make_group(owner, [], title="Wordlist group")
    base = f"/explorer/{owner}/groups/{gid}/listing"
    ho = hdr(owner)

    def put(body):
        limiter.reset()
        return cli.put(base, json=body, headers=ho)

    bad = []
    for term in cfg.youth_terms:
        for field, body in (("title", {"title": f"A {term} group"}), ("summary", {"summary": f"For {term} only"})):
            r = put(body)
            if not (r.status_code == 422 and dcode(r) == "youth_not_supported"):
                bad.append((term, field, r.status_code, dcode(r)))
    check(f"every youth term ({len(cfg.youth_terms)}) is rejected in title and summary", not bad, bad[:3])
    r = put({"title": "A TEENAGERS group"})
    check("youth match is case-insensitive", r.status_code == 422 and dcode(r) == "youth_not_supported", r.text)
    for ok_title in ("Adult Bible Study", "Skidmore Evening Group", "Mankind Fellowship", "Kidney Support Prayer"):
        r = put({"title": ok_title})
        check(f"no false positive on a substring ('{ok_title}')", r.status_code == 200, (r.status_code, r.text[:120]))
    bad = []
    for host in cfg.blocked_link_hosts:
        for text in (f"[go](https://{host}/abc)", f"see https://{host}/x", f"[go](https://sub.{host}/abc)"):
            r = put({"description_blocks": [{"type": "text", "text": text}]})
            if not (r.status_code == 422 and dcode(r) == "link_blocked"):
                bad.append((host, text, r.status_code, dcode(r)))
    check(f"every blocked link host ({len(cfg.blocked_link_hosts)}) is rejected incl. subdomains", not bad, bad[:3])
    r = put({"description_blocks": [{"type": "text", "text": "[ok](https://example.org/page)"}]})
    check("an ordinary https link is allowed", r.status_code == 200, (r.status_code, r.text[:160]))
    r = put({"description_blocks": [{"type": "text", "text": "[x](http://example.org/a)"}]})
    check("plain http link outcome is deterministic (no 500)", r.status_code in (200, 422), r.status_code)

    from backend.moderation.content_filter import ContentRejected, check_clean
    word = None
    for cand in ("rape", "blowjob", "bukkake", "pedophile", "cocksucker"):
        try:
            check_clean(t=cand)
        except ContentRejected:
            word = cand
            break
    if word:
        r = put({"title": f"Group {word}"})
        check("profanity from the shared filter is refused (422 content_rejected; the shared message names the owner's own text by design)", r.status_code == 422 and dcode(r) == "content_rejected", (r.status_code, r.text[:160]))
        r = put({"description_blocks": [{"type": "text", "text": f"hello {word}"}]})
        check("profanity in the description is refused", r.status_code == 422 and dcode(r) == "content_rejected", (r.status_code, r.text[:160]))
    else:
        check("profanity candidate found in shared filter", False, "no candidate word tripped check_clean")
    check("a rejected value never leaks into the stored row", lrow(gid, "title")[0] != f"Group {word}")

    check("every reject code has an owner-facing label", all(c in listing_reports.REASON_LABELS for c in cfg.reject_reason_codes))
    check("every hide code has an owner-facing label", all(c in listing_reports.REASON_LABELS for c in cfg.hide_reason_codes))
    check("reason_codes_ok() agrees", listing_reports.reason_codes_ok())
    check("unknown / None code falls back to a neutral label",
          listing_reports.reason_label("zzz") == listing_reports.reason_label(None) and listing_reports.reason_label("zzz"))
    check("system code 'reported' is hide-only; 'duplicate' is reject-only",
          "reported" in cfg.hide_reason_codes and "reported" not in cfg.reject_reason_codes
          and "duplicate" in cfg.reject_reason_codes and "duplicate" not in cfg.hide_reason_codes)
    check("labels are plain text (no markup, no PII placeholders)",
          all("<" not in v and "{" not in v for v in listing_reports.REASON_LABELS.values()))


# -- 9. per-reporter rate limit ---------------------------------------------------------

def test_report_rate_limit(cli):
    print("per-reporter listing-report rate limit")
    admin = make_user(admin=True)
    owner = make_user()
    gid = mk_listing(cli, owner, title="Rate limited", admin=admin)
    p = pid(gid)
    reporter, other = make_user(), make_user()
    hr = hdr(reporter)
    check("config: 10/minute", get_listings_config().rate_limits["report"] == "10/minute")
    limiter.reset()
    codes = []
    with Mailbox():
        for _ in range(12):
            codes.append(cli.post("/reports/", json={"content_type": "group_listing", "content_id": p, "reason": "x"}, headers=hr).status_code)
        check("first 10 reports accepted", codes[:10] == [201] * 10, codes)
        check("11th and 12th -> 429", codes[10:] == [429, 429], codes)
        check("rate-limited reports stored nothing",
              q("SELECT count(*) FROM content_reports WHERE reporter_id = %s", (reporter,))[0][0] == 10)
        r = cli.post("/reports/", json={"content_type": "group_listing", "content_id": p, "reason": "x"}, headers=hdr(other))
        check("a different reporter is unaffected", r.status_code == 201, (r.status_code, r.text))
        victim = make_user()
        r = cli.post("/reports/", json={"content_type": "user", "reported_user_id": victim, "reason": "x"}, headers=hr)
        check("the limit is not applied to other report types", r.status_code == 201, (r.status_code, r.text))
        r = cli.post("/reports/", json={"content_type": "group_listing", "content_id": "ZzZzZzZz12", "reason": "x"}, headers=hr)
        check("over the limit even an unknown id answers 429 (limit applies before lookup)", r.status_code == 429, r.status_code)
        r = cli.post("/reports/", json={"content_type": "group_listing", "content_id": "bad", "reason": "x"}, headers=hr)
        check("malformed id still 422 (validated before the limiter)", r.status_code == 422, r.status_code)
    limiter.reset()
    import inspect
    check("create_report is a plain def (threadpool, not the event loop)", not inspect.iscoroutinefunction(
        __import__("routes.reports", fromlist=["create_report"]).create_report))


# -- 10. logging ------------------------------------------------------------------------

def test_logging(cli):
    print("no PII, listing text or ERROR lines in the moderation flow")
    marker = f"Zqx{uuid.uuid4().hex[:8]}"
    admin = make_user(admin=True)
    owner = make_user()
    gid = mk_listing(cli, owner, title=f"Title {marker}", admin=admin)
    reporters = [make_user() for _ in range(3)]
    with catch_logs() as lg, Mailbox() as mb:
        for rp in reporters:
            report(cli, rp, pid(gid), reason=f"reason {marker}", detail=f"detail {marker}")
        limiter.reset()
        cli.post(f"{ADMIN}/{pid(gid)}/restore", headers=hdr(admin))
        limiter.reset()
        cli.post(f"{ADMIN}/{pid(gid)}/hide", json={"reason_code": "spam"}, headers=hdr(admin))
        limiter.reset()
        cli.get(f"{ADMIN}/queue?status=hidden", headers=hdr(admin))
        limiter.reset()
        cli.post(f"{ADMIN}/{pid(gid)}/reject", json={"reason_code": "spam"}, headers=hdr(admin))
        limiter.reset()
        cli.delete(f"{ADMIN}/{pid(gid)}", headers=hdr(admin))
        mb.fail = True
        g2 = mk_listing(cli, make_user(), title=f"Second {marker}", state="pending_review")
        cli.post(f"{ADMIN}/{pid(g2)}/reject", json={"reason_code": "spam"}, headers=hdr(admin))
    lines = [m for _, m in lg.records]
    check("moderation flow produced log lines to inspect", len(lines) > 0)
    check("no listing/report text in any log line", not [m for m in lines if marker in m], [m for m in lines if marker in m][:2])
    check("no e-mail address in any log line", not [m for m in lines if "@example.com" in m], [m for m in lines if "@example.com" in m][:2])
    check("no ERROR-level record", not [(lv, m) for lv, m in lg.records if lv == "ERROR"], [r for r in lg.records if r[0] == "ERROR"][:2])
    check("hide/reject/auto-hide leave an id-only audit line",
          any("LISTING_MODERATION" in m for m in lines) and any("LISTING_AUTO_HIDDEN" in m for m in lines))
    check("audit lines carry no title/reason", not any("LISTING_MODERATION" in m and ("Title" in m or "spam" in m) for m in lines))
    check("owner emails sent for hide and reject", len(mb.sent) >= 2)


def main():
    db = DBManager()
    db.cur.execute("SHOW port")
    port = db.cur.fetchone()[0]
    db.close()
    check("tests run against scratch DB port 55432", port == "55432", port)
    if port != "55432":
        raise SystemExit("refusing to continue: not the scratch database")
    load_all()
    cli = TestClient(main_module.app)
    saved = {r[0]: (r[1], r[2] or []) for r in q("SELECT name, state, canary_user_ids::text[] FROM feature_flags")}
    try:
        q("UPDATE feature_flags SET state = 'on' WHERE name = 'explorer_publish'", fetch=False)
        flags.invalidate()
        test_resolver(cli)
        test_auto_hide(cli)
        test_admin_endpoints(cli)
        test_cli(cli)
        test_suspended_owner(cli)
        test_put_groups_guard(cli)
        test_lifecycle_and_reports(cli)
        test_word_lists(cli)
        test_report_rate_limit(cli)
        test_logging(cli)
    finally:
        for name, (state, canary) in saved.items():
            q("UPDATE feature_flags SET state = %s, canary_user_ids = %s::uuid[] WHERE name = %s",
              (state, canary, name), fetch=False)
        flags.invalidate()
        cleanup()
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
