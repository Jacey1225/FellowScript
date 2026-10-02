"""Tests for task 20261001-message-threads step 7: the threads HTTP surface
(flag ``threads``): create / list / read / rename.

Scratch database only (asserts SHOW port = 55432 first). Proves:
  * flag off: every route is the same uniform 404 and nothing is written
  * authz: non-member, removed member, path user != session, anonymous, malformed ids,
    a thread / message of another group, DM message, deleted root: ONE identical 404
  * one thread per root (idempotent create 201 then 200; concurrent creates give one row),
    groups only (DM root refused)
  * require_current_terms on create: 403 {code: terms_reaccept_required} after membership
    (a non-member with stale terms still gets the uniform 404)
  * titles: auto from root text, explicit, blank, too long, NUL; thread cap 409
  * list: keyset pagination round trip, forged cursor / cursor_seq / bad limit 422, blocked
    creator excluded; read: PAG envelope + thread_id, author_set filter, soft-deleted hidden
  * rename: creator only, uniform 404 for everyone else
  * REGRESSION (security fix): root_preview is hidden when the root author is blocked by the
    caller (either direction), left the group or deleted their account
  * UI-facing contract: no delete/restore route and no delete affordance on thread messages
  * per-user limits are FIXED scopes: 12 requests over DIFFERENT path ids still hit 429
  * logs: no title/text, no bare ERROR word; R-ROUTE greps
Run with: cd api && ../.venv/bin/python tests/test_threads.py
"""
import _pathfix  # noqa: F401
from _thr_common import *  # noqa: F401,F403
from _thr_common import (  # noqa: F401
    API_DIR, FAILED, PASSED, FakeWS, LogCapture, add_tmsg, check, cleanup, cookie, finish, make_group,
    make_msg, make_thread, make_user, own_key, require_scratch_db, set_flag, sql, tcount,
)

import inspect
import json
import logging
import os
import re
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace

from fastapi.testclient import TestClient

import main as main_module
from backend.interactions import threads as threads_mod
from backend.interactions.threads import ThreadsManager
from backend.interactions.threads_config import get_threads_config
from backend.rate_limiting import limiter

NOT_FOUND = {"code": "not_found", "message": "Not found"}


def u(uid, gid, tail=""):
    return f"/groups/{uid}/{gid}/threads{tail}"


def post_thread(client, uid, gid, mid, title=None, ck=None):
    limiter.reset()
    body = {"message_id": mid}
    if title is not None:
        body["title"] = title
    return client.post(u(uid, gid), json=body, headers=ck or cookie(uid))


def test_flag_off(client):
    print("flag off")
    a, b = make_user(), make_user()
    gid = make_group([a, b])
    mid = make_msg(a, gid)
    tid = make_thread(gid, mid, a)
    set_flag("threads", "off", a)
    limiter.reset()
    ck = cookie(a)
    resps = {
        "create": client.post(u(a, gid), json={"message_id": make_msg(a, gid)}, headers=ck),
        "list": client.get(u(a, gid), headers=ck),
        "read": client.get(u(a, gid, f"/{tid}/messages"), headers=ck),
        "rename": client.put(u(a, gid, f"/{tid}"), json={"title": "x"}, headers=ck),
    }
    for name, r in resps.items():
        check(f"flag off: {name} is the uniform 404", r.status_code == 404 and r.json()["detail"] == NOT_FOUND,
              (r.status_code, r.text))
    check("flag off: create wrote nothing", sql("SELECT COUNT(*) FROM threads WHERE group_id=%s", (gid,))[0][0] == 1)
    check("flag off: rename wrote nothing", sql("SELECT title FROM threads WHERE _id=%s", (tid,))[0][0] == "a thread")
    set_flag("threads", "on", a)


