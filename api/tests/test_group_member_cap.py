"""Backend coverage for task 20261001-group-invite-permanent-member-cap.

Proves: group links are permanent (NULL expires_at, work long after 7 days);
legacy group links keep their stored expiry; subscription links still expire
(see test_subscription_invites.py); the owner-set member cap
(groups.max_members) is enforced under the group row lock on invite redeem
(including a real thread race for the last seat) and on the PUT member-list
path; set-cap authz (403 non-owner / legacy NULL creator / non-member),
validation (422 bounds, bool/float/string, below current count), clear with
null, group info exposure, preview uniformity for a full group, existing
members idempotent when full; revoke authz for permanent links; config
ceiling validation.

Run with: cd api && ../.venv/bin/python tests/test_group_member_cap.py
"""
import _pathfix  # noqa: F401

import copy
import json
import threading

from test_group_invites import (  # noqa: E402  (sets env + imports the app)
    PASSED, FAILED, check, ck, ip_hdr, signup, uname, mk_group, q, group_users,
    invite_row, cleanup, install, create, preview, redeem, inv, ic, InviteError,
    InvitesManager, main_module, TestClient,
)


def set_cap(client, tok, uid, gid, value):
    return client.put(f"/groups/{uid}/{gid}/max-members", json={"max_members": value},
                      headers={**ck(tok), **ip_hdr()})


def info(client, tok, uid, gid):
    return client.get(f"/groups/{uid}/{gid}/info", headers=ck(tok))


def db_cap(gid):
    return q("SELECT max_members FROM groups WHERE _id = %s", (gid,))[0][0]


def test_permanence(client):
    print("\n== Permanence: group links never expire; legacy links keep expiry ==")
    uc, tc = signup(client, uname())
    uj, tj = signup(client, uname())
    uk, tk = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid, max_uses=5).json()
        check("create returns expires_at null", link["expires_at"] is None, str(link))
        check("DB expires_at NULL", invite_row(link["invite_id"])[4] is None)
        # age the link 400 days: it must still be fully usable
        q("UPDATE invites SET created_at = NOW() - INTERVAL '400 days' WHERE _id = %s", (link["invite_id"],))
        r = preview(client, link["token"])
        check("preview works 400 days later", r.status_code == 200, r.text)
        lst = client.get(f"/invites/{uc}/groups/{gid}", headers={**ck(tc), **ip_hdr()}).json()
        item = [i for i in lst["invites"] if i["invite_id"] == link["invite_id"]]
        check("list includes the old permanent link with expires_at null",
              len(item) == 1 and item[0]["expires_at"] is None, str(lst))
        r = redeem(client, tj, uj, link["token"])
        check("redeem works 400 days later", r.status_code == 200 and r.json()["joined"], r.text)
        check("joiner added", uj in group_users(gid))
        # still counted toward the per-user active-link cap (permanent => only revoke frees it)
        install(max_active_links_per_user_per_group=2)
        create(client, tc, uc, gid)
        r = create(client, tc, uc, gid)
        check("permanent links count toward active cap -> 409 link_limit",
              r.status_code == 409 and r.json()["detail"]["code"] == "link_limit", f"{r.status_code} {r.text}")
        install()

        # legacy link with a future expiry still works then expires
        legacy = create(client, tc, uc, gid, max_uses=5).json()
        q("UPDATE invites SET expires_at = NOW() + INTERVAL '2 days' WHERE _id = %s", (legacy["invite_id"],))
        lst = client.get(f"/invites/{uc}/groups/{gid}", headers={**ck(tc), **ip_hdr()}).json()
        item = [i for i in lst["invites"] if i["invite_id"] == legacy["invite_id"]]
        check("legacy link with future expiry lists an ISO expires_at",
              len(item) == 1 and isinstance(item[0]["expires_at"], str))
        check("legacy unexpired link previews", preview(client, legacy["token"]).status_code == 200)
        q("UPDATE invites SET expires_at = NOW() - INTERVAL '1 second' WHERE _id = %s", (legacy["invite_id"],))
        r = redeem(client, tk, uk, legacy["token"])
        check("legacy link past expiry -> 410 expired",
              r.status_code == 410 and r.json()["detail"]["code"] == "expired", r.text)
        check("legacy expired link preview -> uniform 404", preview(client, legacy["token"]).status_code == 404)
        lst = client.get(f"/invites/{uc}/groups/{gid}", headers={**ck(tc), **ip_hdr()}).json()
        check("legacy expired link vanishes from list",
              legacy["invite_id"] not in {i["invite_id"] for i in lst["invites"]})
        check("expired legacy redeem did not join", uk not in group_users(gid))
    finally:
        cleanup([uc, uj, uk], [gid])


