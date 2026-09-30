"""Backend coverage for task 20260929-group-invite-links (phase 1).

Proves: migration idempotency; token entropy/format and hash-only storage
(plaintext never persisted or logged); create / list / revoke / preview /
redeem behavior and authorization; atomic max_uses under a real thread race;
blocked-pair rejection in both directions; uniform not-found; rate limiting;
feature flag off => uniform 404; purge on group delete / last-member leave;
strict config validation; token only accepted in POST bodies.

Run with: cd api && ../.venv/bin/python tests/test_group_invites.py
"""
import _pathfix  # noqa: F401

import base64
import copy
import hashlib
import json
import logging
import os
import threading
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import db as db_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.interactions import invites as inv  # noqa: E402
from backend.interactions import invites_config as ic  # noqa: E402
from backend.interactions.invites import InviteError, InvitesManager  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def ck(tok):
    return {"cookie": f"session={tok}"} if tok else {}


def ip_hdr():
    return {"cf-connecting-ip": f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"}


def signup(client, name):
    r = client.post("/signup", json={
        "username": name, "email": f"{name}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True}, headers=ip_hdr())
    assert r.status_code == 201, f"signup failed {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def uname():
    return f"iv_{uuid.uuid4().hex[:10]}"


def mk_group(client, tok, owner, members, title="Invite group"):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner}", json={"group_id": gid, "title": title,
                                               "users": [owner, *members]}, headers=ck(tok))
    assert r.status_code == 201, f"{r.status_code} {r.text}"
    return gid


def q(sql, params=()):
    db = DBManager()
    try:
        db.cur.execute(sql, params)
        try:
            rows = db.cur.fetchall()
        except Exception:
            rows = None
        db.conn.commit()
        return rows
    finally:
        db.close()


def group_users(gid):
    r = q("SELECT users FROM groups WHERE _id = %s", (gid,))
    return r[0][0] if r else None


def invite_row(invite_id):
    r = q("SELECT token_hash, use_count, max_uses, revoked_at, expires_at FROM invites WHERE _id = %s",
          (invite_id,))
    return r[0] if r else None