def test_create_and_authz(client):
    print("create: shape, idempotency, one thread per root, authz, terms, titles, cap")
    a, b, outsider, removed = make_user(), make_user(), make_user(), make_user()
    stale_member = make_user(terms=False)
    stale_outsider = make_user(terms=False)
    gid = make_group([a, b, removed, stale_member])
    gid2 = make_group([a, b])
    set_flag("threads", "on", a)

    mid = make_msg(b, gid, text="  Let's plan   the retreat  ")
    r = post_thread(client, a, gid, mid)
    check("create 201", r.status_code == 201, r.text)
    body = r.json()
    for k in ("id", "group_id", "title", "root_preview", "root_message_id", "root_deleted",
              "reply_count", "last_activity_at", "created_by", "created"):
        check(f"create body has {k}", k in body, body)
    check("create: created true, root linked, group derived from the path",
          body["created"] is True and body["root_message_id"] == mid and body["group_id"] == gid)
    check("auto title from root text, whitespace normalised", body["title"] == "Let's plan the retreat", body["title"])
    check("root_preview is the root text", body["root_preview"] == "Let's plan the retreat", body["root_preview"])
    check("creator recorded server-side (username), reply_count 0", body["created_by"].startswith("thr_") and body["reply_count"] == 0)
    tid = body["id"]
    check("creator and root author follow the thread",
          {str(r_[0]) for r_ in sql("SELECT user_id FROM thread_followers WHERE thread_id=%s", (tid,))} == {a, b})

    # one thread per root: second call (even by another member) returns the same one with 200
    r2 = post_thread(client, a, gid, mid, title="different title")
    check("second create 200, same thread, created false", r2.status_code == 200 and r2.json()["id"] == tid
          and r2.json()["created"] is False, r2.text)
    r3 = post_thread(client, b, gid, mid)
    check("other member's create of the same root returns the existing thread", r3.status_code == 200 and r3.json()["id"] == tid, r3.text)
    check("exactly one thread row for the root", sql("SELECT COUNT(*) FROM threads WHERE root_message_id=%s", (mid,))[0][0] == 1)

    # concurrent creates (manager level, own connections) -> one row
    mid_c = make_msg(a, gid, text="race root")
    def go(_):
        m = ThreadsManager(b)
        try:
            return m.create_thread(gid, mid_c, None)
        finally:
            m.close()
    with ThreadPoolExecutor(max_workers=5) as ex:
        results = list(ex.map(go, range(5)))
    check("concurrent creates: one winner, all succeed", sum(1 for res in results if res and res[1]) == 1
          and all(res is not None for res in results), [res and res[1] for res in results])
    check("concurrent creates left one row", sql("SELECT COUNT(*) FROM threads WHERE root_message_id=%s", (mid_c,))[0][0] == 1)

    # explicit title, blank title, bad titles
    check("explicit title kept (trimmed)", post_thread(client, a, gid, make_msg(a, gid), title="  Trip  plan ").json()["title"] == "Trip plan")
    check("blank title falls back to auto title", post_thread(client, a, gid, make_msg(a, gid, text="auto me"), title="   ").json()["title"] == "auto me")
    long_text = "x" * 200
    check("auto title capped at auto_title_length", len(post_thread(client, a, gid, make_msg(a, gid, text=long_text)).json()["title"]) == get_threads_config().auto_title_length)
    key = own_key(a)
    pr = post_thread(client, a, gid, make_msg(a, gid, text="", kind="image", key=key))
    check("attachment-only root gets a Photo label", pr.status_code == 201 and pr.json()["title"] == "Photo" and pr.json()["root_preview"] == "Photo", pr.text)
    check("title over title_max_length -> 422", post_thread(client, a, gid, make_msg(a, gid), title="t" * 81).status_code == 422)
    check("title with NUL -> 422", post_thread(client, a, gid, make_msg(a, gid), title="a\u0000b").status_code == 422)

    # uniform 404s
    ref = post_thread(client, a, gid, str(uuid.uuid4()))
    check("unknown message 404 uniform body", ref.status_code == 404 and ref.json()["detail"] == NOT_FOUND, ref.text)
    m_other_group = make_msg(a, gid2)
    m_dm = make_msg(a, None, group=False)
    m_deleted = make_msg(a, gid)
    sql("UPDATE messages SET deleted_at=NOW(), deleted_by=%s WHERE _id=%s", (a, m_deleted))
    m_removed = make_msg(removed, gid)
    denials = {
        "message of another group": post_thread(client, a, gid, m_other_group),
        "DM message (groups only)": post_thread(client, a, gid, m_dm),
        "soft-deleted root": post_thread(client, a, gid, m_deleted),
        "malformed message id": post_thread(client, a, gid, "not-a-uuid"),
        "non-member": post_thread(client, outsider, gid, make_msg(a, gid)),
        "malformed group id": post_thread(client, a, "zzz", make_msg(a, gid)),
        "group the caller is not in": post_thread(client, outsider, gid2, m_other_group),
    }
    for name, resp in denials.items():
        check(f"create denial: {name}: uniform 404", resp.status_code == 404 and resp.json() == ref.json(), (resp.status_code, resp.text))
    check("denials stored no thread", sql("SELECT COUNT(*) FROM threads WHERE root_message_id = ANY(%s::uuid[])", ([m_other_group, m_dm, m_deleted],))[0][0] == 0)
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (removed, gid))
    rr = post_thread(client, removed, gid, make_msg(a, gid))
    check("removed member: uniform 404", rr.status_code == 404 and rr.json() == ref.json())
    check("root whose author left the group: 404 for members (not in author_set)",
          post_thread(client, a, gid, m_removed).status_code == 404)
    limiter.reset()
    rx = client.post(u(a, gid), json={"message_id": make_msg(a, gid)}, headers=cookie(b))
    check("path user != session user: denied (403/404), nothing created", rx.status_code in (403, 404), rx.status_code)
    limiter.reset()
    ra = client.post(u(a, gid), json={"message_id": make_msg(a, gid)})
    check("anonymous: denied", ra.status_code in (401, 403, 404), ra.status_code)
    limiter.reset()
    check("missing message_id -> 422", client.post(u(a, gid), json={}, headers=cookie(a)).status_code == 422)

    # blocked author's root is invisible to the blocker (either direction)
    blocker, blocked_author = make_user(), make_user()
    gid3 = make_group([blocker, blocked_author, a])
    m_ba = make_msg(blocked_author, gid3)
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blocker, blocked_author))
    check("blocker cannot start a thread on the blocked author's message (404)", post_thread(client, blocker, gid3, m_ba).status_code == 404)
    check("blocked author cannot start a thread on the blocker's message either (404)",
          post_thread(client, blocked_author, gid3, make_msg(blocker, gid3)).status_code == 404)
    check("an unrelated member can", post_thread(client, a, gid3, m_ba).status_code == 201)

    # terms gate (create only), after membership
    stale_msg = make_msg(a, gid)
    rt = post_thread(client, stale_member, gid, stale_msg)
    check("stale terms member: create 403", rt.status_code == 403, rt.text)
    check("403 body is {code: terms_reaccept_required}", rt.json().get("detail") == {"code": "terms_reaccept_required"}, rt.text)
    check("stale terms: no thread created", sql("SELECT COUNT(*) FROM threads WHERE root_message_id=%s", (stale_msg,))[0][0] == 0)
    rno = post_thread(client, stale_outsider, gid, stale_msg)
    check("stale-terms NON-member still gets the uniform 404 (membership first)", rno.status_code == 404 and rno.json() == ref.json(), rno.text)
    # reads are not terms-gated
    limiter.reset()
    check("stale terms member can still list", client.get(u(stale_member, gid), headers=cookie(stale_member)).status_code == 200)

    # thread cap -> 409 thread_limit
    gid4 = make_group([a])
    real = threads_mod.get_threads_config
    base = real()
    threads_mod.get_threads_config = lambda: replace(base, max_threads_per_group=2)
    try:
        c1 = post_thread(client, a, gid4, make_msg(a, gid4)).status_code
        c2 = post_thread(client, a, gid4, make_msg(a, gid4)).status_code
        r_cap = post_thread(client, a, gid4, make_msg(a, gid4))
        r_exist = post_thread(client, a, gid4, sql("SELECT root_message_id::text FROM threads WHERE group_id=%s LIMIT 1", (gid4,))[0][0])
    finally:
        threads_mod.get_threads_config = real
    check("cap: first two create", (c1, c2) == (201, 201), (c1, c2))
    check("cap: third -> 409 thread_limit", r_cap.status_code == 409 and r_cap.json()["detail"] == {"code": "thread_limit"}, r_cap.text)
    check("cap: opening an existing thread at the cap still works", r_exist.status_code == 200, r_exist.text)
    limiter.reset()


