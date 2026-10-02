"""Backend coverage for task 20261002-group-invite-show-link.

Proves: new group links derive their token from INVITE_LINK_SECRET + a stored
per-link nonce (43 url-safe chars, 256-bit) while the stored SHA-256 hash still
verifies, so preview / redeem / revoke are unchanged for derived AND legacy
(NULL nonce) links; the reveal endpoint authz matrix (link creator and group
manager ok; other member / non-member identical uniform 404; anonymous 401);
revoked / exhausted / legacy / subscription / unknown links 404 uniformly;
rotating the secret makes reveal 404 while redeem still works; reveal rate
limits; no token in any log line and ids-only audit lines; no-store headers;
INVITE_LINK_SECRET startup validation (missing / short / ok, value never
echoed); feature-flag gating; ``revealable`` flag on the list endpoint;
the shipped invites.json carries the reveal rate-limit keys.

Run with: cd api && ../.venv/bin/python tests/test_group_invite_reveal.py

The secret is forced to the value of the CI env block in
.github/workflows/build-push.yml (never the local .env value), so the test is
identical locally and in CI.
"""
import _pathfix  # noqa: F401

import base64
import hashlib
import hmac
import json
import logging
import os
import uuid

# Same value as the CI env block (build-push.yml). Forced, not setdefault, so a
# local .env secret is never what the assertions depend on.
CI_SECRET = "ci-only-invite-link-secret-0123456789abcdef"
os.environ["INVITE_LINK_SECRET"] = CI_SECRET
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
    return f"rv_{uuid.uuid4().hex[:10]}"


def mk_group(client, tok, owner, members):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner}", json={"group_id": gid, "title": "Reveal group",
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


def rl(**over):
    return {**json.loads(open(ic.CONFIG_PATH).read())["rate_limits"], **over}


def create(client, tok, uid, gid, **body):
    return client.post(f"/invites/{uid}/groups/{gid}", json=body or None, headers={**ck(tok), **ip_hdr()})


def reveal(client, tok, uid, invite_id, **h):
    return client.get(f"/invites/{uid}/{invite_id}/reveal", headers={**ck(tok), **ip_hdr(), **h})


def preview(client, token):
    return client.post("/invites/preview", json={"token": token}, headers=ip_hdr())


def redeem(client, tok, uid, token):
    return client.post(f"/invites/{uid}/redeem", json={"token": token}, headers={**ck(tok), **ip_hdr()})


def token_of(url):
    return url.rsplit("/join/", 1)[1]


class LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


def set_secret(value):
    if value is None:
        os.environ.pop("INVITE_LINK_SECRET", None)
    else:
        os.environ["INVITE_LINK_SECRET"] = value


# -- tests --------------------------------------------------------------------

def test_derivation():
    print("\n== Derivation: HMAC(secret, nonce), 256-bit, URL-safe, hash matches ==")
    nonce = os.urandom(32)
    tok = inv.derive_token(nonce)
    expect = base64.urlsafe_b64encode(
        hmac.new(CI_SECRET.encode(), nonce, hashlib.sha256).digest()).rstrip(b"=").decode()
    check("derive_token == base64url(HMAC-SHA256(secret, nonce)) unpadded", tok == expect)
    check("derived token is well formed (43 url-safe chars)", inv.is_well_formed_token(tok) and len(tok) == 43)
    check("derived token decodes to 32 bytes (256 bits)", len(base64.urlsafe_b64decode(tok + "=")) == 32)
    check("derivation is deterministic", inv.derive_token(nonce) == tok)
    check("different nonces give different tokens",
          len({inv.derive_token(os.urandom(32)) for _ in range(200)}) == 200)
    check("hash_token(derived) is sha256 hex",
          inv.hash_token(tok) == hashlib.sha256(tok.encode()).hexdigest())
    set_secret(CI_SECRET + "-rotated")
    try:
        check("a different secret derives a different token", inv.derive_token(nonce) != tok)
    finally:
        set_secret(CI_SECRET)


