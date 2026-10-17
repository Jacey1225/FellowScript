"""Backend coverage for the in-chat "member joined" system line (task
20261016-push-notifications-and-ui, addendum G2).

Real routes, real notifier, real Postgres (scratch DB only: ``require_scratch_db``
asserts port 55432); only ``send_push`` is faked (capturing), so no APNs call is made.

  A. Written on all three add paths (member-list edit, invite redeem, join-request
     approval): one row per genuinely new member, from_user = joiner, system_kind
     'member_joined', sealed text opens to 'joined the group'; not on removals,
     title-only edits, group creation or a denied request.
  B. Hidden without include_system on every reader (legacy GET, paged GET,
     GET /messages), shown with it on all three (system_kind surfaced, text opens),
     a soft-deleted line stays hidden, a viewer who blocked the joiner never sees it.
  C. No side effects: no message_recipients rows, no chat push (the only push is the
     pre-existing essential member_joined one), the contact-list load (limit=1, no
     include_system) still returns the real last message and never the line.
  D. Dedupe: a repeat/concurrent call inside 10 minutes writes nothing; outside the
     window (leave + re-join) writes a new line; re-saving the same member list adds
     nothing; at most MAX_LINES_PER_CALL per call.
  E. Non-member / removed user / unknown user / unknown group / bad ids write nothing.
  F. Failure isolation: DB down, per-user insert failure and a recorder crash never
     raise, never fail the join (HTTP 200) and never suppress the member_joined push.

Run: cd api && python tests/test_member_joined_line.py
"""
import _pathfix  # noqa: F401

import asyncio
import json
import os
import threading
import uuid

os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

import _jrq_common as J  # noqa: E402
from _thr_common import (  # noqa: E402
    FAILED, GROUPS, PASSED, USERS, check, cookie, make_group, make_msg, make_user, sql,
)
from backend import content_store  # noqa: E402
from backend.interactions import flags  # noqa: E402
import backend.interactions.invites_config as ic  # noqa: E402
import backend.interactions.member_joined_line as mjl  # noqa: E402
import backend.interactions.member_joined_notifier as mjn  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402

SENT: list[dict] = []


async def fake_send_push(token, title, body, data=None):
    SENT.append({"token": token, "title": title, "body": body, "data": data})
    return True


def token_for(uid):
    tok = f"tok-{uid}"
    sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) "
        "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token", (uid, tok))
    return tok


def lines(gid, uid=None):
    q = "SELECT _id::text, from_user::text, text FROM messages WHERE group_id=%s AND system_kind='member_joined'"
    p = [gid]
    if uid:
        q += " AND from_user=%s"
        p.append(uid)
    return sql(q, p)


def opened(row):
    return content_store.open_(row[0], content_store.F_MESSAGE_TEXT, row[2])


def actions():
    return [s["data"].get("action") for s in SENT]


def put_members(cli, owner, gid, users, title="G2 Group"):
    limiter.reset()
    return cli.put(f"/groups/{owner}/{gid}", json={"group_id": gid, "title": title, "users": users},
                   headers=cookie(owner))


def legacy_rows(body):
    return list(body.get("host_msgs") or []) + list(body.get("other_msgs") or [])


def read_legacy(cli, viewer, gid, include=False):
    limiter.reset()
    r = cli.get(f"/groups/{viewer}/{gid}" + ("?include_system=1" if include else ""), headers=cookie(viewer))
    assert r.status_code == 200, r.text
    return legacy_rows(r.json())


def read_paged(cli, viewer, gid, include=False, limit=100):
    limiter.reset()
    q = f"?limit={limit}" + ("&include_system=1" if include else "")
    r = cli.get(f"/groups/{viewer}/{gid}{q}", headers=cookie(viewer))
    assert r.status_code == 200, r.text
    return r.json()["messages"]


def read_page_route(cli, viewer, gid, include=False):
    limiter.reset()
    r = cli.get(f"/groups/{viewer}/{gid}/messages" + ("?include_system=1" if include else ""), headers=cookie(viewer))
    assert r.status_code == 200, r.text
    return r.json()["messages"]


def kinds(rows):
    return [m.get("system_kind") for m in rows if m.get("system_kind")]


# ------------------------------------------------------------------ A. add paths

