"""Backend coverage for task 20261009-announcements-advanced part E.

Links, gallery, event payment handles (display only), RSVP capacity. All four
flags ship OFF. Reuses the harness helpers of test_group_announcements.py.

Run with: cd api && FS_TEST_PGPORT=<scratch port> ../.venv/bin/python tests/test_announcement_attachments.py
"""
import _pathfix  # noqa: F401

import threading
import uuid

import test_group_announcements as T
from test_group_announcements import (  # noqa: E402
    TestClient, base, check, ck, cleanup, create_group, create_tables, DBManager,
    main_module, make_paid, signup, sql, future,
)
import backend.interactions.announcement_extras as ex
import backend.interactions.announcements as ann
from backend.interactions import flags

FLAGS = (ann.LINKS_FLAG, ann.GALLERY_FLAG, ann.PAYMENTS_FLAG, ann.RSVP_FLAG)


def set_flags(state):
    for name in FLAGS:
        sql("UPDATE feature_flags SET state=%s WHERE name=%s", (state, name))
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
    print("\n== validators ==")
    ok = ex.normalize_links([{"url": "HTTPS://Example.com/a?b=1", "label": " Sign up "}])
    check("scheme lowercased, label trimmed", ok == [{"url": "https://Example.com/a?b=1", "label": "Sign up"}], str(ok))
    check("None/[] -> []", ex.normalize_links(None) == [] and ex.normalize_links([]) == [])
    bad_urls = ["javascript:alert(1)", "data:text/html,hi", "ftp://example.com/x", "example.com", "//example.com",
                "https://", "https://user:pw@example.com", "https://exa mple.com", "https://example.com/\nx",
                "https://localhost", "http://example.com:99999", "x" * 600, "", "file:///etc/passwd",
                "JaVaScRiPt:alert(1)", "https:example.com"]
    for u in bad_urls:
        check(f"bad url {u[:30]!r} rejected", raises(ex.normalize_links, [{"url": u}]))
    check("6 links rejected", raises(ex.normalize_links, [{"url": f"https://a{i}.com"} for i in range(6)]))
    check("extra link key rejected", raises(ex.normalize_links, [{"url": "https://a.com", "x": 1}]))
    check("non-list rejected", raises(ex.normalize_links, "https://a.com"))
    check("long label rejected", raises(ex.normalize_links, [{"url": "https://a.com", "label": "x" * 61}]))
    check("dup links collapse", len(ex.normalize_links([{"url": "https://a.com"}, {"url": "HTTPS://A.com"}])) == 1)

    good = [("venmo", "jane_doe", "@jane_doe"), ("venmo", "@Jane-D1", "@Jane-D1"), ("cashapp", "janeD", "$janeD"),
            ("cashapp", "$janeD", "$janeD"), ("paypal", "janedoe", "janedoe"), ("paypal", "Jane@Ex.com", "jane@ex.com"),
            ("zelle", "jane@ex.com", "jane@ex.com"), ("zelle", "(555) 123-4567", "5551234567"),
            ("zelle", "+1 555-123-4567", "5551234567")]
    for prov, h, want in good:
        got = ex.normalize_payment_handles([{"provider": prov, "handle": h}])
        check(f"{prov} {h!r} ok", got == [{"provider": prov, "handle": want}], str(got))
    bad = [("venmo", "4111111111111111"), ("venmo", "4111 1111 1111 1111"), ("cashapp", "$4111111111111111"),
           ("paypal", "4111-1111-1111-1111"), ("zelle", "4111 1111 1111 1111"), ("zelle", "123456789012"),
           ("zelle", "021000021"), ("zelle", "1234567890123"), ("venmo", "12345678"), ("paypal", "12345678901"),
           ("zelle", "acct 000123456789012"), ("bitcoin", "abc12345"), ("venmo", "a b c d e"), ("venmo", "ab"),
           ("venmo", "x" * 65), ("zelle", "jane@"), ("paypal", "https://paypal.me/x"), ("venmo", ""),
           ("cashapp", "$1abc"), ("venmo", "jane\ndoe"), ("zelle", "5551234")]
    for prov, h in bad:
        check(f"bad {prov} {h[:24]!r} rejected", raises(ex.normalize_payment_handles, [{"provider": prov, "handle": h}]))
    check("dup provider rejected", raises(ex.normalize_payment_handles,
          [{"provider": "venmo", "handle": "jane_doe"}, {"provider": "venmo", "handle": "john_doe"}]))
    check("extra keys rejected", raises(ex.normalize_payment_handles,
          [{"provider": "venmo", "handle": "jane_doe", "note": "x"}]))
    check("missing handle rejected", raises(ex.normalize_payment_handles, [{"provider": "venmo"}]))
    for v in (0, -1, 10000, True, "5", 2.5):
        check(f"capacity {v!r} rejected", raises(ex.normalize_capacity, v))
    check("capacity 1/9999/None ok", ex.normalize_capacity(1) == 1 and ex.normalize_capacity(9999) == 9999
          and ex.normalize_capacity(None) is None)
    check("gallery > 6 rejected", raises(ex.normalize_gallery_keys, ["a"] * 7, lambda k: True))
    check("gallery dupes dropped", ex.normalize_gallery_keys(["a", "a", "b"], lambda k: True) == ["a", "b"])


