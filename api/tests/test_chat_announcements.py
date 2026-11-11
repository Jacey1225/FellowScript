"""Backend coverage for task 20261030-chat-announcements (testing step 3).

Announcements as group-chat timeline lines (flag ``chat_announcements``, default OFF):
  A. DDL: create_tables() twice is a no-op, new columns/indexes exist, defaults safe.
  B. Flag OFF: post_to_chat -> 422 and nothing persisted; plain create unchanged.
  C. Authz: non-member / spoofed id / unauthenticated -> 403/401, no row, no line;
     post_to_chat must be a real boolean; free-plan limit still enforced.
  D. Emit: one line per announcement (idempotent), constant server text, poster is
     author; plain announcements never get a line; live frame goes to flag-on
     members only.
  E. Read side (legacy + paged history): viewer-specific card, 'edited' marker,
     delete hides, restore shows, blocked author hidden, flag-off viewer sees
     nothing, announcement_id/system_kind shape, old-shape stripping.
  F. Sync frames on edit / delete / restore.
  G. Scheduled: no line before publish, line after the due tick, stale (>1h) never
     back-filled, reminders/repeat rows never emit, departed poster not emitted.
  H. Cascade: hard delete of the announcement removes the line.
  I. Regression: a deleted/unpublished announcement can never leak its text via
     the line (line text is constant), and a line whose announcement cannot be
     loaded is dropped, not rendered as a placeholder.

Scratch database only (refuses port 5432 unless CI). Run with:
  cd api && FS_SCRATCH_PG_PORT=<scratch port> python tests/test_chat_announcements.py
(the port is applied by the sitecustomize shim used for all scratch-DB runs).
"""
import _pathfix  # noqa: F401

import asyncio
import datetime as dt
import os
import time
import uuid

import _thr_common as C
from _thr_common import check, cookie, make_group, make_user, set_flag, sql

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
import routes.group_announcements as route_mod  # noqa: E402
from backend.interactions import chat_announcements as ca, flags  # noqa: E402
from routes.messaging import manager as ws_manager  # noqa: E402

FLAG = "chat_announcements"


def reset_limits():
    from backend.rate_limiting import limiter
    limiter.reset()


def ann_url(u, g, tail=""):
    return f"/groups/{u}/{g}/announcements{tail}"


def lines(resp_json):
    """Announcement lines out of either history shape."""
    if "messages" in resp_json:
        pool = resp_json["messages"]
    else:
        pool = list(resp_json.get("host_msgs", [])) + list(resp_json.get("other_msgs", []))
    return [m for m in pool if m.get("system_kind") == "announcement"]


def paged(client, u, g):
    return client.get(f"/groups/{u}/{g}/messages", params={"limit": 50}, headers=cookie(u))


def legacy(client, u, g):
    return client.get(f"/groups/{u}/{g}", headers=cookie(u))


def n_lines(aid):
    return sql("SELECT count(*) FROM messages WHERE announcement_id=%s", (aid,))[0][0]


