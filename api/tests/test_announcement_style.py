"""Backend coverage for task 20261009-announcements-advanced parts C and D.

title_font / bg_theme: nullable allowlisted keys, flag-gated (both flags ship
OFF). Flag off: response keys omitted, non-null writes 422, null writes ok.
Flag on: unknown keys 422, null on update resets, omitted leaves untouched.
Reuses the harness helpers of test_group_announcements.py.

Run with: cd api && FS_TEST_PGPORT=<scratch port> ../.venv/bin/python tests/test_announcement_style.py
"""
import _pathfix  # noqa: F401

import uuid

import test_group_announcements as T
from test_group_announcements import (  # noqa: E402
    DBManager, TestClient, base, check, ck, cleanup, create_group, create_tables,
    main_module, make_paid, signup, sql,
)
import backend.interactions.announcements as ann
from backend.interactions import flags

FLAGS = (ann.TITLE_FONT_FLAG, ann.BG_THEME_FLAG)
BAD_FONT = ["Playfair", "playfair ", "", "none", "../x", "default\n", "x" * 500, "ｐlayfair", "javascript:1", "DEFAULT"]
BAD_THEME = ["Ember", "ember ", "", "default", "#FFFFFF", "red", "url(http://evil)", "none\n", "x" * 500]


def set_flags(state):
    for name in FLAGS:
        sql("UPDATE feature_flags SET state=%s WHERE name=%s", (state, name))
    flags.invalidate()


def reset_limits():
    from backend.rate_limiting import limiter
    limiter.reset()


def test_migration_and_seed():
    print("\n== migration / seed ==")
    db = DBManager()
    try:
        create_tables(db.cur); create_tables(db.cur); db.conn.commit()
        check("create_tables() twice ok", True)
    finally:
        db.close()
    rows = sql("SELECT column_name, is_nullable, column_default FROM information_schema.columns "
               "WHERE table_name='group_announcements' AND column_name IN ('title_font','bg_theme') ORDER BY 1",
               fetch=True)
    check("both columns exist, nullable, no default",
          rows == [("bg_theme", "YES", None), ("title_font", "YES", None)], str(rows))
    for name in FLAGS:
        # Seeded off on a fresh DB; the test flips it, so just check the row exists.
        r = sql("SELECT state FROM feature_flags WHERE name=%s", (name,), fetch=True)
        check(f"flag {name} seeded", len(r) == 1, str(r))


def test_unit():
    print("\n== normalize unit ==")
    check("None passes", ann.normalize_title_font(None) is None and ann.normalize_bg_theme(None) is None)
    for k in ann.TITLE_FONT_KEYS:
        check(f"font {k} ok", ann.normalize_title_font(k) == k)
    for k in ann.BG_THEME_KEYS:
        check(f"theme {k} ok", ann.normalize_bg_theme(k) == k)
    for k in BAD_FONT + [1, True, ["lora"]]:
        try:
            ann.normalize_title_font(k); check(f"font {k!r} rejected", False)
        except ValueError:
            check(f"font {k!r} rejected", True)
    for k in BAD_THEME + [1, ["ember"]]:
        try:
            ann.normalize_bg_theme(k); check(f"theme {k!r} rejected", False)
        except ValueError:
            check(f"theme {k!r} rejected", True)
    check("none + 12 themes, 8 fonts", len(ann.BG_THEME_KEYS) == 13 and len(ann.TITLE_FONT_KEYS) == 8)


def test_flags_off(client):
    print("\n== flags off ==")
    set_flags("off")
    a, ta = signup(client, f"st_off_{uuid.uuid4().hex[:8]}")
    make_paid(a)
    gid = None
    try:
        gid = create_group(client, ta, a, [])
        r = client.post(base(a, gid), json={"title": "plain"}, headers=ck(ta))
        check("plain create 201", r.status_code == 201, r.text)
        check("keys omitted when off", "title_font" not in r.json() and "bg_theme" not in r.json(), str(r.json()))
        for body in ({"title_font": "lora"}, {"bg_theme": "ember"}):
            r = client.post(base(a, gid), json={"title": "x", **body}, headers=ck(ta))
            check(f"create {body} 422 while off", r.status_code == 422, r.text)
        r = client.post(base(a, gid), json={"title": "nulls", "title_font": None, "bg_theme": None}, headers=ck(ta))
        check("explicit nulls ok while off", r.status_code == 201, r.text)
        aid = r.json()["id"]
        r = client.put(f"{base(a, gid)}/{aid}", json={"title_font": "lora"}, headers=ck(ta))
        check("update non-null 422 while off", r.status_code == 422, r.text)
        r = client.put(f"{base(a, gid)}/{aid}", json={"bg_theme": None}, headers=ck(ta))
        check("update null accepted while off", r.status_code == 200, r.text)
        v = sql("SELECT title_font, bg_theme FROM group_announcements WHERE group_id=%s", (gid,), fetch=True)
        check("nothing stored", all(x == (None, None) for x in v), str(v))
    finally:
        cleanup([a], [gid] if gid else [])