def test_flags_off(client):
    print("\n== flags off ==")
    set_flags("off")
    a, ta = signup(client, f"at_off_{uuid.uuid4().hex[:8]}")
    make_paid(a)
    gid = None
    try:
        gid = create_group(client, ta, a, [])
        r = client.post(base(a, gid), json={"title": "plain"}, headers=ck(ta))
        check("plain create 201, no part E keys", r.status_code == 201 and not any(
            k in r.json() for k in ("links", "gallery", "is_event", "payment_handles", "capacity", "rsvp_count")), r.text)
        aid = r.json()["id"]
        reset_limits()
        for body in ({"links": [{"url": "https://a.com"}]}, {"gallery_keys": [f"group-announcements/{gid}/{a}/x.jpg"]},
                     {"is_event": True}, {"capacity": 5}):
            r = client.put(f"{base(a, gid)}/{aid}", json=body, headers=ck(ta))
            check(f"update {list(body)[0]} 422 while off", r.status_code == 422, r.text)
        r = client.put(f"{base(a, gid)}/{aid}", json={"links": [], "gallery_keys": None, "is_event": False,
                                                       "payment_handles": [], "capacity": None}, headers=ck(ta))
        check("empty/null clears accepted while off", r.status_code == 200, r.text)
        r = client.post(f"{base(a, gid)}/{aid}/rsvp", headers=ck(ta))
        check("rsvp 404 while off", r.status_code == 404, r.text)
        r = client.get(f"{base(a, gid)}/{aid}/rsvps", headers=ck(ta))
        check("rsvps list 404 while off", r.status_code == 404, r.text)
    finally:
        cleanup([a], [gid] if gid else [])


