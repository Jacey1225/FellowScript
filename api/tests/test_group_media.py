"""Endpoint tests for task 20261023-group-info-row, backend step:
``GET /groups/{user_id}/{group_id}/media`` behind the default-OFF ``group_media`` flag.

Proves (each would catch a regression of the specific change):
  * flag registered, default OFF, exposed as capabilities features.group_media
  * flag off: 404 (route looks absent), even for a member
  * member 200 with the exact item shape; stored attachment_key never returned
  * non-member 403, user_id/caller mismatch 403, malformed/unknown group 403,
    membership checked before validation, unauthenticated rejected
  * kind filter (single, comma list, default all three); unknown/empty/"file" -> 422
  * keyset paging with equal timestamps: no gap, no duplicate, newest first
  * limit: default page_size, clamped to max_page_size, bad values 422; bad cursor 422
  * excludes text-only, file, soft-deleted, blocked-author, ex-member, non-member-injected rows
  * media from another group is never returned (forged cursor)
  * gif url passthrough (https only), meta numbers range-checked
  * rate limit (shares the messages_page limit)

Run with: cd api && ../.venv/bin/python tests/test_group_media.py
"""
import _pathfix  # noqa: F401

import os
import sys
import uuid
import json
import logging
from datetime import datetime, timedelta, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.interactions import flags, chat_config  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
import test_chat_pagination as base  # noqa: E402  (helpers only; its main() is guarded)

check, make_user, make_group, insert_msg = base.check, base.make_user, base.make_group, base.insert_msg
cleanup, session_cookie = base.cleanup, base.session_cookie
PASSED, FAILED = base.PASSED, base.FAILED

PAGE_KEYS = {"limit", "has_more", "next_cursor_timestamp", "next_cursor_seq", "next_cursor_id"}
ITEM_KEYS = ["message_id", "kind", "thumb_url", "url", "width", "height", "duration",
             "sender_id", "sender_name", "created_at"]


def assert_scratch():
    d = DBManager()
    d.cur.execute("SHOW port")
    port = d.cur.fetchone()[0]
    d.close()
    ok = port == "55432" or (port == "5432" and os.environ.get("GITHUB_ACTIONS") == "true")
    check("tests run against scratch DB port 55432", ok, port)
    if not ok:
        raise SystemExit("refusing to continue: not the scratch database")


def set_media_flag(state, actor):
    flags.set_flag("group_media", state, actor=actor)
    flags.invalidate()


def insert_media(from_user, gid, kind, ts, key="auto", meta=None, deleted=False):
    mid = insert_msg(from_user, gid, f"{kind}-msg", ts)
    if key == "auto":
        key = None if kind == "gif" else f"secret/{mid}.bin"
    if kind == "gif" and meta is None:
        meta = {"url": "https://media.example.com/g.gif", "preview_url": "https://media.example.com/g-s.gif"}
    d = DBManager()
    d.cur.execute(
        "UPDATE messages SET attachment_kind=%s, attachment_key=%s, attachment_meta=%s::jsonb WHERE _id=%s",
        (kind, key, json.dumps(meta or {}), mid))
    if deleted:
        d.cur.execute("UPDATE messages SET deleted_at = NOW(), deleted_by = %s WHERE _id = %s", (from_user, mid))
    d.conn.commit()
    d.close()
    return mid


def cursor_params(page):
    p = {"cursor_timestamp": page["next_cursor_timestamp"], "cursor_id": page["next_cursor_id"]}
    if page["next_cursor_seq"] is not None:
        p["cursor_seq"] = str(page["next_cursor_seq"])
    return p


def test_flag_registration(client, host):
    print("flag registration")
    spec = flags.registry().get("group_media")
    check("group_media is registered and exposed in capabilities", spec is not None and spec.exposed_in_capabilities)
    set_media_flag("off", host)
    check("group_media defaults/evaluates OFF", flags.is_enabled("group_media", host) is False)
    r = client.get("/app/capabilities", headers=session_cookie(host))
    check("capabilities features.group_media is false when off",
          r.status_code == 200 and r.json()["features"].get("group_media") is False, r.text[:200])
    set_media_flag("on", host)
    r = client.get("/app/capabilities", headers=session_cookie(host))
    check("capabilities features.group_media is true when on",
          r.status_code == 200 and r.json()["features"].get("group_media") is True, r.text[:200])