def test_add_paths(cli):
    print("A. line written on every add path")
    owner, m1, n1, n2 = make_user("g2_o"), make_user("g2_m"), make_user("g2_n1"), make_user("g2_n2")
    for u in (owner, m1, n1, n2):
        token_for(u)
    gid = make_group([owner, m1], creator=owner)
    sql("UPDATE groups SET title='G2 Group' WHERE _id=%s", (gid,))
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s),(%s,%s),(%s,%s) ON CONFLICT DO NOTHING",
        (owner, n1, n1, owner, owner, n2, n2, owner))

    check("group creation (seed members) wrote no line", lines(gid) == [])
    SENT.clear()
    r = put_members(cli, owner, gid, [owner, m1, n1])
    check("member-list edit: 200", r.status_code == 200, r.text)
    got = lines(gid, n1)
    check("member-list edit wrote exactly one line for the new member", len(got) == 1 and len(lines(gid)) == 1, lines(gid))
    check("line author is the joiner (from_user) and the sealed text opens to 'joined the group'",
          got and got[0][1] == n1 and opened(got[0]) == "joined the group", got)
    check("the essential member_joined push still fires (once per existing member)",
          sorted(s["token"] for s in SENT) == sorted([f"tok-{owner}", f"tok-{m1}"]) and set(actions()) == {"member_joined"}, SENT)

    r = put_members(cli, owner, gid, [owner, m1, n1], title="Renamed")
    check("title-only edit (no new member) wrote nothing", r.status_code == 200 and len(lines(gid)) == 1, lines(gid))
    r = put_members(cli, owner, gid, [owner, m1])
    check("removing a member wrote nothing", r.status_code == 200 and len(lines(gid)) == 1, lines(gid))
    r = put_members(cli, owner, gid, [owner, m1, n1, n2])
    check("adding two at once (one is a re-add of n1 inside the window): only n2 is new -> one more line, n1 not duplicated",
          r.status_code == 200 and len(lines(gid, n1)) == 1 and len(lines(gid, n2)) == 1, lines(gid))

    # group creation through the route is not a join
    limiter.reset()
    gnew = str(uuid.uuid4())
    GROUPS.append(gnew)
    r = cli.post(f"/groups/{owner}", json={"group_id": gnew, "title": "Brand New", "users": [owner, m1]}, headers=cookie(owner))
    check("creating a group through the route wrote no line", r.status_code == 201 and lines(gnew) == [], (r.status_code, lines(gnew)))

    # invite redeem
    raw = json.loads(open(ic.CONFIG_PATH).read())
    raw["enabled"] = True
    ic.set_invites_config_for_tests(ic.parse_invites_config(raw))
    try:
        io, im, ij, ij2 = make_user("g2_io"), make_user("g2_im"), make_user("g2_ij"), make_user("g2_ij2")
        for u in (io, im, ij, ij2):
            token_for(u)
        ig = make_group([io, im], creator=io)
        sql("UPDATE groups SET title = 'Invite Group' WHERE _id = %s", (ig,))
        limiter.reset()
        r = cli.post(f"/invites/{io}/groups/{ig}", headers=cookie(io))
        check("invite link created", r.status_code in (200, 201), r.text)
        link = r.json().get("token") or r.json().get("link", "")
        limiter.reset()
        r = cli.post(f"/invites/{ij}/redeem", json={"token": link}, headers=cookie(ij))
        check("redeem joins", r.status_code == 200 and r.json().get("joined") is True, r.text)
        check("invite redeem wrote one line for the redeemer", len(lines(ig, ij)) == 1 and len(lines(ig)) == 1, lines(ig))
        limiter.reset()
        r = cli.post(f"/invites/{ij}/redeem", json={"token": link}, headers=cookie(ij))
        check("second redeem by the existing member (already_member): still one line",
              r.status_code == 200 and len(lines(ig)) == 1, lines(ig))
        limiter.reset()
        r = cli.post(f"/invites/{io}/redeem", json={"token": link}, headers=cookie(io))
        check("creator redeeming own link: no line for the creator", r.status_code == 200 and len(lines(ig, io)) == 0, lines(ig))
        SENT.clear()
        limiter.reset()
        r = cli.post(f"/invites/{ij2}/redeem", json={"token": link}, headers=cookie(ij2))
        check("a second newcomer gets their own line", r.status_code == 200 and len(lines(ig, ij2)) == 1, lines(ig))
    finally:
        ic.set_invites_config_for_tests(None)

    # join-request approval
    jo, ja, je = make_user("g2_jo"), make_user("g2_ja"), make_user("g2_je")
    for u in (jo, ja, je):
        token_for(u)
    J.set_flags(jo, push="on")
    jgid, pid = J.make_listing(jo, members=[je], title="Approval Group")
    limiter.reset()
    rid = J.req(cli, ja, pid).json()["id"]
    check("pending request wrote no line yet", lines(jgid) == [])
    r = J.decide(cli, jo, jgid, rid, "approve")
    check("approve ok", r.status_code == 200, r.text)
    check("approval wrote one line for the applicant", len(lines(jgid, ja)) == 1 and len(lines(jgid)) == 1, lines(jgid))
    ja2 = make_user("g2_ja2")
    limiter.reset()
    rid2 = J.req(cli, ja2, pid).json()["id"]
    r = J.decide(cli, jo, jgid, rid2, "deny")
    check("denied request wrote no line", r.status_code == 200 and len(lines(jgid, ja2)) == 0 and len(lines(jgid)) == 1, lines(jgid))