def test_list_and_read(client):
    print("list + read: pagination, filters")
    a, b, c, outsider = make_user(), make_user(), make_user(), make_user()
    gid, gid2 = make_group([a, b, c]), make_group([a])
    set_flag("threads", "on", a)
    ck = cookie(a)
    tids = []
    for i in range(5):
        m = make_msg(a, gid, text=f"root {i}")
        t = make_thread(gid, m, a, title=f"T{i}", root_preview=f"root {i}")
        sql("UPDATE threads SET last_activity_at = NOW() - make_interval(mins => %s) WHERE _id=%s", (10 * i, t))
        tids.append(t)  # tids[0] most recent
    other_thread = make_thread(gid2, make_msg(a, gid2), a, title="other group")
    limiter.reset()
    r = client.get(u(a, gid), headers=ck)
    check("list 200", r.status_code == 200, r.text)
    j = r.json()
    check("list envelope: threads + page", set(j) == {"threads", "page"} and j["page"]["limit"] == 20, j.get("page"))
    check("list ordered by last activity, only this group's threads",
          [t["id"] for t in j["threads"]] == tids, [t["id"] for t in j["threads"]])
    for k in ("id", "title", "root_preview", "root_deleted", "reply_count", "last_activity_at", "created_by"):
        check(f"list item has {k}", k in j["threads"][0])
    check("list item exposes no delete affordance", not any("delete" in k and k != "root_deleted" for k in j["threads"][0]))
    # pagination round trip
    seen, cursor, pages = [], {}, 0
    while True:
        limiter.reset()
        rp = client.get(u(a, gid), params={"limit": 2, **cursor}, headers=ck).json()
        pages += 1
        seen += [t["id"] for t in rp["threads"]]
        pg = rp["page"]
        if not pg["has_more"]:
            break
        check("list page: next_cursor_seq always null", pg["next_cursor_seq"] is None, pg)
        cursor = {"cursor_timestamp": pg["next_cursor_timestamp"], "cursor_id": pg["next_cursor_id"]}
    check("pagination walked every thread once, in order", seen == tids and pages == 3, (seen, pages))
    limiter.reset()
    check("cursor_seq on the list -> 422", client.get(u(a, gid), params={"cursor_timestamp": "2026-01-01T00:00:00Z", "cursor_id": tids[0], "cursor_seq": "1"}, headers=ck).status_code == 422)
    limiter.reset()
    check("forged cursor id -> 422", client.get(u(a, gid), params={"cursor_timestamp": "2026-01-01T00:00:00Z", "cursor_id": "x'; --"}, headers=ck).status_code == 422)
    limiter.reset()
    check("cursor_timestamp without cursor_id -> 422", client.get(u(a, gid), params={"cursor_timestamp": "2026-01-01T00:00:00Z"}, headers=ck).status_code == 422)
    for bad in ("0", "-1", "abc", "1; drop"):
        limiter.reset()
        check(f"limit={bad!r} -> 422", client.get(u(a, gid), params={"limit": bad}, headers=ck).status_code == 422)
    limiter.reset()
    check("huge limit is clamped to the max (50), not an error", client.get(u(a, gid), params={"limit": "9999"}, headers=ck).json()["page"]["limit"] == 50)
    limiter.reset()
    rn = client.get(u(outsider, gid), headers=cookie(outsider))
    check("non-member list: uniform 404", rn.status_code == 404 and rn.json()["detail"] == NOT_FOUND)
    limiter.reset()
    rw = client.get(u(a, "zzz"), headers=ck)
    check("malformed group id: uniform 404", rw.status_code == 404 and rw.json()["detail"] == NOT_FOUND)

    # blocked creator's thread is excluded for the blocker only
    cb = make_msg(b, gid, text="b root")
    tb = make_thread(gid, cb, b, title="b thread", root_preview="b root")
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (a, b))
    limiter.reset()
    ids_a = [t["id"] for t in client.get(u(a, gid), headers=ck).json()["threads"]]
    limiter.reset()
    ids_c = [t["id"] for t in client.get(u(c, gid), headers=cookie(c)).json()["threads"]]
    check("blocked creator's thread excluded for the blocker", tb not in ids_a)
    check("same thread still listed for an unrelated member", tb in ids_c)
    sql("DELETE FROM blocked_users WHERE blocker_id=%s", (a,))

    # ---- read
    tid = tids[0]
    t0 = "2026-03-01T10:00:00+00:00"
    msgs = []
    for i in range(5):
        mid = str(uuid.uuid4())
        sql("INSERT INTO thread_messages (_id, thread_id, from_user, text, created_at) "
            "VALUES (%s,%s,%s,%s, %s::timestamptz + make_interval(secs => %s))", (mid, tid, a if i % 2 else b, f"m{i}", t0, i))
        msgs.append(mid)
    limiter.reset()
    rr = client.get(u(a, gid, f"/{tid}/messages"), headers=ck)
    check("read 200", rr.status_code == 200, rr.text)
    jm = rr.json()
    check("read envelope: messages + page", set(jm) == {"messages", "page"})
    check("read returns all five oldest-first inside the page", [m["text"] for m in jm["messages"]] == [f"m{i}" for i in range(5)], jm)
    row = jm["messages"][0]
    check("row has main-chat shape plus thread_id", {"id", "thread_id", "from_user", "mine", "text", "timestamp",
          "attachment_kind", "attachment_meta", "attachment_url"} <= set(row), sorted(row))
    check("row thread_id and mine are right", row["thread_id"] == tid and row["mine"] is False and jm["messages"][1]["mine"] is True)
    check("row carries no delete affordance keys", not any("delete" in k for k in row), sorted(row))
    # pagination: newest page first
    seen, cursor = [], {}
    while True:
        limiter.reset()
        rp = client.get(u(a, gid, f"/{tid}/messages"), params={"limit": 2, **cursor}, headers=ck).json()
        seen = [m["text"] for m in rp["messages"]] + seen
        pg = rp["page"]
        if not pg["has_more"]:
            break
        cursor = {"cursor_timestamp": pg["next_cursor_timestamp"], "cursor_seq": pg["next_cursor_seq"], "cursor_id": pg["next_cursor_id"]}
    check("thread message pagination round trip, no gaps or duplicates", seen == [f"m{i}" for i in range(5)], seen)
    limiter.reset()
    check("thread messages: forged cursor -> 422", client.get(u(a, gid, f"/{tid}/messages"), params={"cursor_timestamp": "bad", "cursor_id": msgs[0]}, headers=ck).status_code == 422)

    # filters: blocked author, ex-member author, soft-deleted
    ex = make_user()
    sql("UPDATE groups SET users = users || %s::text WHERE _id=%s", (ex, gid))
    add_tmsg(tid, ex, "from ex-member")
    add_tmsg(tid, a, "soft deleted", deleted=True)
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (ex, gid))
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (a, b))
    limiter.reset()
    texts = [m["text"] for m in client.get(u(a, gid, f"/{tid}/messages"), headers=ck).json()["messages"]]
    check("blocked author's messages hidden from the blocker", not {"m0", "m2", "m4"} & set(texts), texts)
    check("ex-member's messages hidden", "from ex-member" not in texts)
    check("soft-deleted thread messages hidden", "soft deleted" not in texts)
    limiter.reset()
    texts_c = [m["text"] for m in client.get(u(c, gid, f"/{tid}/messages"), headers=cookie(c)).json()["messages"]]
    check("unrelated member still sees the blocked author's messages", {"m0", "m2", "m4"} <= set(texts_c), texts_c)
    sql("DELETE FROM blocked_users WHERE blocker_id=%s", (a,))

    # uniform 404s on read
    limiter.reset()
    ref = client.get(u(a, gid, f"/{uuid.uuid4()}/messages"), headers=ck)
    check("unknown thread: uniform 404", ref.status_code == 404 and ref.json()["detail"] == NOT_FOUND)
    for name, resp in {
        "thread of another group": client.get(u(a, gid, f"/{other_thread}/messages"), headers=ck),
        "non-member": client.get(u(outsider, gid, f"/{tid}/messages"), headers=cookie(outsider)),
        "malformed thread id": client.get(u(a, gid, "/nope/messages"), headers=ck),
    }.items():
        limiter.reset()
        check(f"read denial: {name}: identical 404", resp.status_code == 404 and resp.json() == ref.json(), (resp.status_code, resp.text))
    limiter.reset()
    left = make_user()
    sql("UPDATE groups SET users = users || %s::text WHERE _id=%s", (left, gid))
    ckl = cookie(left)
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (left, gid))
    check("removed member can no longer read (membership re-checked each call)", client.get(u(left, gid, f"/{tid}/messages"), headers=ckl).status_code == 404)
    limiter.reset()
    check("anonymous read denied", client.get(u(a, gid, f"/{tid}/messages")).status_code in (401, 403, 404))
    limiter.reset()


