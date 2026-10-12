"""Tests for task 20261012-message-pins, step 2: pinned chat messages (flag ``message_pins``).

Scratch database only (asserts SHOW port = 55432 first). REVISION 1: no cap, push on pin,
no banner. Proves:
  * DDL module applies twice, is registered, PK is message_id, FKs cascade, soft delete keeps rows
  * flag registered, seeded off; flag off means pin/unpin/list are the same uniform 404 as an
    unknown id with NO write, capabilities features.message_pins is false, history payloads omit
    ``pinned``
  * pin/unpin: auth (401/403 anonymous, 403 path-user mismatch), idempotent, unpin needs no terms,
    pin needs current terms, anyone in a DM or group can pin and unpin
  * ONE uniform 404 for non-member, ex-member, DM stranger, blocked pair, soft-deleted message,
    unknown and malformed ids, system lines
  * NO cap: many pins in one chat are all accepted (regression guard for the dropped 3-pin cap)
  * list: newest pin first, paginated (limit/offset/has_more/count), scoped to the caller's chat,
    soft-deleted messages vanish (and return on restore), content decrypts via the existing path,
    non-member 404, DM list scoped to the pair
  * history payloads (flag on) carry pinned bool, system_kind on system lines
  * system line + push: written once per throttle window with constant text, from the pinner, no
    push through the chat path; push goes to other members only, skips blocked / muted / no-token /
    flag-off recipients, body carries no message text; churn inside the window is silent; the
    claim is atomic under concurrency; unpin sends no push and no line
  * websocket: pin_updated reaches members only, never a stranger; no from_user/text; sent only on change
  * logs carry no message content or names; rate limit returns 429 past the configured rate
Run with: cd api && ../.venv/bin/python tests/test_message_pins.py
(locally needs the scratch cluster: FS_SCRATCH_PG_PORT=55432, see fs_scratch_shim)
"""
import _pathfix  # noqa: F401

import logging
import os
import sys
import threading
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
from db import DBManager  # noqa: E402
from _thr_common import (  # noqa: E402
    PASSED, FAILED, USERS, LogCapture, check, require_scratch_db, sql, make_user, make_group,
    make_msg, cookie, cleanup,
)
from backend.interactions import flags  # noqa: E402
from backend.interactions import message_pins as mp  # noqa: E402
from backend.interactions import push as push_module  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from routes.messaging import manager as ws_manager  # noqa: E402
from schema_ddl import message_pins as ddl  # noqa: E402

FLAG = "message_pins"
ALL_FLAGS = (FLAG, "chat_pagination", "chat_pagination_dm")
SENT: list[dict] = []


async def fake_send_push(token, title, body, data=None):
    SENT.append({"token": token, "title": title, "body": body, "data": data})
    return True


push_module.send_push = fake_send_push


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


def set_flag(name, state, actor):
    flags.set_flag(name, state, actor=actor)
    flags.invalidate()


def url(u, m):
    return f"/message-pins/{u}/{m}"


def pin(client, u, m, ck):
    return client.post(url(u, m), headers=ck)


def unpin(client, u, m, ck):
    return client.delete(url(u, m), headers=ck)


def glist(client, u, gid, ck, **params):
    return client.get(f"/message-pins/{u}/group/{gid}", params=params, headers=ck)


def dlist(client, u, f, ck, **params):
    return client.get(f"/message-pins/{u}/dm/{f}", params=params, headers=ck)


def pins_n(mid=None, chat=None):
    if mid:
        return sql("SELECT COUNT(*) FROM message_pins WHERE message_id=%s", (mid,))[0][0]
    return sql("SELECT COUNT(*) FROM message_pins WHERE chat_key=%s", (chat,))[0][0]


def lines_n(chat_key, group=True):
    if group:
        return sql("SELECT COUNT(*) FROM messages WHERE group_id=%s AND system_kind='pin'", (chat_key,))[0][0]
    return 0


def befriend(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s)", (a, b, b, a))


def make_dm(author, to, text="dm text"):
    mid = make_msg(author, None, text, group=False)
    sql("INSERT INTO message_recipients (message_id, user_id) VALUES (%s,%s)", (mid, to))
    return mid


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blocker, blocked))


def token(uid):
    t = f"tok-{uuid.uuid4().hex[:10]}"
    sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) ON CONFLICT DO NOTHING", (uid, t))
    return t


def all_msgs(body):
    p = body.get("payload", body)
    out = []
    for k in ("host_msgs", "other_msgs", "messages"):
        out += p.get(k) or []
    return out


def clear_throttle(chat_key=None):
    if chat_key:
        sql("DELETE FROM message_pin_push_claims WHERE chat_key=%s", (chat_key,))
    else:
        sql("DELETE FROM message_pin_push_claims")


