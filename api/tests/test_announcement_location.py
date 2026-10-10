"""Backend coverage for task 20261010-announcement-location-chat-replies, part A:
optional free-text Location on announcements (flag ``announcement_location``, ships OFF).

Flag off: payload key omitted, non-empty writes 422, blank/null clears accepted.
Flag on: trimmed, capped at 120, control and bidi characters rejected, content filter
applied, clearing works on update, omitted key leaves it untouched, member sees it in
get/list/latest. Reuses the harness helpers of test_group_announcements.py.

Run with: cd api && FS_SCRATCH_PG_PORT=<scratch port> ../.venv/bin/python tests/test_announcement_location.py
"""
import _pathfix  # noqa: F401

import uuid

import test_group_announcements as T
from test_group_announcements import (  # noqa: E402
    DBManager, TestClient, base, check, ck, cleanup, create_group, create_tables,
    main_module, make_paid, signup, sql,
)
import backend.interactions.announcement_extras as ex
import backend.interactions.announcements as ann
from backend.interactions import flags

FLAG = ann.LOCATION_FLAG


def set_flag(state):
    sql("UPDATE feature_flags SET state=%s WHERE name=%s", (state, FLAG))
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


def test_unit():
    print("\n== validator ==")
    check("None -> None", ex.normalize_location(None) is None)
    check("blank -> None", ex.normalize_location("   ") is None and ex.normalize_location("") is None)
    check("trimmed", ex.normalize_location("  123 Main St, Springfield  ") == "123 Main St, Springfield")
    check("unicode and emoji kept", ex.normalize_location("Café du Monde \U0001F4CD") == "Café du Monde \U0001F4CD")
    check("120 chars ok", len(ex.normalize_location("x" * 120)) == 120)
    check("121 chars rejected", raises(ex.normalize_location, "x" * 121))
    for label, v in (("newline", "a\nb"), ("tab", "a\tb"), ("NUL", "a\x00b"), ("DEL", "a\x7fb"), ("CR", "a\rb"),
                     ("RLO bidi override", "abc‮def"), ("isolate", "a⁦b"), ("ESC", "a\x1bb")):
        check(f"{label} rejected", raises(ex.normalize_location, v))
    for v in (5, True, ["a"], {"a": 1}):
        check(f"non-text {v!r} rejected", raises(ex.normalize_location, v))


def test_migration():
    print("\n== migration / seed ==")
    db = DBManager()
    try:
        create_tables(db.cur); create_tables(db.cur); db.conn.commit()
        check("create_tables() twice ok", True)
    finally:
        db.close()
    rows = sql("SELECT data_type, is_nullable FROM information_schema.columns WHERE table_name='group_announcements' "
               "AND column_name='location'", fetch=True)
    check("location column exists, nullable text", rows == [("text", "YES")], str(rows))
    check("flag seeded", len(sql("SELECT 1 FROM feature_flags WHERE name=%s", (FLAG,), fetch=True)) == 1)
    from schema_ddl.flags import SEED_FLAG_NAMES
    check("flag in SEED_FLAG_NAMES", FLAG in SEED_FLAG_NAMES)
    check("flag registered", FLAG in flags._REGISTRY and flags._REGISTRY[FLAG].exposed_in_capabilities)


def test_flag_off(client):
    print("\n== flag off ==")
    set_flag("off")
    a, ta = signup(client, f"lo_off_{uuid.uuid4().hex[:8]}")
    make_paid(a)
    gid = None
    try:
        gid = create_group(client, ta, a, [])
        r = client.post(base(a, gid), json={"title": "plain"}, headers=ck(ta))
        check("plain create 201, no location key", r.status_code == 201 and "location" not in r.json(), r.text)
        aid = r.json()["id"]
        reset_limits()
        r = client.post(base(a, gid), json={"title": "with loc", "location": "Somewhere"}, headers=ck(ta))
        check("create with location 422 while off", r.status_code == 422, r.text)
        reset_limits()
        r = client.put(f"{base(a, gid)}/{aid}", json={"location": "Somewhere"}, headers=ck(ta))
        check("update with location 422 while off", r.status_code == 422, r.text)
        check("nothing stored", sql("SELECT location FROM group_announcements WHERE _id=%s", (aid,), fetch=True) == [(None,)])
        for body in ({"location": None}, {"location": "   "}, {"location": ""}):
            r = client.put(f"{base(a, gid)}/{aid}", json=body, headers=ck(ta))
            check(f"clearing {body!r} accepted while off", r.status_code == 200 and "location" not in r.json(), r.text)
            reset_limits()
        # a stored value survives a flag-off period and stays hidden
        sql("UPDATE group_announcements SET location='Stored place' WHERE _id=%s", (aid,))
        r = client.get(f"{base(a, gid)}/{aid}", headers=ck(ta))
        check("stored value hidden while off", r.status_code == 200 and "location" not in r.json(), r.text)
        r = client.get(base(a, gid), headers=ck(ta))
        check("list hides it while off", all("location" not in x for x in r.json()["announcements"]))
        caps = client.get("/app/capabilities", headers=ck(ta)).json()
        check("capabilities flag false", caps["features"].get(FLAG) is False, str(caps["features"]))
    finally:
        cleanup([a], [gid] if gid else [])


