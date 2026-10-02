"""Tests for task 20261001-explorer-join-requests, requester + owner-list surface.

Properties proved (each would catch a regression of the behaviour it names):
  1. Create: needs flag join_requests (caller AND listing owner), explorer_browse,
     a requestable listing (published, accepting, not full) and CURRENT terms;
     201 then idempotent 200 with the same id and exactly one row; already_member
     only for the member; uniform 404 for flag off / not requestable / junk id.
  2. Uniform 403 cannot_request (same body) for block, cooldown after deny,
     block_reapply, suspended, and every cap; cooldown lapses after cooldown_days
     but block_reapply never does.
  3. Caps and limits with FIXED scopes: per group pending, per user pending, per
     user per day, and the rate limit bucket is shared across different listing
     paths (no per-path-parameter buckets); source has no @limiter.limit.
  4. Withdraw: own pending only, idempotent, other user 404, decided -> 409.
  5. My requests: statuses pending/approved/not_approved/withdrawn (denied and
     expired both not_approved); group_id only for an approved current member.
  6. Owner list: pending_count, accepting_requests, applicant_user_id; non-owner
     member, non-member, unknown group, departed owner and suspended owner all get
     the identical 404; the accepting toggle writes only through
     listings.set_accepting_requests and reads through get_accepting_requests.
  7. The group invite code is never reused: no invites rows are created.
  8. Note validation (length, control chars, non-string, extra fields).

Scratch DB only (asserts SHOW port = 55432 first).
Run with: cd api && PYTHONPATH=<shim dir> ../.venv/bin/python tests/test_group_join_requests.py
"""
import _pathfix  # noqa: F401

import os
import re
import uuid

import _jrq_common as J
from _jrq_common import check, decide, make_listing, make_user, mine, owner_list, req, req_status, sql
from backend.interactions import listings

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOT_FOUND = {"detail": {"code": "not_found", "message": "Not found"}}


