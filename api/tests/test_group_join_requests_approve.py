"""Tests for task 20261001-explorer-join-requests, approve / deny / undo-deny.

Properties proved (each would catch a regression of the behaviour it names):
  1. Approve is ONE transaction: a failure after the member append rolls the
     append back; group lock taken FIRST then the request row (a connection
     holding either lock makes approve answer 409 busy within the bound).
  2. Re-checks under the lock: approver still creator AND current member AND not
     suspended; request still pending; applicant exists and not suspended
     (request expires, 409 no_longer_available); block relationships either
     direction (expires, 409); already a member -> approved without a second append.
  3. max_members full -> 409 group_full and the request STAYS pending; frees up
     after a seat opens. The approve cap counts raw groups.users like invite redeem.
  4. SET LOCAL lock_timeout: a second connection holding the group lock gives
     409 busy in well under 5 s, no ERROR level line, no DB_WRITE_FAILURE.
  5. Concurrent approvals into ONE free seat: exactly one 200 and one 409, and the
     group never exceeds max_members.
  6. Approve is idempotent; deny after approve 409; deny idempotent; undo-deny
     works within 10 s, is refused after, for another decider, and when a newer
     pending request from the same applicant exists (unique index).
  7. The invite code is never reused: no invites rows appear.
  8. Logging: audit lines carry ids only (no username, note, title, applicant id).

Scratch DB only (asserts SHOW port = 55432 first).
"""
import _pathfix  # noqa: F401

import logging
import threading
import time

import _jrq_common as J
from _jrq_common import check, decide, make_listing, make_user, members, req, req_status, sql
from backend.interactions.join_requests import JoinRequestError, JoinRequestsManager
from backend.rate_limiting import limiter
from db import DBManager


def pending(cli, pid, owner):
    u = make_user("ap")
    r = req(cli, u, pid)
    assert r.status_code == 201, r.text
    return u, r.json()["id"]