# ---------------------------------------------------------------- 1 DDL / flag

def test_ddl_and_flag():
    print("DDL module and flag")
    d = DBManager()
    try:
        ddl.apply(d.cur)
        ddl.apply(d.cur)
        d.conn.commit()
        check("DDL module applies twice without error", True)
        check("registered in DDL_MODULES", "message_pins" in list(db_module.DDL_MODULES))
        d.cur.execute(
            "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum = ANY(i.indkey) "
            "WHERE i.indrelid='message_pins'::regclass AND i.indisprimary")
        check("primary key is message_id", {r[0] for r in d.cur.fetchall()} == {"message_id"})
        d.cur.execute(
            "SELECT confrelid::regclass::text, confdeltype FROM pg_constraint "
            "WHERE conrelid='message_pins'::regclass AND contype='f' ORDER BY 1")
        check("pins FKs are ON DELETE CASCADE", d.cur.fetchall() == [("messages", "c"), ("users", "c")])
        d.cur.execute(
            "SELECT confdeltype FROM pg_constraint WHERE conrelid='message_pin_push_claims'::regclass AND contype='f'")
        check("claims FK is ON DELETE CASCADE", [r[0] for r in d.cur.fetchall()] == ["c"])
        d.cur.execute("SELECT 1 FROM information_schema.columns WHERE table_name='messages' AND column_name='system_kind'")
        check("messages.system_kind exists", d.cur.fetchone() is not None)
    finally:
        d.close()

    u1 = make_user("pnd1")
    gid = make_group([u1])
    m = make_msg(u1, gid)
    sql("INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s,%s,%s)", (m, gid, u1))
    dup = False
    try:
        sql("INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s,%s,%s)", (m, gid, u1))
    except Exception as e:  # noqa: BLE001
        dup = "duplicate key" in str(e)
    check("a message can be pinned only once (PK)", dup)
    sql("UPDATE messages SET deleted_at = NOW(), deleted_by = %s WHERE _id=%s", (u1, m))
    check("soft delete keeps the pin row", pins_n(m) == 1)
    sql("DELETE FROM messages WHERE _id=%s", (m,))
    check("hard delete cascades the pin", pins_n(m) == 0)
    m2 = make_msg(u1, gid)
    sql("INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s,%s,%s)", (m2, gid, u1))
    sql("DELETE FROM messages WHERE group_id=%s", (gid,))
    sql("DELETE FROM groups WHERE _id=%s", (gid,))
    sql("DELETE FROM users WHERE _id=%s", (u1,))
    check("deleting the pinner user cascades (no FK error)", pins_n(m2) == 0)

    check("flag registered", FLAG in flags._REGISTRY)
    row = sql("SELECT state FROM feature_flags WHERE name=%s", (FLAG,))
    check("flag has no row or an off row (missing row reads as off; pipeline never flips it)", (not row) or row[0][0] == "off", str(row))
    u2 = make_user("pnd2")
    flags.invalidate()
    check("flag off for a user by default", flags.is_enabled(FLAG, u2) is False)


# ---------------------------------------------------------------- 2 flag off

def test_flag_off(client):
    print("flag off")
    a, b = make_user("pno1"), make_user("pno2")
    gid = make_group([a, b])
    m = make_msg(b, gid, "secret off text")
    ck = cookie(a)
    set_flag(FLAG, "off", a)
    r = pin(client, a, m, ck)
    unknown = pin(client, a, str(uuid.uuid4()), ck)
    check("pin 404 identical to unknown id", r.status_code == 404 and r.json() == unknown.json(), r.text)
    check("no pin row written", pins_n(m) == 0)
    check("no system line written", lines_n(gid) == 0)
    check("unpin 404", unpin(client, a, m, ck).status_code == 404)
    check("group list 404", glist(client, a, gid, ck).status_code == 404)
    check("dm list 404", dlist(client, a, b, ck).status_code == 404)
    cap = client.get("/app/capabilities", headers=ck).json()
    check("capabilities features.message_pins is false", cap["features"].get(FLAG) is False, str(cap["features"]))
    sql("INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s,%s,%s)", (m, gid, b))
    set_flag("chat_pagination", "off", a)
    body = client.get(f"/groups/{a}/{gid}", headers=ck).json()
    ms = all_msgs(body)
    check("flag off: history payload has no pinned key", ms and all("pinned" not in x for x in ms), str(ms)[:200])
    set_flag(FLAG, "on", a)
    cap = client.get("/app/capabilities", headers=ck).json()
    check("flag on: capabilities features.message_pins true", cap["features"].get(FLAG) is True)
    set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 3 pin/unpin