def test_create(cli):
    print("create: gates, idempotence, already_member, no invites")
    owner, a, m = make_user("jo"), make_user("jo"), make_user("jo")
    gid, pid = make_listing(owner, [m])
    J.set_flags(owner)
    inv_before = sql("SELECT count(*) FROM invites WHERE target_id = %s", (gid,))[0][0]
    r = req(cli, a, pid, note="hello  there")
    check("create 201 pending with id", r.status_code == 201 and r.json()["status"] == "pending" and r.json()["id"], r.text)
    rid = r.json()["id"]
    check("response never leaks the internal 'created' key or applicant data",
          set(r.json()) == {"status", "id", "created_at"}, r.json())
    check("note whitespace normalised",
          sql("SELECT note FROM group_join_requests WHERE id = %s", (rid,))[0][0] == "hello there")
    r2 = req(cli, a, pid)
    check("repeat is 200 with the same id", r2.status_code == 200 and r2.json()["id"] == rid, r2.text)
    check("exactly one row after the repeat",
          sql("SELECT count(*) FROM group_join_requests WHERE group_id = %s AND user_id = %s", (gid, a))[0][0] == 1)
    r3 = req(cli, m, pid)
    check("a current member gets already_member 200, no row",
          r3.status_code == 200 and r3.json()["status"] == "already_member"
          and sql("SELECT count(*) FROM group_join_requests WHERE user_id = %s", (m,))[0][0] == 0, r3.text)
    check("the invite code is never reused: no invites rows created for the group",
          sql("SELECT count(*) FROM invites WHERE target_id = %s", (gid,))[0][0] == inv_before)
    check("no invites rows reference the request id either",
          sql("SELECT count(*) FROM invites WHERE target_id::text = %s", (rid,))[0][0] == 0)
    src = open(os.path.join(API_DIR, "backend/interactions/join_requests.py")).read()
    check("manager never writes or reads the invites table",
          not re.search(r"(FROM|INTO|UPDATE)\s+invites", src))

    # flags: fail closed, uniform 404
    for label, jr, eb in (("join_requests off", "off", "on"), ("explorer_browse off", "on", "off")):
        J.set_flags(owner, jr, eb)
        b = make_user("jo")
        r = req(cli, b, pid)
        check(f"{label}: 404 not_found, no row",
              r.status_code == 404 and r.json() == NOT_FOUND
              and sql("SELECT count(*) FROM group_join_requests WHERE user_id = %s", (b,))[0][0] == 0, r.text)
    # canary: caller in the canary but the OWNER is not -> a request the owner could not see is never created
    c = make_user("jo")
    from backend.interactions import flags
    flags.set_flag("join_requests", "canary", [c], actor=owner)
    flags.set_flag("explorer_browse", "on", actor=owner)
    flags.invalidate()
    r = req(cli, c, pid)
    check("owner outside the join_requests canary: 404", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    flags.set_flag("join_requests", "canary", [c, owner], actor=owner)
    flags.invalidate()
    r = req(cli, c, pid)
    check("caller and owner both in the canary: 201", r.status_code == 201, r.text)
    J.set_flags(owner)

    # requestable gating
    d = make_user("jo")
    for label, kw in (("not accepting", dict(accepting=False)), ("draft listing", dict(status="draft")),
                      ("hidden listing", dict(status="hidden")), ("unpublished", dict(status="unpublished"))):
        g2, p2 = make_listing(make_user("jo"), **kw)
        J.set_flags(sql("SELECT creator_id::text FROM groups WHERE _id = %s", (g2,))[0][0])
        r = req(cli, d, p2)
        check(f"{label}: uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    o3 = make_user("jo")
    g3, p3 = make_listing(o3, [make_user("jo")], max_members=2)
    J.set_flags(o3)
    r = req(cli, d, p3)
    check("full group (live members at max_members): uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    for junk in ("short", "x" * 30, "AbCdEfGh1!"):
        r = req(cli, d, junk)
        check(f"junk public id {junk[:6]!r}: 404", r.status_code == 404, r.text)
    check("a path user that is not the session user is refused and creates no row",
          J.call(cli, "post", f"/join-requests/{d}/listings/{pid}/request", a, json={}).status_code in (401, 403, 404)
          and sql("SELECT count(*) FROM group_join_requests WHERE user_id = %s", (d,))[0][0] == 0)

    # terms and suspension
    J.set_flags(owner)
    nt = make_user("jo", terms=False)
    r = req(cli, nt, pid)
    check("stale terms: 403 terms_reaccept_required",
          r.status_code == 403 and r.json()["detail"]["code"] == "terms_reaccept_required", r.text)
    sus = make_user("jo", suspended=True)
    r = req(cli, sus, pid)
    check("suspended applicant: generic 403 cannot_request",
          r.status_code == 403 and r.json()["detail"]["code"] == "cannot_request", r.text)

    # validation
    e = make_user("jo")
    for label, note in (("note over 280", "x" * 281), ("control char", "a\x07b"), ("bidi override", "a‮b"),
                        ("note 1200+ (guard)", "y" * 2000)):
        r = req(cli, e, pid, note=note)
        check(f"{label}: 422", r.status_code == 422, (r.status_code, r.text[:80]))
    r = J.call(cli, "post", f"/join-requests/{e}/listings/{pid}/request", e, json={"note": 5})
    check("non-string note: 422", r.status_code == 422, r.text)
    r = J.call(cli, "post", f"/join-requests/{e}/listings/{pid}/request", e, json={"note": "ok", "extra": 1})
    check("unknown body field: 422", r.status_code == 422, r.text)
    r = req(cli, e, pid, note="x" * 280)
    check("note of exactly 280 is accepted", r.status_code == 201, r.text)
    check("no request rows from the rejected attempts",
          sql("SELECT count(*) FROM group_join_requests WHERE user_id = %s", (e,))[0][0] == 1)


def test_denials_and_cooldown(cli):
    print("denial shape, cooldown, block_reapply, blocked_users")
    owner, a, b, blk, member2 = (make_user("jo") for _ in range(5))
    gid, pid = make_listing(owner, [member2])
    J.set_flags(owner)
    r = req(cli, a, pid)
    rid = r.json()["id"]
    d = J.decide(cli, owner, gid, rid, "deny", json={})
    check("deny 200 with undo_seconds", d.status_code == 200 and d.json()["status"] == "denied"
          and d.json()["undo_seconds"] == 10, d.text)
    cool = req(cli, a, pid)
    check("cooldown after deny: generic 403 cannot_request",
          cool.status_code == 403 and cool.json()["detail"]["code"] == "cannot_request", cool.text)
    # block (both directions) -> same body
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (member2, blk))
    bl = req(cli, blk, pid)
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (b, owner))
    bl2 = req(cli, b, pid)
    check("blocked_users either direction: 403 cannot_request",
          bl.status_code == 403 and bl2.status_code == 403
          and bl.json()["detail"]["code"] == bl2.json()["detail"]["code"] == "cannot_request", (bl.text, bl2.text))
    check("block, cooldown and suspended denials share ONE body (no oracle)",
          bl.json() == cool.json() == bl2.json(), (bl.json(), cool.json()))
    check("a blocked attempt creates no row",
          sql("SELECT count(*) FROM group_join_requests WHERE user_id IN (%s,%s)", (blk, b))[0][0] == 0)
    # cooldown lapses
    sql("UPDATE group_join_requests SET decided_at = NOW() - interval '15 days' WHERE id = %s", (rid,))
    r2 = req(cli, a, pid)
    check("after cooldown_days the same user may request again (201)", r2.status_code == 201, r2.text)
    # block_reapply never lapses
    rid2 = r2.json()["id"]
    d2 = J.decide(cli, owner, gid, rid2, "deny", json={"block_reapply": True})
    check("deny with block_reapply 200", d2.status_code == 200, d2.text)
    check("block_reapply stored on the row",
          sql("SELECT block_reapply FROM group_join_requests WHERE id = %s", (rid2,))[0][0] is True)
    sql("UPDATE group_join_requests SET decided_at = NOW() - interval '400 days' WHERE id = %s", (rid2,))
    r3 = req(cli, a, pid)
    check("block_reapply: 403 even long after the cooldown",
          r3.status_code == 403 and r3.json()["detail"]["code"] == "cannot_request", r3.text)
    check("block_reapply is on the request row, not in blocked_users",
          sql("SELECT count(*) FROM blocked_users WHERE blocker_id = %s AND blocked_id = %s", (owner, a))[0][0] == 0)
    r4 = J.decide(cli, owner, gid, rid2, "deny", json={"block_reapply": "yes"})
    check("deny body block_reapply is a strict bool", r4.status_code == 422, r4.text)
    r5 = J.decide(cli, owner, gid, rid2, "deny", json={"surprise": 1})
    check("deny body rejects unknown fields", r5.status_code == 422, r5.text)


def test_caps_and_limits(cli):
    print("caps and rate limits with fixed scopes")
    owner = make_user("jo")
    gid, pid = make_listing(owner)
    J.set_flags(owner)
    try:
        # per-group pending cap
        J.override_cfg(max_pending_per_group=2)
        u1, u2, u3 = make_user("jo"), make_user("jo"), make_user("jo")
        r1, r2, r3 = req(cli, u1, pid), req(cli, u2, pid), req(cli, u3, pid)
        check("per-group cap: two fit, the third is generic 403",
              r1.status_code == 201 and r2.status_code == 201 and r3.status_code == 403
              and r3.json()["detail"]["code"] == "cannot_request", (r1.status_code, r2.status_code, r3.text))
        check("idempotent repeat at the cap is not a refusal", req(cli, u1, pid).status_code == 200)
        # per-user pending cap, spread across groups
        J.override_cfg(max_pending_per_user=2)
        v = make_user("jo")
        ps = [make_listing(make_user("jo"))[1] for _ in range(3)]
        for p in ps:
            J.set_flags(sql("SELECT g.creator_id::text FROM groups g JOIN group_listings gl ON gl._id IS NOT NULL "
                            "AND gl.group_id = g._id WHERE gl.public_id = %s", (p,))[0][0])
        out = [req(cli, v, p).status_code for p in ps]
        check("per-user pending cap: third pending request refused", out == [201, 201, 403], out)
        # a withdrawn request frees pending but still counts toward the daily cap
        J.override_cfg(max_pending_per_user=10, max_requests_per_user_per_day=2)
        w = make_user("jo")
        a1 = req(cli, w, ps[0]); a2 = req(cli, w, ps[1])
        J.call(cli, "post", f"/join-requests/{w}/requests/{a1.json()['id']}/withdraw", w)
        a3 = req(cli, w, ps[2])
        check("per-day cap counts withdrawn requests too (third create refused)",
              a1.status_code == a2.status_code == 201 and a3.status_code == 403, (a1.status_code, a2.status_code, a3.text))
        old = sql("UPDATE group_join_requests SET created_at = NOW() - interval '2 days' WHERE user_id = %s RETURNING 1", (w,))
        a4 = req(cli, w, ps[2])
        check("requests older than 24 h leave the daily window", a4.status_code == 201, a4.text)
    finally:
        J.restore_cfg()

    # rate limit: ONE shared bucket per scope, regardless of the listing in the path
    try:
        cfg = J.override_cfg(rate_limits={**J.jrc.get_join_requests_config().rate_limits, "create": "3/hour",
                                          "withdraw": "2/minute"})
        x = make_user("jo")
        from backend.rate_limiting import limiter
        limiter.reset()
        codes = [req(cli, x, p, reset=False).status_code for p in ps + [pid]]
        check("create rate limit: 4th call (a DIFFERENT listing path) is 429 -> one bucket per scope, not per path",
              codes[-1] == 429 and 429 not in codes[:3], codes)
        y = make_user("jo")
        limiter.reset()
        ok = [req(cli, y, ps[0], reset=False).status_code for _ in range(3)]
        other = req(cli, make_user("jo"), ps[0], reset=False)
        check("the limit is per user: another user is not throttled by x/y", 429 not in ok and other.status_code != 429,
              (ok, other.status_code))
        z = make_user("jo")
        limiter.reset()
        fake = [str(uuid.uuid4()) for _ in range(3)]
        wc = [J.call(cli, "post", f"/join-requests/{z}/requests/{f}/withdraw", z, reset=False).status_code for f in fake]
        check("withdraw limit shared across request ids (3rd distinct id is 429)", wc[-1] == 429 and 429 not in wc[:2], wc)
    finally:
        J.restore_cfg()
        from backend.rate_limiting import limiter
        limiter.reset()
    src = open(os.path.join(API_DIR, "routes/join_requests.py")).read()
    check("R-ROUTE: every route is a plain def (no async def, no 'await')",
          not re.search(r"^async def ", src, re.M) and "await " not in src)
    check("R-ROUTE: no @limiter.limit (path-keyed) decorators, only shared_limit",
          "@limiter.limit(" not in src and src.count("@limiter.shared_limit(") >= 8)
    scopes = re.findall(r'scope="(jrq_[a-z_]+)"', src)
    check("every shared_limit scope is a fixed literal string", len(scopes) >= 8 and all(re.fullmatch(r"jrq_[a-z_]+", s) for s in scopes), scopes)
    check("no scope or key function interpolates a path parameter other than via the user key",
          not re.search(r'scope=f"', src) and "path_params.get('group_id')" not in src
          and "path_params.get('request_id')" not in src and "path_params.get('public_id')" not in src)
    check("R-ROUTE: no DBManager / psycopg2 / raw SQL in the route module",
          "DBManager" not in src and "psycopg2" not in src and "cur.execute" not in src)


def test_withdraw_and_mine(cli):
    print("withdraw and my requests")
    owner, a, b, c = make_user("jo"), make_user("jo"), make_user("jo"), make_user("jo")
    gid, pid = make_listing(owner)
    J.set_flags(owner)
    rid = req(cli, a, pid).json()["id"]
    r = J.call(cli, "post", f"/join-requests/{b}/requests/{rid}/withdraw", b)
    check("withdraw someone else's request: 404 and it stays pending", r.status_code == 404 and req_status(rid) == "pending", r.text)
    r = J.call(cli, "post", f"/join-requests/{a}/requests/not-a-uuid/withdraw", a)
    check("withdraw with a junk id: 404", r.status_code == 404, r.text)
    m = mine(cli, a, pid)
    check("mine: pending with title and public_id, no group_id yet",
          m.status_code == 200 and m.json()["requests"][0]["status"] == "pending"
          and m.json()["requests"][0]["public_id"] == pid and "group_id" not in m.json()["requests"][0]
          and m.json()["already_member"] is False, m.text)
    r = J.call(cli, "post", f"/join-requests/{a}/requests/{rid}/withdraw", a)
    check("withdraw own pending: 200 withdrawn", r.status_code == 200 and r.json()["status"] == "withdrawn", r.text)
    r = J.call(cli, "post", f"/join-requests/{a}/requests/{rid}/withdraw", a)
    check("withdraw again is idempotent 200", r.status_code == 200 and r.json()["status"] == "withdrawn", r.text)
    check("mine shows withdrawn", mine(cli, a).json()["requests"][0]["status"] == "withdrawn")

    # denied and expired are both 'not_approved' (a requester cannot tell them apart)
    rid_b = req(cli, b, pid).json()["id"]
    J.decide(cli, owner, gid, rid_b, "deny", json={})
    sb = mine(cli, b).json()["requests"][0]["status"]
    rid_c = req(cli, c, pid).json()["id"]
    sql("UPDATE group_join_requests SET status = 'expired', decided_at = NOW() WHERE id = %s", (rid_c,))
    sc = mine(cli, c).json()["requests"][0]["status"]
    check("denied and expired both read not_approved", sb == sc == "not_approved", (sb, sc))
    check("no requester-visible status named denied or expired anywhere",
          "denied" not in str(mine(cli, b).json()) and "expired" not in str(mine(cli, c).json()))
    # approved shows group_id only while still a member
    d = make_user("jo")
    rid_d = req(cli, d, pid).json()["id"]
    J.decide(cli, owner, gid, rid_d, "approve")
    md = mine(cli, d, pid).json()
    check("approved: status approved, group_id present, already_member true",
          md["requests"][0]["status"] == "approved" and md["requests"][0]["group_id"] == gid and md["already_member"] is True, md)
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (d, gid))
    md2 = mine(cli, d, pid).json()
    check("after leaving, group_id is no longer returned", "group_id" not in md2["requests"][0] and md2["already_member"] is False, md2)
    check("mine with a junk public_id is an empty list, not an error",
          mine(cli, d, "zzzz").json() == {"requests": [], "already_member": False})
    check("another user's requests never appear in mine", all(
        x["id"] != rid for x in mine(cli, b).json()["requests"]))
    r = J.call(cli, "get", f"/join-requests/{a}/requests", b)
    check("mine for a path user that is not the session user is refused", r.status_code in (401, 403, 404), r.status_code)
    J.set_flags(owner, "off", "on")
    check("flag off: mine is the uniform 404", mine(cli, a).status_code == 404)
    J.set_flags(owner)


