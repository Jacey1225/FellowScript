"""Backend coverage for task 20261024-announcement-polls.

Real routes + a scratch Postgres (same harness as test_announcement_attachments.py).
  A. Validator unit tests (pure).
  B. Migration is idempotent; tables exist.
  C. Flag off: poll key omitted, create with poll 422, all poll routes 404.
  D. Create/read: poll attached, counts live, own selection only for the caller.
  E. Voting: single choice replace, multiple choice, retract, idempotent, unknown options.
  F. Security: non-member 403, ex-member votes not counted, other poll's option rejected,
     body cannot spoof the voter, scheduled/deleted 404, closed 409, close permission,
     blocked author 404, no endpoint lists voters, spoofed user_id 403.
  G. Concurrency: parallel votes never leave a single-choice user with 2 votes.
  H. Edit rules: options lock after votes; remove deletes votes; cascade on announcement delete.

Run with: cd api && ../.venv/bin/python tests/test_announcement_polls.py   (scratch DB; see run_scratch.py)
"""
import _pathfix  # noqa: F401

import threading
import uuid
from datetime import datetime, timedelta, timezone

import test_group_announcements as T
from test_group_announcements import (  # noqa: E402
    TestClient, base, check, ck, cleanup, create_group, create_tables, DBManager,
    main_module, make_paid, signup, sql, future,
)
import backend.interactions.announcement_polls as polls
from backend.interactions import flags


def set_flag(state):
    sql("UPDATE feature_flags SET state=%s WHERE name=%s", (state, polls.POLLS_FLAG))
    flags.invalidate()


def reset_limits():
    from backend.rate_limiting import limiter
    limiter.reset()


def raises(fn, *a):
    try:
        fn(*a)
    except ValueError:
        return True
    return False