def test_flags_on(client):
    print("\n== flags on ==")
    set_flags("on")
    a, ta = signup(client, f"st_on_{uuid.uuid4().hex[:8]}")
    make_paid(a)
    gid = None
    try:
        gid = create_group(client, ta, a, [])
        r = client.post(base(a, gid), json={"title": "styled", "title_font": "lora", "bg_theme": "dusk"},
                        headers=ck(ta))
        check("create 201", r.status_code == 201, r.text)
        j = r.json(); aid = j["id"]
        check("fields echoed", j.get("title_font") == "lora" and j.get("bg_theme") == "dusk", str(j))
        r = client.post(base(a, gid), json={"title": "default"}, headers=ck(ta))
        check("unset -> null keys present", r.json().get("title_font") is None and "bg_theme" in r.json(), r.text)
        reset_limits()
        for bad in BAD_FONT:
            r = client.post(base(a, gid), json={"title": "x", "title_font": bad}, headers=ck(ta))
            if r.status_code != 422:
                check(f"bad font {bad!r} 422", False, str(r.status_code)); break
            reset_limits()
        else:
            check("all bad fonts 422 on create", True)
        for bad in BAD_THEME:
            r = client.post(base(a, gid), json={"title": "x", "bg_theme": bad}, headers=ck(ta))
            if r.status_code != 422:
                check(f"bad theme {bad!r} 422", False, str(r.status_code)); break
            reset_limits()
        else:
            check("all bad themes 422 on create", True)
        r = client.post(base(a, gid), json={"title": "x", "title_font": 5}, headers=ck(ta))
        check("non-string font 422", r.status_code == 422, r.text)
        r = client.put(f"{base(a, gid)}/{aid}", json={"title": "renamed"}, headers=ck(ta))
        check("omitted leaves untouched", r.json().get("title_font") == "lora" and r.json().get("bg_theme") == "dusk", r.text)
        r = client.put(f"{base(a, gid)}/{aid}", json={"title_font": "bebas"}, headers=ck(ta))
        check("update font", r.status_code == 200 and r.json()["title_font"] == "bebas" and r.json()["bg_theme"] == "dusk", r.text)
        r = client.put(f"{base(a, gid)}/{aid}", json={"bg_theme": "nope"}, headers=ck(ta))
        check("update bad theme 422", r.status_code == 422, r.text)
        r = client.put(f"{base(a, gid)}/{aid}", json={"title_font": None}, headers=ck(ta))
        check("null resets font only", r.status_code == 200 and r.json()["title_font"] is None and r.json()["bg_theme"] == "dusk", r.text)
        r = client.get(f"{base(a, gid)}/{aid}", headers=ck(ta))
        check("get returns theme", r.json().get("bg_theme") == "dusk", r.text)
        r = client.get(base(a, gid), headers=ck(ta))
        check("list carries keys", all("title_font" in x and "bg_theme" in x for x in r.json()["announcements"]), r.text)
        r = client.get(f"{base(a, gid)}/latest", headers=ck(ta))
        check("latest carries keys", "bg_theme" in (r.json()["announcement"] or {}), r.text)
        # Flag flipped back off: stored values hidden, never leaked.
        set_flags("off")
        r = client.get(f"{base(a, gid)}/{aid}", headers=ck(ta))
        check("hidden again when flag off", "bg_theme" not in r.json() and "title_font" not in r.json(), r.text)
        set_flags("on")
        r = client.get(f"{base(a, gid)}/{aid}", headers=ck(ta))
        check("stored value survives off/on", r.json().get("bg_theme") == "dusk", r.text)
    finally:
        set_flags("off")
        cleanup([a], [gid] if gid else [])


def main():
    test_unit()
    with TestClient(main_module.app) as client:
        test_migration_and_seed()
        test_flags_off(client)
        test_flags_on(client)
    print(f"\n{'=' * 60}")
    if T.FAILED:
        print(f"RESULT: {len(T.PASSED)} passed, {len(T.FAILED)} FAILED")
        for label, detail in T.FAILED:
            print(f"  X {label} -- {detail}")
        raise SystemExit(1)
    print(f"RESULT: {len(T.PASSED)} passed, 0 failed\nSTATUS: ALL PASS")


if __name__ == "__main__":
    main()
