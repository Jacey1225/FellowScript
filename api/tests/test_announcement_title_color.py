"""Backend coverage for task 20260929-announcement-title-color-crop-layer-fix (testing step 3).

title_color: nullable strict #RRGGBB, uppercased, 422 on anything else,
null on update resets to default, omitted on update leaves untouched.
Reuses the harness helpers of test_group_announcements.py.

Run with: cd api && ../.venv/bin/python tests/test_announcement_title_color.py
"""
import _pathfix  # noqa: F401

import uuid

import test_group_announcements as T
from test_group_announcements import (  # noqa: E402
    DBManager, TestClient, base, check, ck, cleanup, create_group, create_tables,
    main_module, make_paid, signup, sql,
)
import backend.interactions.announcements as ann_module  # noqa: E402

BAD = [
    "#FFF", "#ffff", "FFFFFF", "red", "Red", "rgb(1,2,3)", "#12345", "#1234567", "#GGGGGG",
    "#FFFFFF\n", "\n#FFFFFF", " #FFFFFF", "#FFFFFF ", "#FFFFFF\t", "",
    "#FFFFFF;", "#FFFFFF; background:url(http://evil/x)", "url(http://evil/x)",
    "javascript:alert(1)", "expression(alert(1))", "#FFFFFF}</style><script>alert(1)</script>",
    "#FFFFFF" * 20, "#" + "A" * 500, "#ＦＦＦＦＦＦ",  # fullwidth F
    "#١٢٣٤٥٦",  # arabic-indic digits
    "#FFFFFÉ", "#FFFFFF​", "#FF\x00FFF", "0xFFFFFF",
]


def reset_limits():
    """Route rate limits (30/min) would otherwise 429 the bulk rejection sweep."""
    from backend.rate_limiting import limiter
    limiter.reset()