def test_flag_on(client):
    print("\n== flag on ==")
    set_flag("on")
    a, ta = signup(client, f"lo_on_{uuid.uuid4().hex[:8]}")
    b, tb = signup(client, f"lo_on2_{uuid.uuid4().hex[:8]}")
    out, tout = signup(client, f"lo_out_{uuid.uuid4().hex[:8]}")
    make_paid(a)
    gid = None
    try:
        gid = create_group(client, ta, a, [b])
        caps = client.get("/app/capabilities", headers=ck(ta)).json()
        check("capabilities flag true", caps["features"].get(FLAG) is True)
        r = client.post(base(a, gid), json={"title": "party", "location": "  Grace Church, 12 Oak St  "}, headers=ck(ta))
        check("create with location 201, trimmed", r.status_code == 201 and r.json()["location"] == "Grace Church, 12 Oak St", r.text)
        aid = r.json()["id"]
        reset_limits()
        r = client.get(f"{base(b, gid)}/{aid}", headers=ck(tb))
        check("member sees it on get", r.status_code == 200 and r.json()["location"] == "Grace Church, 12 Oak St", r.text)
        r = client.get(base(b, gid), headers=ck(tb))
        check("member sees it in list", r.json()["announcements"][0]["location"] == "Grace Church, 12 Oak St", r.text)
        r = client.get(f"{base(b, gid)}/latest", headers=ck(tb))
        check("chat widget (latest) carries it", (r.json()["announcement"] or {}).get("location") == "Grace Church, 12 Oak St", r.text)
        r = client.get(f"{base(out, gid)}/{aid}", headers=ck(tout))
        check("non-member 403", r.status_code == 403, r.text)

        reset_limits()
        r = client.put(f"{base(a, gid)}/{aid}", json={"title": "renamed"}, headers=ck(ta))
        check("update without the key leaves location untouched", r.status_code == 200 and r.json()["location"] == "Grace Church, 12 Oak St", r.text)
        r = client.put(f"{base(a, gid)}/{aid}", json={"location": "New place"}, headers=ck(ta))
        check("update changes it", r.status_code == 200 and r.json()["location"] == "New place", r.text)
        for label, body in (("too long", {"location": "x" * 121}), ("newline", {"location": "a\nb"}),
                            ("bidi override", {"location": "a‮b"}), ("number", {"location": 5}), ("list", {"location": ["a"]})):
            reset_limits()
            r = client.put(f"{base(a, gid)}/{aid}", json=body, headers=ck(ta))
            check(f"update {label} -> 422", r.status_code == 422, f"{r.status_code} {r.text[:100]}")
        check("rejected writes did not change it", sql("SELECT location FROM group_announcements WHERE _id=%s", (aid,), fetch=True) == [("New place",)])
        reset_limits()
        r = client.post(base(a, gid), json={"title": "bad", "location": "x" * 121}, headers=ck(ta))
        check("create too long -> 422", r.status_code == 422, r.text)

        from backend.moderation.content_filter import ContentRejected, check_clean
        bad = None
        for cand in ("fuck", "shit", "nigger", "cunt"):
            try:
                check_clean(location=cand)
            except ContentRejected:
                bad = cand
                break
        if bad:
            reset_limits()
            r = client.put(f"{base(a, gid)}/{aid}", json={"location": bad}, headers=ck(ta))
            check("content-filtered location on update -> 422", r.status_code == 422, r.text)
            reset_limits()
            r = client.post(base(a, gid), json={"title": "ok", "location": bad}, headers=ck(ta))
            check("content-filtered location on create -> 422", r.status_code == 422, r.text)
        else:
            check("content filter has a rejectable word", False, "none rejected")

        reset_limits()
        r = client.put(f"{base(a, gid)}/{aid}", json={"location": None}, headers=ck(ta))
        check("null clears", r.status_code == 200 and r.json()["location"] is None, r.text)
        reset_limits()
        client.put(f"{base(a, gid)}/{aid}", json={"location": "Back again"}, headers=ck(ta))
        r = client.put(f"{base(a, gid)}/{aid}", json={"location": "   "}, headers=ck(ta))
        check("blank clears", r.status_code == 200 and r.json()["location"] is None, r.text)
        check("cleared in DB", sql("SELECT location FROM group_announcements WHERE _id=%s", (aid,), fetch=True) == [(None,)])
        reset_limits()
        r = client.post(base(a, gid), json={"title": "no loc"}, headers=ck(ta))
        check("create without location: location null when flag on", r.status_code == 201 and r.json()["location"] is None, r.text)
        # only the creator (or group creator) may edit, as before
        r = client.put(f"{base(b, gid)}/{aid}", json={"location": "Hijack"}, headers=ck(tb))
        check("non-author member cannot edit location", r.status_code == 403, r.text)
    finally:
        set_flag("off")
        cleanup([a, b, out], [gid] if gid else [])


def main():
    test_unit()
    with TestClient(main_module.app) as client:
        test_migration()
        test_flag_off(client)
        test_flag_on(client)
    print(f"\n{'=' * 60}")
    if T.FAILED:
        print(f"RESULT: {len(T.PASSED)} passed, {len(T.FAILED)} FAILED")
        for label, detail in T.FAILED:
            print(f"  X {label} -- {detail}")
        raise SystemExit(1)
    print(f"RESULT: {len(T.PASSED)} passed, 0 failed\nSTATUS: ALL PASS")


if __name__ == "__main__":
    main()