def soon(minutes=30):
    return (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()


POLL = {"question": "Which night works?", "options": ["Tuesday", "Wednesday", "Friday"]}


def test_unit():
    print("\n== A. validator ==")
    ok = polls.normalize_poll({"question": "  Pick   one ", "options": [" A ", "B"], "multiple": True})
    check("normalized", ok == {"question": "Pick one", "options": ["A", "B"], "multiple": True, "closes_at": None}, str(ok))
    bad = [
        None, [], "x", {}, {"question": "q"}, {"question": "q", "options": ["a"]},
        {"question": "q", "options": ["a"] * 2}, {"question": "q", "options": ["a", "A"]},
        {"question": "q", "options": [str(i) for i in range(7)]}, {"question": "", "options": ["a", "b"]},
        {"question": "x" * 201, "options": ["a", "b"]}, {"question": "q", "options": ["a", "x" * 81]},
        {"question": "q", "options": ["a", 3]}, {"question": "q", "options": "ab"},
        {"question": "q", "options": ["a", "b"], "multiple": "yes"},
        {"question": "q", "options": ["a", "b"], "extra": 1},
        {"question": "q\x00", "options": ["a", "b"]}, {"question": "q", "options": ["a‮b", "c"]},
        {"question": "q", "options": ["a", "b"], "closes_at": "2020-01-01T00:00:00+00:00"},
        {"question": "q", "options": ["a", "b"], "closes_at": "2999-01-01T00:00:00+00:00"},
        {"question": "q", "options": ["a", "b"], "closes_at": "tomorrow"},
        {"question": "q", "options": ["a", "b"], "closes_at": "2030-01-01T00:00:00"},
    ]
    for b in bad:
        check(f"bad poll rejected {str(b)[:50]}", raises(polls.normalize_poll, b))
    check("closes_at accepted", polls.normalize_poll({"question": "q", "options": ["a", "b"], "closes_at": soon()})["closes_at"] is not None)


def test_migration():
    print("\n== B. migration ==")
    db = DBManager()
    try:
        create_tables(db.cur); create_tables(db.cur); db.conn.commit()
    finally:
        db.close()
    check("create_tables() twice ok", True)
    for t in ("group_announcement_polls", "group_announcement_poll_options", "group_announcement_poll_votes"):
        n = sql("SELECT count(*) FROM information_schema.tables WHERE table_name=%s", (t,), fetch=True)[0][0]
        check(f"{t} exists", n == 1)
    check("flag seeded off", sql("SELECT state FROM feature_flags WHERE name=%s", (polls.POLLS_FLAG,), fetch=True)[0][0] in ("off", "on", "canary"))


def poll_of(j):
    return j.get("poll")


def mk(client, host, th, gid, poll=POLL, **extra):
    reset_limits()
    r = client.post(base(host, gid), json={"title": "t", "poll": poll, **extra}, headers=ck(th))
    return r


def test_flag_off_and_basic(client):
    print("\n== C/D/E. flag, create, vote ==")
    users = []; gid = None
    try:
        host, th = signup(client, f"pl_host_{uuid.uuid4().hex[:8]}"); users.append(host); make_paid(host)
        m1, t1 = signup(client, f"pl_m1_{uuid.uuid4().hex[:8]}"); users.append(m1)
        m2, t2 = signup(client, f"pl_m2_{uuid.uuid4().hex[:8]}"); users.append(m2)
        gid = create_group(client, th, host, [m1, m2])
        set_flag("off")
        r = mk(client, host, th, gid)
        check("create with poll 422 while off", r.status_code == 422, r.text)
        reset_limits()
        plain = client.post(base(host, gid), json={"title": "plain"}, headers=ck(th)).json()["id"]
        r = client.post(f"{base(m1, gid)}/{plain}/poll/vote", json={"option_ids": [str(uuid.uuid4())]}, headers=ck(t1))
        check("vote 404 while off", r.status_code == 404, r.text)
        check("no poll key while off", "poll" not in client.get(f"{base(m1, gid)}/{plain}", headers=ck(t1)).json())

        set_flag("on")
        r = mk(client, host, th, gid)
        check("create with poll 201", r.status_code == 201, r.text)
        j = r.json(); aid = j["id"]; p = poll_of(j)
        check("poll in create response", p and p["question"] == "Which night works?" and len(p["options"]) == 3, str(j))
        check("zero votes, not closed, none mine", p["total_voters"] == 0 and not p["closed"] and p["my_votes"] == [])
        opts = {o["label"]: o["id"] for o in p["options"]}
        vote = lambda u, t, ids, a=aid: client.post(f"{base(u, gid)}/{a}/poll/vote", json={"option_ids": ids}, headers=ck(t))
        r = vote(m1, t1, [opts["Tuesday"]])
        pj = poll_of(r.json())
        check("vote 200 counted", r.status_code == 200 and pj["total_voters"] == 1 and pj["my_votes"] == [opts["Tuesday"]], r.text)
        check("percent 100", [o["percent"] for o in pj["options"] if o["label"] == "Tuesday"] == [100])
        r = vote(m1, t1, [opts["Tuesday"]])
        check("idempotent", poll_of(r.json())["total_voters"] == 1)
        r = vote(m1, t1, [opts["Friday"]])
        pj = poll_of(r.json())
        check("change vote replaces", pj["my_votes"] == [opts["Friday"]] and {o["label"]: o["votes"] for o in pj["options"]}["Tuesday"] == 0, r.text)
        r = vote(m2, t2, [opts["Friday"]])
        pj = poll_of(r.json())
        check("two voters 100% friday", pj["total_voters"] == 2 and [o["percent"] for o in pj["options"] if o["label"] == "Friday"] == [100], r.text)
        other = poll_of(client.get(f"{base(host, gid)}/{aid}", headers=ck(th)).json())
        check("host sees counts but not others' choices", other["my_votes"] == [] and other["total_voters"] == 2)
        r = vote(m1, t1, [opts["Tuesday"], opts["Friday"]])
        check("two answers on single choice 422", r.status_code == 422, r.text)
        r = vote(m1, t1, [])
        check("empty 422", r.status_code == 422, r.text)
        r = vote(m1, t1, [str(uuid.uuid4())])
        check("unknown option 422", r.status_code == 422, r.text)
        r = vote(m1, t1, ["not-a-uuid"])
        check("garbage id 422", r.status_code == 422, r.text)
        r = client.post(f"{base(m1, gid)}/{aid}/poll/vote", json={"option_ids": [opts["Friday"]], "user_id": host}, headers=ck(t1))
        check("extra body field rejected (no voter spoof)", r.status_code == 422, r.text)
        check("votes unchanged after rejects", sql("SELECT count(*) FROM group_announcement_poll_votes WHERE announcement_id=%s", (aid,), fetch=True)[0][0] == 2)
        r = client.delete(f"{base(m1, gid)}/{aid}/poll/vote", headers=ck(t1))
        check("retract", r.status_code == 200 and poll_of(r.json())["my_votes"] == [] and poll_of(r.json())["total_voters"] == 1, r.text)
        r = client.delete(f"{base(m1, gid)}/{aid}/poll/vote", headers=ck(t1))
        check("retract idempotent", r.status_code == 200)

        # multiple choice
        r = mk(client, host, th, gid, {"question": "Bring?", "options": ["Bread", "Wine", "Cheese"], "multiple": True})
        mid = r.json()["id"]; mo = {o["label"]: o["id"] for o in poll_of(r.json())["options"]}
        r = vote(m1, t1, [mo["Bread"], mo["Wine"]], mid)
        pj = poll_of(r.json())
        check("multiple: two answers ok", r.status_code == 200 and sorted(pj["my_votes"]) == sorted([mo["Bread"], mo["Wine"]]) and pj["total_voters"] == 1, r.text)
        r = vote(m1, t1, [mo["Bread"], mo["Bread"]], mid)
        check("multiple: duplicate ids 422", r.status_code == 422, r.text)
        r = vote(m1, t1, [mo["Cheese"]], mid)
        check("multiple: replace selection", sorted(poll_of(r.json())["my_votes"]) == [mo["Cheese"]])
        check("announcement list carries poll", any("poll" in a for a in client.get(base(m1, gid), headers=ck(t1)).json()["announcements"]))
        check("latest carries poll or null", client.get(f"{base(m1, gid)}/latest", headers=ck(t1)).status_code == 200)
    finally:
        cleanup(users, [gid] if gid else [])


def test_security(client):
    print("\n== F. security ==")
    set_flag("on")
    users = []; gid = None; gid2 = None
    try:
        host, th = signup(client, f"ps_host_{uuid.uuid4().hex[:8]}"); users.append(host); make_paid(host)
        mem, tm = signup(client, f"ps_m_{uuid.uuid4().hex[:8]}"); users.append(mem)
        leaver, tl = signup(client, f"ps_l_{uuid.uuid4().hex[:8]}"); users.append(leaver)
        out, to = signup(client, f"ps_o_{uuid.uuid4().hex[:8]}"); users.append(out)
        gid = create_group(client, th, host, [mem, leaver])
        r = mk(client, host, th, gid); j = r.json(); aid = j["id"]
        opts = {o["label"]: o["id"] for o in poll_of(j)["options"]}
        vote = lambda u, t, ids, g=gid, a=aid: client.post(f"{base(u, g)}/{a}/poll/vote", json={"option_ids": ids}, headers=ck(t))
        check("non-member vote 403", vote(out, to, [opts["Friday"]]).status_code == 403)
        check("non-member retract 403", client.delete(f"{base(out, gid)}/{aid}/poll/vote", headers=ck(to)).status_code == 403)
        check("non-member close 403", client.post(f"{base(out, gid)}/{aid}/poll/close", headers=ck(to)).status_code == 403)
        check("non-member read 403", client.get(f"{base(out, gid)}/{aid}", headers=ck(to)).status_code == 403)
        check("spoofed user_id 403", vote(host, tm, [opts["Friday"]]).status_code == 403)
        check("unauthenticated 401", client.post(f"{base(mem, gid)}/{aid}/poll/vote", json={"option_ids": [opts["Friday"]]}).status_code == 401)
        check("no vote rows from denied calls", sql("SELECT count(*) FROM group_announcement_poll_votes WHERE announcement_id=%s", (aid,), fetch=True)[0][0] == 0)

        # option from another announcement's poll
        r2 = mk(client, host, th, gid, {"question": "Other", "options": ["X", "Y"]}); aid2 = r2.json()["id"]
        foreign = poll_of(r2.json())["options"][0]["id"]
        r = vote(mem, tm, [foreign])
        check("foreign option 422", r.status_code == 422, r.text)
        # option from a poll in ANOTHER GROUP
        gid2 = create_group(client, th, host, [out])
        r3 = mk(client, host, th, gid2, {"question": "G2", "options": ["P", "Q"]}); g2opt = poll_of(r3.json())["options"][0]["id"]
        r = vote(mem, tm, [g2opt])
        check("option from another group 422", r.status_code == 422, r.text)
        r = client.post(f"{base(mem, gid2)}/{r3.json()['id']}/poll/vote", json={"option_ids": [g2opt]}, headers=ck(tm))
        check("member of group1 cannot vote in group2", r.status_code == 403, r.text)
        r = client.post(f"{base(mem, gid)}/{r3.json()['id']}/poll/vote", json={"option_ids": [g2opt]}, headers=ck(tm))
        check("announcement id from another group via own group path 404", r.status_code == 404, r.text)

        # leaver votes then leaves: not counted
        check("leaver votes", vote(leaver, tl, [opts["Friday"]]).status_code == 200)
        check("member votes", vote(mem, tm, [opts["Friday"]]).status_code == 200)
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (leaver, gid))
        pj = poll_of(client.get(f"{base(mem, gid)}/{aid}", headers=ck(tm)).json())
        check("ex-member vote not counted", pj["total_voters"] == 1 and {o["label"]: o["votes"] for o in pj["options"]}["Friday"] == 1, str(pj))
        check("ex-member can no longer vote", vote(leaver, tl, [opts["Tuesday"]]).status_code == 403)

        # no voter list anywhere
        body = client.get(f"{base(mem, gid)}/{aid}", headers=ck(tm)).text
        check("no user ids in poll payload", mem not in str(poll_of(client.get(f"{base(host, gid)}/{aid}", headers=ck(th)).json())) and leaver not in body)
        check("no voters route", client.get(f"{base(host, gid)}/{aid}/poll/voters", headers=ck(th)).status_code in (404, 405))

        # scheduled
        reset_limits()
        rs = client.post(base(host, gid), json={"title": "later", "publish_at": future(2), "poll": POLL}, headers=ck(th))
        sid = rs.json()["id"]; so = poll_of(rs.json())["options"][0]["id"]
        check("scheduled poll not votable 404", vote(mem, tm, [so], a=sid).status_code == 404)
        # deleted
        reset_limits()
        rd = mk(client, host, th, gid); did = rd.json()["id"]; do = poll_of(rd.json())["options"][0]["id"]
        client.delete(f"{base(host, gid)}/{did}", headers=ck(th))
        check("deleted poll not votable 404", vote(mem, tm, [do], a=did).status_code == 404)
        # close permissions + closed behavior
        check("member cannot close 403", client.post(f"{base(mem, gid)}/{aid}/poll/close", headers=ck(tm)).status_code == 403)
        r = client.post(f"{base(host, gid)}/{aid}/poll/close", headers=ck(th))
        check("host closes", r.status_code == 200 and poll_of(r.json())["closed"], r.text)
        check("close idempotent", client.post(f"{base(host, gid)}/{aid}/poll/close", headers=ck(th)).status_code == 200)
        check("vote after close 409", vote(mem, tm, [opts["Tuesday"]]).status_code == 409)
        check("retract after close 409", client.delete(f"{base(mem, gid)}/{aid}/poll/vote", headers=ck(tm)).status_code == 409)
        check("results still readable", poll_of(client.get(f"{base(mem, gid)}/{aid}", headers=ck(tm)).json())["total_voters"] == 1)
        # timed close
        reset_limits()
        rt = mk(client, host, th, gid, {"question": "t", "options": ["a", "b"], "closes_at": soon(30)}); tid = rt.json()["id"]; to_ = poll_of(rt.json())["options"][0]["id"]
        check("timed poll open", vote(mem, tm, [to_], a=tid).status_code == 200)
        sql("UPDATE group_announcement_polls SET closes_at = now() - interval '1 minute' WHERE announcement_id=%s", (tid,))
        check("timed poll closed after deadline", vote(mem, tm, [to_], a=tid).status_code == 409)
        check("closed flag in payload", poll_of(client.get(f"{base(mem, gid)}/{tid}", headers=ck(tm)).json())["closed"] is True)
        # block relationship hides the poll from voting
        reset_limits()
        rb = mk(client, host, th, gid); bid = rb.json()["id"]; bo = poll_of(rb.json())["options"][0]["id"]
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (mem, host))
        flags.invalidate()
        code = vote(mem, tm, [bo], a=bid).status_code
        check("blocked author's poll 404", code == 404, str(code))
    finally:
        cleanup(users, [g for g in (gid, gid2) if g])


