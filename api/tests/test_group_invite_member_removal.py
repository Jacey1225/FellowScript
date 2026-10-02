"""Backend coverage for task 20261002-revoke-leaving-member-invite-links.

Proves: when a member leaves a group (creator included) or is dropped by the
PUT member-list replace, every still-active kind='group' link they created for
that group is revoked in the same transaction; other members' links, links of
other groups and kind='subscription' links are untouched; leave/PUT/revoke are
idempotent; last-member leave and group delete purge links; a failing revoke
rolls the membership change back (fail closed); a concurrent redeem vs leave
is deterministic (never a live link past the departure); revoked links give
the uniform not_found and rejoining does not resurrect them; and the
create_tables backfill revokes only active group links whose creator is not in
groups.users (NULL users included), is idempotent, and create_tables can run
twice.

Run with: cd api && ../.venv/bin/python tests/test_group_invite_member_removal.py
"""
import _pathfix  # noqa: F401

import threading
import time
import uuid

import psycopg2 as sql

from test_group_invites import (  # noqa: E402  (sets env + imports the app)
    PASSED, FAILED, check, ck, ip_hdr, signup, uname, mk_group, q, group_users,
    cleanup, install, create, preview, redeem, inv, db_module, DBManager,
    main_module, TestClient, ic,
)
from backend.errors import SaveFailedError  # noqa: E402
from backend.interactions.groups import GroupsManager  # noqa: E402
from schemas.message import Group  # noqa: E402


def leave(client, tok, uid, gid):
    return client.post(f"/groups/{uid}/{gid}/leave", headers=ck(tok))


def put_users(client, tok, uid, gid, users, title="Invite group"):
    return client.put(f"/groups/{uid}/{gid}", json={"group_id": gid, "title": title, "users": users},
                      headers={**ck(tok), **ip_hdr()})


def active_count(gid, uid, kind="group"):
    return q("SELECT COUNT(*) FROM invites WHERE kind = %s AND target_id = %s AND created_by = %s "
             "AND revoked_at IS NULL", (kind, gid, uid))[0][0]


def is_revoked(invite_id):
    return q("SELECT revoked_at IS NOT NULL FROM invites WHERE _id = %s", (invite_id,))[0][0]


def seed_invite(kind, target_id, created_by, revoked=False):
    iid = str(uuid.uuid4())
    q("INSERT INTO invites (_id, token_hash, kind, target_id, created_by, expires_at, max_uses, revoked_at) "
      "VALUES (%s, %s, %s, %s, %s, %s, 5, %s)",
      (iid, uuid.uuid4().hex + uuid.uuid4().hex, kind, target_id, created_by,
       None if kind == "group" else "2099-01-01", "2020-01-01" if revoked else None))
    return iid