def test_basic_approve(cli, cap):
    print("approve basics, idempotence, deny/undo")
    owner, other = make_user("ow"), make_user("ow")
    gid, pid = make_listing(owner, title="Secret Title Zebra")
    J.set_flags(owner)
    inv0 = sql("SELECT count(*) FROM invites WHERE target_id = %s", (gid,))[0][0]
    a, rid = pending(cli, pid, owner)
    sql("UPDATE group_join_requests SET note = 'private note quokka' WHERE id = %s", (rid,))
    cap.clear()
    r = decide(cli, owner, gid, rid, "approve")
    check("approve 200 approved, not already_member, no internal 'applied' key",
          r.status_code == 200 and r.json() == {"status": "approved", "already_member": False}, r.text)
    check("applicant appended exactly once", members(gid).count(a) == 1)
    check("row approved with decided_by and decided_at",
          sql("SELECT status, decided_by::text, decided_at IS NOT NULL FROM group_join_requests WHERE id = %s", (rid,))[0]
          == ("approved", owner, True))
    r = decide(cli, owner, gid, rid, "approve")
    check("approve twice is idempotent (200) with no second append",
          r.status_code == 200 and r.json()["status"] == "approved" and members(gid).count(a) == 1, r.text)
    r = decide(cli, owner, gid, rid, "deny", json={})
    check("deny after approve: 409 not_pending", r.status_code == 409 and r.json()["detail"]["code"] == "not_pending", r.text)
    check("the invite code is never reused: no invites rows for the group",
          sql("SELECT count(*) FROM invites WHERE target_id = %s", (gid,))[0][0] == inv0)
    lines = "\n".join(cap.lines)
    check("log lines carry no username, note, title or applicant id",
          "private note" not in lines and "Secret Title" not in lines and a not in lines
          and sql("SELECT username FROM users WHERE _id = %s", (a,))[0][0] not in lines)
    check("an audit line exists with group and request ids", f"request={rid}" in lines and f"group={gid}" in lines)
    check("no watchdog-trap line from approve (ERROR/CRITICAL/DB_WRITE_FAILURE)", not cap.watchdog_hits(), cap.watchdog_hits()[:2])

    # request for a different group/unknown id
    r = decide(cli, owner, gid, "00000000-0000-0000-0000-000000000000", "approve")
    check("approve of an unknown request id: 404", r.status_code == 404, r.text)
    g2, p2 = make_listing(other)
    J.set_flags(owner)
    b, rb = pending(cli, p2, other)
    r = decide(cli, owner, gid, rb, "approve")
    check("approve a request that belongs to ANOTHER group via my group id: 404 and untouched",
          r.status_code == 404 and req_status(rb) == "pending" and b not in members(gid))

    # deny + undo-deny window
    c, rc = pending(cli, pid, owner)
    d = decide(cli, owner, gid, rc, "deny", json={})
    check("deny 200", d.status_code == 200 and d.json() == {"status": "denied", "undo_seconds": 10}, d.text)
    check("deny is idempotent", decide(cli, owner, gid, rc, "deny", json={}).status_code == 200)
    u = decide(cli, owner, gid, rc, "undo-deny")
    check("undo-deny within 10 s restores pending (200)",
          u.status_code == 200 and u.json() == {"status": "pending"} and req_status(rc) == "pending", u.text)
    check("undo clears the decision fields and block_reapply",
          sql("SELECT decided_by, decided_at, block_reapply FROM group_join_requests WHERE id = %s", (rc,))[0] == (None, None, False))
    decide(cli, owner, gid, rc, "deny", json={"block_reapply": True})
    sql("UPDATE group_join_requests SET decided_at = NOW() - interval '11 seconds' WHERE id = %s", (rc,))
    u = decide(cli, owner, gid, rc, "undo-deny")
    check("undo-deny after 10 s is refused 409 not_undoable and the row stays denied",
          u.status_code == 409 and u.json()["detail"]["code"] == "not_undoable" and req_status(rc) == "denied", u.text)
    sql("UPDATE group_join_requests SET decided_at = NOW() - interval '9 seconds' WHERE id = %s", (rc,))
    u = decide(cli, owner, gid, rc, "undo-deny")
    check("undo-deny at 9 s is still allowed (boundary)", u.status_code == 200, u.text)
    check("undo of a request that is pending: 409", decide(cli, owner, gid, rc, "undo-deny").status_code == 409)

    # a different decider (an owner swap) cannot undo
    decide(cli, owner, gid, rc, "deny", json={})
    sql("UPDATE group_join_requests SET decided_by = %s WHERE id = %s", (other, rc))
    u = decide(cli, owner, gid, rc, "undo-deny")
    check("undo-deny by someone other than the decider: 409", u.status_code == 409, u.text)
    # unique index: a newer pending request from the same applicant blocks the undo
    sql("UPDATE group_join_requests SET decided_by = %s, decided_at = NOW() WHERE id = %s", (owner, rc))
    sql("INSERT INTO group_join_requests (group_id, user_id) VALUES (%s,%s)", (gid, c))
    cap.clear()
    u = decide(cli, owner, gid, rc, "undo-deny")
    check("undo while a newer pending request exists: 409 not_undoable (unique index), row stays denied",
          u.status_code == 409 and u.json()["detail"]["code"] == "not_undoable" and req_status(rc) == "denied", u.text)
    check("that unique-violation path logs no ERROR", not cap.watchdog_hits(), cap.watchdog_hits()[:2])


def test_rechecks(cli):
    print("re-checks under the lock")
    owner = make_user("ow")
    gid, pid = make_listing(owner)
    J.set_flags(owner)
    # approver suspended / departed / no longer creator
    a, rid = pending(cli, pid, owner)
    sql("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (owner,))
    r = decide(cli, owner, gid, rid, "approve")
    check("approver suspended: 404, request still pending, applicant not added",
          r.status_code == 404 and req_status(rid) == "pending" and a not in members(gid), r.text)
    sql("UPDATE users SET suspended_at = NULL WHERE _id = %s", (owner,))
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (owner, gid))
    r = decide(cli, owner, gid, rid, "approve")
    check("approver no longer a current member (creator_id alone is not enough): 404",
          r.status_code == 404 and req_status(rid) == "pending" and a not in members(gid), r.text)
    sql("UPDATE groups SET users = array_append(users, %s) WHERE _id = %s", (owner, gid))
    sql("UPDATE groups SET creator_id = NULL WHERE _id = %s", (gid,))
    check("ownerless group: approve 404", decide(cli, owner, gid, rid, "approve").status_code == 404)
    sql("UPDATE groups SET creator_id = %s WHERE _id = %s", (owner, gid))
    # non-pending states
    for st in ("withdrawn", "expired"):
        sql("UPDATE group_join_requests SET status = %s, decided_at = NOW() WHERE id = %s", (st, rid))
        r = decide(cli, owner, gid, rid, "approve")
        check(f"approve of a {st} request: 409 not_pending, nobody added",
              r.status_code == 409 and r.json()["detail"]["code"] == "not_pending" and a not in members(gid), r.text)
    # applicant suspended -> expired + 409
    b, rb = pending(cli, pid, owner)
    sql("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (b,))
    r = decide(cli, owner, gid, rb, "approve")
    check("applicant suspended after asking: 409 no_longer_available and the request is expired",
          r.status_code == 409 and r.json()["detail"]["code"] == "no_longer_available"
          and req_status(rb) == "expired" and b not in members(gid), r.text)
    # blocked relationships (applicant blocked by owner, and applicant blocks owner)
    for label, blocker, blocked in (("owner blocks applicant", owner, None), ("applicant blocks owner", None, owner)):
        c, rc = pending(cli, pid, owner)
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blocker or c, blocked or c))
        r = decide(cli, owner, gid, rc, "approve")
        check(f"{label}: approve 409 no_longer_available, expired, not added",
              r.status_code == 409 and r.json()["detail"]["code"] == "no_longer_available"
              and req_status(rc) == "expired" and c not in members(gid), r.text)
    # a block against ANY current member, not just the owner
    m = make_user("ow")
    sql("UPDATE groups SET users = array_append(users, %s) WHERE _id = %s", (m, gid))
    d, rd = pending(cli, pid, owner)
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (m, d))
    r = decide(cli, owner, gid, rd, "approve")
    check("a block with any current member also stops approval", r.status_code == 409 and d not in members(gid), r.text)
    # already a member by another path: approved, no duplicate append
    e, re_ = pending(cli, pid, owner)
    sql("UPDATE groups SET users = array_append(users, %s) WHERE _id = %s", (e, gid))
    r = decide(cli, owner, gid, re_, "approve")
    check("applicant already in the member list: 200 already_member true, no duplicate entry, row approved",
          r.status_code == 200 and r.json()["already_member"] is True and members(gid).count(e) == 1
          and req_status(re_) == "approved", r.text)