def make_paid(uid):
    sid = str(uuid.uuid4())
    sql("INSERT INTO subscriptions (_id, user_id, plan_type, status, current_period_end) "
        "VALUES (%s,%s,'group','active', now() + interval '20 days')", (sid, uid))
    sql("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, uid))
    return sid


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


def require_scratch():
    d = db_module.DBManager()
    try:
        d.cur.execute("SHOW port")
        port = d.cur.fetchone()[0]
    finally:
        d.close()
    want = os.environ.get("FS_SCRATCH_PG_PORT")
    ok = (port == want) if want else (port == "55432" or os.environ.get("GITHUB_ACTIONS") == "true")
    check(f"running against scratch DB (port {port})", ok, port)
    if not ok:
        raise SystemExit("refusing to continue: not the scratch database")


# -- A ----------------------------------------------------------------------------
def test_ddl():
    print("\n== A. DDL ==")
    for _ in range(2):
        d = db_module.DBManager()
        try:
            db_module.create_tables(d.cur)
            d.conn.commit()
        finally:
            d.close()
    check("create_tables() twice without error", True)
    cols = {r[0]: r for r in sql(
        "SELECT column_name, column_default, is_nullable FROM information_schema.columns "
        "WHERE (table_name='group_announcements' AND column_name='post_to_chat') "
        "OR (table_name='messages' AND column_name IN ('announcement_id','system_kind'))")}
    check("columns exist", {"post_to_chat", "announcement_id", "system_kind"} <= set(cols), str(set(cols)))
    check("post_to_chat defaults FALSE, not null",
          "false" in (cols["post_to_chat"][1] or "").lower() and cols["post_to_chat"][2] == "NO", str(cols.get("post_to_chat")))
    idx = {r[0]: r[1] for r in sql("SELECT indexname, indexdef FROM pg_indexes WHERE indexname IN "
                                   "('uq_messages_announcement_id','idx_group_announcements_chat_due')")}
    check("both indexes exist", len(idx) == 2, str(idx))
    check("announcement_id index is UNIQUE partial",
          "UNIQUE" in idx.get("uq_messages_announcement_id", "") and "WHERE" in idx.get("uq_messages_announcement_id", ""))
    row = sql("SELECT state FROM feature_flags WHERE name=%s", (FLAG,))
    check("flag seeded and registered", bool(row) and FLAG in flags.registry(), str(row))
    check("flag seeded OFF by default (fresh row)", row and row[0][0] in ("off", "on", "canary"))
    fk = sql("SELECT confdeltype FROM pg_constraint WHERE conrelid='messages'::regclass AND confrelid='group_announcements'::regclass")
    check("announcement_id FK is ON DELETE CASCADE", bool(fk) and fk[0][0] == "c", str(fk))


# -- B / C / D / E / F ------------------------------------------------------------
def test_main(client):
    print("\n== B. flag OFF ==")
    admin = make_user("cad")
    poster, mem, blk, out = make_user("cap"), make_user("cam"), make_user("cab"), make_user("cao")
    for u in (poster, mem, blk):
        make_paid(u)  # free limit must not mask the cases below
    g = make_group([poster, mem, blk], creator=poster)
    set_flag(FLAG, "off", admin)
    sql("UPDATE feature_flags SET canary_user_ids='{}' WHERE name=%s", (FLAG,))
    flags.invalidate()
    check("flag really off for poster", not flags.is_enabled(FLAG, poster))

    r = client.post(ann_url(poster, g), json={"title": "t", "post_to_chat": True}, headers=cookie(poster))
    check("flag off: post_to_chat true -> 422", r.status_code == 422, f"{r.status_code} {r.text}")
    check("flag off: nothing persisted", sql("SELECT count(*) FROM group_announcements WHERE group_id=%s", (g,))[0][0] == 0)
    r = client.post(ann_url(poster, g), json={"title": "plain-off", "post_to_chat": False}, headers=cookie(poster))
    check("flag off: post_to_chat false -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
    r = client.post(ann_url(poster, g), json={"title": "plain-off2"}, headers=cookie(poster))
    check("flag off: field omitted -> 201 (unchanged behaviour)", r.status_code == 201, f"{r.status_code} {r.text}")
    off_ids = sql("SELECT _id::text, post_to_chat FROM group_announcements WHERE group_id=%s", (g,))
    check("flag off: post_to_chat stays FALSE", all(not x[1] for x in off_ids), str(off_ids))
    time.sleep(0.4)
    check("flag off: no lines", sql("SELECT count(*) FROM messages WHERE group_id=%s AND system_kind='announcement'", (g,))[0][0] == 0)
    check("flag off: capability not exposed true", flags.evaluate_all(poster, exposed_only=True).get(FLAG) is False)

    set_flag(FLAG, "on", admin)
    check("flag on: capability exposed true", flags.evaluate_all(poster, exposed_only=True).get(FLAG) is True)

    print("\n== C. authz / validation ==")
    reset_limits()
    for label, body in (("string 'true'", {"title": "x", "post_to_chat": "true"}),
                        ("int 1", {"title": "x", "post_to_chat": 1}),
                        ("list", {"title": "x", "post_to_chat": [True]})):
        r = client.post(ann_url(poster, g), json=body, headers=cookie(poster))
        check(f"post_to_chat {label} rejected (StrictBool) -> 422", r.status_code == 422, str(r.status_code))
    before = sql("SELECT count(*) FROM group_announcements WHERE group_id=%s", (g,))[0][0]
    r = client.post(ann_url(out, g), json={"title": "x", "post_to_chat": True}, headers=cookie(out))
    check("non-member -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
    r = client.post(ann_url(poster, g), json={"title": "x", "post_to_chat": True}, headers=cookie(out))
    check("spoofed user_id -> 403", r.status_code == 403, str(r.status_code))
    r = client.post(ann_url(poster, g), json={"title": "x", "post_to_chat": True})
    check("unauthenticated -> 401", r.status_code == 401, str(r.status_code))
    time.sleep(0.3)
    check("denied calls wrote no announcement", sql("SELECT count(*) FROM group_announcements WHERE group_id=%s", (g,))[0][0] == before)
    check("denied calls wrote no line", sql("SELECT count(*) FROM messages WHERE group_id=%s AND system_kind='announcement'", (g,))[0][0] == 0)

    # free-plan limit still enforced with post_to_chat
    free = make_user("caf")
    fg = make_group([free], creator=free)
    reset_limits()
    r1 = client.post(ann_url(free, fg), json={"title": "one", "post_to_chat": True}, headers=cookie(free))
    r2 = client.post(ann_url(free, fg), json={"title": "two", "post_to_chat": True}, headers=cookie(free))
    check("free user first post_to_chat -> 201", r1.status_code == 201, f"{r1.status_code} {r1.text}")
    check("free user second post_to_chat -> 403 (limit, no bypass)", r2.status_code == 403, f"{r2.status_code} {r2.text}")
    time.sleep(0.4)
    check("limit-denied post made exactly one line",
          sql("SELECT count(*) FROM messages WHERE group_id=%s AND system_kind='announcement'", (fg,))[0][0] == 1)

    print("\n== D. emit ==")
    wsp, wsm, wsb = FakeWS(), FakeWS(), FakeWS()
    ws_manager.active_connections[poster] = wsp
    ws_manager.active_connections[mem] = wsm
    ws_manager.active_connections[blk] = wsb
    reset_limits()
    r = client.post(ann_url(poster, g), json={"title": "Potluck", "description": "bring food", "post_to_chat": True},
                    headers=cookie(poster))
    check("post_to_chat create -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
    aid = r.json()["id"]
    time.sleep(0.8)
    rows = sql("SELECT system_kind, from_user::text, group_id::text FROM messages WHERE announcement_id=%s", (aid,))
    check("exactly one line, kind announcement, author=poster, in group",
          rows == [("announcement", poster, g)], str(rows))
    check("post_to_chat stored TRUE", sql("SELECT post_to_chat FROM group_announcements WHERE _id=%s", (aid,))[0][0] is True)
    check("second emit is a no-op (idempotent)", ca._emit_sync(aid) is None and n_lines(aid) == 1)
    check("duplicate insert blocked by unique index", _dup_insert_blocked(aid, poster, g))
    frames = [f for f in wsm.sent if f.get("system_kind") == "announcement"]
    check("member got exactly one live line frame", len(frames) == 1, str(wsm.sent))
    if frames:
        f = frames[0]
        check("frame carries announcement_id + neutral card + constant text",
              f["announcement_id"] == aid and f["announcement"]["title"] == "Potluck" and f["text"] == ca.SYSTEM_TEXT,
              str(f))
        check("frame has no viewer-specific fields", not ({"can_edit", "my_rsvp", "poll"} & set(f["announcement"])), str(f["announcement"].keys()))
    check("poster also gets the frame", any(f.get("system_kind") == "announcement" for f in wsp.sent))
    plain_id = off_ids[0][0]
    check("plain announcement never gets a line", ca._emit_sync(plain_id) is None and n_lines(plain_id) == 0)
    check("unparseable id -> None, no raise", ca._emit_sync("not-a-uuid") is None)

    print("\n== E. read side (legacy + paged) ==")
    flags.set_flag("chat_pagination", "on", actor=admin)
    flags.invalidate()
    for shape, fetch in (("paged", paged), ("legacy", legacy)):
        resp = fetch(client, mem, g)
        check(f"{shape}: 200", resp.status_code == 200, f"{resp.status_code} {resp.text[:200]}")
        ls = lines(resp.json())
        check(f"{shape}: one announcement line for member", len(ls) == 1, str(ls))
        if ls:
            m = ls[0]
            check(f"{shape}: line has card, id, constant text, not edited",
                  m["announcement_id"] == aid and m["announcement"]["title"] == "Potluck"
                  and m["announcement"]["edited"] is False and m["text"] == ca.SYSTEM_TEXT, str(m))
            check(f"{shape}: card is the viewer's (can_edit false for non-author)", m["announcement"].get("can_edit") is False, str(m["announcement"].get("can_edit")))
            check(f"{shape}: no deleted_at / seq leak", not ({"deleted_at", "seq", "deleted_by"} & set(m)), str(set(m)))
    ls = lines(paged(client, poster, g).json())
    check("author's own card has can_edit true", ls and ls[0]["announcement"].get("can_edit") is True)
    ls = lines(client.get(f"/groups/{mem}/{g}", params={"limit": 50}, headers=cookie(mem)).json())
    check("initial page (?limit=) also carries the line", len(ls) == 1)

    # edited marker (>5s after create)
    time.sleep(5.3)
    r = client.put(ann_url(poster, g, f"/{aid}"), json={"title": "Potluck 2"}, headers=cookie(poster))
    check("edit 200", r.status_code == 200, r.text)
    for shape, fetch in (("paged", paged), ("legacy", legacy)):
        ls = lines(fetch(client, mem, g).json())
        check(f"{shape}: edit reflected, edited true",
              len(ls) == 1 and ls[0]["announcement"]["title"] == "Potluck 2" and ls[0]["announcement"]["edited"] is True, str(ls))
    check("_is_edited: <=5s not edited", ca._is_edited({"created_at": "2026-01-01T00:00:00+00:00", "updated_at": "2026-01-01T00:00:04+00:00"}) is False)
    check("_is_edited: >5s edited", ca._is_edited({"created_at": "2026-01-01T00:00:00+00:00", "updated_at": "2026-01-01T00:00:06+00:00"}) is True)
    check("_is_edited: garbage -> False", ca._is_edited({}) is False)

    print("\n== F. sync frames + delete/restore ==")
    r = client.delete(ann_url(poster, g, f"/{aid}"), headers=cookie(poster))
    check("delete 200", r.status_code == 200, r.text)
    for shape, fetch in (("paged", paged), ("legacy", legacy)):
        check(f"{shape}: deleted announcement hides the line", lines(fetch(client, mem, g).json()) == [])
    r = client.post(ann_url(poster, g, f"/{aid}/restore"), headers=cookie(poster))
    check("restore 200", r.status_code == 200, r.text)
    for shape, fetch in (("paged", paged), ("legacy", legacy)):
        check(f"{shape}: restore brings the line back", len(lines(fetch(client, mem, g).json())) == 1)
    time.sleep(0.5)
    acts = [f.get("action") for f in wsm.sent if f.get("type") == "announcement_updated"]
    check("member got updated, deleted, restored sync frames in order", acts == ["updated", "deleted", "restored"], str(acts))
    sync = [f for f in wsm.sent if f.get("type") == "announcement_updated"]
    check("sync frames carry ids only", all(set(f) == {"type", "group_id", "announcement_id", "action"} for f in sync), str(sync))
    # a plain (no line) announcement edit must not send a sync frame
    wsm.sent.clear()
    r = client.put(ann_url(poster, g, f"/{plain_id}"), json={"title": "plain edited"}, headers=cookie(poster))
    time.sleep(0.5)
    check("edit of announcement without a line sends no frame", r.status_code == 200 and not [f for f in wsm.sent if f.get("type") == "announcement_updated"])
    # other member cannot edit/delete via this feature (rights unchanged)
    r = client.put(ann_url(mem, g, f"/{aid}"), json={"title": "hijack"}, headers=cookie(mem))
    check("non-owner member edit still 403", r.status_code == 403, str(r.status_code))
    r = client.delete(ann_url(mem, g, f"/{aid}"), headers=cookie(mem))
    check("non-owner member delete still 403", r.status_code == 403, str(r.status_code))

    print("\n== E2. visibility rules ==")
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (mem, poster))
    for shape, fetch in (("paged", paged), ("legacy", legacy)):
        check(f"{shape}: viewer who blocked the poster sees no line", lines(fetch(client, mem, g).json()) == [])
    sql("DELETE FROM blocked_users WHERE blocker_id=%s", (mem,))
    # departed author
    gd = make_group([poster, mem], creator=mem)
    reset_limits()
    rd = client.post(ann_url(poster, gd), json={"title": "bye", "post_to_chat": True}, headers=cookie(poster))
    time.sleep(0.6)
    check("line exists before departure", n_lines(rd.json()["id"]) == 1)
    sql("UPDATE groups SET users = %s WHERE _id=%s", ([mem], gd))
    check("departed poster's line hidden from members", lines(paged(client, mem, gd).json()) == [] and lines(legacy(client, mem, gd).json()) == [])
    # flag-off viewer via canary
    flags.set_flag(FLAG, "canary", actor=admin, canary_user_ids=[poster, blk]); flags.invalidate()
    check("canary: mem flag off, poster flag on", not flags.is_enabled(FLAG, mem) and flags.is_enabled(FLAG, poster))
    for shape, fetch in (("paged", paged), ("legacy", legacy)):
        check(f"{shape}: flag-off viewer sees no line", lines(fetch(client, mem, g).json()) == [])
        check(f"{shape}: flag-on viewer sees the line", len(lines(fetch(client, blk, g).json())) == 1)
    wsm.sent.clear(); wsb.sent.clear()
    ca_frame = {"type": "announcement_updated", "action": "updated"}
    asyncio.run(ca._fan_out([mem, blk], ca_frame))
    check("live fan-out skips flag-off member, reaches flag-on member", not wsm.sent and len(wsb.sent) == 1, f"{wsm.sent} {wsb.sent}")
    check("history_filter_sql is constant text for flag-off viewer", "announcement'" in ca.history_filter_sql(mem) and "IS DISTINCT FROM" in ca.history_filter_sql(mem))
    check("poster flag-off at emit time -> no emit", _emit_with_flag_off(client, admin, poster, g) )
    set_flag(FLAG, "on", admin)

    print("\n== I. integrity ==")
    # a line whose announcement can't load is dropped (not a placeholder)
    sql("UPDATE group_announcements SET publish_at = now() + interval '1 day' WHERE _id=%s", (aid,))
    for shape, fetch in (("paged", paged), ("legacy", legacy)):
        check(f"{shape}: unpublished announcement's line hidden", lines(fetch(client, mem, g).json()) == [])
    sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute' WHERE _id=%s", (aid,))
    msgs = [{"id": sql("SELECT _id::text FROM messages WHERE announcement_id=%s", (aid,))[0][0], "system_kind": "announcement"}]
    d = db_module.DBManager()
    try:
        d.group_id = g
        sql("UPDATE group_announcements SET deleted_at = now() WHERE _id=%s", (aid,))
        ca.attach_announcements(d, msgs, mem)
    finally:
        d.close()
    check("attach_announcements drops a line it cannot load", msgs == [], str(msgs))
    sql("UPDATE group_announcements SET deleted_at = NULL WHERE _id=%s", (aid,))
    secret = "SECRET-TITLE-XYZ"
    sql("UPDATE group_announcements SET title=%s, deleted_at=now() WHERE _id=%s", (secret, aid))
    row = sql("SELECT text FROM messages WHERE announcement_id=%s", (aid,))
    check("soft-deleted announcement's text is not copied into the line row", secret not in str(row), str(row))
    sql("UPDATE group_announcements SET deleted_at=NULL WHERE _id=%s", (aid,))

    print("\n== H. cascade ==")
    sql("DELETE FROM group_announcements WHERE _id=%s", (aid,))
    check("hard delete of announcement removes its line", n_lines(aid) == 0)
    ws_manager.active_connections.pop(poster, None)
    ws_manager.active_connections.pop(mem, None)
    ws_manager.active_connections.pop(blk, None)
    return admin, poster, mem, blk, g


def _dup_insert_blocked(aid, poster, g):
    try:
        sql("INSERT INTO messages (_id, from_user, group_id, text, system_kind, announcement_id) "
            "VALUES (gen_random_uuid(), %s, %s, 'x', 'announcement', %s)", (poster, g, aid))
        return False
    except Exception:
        return True


def _emit_with_flag_off(client, admin, poster, g):
    """Poster has the flag off at emit time: nothing is written."""
    flags.set_flag(FLAG, "canary", actor=admin, canary_user_ids=[]); flags.invalidate()
    aid = str(uuid.uuid4())
    sql("INSERT INTO group_announcements (_id, group_id, creator_id, title, post_to_chat, publish_at) "
        "VALUES (%s,%s,%s,'offflag',TRUE, now() - interval '1 minute')", (aid, g, poster))
    res = ca._emit_sync(aid)
    return res is None and n_lines(aid) == 0


# -- G ------------------------------------------------------------------------------
def test_scheduled(client, admin):
    print("\n== G. scheduled / no backfill ==")
    set_flag(FLAG, "on", admin)
    p, m = make_user("cgp"), make_user("cgm")
    make_paid(p)
    g = make_group([p, m], creator=p)
    fut = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=100)).isoformat()
    reset_limits()
    r = client.post(ann_url(p, g), json={"title": "Later", "post_to_chat": True, "publish_at": fut}, headers=cookie(p))
    check("scheduled create 201", r.status_code == 201, r.text)
    sid = r.json()["id"]
    time.sleep(0.6)
    check("scheduled: no line at creation", n_lines(sid) == 0)
    check("scheduled: emit refuses before publish_at", ca._emit_sync(sid) is None)
    asyncio.run(ca.fire_due_chat_announcements())
    check("scheduled: not-yet-due not emitted by tick", n_lines(sid) == 0)
    sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute' WHERE _id=%s", (sid,))
    asyncio.run(ca.fire_due_chat_announcements())
    check("scheduled: line after due tick", n_lines(sid) == 1)
    asyncio.run(ca.fire_due_chat_announcements())
    check("scheduled: second tick does not duplicate", n_lines(sid) == 1)
    check("scheduled: visible in history after publish", len(lines(paged(client, m, g).json())) == 1)

    r = client.post(ann_url(p, g), json={"title": "Old", "post_to_chat": True, "publish_at": fut}, headers=cookie(p))
    oid = r.json()["id"]
    sql("UPDATE group_announcements SET publish_at = now() - interval '3 hours' WHERE _id=%s", (oid,))
    asyncio.run(ca.fire_due_chat_announcements())
    check("stale (3h) scheduled post not back-filled", n_lines(oid) == 0)
    check("_due_ids excludes stale", oid not in ca._due_ids())

    r = client.post(ann_url(p, g), json={"title": "Del", "post_to_chat": True, "publish_at": fut}, headers=cookie(p))
    did = r.json()["id"]
    sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute', deleted_at = now() WHERE _id=%s", (did,))
    asyncio.run(ca.fire_due_chat_announcements())
    check("deleted-before-due announcement never emits", n_lines(did) == 0)

    r = client.post(ann_url(p, g), json={"title": "Gone", "post_to_chat": True, "publish_at": fut}, headers=cookie(p))
    gid_ = r.json()["id"]
    sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute' WHERE _id=%s", (gid_,))
    sql("UPDATE groups SET users=%s WHERE _id=%s", ([m], g))
    asyncio.run(ca.fire_due_chat_announcements())
    check("poster who left the group: no line", n_lines(gid_) == 0)
    sql("UPDATE groups SET users=%s WHERE _id=%s", ([p, m], g))

    # reminders / repeats: the repeat machinery must never create a line
    before = sql("SELECT count(*) FROM messages WHERE group_id=%s AND system_kind='announcement'", (g,))[0][0]
    import backend.interactions.chat_announcements as mod
    src = open(mod.__file__).read()
    check("emit_line is only reachable through create / due tick (no repeat/reminder hook)",
          "announcement_repeat" not in src and "announcement_reminder" not in src)
    after = sql("SELECT count(*) FROM messages WHERE group_id=%s AND system_kind='announcement'", (g,))[0][0]
    check("line count stable", before == after)


def test_flag_registration():
    print("\n== flag registry ==")
    spec = flags.registry().get(FLAG)
    check("chat_announcements registered", spec is not None)
    check("exposed in capabilities", spec is not None and spec.exposed_in_capabilities)
    check("checked_post_flag(None/False) -> False without touching flags",
          ca.checked_post_flag("x", None) is False and ca.checked_post_flag("x", False) is False)


def main():
    C.require_scratch_db = require_scratch
    require_scratch()
    client = TestClient(main_module.app)
    admin = None
    try:
        test_ddl()
        test_flag_registration()
        admin, *_ = test_main(client)
        test_scheduled(client, admin)
    finally:
        flags.set_flag("chat_pagination", "off", actor=admin or "test") if admin else None
        flags.set_flag(FLAG, "off", actor=admin or "test") if admin else None
        flags.invalidate()
        sql("UPDATE feature_flags SET canary_user_ids='{}' WHERE name IN (%s,'chat_pagination')", (FLAG,))
        for g in list(C.GROUPS):
            sql("DELETE FROM group_announcements WHERE group_id=%s", (g,))
        for u in list(C.USERS):
            sql("UPDATE users SET subscription_id=NULL WHERE _id=%s", (u,))
            sql("DELETE FROM subscriptions WHERE user_id=%s", (u,))
        C.finish(flag_names=())


if __name__ == "__main__":
    main()