def test_links_gallery_payments(client):
    print("\n== links / gallery / payments (flags on) ==")
    set_flags("on")
    a, ta = signup(client, f"at_on_{uuid.uuid4().hex[:8]}")
    b, tb = signup(client, f"at_on2_{uuid.uuid4().hex[:8]}")
    out, tout = signup(client, f"at_out_{uuid.uuid4().hex[:8]}")
    make_paid(a)
    gid = None
    deleted = []
    orig = ann.delete_object
    ann.delete_object = lambda k: deleted.append(k)
    try:
        gid = create_group(client, ta, a, [b])
        k1, k2, k3 = (f"group-announcements/{gid}/{a}/{uuid.uuid4()}.jpg" for _ in range(3))
        r = client.post(base(a, gid), json={
            "title": "party", "links": [{"url": "HTTP://example.com/rsvp", "label": "RSVP"}],
            "gallery_keys": [k1, k2], "is_event": True,
            "payment_handles": [{"provider": "venmo", "handle": "jane_doe"}], "capacity": 4}, headers=ck(ta))
        check("create with all part E 201", r.status_code == 201, r.text)
        j = r.json(); aid = j["id"]
        check("links normalized", j["links"] == [{"url": "http://example.com/rsvp", "label": "RSVP"}], str(j["links"]))
        check("gallery keys+urls in order", [g["key"] for g in j["gallery"]] == [k1, k2], str(j["gallery"]))
        check("event + handle echoed", j["is_event"] is True and j["payment_handles"] == [
            {"provider": "venmo", "handle": "@jane_doe"}], str(j))
        check("capacity + rsvp fields", j["capacity"] == 4 and j["rsvp_count"] == 0 and j["rsvp_joined"] is False, str(j))
        reset_limits()
        r = client.get(f"{base(b, gid)}/{aid}", headers=ck(tb))
        check("member sees attachments", r.status_code == 200 and r.json()["links"] and r.json()["payment_handles"], r.text)
        r = client.get(f"{base(out, gid)}/{aid}", headers=ck(tout))
        check("non-member 403", r.status_code == 403, r.text)
        r = client.get(base(a, gid), headers=ck(ta))
        check("list carries part E", r.json()["announcements"][0].get("capacity") == 4, r.text)
        r = client.get(f"{base(a, gid)}/latest", headers=ck(ta))
        check("latest carries part E", (r.json()["announcement"] or {}).get("rsvp_count") == 0, r.text)

        # validation over HTTP
        reset_limits()
        for label, body, code in [
            ("javascript link", {"links": [{"url": "javascript:alert(1)"}]}, 422),
            ("data link", {"links": [{"url": "data:text/html,x"}]}, 422),
            ("6 links", {"links": [{"url": f"https://a{i}.com"} for i in range(6)]}, 422),
            ("links wrong type", {"links": "https://a.com"}, 422),
            ("foreign gallery key", {"gallery_keys": [f"group-announcements/{uuid.uuid4()}/{a}/x.jpg"]}, 403),
            ("traversal gallery key", {"gallery_keys": [f"group-announcements/{gid}/../x.jpg"]}, 403),
            ("7 gallery keys", {"gallery_keys": [f"group-announcements/{gid}/{a}/{i}.jpg" for i in range(7)]}, 422),
            ("card in handle", {"payment_handles": [{"provider": "venmo", "handle": "4111111111111111"}]}, 422),
            ("bad provider", {"payment_handles": [{"provider": "stripe", "handle": "jane_doe"}]}, 422),
            ("capacity 0", {"capacity": 0}, 422),
            ("capacity string", {"capacity": "5"}, 422),
            ("capacity bool", {"capacity": True}, 422),
            ("is_event string", {"is_event": "yes"}, 422),
        ]:
            r = client.put(f"{base(a, gid)}/{aid}", json=body, headers=ck(ta))
            check(f"{label} -> {code}", r.status_code == code, f"{r.status_code} {r.text[:120]}")
            reset_limits()
        r = client.put(f"{base(a, gid)}/{aid}", json={"is_event": False}, headers=ck(ta))
        check("event off drops handles", r.status_code == 200 and r.json()["payment_handles"] == []
              and r.json()["is_event"] is False, r.text)
        r = client.put(f"{base(a, gid)}/{aid}", json={"payment_handles": [{"provider": "venmo", "handle": "jane_doe"}]},
                       headers=ck(ta))
        check("handles without event 422", r.status_code == 422, r.text)
        r = client.put(f"{base(a, gid)}/{aid}", json={"is_event": True, "payment_handles": [
            {"provider": "zelle", "handle": "555-123-4567"}, {"provider": "paypal", "handle": "janedoe"}]}, headers=ck(ta))
        check("event on + 2 handles", r.status_code == 200 and len(r.json()["payment_handles"]) == 2, r.text)
        check("no handle in any log-ish field (stored normalized)", sql(
            "SELECT payment_handles::text FROM group_announcements WHERE _id=%s", (aid,), fetch=True)[0][0].count("5551234567") == 1)

        # gallery edit sweeps removed objects
        r = client.put(f"{base(a, gid)}/{aid}", json={"gallery_keys": [k2, k3]}, headers=ck(ta))
        check("gallery reorder/replace ok", r.status_code == 200 and [g["key"] for g in r.json()["gallery"]] == [k2, k3], r.text)
        check("removed key swept, kept keys not", deleted == [k1], str(deleted))
        # key shared with another announcement is not swept
        reset_limits()
        r2 = client.post(base(a, gid), json={"title": "second", "gallery_keys": [k3]}, headers=ck(ta))
        check("second announcement shares key", r2.status_code == 201, r2.text)
        deleted.clear()
        r = client.put(f"{base(a, gid)}/{aid}", json={"gallery_keys": None}, headers=ck(ta))
        check("clear gallery ok", r.status_code == 200 and r.json()["gallery"] == [], r.text)
        check("shared key kept, unshared swept", deleted == [k2], str(deleted))
        # banner in use by gallery isn't swept
        deleted.clear()
        r = client.put(f"{base(a, gid)}/{r2.json()['id']}", json={"banner_key": k3}, headers=ck(ta))
        r = client.put(f"{base(a, gid)}/{r2.json()['id']}", json={"banner_key": None}, headers=ck(ta))
        check("banner swap respects gallery use", k3 not in deleted, str(deleted))
        # non-host cannot edit part E
        r = client.put(f"{base(b, gid)}/{aid}", json={"links": [{"url": "https://a.com"}]}, headers=ck(tb))
        check("non-host edit 403", r.status_code == 403, r.text)
        # flag off hides stored values
        set_flags("off")
        r = client.get(f"{base(a, gid)}/{aid}", headers=ck(ta))
        check("hidden when flags turned off", not any(k in r.json() for k in (
            "links", "gallery", "payment_handles", "is_event", "capacity", "rsvp_count")), r.text)
        set_flags("on")
    finally:
        ann.delete_object = orig
        set_flags("off")
        cleanup([a, b, out], [gid] if gid else [])