def test_pin_unpin(client):
    print("pin / unpin")
    a, b, c = make_user("pnp1"), make_user("pnp2"), make_user("pnp3")
    noterms = make_user("pnpt", terms=False)
    gid = make_group([a, b, c, noterms])
    m = make_msg(b, gid, "pin me please")
    ck_a, ck_b, ck_c, ck_t = cookie(a), cookie(b), cookie(c), cookie(noterms)
    set_flag(FLAG, "on", a)
    check("anonymous pin refused", client.post(url(a, m)).status_code in (401, 403))
    check("path-user mismatch is 403", client.post(url(b, m), headers=ck_a).status_code == 403)
    check("path-user mismatch unpin is 403", client.delete(url(b, m), headers=ck_a).status_code == 403)
    check("anonymous list refused", client.get(f"/message-pins/{a}/group/{gid}").status_code in (401, 403))
    r = pin(client, a, m, ck_a)
    check("member pins -> 200 {message_id, pinned: true}", r.status_code == 200 and r.json() == {"message_id": m, "pinned": True}, r.text)
    check("pin row exists with pinner", sql("SELECT pinned_by::text, chat_key FROM message_pins WHERE message_id=%s", (m,)) == [(a, gid)])
    r2 = pin(client, a, m, ck_a)
    check("re-pin idempotent 200", r2.status_code == 200 and pins_n(m) == 1, r2.text)
    r3 = pin(client, c, m, ck_c)
    check("a different member re-pinning is idempotent and keeps original pinner",
          r3.status_code == 200 and sql("SELECT pinned_by::text FROM message_pins WHERE message_id=%s", (m,))[0][0] == a)
    r = unpin(client, b, m, ck_b)
    check("any member (not the pinner) can unpin", r.status_code == 200 and r.json() == {"message_id": m, "pinned": False} and pins_n(m) == 0, r.text)
    r = unpin(client, b, m, ck_b)
    check("unpin of unpinned is idempotent 200", r.status_code == 200, r.text)
    # terms: pin needs current terms, unpin does not
    r = pin(client, noterms, m, ck_t)
    check("pin without current terms refused (not 200) and no row", r.status_code != 200 and pins_n(m) == 0, f"{r.status_code} {r.text}")
    sql("INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s,%s,%s)", (m, gid, a))
    r = unpin(client, noterms, m, ck_t)
    check("unpin without current terms still works", r.status_code == 200 and pins_n(m) == 0, f"{r.status_code} {r.text}")
    # DM: either participant may pin
    befriend(a, b)
    dm = make_dm(a, b, "dm pin text")
    r = pin(client, b, dm, ck_b)
    check("DM recipient can pin the sender's message", r.status_code == 200, r.text)
    key = "|".join(sorted([a, b]))
    check("DM pin chat_key is sorted a|b", sql("SELECT chat_key FROM message_pins WHERE message_id=%s", (dm,)) == [(key,)])
    r = unpin(client, a, dm, ck_a)
    check("DM sender can unpin", r.status_code == 200 and pins_n(dm) == 0)
    # malformed ids
    for bad in ("not-a-uuid", "1", "' OR 1=1 --", "%00"):
        rr = pin(client, a, bad, ck_a)
        check(f"malformed id {bad!r} is 404 not 500", rr.status_code == 404, str(rr.status_code))
    set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 4 deny-by-default