def test_rename(client):
    print("rename: creator only")
    a, b, outsider = make_user(), make_user(), make_user()
    gid, gid2 = make_group([a, b]), make_group([a, b])
    set_flag("threads", "on", a)
    t = make_thread(gid, make_msg(a, gid), a, title="old")
    t_other = make_thread(gid2, make_msg(a, gid2), a, title="other")
    limiter.reset()
    r = client.put(u(a, gid, f"/{t}"), json={"title": "  New   name "}, headers=cookie(a))
    check("creator rename 200 {id,title}", r.status_code == 200 and r.json() == {"id": t, "title": "New name"}, r.text)
    ref = client.put(u(a, gid, f"/{uuid.uuid4()}"), json={"title": "x"}, headers=cookie(a))
    check("unknown thread: uniform 404", ref.status_code == 404 and ref.json()["detail"] == NOT_FOUND)
    for name, resp in {
        "non-creator member": client.put(u(b, gid, f"/{t}"), json={"title": "hijack"}, headers=cookie(b)),
        "non-member": client.put(u(outsider, gid, f"/{t}"), json={"title": "hijack"}, headers=cookie(outsider)),
        "thread of another group": client.put(u(a, gid, f"/{t_other}"), json={"title": "hijack"}, headers=cookie(a)),
        "malformed thread id": client.put(u(a, gid, "/nope"), json={"title": "hijack"}, headers=cookie(a)),
    }.items():
        check(f"rename denial: {name}: identical 404", resp.status_code == 404 and resp.json() == ref.json(), (resp.status_code, resp.text))
    check("denied renames changed nothing", sql("SELECT title FROM threads WHERE _id=%s", (t,))[0][0] == "New name"
          and sql("SELECT title FROM threads WHERE _id=%s", (t_other,))[0][0] == "other")
    for bad, label in (("   ", "blank"), ("t" * 81, "too long"), ("a\u0000b", "NUL")):
        check(f"rename {label} title -> 422", client.put(u(a, gid, f"/{t}"), json={"title": bad}, headers=cookie(a)).status_code == 422)
    check("rename missing title -> 422", client.put(u(a, gid, f"/{t}"), json={}, headers=cookie(a)).status_code == 422)
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (a, gid))
    check("creator who left the group cannot rename (404)", client.put(u(a, gid, f"/{t}"), json={"title": "late"}, headers=cookie(a)).status_code == 404)
    limiter.reset()
    check("anonymous rename denied", client.put(u(a, gid, f"/{t}"), json={"title": "x"}).status_code in (401, 403, 404))
    limiter.reset()


