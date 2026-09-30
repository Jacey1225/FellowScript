"""Backend coverage for task 20260930-subscription-seat-invites (phase 2).

Proves: owner-only create/list/revoke/reset (403 for non-owners incl. plan
members), single-seat / non-group / lapsed plans refused; redeem only files a
pending subscription_request and NEVER changes users.subscription_id; use
consumed only on a new request; idempotency; uniform not_found for full /
ineligible / capped plans; other-plan and blocked rejections; preview minimal
shape; owner accept/decline (owner-only, capacity-enforced, race-safe under
real threads); purge on delete / downgrade; flag-off uniform 404; rate limits;
config validation of the new keys; hashed tokens / no plaintext in logs;
group-kind regression smoke.

Run with: cd api && ../.venv/bin/python tests/test_subscription_invites.py
"""
import _pathfix  # noqa: F401

import copy
import json
import logging
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

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.interactions import invites as inv  # noqa: E402
from backend.interactions import invites_config as ic  # noqa: E402
from backend.subscription.subscriptions import SubscriptionsManager  # noqa: E402
from schemas.subscription import SubscriptionUpdate  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def ck(tok):
    return {"cookie": f"session={tok}"} if tok else {}


def ip_hdr():
    return {"cf-connecting-ip": f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"}


def signup(client, name):
    r = client.post("/signup", json={
        "username": name, "email": f"{name}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True}, headers=ip_hdr())
    assert r.status_code == 201, f"signup failed {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def uname():
    return f"si_{uuid.uuid4().hex[:10]}"


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


def mk_sub(owner, max_members=3, plan_type="group", status="active", period_days=30):
    """Insert a plan owned by `owner` and attach the owner to it."""
    sid = str(uuid.uuid4())
    q("INSERT INTO subscriptions (_id, user_id, plan_type, status, max_members, current_period_end) "
      "VALUES (%s, %s, %s, %s, %s, NOW() + (%s || ' days')::interval)",
      (sid, owner, plan_type, status, max_members, str(period_days)))
    q("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, owner))
    return sid


def attach(uid, sid):
    q("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, uid))


def user_sub(uid):
    r = q("SELECT subscription_id FROM users WHERE _id = %s", (uid,))
    return str(r[0][0]) if r and r[0][0] else None


def free_sub(uid):
    """Signup gives every user a free-plan row; 'unchanged' means this value."""
    return user_sub(uid)


def pending(sid):
    return {str(r[0]) for r in q("SELECT from_user_id FROM subscription_request WHERE subscription_id = %s", (sid,))}


def invite_row(iid):
    r = q("SELECT token_hash, use_count, max_uses, revoked_at, expires_at FROM invites WHERE _id = %s", (iid,))
    return r[0] if r else None


def cleanup(uids, sids):
    for s in sids:
        q("DELETE FROM invites WHERE target_id = %s", (s,))
        q("UPDATE users SET subscription_id = NULL WHERE subscription_id = %s", (s,))
        q("DELETE FROM subscriptions WHERE _id = %s", (s,))
    for u in uids:
        q("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (u, u))
        q("DELETE FROM subscriptions WHERE user_id = %s", (u,))
        q("DELETE FROM users WHERE _id = %s", (u,))


def base_cfg(**over):
    raw = json.loads(open(ic.CONFIG_PATH).read())
    raw["enabled"] = True
    raw.update(over)
    return ic.parse_invites_config(raw)


def install(**over):
    ic.set_invites_config_for_tests(base_cfg(**over))


def create(client, tok, uid, sid, **body):
    return client.post(f"/invites/{uid}/subscriptions/{sid}", json=body or None,
                       headers={**ck(tok), **ip_hdr()})


def lst(client, tok, uid, sid):
    return client.get(f"/invites/{uid}/subscriptions/{sid}", headers={**ck(tok), **ip_hdr()})


def redeem(client, tok, uid, token):
    return client.post(f"/invites/{uid}/redeem", json={"token": token}, headers={**ck(tok), **ip_hdr()})


def preview(client, token):
    return client.post("/invites/preview", json={"token": token}, headers=ip_hdr())


class LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


# ── tests ────────────────────────────────────────────────────────────────────

def test_create_authz(client):
    print("\n== Create/list/revoke/reset: owner only; eligibility ==")
    uo, to = signup(client, uname())
    um, tm = signup(client, uname())   # plan member
    ux, tx = signup(client, uname())   # outsider
    sid = mk_sub(uo, 3)
    attach(um, sid)
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    logging.getLogger().setLevel(logging.INFO)
    try:
        r = client.post(f"/invites/{uo}/subscriptions/{sid}", headers=ip_hdr())
        check("unauthenticated create -> 401", r.status_code == 401, str(r.status_code))
        r = create(client, tm, um, sid)
        check("plan MEMBER create -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = create(client, tx, ux, sid)
        check("outsider create -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = create(client, tm, uo, sid)
        check("spoofed path user id -> 403", r.status_code == 403, str(r.status_code))
        r = create(client, to, uo, str(uuid.uuid4()))
        check("unknown subscription -> 403 (no existence leak)", r.status_code == 403, str(r.status_code))
        r = create(client, to, uo, "not-a-uuid")
        check("malformed subscription id -> 403", r.status_code == 403, str(r.status_code))
        check("no link created by any rejected attempt",
              q("SELECT COUNT(*) FROM invites WHERE target_id = %s", (sid,))[0][0] == 0)

        r = create(client, to, uo, sid)
        check("owner create -> 201", r.status_code == 201, r.text)
        link = r.json()
        check("response has token + url, defaults from subscription config",
              link["token"] in link["url"] and link["max_uses"] == 5, str(link))
        row = invite_row(link["invite_id"])
        check("only token hash stored (not plaintext)",
              row[0] == inv.hash_token(link["token"]) and link["token"] not in row[0])
        check("row kind is 'subscription'",
              q("SELECT kind FROM invites WHERE _id = %s", (link["invite_id"],))[0][0] == "subscription")
        check("disallowed max_uses (25 not in subscription set) -> 422",
              create(client, to, uo, sid, max_uses=25).status_code == 422)
        check("plaintext token never logged", not any(link["token"] in l for l in cap.lines))
        check("create audited", any("create" in l and "subscription" in l for l in cap.lines))

        r = lst(client, tm, um, sid)
        check("member list -> 403", r.status_code == 403, str(r.status_code))
        r = lst(client, tx, ux, sid)
        check("outsider list -> 403", r.status_code == 403)
        r = lst(client, to, uo, sid)
        body = r.json()
        check("owner list -> 200, metadata only, config options present",
              r.status_code == 200 and "token" not in json.dumps(body) and "allowed_max_uses" in json.dumps(body)
              and len(body["invites"]) == 1, r.text)

        r = client.delete(f"/invites/{um}/{link['invite_id']}", headers={**ck(tm), **ip_hdr()})
        check("member revoke -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = client.delete(f"/invites/{ux}/{link['invite_id']}", headers={**ck(tx), **ip_hdr()})
        check("outsider revoke -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        check("link still live after rejected revokes", invite_row(link["invite_id"])[3] is None)
        r = client.post(f"/invites/{um}/subscriptions/{sid}/reset", headers={**ck(tm), **ip_hdr()})
        check("member reset -> 403", r.status_code == 403)
        r = client.post(f"/invites/{ux}/subscriptions/{sid}/reset", headers={**ck(tx), **ip_hdr()})
        check("outsider reset -> 403", r.status_code == 403)
        check("link still live after rejected resets", invite_row(link["invite_id"])[3] is None)

        # caps
        install(max_active_links_per_subscription=2)
        check("second link ok", create(client, to, uo, sid).status_code == 201)
        r = create(client, to, uo, sid)
        check("third link over cap -> 409 link_limit",
              r.status_code == 409 and r.json()["detail"]["code"] == "link_limit", r.text)
        install()

        r = client.delete(f"/invites/{uo}/{link['invite_id']}", headers={**ck(to), **ip_hdr()})
        check("owner revoke -> 204", r.status_code in (200, 204), str(r.status_code))
        check("revoked_at set", invite_row(link["invite_id"])[3] is not None)
        r = client.post(f"/invites/{uo}/subscriptions/{sid}/reset", headers={**ck(to), **ip_hdr()})
        check("owner reset -> 200", r.status_code == 200, r.text)
        check("reset revoked everything",
              q("SELECT COUNT(*) FROM invites WHERE target_id = %s AND revoked_at IS NULL", (sid,))[0][0] == 0)
    finally:
        logging.getLogger().removeHandler(cap)
        cleanup([uo, um, ux], [sid])


def test_create_ineligible(client):
    print("\n== Create refused for single-seat / non-group / lapsed / inactive plans ==")
    uo, to = signup(client, uname())
    sids = []
    try:
        for label, kw in (
            ("single-seat group plan", dict(max_members=1)),
            ("free plan", dict(plan_type="free", max_members=5)),
            ("inactive plan", dict(status="canceled")),
            ("lapsed plan", dict(period_days=-30)),
        ):
            sid = mk_sub(uo, **{"max_members": 3, **kw})
            sids.append(sid)
            r = create(client, to, uo, sid)
            check(f"{label} -> 409 not_eligible",
                  r.status_code == 409 and r.json()["detail"]["code"] == "not_eligible", f"{r.status_code} {r.text}")
            q("UPDATE users SET subscription_id = NULL WHERE _id = %s", (uo,))
            q("DELETE FROM subscriptions WHERE _id = %s", (sid,))
    finally:
        cleanup([uo], sids)


def test_redeem_request_only(client):
    print("\n== Redeem files a pending request; never changes membership ==")
    uo, to = signup(client, uname())
    um, tm = signup(client, uname())
    ui, ti = signup(client, uname())   # invitee
    uk, tk = signup(client, uname())
    sid = mk_sub(uo, 4)
    attach(um, sid)
    try:
        ui_base = user_sub(ui)
        link = create(client, to, uo, sid, max_uses=5).json()
        r = client.post(f"/invites/{ui}/redeem", json={"token": link["token"]}, headers=ip_hdr())
        check("unauthenticated redeem -> 401", r.status_code == 401)
        r = client.post(f"/invites/{uo}/redeem", json={"token": link["token"]}, headers={**ck(ti), **ip_hdr()})
        check("spoofed user redeem -> 403", r.status_code == 403)

        r = redeem(client, ti, ui, link["token"])
        check("redeem -> 200 requested/pending, NOT joined",
              r.status_code == 200 and r.json() == {
                  "kind": "subscription", "target_id": sid, "joined": False,
                  "already_member": False, "requested": True, "pending": True}, r.text)
        check("users.subscription_id unchanged (still their free plan)", user_sub(ui) == ui_base and user_sub(ui) != sid)
        check("pending request exists", ui in pending(sid))
        check("use consumed exactly once", invite_row(link["invite_id"])[1] == 1)

        r = redeem(client, ti, ui, link["token"])
        check("second redeem idempotent (pending, no new request)",
              r.status_code == 200 and r.json()["pending"] and not r.json()["requested"]
              and not r.json()["joined"], r.text)
        check("idempotent redeem consumed no use", invite_row(link["invite_id"])[1] == 1)
        check("still one request row", len(pending(sid)) == 1)
        check("membership still unchanged", user_sub(ui) == ui_base)

        r = redeem(client, to, uo, link["token"])
        check("owner redeeming own link -> already_member, no request/use",
              r.status_code == 200 and r.json()["already_member"] and uo not in pending(sid)
              and invite_row(link["invite_id"])[1] == 1, r.text)
        r = redeem(client, tm, um, link["token"])
        check("existing member redeem -> already_member, no request/use",
              r.status_code == 200 and r.json()["already_member"] and um not in pending(sid)
              and invite_row(link["invite_id"])[1] == 1, r.text)

        # unknown/malformed token same uniform 404
        r1 = redeem(client, tk, uk, inv.generate_token())
        r2 = redeem(client, tk, uk, "abc")
        check("unknown & malformed tokens -> identical 404", r1.status_code == 404 and r1.text == r2.text)

        # expired / revoked / exhausted
        ex = create(client, to, uo, sid).json()
        q("UPDATE invites SET expires_at = NOW() - INTERVAL '1 second' WHERE _id = %s", (ex["invite_id"],))
        r = redeem(client, tk, uk, ex["token"])
        check("expired -> 410", r.status_code == 410 and r.json()["detail"]["code"] == "expired", r.text)
        rv = create(client, to, uo, sid).json()
        client.delete(f"/invites/{uo}/{rv['invite_id']}", headers={**ck(to), **ip_hdr()})
        r = redeem(client, tk, uk, rv["token"])
        check("revoked -> 410", r.status_code == 410 and r.json()["detail"]["code"] == "revoked", r.text)
        q("DELETE FROM invites WHERE _id IN (%s, %s)", (ex["invite_id"], rv["invite_id"]))
        check("failed redeems created no request", uk not in pending(sid))
    finally:
        cleanup([uo, um, ui, uk], [sid])


def test_redeem_rejections(client):
    print("\n== Redeem rejections: full / lapsed / downgraded / other plan / blocked / pending cap ==")
    uo, to = signup(client, uname())
    um, tm = signup(client, uname())
    j1, t1 = signup(client, uname())   # other paid plan
    j2, t2 = signup(client, uname())   # blocked by a member
    j3, t3 = signup(client, uname())   # has blocked the owner
    j4, t4 = signup(client, uname())   # on free plan (allowed)
    j5, t5 = signup(client, uname())   # for full plan
    uo2, _ = signup(client, uname())   # owner of j1's other plan
    sid = mk_sub(uo, 3)
    attach(um, sid)
    other = mk_sub(uo2, 3)
    attach(j1, other)
    free = mk_sub(j4, 1, plan_type="free", status="active")
    try:
        link = create(client, to, uo, sid, max_uses=10).json()

        r = redeem(client, t1, j1, link["token"])
        check("caller on a different paid plan -> 409 other_plan",
              r.status_code == 409 and r.json()["detail"]["code"] == "other_plan", r.text)
        check("other_plan: no request, no use, plan untouched",
              j1 not in pending(sid) and invite_row(link["invite_id"])[1] == 0 and user_sub(j1) == other)

        q("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s, %s)", (um, j2))
        q("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s, %s)", (j3, uo))
        r2 = redeem(client, t2, j2, link["token"])
        r3 = redeem(client, t3, j3, link["token"])
        check("blocked by member -> 403 blocked", r2.status_code == 403 and r2.json()["detail"]["code"] == "blocked", r2.text)
        check("has blocked owner -> 403 blocked (same body)", r3.status_code == 403 and r3.text == r2.text, r3.text)
        check("blocked body leaks no ids", um not in r2.text and uo not in r2.text)
        check("blocked: no request rows, no use", not ({j2, j3} & pending(sid)) and invite_row(link["invite_id"])[1] == 0)

        r = redeem(client, t4, j4, link["token"])
        check("user on free plan may request", r.status_code == 200 and r.json()["requested"], r.text)
        check("free-plan requester's membership unchanged", user_sub(j4) == free)

        # pending cap
        install(max_pending_requests_per_subscription=1)
        r = redeem(client, t5, j5, link["token"])
        nf = r.text
        check("pending cap reached -> uniform 404", r.status_code == 404 and r.json()["detail"]["code"] == "not_found", r.text)
        check("pending cap: no request/use", j5 not in pending(sid) and invite_row(link["invite_id"])[1] == 1)
        install()

        # full plan (owner + member + 1 more = 3 of 3)
        ufill, _ = signup(client, uname())
        attach(ufill, sid)
        r = redeem(client, t5, j5, link["token"])
        check("full plan -> uniform 404 (same body as cap)", r.status_code == 404 and r.text == nf, r.text)
        pv = preview(client, link["token"])
        check("full plan preview -> uniform 404", pv.status_code == 404 and pv.json()["detail"]["code"] == "not_found")
        check("full plan: no request", j5 not in pending(sid))
        q("UPDATE users SET subscription_id = NULL WHERE _id = %s", (ufill,))
        q("DELETE FROM users WHERE _id = %s", (ufill,))

        # lapsed
        q("UPDATE subscriptions SET current_period_end = NOW() - INTERVAL '60 days' WHERE _id = %s", (sid,))
        r = redeem(client, t5, j5, link["token"])
        check("lapsed plan redeem -> uniform 404", r.status_code == 404 and r.text == nf, r.text)
        check("lapsed plan preview -> 404", preview(client, link["token"]).status_code == 404)
        q("UPDATE subscriptions SET current_period_end = NOW() + INTERVAL '30 days' WHERE _id = %s", (sid,))
        # single-seat
        q("UPDATE subscriptions SET max_members = 1 WHERE _id = %s", (sid,))
        r = redeem(client, t5, j5, link["token"])
        check("single-seat plan redeem -> uniform 404", r.status_code == 404 and r.text == nf, r.text)
        q("UPDATE subscriptions SET max_members = 3 WHERE _id = %s", (sid,))
        # subscription deleted entirely (link row orphaned by hand)
        check("j5 never got membership or request", user_sub(j5) != sid and j5 not in pending(sid))
    finally:
        cleanup([uo, um, j1, j2, j3, j4, j5, uo2], [sid, other, free])


def test_preview(client):
    print("\n== Preview: minimal shape, uniform 404 ==")
    uo, to = signup(client, uname())
    sid = mk_sub(uo, 3)
    try:
        link = create(client, to, uo, sid).json()
        r = preview(client, link["token"])
        body = r.json()
        check("preview 200 minimal shape", r.status_code == 200 and set(body) == {"kind", "inviter_username", "plan_type"}
              and body["kind"] == "subscription" and body["inviter_username"], r.text)
        check("preview leaks no ids/emails/seat counts",
              uo not in r.text and sid not in r.text and "@" not in r.text)
        nf = preview(client, inv.generate_token())
        check("unknown token -> 404 not_found", nf.status_code == 404)
        q("UPDATE invites SET revoked_at = NOW() WHERE _id = %s", (link["invite_id"],))
        r = preview(client, link["token"])
        check("revoked preview body == unknown-token body", r.status_code == 404 and r.text == nf.text)
    finally:
        cleanup([uo], [sid])


def test_accept_decline(client):
    print("\n== Owner accept/decline: owner-only, capacity-enforced, entitlement, audited ==")
    uo, to = signup(client, uname())
    um, tm = signup(client, uname())
    j1, t1 = signup(client, uname())
    j2, t2 = signup(client, uname())
    j3, t3 = signup(client, uname())
    uo2, _ = signup(client, uname())
    sid = mk_sub(uo, 3)   # owner + 1 member + room for exactly 1
    attach(um, sid)
    other = mk_sub(uo2, 3)
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    logging.getLogger().setLevel(logging.INFO)
    try:
        link = create(client, to, uo, sid, max_uses=10).json()
        for uid, t in ((j1, t1), (j2, t2), (j3, t3)):
            check(f"request filed for {uid[:4]}", redeem(client, t, uid, link["token"]).status_code == 200)

        base = f"/subscriptions/{sid}/requests"
        r = client.get(base, headers=ck(tm))
        check("member cannot list requests -> 403", r.status_code == 403, str(r.status_code))
        r = client.get(base, headers=ck(t1))
        check("requester cannot list requests -> 403", r.status_code == 403)
        r = client.get(base, headers=ck(to))
        check("owner lists pending requests", r.status_code == 200 and {x["user_id"] if "user_id" in x else x.get("from_user_id")
              for x in r.json()} >= {j1, j2, j3} or len(r.json()) == 3, r.text)

        r = client.post(f"{base}/{j1}/accept", headers=ck(tm))
        check("member accept -> 403", r.status_code == 403)
        r = client.post(f"{base}/{j1}/accept", headers=ck(t2))
        check("other requester accept -> 403", r.status_code == 403)
        check("rejected accepts changed nothing", user_sub(j1) != sid and j1 in pending(sid))
        r = client.delete(f"{base}/{j2}", headers=ck(tm))
        check("member decline of someone else -> 403", r.status_code == 403)
        check("request survived", j2 in pending(sid))

        r = client.post(f"{base}/{j1}/accept", headers=ck(to))
        check("owner accept -> 200", r.status_code == 200, r.text)
        check("accepted user gains the plan entitlement", user_sub(j1) == sid)
        check("request row consumed", j1 not in pending(sid))

        r = client.post(f"{base}/{j2}/accept", headers=ck(to))
        check("accept when full -> 400 Plan is full", r.status_code == 400 and "full" in r.text.lower(), r.text)
        check("full accept: no membership, request retained", user_sub(j2) != sid and j2 in pending(sid))

        r = client.delete(f"{base}/{j2}", headers=ck(to))
        check("owner decline -> 204", r.status_code == 204, str(r.status_code))
        check("decline removes request; membership untouched", j2 not in pending(sid) and user_sub(j2) != sid)
        r = client.post(f"{base}/{j2}/accept", headers=ck(to))
        check("accept of declined/nonexistent request -> 400", r.status_code == 400)
        r = client.delete(f"{base}/{j3}", headers=ck(t3))
        check("requester may cancel own request", r.status_code == 204 and j3 not in pending(sid))

        # requester moved onto another paid plan after filing -> accept refuses
        q("INSERT INTO subscription_request (subscription_id, from_user_id) VALUES (%s, %s)", (sid, j3))
        q("UPDATE users SET subscription_id = %s WHERE _id = %s", (other, j3))
        q("UPDATE subscriptions SET max_members = 5 WHERE _id = %s", (sid,))
        r = client.post(f"{base}/{j3}/accept", headers=ck(to))
        check("accept refused when requester is on another paid plan",
              r.status_code == 400 and "another paid plan" in r.text, r.text)
        check("their other plan not displaced", user_sub(j3) == other)

        for ev in ("subscription_request_accept", "subscription_request_accept_fail",
                   "subscription_request_decline", "subscription_request_cancel"):
            check(f"audit event {ev} emitted", any(ev in l for l in cap.lines))
        check("audit lines contain no tokens", not any(link["token"] in l for l in cap.lines))
    finally:
        logging.getLogger().removeHandler(cap)
        cleanup([uo, um, j1, j2, j3, uo2], [sid, other])


def test_accept_race(client):
    print("\n== Concurrent accepts cannot exceed max_members (real threads) ==")
    uo, _ = signup(client, uname())
    reqs = [signup(client, uname())[0] for _ in range(8)]
    sid = mk_sub(uo, 3)   # owner + 2 open seats
    try:
        for r in reqs:
            q("INSERT INTO subscription_request (subscription_id, from_user_id) VALUES (%s, %s)", (sid, r))
        barrier = threading.Barrier(len(reqs))
        out, lock = [], threading.Lock()

        def worker(uid):
            m = SubscriptionsManager()
            try:
                barrier.wait()
                res = m.accept_request(sid, uid)
                v = "ok" if res is None else res["error"]
            except Exception as e:  # noqa: BLE001
                v = f"exc:{type(e).__name__}:{e}"
            finally:
                m.close()
            with lock:
                out.append(v)

        ts = [threading.Thread(target=worker, args=(r,)) for r in reqs]
        [t.start() for t in ts]
        [t.join() for t in ts]
        members = q("SELECT COUNT(*) FROM users WHERE subscription_id = %s", (sid,))[0][0]
        check("exactly 2 accepts won", out.count("ok") == 2, str(out))
        check("others got 'Plan is full', no exceptions", out.count("Plan is full") == 6, str(out))
        check("members never exceed max_members (owner + 2 = 3)", members == 3, str(members))
    finally:
        cleanup([uo, *reqs], [sid])


def test_redeem_race_single_seat_left(client):
    print("\n== Concurrent redeem of a max_uses=1 link -> exactly one request ==")
    uo, to = signup(client, uname())
    joiners = [signup(client, uname())[0] for _ in range(8)]
    sid = mk_sub(uo, 5)
    try:
        link = create(client, to, uo, sid, max_uses=1).json()
        barrier = threading.Barrier(len(joiners))
        out, lock = [], threading.Lock()

        def worker(uid):
            m = inv.InvitesManager(uid)
            try:
                barrier.wait()
                m.redeem(link["token"])
                v = "won"
            except inv.InviteError as e:
                v = e.code
            except Exception as e:  # noqa: BLE001
                v = f"exc:{type(e).__name__}:{e}"
            finally:
                m.close()
            with lock:
                out.append(v)

        ts = [threading.Thread(target=worker, args=(j,)) for j in joiners]
        [t.start() for t in ts]
        [t.join() for t in ts]
        check("exactly one winner", out.count("won") == 1, str(out))
        check("one pending request, use_count == 1",
              len(pending(sid)) == 1 and invite_row(link["invite_id"])[1] == 1)
        check("nobody joined", all(user_sub(j) != sid for j in joiners))
    finally:
        cleanup([uo, *joiners], [sid])


def test_purge(client):
    print("\n== Invites purged on delete / downgrade to single seat ==")
    uo, to = signup(client, uname())
    s1 = mk_sub(uo, 3)
    try:
        i1 = create(client, to, uo, s1).json()
        m = SubscriptionsManager()
        try:
            m.update_subscription(s1, SubscriptionUpdate(member_count=2))
            check("seat change above 1 keeps invites", invite_row(i1["invite_id"]) is not None)
            m.update_subscription(s1, SubscriptionUpdate(member_count=1))
            check("downgrade to single seat purges invites", invite_row(i1["invite_id"]) is None)
        finally:
            m.close()
        q("UPDATE subscriptions SET max_members = 3 WHERE _id = %s", (s1,))
        i2 = create(client, to, uo, s1).json()
        m = SubscriptionsManager()
        try:
            m.delete_subscription(s1)
        finally:
            m.close()
        check("delete_subscription purges invites", invite_row(i2["invite_id"]) is None)
        check("preview after delete -> 404", preview(client, i2["token"]).status_code == 404)
        r = redeem(client, to, uo, i2["token"])
        check("redeem after delete -> 404", r.status_code == 404)
    finally:
        cleanup([uo], [s1])


def test_flag_off(client):
    print("\n== Flag off => uniform 404 on every subscription route ==")
    uo, to = signup(client, uname())
    sid = mk_sub(uo, 3)
    try:
        link = create(client, to, uo, sid).json()
        ic.set_invites_config_for_tests(base_cfg(enabled=False))
        outs = {
            "create": create(client, to, uo, sid),
            "list": lst(client, to, uo, sid),
            "reset": client.post(f"/invites/{uo}/subscriptions/{sid}/reset", headers={**ck(to), **ip_hdr()}),
            "revoke": client.delete(f"/invites/{uo}/{link['invite_id']}", headers={**ck(to), **ip_hdr()}),
            "redeem": redeem(client, to, uo, link["token"]),
            "preview": preview(client, link["token"]),
        }
        check("all routes 404 when disabled", all(v.status_code == 404 for v in outs.values()),
              str({k: v.status_code for k, v in outs.items()}))
        check("disabled: link not revoked / consumed, no requests",
              invite_row(link["invite_id"])[3] is None and invite_row(link["invite_id"])[1] == 0
              and not pending(sid))
    finally:
        install()
        cleanup([uo], [sid])


def test_rate_limits(client):
    print("\n== Rate limits apply to subscription routes ==")
    uo, to = signup(client, uname())
    sid = mk_sub(uo, 3)
    try:
        rl = {**json.loads(open(ic.CONFIG_PATH).read())["rate_limits"], "create": "2/minute", "redeem": "2/minute"}
        install(rate_limits=rl, max_active_links_per_subscription=50)
        hdr = {**ck(to), "cf-connecting-ip": f"192.0.2.{uuid.uuid4().int % 250 + 1}"}
        codes = [client.post(f"/invites/{uo}/subscriptions/{sid}", headers=hdr).status_code for _ in range(4)]
        check("create rate-limited -> 429 after 2", codes[:2] == [201, 201] and 429 in codes[2:], str(codes))
        hdr2 = {**ck(to), "cf-connecting-ip": f"192.0.2.{uuid.uuid4().int % 250 + 1}"}
        codes = [client.post(f"/invites/{uo}/redeem", json={"token": inv.generate_token()}, headers=hdr2).status_code
                 for _ in range(4)]
        check("redeem rate-limited -> 429", 429 in codes[2:], str(codes))
    finally:
        install()
        cleanup([uo], [sid])


def test_config_validation():
    print("\n== New config keys validated strictly ==")
    good = json.loads(open(ic.CONFIG_PATH).read())

    def bad(mut, label):
        raw = copy.deepcopy(good)
        mut(raw)
        try:
            ic.parse_invites_config(raw)
            check(label, False, "accepted")
        except ic.InvitesConfigError:
            check(label, True)

    for k in ("subscription_default_expiry_days", "subscription_allowed_expiry_days",
              "subscription_default_max_uses", "subscription_allowed_max_uses",
              "max_active_links_per_subscription", "max_pending_requests_per_subscription"):
        bad(lambda r, k=k: r.pop(k), f"missing {k} rejected")
    bad(lambda r: r.update(subscription_default_expiry_days=3), "sub default expiry not in allowed set")
    bad(lambda r: r.update(subscription_default_max_uses=4), "sub default max_uses not in allowed set")
    bad(lambda r: r.update(subscription_allowed_max_uses=[]), "empty sub allowed list")
    bad(lambda r: r.update(max_active_links_per_subscription=0), "zero sub link cap")
    bad(lambda r: r.update(max_pending_requests_per_subscription=0), "zero pending cap")
    bad(lambda r: r.update(max_pending_requests_per_subscription=True), "bool pending cap")
    c = ic.parse_invites_config(copy.deepcopy(good))
    check("shipped config parses with new keys", c.max_pending_requests_per_subscription == 10
          and c.subscription_default_max_uses == 5)


def test_group_regression(client):
    print("\n== Group kind smoke (unchanged behavior) ==")
    uc, tc = signup(client, uname())
    uj, tj = signup(client, uname())
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{uc}", json={"group_id": gid, "title": "G", "users": [uc]}, headers=ck(tc))
    assert r.status_code == 201, r.text
    try:
        r = client.post(f"/invites/{uc}/groups/{gid}", headers={**ck(tc), **ip_hdr()})
        check("group create still 201", r.status_code == 201, r.text)
        tok = r.json()["token"]
        pv = preview(client, tok)
        check("group preview keeps group shape", pv.status_code == 200 and pv.json()["kind"] == "group"
              and "group_name" in pv.json(), pv.text)
        r = redeem(client, tj, uj, tok)
        check("group redeem still joins", r.status_code == 200 and r.json() == {
            "kind": "group", "target_id": gid, "joined": True, "already_member": False}, r.text)
    finally:
        q("DELETE FROM invites WHERE target_id = %s", (gid,))
        q("DELETE FROM groups WHERE _id = %s", (gid,))
        cleanup([uc, uj], [])


def main():
    test_config_validation()
    with TestClient(main_module.app) as client:
        install()
        test_create_authz(client)
        test_create_ineligible(client)
        test_redeem_request_only(client)
        test_redeem_rejections(client)
        test_preview(client)
        test_accept_decline(client)
        test_accept_race(client)
        test_redeem_race_single_seat_left(client)
        test_purge(client)
        test_flag_off(client)
        test_rate_limits(client)
        test_group_regression(client)
        ic.set_invites_config_for_tests(None)

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