def test_rsvp(client):
    print("\n== RSVP ==")
    set_flags("on")
    reset_limits()
    users = []
    gid = None
    try:
        host, th = signup(client, f"rs_host_{uuid.uuid4().hex[:8]}"); users.append(host)
        make_paid(host)
        mem = []
        for i in range(8):
            u, t = signup(client, f"rs_m{i}_{uuid.uuid4().hex[:6]}"); users.append(u); mem.append((u, t))
        outsider, tout = signup(client, f"rs_out_{uuid.uuid4().hex[:8]}"); users.append(outsider)
        gid = create_group(client, th, host, [u for u, _ in mem])
        r = client.post(base(host, gid), json={"title": "ev", "capacity": 3}, headers=ck(th))
        check("create joinable", r.status_code == 201, r.text)
        aid = r.json()["id"]
        reset_limits()
        plain = client.post(base(host, gid), json={"title": "no cap"}, headers=ck(th)).json()["id"]
        reset_limits()
        (u1, t1), (u2, t2), (u3, t3), (u4, t4) = mem[:4]
        rp = lambda u, t, m="post", a=aid: getattr(client, m)(f"{base(u, gid)}/{a}/rsvp", headers=ck(t))
        r = rp(u1, t1)
        check("join 200 count 1 joined", r.status_code == 200 and r.json()["rsvp_count"] == 1 and r.json()["rsvp_joined"], r.text)
        r = rp(u1, t1)
        check("join idempotent", r.status_code == 200 and r.json()["rsvp_count"] == 1, r.text)
        check("one row", sql("SELECT count(*) FROM group_announcement_rsvps WHERE announcement_id=%s", (aid,), fetch=True)[0][0] == 1)
        r = client.get(f"{base(u2, gid)}/{aid}", headers=ck(t2))
        check("others see count not joined", r.json()["rsvp_count"] == 1 and r.json()["rsvp_joined"] is False, r.text)
        rp(u2, t2); rp(u3, t3)
        r = rp(u4, t4)
        check("full -> 409", r.status_code == 409, r.text)
        check("still 3 rows", sql("SELECT count(*) FROM group_announcement_rsvps WHERE announcement_id=%s", (aid,), fetch=True)[0][0] == 3)
        r = rp(u1, t1)
        check("already-joined member re-join when full still 200", r.status_code == 200, r.text)
        r = rp(u1, t1, "delete")
        check("leave 200 count 2", r.status_code == 200 and r.json()["rsvp_count"] == 2 and not r.json()["rsvp_joined"], r.text)
        r = rp(u1, t1, "delete")
        check("leave idempotent", r.status_code == 200 and r.json()["rsvp_count"] == 2, r.text)
        r = rp(u4, t4)
        check("freed spot joinable", r.status_code == 200 and r.json()["rsvp_count"] == 3, r.text)
        # authz
        r = rp(outsider, tout)
        check("non-member 403", r.status_code == 403, r.text)
        r = rp(host, th, "post", plain)
        check("not joinable 404", r.status_code == 404, r.text)
        r = rp(host, th, "post", str(uuid.uuid4()))
        check("unknown 404", r.status_code == 404, r.text)
        r = client.post(f"{base(u1, gid)}/{aid}/rsvp", headers=ck(th))
        check("spoofed user_id 403", r.status_code == 403, r.text)
        r = client.post(f"{base(u1, gid)}/{aid}/rsvp")
        check("unauthenticated 401", r.status_code == 401, r.text)
        # host list
        r = client.get(f"{base(host, gid)}/{aid}/rsvps", headers=ck(th))
        check("host sees attendee list", r.status_code == 200 and len(r.json()["rsvps"]) == 3
              and {p["user_id"] for p in r.json()["rsvps"]} == {u2, u3, u4}, r.text)
        r = client.get(f"{base(u2, gid)}/{aid}/rsvps", headers=ck(t2))
        check("non-host attendee list 403", r.status_code == 403, r.text)
        r = client.get(f"{base(outsider, gid)}/{aid}/rsvps", headers=ck(tout))
        check("outsider attendee list 403", r.status_code == 403, r.text)
        # capacity guard
        r = client.put(f"{base(host, gid)}/{aid}", json={"capacity": 2}, headers=ck(th))
        check("capacity below RSVPs 422", r.status_code == 422, r.text)
        check("rsvps intact after rejected change", sql("SELECT count(*) FROM group_announcement_rsvps WHERE announcement_id=%s", (aid,), fetch=True)[0][0] == 3)
        r = client.put(f"{base(host, gid)}/{aid}", json={"capacity": 5}, headers=ck(th))
        check("raise capacity ok", r.status_code == 200 and r.json()["capacity"] == 5 and r.json()["rsvp_count"] == 3, r.text)
        # member leaving the group frees the spot
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (u2, gid))
        r = client.get(f"{base(host, gid)}/{aid}", headers=ck(th))
        check("departed member not counted", r.json()["rsvp_count"] == 2, r.text)
        sql("UPDATE groups SET users = users || %s::text WHERE _id=%s", (u2, gid))
        # blocks
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (u1, host))
        r = rp(u1, t1)
        check("blocked relationship with host -> 404", r.status_code == 404, r.text)
        sql("DELETE FROM blocked_users WHERE blocker_id=%s", (u1,))
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (host, u3))
        r = client.get(f"{base(host, gid)}/{aid}/rsvps", headers=ck(th))
        check("host list hides blocked attendee", {p["user_id"] for p in r.json()["rsvps"]} == {u2, u4}, r.text)
        sql("DELETE FROM blocked_users WHERE blocker_id=%s", (host,))
        # scheduled not joinable
        reset_limits()
        r = client.post(base(host, gid), json={"title": "later", "capacity": 2, "publish_at": future()}, headers=ck(th))
        check("scheduled create", r.status_code == 201, r.text)
        r = rp(u1, t1, "post", r.json()["id"])
        check("scheduled not joinable 404", r.status_code == 404, r.text)
        # deleted
        reset_limits()
        client.delete(f"{base(host, gid)}/{aid}", headers=ck(th))
        r = rp(u1, t1)
        check("deleted not joinable 404", r.status_code == 404, r.text)
        client.post(f"{base(host, gid)}/{aid}/restore", headers=ck(th))
        # clear capacity drops RSVPs
        r = client.put(f"{base(host, gid)}/{aid}", json={"capacity": None}, headers=ck(th))
        check("clear capacity ok", r.status_code == 200 and r.json()["capacity"] is None and "rsvp_count" not in r.json(), r.text)
        check("rsvps dropped", sql("SELECT count(*) FROM group_announcement_rsvps WHERE announcement_id=%s", (aid,), fetch=True)[0][0] == 0)
        # membership untouched by RSVP
        before = sql("SELECT users FROM groups WHERE _id=%s", (gid,), fetch=True)[0][0]
        client.put(f"{base(host, gid)}/{aid}", json={"capacity": 8}, headers=ck(th))
        for u, t in mem:
            rp(u, t)
        check("rsvp never changes group membership", sql("SELECT users FROM groups WHERE _id=%s", (gid,), fetch=True)[0][0] == before)
        sql("DELETE FROM group_announcement_rsvps WHERE announcement_id=%s", (aid,))
        # concurrency: 8 joiners, capacity 3
        r = client.put(f"{base(host, gid)}/{aid}", json={"capacity": 3}, headers=ck(th))
        check("set capacity 3 for race", r.status_code == 200, r.text)
        results = []

        def go(uid):
            m = ann.AnnouncementsManager(uid, gid)
            try:
                m.rsvp_join(aid); results.append("ok")
            except ann.AnnouncementFull:
                results.append("full")
            except Exception as e:  # noqa: BLE001
                results.append(f"err:{type(e).__name__}")
            finally:
                m.close()
        ths = [threading.Thread(target=go, args=(u,)) for u, _ in mem]
        [t.start() for t in ths]; [t.join() for t in ths]
        rows = sql("SELECT count(*) FROM group_announcement_rsvps WHERE announcement_id=%s", (aid,), fetch=True)[0][0]
        check("race: exactly capacity rows", rows == 3, f"{rows} {results}")
        check("race: 3 ok 5 full", sorted(results) == ["full"] * 5 + ["ok"] * 3, str(results))
        results.clear()
        sql("DELETE FROM group_announcement_rsvps WHERE announcement_id=%s", (aid,))
        ths = [threading.Thread(target=go, args=(mem[0][0],)) for _ in range(6)]
        [t.start() for t in ths]; [t.join() for t in ths]
        rows = sql("SELECT count(*) FROM group_announcement_rsvps WHERE announcement_id=%s", (aid,), fetch=True)[0][0]
        check("race: same user 6x -> 1 row, all ok", rows == 1 and results == ["ok"] * 6, f"{rows} {results}")
        # cascade on hard delete
        sql("DELETE FROM group_announcements WHERE _id=%s", (aid,))
        check("rsvps cascade", sql("SELECT count(*) FROM group_announcement_rsvps WHERE announcement_id=%s", (aid,), fetch=True)[0][0] == 0)
    finally:
        set_flags("off")
        cleanup(users, [gid] if gid else [])