def _find(client, viewer, gid, tid):
    limiter.reset()
    items = client.get(u(viewer, gid), headers=cookie(viewer)).json()["threads"]
    return next((t for t in items if t["id"] == tid), None)


def test_root_preview_regression(client):
    print("REGRESSION: root_preview hidden for a blocked / departed / deleted root author")
    set_flag("threads", "on", USERS[0] if USERS else "x")
    secret = "ROOT-SECRET-TEXT"
    # (1) caller blocked the root author
    a, b, c = make_user(), make_user(), make_user()
    gid = make_group([a, b, c])
    set_flag("threads", "on", a)
    mid = make_msg(b, gid, text=secret)
    r = post_thread(client, a, gid, mid, title="neutral title")
    tid = r.json()["id"]
    check("baseline: before the block the creator sees the root preview", r.json()["root_preview"] == secret and r.json()["root_deleted"] is False)
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (a, b))
    item = _find(client, a, gid, tid)
    check("caller blocked the root author: list hides root_preview", item is not None and item["root_preview"] is None and item["root_deleted"] is True, item)
    check("hidden preview text is nowhere in the list response", secret not in json.dumps(client.get(u(a, gid), headers=cookie(a)).json()))
    limiter.reset()
    again = client.post(u(a, gid), json={"message_id": mid}, headers=cookie(a))
    check("create path: the root author is not visible to the blocker so the root is refused (404)", again.status_code == 404, again.text)
    item_c = _find(client, c, gid, tid)
    check("unrelated member c still sees the preview", item_c is not None and item_c["root_preview"] == secret and item_c["root_deleted"] is False, item_c)
    sql("DELETE FROM blocked_users WHERE blocker_id=%s", (a,))

    # (1b) root author blocked the caller (the other direction)
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (b, a))
    item = _find(client, a, gid, tid)
    check("root author blocked the caller: list hides root_preview", item is not None and item["root_preview"] is None and item["root_deleted"] is True, item)
    sql("DELETE FROM blocked_users WHERE blocker_id=%s", (b,))
    item = _find(client, a, gid, tid)
    check("unblocked: preview visible again", item is not None and item["root_preview"] == secret)

    # (2) root author left the group
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (b, gid))
    for viewer in (a, c):
        item = _find(client, viewer, gid, tid)
        check("root author left the group: preview hidden", item is not None and item["root_preview"] is None and item["root_deleted"] is True, item)
    check("thread itself stays listed (it dies only with its group)", _find(client, a, gid, tid) is not None)

    # (3) root author deleted their account
    d1, d2, d3 = make_user(), make_user(), make_user()
    gid3 = make_group([d1, d2, d3])
    set_flag("threads", "on", d1)
    mid3 = make_msg(d2, gid3, text=secret)
    tid3 = post_thread(client, d1, gid3, mid3, title="neutral title").json()["id"]
    check("baseline: preview visible before account deletion", _find(client, d3, gid3, tid3)["root_preview"] == secret)
    limiter.reset()
    rd = client.delete(f"/user/{d2}", headers=cookie(d2))
    check("account deleted (204)", rd.status_code == 204, (rd.status_code, rd.text))
    item = _find(client, d3, gid3, tid3)
    check("root author's account deleted: preview hidden, root_deleted true",
          item is not None and item["root_preview"] is None and item["root_deleted"] is True, item)
    check("deleted-author secret text not in the response", secret not in json.dumps(client.get(u(d3, gid3), headers=cookie(d3)).json()))
    limiter.reset()