# ------------------------------------------------------------------ B/C. readers + no side effects

def test_visibility_and_side_effects(cli):
    print("B/C. hidden by default, shown on opt-in, no side effects")
    flags.set_flag("chat_pagination", "on", actor=USERS[0] if USERS else "test")
    flags.invalidate()
    owner, m1, joiner = make_user("g2v_o"), make_user("g2v_m"), make_user("g2v_j")
    for u in (owner, m1, joiner):
        token_for(u)
    gid = make_group([owner, m1], creator=owner)
    sql("UPDATE groups SET title='G2 Vis' WHERE _id=%s", (gid,))
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s) ON CONFLICT DO NOTHING",
        (owner, joiner, joiner, owner))
    real = make_msg(m1, gid, text="real last message")
    sql("UPDATE messages SET timestamp = NOW() - INTERVAL '1 hour' WHERE _id=%s", (real,))
    SENT.clear()
    r = put_members(cli, owner, gid, [owner, m1, joiner], title="G2 Vis")
    check("join via member-list edit: 200", r.status_code == 200, r.text)
    line_id = lines(gid, joiner)[0][0]

    for who, label in ((owner, "owner"), (m1, "member"), (joiner, "joiner")):
        check(f"[{label}] legacy GET hides the line by default", kinds(read_legacy(cli, who, gid)) == [])
        check(f"[{label}] paged GET hides the line by default", kinds(read_paged(cli, who, gid)) == [])
        check(f"[{label}] GET /messages hides the line by default", kinds(read_page_route(cli, who, gid)) == [])
        lg = read_legacy(cli, who, gid, include=True)
        pg = read_paged(cli, who, gid, include=True)
        rt = read_page_route(cli, who, gid, include=True)
        check(f"[{label}] legacy GET with include_system shows exactly one member_joined row",
              kinds(lg) == ["member_joined"], lg)
        check(f"[{label}] paged GET with include_system shows exactly one member_joined row",
              kinds(pg) == ["member_joined"], pg)
        check(f"[{label}] GET /messages with include_system shows exactly one member_joined row",
              kinds(rt) == ["member_joined"], rt)
    pg = read_paged(cli, owner, gid, include=True)
    row = next(m for m in pg if m.get("system_kind"))
    check("paged row: id, joiner's username, text opens, mine false for a viewer who is not the joiner",
          row["id"] == line_id and row["text"] == "joined the group" and row["mine"] is False
          and row["from_user"] == sql("SELECT username FROM users WHERE _id=%s", (joiner,))[0][0], row)
    pgj = read_paged(cli, joiner, gid, include=True)
    check("paged row: mine is true for the joiner", next(m for m in pgj if m.get("system_kind"))["mine"] is True)
    check("the real message is never tagged system_kind",
          all(not m.get("system_kind") for m in pg if m["text"] == "real last message"))
    check("internal columns not leaked on the legacy row (seq/deleted_at/reply_to_id)",
          all(not ({"seq", "deleted_at", "deleted_by", "reply_to_id"} & set(m)) for m in read_legacy(cli, owner, gid, include=True)))

    # contact-list load: limit=1, no include_system -> real last message, never the line
    top = read_paged(cli, owner, gid, include=False, limit=1)
    check("contact-list load (limit=1, no include_system) returns the real last message, not the line",
          len(top) == 1 and top[0]["text"] == "real last message" and not top[0].get("system_kind"), top)

    # side effects
    check("no message_recipients row references the line (no unread)",
          sql("SELECT COUNT(*) FROM message_recipients WHERE message_id=%s", (line_id,))[0][0] == 0)
    check("no recipients written for any message of this group",
          sql("SELECT COUNT(*) FROM message_recipients WHERE message_id IN (SELECT _id FROM messages WHERE group_id=%s "
              "AND system_kind IS NOT NULL)", (gid,))[0][0] == 0)
    check("the only pushes are the pre-existing essential member_joined ones (no chat push for the line)",
          SENT and set(actions()) == {"member_joined"} and f"tok-{joiner}" not in {s["token"] for s in SENT}, SENT)
    SENT.clear()
    n = mjl.record_member_joined(gid, [joiner])  # dedupe path, plus direct call
    check("the recorder alone sends no push", n == 0 and SENT == [], (n, SENT))

    # soft-deleted line hidden even with opt-in
    sql("UPDATE messages SET deleted_at = NOW() WHERE _id=%s", (line_id,))
    check("soft-deleted line stays hidden even with include_system",
          kinds(read_paged(cli, owner, gid, include=True)) == [] and kinds(read_legacy(cli, owner, gid, include=True)) == [])
    sql("UPDATE messages SET deleted_at = NULL WHERE _id=%s", (line_id,))

    # block: viewer who blocked the joiner does not see the line
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (m1, joiner))
    check("a viewer who blocked the joiner does not see the line (paged)", kinds(read_paged(cli, m1, gid, include=True)) == [])
    check("a viewer who blocked the joiner does not see the line (legacy)", kinds(read_legacy(cli, m1, gid, include=True)) == [])
    check("an unrelated viewer still sees it", kinds(read_paged(cli, owner, gid, include=True)) == ["member_joined"])

    # non-member reader is rejected regardless of include_system
    outsider = make_user("g2v_x")
    limiter.reset()
    r = cli.get(f"/groups/{outsider}/{gid}?include_system=1", headers=cookie(outsider))
    check("non-member cannot read the group (403) even with include_system", r.status_code == 403, r.status_code)

    flags.set_flag("chat_pagination", "off", actor=owner)
    flags.invalidate()