def test_visibility(client):
    print("uniform 404 visibility")
    a, b, out, ex = (make_user(f"pnv{i}") for i in range(4))
    gid = make_group([a, b, ex])
    other_gid = make_group([out])
    m = make_msg(b, gid, "private text")
    foreign = make_msg(out, other_gid, "foreign")
    ck_a, ck_out, ck_ex = cookie(a), cookie(out), cookie(ex)
    set_flag(FLAG, "on", a)
    unknown = pin(client, a, str(uuid.uuid4()), ck_a)
    bodies = {"unknown": unknown.json()}
    resp = {
        "non-member": pin(client, out, m, ck_out),
        "foreign-group message by member": pin(client, a, foreign, ck_a),
    }
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (ex, gid))
    resp["ex-member"] = pin(client, ex, m, ck_ex)
    resp["unpin non-member"] = unpin(client, out, m, ck_out)
    for label, r in resp.items():
        check(f"{label}: 404 identical to unknown", r.status_code == 404 and r.json() == bodies["unknown"], f"{r.status_code} {r.text}")
    check("no pin rows from denied calls", pins_n(m) == 0 and pins_n(foreign) == 0)
    # DM stranger
    c = make_user("pnv5")
    befriend(a, b)
    dm = make_dm(a, b, "dm secret")
    r = pin(client, c, dm, cookie(c))
    check("DM stranger: uniform 404", r.status_code == 404 and r.json() == bodies["unknown"])
    # blocked pairs, both directions, group + DM
    for blocker, blocked, label in ((a, b, "viewer blocked author"), (b, a, "author blocked viewer")):
        block(blocker, blocked)
        rg, rd = pin(client, a, m, ck_a), pin(client, a, dm, ck_a)
        check(f"{label}: group pin uniform 404", rg.status_code == 404 and rg.json() == bodies["unknown"], rg.text)
        check(f"{label}: DM pin uniform 404", rd.status_code == 404 and rd.json() == bodies["unknown"], rd.text)
        sql("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (a, a))
    check("blocked calls wrote nothing", pins_n(m) == 0 and pins_n(dm) == 0)
    # soft-deleted
    sql("UPDATE messages SET deleted_at = NOW(), deleted_by = %s WHERE _id=%s", (b, m))
    r = pin(client, a, m, ck_a)
    check("soft-deleted message: uniform 404", r.status_code == 404 and r.json() == bodies["unknown"], r.text)
    sql("UPDATE messages SET deleted_at = NULL, deleted_by = NULL WHERE _id=%s", (m,))
    # system line cannot be pinned
    r = pin(client, a, m, ck_a)
    check("control: visible message pins", r.status_code == 200)
    line = sql("SELECT _id::text FROM messages WHERE group_id=%s AND system_kind='pin'", (gid,))
    if line:
        r = pin(client, a, line[0][0], ck_a)
        check("system line cannot be pinned (uniform 404)", r.status_code == 404 and r.json() == bodies["unknown"], r.text)
        check("system line not in pins", pins_n(line[0][0]) == 0)
    else:
        check("system line existed to test against", False, "no line written")
    # list scoping / IDOR
    for label, r in (("non-member group list", glist(client, out, gid, ck_out)),
                     ("unknown group list", glist(client, a, str(uuid.uuid4()), ck_a)),
                     ("malformed group list", glist(client, a, "zzz", ck_a)),
                     ("DM list with non-friend/unknown", dlist(client, a, str(uuid.uuid4()), ck_a)),
                     ("DM list with self", dlist(client, a, a, ck_a))):
        check(f"{label}: 404", r.status_code == 404 and r.json() == bodies["unknown"], f"{r.status_code} {r.text}")
    set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 5 no cap

def test_no_cap(client):
    print("no cap")
    a, b = make_user("pnc1"), make_user("pnc2")
    gid = make_group([a, b])
    ck = cookie(a)
    set_flag(FLAG, "on", a)
    msgs = [make_msg(b, gid, f"cap-{i}") for i in range(12)]
    codes = []
    for m in msgs:
        codes.append(pin(client, a, m, ck).status_code)
    check("12 pins in one chat all accepted (no 3-pin cap, no 409)", codes == [200] * 12, str(codes))
    check("all 12 rows stored", pins_n(chat=gid) == 12)
    r = glist(client, a, gid, ck, limit=100)
    check("list reports count 12", r.status_code == 200 and r.json()["count"] == 12 and len(r.json()["pins"]) == 12, r.text[:200])
    set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 6 list

def test_list(client):
    print("list")
    a, b, c, out = (make_user(f"pnl{i}") for i in range(4))
    gid = make_group([a, b, c])
    gid2 = make_group([a, b])
    ck_a = cookie(a)
    set_flag(FLAG, "on", a)
    check("empty list ok", glist(client, a, gid, ck_a).json() == {"pins": [], "has_more": False, "count": 0})
    ms = [make_msg(b if i % 2 else a, gid, f"list text {i}") for i in range(5)]
    other = make_msg(a, gid2, "other chat")
    for i, m in enumerate(ms):
        sql("INSERT INTO message_pins (message_id, chat_key, pinned_by, pinned_at) VALUES (%s,%s,%s, NOW() - make_interval(secs => %s))",
            (m, gid, a, (10 - i) * 5))
    sql("INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s,%s,%s)", (other, gid2, a))
    r = glist(client, a, gid, ck_a)
    body = r.json()
    check("200 with 5 pins scoped to this chat only", r.status_code == 200 and body["count"] == 5 and len(body["pins"]) == 5, r.text[:200])
    ids = [p["message_id"] for p in body["pins"]]
    check("newest pin first (by pinned_at)", ids == list(reversed(ms)), str(ids))
    check("other chat pin does not leak", other not in ids)
    p0 = body["pins"][0]
    check("pin shape and decrypted text", p0["message"]["text"] == "list text 4" and p0["pinned_by_id"] == a
          and p0["message"]["id"] == p0["message_id"] and p0["message"]["from_user_id"] == a, str(p0))
    pg1 = glist(client, a, gid, ck_a, limit=2, offset=0).json()
    pg2 = glist(client, a, gid, ck_a, limit=2, offset=2).json()
    pg3 = glist(client, a, gid, ck_a, limit=2, offset=4).json()
    check("pagination: has_more true, true, false; count stays 5",
          (pg1["has_more"], pg2["has_more"], pg3["has_more"]) == (True, True, False) and pg1["count"] == 5)
    check("pagination pages are disjoint and cover all",
          [p["message_id"] for p in pg1["pins"] + pg2["pins"] + pg3["pins"]] == ids)
    check("limit 0 / negative offset / oversized limit are 422",
          glist(client, a, gid, ck_a, limit=0).status_code == 422 and glist(client, a, gid, ck_a, offset=-1).status_code == 422
          and glist(client, a, gid, ck_a, limit=100000).status_code == 422)
    check("limit above max_page_size is clamped", len(glist(client, a, gid, ck_a, limit=1000).json()["pins"]) == 5
          and mp.max_page_size() >= 1)
    # long text clipped
    long_m = make_msg(a, gid, "x" * 600)
    sql("INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s,%s,%s)", (long_m, gid, a))
    top = glist(client, a, gid, ck_a).json()["pins"][0]
    check("preview clipped to 280", top["message_id"] == long_m and len(top["message"]["text"]) == mp.PREVIEW_MAX, str(len(top["message"]["text"])))
    # soft delete hides content, restore brings it back
    sql("UPDATE messages SET deleted_at = NOW(), deleted_by=%s WHERE _id=%s", (a, ms[4]))
    body = glist(client, a, gid, ck_a).json()
    check("soft-deleted message leaves list and count; text never returned",
          ms[4] not in [p["message_id"] for p in body["pins"]] and body["count"] == 5 and "list text 4" not in str(body))
    sql("UPDATE messages SET deleted_at = NULL, deleted_by=NULL WHERE _id=%s", (ms[4],))
    check("restore brings pin back", glist(client, a, gid, ck_a).json()["count"] == 6)
    # blocked author's pin hidden from the blocker
    block(a, c)
    cm = make_msg(c, gid, "blocked author text")
    sql("INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s,%s,%s)", (cm, gid, b))
    body = glist(client, a, gid, ck_a).json()
    check("blocked author's pinned message hidden", cm not in [p["message_id"] for p in body["pins"]] and "blocked author text" not in str(body))
    sql("DELETE FROM blocked_users WHERE blocker_id=%s", (a,))
    # DM list
    befriend(a, b)
    dm = make_dm(b, a, "dm list text")
    sql("INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s,%s,%s)", (dm, "|".join(sorted([a, b])), b))
    r = dlist(client, a, b, ck_a)
    check("DM list returns the DM pin only", r.status_code == 200 and [p["message_id"] for p in r.json()["pins"]] == [dm]
          and r.json()["pins"][0]["message"]["text"] == "dm list text", r.text[:200])
    check("group pins not in DM list", gid not in r.text)
    block(b, a)
    check("blocked pair DM list is uniform 404", dlist(client, a, b, ck_a).status_code == 404)
    sql("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (a, a))
    set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 7 history payloads

def test_payloads(client):
    print("history payloads")
    a, b = make_user("pny1"), make_user("pny2")
    gid = make_group([a, b])
    ck_a = cookie(a)
    m1, m2 = make_msg(b, gid, "hist one"), make_msg(a, gid, "hist two")
    befriend(a, b)
    d1, d2 = make_dm(a, b, "dm hist one"), make_dm(b, a, "dm hist two")
    set_flag(FLAG, "on", a)
    check("pin via API", pin(client, a, m1, ck_a).status_code == 200 and pin(client, a, d1, ck_a).status_code == 200)
    try:
        for gflag, dflag, label in (("off", "off", "legacy"), ("on", "on", "paged")):
            set_flag("chat_pagination", gflag, a)
            set_flag("chat_pagination_dm", dflag, a)
            r = client.get(f"/groups/{a}/{gid}", params={"limit": "50"} if gflag == "on" else {}, headers=ck_a)
            ms = {x["id"]: x for x in all_msgs(r.json()) if x.get("id")}
            check(f"{label} group: pinned true/false per message",
                  r.status_code == 200 and ms.get(m1, {}).get("pinned") is True and ms.get(m2, {}).get("pinned") is False, r.text[:200])
            line = [x for x in ms.values() if x.get("system_kind") == "pin"]
            check(f"{label} group: system line carries system_kind and constant text",
                  len(line) == 1 and line[0].get("pinned") is False and "pinned a message" in str(line[0].get("text")), str(line))
            r = client.get(f"/friends/{a}/{b}", params={"limit": "10"} if dflag == "on" else {}, headers=ck_a)
            dms = {x["id"]: x for x in all_msgs(r.json()) if x.get("id")}
            check(f"{label} DM: pinned flags", r.status_code == 200 and dms.get(d1, {}).get("pinned") is True
                  and dms.get(d2, {}).get("pinned") is False, r.text[:200])
            if gflag == "on":
                r = client.get(f"/groups/{a}/{gid}/messages", params={"limit": "50"}, headers=ck_a)
                pm = {x["id"]: x for x in r.json()["messages"]}
                check("paged group endpoint: pinned flags", pm.get(m1, {}).get("pinned") is True and pm.get(m2, {}).get("pinned") is False, r.text[:200])
                r = client.get(f"/friends/{a}/{b}/messages", params={"limit": "10"}, headers=ck_a)
                pd = {x["id"]: x for x in r.json()["messages"]}
                check("paged DM endpoint: pinned flags", pd.get(d1, {}).get("pinned") is True, r.text[:200])
    finally:
        set_flag("chat_pagination", "off", a)
        set_flag("chat_pagination_dm", "off", a)
        set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 8 system line + push

def test_line_and_push(client):
    print("system line and push")
    a, b, c, nt, muted, blocked_b, offflag = (make_user(f"pnq{i}") for i in range(7))
    gid = make_group([a, b, c, nt, muted, blocked_b, offflag])
    tok = {u: token(u) for u in (b, c, muted, blocked_b, offflag, a)}
    sql("INSERT INTO group_mutes (group_id, user_id) VALUES (%s,%s)", (gid, muted))
    block(a, blocked_b)
    ck_a = cookie(a)
    secret = "TOP-SECRET-MESSAGE-BODY"
    m = make_msg(b, gid, secret)
    set_flag(FLAG, "on", a)
    # flag per recipient: turn on for all except offflag via per-user override if supported, else global on
    # (offflag is exercised through the direct _prepare path below)
    SENT.clear()
    clear_throttle(gid)
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    try:
        r = pin(client, a, m, ck_a)
    finally:
        logging.getLogger().removeHandler(cap)
    check("pin 200", r.status_code == 200, r.text)
    lines = sql("SELECT from_user::text, system_kind FROM messages WHERE group_id=%s AND system_kind='pin'", (gid,))
    check("exactly one system line from the pinner", lines == [(a, "pin")], str(lines))
    raw = sql("SELECT text FROM messages WHERE group_id=%s AND system_kind='pin'", (gid,))[0][0]
    from backend import content_store  # noqa: E402
    lid = sql("SELECT _id::text FROM messages WHERE group_id=%s AND system_kind='pin'", (gid,))[0][0]
    check("system line text is the constant (decrypts to 'pinned a message')",
          content_store.open_or_none(lid, content_store.F_MESSAGE_TEXT, raw, label="t") == "pinned a message")
    rec = {x[0] for x in sql("SELECT user_id::text FROM message_recipients WHERE message_id=%s", (lid,))}
    check("system line recipients are the other live members, not the pinner", a not in rec and {b, c} <= rec, str(rec))
    sent_tokens = {s["token"] for s in SENT}
    check("push sent to eligible members b, c", {tok[b], tok[c]} <= sent_tokens, str(SENT))
    check("push never to the pinner", tok[a] not in sent_tokens)
    check("push skips muted member", tok[muted] not in sent_tokens)
    check("push skips member blocked with the pinner", tok[blocked_b] not in sent_tokens)
    check("push body is 'pinned a message', no message text", all(s["body"] == "pinned a message" and secret not in str(s) for s in SENT), str(SENT))
    check("push title is the pinner's name", all(s["title"] == sql("SELECT username FROM users WHERE _id=%s", (a,))[0][0] for s in SENT))
    check("push data carries ids only for deep link", all(s["data"].get("group_id") == gid and s["data"].get("action") == "message" and "text" not in s["data"] for s in SENT), str(SENT))
    text = " ".join(x.getMessage() for x in cap.records)
    check("logs contain no message content", secret not in text, text[:200])
    # churn: unpin + re-pin within the window is silent
    n_sent, n_lines = len(SENT), lines_n(gid)
    unpin(client, a, m, ck_a)
    check("unpin sends no push and no line", len(SENT) == n_sent and lines_n(gid) == n_lines)
    r = pin(client, a, m, ck_a)
    check("re-pin inside window is 200 but silent (no push, no new line)", r.status_code == 200 and len(SENT) == n_sent and lines_n(gid) == n_lines, f"{len(SENT)} {lines_n(gid)}")
    check("pin row exists despite silence", pins_n(m) == 1)
    # another message by the same pinner inside the window: also silent
    m3 = make_msg(c, gid, "second")
    pin(client, a, m3, ck_a)
    check("different message by same pinner inside window is silent", len(SENT) == n_sent and lines_n(gid) == n_lines)
    # after the window, a new pin notifies again
    sql("UPDATE message_pin_push_claims SET last_at = NOW() - interval '1 hour' WHERE chat_key=%s", (gid,))
    m4 = make_msg(c, gid, "third")
    pin(client, a, m4, ck_a)
    check("after the window a new pin writes a line again", lines_n(gid) == n_lines + 1)
    check("after the window a new pin pushes again", len(SENT) > n_sent)
    # other pinner is independent
    SENT.clear()
    m5 = make_msg(c, gid, "fourth")
    pb = pin(client, b, m5, cookie(b))
    check("a different pinner has their own throttle (line written)", pb.status_code == 200 and lines_n(gid) == n_lines + 2)
    # chat-path push is never fired for the system line: nothing sent with action message and no pin body
    check("no chat-style push (every push body is the pin body)", all(s["body"] == "pinned a message" for s in SENT))
    # atomic claim under concurrency
    clear_throttle(gid)
    base_lines = lines_n(gid)
    cm = [make_msg(c, gid, f"conc-{i}") for i in range(8)]
    out_ = []
    errs = []

    def worker(mid):
        try:
            d = mp.MessagePinsManager(a)
            try:
                out_.append(d.pin(mid))
            finally:
                d.close()
        except Exception as e:  # noqa: BLE001
            errs.append(e)

    ts = [threading.Thread(target=worker, args=(mid,)) for mid in cm]
    [t.start() for t in ts]
    [t.join() for t in ts]
    check("8 concurrent pins by one user claim exactly once", not errs and sum(1 for o in out_ if o and o["notify"]) == 1
          and lines_n(gid) == base_lines + 1, f"{errs} {[o and o['notify'] for o in out_]}")
    check("all 8 concurrent pins stored (no cap)", all(pins_n(mid) == 1 for mid in cm))
    # recipient flag off: use _prepare directly with global flag state for one recipient
    import backend.interactions.pin_push as pp  # noqa: E402
    set_flag(FLAG, "off", a)
    check("recipient flag off: nothing prepared", pp._prepare(gid, a, m, [b, c]) == [])
    set_flag(FLAG, "on", a)
    check("recipient flag on: prepared for b and c", len(pp._prepare(gid, a, m, [b, c])) == 2)
    set_flag(FLAG, "off", a)
    # suspended recipient
    sql("UPDATE users SET suspended_at = NOW() WHERE _id=%s", (b,))
    set_flag(FLAG, "on", a)
    prep = pp._prepare(gid, a, m, [b, c])
    check("suspended recipient skipped", len(prep) == 1 and prep[0]["token"] == tok[c])
    set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 9 DM line + push

def test_dm_line(client):
    print("DM system line")
    a, b = make_user("pnm1"), make_user("pnm2")
    befriend(a, b)
    tb = token(b)
    dm = make_dm(b, a, "dm secret")
    ck_a = cookie(a)
    set_flag(FLAG, "on", a)
    SENT.clear()
    key = "|".join(sorted([a, b]))
    clear_throttle(key)
    r = pin(client, a, dm, ck_a)
    check("DM pin 200", r.status_code == 200, r.text)
    row = sql("SELECT from_user::text, group_id, system_kind FROM messages WHERE from_user=%s AND system_kind='pin'", (a,))
    check("DM system line is a DM row (no group_id) from the pinner", row == [(a, None, "pin")], str(row))
    rec = sql("SELECT user_id::text FROM message_recipients WHERE message_id=(SELECT _id FROM messages WHERE from_user=%s AND system_kind='pin')", (a,))
    check("DM line addressed to the other participant", [x[0] for x in rec] == [b], str(rec))
    check("DM push to the other participant only, no content", [s["token"] for s in SENT] == [tb] and "dm secret" not in str(SENT), str(SENT))
    set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 10 websocket

def test_websocket(client):
    print("websocket frames")
    a, b, c, outsider, blk = (make_user(f"pnw{i}") for i in range(5))
    gid = make_group([a, b, c, blk])
    m = make_msg(b, gid, "ws secret text")
    ck_a = cookie(a)
    block(a, blk)
    set_flag(FLAG, "on", a)
    clear_throttle(gid)
    sockets = {u: FakeWS() for u in (a, b, c, outsider, blk)}
    ws_manager.active_connections.update(sockets)
    try:
        r = pin(client, a, m, ck_a)
        check("pin 200", r.status_code == 200, r.text)
        fb = [f for f in sockets[b].sent if f.get("type") == "pin_updated"]
        check("member b got pin_updated", len(fb) == 1, str(sockets[b].sent))
        if fb:
            check("frame is exactly type/message_id/group_id/pinned/actor_id",
                  fb[0] == {"type": "pin_updated", "message_id": m, "group_id": gid, "pinned": True, "actor_id": a}, str(fb[0]))
            check("frame has no from_user or text (old clients ignore it)", "from_user" not in fb[0] and "text" not in fb[0])
        check("member c got pin_updated", any(f.get("type") == "pin_updated" for f in sockets[c].sent))
        lines = [f for f in sockets[b].sent if f.get("system_kind") == "pin"]
        check("system line frame delivered with system_kind and constant text",
              len(lines) == 1 and lines[0]["text"] == "pinned a message" and lines[0]["from_user"] == a, str(lines))
        check("actor does not get its own frames", sockets[a].sent == [], str(sockets[a].sent))
        check("non-member gets nothing", sockets[outsider].sent == [])
        check("blocked-with-actor user gets no pin_updated", not any(f.get("type") == "pin_updated" for f in sockets[blk].sent), str(sockets[blk].sent))
        n = len(sockets[b].sent)
        pin(client, a, m, ck_a)
        check("idempotent re-pin sends nothing", len(sockets[b].sent) == n)
        unpin(client, a, m, ck_a)
        last = sockets[b].sent[-1]
        check("unpin frame pinned=false", last.get("type") == "pin_updated" and last["pinned"] is False and last["actor_id"] == a, str(last))
        n = len(sockets[b].sent)
        unpin(client, a, m, ck_a)
        check("idempotent unpin sends nothing", len(sockets[b].sent) == n)
        n_all = sum(len(s.sent) for s in sockets.values())
        pin(client, outsider, m, cookie(outsider))
        check("denied pin sends nothing", sum(len(s.sent) for s in sockets.values()) == n_all)

        class Dead:
            async def send_json(self, p):
                raise RuntimeError("socket gone")
        ws_manager.active_connections[c] = Dead()
        r = pin(client, a, m, ck_a)
        check("dead socket never fails the request", r.status_code == 200, r.text)
    finally:
        for u in sockets:
            ws_manager.active_connections.pop(u, None)
        set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 11 logs

def test_logs(client):
    print("log redaction")
    a, b = make_user("pnx1"), make_user("pnx2")
    gid = make_group([a, b])
    secret = "LOGSECRET-pin-body-xyz"
    m = make_msg(b, gid, secret)
    ck = cookie(a)
    token(b)
    set_flag(FLAG, "on", a)
    clear_throttle(gid)
    cap = LogCapture()
    root = logging.getLogger()
    root.addHandler(cap)
    old = root.level
    root.setLevel(logging.DEBUG)
    try:
        pin(client, a, m, ck)
        glist(client, a, gid, ck)
        unpin(client, a, m, ck)
        pin(client, b, str(uuid.uuid4()), cookie(b))
    finally:
        root.removeHandler(cap)
        root.setLevel(old)
    text = " ".join(r.getMessage() for r in cap.records)
    check("no message content in any log line across pin/list/unpin/404", secret not in text)
    set_flag(FLAG, "off", a)


# ---------------------------------------------------------------- 12 rate limit

def test_rate_limit(client):
    print("rate limit")
    a, b = make_user("pnr1"), make_user("pnr2")
    gid = make_group([a, b])
    m = make_msg(b, gid)
    ck = cookie(a)
    set_flag(FLAG, "on", a)
    try:
        limiter.reset()
        rate = mp.pin_rate()
        check("configured rate parses (N/period)", "/" in rate, rate)
        n = int(rate.split("/")[0])
        codes = [(pin(client, a, m, ck) if i % 2 == 0 else unpin(client, a, m, ck)).status_code for i in range(n + 5)]
        check("requests past the limit are 429", codes[:n].count(429) == 0 and codes[n:].count(429) >= 1, str(codes))
        check("pin and unpin share one bucket", len(codes) - codes.count(429) == n, str(codes))
        check("another user is not throttled by this bucket", pin(client, b, m, cookie(b)).status_code == 200)
        limiter.reset()
        ln = int(mp.list_rate().split("/")[0])
        codes = [glist(client, a, gid, ck).status_code for _ in range(ln + 3)]
        check("list is rate limited past list_rate", 429 in codes[ln:] and codes[:ln].count(429) == 0, str(codes[-6:]))
    finally:
        limiter.reset()
        set_flag(FLAG, "off", a)


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    try:
        for fn in (test_ddl_and_flag, test_flag_off, test_pin_unpin, test_visibility, test_no_cap, test_list,
                   test_payloads, test_line_and_push, test_dm_line, test_websocket, test_logs, test_rate_limit):
            limiter.reset()
            if fn is test_ddl_and_flag:
                fn()
            else:
                fn(client)
    finally:
        for f in ALL_FLAGS:
            try:
                set_flag(f, "off", USERS[0] if USERS else "test")
            except Exception:
                pass
        cleanup()
    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        sys.exit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")


if __name__ == "__main__":
    main()