def test_create_stores_nonce_and_hash(client):
    print("\n== Create: nonce stored, stored hash == sha256(derived token), no plaintext ==")
    uc, tc = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid).json()
        row = q("SELECT token_hash, reveal_nonce FROM invites WHERE _id = %s", (link["invite_id"],))[0]
        nonce = bytes(row[1]) if row[1] is not None else None
        check("reveal_nonce stored (32 bytes)", nonce is not None and len(nonce) == 32)
        check("create token == derive_token(stored nonce)", nonce is not None and inv.derive_token(nonce) == link["token"])
        check("stored token_hash == sha256(token)", row[0].strip() == hashlib.sha256(link["token"].encode()).hexdigest())
        check("create url ends with the token", link["url"].endswith("/join/" + link["token"]))
        cols = {r[0] for r in q("SELECT column_name FROM information_schema.columns WHERE table_name='invites'")}
        check("migration idempotent and reveal_nonce column exists", "reveal_nonce" in cols)
        db = DBManager()
        try:
            db_module.create_tables(db.cur)
            db.conn.commit()
        finally:
            db.close()
        check("create_tables rerun does not raise", True)
    finally:
        cleanup([uc], [gid])


def test_flows_unchanged(client):
    print("\n== preview / redeem / revoke unchanged for derived AND legacy links ==")
    uc, tc = signup(client, uname())
    uj, tj = signup(client, uname())
    ul, tl = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        derived = create(client, tc, uc, gid, max_uses=5).json()
        # Legacy link: random token, NULL nonce (as created before this change).
        legacy_tok = inv.generate_token()
        legacy_id = str(uuid.uuid4())
        q("INSERT INTO invites (_id, token_hash, kind, target_id, created_by, expires_at, max_uses) "
          "VALUES (%s, %s, 'group', %s, %s, NULL, 5)", (legacy_id, inv.hash_token(legacy_tok), gid, uc))
        for label, tok in (("derived", derived["token"]), ("legacy", legacy_tok)):
            r = preview(client, tok)
            check(f"{label}: preview 200", r.status_code == 200 and r.json().get("kind") == "group", r.text)
        r = redeem(client, tj, uj, derived["token"])
        check("derived: redeem joins", r.status_code == 200 and r.json()["joined"] is True, r.text)
        r = redeem(client, tl, ul, legacy_tok)
        check("legacy: redeem joins", r.status_code == 200 and r.json()["joined"] is True, r.text)
        # revoke both
        for label, iid, tok in (("derived", derived["invite_id"], derived["token"]), ("legacy", legacy_id, legacy_tok)):
            r = client.delete(f"/invites/{uc}/{iid}", headers={**ck(tc), **ip_hdr()})
            check(f"{label}: revoke 204", r.status_code == 204, str(r.status_code))
            check(f"{label}: preview after revoke 404", preview(client, tok).status_code == 404)
    finally:
        cleanup([uc, uj, ul], [gid])