# ------------------------------------------------------------------ D/E. dedupe + membership guard

def test_dedupe_and_guard():
    print("D/E. dedupe window and membership guard")
    a, b, c = make_user("g2d_a"), make_user("g2d_b"), make_user("g2d_c")
    gid = make_group([a, b], creator=a)
    check("first call writes one line", mjl.record_member_joined(gid, [b]) == 1 and len(lines(gid, b)) == 1)
    check("repeat call inside the window writes nothing", mjl.record_member_joined(gid, [b]) == 0 and len(lines(gid, b)) == 1)
    res = []
    ts = [threading.Thread(target=lambda: res.append(mjl.record_member_joined(gid, [b]))) for _ in range(6)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("six concurrent calls inside the window write nothing", sum(res) == 0 and len(lines(gid, b)) == 1, res)

    # fresh group: concurrent first calls write exactly one
    g2 = make_group([a, c], creator=a)
    res = []
    ts = [threading.Thread(target=lambda: res.append(mjl.record_member_joined(g2, [c]))) for _ in range(6)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("six concurrent first calls write exactly one line (advisory lock serializes)",
          sum(res) == 1 and len(lines(g2, c)) == 1, (res, lines(g2)))

    # 10-minute window: just inside vs just outside
    sql("UPDATE messages SET timestamp = NOW() - INTERVAL '9 minutes' WHERE group_id=%s AND system_kind='member_joined'", (gid,))
    check("line 9 minutes old still dedupes", mjl.record_member_joined(gid, [b]) == 0)
    sql("UPDATE messages SET timestamp = NOW() - INTERVAL '11 minutes' WHERE group_id=%s AND system_kind='member_joined'", (gid,))
    check("line 11 minutes old (leave then re-join) writes a new line",
          mjl.record_member_joined(gid, [b]) == 1 and len(lines(gid, b)) == 2)
    check("dedupe is per user: another member of the same group is independent",
          mjl.record_member_joined(gid, [a]) == 1 and len(lines(gid, a)) == 1)
    check("duplicate ids in one call collapse to one line", mjl.record_member_joined(g2, [a, a]) == 1 and len(lines(g2, a)) == 1)

    # cap
    members = [make_user("g2cap") for _ in range(mjl.MAX_LINES_PER_CALL + 5)]
    gcap = make_group(members, creator=members[0])
    check("at most MAX_LINES_PER_CALL lines per call",
          mjl.record_member_joined(gcap, members) == mjl.MAX_LINES_PER_CALL and len(lines(gcap)) == mjl.MAX_LINES_PER_CALL)

    # E. guard
    gx = make_group([a], creator=a)
    stranger = make_user("g2e_s")
    check("non-member writes nothing", mjl.record_member_joined(gx, [stranger]) == 0 and lines(gx) == [])
    gone = make_user("g2e_gone")
    gy = make_group([a, gone], creator=a)
    sql("UPDATE groups SET users = %s WHERE _id=%s", ([a], gy))
    check("removed user (no longer in groups.users) writes nothing", mjl.record_member_joined(gy, [gone]) == 0 and lines(gy) == [])
    check("unknown user id (valid uuid) writes nothing",
          mjl.record_member_joined(gx, [str(uuid.uuid4())]) == 0 and lines(gx) == [])
    ghost = str(uuid.uuid4())
    sql("UPDATE groups SET users = %s WHERE _id=%s", ([a, ghost], gx))
    check("id in groups.users but no users row writes nothing (INSERT...SELECT FROM users)",
          mjl.record_member_joined(gx, [ghost]) == 0 and lines(gx) == [])
    check("unknown group writes nothing", mjl.record_member_joined(str(uuid.uuid4()), [a]) == 0)
    check("bad ids / empty lists write nothing and never raise",
          mjl.record_member_joined("nope", [a]) == 0 and mjl.record_member_joined(gx, ["x", None, 5]) == 0
          and mjl.record_member_joined(gx, []) == 0 and mjl.record_member_joined(gx, None) == 0 and mjl.record_member_joined(None, None) == 0)
    check("case-insensitive uuids are accepted (upper-case input maps to the member)",
          mjl.record_member_joined(gx, [a.upper()]) == 1 and len(lines(gx, a)) == 1)


# ------------------------------------------------------------------ F. failure isolation

def test_failure_isolation(cli):
    print("F. failure isolation")
    owner, m1, joiner = make_user("g2f_o"), make_user("g2f_m"), make_user("g2f_j")
    for u in (owner, m1, joiner):
        token_for(u)
    gid = make_group([owner, m1], creator=owner)
    sql("UPDATE groups SET title='G2 Fail' WHERE _id=%s", (gid,))
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s) ON CONFLICT DO NOTHING",
        (owner, joiner, joiner, owner))

    # 1. DB unavailable inside the recorder
    orig_db = mjl.DBManager

    def boom():
        raise RuntimeError("db down")
    mjl.DBManager = boom
    try:
        check("recorder with the DB down returns 0 and does not raise", mjl.record_member_joined(gid, [joiner]) == 0)
    finally:
        mjl.DBManager = orig_db

    # 2. per-user insert failure (seal raises): rolled back, no row, no raise
    orig_seal = content_store.seal

    def bad_seal(*a, **k):
        raise RuntimeError("seal failed")
    content_store.seal = bad_seal
    try:
        sql("UPDATE groups SET users = %s WHERE _id=%s", ([owner, m1, joiner], gid))
        check("per-user insert failure is swallowed: returns 0, no row", mjl.record_member_joined(gid, [joiner]) == 0 and lines(gid) == [])
    finally:
        content_store.seal = orig_seal
    check("the recorder recovers on the next call (connection not poisoned)", mjl.record_member_joined(gid, [joiner]) == 1)
    sql("DELETE FROM messages WHERE group_id=%s AND system_kind='member_joined'", (gid,))
    sql("UPDATE groups SET users = %s WHERE _id=%s", ([owner, m1], gid))

    # 3. recorder crash inside the notifier does not suppress the push
    orig_rec = mjl.record_member_joined

    def crash(*a, **k):
        raise RuntimeError("recorder crashed")
    mjl.record_member_joined = crash
    try:
        SENT.clear()
        r = put_members(cli, owner, gid, [owner, m1, joiner], title="G2 Fail")
        check("a crashing recorder never fails the join (HTTP 200)", r.status_code == 200, r.text)
        check("...the member joined (membership persisted)",
              joiner in [str(u) for u in sql("SELECT users FROM groups WHERE _id=%s", (gid,))[0][0]])
        check("...and the member_joined push is still sent to existing members",
              sorted(s["token"] for s in SENT) == sorted([f"tok-{owner}", f"tok-{m1}"]) and set(actions()) == {"member_joined"}, SENT)
        check("...and no line was written", lines(gid) == [])
    finally:
        mjl.record_member_joined = orig_rec

    # 4. direct notifier call: recorder first, then push, both independent
    sql("UPDATE groups SET users = %s WHERE _id=%s", ([owner, m1, joiner], gid))
    SENT.clear()
    asyncio.run(mjn.notify_members_of_new_members(gid, [joiner]))
    check("notifier writes the line and sends the push in one background call",
          len(lines(gid, joiner)) == 1 and len(SENT) == 2, (lines(gid), SENT))

    # 5. line write works even when the push side fails
    sql("DELETE FROM messages WHERE group_id=%s AND system_kind='member_joined'", (gid,))

    async def raising_push(*a, **k):
        raise RuntimeError("apns down")
    push_module.send_push = raising_push
    try:
        asyncio.run(mjn.notify_members_of_new_members(gid, [joiner]))
        check("APNs failure does not stop the line", len(lines(gid, joiner)) == 1, lines(gid))
    finally:
        push_module.send_push = fake_send_push