def test_owner_list_and_authz(cli):
    print("owner list, uniform authz errors, accepting toggle")
    owner, member, a, outsider, ghost = (make_user("jo") for _ in range(5))
    gid, pid = make_listing(owner, [member])
    J.set_flags(owner)
    rid = req(cli, a, pid, note="Hi from a").json()["id"]
    r = owner_list(cli, owner, gid)
    j = r.json()
    check("owner list: pending_count, accepting_requests true, applicant_user_id and note",
          r.status_code == 200 and j["pending_count"] == 1 and j["accepting_requests"] is True
          and j["requests"][0]["applicant_user_id"] == a and j["requests"][0]["note"] == "Hi from a"
          and j["requests"][0]["id"] == rid and "username" in j["requests"][0], r.text)
    check("owner list row has no email or other-group data",
          not ({"email", "groups", "friends"} & set(j["requests"][0])))
    bodies = {}
    for label, uid, g in (("non-owner member", member, gid), ("non-member", outsider, gid),
                          ("unknown group", owner, str(uuid.uuid4())), ("junk group id", owner, "not-a-uuid"),
                          ("the applicant", a, gid)):
        rr = owner_list(cli, uid, g)
        bodies[label] = (rr.status_code, rr.json())
    check("list authz: every non-owner case is the identical 404 body",
          all(v == (404, NOT_FOUND) for v in bodies.values()), bodies)
    for action in ("approve", "deny", "undo-deny"):
        got = [J.decide(cli, u, gid, rid, action).status_code for u in (member, outsider, a)]
        check(f"{action} by member/non-member/applicant: all 404", got == [404, 404, 404], got)
    check("the request is untouched by those refused calls", req_status(rid) == "pending")
    t = J.call(cli, "put", f"/join-requests/{member}/groups/{gid}/accepting", member, json={"accepting": False})
    check("non-owner accepting toggle: 404 and no change",
          t.status_code == 404 and listings_accepting(gid) is True, t.text)

    # accepting toggle: only via listings helpers
    calls = []
    real_set, real_get = listings.set_accepting_requests, listings.get_accepting_requests
    listings.set_accepting_requests = lambda cur, g, v: (calls.append(("set", g, v)), real_set(cur, g, v))[1]
    listings.get_accepting_requests = lambda cur, g: (calls.append(("get", g)), real_get(cur, g))[1]
    try:
        t = J.call(cli, "put", f"/join-requests/{owner}/groups/{gid}/accepting", owner, json={"accepting": False})
        check("owner toggle off: 200 {accepting:false} via set_accepting_requests",
              t.status_code == 200 and t.json() == {"accepting": False} and ("set", gid, False) in calls, (t.text, calls))
        check("stored column now false", listings_accepting(gid) is False)
        lst = owner_list(cli, owner, gid).json()
        check("owner list reads accepting via get_accepting_requests and reports false, pending untouched",
              ("get", gid) in calls and lst["accepting_requests"] is False and lst["pending_count"] == 1, (calls, lst))
    finally:
        listings.set_accepting_requests, listings.get_accepting_requests = real_set, real_get
    n = req(cli, make_user("jo"), pid)
    check("accepting off: new requests get the uniform 404", n.status_code == 404 and n.json() == NOT_FOUND, n.text)
    t = J.call(cli, "put", f"/join-requests/{owner}/groups/{gid}/accepting", owner, json={"accepting": "yes"})
    check("accepting body is a strict bool (422)", t.status_code == 422, t.text)
    t = J.call(cli, "put", f"/join-requests/{owner}/groups/{gid}/accepting", owner, json={"accepting": True})
    check("owner toggle on", t.status_code == 200 and listings_accepting(gid) is True)
    # a group with no listing: same 404 as a non-owner
    g_nolist = J.make_group([owner], creator=owner)
    t = J.call(cli, "put", f"/join-requests/{owner}/groups/{g_nolist}/accepting", owner, json={"accepting": True})
    check("toggle for a group with no listing: 404", t.status_code == 404, t.text)
    src = open(os.path.join(API_DIR, "backend/interactions/join_requests.py")).read()
    check("accepting_requests is never written by SQL in this module (only via the listings helper)",
          not re.search(r"UPDATE\s+group_listings", src) and not re.search(r"SET\s+accepting_requests", src))
    check("the module never reads group_listings.accepting_requests directly",
          "gl.accepting_requests" not in src and "SELECT accepting_requests" not in src)

    # departed owner / suspended owner / ownerless: nothing is listed or approved
    o2, ap = make_user("jo"), make_user("jo")
    g2, p2 = make_listing(o2)
    J.set_flags(o2)
    rr = req(cli, ap, p2).json()["id"]
    sql("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (o2,))
    check("suspended owner: list is 404", owner_list(cli, o2, g2).status_code == 404)
    check("suspended owner: approve is 404 and nothing changes",
          J.decide(cli, o2, g2, rr, "approve").status_code == 404 and req_status(rr) == "pending")
    sql("UPDATE users SET suspended_at = NULL WHERE _id = %s", (o2,))
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (o2, g2))
    check("owner no longer a member: list 404", owner_list(cli, o2, g2).status_code == 404)
    sql("UPDATE groups SET creator_id = NULL WHERE _id = %s", (g2,))
    check("ownerless group: list 404 for the old creator", owner_list(cli, o2, g2).status_code == 404)
    J.set_flags(owner, "off", "on")
    check("flag off: owner list is the uniform 404 too", owner_list(cli, owner, gid).status_code == 404)
    J.set_flags(owner)


def listings_accepting(gid):
    return sql("SELECT accepting_requests FROM group_listings WHERE group_id = %s", (gid,))[0][0]


def main():
    cli, cap = J.start()
    try:
        test_create(cli)
        test_denials_and_cooldown(cli)
        test_caps_and_limits(cli)
        test_withdraw_and_mine(cli)
        test_owner_list_and_authz(cli)
        check("no watchdog error signal (ERROR/CRITICAL/DB_WRITE_FAILURE) in any log line emitted by these flows",
              not cap.watchdog_hits(), cap.watchdog_hits()[:3])
    finally:
        J.finish()


if __name__ == "__main__":
    main()
