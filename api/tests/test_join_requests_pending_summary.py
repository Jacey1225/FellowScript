"""Tests for GET /join-requests/{user_id}/pending-summary (notification badge source).

Properties proved:
  1. Owner gets {groups: [{group_id, pending_count, newest_request_at}]} for owned groups with pending
     requests only; groups with none pending are omitted; decided requests do not count.
  2. Counts only: no applicant ids, usernames or notes in the body.
  3. A non-owner member, a non-member and a user with no owned groups get an empty
     list (no enumeration of other owners' groups).
  4. Another user's id in the path is rejected by require_match; no cookie is 401.
  5. Flag join_requests off for the caller returns 200 with an empty list.
  6. A suspended owner, or an owner who left the group, gets nothing.
  7. The route shares the owner_read rate limit bucket and does not shadow
     GET /{user_id}/requests.

Scratch DB only (asserts SHOW port = 55432 first).
Run with: cd api && ../.venv/bin/python tests/test_join_requests_pending_summary.py
"""
import _pathfix  # noqa: F401

import re

from backend.interactions import paging

import _jrq_common as J
from _jrq_common import call, check, make_listing, make_user, req, sql


def summary(cli, uid, as_uid=None):
    return call(cli, "get", f"/join-requests/{uid}/pending-summary", as_uid or uid)


def test_owner_counts(cli):
    print("owner: counts per owned group, pending only")
    owner, a, b, c, m = (make_user("ps") for _ in range(5))
    g1, p1 = make_listing(owner, [m])
    g2, p2 = make_listing(owner)
    g3, _p3 = make_listing(owner)
    J.set_flags(owner)
    for u in (a, b):
        check("request placed", req(cli, u, p1).status_code == 201)
    check("request placed on g2", req(cli, c, p2).status_code == 201)
    # a decided request must not count
    rid = sql("SELECT id::text FROM group_join_requests WHERE group_id = %s AND user_id = %s", (g1, b))[0][0]
    sql("UPDATE group_join_requests SET status = 'denied', decided_at = NOW() WHERE id = %s", (rid,))
    r = summary(cli, owner)
    check("200", r.status_code == 200, r.text)
    got = {x["group_id"]: x["pending_count"] for x in r.json()["groups"]}
    check("g1 counts only the pending one, g2 counts one, g3 omitted", got == {g1: 1, g2: 1}, got)
    check("body is counts only",
          all(set(x) == {"group_id", "pending_count", "newest_request_at"} for x in r.json()["groups"]) and set(r.json()) == {"groups"},
          r.json())
    stamp = {x["group_id"]: x["newest_request_at"] for x in r.json()["groups"]}
    fmt = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$")
    check("newest_request_at is UTC ISO with microseconds and Z", all(fmt.match(v) for v in stamp.values()), stamp)
    expect = sql("SELECT max(created_at) FROM group_join_requests WHERE group_id = %s AND status = 'pending'", (g1,))[0][0]
    check("g1 newest_request_at equals max pending created_at", stamp[g1] == paging.format_timestamp(expect), (stamp[g1], expect))
    # newest moves forward with a later pending request and ignores decided ones
    sql("UPDATE group_join_requests SET created_at = created_at + INTERVAL '1 hour' WHERE group_id = %s AND user_id = %s", (g1, b))
    again = {x["group_id"]: x["newest_request_at"] for x in summary(cli, owner).json()["groups"]}
    check("denied request does not move newest_request_at", again[g1] == stamp[g1], (again, stamp))
    text = r.text
    check("no applicant ids in the body", a not in text and b not in text and c not in text, text)
    # not owner
    for label, uid in (("member", m), ("applicant", a), ("stranger", make_user("ps"))):
        rr = summary(cli, uid)
        check(f"{label} gets empty list", rr.status_code == 200 and rr.json() == {"groups": []}, rr.text)
    return owner, g1


def test_auth(cli, owner):
    print("auth: require_match")
    other = make_user("ps")
    r = summary(cli, owner, as_uid=other)
    check("other user's id in path is rejected", r.status_code in (401, 403) and "groups" not in r.text, r.text)
    J.limiter.reset()
    r = cli.get(f"/join-requests/{owner}/pending-summary")
    check("no cookie rejected", r.status_code in (401, 403), r.status_code)


def test_flag_off(cli):
    print("flag: off returns empty, not an error")
    owner, a = make_user("ps"), make_user("ps")
    _gid, pid = make_listing(owner)
    J.set_flags(owner)
    check("request placed", req(cli, a, pid).status_code == 201)
    check("flag on shows count", len(summary(cli, owner).json()["groups"]) == 1)
    J.set_flags(owner, join_requests="off")
    r = summary(cli, owner)
    check("flag off: 200 empty", r.status_code == 200 and r.json() == {"groups": []}, r.text)
    J.set_flags(owner)


def test_owner_state(cli):
    print("owner state: suspended or departed owner sees nothing")
    owner, a = make_user("ps"), make_user("ps")
    gid, pid = make_listing(owner)
    J.set_flags(owner)
    check("request placed", req(cli, a, pid).status_code == 201)
    sql("UPDATE groups SET users = %s WHERE _id = %s", ([a], gid))
    check("owner no longer a member: empty", summary(cli, owner).json() == {"groups": []})
    sql("UPDATE groups SET users = %s WHERE _id = %s", ([owner, a], gid))
    check("restored: counted", len(summary(cli, owner).json()["groups"]) == 1)
    sql("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (owner,))
    check("suspended owner: empty", summary(cli, owner).json() == {"groups": []})


def test_routing_and_limit(cli):
    print("routing and rate limit")
    owner = make_user("ps")
    J.set_flags(owner)
    r = J.mine(cli, owner)
    check("GET /requests not shadowed", r.status_code == 200 and "requests" in r.json(), r.text)
    J.override_cfg(rate_limits={**J.jrc.get_join_requests_config().rate_limits, "owner_read": "2/minute"})
    J.limiter.reset()
    codes = [cli.get(f"/join-requests/{owner}/pending-summary", headers=J.H(owner)).status_code for _ in range(3)]
    check("owner_read limit applies (3rd call 429)", codes == [200, 200, 429], codes)
    J.restore_cfg()


if __name__ == "__main__":
    cli, _cap = J.start()
    try:
        owner, _g = test_owner_counts(cli)
        test_auth(cli, owner)
        test_flag_off(cli)
        test_owner_state(cli)
        test_routing_and_limit(cli)
    finally:
        J.finish()