def test_source_guards():
    print("G. wiring guards")
    import inspect
    src = inspect.getsource(mjn.notify_members_of_new_members)
    check("recorder is called before the push inside notify_members_of_new_members",
          src.index("record_member_joined") < src.index("_prepare"))
    check("recorder runs in an executor with its own try (blocking DB off the event loop)",
          "run_in_executor" in src.split("_prepare")[0] and "try:" in src.split("_prepare")[0])
    rsrc = inspect.getsource(mjl)
    check("recorder never touches the websocket send path or push",
          "send_push" not in rsrc and "message_recipients" not in rsrc.replace("message_recipients`` rows", ""))
    check("kind constant matches the shipped iOS pin system_kind column mechanism",
          mjl.SYSTEM_KIND == "member_joined" and mjl.SYSTEM_TEXT == "joined the group" and mjl.DEDUPE_WINDOW_SECONDS == 600)


def main():
    cli, _cap = J.start()
    push_module.send_push = fake_send_push
    import traceback
    try:
        for fn, args in ((test_add_paths, (cli,)), (test_visibility_and_side_effects, (cli,)),
                         (test_dedupe_and_guard, ()), (test_failure_isolation, (cli,)), (test_source_guards, ())):
            try:
                fn(*args)
            except Exception:  # noqa: BLE001 - an exception is a failure, never a silent pass
                FAILED.append((f"{fn.__name__} raised", traceback.format_exc()[-600:]))
                print(f"  FAIL {fn.__name__} raised\n{traceback.format_exc()}")
    finally:
        J.restore_cfg()
        for gid in GROUPS:
            try:
                sql("DELETE FROM group_join_requests WHERE group_id=%s", (gid,))
                sql("DELETE FROM group_listings WHERE group_id=%s", (gid,))
                sql("DELETE FROM invites WHERE target_id=%s", (gid,))
            except Exception:  # noqa: BLE001
                pass
        for u in USERS:
            try:
                sql("DELETE FROM group_join_requests WHERE user_id=%s", (u,))
                sql("DELETE FROM push_preferences WHERE user_id=%s", (u,))
            except Exception:  # noqa: BLE001
                pass
        try:
            from _thr_common import cleanup
            cleanup()
        except Exception:  # noqa: BLE001
            pass

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