def test_media(client):
    print("group media endpoint")
    host, other, blocked, outsider, ex = (make_user(f"gmd{i}") for i in range(5))
    gid = make_group([host, other, blocked, ex])
    ck, ck_out = session_cookie(host), session_cookie(outsider)
    url = f"/groups/{host}/{gid}/media"
    d = DBManager()
    d.cur.execute("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (host, blocked))
    d.conn.commit()
    d.close()
    other_gid = None
    try:
        test_flag_registration(client, host)
        ts = datetime.now(timezone.utc) - timedelta(hours=2)
        same = ts + timedelta(seconds=30)
        # 10 images + 6 videos + 4 gifs; 8 of the images share ONE timestamp
        images = [insert_media(host if i % 2 else other, gid, "image", same if i < 8 else ts + timedelta(seconds=i)) for i in range(10)]
        videos = [insert_media(other, gid, "video", ts + timedelta(seconds=100 + i),
                               meta={"width": 1920, "height": 1080, "duration": 12.5}) for i in range(6)]
        gifs = [insert_media(host, gid, "gif", ts + timedelta(seconds=200 + i)) for i in range(4)]
        everything = set(images) | set(videos) | set(gifs)
        # rows that must never appear
        insert_msg(host, gid, "plain text", same)
        insert_media(host, gid, "file", same)
        insert_media(host, gid, "image", same, deleted=True)
        insert_media(blocked, gid, "image", same)
        insert_media(outsider, gid, "image", same)
        insert_media(ex, gid, "image", same)
        d = DBManager()
        d.cur.execute("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (ex, gid))
        d.conn.commit()
        d.close()

        # ---- flag off
        set_media_flag("off", host)
        r = client.get(url, headers=ck)
        check("flag off: member gets 404", r.status_code == 404, str(r.status_code))
        r = client.get(f"/groups/{outsider}/{gid}/media", headers=ck_out)
        check("flag off: non-member also 404 (route absent, no membership oracle)", r.status_code == 404, str(r.status_code))
        set_media_flag("on", host)

        # ---- happy path and shape
        r = client.get(url, headers=ck)
        check("member 200", r.status_code == 200, r.text[:200])
        body = r.json()
        check("envelope keys media+page", set(body) == {"media", "page"} and set(body["page"]) == PAGE_KEYS, str(sorted(body)))
        cfg = chat_config.get_pagination_config()
        check("default limit is page_size", body["page"]["limit"] == cfg.page_size)
        rows = body["media"]
        check("item shape exact and no attachment_key", all(list(i) == ITEM_KEYS for i in rows)
              and "secret/" not in r.text and "attachment_key" not in r.text)
        check("only image/video/gif kinds", {i["kind"] for i in rows} <= {"image", "video", "gif"})
        check("newest first", [i["created_at"] for i in rows] == sorted((i["created_at"] for i in rows), reverse=True))
        gif_item = next(i for i in rows if i["kind"] == "gif")
        check("gif passes provider https url and preview", gif_item["url"] == "https://media.example.com/g.gif"
              and gif_item["thumb_url"] == "https://media.example.com/g-s.gif")
        vid = next(i for i in rows if i["kind"] == "video")
        check("video meta width/height/duration surfaced, thumb_url null",
              (vid["width"], vid["height"], vid["duration"]) == (1920, 1080, 12.5) and vid["thumb_url"] is None)
        check("sender_name resolved, sender_id is lowercase uuid",
              all(i["sender_name"] and i["sender_id"] == i["sender_id"].lower() for i in rows))

        # ---- kind filter
        def ids_for(params):
            return {i["message_id"] for i in client.get(url, params={"limit": "100", **params}, headers=ck).json()["media"]}
        check("default kind returns exactly the visible media set", ids_for({}) == everything)
        check("kind=image", ids_for({"kind": "image"}) == set(images))
        check("kind=video", ids_for({"kind": "video"}) == set(videos))
        check("kind=gif", ids_for({"kind": "gif"}) == set(gifs))
        check("kind=image,video", ids_for({"kind": "image,video"}) == set(images) | set(videos))
        check("kind=image,image de-duplicates", ids_for({"kind": "image,image"}) == set(images))
        for bad in ("file", "image,file", "", ",", "image,", "IMAGE", "x" * 80, "image;DROP"):
            r = client.get(url, params={"kind": bad}, headers=ck)
            check(f"kind={bad[:14]!r} is 422", r.status_code == 422 and "DROP" not in r.text, f"{r.status_code} {r.text[:80]}")

        # ---- paging: no gap, no dup, across equal timestamps
        for size in (1, 3, 7):
            seen, page, guard = [], None, 0
            r = client.get(url, params={"limit": str(size)}, headers=ck)
            assert r.status_code == 200, r.text
            b = r.json()
            seen += [i["message_id"] for i in b["media"]]
            page = b["page"]
            while page["has_more"] and guard < 100:
                guard += 1
                r = client.get(url, params={"limit": str(size), **cursor_params(page)}, headers=ck)
                b = r.json()
                seen += [i["message_id"] for i in b["media"]]
                page = b["page"]
            check(f"size {size}: no duplicates", len(seen) == len(set(seen)))
            check(f"size {size}: no gap, exactly the visible set", set(seen) == everything and len(seen) == len(everything),
                  f"{len(seen)} vs {len(everything)}")
            check(f"size {size}: last page cursors null", page["next_cursor_id"] is None and page["next_cursor_timestamp"] is None)

        # ---- limit and cursor validation
        r = client.get(url, params={"limit": "100000"}, headers=ck)
        check("limit above max is clamped", r.status_code == 200 and r.json()["page"]["limit"] == cfg.max_page_size)
        for bad in ("0", "-1", "abc", "1.5", ""):
            r = client.get(url, params={"limit": bad}, headers=ck)
            check(f"limit={bad!r} is 422", r.status_code == 422, str(r.status_code))
        goodts, goodid = "2026-01-01T00:00:00Z", str(uuid.uuid4())
        for label, params in (
            ("timestamp without id", {"cursor_timestamp": goodts}),
            ("id without timestamp", {"cursor_id": goodid}),
            ("bad timestamp", {"cursor_timestamp": "yesterday", "cursor_id": goodid}),
            ("bad id", {"cursor_timestamp": goodts, "cursor_id": "x'; DROP TABLE messages;--"}),
            ("negative seq", {"cursor_timestamp": goodts, "cursor_id": goodid, "cursor_seq": "-1"}),
        ):
            r = client.get(url, params=params, headers=ck)
            check(f"cursor {label}: 422 invalid_cursor, value not echoed",
                  r.status_code == 422 and "invalid_cursor" in r.text and "DROP" not in r.text, f"{r.status_code} {r.text[:80]}")

        # ---- authorization
        r = client.get(f"/groups/{outsider}/{gid}/media", headers=ck_out)
        check("non-member 403", r.status_code == 403, str(r.status_code))
        r = client.get(f"/groups/{outsider}/{gid}/media", params={"kind": "file", "limit": "0"}, headers=ck_out)
        check("non-member with bad params is 403 not 422 (membership before validation)", r.status_code == 403, str(r.status_code))
        r = client.get(url, headers=ck_out)
        check("path user_id / caller mismatch 403", r.status_code == 403, str(r.status_code))
        r = client.get(f"/groups/{host}/not-a-uuid/media", headers=ck)
        check("malformed group id 403", r.status_code == 403, str(r.status_code))
        r = client.get(f"/groups/{host}/{uuid.uuid4()}/media", headers=ck)
        check("unknown group id 403", r.status_code == 403, str(r.status_code))
        r = client.get(url)
        check("unauthenticated rejected", r.status_code in (401, 403), str(r.status_code))

        # ---- other groups' media, forged cursor
        other_gid = make_group([outsider])
        foreign = insert_media(outsider, other_gid, "image", datetime.now(timezone.utc) - timedelta(hours=3))
        r = client.get(url, params={"limit": "100", "cursor_timestamp": "2099-01-01T00:00:00Z", "cursor_id": foreign}, headers=ck)
        check("forged cursor from another group returns only this group's media", r.status_code == 200
              and {i["message_id"] for i in r.json()["media"]} == everything)
        # thread media lives in another table: not listed (nothing to insert here; table scoping asserted by SQL)

        # ---- meta hardening
        evil = insert_media(host, gid, "gif", datetime.now(timezone.utc),
                            meta={"url": "javascript:alert(1)", "width": -5, "height": "tall", "duration": 1e12})
        evil_img = insert_media(host, gid, "image", datetime.now(timezone.utc), meta={"width": True, "height": 10 ** 9})
        got = {i["message_id"]: i for i in client.get(url, params={"limit": "100"}, headers=ck).json()["media"]}
        check("non-https gif url dropped to null", got[evil]["url"] is None and got[evil]["thumb_url"] is None)
        check("out-of-range / non-numeric meta numbers become null",
              (got[evil]["width"], got[evil]["height"], got[evil]["duration"]) == (None, None, None)
              and (got[evil_img]["width"], got[evil_img]["height"]) == (None, None))

        # ---- rate limit (shares messages_page)
        saved = chat_config._cached
        chat_config._cached = chat_config.PaginationConfig(
            saved.initial_page_size, saved.page_size, saved.max_page_size,
            saved.future_timestamp_skew_seconds, {"messages_page": "3/minute"})
        try:
            try:
                limiter.reset()
            except Exception:
                pass
            codes = [client.get(url, params={"limit": "2"}, headers=ck).status_code for _ in range(5)]
            check("rate limit: 3 allowed then 429", codes[:3] == [200] * 3 and codes[3:] == [429, 429], str(codes))
        finally:
            chat_config._cached = saved
            try:
                limiter.reset()
            except Exception:
                pass
    finally:
        set_media_flag("off", host)
        cleanup([host, other, blocked, outsider, ex], [gid] + ([other_gid] if other_gid else []))


def main():
    logging.getLogger().setLevel(logging.WARNING)
    assert_scratch()
    chat_config.reset_for_tests()
    client = TestClient(main_module.app)
    test_media(client)
    print("\n" + "=" * 60)
    print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} failed")
    for f in FAILED:
        print("  FAILED:", f)
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