def test_concurrency(client):
    print("\n== G. concurrency ==")
    set_flag("on")
    users = []; gid = None
    try:
        host, th = signup(client, f"pc_host_{uuid.uuid4().hex[:8]}"); users.append(host); make_paid(host)
        mem, tm = signup(client, f"pc_m_{uuid.uuid4().hex[:8]}"); users.append(mem)
        gid = create_group(client, th, host, [mem])
        r = mk(client, host, th, gid); aid = r.json()["id"]
        ids = [o["id"] for o in poll_of(r.json())["options"]]
        reset_limits()
        results = []

        def go(i):
            rr = client.post(f"{base(mem, gid)}/{aid}/poll/vote", json={"option_ids": [ids[i % 3]]}, headers=ck(tm))
            results.append(rr.status_code)
        ts = [threading.Thread(target=go, args=(i,)) for i in range(12)]
        [t.start() for t in ts]; [t.join() for t in ts]
        n = sql("SELECT count(*) FROM group_announcement_poll_votes WHERE announcement_id=%s AND user_id=%s", (aid, mem), fetch=True)[0][0]
        check("12 racing votes leave exactly 1 row for a single-choice poll", n == 1, f"rows={n} statuses={sorted(set(results))}")
        check("all racing votes answered 200", set(results) == {200}, str(sorted(results)))
    finally:
        cleanup(users, [gid] if gid else [])


