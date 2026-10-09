"""Tests for GET /notes/highlight/{user_id}/search (HighlightSearch), task 20261009-highlight-search:
search viewer's own + accepted friends' highlights.

Covers: require_match authz (403/401), self + friend visibility, non-friend
exclusion, block exclusion in both directions, one-way (non-accepted) friend
rows, book/chapter/verse/username matching, LIKE wildcard escaping, NUL /
empty / over-length -> 422, pagination (keyset, no dupes), bad cursor -> 422,
verse_text shape.

Run:  cd api && ../.venv/bin/python tests/test_highlight_search.py
"""
import _pathfix  # noqa: F401,E402

import os
import sys
import uuid
from datetime import datetime, timedelta

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


_ctr = 0


def signup(client, prefix):
    global _ctr
    _ctr += 1
    fake_ip = f"198.51.100.{_ctr % 250 + 1}"
    username = f"{prefix}{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session"), username


def hdr(tok):
    return {"cookie": f"session={tok}"}


def sql(q, params=()):
    db = DBManager()
    try:
        db.cur.execute(q, params)
        db.conn.commit()
    finally:
        db.close()


def friends(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s)", (a, b, b, a))


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blocker, blocked))


def hl(uid, key, minutes_ago=0, color="yellow"):
    sql("INSERT INTO highlights (user_id, key, color, timestamp) VALUES (%s,%s,%s,%s)",
        (uid, key, color, datetime.now() - timedelta(minutes=minutes_ago)))