def test_migration(client):
    print("\n== migration ==")
    db = DBManager()
    try:
        create_tables(db.cur)
        create_tables(db.cur)
        db.conn.commit()
        check("create_tables() twice ok", True)
    except Exception as e:
        db.conn.rollback()
        check("create_tables() twice ok", False, repr(e))
    finally:
        db.close()
    rows = sql("SELECT data_type, is_nullable, column_default, character_maximum_length FROM information_schema.columns "
               "WHERE table_name='group_announcements' AND column_name='title_color'", fetch=True)
    check("title_color column exists, nullable, no default",
          len(rows) == 1 and rows[0][1] == "YES" and rows[0][2] is None, str(rows))
    # Idempotent over pre-existing data: rerunning must not clobber stored values.
    a, ta = signup(client, f"tc_m_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, ta, a, [])
        r = client.post(base(a, gid), json={"title": "keep", "title_color": "#AABBCC"}, headers=ck(ta))
        check("seed create 201", r.status_code == 201, r.text)
        db = DBManager()
        create_tables(db.cur); db.conn.commit(); db.close()
        v = sql("SELECT title_color FROM group_announcements WHERE group_id=%s", (gid,), fetch=True)
        check("migration rerun preserves value", v == [("#AABBCC",)], str(v))
    finally:
        cleanup([a], [gid] if gid else [])


def test_unit():
    print("\n== normalize_title_color unit ==")
    n = ann_module.normalize_title_color
    check("None -> None", n(None) is None)
    check("uppercases", n("#aabbcc") == "#AABBCC")
    check("mixed case", n("#aAbB0c") == "#AABB0C")
    for b in BAD:
        try:
            n(b)
            check(f"rejects {b[:30]!r}", False, "accepted")
        except ValueError:
            check(f"rejects {b[:30]!r}", True)
    for b in (123, ["#FFFFFF"], b"#FFFFFF"):
        try:
            n(b)
            check(f"rejects non-str {type(b).__name__}", False, "accepted")
        except ValueError:
            check(f"rejects non-str {type(b).__name__}", True)


def test_api(client):
    print("\n== API create/update/get/list/latest ==")
    o, to = signup(client, f"tc_o_{uuid.uuid4().hex[:8]}")
    m, tm = signup(client, f"tc_mem_{uuid.uuid4().hex[:8]}")
    x, tx = signup(client, f"tc_x_{uuid.uuid4().hex[:8]}")
    sids = [make_paid(o), make_paid(m)]
    gid = None
    try:
        gid = create_group(client, to, o, [m])
        u = base(o, gid)

        # old client: field omitted
        r = client.post(u, json={"title": "legacy"}, headers=ck(to))
        check("omitted -> 201", r.status_code == 201, r.text)
        check("omitted -> title_color null in response", "title_color" in r.json() and r.json()["title_color"] is None, r.text)
        legacy = r.json()["id"]
        r = client.post(u, json={"title": "explicit null", "title_color": None}, headers=ck(to))
        check("explicit null -> 201/null", r.status_code == 201 and r.json()["title_color"] is None, r.text)

        # valid, lowercase normalized
        r = client.post(u, json={"title": "colored", "title_color": "#c8a24b"}, headers=ck(to))
        check("valid lower -> 201 uppercased", r.status_code == 201 and r.json()["title_color"] == "#C8A24B", r.text)
        cid = r.json()["id"]
        check("stored uppercase in DB",
              sql("SELECT title_color FROM group_announcements WHERE _id=%s", (cid,), fetch=True) == [("#C8A24B",)])

        # get / list / latest carry it
        r = client.get(f"{base(m, gid)}/{cid}", headers=ck(tm))
        check("get carries color (member)", r.status_code == 200 and r.json()["title_color"] == "#C8A24B", r.text)
        r = client.get(base(m, gid), headers=ck(tm))
        body = r.json()
        items = body if isinstance(body, list) else body.get("announcements") or body.get("items") or []
        by = {i["id"]: i for i in items}
        check("list carries color", by.get(cid, {}).get("title_color") == "#C8A24B", r.text[:300])
        check("list legacy has null color", legacy in by and by[legacy].get("title_color") is None, r.text[:300])
        r = client.get(f"{base(m, gid)}/latest", headers=ck(tm))
        lj = r.json()
        lat = lj.get("announcement", lj) if isinstance(lj, dict) else lj
        check("latest 200", r.status_code == 200, r.text)
        check("latest carries title_color key", isinstance(lat, dict) and "title_color" in lat, r.text[:300])

        # update: omitted leaves untouched
        r = client.put(f"{u}/{cid}", json={"title": "colored2"}, headers=ck(to))
        check("update without field keeps color", r.status_code == 200 and r.json()["title_color"] == "#C8A24B", r.text)
        # update: change + uppercase
        r = client.put(f"{u}/{cid}", json={"title_color": "#0a0b0c"}, headers=ck(to))
        check("update changes + uppercases", r.status_code == 200 and r.json()["title_color"] == "#0A0B0C", r.text)
        check("update color-only kept title", r.json()["title"] == "colored2", r.text)
        # update: null resets
        r = client.put(f"{u}/{cid}", json={"title_color": None}, headers=ck(to))
        check("update null resets to default", r.status_code == 200 and r.json()["title_color"] is None, r.text)
        check("DB NULL after reset",
              sql("SELECT title_color FROM group_announcements WHERE _id=%s", (cid,), fetch=True) == [(None,)])
        # legacy row: update of other fields leaves color null
        r = client.put(f"{u}/{legacy}", json={"description": "d"}, headers=ck(to))
        check("legacy update ok, color still null", r.status_code == 200 and r.json()["title_color"] is None, r.text)

        # rejection on create + update; nothing persisted / changed
        client.put(f"{u}/{cid}", json={"title_color": "#112233"}, headers=ck(to))
        before = sql("SELECT count(*) FROM group_announcements WHERE group_id=%s", (gid,), fetch=True)[0][0]
        for b in BAD:
            reset_limits()
            r = client.post(u, json={"title": "bad", "title_color": b}, headers=ck(to))
            check(f"create 422 {b[:25]!r}", r.status_code == 422, f"{r.status_code} {r.text[:120]}")
            r = client.put(f"{u}/{cid}", json={"title_color": b}, headers=ck(to))
            check(f"update 422 {b[:25]!r}", r.status_code == 422, f"{r.status_code} {r.text[:120]}")
        for b in (123, True, ["#FFFFFF"], {"a": 1}):
            r = client.post(u, json={"title": "bad", "title_color": b}, headers=ck(to))
            check(f"create 422 non-string {b!r}", r.status_code == 422, f"{r.status_code}")
        after = sql("SELECT count(*) FROM group_announcements WHERE group_id=%s", (gid,), fetch=True)[0][0]
        check("rejected creates persisted nothing", before == after, f"{before} vs {after}")
        check("rejected updates left value intact",
              sql("SELECT title_color FROM group_announcements WHERE _id=%s", (cid,), fetch=True) == [("#112233",)])
        reset_limits()
        # a bad color together with otherwise valid fields must not partially apply
        r = client.put(f"{u}/{cid}", json={"title": "partial", "title_color": "red"}, headers=ck(to))
        check("mixed valid+invalid update 422", r.status_code == 422, r.text)
        check("no partial apply",
              sql("SELECT title FROM group_announcements WHERE _id=%s", (cid,), fetch=True) == [("colored2",)])

        # authz unchanged
        r = client.put(f"{base(m, gid)}/{cid}", json={"title_color": "#FFFFFF"}, headers=ck(tm))
        check("non-author member cannot recolor -> 403", r.status_code == 403, r.text)
        r = client.post(base(x, gid), json={"title": "n", "title_color": "#FFFFFF"}, headers=ck(tx))
        check("non-member create -> 403", r.status_code == 403, r.text)
        r = client.post(u, json={"title": "n", "title_color": "#FFFFFF"})
        check("unauthenticated create -> 401", r.status_code == 401, r.text)
        check("authz denied calls did not change color",
              sql("SELECT title_color FROM group_announcements WHERE _id=%s", (cid,), fetch=True) == [("#112233",)])
    finally:
        cleanup([o, m, x], [gid] if gid else [], sids)


def main():
    test_unit()
    with TestClient(main_module.app) as client:
        test_migration(client)
        test_api(client)
    P, F = T.PASSED, T.FAILED
    print(f"\n{'=' * 60}")
    if F:
        print(f"RESULT: {len(P)} passed, {len(F)} FAILED")
        for label, detail in F:
            print(f"  X {label} -- {detail}")
        raise SystemExit(1)
    print(f"RESULT: {len(P)} passed, 0 failed\nSTATUS: ALL PASS")


if __name__ == "__main__":
    main()