def test_migration():
    print("\n== migration / seed ==")
    db = DBManager()
    try:
        create_tables(db.cur); create_tables(db.cur); db.conn.commit()
        check("create_tables() twice ok", True)
    finally:
        db.close()
    rows = sql("SELECT column_name FROM information_schema.columns WHERE table_name='group_announcements' "
               "AND column_name IN ('links','gallery_keys','is_event','payment_handles','capacity') ORDER BY 1", fetch=True)
    check("5 columns exist", len(rows) == 5, str(rows))
    pk = sql("SELECT count(*) FROM information_schema.table_constraints WHERE table_name='group_announcement_rsvps' "
             "AND constraint_type='PRIMARY KEY'", fetch=True)[0][0]
    check("rsvp table has composite PK (unique per user)", pk == 1)
    for name in FLAGS:
        check(f"flag {name} seeded", len(sql("SELECT 1 FROM feature_flags WHERE name=%s", (name,), fetch=True)) == 1)


def main():
    test_unit()
    with TestClient(main_module.app) as client:
        test_migration()
        test_flags_off(client)
        test_links_gallery_payments(client)
        test_rsvp(client)
    print(f"\n{'=' * 60}")
    if T.FAILED:
        print(f"RESULT: {len(T.PASSED)} passed, {len(T.FAILED)} FAILED")
        for label, detail in T.FAILED:
            print(f"  X {label} -- {detail}")
        raise SystemExit(1)
    print(f"RESULT: {len(T.PASSED)} passed, 0 failed\nSTATUS: ALL PASS")


if __name__ == "__main__":
    main()