def test_reveal_authz(client):
    print("\n== Reveal authz: creator and manager ok; others uniform 404 ==")
    uc, tc = signup(client, uname())   # group creator == manager
    um, tm = signup(client, uname())   # member who creates a link
    uo, to = signup(client, uname())   # other member (not creator of link, not manager)
    ux, tx = signup(client, uname())   # non-member
    gid = mk_group(client, tc, uc, [um, uo])
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    logging.getLogger().setLevel(logging.INFO)
    try:
        link = create(client, tm, um, gid).json()          # created by member um
        mgr_link = create(client, tc, uc, gid).json()      # created by manager uc
        iid = link["invite_id"]

        r = reveal(client, tm, um, iid)
        check("creator reveals own link (200, same url as create)",
              r.status_code == 200 and r.json() == {"invite_id": iid, "url": link["url"]}, r.text)
        check("reveal token redeemable = same token as create", token_of(r.json()["url"]) == link["token"])
        check("reveal response has no-store", "no-store" in r.headers.get("cache-control", ""))
        r = reveal(client, tc, uc, iid)
        check("group manager reveals a member's link", r.status_code == 200 and r.json()["url"] == link["url"], r.text)
        r = reveal(client, tc, uc, mgr_link["invite_id"])
        check("manager reveals own link", r.status_code == 200 and r.json()["url"] == mgr_link["url"], r.text)
        r = reveal(client, tm, um, iid)
        check("repeated reveal returns the same url", r.status_code == 200 and r.json()["url"] == link["url"])

        # Non-authorized callers: identical uniform 404
        r_other = reveal(client, to, uo, iid)
        r_nonmem = reveal(client, tx, ux, iid)
        r_unknown = reveal(client, tm, um, str(uuid.uuid4()))
        r_badid = reveal(client, tm, um, "not-a-uuid")
        check("other member -> 404", r_other.status_code == 404, str(r_other.status_code))
        check("non-member -> 404", r_nonmem.status_code == 404, str(r_nonmem.status_code))
        check("unknown id -> 404", r_unknown.status_code == 404)
        check("malformed id -> 404", r_badid.status_code == 404)
        bodies = {json.dumps(x.json(), sort_keys=True) for x in (r_other, r_nonmem, r_unknown, r_badid)}
        check("all failure bodies identical (no enumeration oracle)", len(bodies) == 1, str(bodies))
        check("failure responses carry no-store", all("no-store" in x.headers.get("cache-control", "")
              for x in (r_other, r_nonmem, r_unknown)))
        check("failure body does not leak the token/url",
              link["token"] not in r_other.text and "/join/" not in r_other.text)
        # non-manager member cannot see manager's link either
        check("other member cannot reveal manager's link",
              reveal(client, to, uo, mgr_link["invite_id"]).status_code == 404)
        # anonymous / spoofed
        r = client.get(f"/invites/{um}/{iid}/reveal", headers=ip_hdr())
        check("anonymous -> 401 (auth boundary, no link data)", r.status_code == 401 and link["token"] not in r.text, str(r.status_code))
        r = client.get(f"/invites/{um}/{iid}/reveal", headers={**ck(tx), **ip_hdr()})
        check("spoofed path user id -> 403", r.status_code == 403, str(r.status_code))

        # departed link creator: removed from group -> can no longer reveal
        q("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (um, gid))
        check("creator who left the group -> 404", reveal(client, tm, um, iid).status_code == 404)
        check("manager can still reveal after creator left", reveal(client, tc, uc, iid).status_code == 200)
        q("UPDATE groups SET users = array_append(users, %s) WHERE _id = %s", (um, gid))

        # audit lines: ids only, as=creator|manager, never the token
        text = "\n".join(cap.lines)
        audits = [l for l in cap.lines if "INVITE_AUDIT" in l and "event=reveal " in l]
        check("reveal audit lines recorded", len(audits) >= 3, str(len(audits)))
        check("audit distinguishes as=creator and as=manager",
              any("as=creator" in l for l in audits) and any("as=manager" in l for l in audits))
        check("reveal_miss audited with reason code", any("event=reveal_miss" in l and "reason=" in l for l in cap.lines))
        check("no token or url anywhere in captured logs",
              link["token"] not in text and mgr_link["token"] not in text and "/join/" not in text)
        check("no token hash anywhere in full in logs",
              inv.hash_token(link["token"]) not in text and inv.hash_token(mgr_link["token"]) not in text)
    finally:
        logging.getLogger().removeHandler(cap)
        cleanup([uc, um, uo, ux], [gid])


def test_reveal_inactive_and_legacy(client):
    print("\n== Revoked / exhausted / legacy / subscription / expired links 404 uniformly ==")
    uc, tc = signup(client, uname())
    uj, tj = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        ref = reveal(client, tc, uc, str(uuid.uuid4()))   # reference uniform 404
        ref_body = json.dumps(ref.json(), sort_keys=True)

        a = create(client, tc, uc, gid).json()
        client.delete(f"/invites/{uc}/{a['invite_id']}", headers={**ck(tc), **ip_hdr()})
        r = reveal(client, tc, uc, a["invite_id"])
        check("revoked -> uniform 404", r.status_code == 404 and json.dumps(r.json(), sort_keys=True) == ref_body, r.text)

        b = create(client, tc, uc, gid, max_uses=1).json()
        redeem(client, tj, uj, b["token"])
        r = reveal(client, tc, uc, b["invite_id"])
        check("exhausted -> uniform 404", r.status_code == 404 and json.dumps(r.json(), sort_keys=True) == ref_body, r.text)

        legacy_id = str(uuid.uuid4())
        q("INSERT INTO invites (_id, token_hash, kind, target_id, created_by, expires_at, max_uses) "
          "VALUES (%s, %s, 'group', %s, %s, NULL, 5)", (legacy_id, inv.hash_token(inv.generate_token()), gid, uc))
        r = reveal(client, tc, uc, legacy_id)
        check("legacy (NULL nonce) -> uniform 404", r.status_code == 404 and json.dumps(r.json(), sort_keys=True) == ref_body, r.text)

        c = create(client, tc, uc, gid).json()
        q("UPDATE invites SET expires_at = NOW() - interval '1 hour' WHERE _id = %s", (c["invite_id"],))
        r = reveal(client, tc, uc, c["invite_id"])
        check("expired -> uniform 404", r.status_code == 404 and json.dumps(r.json(), sort_keys=True) == ref_body, r.text)

        # subscription-kind link, even with a nonce, must never reveal
        sub_id = str(uuid.uuid4())
        q("INSERT INTO invites (_id, token_hash, kind, target_id, created_by, expires_at, max_uses, reveal_nonce) "
          "VALUES (%s, %s, 'subscription', %s, %s, '2099-01-01', 5, %s)",
          (sub_id, inv.hash_token("x" * 43), gid, uc, os.urandom(32)))
        r = reveal(client, tc, uc, sub_id)
        check("subscription kind -> uniform 404", r.status_code == 404 and json.dumps(r.json(), sort_keys=True) == ref_body, r.text)
        # nonce whose derived hash doesn't match stored hash (tampered row)
        d_id = str(uuid.uuid4())
        q("INSERT INTO invites (_id, token_hash, kind, target_id, created_by, expires_at, max_uses, reveal_nonce) "
          "VALUES (%s, %s, 'group', %s, %s, NULL, 5, %s)",
          (d_id, inv.hash_token("y" * 43), gid, uc, os.urandom(32)))
        r = reveal(client, tc, uc, d_id)
        check("derived token not matching stored hash -> uniform 404", r.status_code == 404 and json.dumps(r.json(), sort_keys=True) == ref_body, r.text)
    finally:
        cleanup([uc, uj], [gid])


def test_list_revealable(client):
    print("\n== list_active exposes revealable flag, never a token ==")
    uc, tc = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid).json()
        legacy_id = str(uuid.uuid4())
        q("INSERT INTO invites (_id, token_hash, kind, target_id, created_by, expires_at, max_uses) "
          "VALUES (%s, %s, 'group', %s, %s, NULL, 5)", (legacy_id, inv.hash_token(inv.generate_token()), gid, uc))
        r = client.get(f"/invites/{uc}/groups/{gid}", headers={**ck(tc), **ip_hdr()})
        check("list 200", r.status_code == 200, r.text)
        by = {i["invite_id"]: i for i in r.json()["invites"]}
        check("derived link revealable=true", by[link["invite_id"]]["revealable"] is True)
        check("legacy link revealable=false", by[legacy_id]["revealable"] is False)
        check("list never contains a token", link["token"] not in r.text and "token" not in json.dumps(r.json()["invites"]))
    finally:
        cleanup([uc], [gid])