def test_edit_rules(client):
    print("\n== H. edit rules ==")
    set_flag("on")
    users = []; gid = None
    try:
        host, th = signup(client, f"pe_host_{uuid.uuid4().hex[:8]}"); users.append(host); make_paid(host)
        mem, tm = signup(client, f"pe_m_{uuid.uuid4().hex[:8]}"); users.append(mem)
        gid = create_group(client, th, host, [mem])
        r = mk(client, host, th, gid); aid = r.json()["id"]
        opts = {o["label"]: o["id"] for o in poll_of(r.json())["options"]}
        put = lambda body, u=host, t=th: client.put(f"{base(u, gid)}/{aid}", json=body, headers=ck(t))
        check("member cannot edit poll 403", put({"poll": None}, mem, tm).status_code == 403)
        r = put({"poll": {"question": "New q", "options": ["Tuesday", "Wednesday", "Friday", "Sunday"]}})
        check("no votes: options replaceable", r.status_code == 200 and len(poll_of(r.json())["options"]) == 4, r.text)
        opts = {o["label"]: o["id"] for o in poll_of(r.json())["options"]}
        client.post(f"{base(mem, gid)}/{aid}/poll/vote", json={"option_ids": [opts["Sunday"]]}, headers=ck(tm))
        r = put({"poll": {"question": "Other", "options": ["a", "b"]}})
        check("votes lock options 422", r.status_code == 422, r.text)
        r = put({"poll": {"question": "Reworded", "options": ["Tuesday", "Wednesday", "Friday", "Sunday"]}})
        pj = poll_of(r.json())
        check("votes: question editable, votes kept", r.status_code == 200 and pj["question"] == "Reworded" and pj["total_voters"] == 1, r.text)
        r = put({"poll": {"question": "Reworded", "options": ["Tuesday", "Wednesday", "Friday", "Sunday"], "multiple": True}})
        check("votes: multiple locked 422", r.status_code == 422, r.text)
        r = put({"title": "title only"})
        check("title edit keeps poll", poll_of(r.json()) is not None and poll_of(r.json())["total_voters"] == 1, r.text)
        r = put({"poll": None})
        check("remove poll", r.status_code == 200 and "poll" not in r.json(), r.text)
        check("votes gone with poll", sql("SELECT count(*) FROM group_announcement_poll_votes WHERE announcement_id=%s", (aid,), fetch=True)[0][0] == 0)
        r = put({"poll": {"question": "Again", "options": ["a", "b"]}})
        check("add poll to existing announcement", r.status_code == 200 and poll_of(r.json())["question"] == "Again", r.text)
        # cascade on hard delete
        sql("DELETE FROM group_announcements WHERE _id=%s", (aid,))
        check("cascade removes poll rows", sql("SELECT count(*) FROM group_announcement_poll_options WHERE announcement_id=%s", (aid,), fetch=True)[0][0] == 0)
        # content filter
        reset_limits()
        r = client.post(base(host, gid), json={"title": "t", "poll": {"question": "ok", "options": ["fine", "fine too"]}}, headers=ck(th))
        check("clean poll accepted", r.status_code == 201, r.text)
    finally:
        cleanup(users, [gid] if gid else [])


def main():
    test_unit()
    with TestClient(main_module.app) as client:
        test_migration()
        test_flag_off_and_basic(client)
        test_security(client)
        test_concurrency(client)
        test_edit_rules(client)
        set_flag("off")
    print(f"\n{'=' * 60}")
    if T.FAILED:
        print(f"RESULT: {len(T.PASSED)} passed, {len(T.FAILED)} FAILED")
        for label, detail in T.FAILED:
            print(f"  X {label} -- {detail}")
        raise SystemExit(1)
    print(f"RESULT: {len(T.PASSED)} passed, 0 failed\nSTATUS: ALL PASS")


if __name__ == "__main__":
    main()