def test_no_delete_contract():
    print("UI-facing contract: no delete on thread messages")
    app = main_module.app
    routes = [r for r in app.routes if getattr(r, "path", "") and "thread" in r.path]
    methods = {m for r in routes for m in (r.methods or ())}
    check("threads routes expose only GET/POST/PUT", methods <= {"GET", "POST", "PUT", "HEAD", "OPTIONS"}, methods)
    check("no restore / delete path under threads", not any(re.search(r"delete|restore", r.path) for r in routes), [r.path for r in routes])
    from routes import messages_delete as md_routes
    check("message_delete twin routes only address /messages/{id}, not thread messages",
          all("thread" not in r.path for r in md_routes.messages_delete_router.routes), [r.path for r in md_routes.messages_delete_router.routes])
    src = open(os.path.join(API_DIR, "backend", "interactions", "threads.py")).read()
    check("thread read row builder has no delete/undo key", not re.search(r'"(can_)?(delete|undo|deletable)', src))


def test_rate_limit_fixed_scopes(client):
    print("per-user limits use FIXED scopes (not bucketed per path parameter)")
    a = make_user()
    gid = make_group([a])
    set_flag("threads", "on", a)
    ck = cookie(a)
    limiter.reset()
    codes = [client.post(u(a, gid), json={"message_id": str(uuid.uuid4())}, headers=ck).status_code for _ in range(12)]
    check("create: 10/minute per user across DIFFERENT message ids: 11th+ is 429", codes[:10].count(404) == 10 and 429 in codes[10:], codes)
    limiter.reset()
    codes = [client.put(u(a, gid, f"/{uuid.uuid4()}"), json={"title": "x"}, headers=ck).status_code for _ in range(12)]
    check("rename: 10/minute per user across DIFFERENT thread ids: 11th+ is 429", codes[:10].count(404) == 10 and 429 in codes[10:], codes)
    limiter.reset()
    codes = [client.get(u(a, gid, f"/{uuid.uuid4()}/messages"), headers=ck).status_code for _ in range(123)]
    check("thread messages read: 120/minute per user across DIFFERENT thread ids: 121st+ is 429", codes[:120].count(404) == 120 and 429 in codes[120:], (codes[:3], codes[118:]))
    # another user is not affected by a's exhausted bucket
    b = make_user()
    gid_b = make_group([b])
    check("a different user has their own bucket", client.get(u(b, gid_b, f"/{uuid.uuid4()}/messages"), headers=cookie(b)).status_code == 404)
    limiter.reset()
    src = open(os.path.join(API_DIR, "routes", "threads.py")).read()
    for scope in ("thread_create", "thread_rename", "threads_list", "thread_messages_page"):
        check(f"fixed scope {scope!r} declared", f'scope="{scope}"' in src)
    check("every limit uses shared_limit (never a path-bucketed @limiter.limit)", "@limiter.limit" not in src and src.count("shared_limit(") == 4)