def cleanup(uids, gids):
    for g in gids:
        q("DELETE FROM invites WHERE target_id = %s", (g,))
        q("DELETE FROM groups WHERE _id = %s", (g,))
    for u in uids:
        q("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (u, u))
        q("DELETE FROM groups WHERE %s = ANY(users)", (u,))
        q("DELETE FROM users WHERE _id = %s", (u,))


def base_cfg(**over):
    raw = json.loads(open(ic.CONFIG_PATH).read())
    raw["enabled"] = True
    raw.update(over)
    return ic.parse_invites_config(raw)


def install(**over):
    ic.set_invites_config_for_tests(base_cfg(**over))


def create(client, tok, uid, gid, **body):
    return client.post(f"/invites/{uid}/groups/{gid}", json=body or None, headers={**ck(tok), **ip_hdr()})


def preview(client, token, **h):
    return client.post("/invites/preview", json={"token": token}, headers={**ip_hdr(), **h})


def redeem(client, tok, uid, token):
    return client.post(f"/invites/{uid}/redeem", json={"token": token}, headers={**ck(tok), **ip_hdr()})


class LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


# ── tests ────────────────────────────────────────────────────────────────────

def test_migration_idempotent():
    print("\n== Migration: create_tables is idempotent and yields the invites schema ==")
    db = DBManager()
    try:
        db_module.create_tables(db.cur)
        db_module.create_tables(db.cur)
        db.conn.commit()
        db.cur.execute("SELECT column_name FROM information_schema.columns WHERE table_name='invites'")
        cols = {r[0] for r in db.cur.fetchall()}
    finally:
        db.close()
    want = {"_id", "token_hash", "kind", "target_id", "created_by", "created_at",
            "expires_at", "max_uses", "use_count", "revoked_at"}
    check("create_tables x2 does not raise; invites columns present", want <= cols, str(cols ^ want))
    check("no plaintext token column exists", not any("token" == c for c in cols))


def test_token_generation():
    print("\n== Token entropy / format / hashing ==")
    toks = [inv.generate_token() for _ in range(500)]
    check("500 tokens all unique", len(set(toks)) == 500)
    check("all tokens are 43 url-safe chars", all(inv.is_well_formed_token(t) for t in toks))
    raw = base64.urlsafe_b64decode(toks[0] + "=")
    check("token decodes to 32 bytes (256 bits >= 128)", len(raw) == 32, str(len(raw)))
    check("hash_token is sha256 hex of the token",
          inv.hash_token(toks[0]) == hashlib.sha256(toks[0].encode()).hexdigest())
    check("malformed tokens rejected by format check",
          not inv.is_well_formed_token("short") and not inv.is_well_formed_token("a" * 44)
          and not inv.is_well_formed_token("a" * 42 + "!") and not inv.is_well_formed_token(None))
    # crude entropy sanity: many distinct chars across the corpus
    check("token corpus uses a wide alphabet", len(set("".join(toks))) >= 60)


def test_create_list_revoke(client):
    print("\n== Create / list / revoke + authorization ==")
    uc, tc = signup(client, uname())   # group creator
    um, tm = signup(client, uname())   # ordinary member
    uo, to = signup(client, uname())   # outsider
    gid = mk_group(client, tc, uc, [um])
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    logging.getLogger().setLevel(logging.INFO)
    try:
        # unauthenticated / spoofed / non-member
        r = client.post(f"/invites/{uc}/groups/{gid}", headers=ip_hdr())
        check("unauthenticated create -> 401", r.status_code == 401, str(r.status_code))
        r = create(client, tm, uc, gid)
        check("spoofed user (member cookie, creator's path id) -> 403", r.status_code == 403, str(r.status_code))
        r = create(client, to, uo, gid)
        check("non-member create -> 403", r.status_code == 403, f"{r.status_code} {r.text}")

        # any member (non-creator) can create
        r = create(client, tm, um, gid)
        check("ordinary member create -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        body = r.json()
        token = body["token"]
        check("response has plaintext token + url once", token and body["url"].endswith("/join/" + token))
        check("Cache-Control no-store on create", r.headers.get("cache-control") == "no-store")
        row = invite_row(body["invite_id"])
        check("only sha256 hash stored", row[0].strip() == hashlib.sha256(token.encode()).hexdigest())
        dump = q("SELECT row_to_json(i)::text FROM invites i WHERE _id = %s", (body["invite_id"],))[0][0]
        check("plaintext token appears nowhere in the stored row", token not in dump)
        check("defaults applied: max_uses 25, ~7d expiry", body["max_uses"] == 25 and 6.9 < (
            __import__("datetime").datetime.fromisoformat(body["expires_at"])
            - __import__("datetime").datetime.now(__import__("datetime").timezone.utc)).total_seconds() / 86400 <= 7.01)

        # bad option values
        r = create(client, tm, um, gid, max_uses=7)
        check("max_uses not in allowed set -> 422", r.status_code == 422, str(r.status_code))
        r = create(client, tm, um, gid, expires_in_days=3)
        check("expiry not in allowed set -> 422", r.status_code == 422, str(r.status_code))

        # creator makes their own link too
        rc = create(client, tc, uc, gid, max_uses=5, expires_in_days=1)
        check("creator create with explicit allowed options -> 201", rc.status_code == 201 and rc.json()["max_uses"] == 5)
        cinv = rc.json()

        # list: member sees own only, creator sees all
        r = client.get(f"/invites/{um}/groups/{gid}", headers={**ck(tm), **ip_hdr()})
        ids = [i["invite_id"] for i in r.json()["invites"]]
        check("member list -> only own link", r.status_code == 200 and ids == [body["invite_id"]], str(ids))
        r = client.get(f"/invites/{uc}/groups/{gid}", headers={**ck(tc), **ip_hdr()})
        ids_c = {i["invite_id"] for i in r.json()["invites"]}
        check("creator list -> all links in group", ids_c == {body["invite_id"], cinv["invite_id"]}, str(ids_c))
        check("list never returns a token/url/hash", "token" not in r.text.lower().replace("token_", "x")
              and token not in r.text and cinv["token"] not in r.text and "url" not in r.text
              and hashlib.sha256(token.encode()).hexdigest() not in r.text)
        check("list exposes options block", "allowed_max_uses" in r.json()["options"])
        r = client.get(f"/invites/{uo}/groups/{gid}", headers={**ck(to), **ip_hdr()})
        check("non-member list -> 403", r.status_code == 403)

        # revoke
        r = client.delete(f"/invites/{um}/{cinv['invite_id']}", headers={**ck(tm), **ip_hdr()})
        check("member revoking creator's link -> 403", r.status_code == 403, str(r.status_code))
        r = client.delete(f"/invites/{uo}/{body['invite_id']}", headers={**ck(to), **ip_hdr()})
        check("non-member revoke -> 404 (indistinguishable)", r.status_code == 404, str(r.status_code))
        r = client.delete(f"/invites/{um}/{body['invite_id']}", headers={**ck(tm), **ip_hdr()})
        check("member revokes own link -> 204", r.status_code == 204, str(r.status_code))
        check("revoked_at set", invite_row(body["invite_id"])[3] is not None)
        r = client.delete(f"/invites/{um}/{body['invite_id']}", headers={**ck(tm), **ip_hdr()})
        check("revoke is idempotent", r.status_code == 204)
        r = client.delete(f"/invites/{uc}/{body['invite_id']}", headers={**ck(tc), **ip_hdr()})
        check("creator can revoke any link (already revoked ok)", r.status_code == 204)
        # creator revokes member's fresh link
        r2 = create(client, tm, um, gid).json()
        r = client.delete(f"/invites/{uc}/{r2['invite_id']}", headers={**ck(tc), **ip_hdr()})
        check("group creator revokes another member's link -> 204",
              r.status_code == 204 and invite_row(r2["invite_id"])[3] is not None)
        r = client.delete(f"/invites/{uc}/not-a-uuid", headers={**ck(tc), **ip_hdr()})
        check("bad invite id -> 404", r.status_code == 404)
        r = client.get(f"/invites/{um}/groups/{gid}", headers={**ck(tm), **ip_hdr()})
        check("revoked links vanish from list", r.json()["invites"] == [])

        # reset
        a = create(client, tm, um, gid).json()
        b = create(client, tc, uc, gid).json()
        r = client.post(f"/invites/{um}/groups/{gid}/reset", headers={**ck(tm), **ip_hdr()})
        check("member reset revokes only own", r.json()["revoked"] == 1 and invite_row(a["invite_id"])[3]
              and invite_row(b["invite_id"])[3] is None, r.text)

        # soft cap
        install(max_active_links_per_user_per_group=2)
        create(client, tm, um, gid); create(client, tm, um, gid)
        r = create(client, tm, um, gid)
        check("per-user active-link cap -> 409 link_limit",
              r.status_code == 409 and r.json()["detail"]["code"] == "link_limit", f"{r.status_code} {r.text}")
        install()

        # plaintext never logged
        logs = "\n".join(cap.lines)
        check("plaintext tokens never appear in logs", token not in logs and cinv["token"] not in logs and "INVITE_AUDIT" in logs)
    finally:
        logging.getLogger().removeHandler(cap)
        cleanup([uc, um, uo], [gid])


def test_preview(client):
    print("\n== Preview: minimal fields, uniform not-found ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    gid = mk_group(client, tc, uc, [um], title="Preview Group")
    extra_gid = None
    try:
        good = create(client, tc, uc, gid).json()
        r = preview(client, good["token"])
        check("valid preview -> 200", r.status_code == 200, r.text)
        j = r.json()
        check("preview fields limited to name/photo/inviter/count/kind",
              set(j) == {"kind", "group_name", "photo_url", "inviter_username", "member_count"}, str(set(j)))
        check("preview values correct", j["group_name"] == "Preview Group" and j["member_count"] == 2)
        check("preview has no member ids / member list",
              uc not in r.text and um not in r.text and "users" not in j)
        check("preview no-store", r.headers.get("cache-control") == "no-store")

        # unusable variants
        unknown = inv.generate_token()
        rv = create(client, tc, uc, gid).json()
        client.delete(f"/invites/{uc}/{rv['invite_id']}", headers={**ck(tc), **ip_hdr()})
        ex = create(client, tc, uc, gid).json()
        q("UPDATE invites SET expires_at = NOW() - INTERVAL '1 minute' WHERE _id = %s", (ex["invite_id"],))
        full = create(client, tc, uc, gid, max_uses=1).json()
        q("UPDATE invites SET use_count = max_uses WHERE _id = %s", (full["invite_id"],))
        resp = {
            "unknown": preview(client, unknown), "malformed": preview(client, "abc"),
            "revoked": preview(client, rv["token"]), "expired": preview(client, ex["token"]),
            "used-up": preview(client, full["token"]),
        }
        bodies = {k: (v.status_code, v.text) for k, v in resp.items()}
        check("all unusable previews -> 404", all(s == 404 for s, _ in bodies.values()), str(bodies))
        check("all unusable previews have byte-identical bodies", len({t for _, t in bodies.values()}) == 1, str(bodies))
        r = client.post("/invites/preview", json={"token": "x" * 300}, headers=ip_hdr())
        check("oversized token rejected before work (422)", r.status_code == 422)

        # group gone => not found
        g2 = mk_group(client, tc, uc, [], title="G2"); extra_gid = g2
        t2 = create(client, tc, uc, g2).json()
        q("DELETE FROM groups WHERE _id = %s", (g2,))  # no invite purge => orphan
        r = preview(client, t2["token"])
        check("orphaned invite (group missing) -> uniform 404",
              r.status_code == 404 and r.text == bodies["unknown"][1])

        # tokens only in POST bodies
        check("GET /invites/preview not routed", client.get(f"/invites/preview?token={good['token']}").status_code in (404, 405))
        check("token in path not accepted for preview",
              client.post(f"/invites/preview/{good['token']}", headers=ip_hdr()).status_code in (404, 405))
        r = client.post(f"/invites/preview?token={good['token']}", headers=ip_hdr())
        check("token in query string not accepted (422)", r.status_code == 422)
        r = client.post(f"/invites/{um}/redeem?token={good['token']}", headers={**ck(tm), **ip_hdr()})
        check("redeem token in query not accepted (422)", r.status_code == 422)
    finally:
        cleanup([uc, um], [gid] + ([extra_gid] if extra_gid else []))


def test_preview_rate_limit(client):
    print("\n== Preview rate limiting (per IP) ==")
    install(rate_limits={**json.loads(open(ic.CONFIG_PATH).read())["rate_limits"], "preview": "3/minute"})
    ip = {"cf-connecting-ip": f"192.0.2.{uuid.uuid4().int % 250 + 1}"}
    codes = [client.post("/invites/preview", json={"token": inv.generate_token()}, headers=ip).status_code
             for _ in range(5)]
    check("4th+ request from same IP -> 429", codes[:3] == [404] * 3 and 429 in codes[3:], str(codes))
    other = client.post("/invites/preview", json={"token": inv.generate_token()},
                        headers={"cf-connecting-ip": "192.0.2.251"})
    check("different IP unaffected", other.status_code == 404, str(other.status_code))
    install()


def test_redeem(client):
    print("\n== Redeem: join, idempotency, expiry, revoke, uniform errors ==")
    uc, tc = signup(client, uname())
    uj, tj = signup(client, uname())
    uk, tk = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid, max_uses=5).json()
        r = client.post(f"/invites/{uj}/redeem", json={"token": link["token"]}, headers=ip_hdr())
        check("unauthenticated redeem -> 401", r.status_code == 401)
        r = client.post(f"/invites/{uc}/redeem", json={"token": link["token"]}, headers={**ck(tj), **ip_hdr()})
        check("spoofed user redeem -> 403", r.status_code == 403)

        r = redeem(client, tj, uj, link["token"])
        check("redeem -> 200 joined", r.status_code == 200 and r.json() == {
            "kind": "group", "target_id": gid, "joined": True, "already_member": False}, r.text)
        check("joiner appended to groups.users", uj in group_users(gid))
        check("use_count == 1", invite_row(link["invite_id"])[1] == 1)
        check("joined user can fetch group", client.get(f"/groups/{uj}/{gid}", headers=ck(tj)).status_code == 200)

        r = redeem(client, tj, uj, link["token"])
        check("second redeem by member idempotent (200, already_member)",
              r.status_code == 200 and r.json()["already_member"] and not r.json()["joined"])
        check("idempotent redeem consumed no use", invite_row(link["invite_id"])[1] == 1)
        check("no duplicate member entry", group_users(gid).count(uj) == 1)
        r = redeem(client, tc, uc, link["token"])
        check("creator redeeming own link no-op, no use consumed", r.json()["already_member"]
              and invite_row(link["invite_id"])[1] == 1)

        r = redeem(client, tk, uk, inv.generate_token())
        nf = r.text
        check("unknown token -> 404 not_found", r.status_code == 404 and r.json()["detail"]["code"] == "not_found")
        r = redeem(client, tk, uk, "abc")
        check("malformed token redeem -> same 404 body", r.status_code == 404 and r.text == nf)

        # expired
        ex = create(client, tc, uc, gid).json()
        q("UPDATE invites SET expires_at = NOW() - INTERVAL '1 second' WHERE _id = %s", (ex["invite_id"],))
        r = redeem(client, tk, uk, ex["token"])
        check("expired -> 410 expired", r.status_code == 410 and r.json()["detail"]["code"] == "expired", r.text)
        # revoked
        rv = create(client, tc, uc, gid).json()
        client.delete(f"/invites/{uc}/{rv['invite_id']}", headers={**ck(tc), **ip_hdr()})
        r = redeem(client, tk, uk, rv["token"])
        check("revoked -> 410 revoked", r.status_code == 410 and r.json()["detail"]["code"] == "revoked", r.text)
        # full
        fl = create(client, tc, uc, gid, max_uses=1).json()
        q("UPDATE invites SET use_count = 1 WHERE _id = %s", (fl["invite_id"],))
        r = redeem(client, tk, uk, fl["token"])
        check("full -> 409 full", r.status_code == 409 and r.json()["detail"]["code"] == "full", r.text)
        check("failed redeems did not add member or bump count",
              uk not in group_users(gid) and invite_row(fl["invite_id"])[1] == 1)

        # group gone
        q("DELETE FROM groups WHERE _id = %s", (gid,))
        r = redeem(client, tk, uk, link["token"])
        check("redeem for deleted group -> 404", r.status_code == 404)
    finally:
        cleanup([uc, uj, uk], [gid])


def test_redeem_blocked(client):
    print("\n== Redeem: blocked pairs (both directions), generic error ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    j1, t1 = signup(client, uname())   # joiner blocked BY a member
    j2, t2 = signup(client, uname())   # joiner HAS blocked a member
    j3, t3 = signup(client, uname())   # unrelated
    gid = mk_group(client, tc, uc, [um])
    try:
        link = create(client, tc, uc, gid).json()
        q("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s, %s)", (um, j1))
        q("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s, %s)", (j2, uc))
        r1 = redeem(client, t1, j1, link["token"])
        r2 = redeem(client, t2, j2, link["token"])
        check("member-blocked-joiner rejected 403 blocked", r1.status_code == 403 and r1.json()["detail"]["code"] == "blocked", r1.text)
        check("joiner-blocked-member rejected 403 blocked", r2.status_code == 403 and r2.json()["detail"]["code"] == "blocked", r2.text)
        check("blocked error body identical for both directions (no leak)", r1.text == r2.text)
        check("blocked message names no user", um not in r1.text and uc not in r1.text)
        gu = group_users(gid)
        check("blocked joiners not added; no use consumed",
              j1 not in gu and j2 not in gu and invite_row(link["invite_id"])[1] == 0)
        r3 = redeem(client, t3, j3, link["token"])
        check("unrelated joiner still joins", r3.status_code == 200 and j3 in group_users(gid))
        check("use_count correct == 1", invite_row(link["invite_id"])[1] == 1)
    finally:
        cleanup([uc, um, j1, j2, j3], [gid])


def test_race_last_slot(client):
    print("\n== Redeem: real threads racing the last slot -> exactly one winner ==")
    uc, tc = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    joiners = [signup(client, uname())[0] for _ in range(10)]
    try:
        link = create(client, tc, uc, gid, max_uses=1).json()
        barrier = threading.Barrier(len(joiners))
        results = []
        lock = threading.Lock()

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
        wins = results.count("won")
        check("exactly one winner", wins == 1, str(results))
        check("all losers got 'full'", results.count("full") == len(joiners) - 1, str(results))
        row = invite_row(link["invite_id"])
        check("use_count == 1 (== max_uses)", row[1] == 1, str(row))
        members = [u for u in group_users(gid) if u in joiners]
        check("exactly one joiner actually added to group", len(members) == 1, str(members))

        # multi-slot race: max_uses=5, 10 racers -> exactly 5
        link5 = create(client, tc, uc, gid, max_uses=5).json()
        others = [signup(client, uname())[0] for _ in range(10)]
        joiners += others
        barrier2 = threading.Barrier(len(others))
        res2 = []

        def worker2(uid):
            m = InvitesManager(uid)
            try:
                barrier2.wait()
                m.redeem(link5["token"])
                out = "won"
            except InviteError as e:
                out = e.code
            except Exception as e:  # noqa: BLE001
                out = f"exc:{e}"
            finally:
                m.close()
            with lock:
                res2.append(out)

        ts = [threading.Thread(target=worker2, args=(u,)) for u in others]
        [t.start() for t in ts]
        [t.join() for t in ts]
        check("max_uses=5 with 10 racers -> exactly 5 winners", res2.count("won") == 5, str(res2))
        check("use_count == 5 and 5 members added",
              invite_row(link5["invite_id"])[1] == 5 and len([u for u in group_users(gid) if u in others]) == 5)

        # double-tap: same user twice concurrently -> one join, one use
        dup_user = signup(client, uname())[0]
        joiners.append(dup_user)
        link_d = create(client, tc, uc, gid, max_uses=10).json()
        b3 = threading.Barrier(2)
        res3 = []

        def worker3():
            m = InvitesManager(dup_user)
            try:
                b3.wait()
                res3.append(m.redeem(link_d["token"]))
            except Exception as e:  # noqa: BLE001
                res3.append({"exc": str(e)})
            finally:
                m.close()

        ts = [threading.Thread(target=worker3) for _ in range(2)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        check("double-tap: no errors, one joined + one already_member",
              sorted(r.get("joined", False) for r in res3) == [False, True], str(res3))
        check("double-tap: use_count 1 and single membership entry",
              invite_row(link_d["invite_id"])[1] == 1 and group_users(gid).count(dup_user) == 1)
    finally:
        cleanup([uc, *joiners], [gid])


def test_purge(client):
    print("\n== Group delete / last-member leave purge invites ==")
    uc, tc = signup(client, uname())
    um, tm = signup(client, uname())
    g1 = mk_group(client, tc, uc, [um])
    g2 = mk_group(client, tc, uc, [])
    try:
        i1 = create(client, tc, uc, g1).json()
        i2 = create(client, tc, uc, g2).json()
        r = client.delete(f"/groups/{uc}/{g1}", headers=ck(tc))
        check("group delete 204", r.status_code == 204, r.text)
        check("group delete purged its invites", invite_row(i1["invite_id"]) is None)
        r = client.post(f"/groups/{uc}/{g2}/leave", headers=ck(tc))
        check("last-member leave 204", r.status_code == 204)
        check("last-member leave purged invites", invite_row(i2["invite_id"]) is None)
        i3 = create(client, tc, uc, mk_group(client, tc, uc, [um])).json()
        g3 = q("SELECT target_id FROM invites WHERE _id = %s", (i3["invite_id"],))[0][0]
        client.post(f"/groups/{uc}/{g3}/leave", headers=ck(tc))
        check("non-last leave keeps invites", invite_row(i3["invite_id"]) is not None)
        q("DELETE FROM invites WHERE target_id = %s", (g3,))
        q("DELETE FROM groups WHERE _id = %s", (g3,))
    finally:
        cleanup([uc, um], [g1, g2])


def test_flag_off(client):
    print("\n== Feature flag off => uniform 404 everywhere ==")
    uc, tc = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid).json()
        ic.set_invites_config_for_tests(base_cfg(enabled=False))
        unknown_body = None
        outs = {
            "create": create(client, tc, uc, gid),
            "list": client.get(f"/invites/{uc}/groups/{gid}", headers={**ck(tc), **ip_hdr()}),
            "reset": client.post(f"/invites/{uc}/groups/{gid}/reset", headers={**ck(tc), **ip_hdr()}),
            "revoke": client.delete(f"/invites/{uc}/{link['invite_id']}", headers={**ck(tc), **ip_hdr()}),
            "redeem": redeem(client, tc, uc, link["token"]),
            "preview": preview(client, link["token"]),
        }
        check("all six routes -> 404 when disabled", all(v.status_code == 404 for v in outs.values()),
              str({k: v.status_code for k, v in outs.items()}))
        check("disabled preview body == invalid-token body",
              outs["preview"].json()["detail"]["code"] == "not_found")
        check("disabled: link not revoked / not consumed",
              invite_row(link["invite_id"])[3] is None and invite_row(link["invite_id"])[1] == 0)
        # shipped config file is off by default
        shipped = json.loads(open(ic.CONFIG_PATH).read())
        check("shipped api/config/invites.json has enabled=false", shipped["enabled"] is False)
    finally:
        install()
        cleanup([uc], [gid])


def test_config_validation():
    print("\n== Structured config validation (no defaults, fails startup) ==")
    good = json.loads(open(ic.CONFIG_PATH).read())

    def bad(mut, label):
        raw = copy.deepcopy(good)
        mut(raw)
        try:
            ic.parse_invites_config(raw)
            check(label, False, "accepted")
        except ic.InvitesConfigError:
            check(label, True)

    check("shipped config parses", ic.parse_invites_config(copy.deepcopy(good)).default_max_uses == 25)
    for k in list(good):
        bad(lambda r, k=k: r.pop(k), f"missing key {k} rejected")
    bad(lambda r: r.update(extra=1), "unknown key rejected")
    bad(lambda r: r.update(enabled="yes"), "enabled must be a bool")
    bad(lambda r: r.update(public_base_url="http://fellowscript.com"), "http base url rejected")
    bad(lambda r: r.update(public_base_url="https://fellowscript.com/"), "trailing slash base url rejected")
    bad(lambda r: r.update(public_base_url="https://fellowscript.com/x"), "base url with path rejected")
    bad(lambda r: r.update(default_expiry_days=3), "default expiry not in allowed set")
    bad(lambda r: r.update(default_max_uses=True), "bool as int rejected")
    bad(lambda r: r.update(allowed_max_uses=[]), "empty allowed list rejected")
    bad(lambda r: r.update(allowed_max_uses=[5, 5, 25]), "duplicate allowed values rejected")
    bad(lambda r: r.update(max_active_links_per_user_per_group=0), "zero cap rejected")
    bad(lambda r: r["rate_limits"].pop("preview"), "missing rate limit rejected")
    bad(lambda r: r["rate_limits"].update(preview="lots"), "unparseable rate limit rejected")
    for bogus in (None, [], "str"):
        try:
            ic.parse_invites_config(bogus)
            check(f"non-object {bogus!r} rejected", False)
        except ic.InvitesConfigError:
            check(f"non-object {bogus!r} rejected", True)
    # missing / corrupt file -> loud error, no fallback
    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as d:
        try:
            ic.load_invites_config(Path(d) / "nope.json")
            check("missing file raises", False)
        except ic.InvitesConfigError:
            check("missing file raises", True)
        p = Path(d) / "bad.json"
        p.write_text("{not json")
        try:
            ic.load_invites_config(p)
            check("corrupt json raises", False)
        except ic.InvitesConfigError:
            check("corrupt json raises", True)
        # startup: an invalid file makes validate_invites_config (called by lifespan) raise
        orig = ic.CONFIG_PATH
        ic.load_invites_config.__defaults__ = (p,)
        try:
            ic.validate_invites_config()
            check("validate_invites_config (startup) raises on invalid file", False)
        except ic.InvitesConfigError:
            check("validate_invites_config (startup) raises on invalid file", True)
        finally:
            ic.load_invites_config.__defaults__ = (orig,)
    src = open(main_module.__file__).read()
    check("main lifespan calls validate_invites_config", "validate_invites_config()" in src)


def test_startup_fails_on_bad_config():
    print("\n== Real app startup refuses to boot on an invalid config ==")
    from pathlib import Path
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "invites.json"
        raw = json.loads(open(ic.CONFIG_PATH).read())
        del raw["rate_limits"]
        p.write_text(json.dumps(raw))
        ic.load_invites_config.__defaults__ = (p,)
        try:
            try:
                with TestClient(main_module.app):
                    pass
                check("app lifespan raises with invalid invites config", False, "booted")
            except ic.InvitesConfigError:
                check("app lifespan raises with invalid invites config", True)
            except Exception as e:  # noqa: BLE001
                check("app lifespan raises with invalid invites config", "invites config" in str(e), repr(e))
        finally:
            ic.load_invites_config.__defaults__ = (ic.CONFIG_PATH,)
            ic.set_invites_config_for_tests(None)


def main():
    test_migration_idempotent()
    test_token_generation()
    test_config_validation()
    test_startup_fails_on_bad_config()
    with TestClient(main_module.app) as client:
        install()
        test_create_list_revoke(client)
        test_preview(client)
        test_preview_rate_limit(client)
        test_redeem(client)
        test_redeem_blocked(client)
        test_race_last_slot(client)
        test_purge(client)
        test_flag_off(client)
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