def test_full_group(cli):
    print("max_members: full group keeps the request pending")
    owner, m1 = make_user("ow"), make_user("ow")
    gid, pid = make_listing(owner, [m1], max_members=3)
    J.set_flags(owner)
    a, ra = pending(cli, pid, owner)
    b, rb = pending(cli, pid, owner)
    check("first approve fills the last seat",
          decide(cli, owner, gid, ra, "approve").status_code == 200 and len(members(gid)) == 3)
    r = decide(cli, owner, gid, rb, "approve")
    check("full: 409 group_full, request stays PENDING, member list unchanged",
          r.status_code == 409 and r.json()["detail"]["code"] == "group_full" and req_status(rb) == "pending"
          and len(members(gid)) == 3 and b not in members(gid), r.text)
    sql("UPDATE groups SET max_members = 4 WHERE _id = %s", (gid,))
    r = decide(cli, owner, gid, rb, "approve")
    check("after the owner raises the cap the same request approves", r.status_code == 200 and b in members(gid), r.text)
    # the cap counts raw groups.users (a dead id still occupies a seat), like invite redeem
    owner2 = make_user("ow")
    g2, p2 = make_listing(owner2, max_members=2)
    J.set_flags(owner2)
    sql("UPDATE groups SET users = array_append(users, '11111111-1111-1111-1111-111111111111') WHERE _id = %s", (g2,))
    c = make_user("ap")
    sql("INSERT INTO group_join_requests (group_id, user_id) VALUES (%s,%s)", (g2, c))
    rc = sql("SELECT id::text FROM group_join_requests WHERE user_id = %s", (c,))[0][0]
    r = decide(cli, owner2, g2, rc, "approve")
    check("approve counts the raw users array (dead id holds a seat): 409 group_full, still pending",
          r.status_code == 409 and r.json()["detail"]["code"] == "group_full" and req_status(rc) == "pending", r.text)