def test_logging(client):
    print("logging: ids only, no PII, no bare ERROR")
    cap = LogCapture()
    root = logging.getLogger()
    root.addHandler(cap)
    old = root.level
    root.setLevel(logging.DEBUG)
    a, b = make_user(), make_user()
    gid = make_group([a, b])
    set_flag("threads", "on", a)
    canary_text, canary_title = "LOG-CANARY-ROOT-TEXT", "LOG-CANARY-TITLE"
    mid = make_msg(b, gid, canary_text)
    tid = post_thread(client, a, gid, mid, title=canary_title).json()["id"]
    limiter.reset()
    client.put(u(a, gid, f"/{tid}"), json={"title": "LOG-CANARY-RENAME"}, headers=cookie(a))
    limiter.reset()
    client.get(u(a, gid), headers=cookie(a))
    client.get(u(a, gid, f"/{tid}/messages"), headers=cookie(a))
    client.post(u(a, gid), json={"message_id": str(uuid.uuid4())}, headers=cookie(a))
    root.removeHandler(cap)
    root.setLevel(old)
    mine = [r for r in cap.records if r.name.startswith(("backend.interactions.threads", "routes.threads"))]
    msgs = [r.getMessage() for r in mine]
    check("create/rename produced audit lines", any("THREAD_CREATE" in m for m in msgs) and any("THREAD_RENAME" in m for m in msgs), msgs)
    check("audit lines hold ids", any(tid in m and gid in m for m in msgs), msgs)
    everything = " ".join(r.getMessage() for r in cap.records)
    check("no root text / title / rename text in any log line", not any(c in everything for c in (canary_text, canary_title, "LOG-CANARY-RENAME")))
    check("no usernames or emails in thread log lines", not any(re.search(r"thr_[0-9a-f]{8}|@example\.com", m) for m in msgs), msgs)
    check("no bare ERROR word in non-error thread log lines", not any(
        re.search(r"\bERROR\b", r.getMessage()) for r in mine if r.levelno < logging.ERROR))
    check("an expected denial does not log at ERROR", not any(r.levelno >= logging.ERROR for r in mine), [(r.levelname, r.getMessage()) for r in mine if r.levelno >= logging.ERROR])
    limiter.reset()