def test_leave_revokes_own_links(client):
    print("\n== Leave revokes the leaver's group links only ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    uo, to = signup(client, uname())
    gid = mk_group(client, tc, uc, [um, uo])
    other = mk_group(client, tm, um, [])
    try:
        m1 = create(client, tm, um, gid).json()
        m2 = create(client, tm, um, gid).json()
        c1 = create(client, tc, uc, gid).json()
        o1 = create(client, to, uo, gid).json()
        m_other = create(client, tm, um, other).json()
        sub = seed_invite("subscription", gid, um)
        r = leave(client, tm, um, gid)
        check("leave -> 204", r.status_code == 204, f"{r.status_code} {r.text}")
        check("member removed", um not in group_users(gid))
        check("both leaver links revoked", is_revoked(m1["invite_id"]) and is_revoked(m2["invite_id"]))
        check("creator link untouched", not is_revoked(c1["invite_id"]))
        check("other member link untouched", not is_revoked(o1["invite_id"]))
        check("leaver link in a different group untouched", not is_revoked(m_other["invite_id"]))
        check("subscription-kind link untouched", not is_revoked(sub))
        # revoked links: uniform not_found on preview and redeem
        r = preview(client, m1["token"])
        check("revoked link preview -> uniform 404", r.status_code == 404, r.text)
        ux, tx = signup(client, uname())
        r = redeem(client, tx, ux, m1["token"])
        check("revoked link redeem -> same 410 revoked as any revoked link", r.status_code == 410 and r.json()["detail"]["code"] == "revoked", r.text)
        check("redeem did not join", ux not in group_users(gid))
        # other links still work
        check("surviving creator link still previews", preview(client, c1["token"]).status_code == 200)
        # idempotent: leaving again is a no-op on links (route may 403 non-member)
        leave(client, tm, um, gid)
        check("repeat leave leaves others untouched", not is_revoked(c1["invite_id"]) and not is_revoked(o1["invite_id"]))
        check("repeat revoke helper on no active links returns 0", _helper_revoke(gid, [um]) == 0)
        # rejoin via another link does not resurrect old link
        r = redeem(client, tm, um, c1["token"])
        check("leaver rejoins via creator link", r.status_code == 200 and um in group_users(gid), r.text)
        check("old links stay revoked after rejoin", is_revoked(m1["invite_id"]) and is_revoked(m2["invite_id"]))
        check("old link still not_found after rejoin", preview(client, m1["token"]).status_code == 404)
        cleanup([ux], [])
    finally:
        cleanup([uc, um, uo], [gid, other])


def _helper_revoke(gid, ids):
    db = DBManager()
    try:
        n = inv.revoke_member_group_invites(db.cur, gid, ids)
        db.conn.commit()
        return n
    finally:
        db.close()


def test_creator_leave_revokes(client):
    print("\n== Creator leaving revokes the creator's links (Decision 2) ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    gid = mk_group(client, tc, uc, [um])
    try:
        c1 = create(client, tc, uc, gid).json()
        m1 = create(client, tm, um, gid).json()
        r = leave(client, tc, uc, gid)
        check("creator leave -> 204", r.status_code == 204, r.text)
        check("creator link revoked", is_revoked(c1["invite_id"]))
        check("remaining member link untouched", not is_revoked(m1["invite_id"]))
        check("group survives with the member", group_users(gid) == [um])
    finally:
        cleanup([uc, um], [gid])


def test_last_member_and_delete_purge(client):
    print("\n== Last-member leave and group delete purge links ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    g1 = mk_group(client, tc, uc, [])
    g2 = mk_group(client, tc, uc, [um])
    try:
        l1 = create(client, tc, uc, g1).json()
        r = leave(client, tc, uc, g1)
        check("last-member leave -> 204", r.status_code == 204)
        check("group deleted", group_users(g1) is None)
        check("links purged with group", q("SELECT COUNT(*) FROM invites WHERE target_id = %s", (g1,))[0][0] == 0)
        check("purged link preview uniform 404", preview(client, l1["token"]).status_code == 404)
        l2 = create(client, tc, uc, g2).json()
        sub = seed_invite("subscription", g2, uc)
        r = client.delete(f"/groups/{uc}/{g2}", headers=ck(tc))
        check("owner delete -> 204", r.status_code == 204, f"{r.status_code} {r.text}")
        check("deleted group's group link unusable",
              preview(client, l2["token"]).status_code == 404
              and q("SELECT COUNT(*) FROM invites WHERE _id = %s", (l2["invite_id"],))[0][0] == 0)
        check("subscription-kind row not purged by group delete", q("SELECT COUNT(*) FROM invites WHERE _id = %s", (sub,))[0][0] == 1)
    finally:
        q("DELETE FROM invites WHERE kind = 'subscription' AND created_by = %s", (uc,))
        cleanup([uc, um], [g1, g2])


def test_put_replace(client):
    print("\n== PUT member-list replace revokes only dropped members' links ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    ud, td = signup(client, uname())
    gid = mk_group(client, tc, uc, [um, ud])
    try:
        cl = create(client, tc, uc, gid).json()
        ml = create(client, tm, um, gid).json()
        dl = create(client, td, ud, gid).json()
        sub = seed_invite("subscription", gid, ud)
        r = put_users(client, tc, uc, gid, [uc, um])
        check("PUT dropping a member ok", r.status_code in (200, 204), f"{r.status_code} {r.text}")
        check("dropped member's link revoked", is_revoked(dl["invite_id"]))
        check("retained member's link kept", not is_revoked(ml["invite_id"]))
        check("creator's link kept", not is_revoked(cl["invite_id"]))
        check("subscription row of dropped member untouched", not is_revoked(sub))
        r = put_users(client, tc, uc, gid, [uc, um], title="Renamed")
        check("rename-only PUT is a no-op for links", r.status_code in (200, 204) and not is_revoked(ml["invite_id"]))
        r = put_users(client, tc, uc, gid, [uc, um, ud])
        check("re-adding does not resurrect", r.status_code in (200, 204) and is_revoked(dl["invite_id"]))
        check("dropped link still uniform 404", preview(client, dl["token"]).status_code == 404)
    finally:
        q("DELETE FROM invites WHERE kind = 'subscription' AND created_by = %s", (ud,))
        cleanup([uc, um, ud], [gid])


def test_rollback_on_revoke_failure(client):
    print("\n== Revoke failure rolls the membership change back (fail closed) ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    ud, td = signup(client, uname())
    gid = mk_group(client, tc, uc, [um, ud])
    real = inv.revoke_member_group_invites

    def boom(cur, group_id, member_ids):
        # do a real write first so a missing rollback would be visible
        real(cur, group_id, member_ids)
        raise sql.Error("simulated revoke failure")

    try:
        ml = create(client, tm, um, gid).json()
        dl = create(client, td, ud, gid).json()
        inv.revoke_member_group_invites = boom
        mgr = GroupsManager(um, gid)
        try:
            raised = False
            try:
                mgr.leave_group()
            except SaveFailedError:
                raised = True
        finally:
            mgr.close()
        check("leave raises SaveFailedError", raised)
        check("membership unchanged after failed leave", um in group_users(gid))
        check("link still active after failed leave", not is_revoked(ml["invite_id"]))

        mgr = GroupsManager(uc, gid)
        try:
            raised = False
            try:
                mgr.update_group(Group(group_id=gid, title="x", users=[uc, um]))
            except SaveFailedError:
                raised = True
        finally:
            mgr.close()
        check("PUT raises SaveFailedError", raised)
        check("membership unchanged after failed PUT", sorted(group_users(gid)) == sorted([uc, um, ud]))
        check("title unchanged after failed PUT", q("SELECT title FROM groups WHERE _id = %s", (gid,))[0][0] == "Invite group")
        check("dropped member link still active after failed PUT", not is_revoked(dl["invite_id"]))
    finally:
        inv.revoke_member_group_invites = real
        cleanup([uc, um, ud], [gid])


def test_concurrent_redeem_vs_leave(client):
    print("\n== Concurrent redeem vs leave (deterministic ordering via the groups lock) ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    uj, tj = signup(client, uname())
    gid = mk_group(client, tc, uc, [um])
    holder = DBManager()
    try:
        link = create(client, tm, um, gid, max_uses=5).json()
        # Hold the groups row lock; start leave (must block behind it) ...
        holder.cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (gid,))
        res = {}

        def do_leave():
            res["leave"] = leave(client, tm, um, gid)
        t = threading.Thread(target=do_leave)
        t.start()
        time.sleep(0.5)
        check("leave blocks on the groups row lock", t.is_alive())
        holder.conn.commit()  # release
        t.join(10)
        check("leave completed 204", res["leave"].status_code == 204, res["leave"].text)
        # redeem arriving after the leave must not get a live link
        r = redeem(client, tj, uj, link["token"])
        check("redeem after leave -> 410 revoked", r.status_code == 410 and r.json()["detail"]["code"] == "revoked", r.text)
        check("joiner not added", uj not in group_users(gid))

        # Opposite order: redeem commits first, then leave still revokes the link
        um2, tm2 = signup(client, uname())
        link2 = create(client, tc, uc, gid, max_uses=5).json()
        # make uc the leaver this time
        r = redeem(client, tm2, um2, link2["token"])
        check("redeem before leave joins", r.status_code == 200 and um2 in group_users(gid), r.text)
        r = leave(client, tc, uc, gid)
        check("then leave 204", r.status_code == 204)
        check("link revoked after redeem+leave", is_revoked(link2["invite_id"]))
        ux, tx = signup(client, uname())
        r = redeem(client, tx, ux, link2["token"])
        check("no live link left after leave", r.status_code == 410 and ux not in group_users(gid), r.text)
        cleanup([um2, ux], [])
    finally:
        holder.close()
        cleanup([uc, um, uj], [gid])


def test_backfill():
    print("\n== Backfill: revokes only departed creators' active group links ==")
    # Real rows seeded here (dev DB has no active group links of its own).
    uin, uout, unull = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
    ids = {}
    try:
        for u in (uin, uout, unull):
            nm = f"bf_{u[:10]}"
            q("INSERT INTO users (_id, username, email, hash_pass) VALUES (%s, %s, %s, 'x')", (u, nm, nm + "@example.com"))
        g_in = str(uuid.uuid4())      # uin is a member
        g_out = str(uuid.uuid4())     # uout created a link but is not in users
        g_null = str(uuid.uuid4())    # users NULL
        for g, users in ((g_in, [uin]), (g_out, [uin]), (g_null, None)):
            q("INSERT INTO groups (_id, title, users) VALUES (%s, 'bf', %s)", (g, users))
        ids["keep_member"] = seed_invite("group", g_in, uin)
        ids["revoke_departed"] = seed_invite("group", g_out, uout)
        ids["revoke_null_users"] = seed_invite("group", g_null, unull)
        ids["revoke_missing_group"] = seed_invite("group", str(uuid.uuid4()), uout)
        ids["keep_sub_departed"] = seed_invite("subscription", g_out, uout)
        ids["keep_already_revoked"] = seed_invite("group", g_out, uout, revoked=True)
        before_ts = q("SELECT revoked_at FROM invites WHERE _id = %s", (ids["keep_already_revoked"],))[0][0]

        db = DBManager()
        try:
            n1 = db_module.backfill_revoke_departed_group_invites(db.cur)
            db.conn.commit()
        finally:
            db.close()
        check("backfill revoked at least the 3 departed active rows", n1 >= 3, str(n1))
        check("member's link kept", not is_revoked(ids["keep_member"]))
        check("departed creator's link revoked", is_revoked(ids["revoke_departed"]))
        check("NULL users group link revoked", is_revoked(ids["revoke_null_users"]))
        check("missing-group link revoked", is_revoked(ids["revoke_missing_group"]))
        check("subscription-kind row untouched", not is_revoked(ids["keep_sub_departed"]))
        check("already-revoked row timestamp unchanged",
              q("SELECT revoked_at FROM invites WHERE _id = %s", (ids["keep_already_revoked"],))[0][0] == before_ts)
        snap = q("SELECT _id::text, revoked_at FROM invites WHERE _id = ANY(%s::uuid[])", (list(ids.values()),))
        db = DBManager()
        try:
            n2 = db_module.backfill_revoke_departed_group_invites(db.cur)
            db.conn.commit()
        finally:
            db.close()
        snap2 = q("SELECT _id::text, revoked_at FROM invites WHERE _id = ANY(%s::uuid[])", (list(ids.values()),))
        check("re-run revokes 0 rows and changes nothing", n2 == 0 and sorted(snap) == sorted(snap2), str(n2))

        # create_tables twice is safe and re-runs the backfill harmlessly
        db = DBManager()
        try:
            db_module.create_tables(db.cur)
            db_module.create_tables(db.cur)
            db.conn.commit()
        finally:
            db.close()
        check("create_tables x2 ok; member's link still active", not is_revoked(ids["keep_member"]))
    finally:
        q("DELETE FROM invites WHERE _id = ANY(%s::uuid[])", (list(ids.values()),))
        q("DELETE FROM groups WHERE title = 'bf' AND (users IS NULL OR %s = ANY(users))", (uin,))
        for u in (uin, uout, unull):
            q("DELETE FROM users WHERE _id = %s", (u,))


def main():
    test_backfill()
    with TestClient(main_module.app) as client:
        install()
        test_leave_revokes_own_links(client)
        test_creator_leave_revokes(client)
        test_last_member_and_delete_purge(client)
        test_put_replace(client)
        test_rollback_on_revoke_failure(client)
        test_concurrent_redeem_vs_leave(client)
        ic.set_invites_config_for_tests(None)

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