def test_set_cap_authz_and_validation(client):
    print("\n== Set cap: authz (403), validation (422), clear, info exposure ==")
    ceiling = ic.get_invites_config().max_group_members_ceiling
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    uo, to = signup(client, uname())
    gid = mk_group(client, tc, uc, [um])          # 2 members
    legacy = mk_group(client, tc, uc, [um])
    try:
        r = client.put(f"/groups/{uc}/{gid}/max-members", json={"max_members": 5}, headers=ip_hdr())
        check("unauthenticated -> 401", r.status_code == 401, str(r.status_code))
        r = set_cap(client, tm, uc, gid, 5)
        check("spoofed path user id -> 403", r.status_code == 403, str(r.status_code))
        r = set_cap(client, tm, um, gid, 5)
        check("non-owner member -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = set_cap(client, to, uo, gid, 5)
        check("non-member -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        check("rejected attempts changed nothing", db_cap(gid) is None)

        # legacy group: creator_id NULL => nobody can set
        q("UPDATE groups SET creator_id = NULL WHERE _id = %s", (legacy,))
        r = set_cap(client, tc, uc, legacy, 5)
        check("legacy NULL creator_id group -> 403 even for ex-creator", r.status_code == 403, f"{r.status_code} {r.text}")
        r = set_cap(client, tm, um, legacy, 5)
        check("legacy NULL creator_id group -> 403 for member", r.status_code == 403)
        check("legacy group cap untouched", db_cap(legacy) is None)

        # validation
        for label, val in [("below floor (1)", 1), ("zero", 0), ("negative", -3),
                           (f"above ceiling ({ceiling + 1})", ceiling + 1)]:
            r = set_cap(client, tc, uc, gid, val)
            check(f"{label} -> 422", r.status_code == 422, f"{r.status_code} {r.text}")
        for label, val in [("bool true", True), ("float 5.5", 5.5), ("string '5'", "5")]:
            r = set_cap(client, tc, uc, gid, val)
            check(f"{label} -> 422 (strict int)", r.status_code == 422, f"{r.status_code} {r.text}")
        check("422s left cap NULL", db_cap(gid) is None)

        # below current count: add a third member first
        ux, tx = signup(client, uname())
        link = create(client, tc, uc, gid, max_uses=5).json()
        check("third member joins", redeem(client, tx, ux, link["token"]).status_code == 200)
        r = set_cap(client, tc, uc, gid, 2)
        check("cap below current member count (3) -> 422", r.status_code == 422, f"{r.status_code} {r.text}")
        check("cap unchanged after below-count rejection", db_cap(gid) is None)
        r = set_cap(client, tc, uc, gid, 3)
        check("cap == current count allowed", r.status_code == 200 and r.json()["max_members"] == 3, r.text)
        r = set_cap(client, tc, uc, gid, ceiling)
        check("cap == ceiling allowed", r.status_code == 200 and db_cap(gid) == ceiling)

        # info exposure
        r = info(client, tm, um, gid)
        j = r.json()
        check("info exposes max_members/member_count/is_owner/ceiling for member",
              r.status_code == 200 and j["max_members"] == ceiling and j["member_count"] == 3
              and j["is_owner"] is False and j["max_members_ceiling"] == ceiling, r.text)
        j = info(client, tc, uc, gid).json()
        check("info is_owner true for creator", j["is_owner"] is True)

        # clear with null
        r = set_cap(client, tc, uc, gid, None)
        check("null clears cap", r.status_code == 200 and r.json()["max_members"] is None and db_cap(gid) is None, r.text)
        check("info shows cleared cap", info(client, tc, uc, gid).json()["max_members"] is None)
        r = client.put(f"/groups/{uc}/{gid}/max-members", json={}, headers={**ck(tc), **ip_hdr()})
        check("omitted max_members behaves as clear", r.status_code == 200 and db_cap(gid) is None)
    finally:
        cleanup([uc, um, uo, ux], [gid, legacy])


def test_cap_enforced_on_redeem(client):
    print("\n== Cap enforcement on invite redeem ==")
    uc, tc = signup(client, uname())
    u1, t1 = signup(client, uname())
    u2, t2 = signup(client, uname())
    uo, to = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid, max_uses=10).json()
        check("set cap 2", set_cap(client, tc, uc, gid, 2).status_code == 200)
        r = redeem(client, t1, u1, link["token"])
        check("join to reach cap (creator + 1 = 2) ok", r.status_code == 200 and r.json()["joined"], r.text)
        r = redeem(client, t2, u2, link["token"])
        check("join when full -> 409 group_full", r.status_code == 409 and r.json()["detail"]["code"] == "group_full", r.text)
        check("full group did not add member", u2 not in group_users(gid) and len(group_users(gid)) == 2)
        check("rejected join consumed no use", invite_row(link["invite_id"])[1] == 1)
        r = redeem(client, t1, u1, link["token"])
        check("existing member redeem still idempotent 200 when full",
              r.status_code == 200 and r.json()["already_member"] and not r.json()["joined"], r.text)
        r = redeem(client, tc, uc, link["token"])
        check("creator redeem own link idempotent when full", r.status_code == 200 and r.json()["already_member"])
        r = preview(client, link["token"])
        unknown = preview(client, inv.generate_token())
        check("preview of full group -> uniform 404 identical to unknown token",
              r.status_code == 404 and r.text == unknown.text, f"{r.status_code} {r.text}")
        check("full-group preview does not leak cap", "max" not in r.text.lower() and "full" not in r.text.lower())
        # raise the cap -> joins work again; clearing too
        set_cap(client, tc, uc, gid, 3)
        check("preview works again with free seat", preview(client, link["token"]).status_code == 200)
        r = redeem(client, t2, u2, link["token"])
        check("join after cap raised ok", r.status_code == 200 and u2 in group_users(gid))
        set_cap(client, tc, uc, gid, None)
        r = redeem(client, to, uo, link["token"])
        check("join after cap cleared ok", r.status_code == 200 and uo in group_users(gid))
    finally:
        cleanup([uc, u1, u2, uo], [gid])


def test_cap_race(client):
    print("\n== Cap vs redeem: real threads racing the last seats under the row lock ==")
    uc, tc = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    joiners = [signup(client, uname())[0] for _ in range(10)]
    try:
        link = create(client, tc, uc, gid, max_uses=25).json()
        check("cap 4 (creator + 3 seats)", set_cap(client, tc, uc, gid, 4).status_code == 200)
        barrier = threading.Barrier(len(joiners))
        results, lock = [], threading.Lock()

        def worker(uid):
            m = InvitesManager(uid)
            try:
                barrier.wait()
                m.redeem(link["token"])
                out = "won"
            except InviteError as e:
                out = e.code
            except Exception as e:  # noqa: BLE001
                out = f"exc:{type(e).__name__}:{e}"
            finally:
                m.close()
            with lock:
                results.append(out)

        ts = [threading.Thread(target=worker, args=(u,)) for u in joiners]
        [t.start() for t in ts]
        [t.join() for t in ts]
        check("exactly 3 winners", results.count("won") == 3, str(results))
        check("all losers got group_full", results.count("group_full") == 7, str(results))
        users = group_users(gid)
        check("member count never exceeds cap (== 4)", len(users) == 4 and len(set(users)) == 4, str(len(users)))
        check("use_count == 3 (rejected joins consumed nothing)", invite_row(link["invite_id"])[1] == 3)
    finally:
        cleanup([uc, *joiners], [gid])


def test_cap_race_vs_set_cap(client):
    print("\n== set-cap racing a redeem: never ends above the cap ==")
    uc, tc = signup(client, uname())
    joiners = [signup(client, uname())[0] for _ in range(6)]
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid, max_uses=25).json()
        barrier = threading.Barrier(len(joiners) + 1)
        outs, lock = [], threading.Lock()

        def joiner(uid):
            m = InvitesManager(uid)
            try:
                barrier.wait()
                m.redeem(link["token"])
            except InviteError:
                pass
            finally:
                m.close()

        def setter():
            barrier.wait()
            r = set_cap(client, tc, uc, gid, 3)
            with lock:
                outs.append(r.status_code)

        ts = [threading.Thread(target=joiner, args=(u,)) for u in joiners] + [threading.Thread(target=setter)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        users = group_users(gid)
        cap = db_cap(gid)
        # Either set-cap won first (cap 3 => members <= 3) or it lost the lock
        # after >3 joined and was rejected 422 (cap stays NULL).
        ok = (cap == 3 and len(users) <= 3) or (cap is None and outs == [422])
        check("invariant: members <= cap whenever a cap exists", ok, f"cap={cap} members={len(users)} set={outs}")
    finally:
        cleanup([uc, *joiners], [gid])


def test_put_member_list_cap(client):
    print("\n== PUT /groups/{uid}/{gid} member-list path honors the cap ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    ua, _ = signup(client, uname())
    ub, _ = signup(client, uname())
    gid = mk_group(client, tc, uc, [um])      # 2 members
    try:
        def put(users, tok=tc, uid=uc, title="Invite group"):
            return client.put(f"/groups/{uid}/{gid}", json={"group_id": gid, "title": title, "users": users},
                              headers={**ck(tok), **ip_hdr()})
        set_cap(client, tc, uc, gid, 3)
        r = put([uc, um, ua])
        check("PUT adding up to cap (3) ok", r.status_code in (200, 204) and ua in group_users(gid), f"{r.status_code} {r.text}")
        r = put([uc, um, ua, ub])
        check("PUT adding past cap -> 409 group_full",
              r.status_code == 409 and r.json()["detail"]["code"] == "group_full", f"{r.status_code} {r.text}")
        check("rejected PUT left members unchanged", sorted(group_users(gid)) == sorted([uc, um, ua]))
        r = put([uc, um, ua], title="Renamed")
        check("PUT at cap with no additions (rename) ok", r.status_code in (200, 204), f"{r.status_code} {r.text}")
        r = put([uc, um])
        check("PUT removal while at cap ok", r.status_code in (200, 204) and ua not in group_users(gid))
        r = put([uc, um, ua, uc, ua])
        check("PUT with duplicate ids counts distinct members (3 <= cap)", r.status_code in (200, 204), f"{r.status_code} {r.text}")
        set_cap(client, tc, uc, gid, None)
        r = put([uc, um, ua, ub])
        check("PUT past former cap ok once cleared", r.status_code in (200, 204) and ub in group_users(gid), f"{r.status_code} {r.text}")
    finally:
        cleanup([uc, um, ua, ub], [gid])


def test_revoke_authz_permanent(client):
    print("\n== Revoke authz on permanent links ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    um2, tm2 = signup(client, uname())
    uo, to = signup(client, uname())
    gid = mk_group(client, tc, uc, [um, um2])
    try:
        mine = create(client, tm, um, gid).json()
        other = create(client, tm2, um2, gid).json()
        check("permanent link", mine["expires_at"] is None)
        r = client.delete(f"/invites/{um}/{other['invite_id']}", headers={**ck(tm), **ip_hdr()})
        check("member cannot revoke another member's permanent link -> 403", r.status_code == 403, str(r.status_code))
        check("link still live", invite_row(other["invite_id"])[3] is None)
        r = client.delete(f"/invites/{uo}/{mine['invite_id']}", headers={**ck(to), **ip_hdr()})
        check("outsider revoke -> 404", r.status_code == 404, str(r.status_code))
        r = client.delete(f"/invites/{um}/{mine['invite_id']}", headers={**ck(tm), **ip_hdr()})
        check("creator-of-link revokes own permanent link -> 204", r.status_code == 204 and invite_row(mine["invite_id"])[3] is not None)
        r = client.delete(f"/invites/{uc}/{other['invite_id']}", headers={**ck(tc), **ip_hdr()})
        check("group owner revokes a member's permanent link -> 204", r.status_code == 204 and invite_row(other["invite_id"])[3] is not None)
        uj, tj = signup(client, uname())
        r = redeem(client, tj, uj, mine["token"])
        check("revoked permanent link -> 410 revoked", r.status_code == 410 and r.json()["detail"]["code"] == "revoked", r.text)
        check("revoked permanent link preview -> 404", preview(client, mine["token"]).status_code == 404)
        cleanup([uj], [])
    finally:
        cleanup([uc, um, um2, uo], [gid])


def test_config_ceiling():
    print("\n== Config: max_group_members_ceiling eagerly validated, no default ==")
    good = json.loads(open(ic.CONFIG_PATH).read())

    def bad(mut, label):
        raw = copy.deepcopy(good)
        mut(raw)
        try:
            ic.parse_invites_config(raw)
            check(label, False, "accepted")
        except ic.InvitesConfigError:
            check(label, True)

    check("shipped ceiling parses and is >= 2",
          ic.parse_invites_config(copy.deepcopy(good)).max_group_members_ceiling >= 2)
    bad(lambda r: r.pop("max_group_members_ceiling"), "missing ceiling rejected (no implicit default)")
    bad(lambda r: r.update(max_group_members_ceiling=1), "ceiling below floor 2 rejected")
    bad(lambda r: r.update(max_group_members_ceiling=0), "ceiling 0 rejected")
    bad(lambda r: r.update(max_group_members_ceiling=True), "bool ceiling rejected")
    bad(lambda r: r.update(max_group_members_ceiling="250"), "string ceiling rejected")
    bad(lambda r: r.update(max_group_members_ceiling=2.5), "float ceiling rejected")
    # deprecated group expiry keys are still accepted (no boot break) but ignored
    raw = copy.deepcopy(good)
    raw["default_expiry_days"] = good["allowed_expiry_days"][0]
    check("deprecated group expiry keys still accepted at load", ic.parse_invites_config(raw) is not None)
    check("shipped config leaves enabled flag a bool", isinstance(good["enabled"], bool))


def main():
    test_config_ceiling()
    with TestClient(main_module.app) as client:
        install()
        test_permanence(client)
        test_set_cap_authz_and_validation(client)
        test_cap_enforced_on_redeem(client)
        test_cap_race(client)
        test_cap_race_vs_set_cap(client)
        test_put_member_list_cap(client)
        test_revoke_authz_permanent(client)
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