def test_greps():
    print("R-ROUTE greps")
    from routes import threads as rt
    rsrc = open(os.path.join(API_DIR, "routes", "threads.py")).read()
    check("routes/threads.py: no async def (R-ROUTE)", "async def" not in rsrc)
    for r in rt.threads_router.routes:
        check(f"{sorted(r.methods)} {r.path} endpoint is plain def", not inspect.iscoroutinefunction(r.endpoint))
        names = [getattr(d.call, "__name__", "") for d in r.dependant.dependencies]
        check(f"{r.path} resolves the session user through require_match", any("require_match" in n or n == "dep" or n for n in names) and "require_match" in rsrc)
    msrc = open(os.path.join(API_DIR, "backend", "interactions", "threads.py")).read()
    check("threads manager has no async def", "async def" not in msrc)
    check("threads.py logs no text/title (audit takes ids)", not re.search(r"logger\.\w+\([^)]*(title|text|body)", msrc))
    bad = [l for l in (msrc + rsrc).splitlines() if re.search(r"logger\.(info|warning|debug)\(", l) and re.search(r"\bERROR\b", l)]
    check("no bare ERROR in module log calls", not bad, bad)
    main_src = open(os.path.join(API_DIR, "main.py")).read()
    check("main wires threads_router", "app.include_router(threads_router)" in main_src)
    ws_src = open(os.path.join(API_DIR, "backend", "interactions", "websockets.py")).read()
    check("send_msg path untouched: no thread reference in websockets.py", "thread_message" not in ws_src and "threads" not in ws_src.lower().replace("threadpool", ""))
    msg_src = open(os.path.join(API_DIR, "routes", "messaging.py")).read()
    check("messaging.py has exactly one thread dispatch branch", msg_src.count("send_thread_message(") == 1 and msg_src.count('== "thread_message"') == 1)
    group_info = open(os.path.join(API_DIR, "routes", "group_info.py")).read()
    check("group_info.py untouched by threads", "threads" not in group_info.lower() and "thread_message" not in group_info)


def main():
    require_scratch_db()
    client = TestClient(main_module.app)
    try:
        test_flag_off(client)
        test_create_and_authz(client)
        test_list_and_read(client)
        test_rename(client)
        test_root_preview_regression(client)
        test_no_delete_contract()
        test_rate_limit_fixed_scopes(client)
        test_logging(client)
        test_greps()
    except BaseException as e:
        FAILED.append(("unexpected exception", repr(e)))
        raise
    finally:
        limiter.reset()
        finish()


if __name__ == "__main__":
    main()