def test_atomicity_and_locks(cli, cap):
    print("one transaction, lock order, bounded lock wait")
    owner = make_user("ow")
    gid, pid = make_listing(owner)
    J.set_flags(owner)
    a, rid = pending(cli, pid, owner)

    # atomicity: fail AFTER the member append -> the append is rolled back
    real = JoinRequestsManager._decide

    def boom(self, *args, **kw):
        raise RuntimeError("injected failure after the append")

    JoinRequestsManager._decide = boom
    try:
        m = JoinRequestsManager(owner)
        try:
            try:
                m.approve(gid, rid)
                raised = False
            except RuntimeError:
                raised = True
        finally:
            m.close()
    finally:
        JoinRequestsManager._decide = real
    check("failure after the append: raised", raised)
    check("the member append was rolled back (one transaction)", a not in members(gid))
    check("the request is still pending", req_status(rid) == "pending")

    # bounded wait on the group lock
    J.override_cfg(lock_timeout_ms=400)
    try:
        hold = DBManager()
        hold.cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (gid,))
        cap.clear()
        t0 = time.time()
        r = decide(cli, owner, gid, rid, "approve")
        el = time.time() - t0
        hold.conn.rollback()
        hold.close()
        check("group lock held elsewhere: 409 busy (SET LOCAL lock_timeout) in < 5 s",
              r.status_code == 409 and r.json()["detail"]["code"] == "busy" and el < 5, (r.status_code, r.text, el))
        check("busy is logged without ERROR or DB_WRITE_FAILURE (INFO wording only)",
              not cap.watchdog_hits() and not any(x.levelno >= logging.WARNING and "JOIN_REQUEST" in x.getMessage()
                                                  for x in cap.records), cap.watchdog_hits()[:2])
        check("a busy approve changed nothing", req_status(rid) == "pending" and a not in members(gid))
        # the group lock came first: with the REQUEST row locked and the group free, approve
        # takes the group lock and then waits on the request row (also bounded, also 409)
        hold = DBManager()
        hold.cur.execute("SELECT 1 FROM group_join_requests WHERE id = %s FOR UPDATE", (rid,))
        t0 = time.time()
        r = decide(cli, owner, gid, rid, "approve")
        el = time.time() - t0
        hold.conn.rollback()
        hold.close()
        check("request row locked elsewhere: bounded 409 busy as well",
              r.status_code == 409 and r.json()["detail"]["code"] == "busy" and el < 5, (r.text, el))
        # deny / accepting / set transactions are bounded too
        hold = DBManager()
        hold.cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (gid,))
        t0 = time.time()
        r2 = J.call(cli, "put", f"/join-requests/{owner}/groups/{gid}/accepting", owner, json={"accepting": False})
        el2 = time.time() - t0
        hold.conn.rollback()
        hold.close()
        check("accepting toggle with the group locked elsewhere: 409 busy in < 5 s",
              r2.status_code == 409 and r2.json()["detail"]["code"] == "busy" and el2 < 5, (r2.text, el2))
        # a new create waits on the group lock too
        hold = DBManager()
        hold.cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (gid,))
        u = make_user("ap")
        t0 = time.time()
        r3 = req(cli, u, pid)
        el3 = time.time() - t0
        hold.conn.rollback()
        hold.close()
        check("create with the group locked elsewhere: 409 busy in < 5 s, no row",
              r3.status_code == 409 and el3 < 5
              and sql("SELECT count(*) FROM group_join_requests WHERE user_id = %s", (u,))[0][0] == 0, (r3.text, el3))
        check("none of the busy paths logged ERROR / DB_WRITE_FAILURE", not cap.watchdog_hits(), cap.watchdog_hits()[:2])
    finally:
        J.restore_cfg()
    r = decide(cli, owner, gid, rid, "approve")
    check("after the lock is released approve succeeds", r.status_code == 200 and a in members(gid), r.text)


def test_concurrent(cli):
    print("concurrent approvals into one free seat")
    owner = make_user("ow")
    gid, pid = make_listing(owner, max_members=2)
    J.set_flags(owner)
    ids = [pending(cli, pid, owner)[1] for _ in range(1)]
    # two requests need two applicants; max_members=2 with owner => one free seat.
    # Insert the second directly (listing_requestable would read the group as full only after the first).
    c = make_user("ap")
    sql("INSERT INTO group_join_requests (group_id, user_id) VALUES (%s,%s)", (gid, c))
    ids.append(sql("SELECT id::text FROM group_join_requests WHERE user_id = %s", (c,))[0][0])
    from fastapi.testclient import TestClient
    import main as M
    results = []
    barrier = threading.Barrier(2)

    def go(rid):
        cl = TestClient(M.app)
        barrier.wait()
        results.append(cl.post(f"/join-requests/{owner}/groups/{gid}/requests/{rid}/approve",
                               headers=J.H(owner)).status_code)

    limiter.reset()
    ts = [threading.Thread(target=go, args=(i,)) for i in ids]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("exactly one 200 and one 409", sorted(results) == [200, 409], results)
    check("the group never exceeds max_members", len(members(gid)) == 2, members(gid))
    check("exactly one request approved, the other still pending",
          sorted(req_status(i) for i in ids) == ["approved", "pending"])


def main():
    cli, cap = J.start()
    try:
        test_basic_approve(cli, cap)
        test_rechecks(cli)
        test_full_group(cli)
        test_atomicity_and_locks(cli, cap)
        test_concurrent(cli)
        check("no watchdog error signal in any log line emitted by these flows",
              not cap.watchdog_hits(), cap.watchdog_hits()[:3])
    finally:
        J.finish()


if __name__ == "__main__":
    main()