def cleanup(*uids):
    for u in uids:
        sql("DELETE FROM highlights WHERE user_id=%s", (u,))
        sql("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (u, u))
        sql("DELETE FROM user_friends WHERE user_id=%s OR friend_id=%s", (u, u))
        sql("DELETE FROM notes WHERE user_id=%s", (u,))
        sql("DELETE FROM users WHERE _id=%s", (u,))


def search(client, uid, tok, q, **kw):
    params = {"q": q, **kw}
    return client.get(f"/notes/highlight/{uid}/search", params=params, headers=hdr(tok))


def keys(r):
    return {(h["owner_id"], h["key"]) for h in r.json()["highlights"]}


def test_all(client):
    me, tme, _ = signup(client, "hsme")
    fr, _t, fr_name = signup(client, "hsfr")
    stranger, _t2, st_name = signup(client, "hsst")
    blk1, _t3, b1_name = signup(client, "hsb1")   # I blocked them
    blk2, _t4, b2_name = signup(client, "hsb2")   # they blocked me
    oneway, _t5, ow_name = signup(client, "hsow")  # friend row only on their side
    uids = [me, fr, stranger, blk1, blk2, oneway]
    try:
        friends(me, fr); friends(me, blk1); friends(me, blk2)
        sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s)", (oneway, me))
        block(me, blk1); block(blk2, me)

        hl(me, "John-3-16", 5)
        hl(me, "Genesis-1-1", 6)
        hl(fr, "John-3-17", 3)
        hl(fr, "Psalms-23-1", 4)
        hl(stranger, "John-3-18", 1)
        hl(blk1, "John-3-19", 1)
        hl(blk2, "John-3-20", 1)
        hl(oneway, "John-3-21", 1)

        print("=== authz ===")
        r = search(client, fr, tme, "John")
        check("cannot search as another user_id (403)", r.status_code == 403, r.status_code)
        r = client.get(f"/notes/highlight/{me}/search", params={"q": "John"})
        check("unauthenticated (401)", r.status_code == 401, r.status_code)

        print("=== visibility ===")
        r = search(client, me, tme, "John")
        check("200", r.status_code == 200, r.text)
        ks = {k for _o, k in keys(r)}
        check("book match returns own + friend John verses",
              ks == {"John-3-16", "John-3-17"}, ks)
        owners = {h["owner_id"] for h in r.json()["highlights"]}
        check("non-friend, blocked (both dirs), one-way-friend excluded",
              owners == {me, fr}, owners)
        item = next(h for h in r.json()["highlights"] if h["owner_id"] == fr)
        check("friend item attribution/shape",
              item["owner_username"] == fr_name and item["is_self"] is False
              and item["book"] == "John" and item["chapter"] == 3 and item["verse"] == 17
              and item["color"] == "yellow" and "verse_text" in item, item)
        mine = next(h for h in r.json()["highlights"] if h["owner_id"] == me)
        check("own item is_self", mine["is_self"] is True)
        check("verse_text populated for real verse", bool(mine["verse_text"]), mine)
        check("ordered newest first",
              [h["key"] for h in r.json()["highlights"]] == ["John-3-17", "John-3-16"])

        print("=== matching ===")
        check("chapter 'John 3'", {k for _o, k in keys(search(client, me, tme, "John 3"))}
              == {"John-3-16", "John-3-17"})
        check("verse 'John 3:16'", keys(search(client, me, tme, "John 3:16")) == {(me, "John-3-16")})
        check("case-insensitive 'john 3:17'", keys(search(client, me, tme, "john 3:17")) == {(fr, "John-3-17")})
        check("book prefix 'Gen'", keys(search(client, me, tme, "Gen")) == {(me, "Genesis-1-1")})
        check("wrong chapter empty", search(client, me, tme, "John 4").json()["highlights"] == [])
        check("unknown book ref empty", search(client, me, tme, "Nopebook 3:1").json()["highlights"] == [])
        check("person by username returns all that friend's highlights",
              keys(search(client, me, tme, fr_name)) == {(fr, "John-3-17"), (fr, "Psalms-23-1")})
        check("person username partial/case-insensitive",
              keys(search(client, me, tme, fr_name[:8].upper())) >= {(fr, "John-3-17")})
        check("non-friend username yields nothing",
              search(client, me, tme, st_name).json()["highlights"] == [])
        check("blocked users' usernames yield nothing",
              search(client, me, tme, b1_name).json()["highlights"] == []
              and search(client, me, tme, b2_name).json()["highlights"] == [])
        check("one-way friend username yields nothing",
              search(client, me, tme, ow_name).json()["highlights"] == [])
        check("'%' wildcard does not match everything",
              search(client, me, tme, "%").json()["highlights"] == [])
        check("'_' wildcard does not match everything",
              search(client, me, tme, "_").json()["highlights"] == [])
        check("SQL-ish input safe (200 empty)",
              search(client, me, tme, "x'; DROP TABLE highlights;--").status_code == 200)

        print("=== validation ===")
        check("empty q 422", search(client, me, tme, "").status_code == 422)
        check("whitespace q 422", search(client, me, tme, "   ").status_code == 422)
        check("missing q 422", client.get(f"/notes/highlight/{me}/search", headers=hdr(tme)).status_code == 422)
        check("101 chars 422", search(client, me, tme, "a" * 101).status_code == 422)
        check("100 chars ok", search(client, me, tme, "a" * 100).status_code == 200)
        check("NUL 422", search(client, me, tme, "Jo\x00hn").status_code == 422)
        check("bad cursor_timestamp 422",
              search(client, me, tme, "John", cursor_timestamp="garbage", cursor_id=fr,
                     cursor_key="John-3-17").status_code == 422)
        check("cursor_key without cursor 422",
              search(client, me, tme, "John", cursor_key="John-3-17").status_code == 422)
        check("malformed cursor_key 422",
              search(client, me, tme, "John", cursor_timestamp="2026-01-01T00:00:00+00:00",
                     cursor_id=fr, cursor_key="x'; --").status_code == 422)

        print("=== pagination ===")
        for i in range(1, 8):
            hl(fr, f"Matthew-5-{i}", 100 + i)
        seen, cur, pages = [], {}, 0
        while True:
            r = search(client, me, tme, "Matthew", limit=3, **cur)
            assert r.status_code == 200, r.text
            body = r.json()
            seen += [h["key"] for h in body["highlights"]]
            pages += 1
            pg = body["page"]
            if not pg["has_more"]:
                break
            cur = {"cursor_timestamp": pg["next_cursor_timestamp"], "cursor_id": pg["next_cursor_id"],
                   "cursor_key": pg["next_cursor_key"]}
            if pages > 10:
                break
        check("paging covers all 7 with no dupes/gaps",
              sorted(seen) == sorted(f"Matthew-5-{i}" for i in range(1, 8)) and len(seen) == 7, seen)
        check("3 pages of limit 3", pages == 3, pages)
        check("limit clamped to max 50",
              len(search(client, me, tme, "Matthew", limit=1000).json()["highlights"]) == 7
              and search(client, me, tme, "Matthew", limit=1000).json()["page"]["limit"] <= 50)
    finally:
        cleanup(*uids)


def main():
    with TestClient(main_module.app) as client:
        test_all(client)
    print(f"\nRESULT: {len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        for l, d in FAILED:
            print(f"  X {l} -- {d}")
        sys.exit(1)
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