def test_rotation(client):
    print("\n== Secret rotation: reveal 404, redeem/preview still work, restore -> reveal works ==")
    uc, tc = signup(client, uname())
    uj, tj = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid, max_uses=5).json()
        check("reveal works before rotation", reveal(client, tc, uc, link["invite_id"]).status_code == 200)
        set_secret("rotated-" + CI_SECRET)
        try:
            r = reveal(client, tc, uc, link["invite_id"])
            check("reveal -> 404 after rotation", r.status_code == 404, r.text)
            check("preview still works after rotation", preview(client, link["token"]).status_code == 200)
            r = redeem(client, tj, uj, link["token"])
            check("redeem still works after rotation", r.status_code == 200 and r.json()["joined"] is True, r.text)
            new = create(client, tc, uc, gid).json()
            check("new link under new secret reveals", reveal(client, tc, uc, new["invite_id"]).status_code == 200)
        finally:
            set_secret(CI_SECRET)
        check("restoring the secret restores reveal of the old link",
              reveal(client, tc, uc, link["invite_id"]).status_code == 200)
    finally:
        cleanup([uc, uj], [gid])


def test_rate_limits(client):
    print("\n== Reveal rate limits (per IP and per user) ==")
    uc, tc = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid).json()
        iid = link["invite_id"]
        install(rate_limits=rl(reveal="3/minute", reveal_per_user="1000/minute"))
        ip = {"cf-connecting-ip": f"192.0.2.{uuid.uuid4().int % 250 + 1}"}
        codes = [client.get(f"/invites/{uc}/{iid}/reveal", headers={**ck(tc), **ip}).status_code for _ in range(5)]
        check("per-IP: 4th+ reveal from same IP -> 429", codes[:3] == [200] * 3 and 429 in codes[3:], str(codes))
        install(rate_limits=rl(reveal="1000/minute", reveal_per_user="2/minute"))
        codes = [reveal(client, tc, uc, iid).status_code for _ in range(4)]
        check("per-user: limited across differing IPs -> 429", codes[:2] == [200, 200] and 429 in codes[2:], str(codes))
    finally:
        install()
        cleanup([uc], [gid])


def test_flag_gating(client):
    print("\n== Feature flag off => reveal 404 (uniform), on => works ==")
    uc, tc = signup(client, uname())
    gid = mk_group(client, tc, uc, [])
    try:
        link = create(client, tc, uc, gid).json()
        install(enabled=False)
        r = reveal(client, tc, uc, link["invite_id"])
        check("flag off -> 404", r.status_code == 404, str(r.status_code))
        check("flag off body leaks nothing", link["token"] not in r.text and "/join/" not in r.text)
        install()
        check("flag on -> 200", reveal(client, tc, uc, link["invite_id"]).status_code == 200)
    finally:
        install()
        cleanup([uc], [gid])


def test_secret_validation():
    print("\n== INVITE_LINK_SECRET validation: missing / blank / short / ok, value never echoed ==")
    try:
        set_secret(None)
        try:
            ic.validate_invite_link_secret()
            check("missing secret raises", False, "no raise")
        except ic.InviteSecretConfigError as e:
            check("missing secret raises, names the variable", "INVITE_LINK_SECRET" in str(e))
        set_secret("   ")
        try:
            ic.validate_invite_link_secret()
            check("blank secret raises", False, "no raise")
        except ic.InviteSecretConfigError:
            check("blank secret raises", True)
        short = "s" * 31
        set_secret(short)
        try:
            ic.validate_invite_link_secret()
            check("31-char secret raises", False, "no raise")
        except ic.InviteSecretConfigError as e:
            check("short secret raises, value never echoed", "INVITE_LINK_SECRET" in str(e) and short not in str(e))
        set_secret("k" * 32)
        try:
            ic.validate_invite_link_secret()
            check("32-char secret accepted", True)
        except Exception as e:  # noqa: BLE001
            check("32-char secret accepted", False, repr(e))
        set_secret(None)
        try:
            inv.derive_token(os.urandom(32))
            check("derive_token with missing secret raises", False, "no raise")
        except ic.InviteSecretConfigError:
            check("derive_token with missing secret raises", True)

        # The real app refuses to boot without a valid secret.
        for label, val in (("missing", None), ("too short", "short")):
            set_secret(val)
            ic.set_invites_config_for_tests(None)
            try:
                with TestClient(main_module.app):
                    pass
                check(f"app lifespan refuses to boot with {label} secret", False, "booted")
            except ic.InviteSecretConfigError:
                check(f"app lifespan refuses to boot with {label} secret", True)
            except Exception as e:  # noqa: BLE001
                check(f"app lifespan refuses to boot with {label} secret", "INVITE_LINK_SECRET" in str(e), repr(e))
    finally:
        set_secret(CI_SECRET)
        ic.set_invites_config_for_tests(None)
    src = open(main_module.__file__).read()
    check("main lifespan calls validate_invite_link_secret", "validate_invite_link_secret()" in src)


def test_config_keys():
    print("\n== invites.json / InvitesConfig carry the reveal rate-limit keys ==")
    raw = json.loads(open(ic.CONFIG_PATH).read())
    check("shipped rate_limits has reveal + reveal_per_user", {"reveal", "reveal_per_user"} <= set(raw["rate_limits"]))
    cfg = ic.parse_invites_config(raw)
    check("parsed config exposes reveal keys", "reveal" in cfg.rate_limits and "reveal_per_user" in cfg.rate_limits)
    check("_RATE_KEYS lists reveal keys", {"reveal", "reveal_per_user"} <= set(ic._RATE_KEYS))
    for key in ("reveal", "reveal_per_user"):
        bad = json.loads(json.dumps(raw))
        del bad["rate_limits"][key]
        try:
            ic.parse_invites_config(bad)
            check(f"missing {key} rejected", False, "accepted")
        except ic.InvitesConfigError:
            check(f"missing {key} rejected", True)
    bad = json.loads(json.dumps(raw))
    bad["rate_limits"]["reveal"] = "lots"
    try:
        ic.parse_invites_config(bad)
        check("unparseable reveal limit rejected", False, "accepted")
    except ic.InvitesConfigError:
        check("unparseable reveal limit rejected", True)


def main():
    test_derivation()
    test_secret_validation()
    test_config_keys()
    with TestClient(main_module.app) as client:
        install()
        test_create_stores_nonce_and_hash(client)
        test_flows_unchanged(client)
        test_reveal_authz(client)
        test_reveal_inactive_and_legacy(client)
        test_list_revealable(client)
        test_rotation(client)
        test_rate_limits(client)
        test_flag_gating(client)
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
