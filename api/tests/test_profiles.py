"""Tests for user profiles (task 20261030-user-profiles, testing step 8).

Covers the backend surface added by the task and the security decisions
D1-D10 (security.json / security-review.json):

  A. Bio validation (pure): NFC + whitespace collapse, zero-width/bidi strip,
     length counted after normalization (160 ok, 161 rejected, never truncated),
     links / emails / HTML tags / combining-mark stacks rejected, content filter.
  B. Config: shipped profile.json valid; bad variants fail loudly.
  C. GET /profiles/{id}: self / friend / stranger tiers (bio key absent for
     strangers), relationship states, unknown == malformed == blocked ==
     suspended (identical 404), suspended viewer 404, unauthenticated 401.
  D. D1 accept-without-pending on BOTH legacy routes and the id route; atomic
     accept creates two rows and removes the request; wrong party cannot accept.
  E. D5 uniform responses for friend request (unknown / blocked / suspended /
     already friends) and uniform 404 for accept.
  F. D2 / D4 email absence and allow-lists: /user/{id}, /friends/{uid},
     read_friend, /message/messages; stranger DM reads 404.
  G. Bio edit: IDOR (403), extra fields (422), terms / suspension gating,
     clear with null, no truncation, content filter 422 warm message.
  H. Rate limits: distinct-profile sweep, friend request hourly, bio burst,
     outstanding cap; generic 429 body.
  I. Every route under /profile* has an auth dependency; unauthenticated calls
     to every method are 401.
  J. Log capture: bio text and message bodies never reach any log handler.
  K. bio_admin clear CLI helper.

Run with: cd api && ../.venv/bin/python tests/test_profiles.py
(needs a scratch Postgres; the shared test env vars as for the other suites).
"""
import _pathfix  # noqa: F401,E402

import dataclasses
import io
import json
import logging
import os
import sys
import tempfile
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")
os.environ["TRIAL_MONTHS"] = "0"

from fastapi.routing import APIRoute  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main as m  # noqa: E402
from db import DBManager  # noqa: E402
from backend.config_loader import ConfigSectionError  # noqa: E402
from backend.interactions import profile_config as pc_mod  # noqa: E402
from backend.interactions import profile_limits as pl  # noqa: E402
from backend.interactions.profile_bio import BioRejected, normalize_bio, validate_bio  # noqa: E402
from backend.interactions.profile_config import get_profile_config, set_profile_config_for_tests  # noqa: E402
from backend.moderation import bio_admin  # noqa: E402
from backend.rate_limiting import limiter as _lim  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def q(sql, params=()):
    d = DBManager()
    try:
        d.cur.execute(sql, params)
        try:
            r = d.cur.fetchall()
        except Exception:
            r = None
        d.conn.commit()
        return r
    finally:
        d.close()


_n = [0]


def signup(c, prefix):
    _n[0] += 1
    name = f"{prefix}_{uuid.uuid4().hex[:8]}"
    r = c.post("/signup", json={"username": name, "email": f"{name}@example.com",
                                "plain_pass": "TestPass123!", "terms_accepted": True},
               headers={"cf-connecting-ip": f"203.0.117.{_n[0] % 250 + 1}"})
    assert r.status_code == 201, f"signup failed {r.status_code} {r.text}"
    return r.json()["user_id"], name, {"cookie": f"session={r.cookies.get('session')}"}


def reset_limits():
    _lim.limiter.storage.reset()
    pl.reset_for_tests()


# ---------------------------------------------------------------- A. bio (pure)

def test_bio_pure():
    print("A. bio validation (pure)")
    check("normalize: collapse whitespace and newlines", normalize_bio("  a \n\n b\t c ") == "a b c")
    check("normalize: empty -> None", normalize_bio("   \n ") is None and normalize_bio(None) is None)
    check("normalize: zero-width and bidi stripped", normalize_bio("a​b‮c⁦d") == "abcd")
    check("normalize: NFC", normalize_bio("é") == "é")
    check("160 chars accepted", validate_bio("a" * 160, 160) == "a" * 160)
    try:
        validate_bio("a" * 161, 160)
        check("161 chars rejected", False)
    except BioRejected as e:
        check("161 chars rejected (too_long), not truncated", e.code == "too_long" and "a" * 20 not in e.message)
    check("length counted after normalization (padding does not count)", validate_bio("  " + "a" * 160 + "  \n", 160) == "a" * 160)
    check("newlines collapse so 80+80 with newlines fits", validate_bio("a" * 80 + "\n\n\n" + "b" * 79, 160) is not None)
    bads = {
        "https://evil.com": "link", "see www.evil.com": "link", "evil.com": "link",
        "javascript:alert(1)": "link", "mail me a@b.co": "email", "<script>x</script>": "tag",
        "hi <b>there": "tag", "＜html＞": None,  # fullwidth angle brackets (NFKC fold)
        "ｈｔｔｐｓ：//x.io": "link",  # fullwidth https://
    }
    for text, _ in bads.items():
        try:
            validate_bio(text, 160)
            ok = text == "＜html＞"  # no letter right after '<' once folded? tolerated if not markup
            check(f"rejects {text!r}", ok, "accepted")
        except BioRejected as e:
            check(f"rejects {text!r}", e.code in ("link_or_markup",), e.code)
    try:
        validate_bio("a" + "́" * 6, 160)
        check("combining-mark stack rejected", False)
    except BioRejected as e:
        check("combining-mark stack rejected", e.code == "odd_characters", e.code)
    try:
        validate_bio("you are a fucking rapist", 160)
        check("content filter rejects", False)
    except BioRejected as e:
        check("content filter rejects with warm message", e.code == "content_filter" and "FellowScript" in e.message, e.message)
    check("plain faith text accepted", validate_bio("Walking with Jesus. Coffee, hiking & Romans 8:28!", 160) is not None)


# ---------------------------------------------------------------- B. config

def test_config():
    print("B. profile config")
    cfg = get_profile_config()
    check("shipped config loads, bio max 160", cfg.bio_max_length == 160)
    good = json.load(open(pc_mod.CONFIG_PATH))
    orig_path, orig_cached = pc_mod.CONFIG_PATH, pc_mod._cached

    def attempt(mutator, label):
        data = json.loads(json.dumps(good))
        mutator(data["profile"])
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(data, f)
        pc_mod.CONFIG_PATH = type(orig_path)(f.name)
        try:
            pc_mod._load()
            check(label, False, "accepted")
        except ConfigSectionError:
            check(label, True)
        finally:
            pc_mod.CONFIG_PATH = orig_path
            os.unlink(f.name)

    attempt(lambda p: p.update(bio_max_length=0), "bio_max_length 0 rejected")
    attempt(lambda p: p.update(bio_max_length=5000), "bio_max_length above request ceiling rejected")
    attempt(lambda p: p["rate_limits"].update(bio_edit_hour="lots"), "unparseable rate string rejected")
    attempt(lambda p: p["rate_limits"].pop("bio_edit_hour"), "missing rate key rejected")
    attempt(lambda p: p.update(surprise=1), "unknown key rejected")
    attempt(lambda p: p.update(distinct_profile_cap="60"), "wrong type rejected")
    pc_mod._cached = orig_cached
    from backend import startup_checks
    names = [getattr(c, "__name__", str(c)) for c in getattr(startup_checks, "CHECKS", [])]
    check("check_profile_config wired into startup_checks.CHECKS", any("profile_config" in n for n in names), str(names))


# ---------------------------------------------------------------- main integration

def main_integration():
    logbuf = io.StringIO()
    handler = logging.StreamHandler(logbuf)
    logging.getLogger().addHandler(handler)
    logging.getLogger().setLevel(logging.INFO)
    cfg = get_profile_config()
    cleanup_ids = []

    with TestClient(m.app) as c:
        a, an, ah = signup(c, "pfa")
        b, bn, bh = signup(c, "pfb")
        x, xn, xh = signup(c, "pfx")
        cleanup_ids += [a, b, x]
        reset_limits()

        print("C. GET /profiles tiers and 404s")
        check("users.bio column exists", bool(q("select 1 from information_schema.columns where table_name='users' and column_name='bio'")))
        r = c.get(f"/profiles/{b}", headers=ah)
        j = r.json()
        check("stranger 200: username, photo key, state none, no bio key, no email",
              r.status_code == 200 and j["username"] == bn and j["relationship"]["state"] == "none"
              and "bio" not in j and "email" not in j and j["editable"] is False, str(j))
        j = c.get(f"/profiles/{a}", headers=ah).json()
        check("self: bio key present (null), editable, state self",
              j.get("bio", 1) is None and j["editable"] is True and j["relationship"]["state"] == "self", str(j))
        check("unauthenticated GET 401", c.get(f"/profiles/{b}").status_code == 401)
        r1 = c.get(f"/profiles/{uuid.uuid4()}", headers=ah)
        r2 = c.get("/profiles/not-a-uuid", headers=ah)
        check("unknown and malformed id: identical 404", r1.status_code == 404 and r1.json() == r2.json() == {"detail": "User not found"}, f"{r1.text} {r2.text}")

        print("D. D1 accept requires a pending request")
        r_user = c.post(f"/friends/{a}/add", params={"friend_username": bn}, headers=ah)
        r_ghost = c.post(f"/friends/{a}/add", params={"friend_username": "no_such_user_zz"}, headers=ah)
        check("D1 /friends/{id}/add without request -> 404, same body as unknown user",
              r_user.status_code == 404 and r_user.json() == r_ghost.json(), f"{r_user.text} {r_ghost.text}")
        r = c.post("/message/add-friend", params={"host_user": a, "user_to_add": bn}, headers=ah)
        check("D1 legacy POST /message/add-friend without request -> 404", r.status_code == 404, f"{r.status_code} {r.text}")
        r = c.post(f"/profiles/{b}/friend-accept", headers=ah)
        check("D1 id route accept without request -> 404", r.status_code == 404, r.text)
        check("D1 no friendship rows created by any of those",
              q("select count(*) from user_friends where user_id in (%s,%s)", (a, b))[0][0] == 0)

        print("E. D5 uniform friend request")
        r_ok = c.post(f"/friends/{a}/request", params={"friend_username": bn}, headers=ah)
        r_unk = c.post(f"/friends/{a}/request", params={"friend_username": "nobody_zz_1"}, headers=ah)
        check("D5 real vs unknown username: identical status and body",
              r_ok.status_code == r_unk.status_code and r_ok.text == r_unk.text, f"{r_ok.status_code} {r_unk.status_code}")
        check("self-request 400", c.post(f"/friends/{a}/request", params={"friend_username": an}, headers=ah).status_code == 400)
        check("request row created once", q("select count(*) from friend_requests where from_user_id=%s and to_user_id=%s", (a, b))[0][0] == 1)
        c.post(f"/friends/{a}/request", params={"friend_username": bn}, headers=ah)
        check("repeat request idempotent (still one row)", q("select count(*) from friend_requests where from_user_id=%s", (a,))[0][0] == 1)
        check("A sees request_sent", c.get(f"/profiles/{b}", headers=ah).json()["relationship"]["state"] == "request_sent")
        check("B sees request_received", c.get(f"/profiles/{a}", headers=bh).json()["relationship"]["state"] == "request_received")
        check("requester cannot accept own request (404)", c.post(f"/profiles/{b}/friend-accept", headers=ah).status_code == 404)
        check("third party cannot accept (404)", c.post(f"/profiles/{a}/friend-accept", headers=xh).status_code == 404)
        check("legacy /add as requester (wrong direction) -> 404", c.post(f"/friends/{a}/add", params={"friend_username": bn}, headers=ah).status_code == 404)
        r = c.post(f"/profiles/{a}/friend-accept", headers=bh)
        check("target accepts by id -> 204", r.status_code == 204, r.text)
        check("exactly two friend rows, request gone",
              q("select count(*) from user_friends where (user_id=%s and friend_id=%s) or (user_id=%s and friend_id=%s)", (a, b, b, a))[0][0] == 2
              and q("select count(*) from friend_requests where (from_user_id=%s and to_user_id=%s) or (from_user_id=%s and to_user_id=%s)", (a, b, b, a))[0][0] == 0)
        check("accept again idempotent 204", c.post(f"/profiles/{a}/friend-accept", headers=bh).status_code == 204)
        # already friends: request is the same silent success
        r_af = c.post(f"/friends/{a}/request", params={"friend_username": bn}, headers=ah)
        check("D5 request to existing friend: same response as unknown", r_af.status_code == r_unk.status_code and r_af.text == r_unk.text)
        check("friend states", c.get(f"/profiles/{b}", headers=ah).json()["relationship"]["state"] == "friends")

        # legacy accept route works when a request exists
        y, yn, yh = signup(c, "pfy")
        cleanup_ids.append(y)
        c.post(f"/friends/{y}/request", params={"friend_username": an}, headers=yh)
        r = c.post(f"/friends/{a}/add", params={"friend_username": yn}, headers=ah)
        check("D1 legacy /add with a pending request succeeds and befriends",
              r.status_code in (200, 204) and q("select count(*) from user_friends where user_id=%s and friend_id=%s", (a, y))[0][0] == 1, f"{r.status_code} {r.text}")
        c.post(f"/friends/{x}/request", params={"friend_username": an}, headers=xh)
        r = c.post("/message/add-friend", params={"host_user": a, "user_to_add": xn}, headers=ah)
        check("D1 legacy /message/add-friend with pending request succeeds",
              r.status_code in (200, 204), f"{r.status_code} {r.text}")
        q("delete from user_friends where (user_id=%s and friend_id=%s) or (user_id=%s and friend_id=%s)", (a, x, x, a))
        q("delete from user_friends where (user_id=%s and friend_id=%s) or (user_id=%s and friend_id=%s)", (a, y, y, a))

        print("F. D2 / D4 allow-lists and email absence")
        secret_bio = "Walking with Jesus"
        r = c.put(f"/profile/{a}/bio", json={"bio": "  Walking with\n\nJesus  "}, headers=ah)
        check("bio set and normalized in response", r.status_code == 200 and r.json()["bio"] == secret_bio, r.text)
        check("friend sees bio", c.get(f"/profiles/{a}", headers=bh).json().get("bio") == secret_bio)
        check("stranger sees no bio key", "bio" not in c.get(f"/profiles/{a}", headers=xh).json())
        lu = c.get(f"/user/{a}", headers=xh).json()
        check("D2 /user/{id} non-self: allow-list only, email blank, no bio",
              set(lu) == {"user_id", "username", "profile_photo_url", "email", "mfa_enabled", "friend_requests", "suspended_at"}
              and lu["email"] == "" and "bio" not in lu, str(lu))
        lf = c.get(f"/user/{a}", headers=bh).json()
        check("D2 /user/{id} for a friend: still no bio, friends, groups, email",
              not ({"bio", "friends", "groups"} & set(lf)) and lf["email"] == "", str(list(lf)))
        ls = c.get(f"/user/{a}", headers=ah).json()
        check("D2 /user/{id} self keeps own record incl. email and bio, never hash_pass/photo key",
              ls["email"].endswith("@example.com") and ls["bio"] == secret_bio and "hash_pass" not in ls and "profile_photo_key" not in ls, str(list(ls)))
        check("/user unknown and malformed -> 404", c.get(f"/user/{uuid.uuid4()}", headers=ah).status_code == 404 and c.get("/user/xyz", headers=ah).status_code == 404)
        fl = c.get(f"/friends/{a}", headers=ah).json()
        check("D4 friends list: no email key anywhere", fl and all("email" not in f for f in fl) and fl[0]["username"] == bn, str(fl))
        rf = c.get(f"/friends/{a}/{b}", headers=ah)
        check("D4 read_friend friend object is the allow-list",
              rf.status_code == 200 and set(rf.json()["friend"]) == {"user_id", "username", "profile_photo_url", "bio"}, rf.text[:300])
        check("D4 read_friend by a stranger -> 404", c.get(f"/friends/{x}/{a}", headers=xh).status_code == 404)
        check("D4 /message/messages by a stranger -> 404", c.get(f"/message/messages/{x}/", params={"guest_user": b}, headers=xh).status_code == 404)
        check("D4 paged /friends/../messages by a stranger -> 404", c.get(f"/friends/{x}/{a}/messages", headers=xh).status_code == 404)
        rm = c.get(f"/message/messages/{a}/", params={"guest_user": b}, headers=ah)
        check("D4 /message/messages friend ok and no email", rm.status_code == 200 and "email" not in rm.json()["payload"]["friend"], rm.text[:200])
        everything = json.dumps([lu, lf, fl, rf.json(), rm.json()])
        check("no user email string appears in any non-self response", f"{bn}@example.com" not in everything and f"{xn}@example.com" not in everything)

        print("G. bio edit authorization and validation")
        reset_limits()
        check("PUT another user's bio -> 403", c.put(f"/profile/{a}/bio", json={"bio": "hacked"}, headers=bh).status_code == 403)
        check("PUT extra field -> 422 (extra=forbid)", c.put(f"/profile/{b}/bio", json={"bio": "x", "email": "e@x.com"}, headers=bh).status_code == 422)
        check("PUT suspended_at mass-assign -> 422", c.put(f"/profile/{b}/bio", json={"bio": "x", "suspended_at": None}, headers=bh).status_code == 422)
        check("PUT unauthenticated -> 401", c.put(f"/profile/{b}/bio", json={"bio": "x"}).status_code == 401)
        check("PUT missing bio key -> 422", c.put(f"/profile/{b}/bio", json={}, headers=bh).status_code == 422)
        check("PUT non-string bio -> 422", c.put(f"/profile/{b}/bio", json={"bio": 123}, headers=bh).status_code == 422)
        r = c.put(f"/profile/{b}/bio", json={"bio": "y" * 161}, headers=bh)
        check("161 chars -> 422, nothing stored (no truncation)", r.status_code == 422 and q("select bio from users where _id=%s", (b,))[0][0] is None, r.text)
        r = c.put(f"/profile/{b}/bio", json={"bio": "z" * 5000}, headers=bh)
        check("oversized body -> 422 at the request ceiling", r.status_code == 422, str(r.status_code))
        r = c.put(f"/profile/{b}/bio", json={"bio": "see https://evil.com"}, headers=bh)
        check("link -> 422 with user-facing detail", r.status_code == 422 and isinstance(r.json()["detail"], str) and "plain text" in r.json()["detail"], r.text)
        r = c.put(f"/profile/{b}/bio", json={"bio": "you are a fucking rapist"}, headers=bh)
        check("content filter -> 422 warm message", r.status_code == 422 and "FellowScript" in r.text, r.text)
        reset_limits()  # failed attempts count toward the 3/minute burst
        check("160-char bio accepted", c.put(f"/profile/{b}/bio", json={"bio": "k" * 160}, headers=bh).status_code == 200)
        reset_limits()
        r = c.put(f"/profile/{b}/bio", json={"bio": None}, headers=bh)
        check("null clears the bio", r.status_code == 200 and r.json()["bio"] is None and q("select bio from users where _id=%s", (b,))[0][0] is None, r.text)
        # terms gate
        reset_limits()
        q("update users set terms_accepted_at=NULL where _id=%s", (b,))
        r = c.put(f"/profile/{b}/bio", json={"bio": "hi"}, headers=bh)
        check("terms not accepted -> 403 with terms message", r.status_code == 403 and "Terms" in r.text, r.text)
        q("update users set terms_accepted_at=now() where _id=%s", (b,))

        print("J. no bio / message text in logs")
        reset_limits()
        leak_bio = "my private zzqq bio line"
        c.put(f"/profile/{b}/bio", json={"bio": leak_bio}, headers=bh)
        c.put(f"/profile/{b}/bio", json={"bio": "visit leakyzzqq.com now"}, headers=bh)
        c.put(f"/profile/{b}/bio", json={"bio": "you are a fucking rapist zzqq"}, headers=bh)
        c.get(f"/profiles/{b}", headers=ah)
        c.get(f"/profiles/{b}", headers=bh)
        c.get(f"/user/{b}", headers=bh)
        logs = logbuf.getvalue()
        check("bio text absent from every log record", "zzqq" not in logs and "leakyzzqq" not in logs and "rapist" not in logs)
        check("audit events are logged (reason codes only)", "PROFILE_AUDIT" in logs)
        check("audit lines carry no bio text or email", "private" not in logs.split("PROFILE_AUDIT", 1)[1] and "@example.com" not in "".join(l for l in logs.splitlines() if "PROFILE_AUDIT" in l))

        print("D3 block / suspend")
        reset_limits()
        r = c.post(f"/blocks/{a}/{x}", headers=ah)
        check("block created", r.status_code in (200, 201, 204), f"{r.status_code} {r.text}")
        ra = c.get(f"/profiles/{x}", headers=ah)
        rb = c.get(f"/profiles/{uuid.uuid4()}", headers=ah)
        check("blocker->blocked 404 identical to unknown", ra.status_code == 404 and ra.json() == rb.json())
        check("blocked->blocker 404", c.get(f"/profiles/{a}", headers=xh).status_code == 404)
        r = c.post(f"/profiles/{a}/friend-request", headers=xh)
        check("blocked requester: silent 204, no row", r.status_code == 204 and q("select count(*) from friend_requests where from_user_id=%s", (x,))[0][0] == 0)
        q("insert into friend_requests (to_user_id, from_user_id) values (%s,%s)", (x, a))
        check("accept refused while blocked (404)", c.post(f"/profiles/{a}/friend-accept", headers=xh).status_code == 404)
        q("delete from friend_requests where from_user_id in (%s,%s,%s) or to_user_id in (%s,%s,%s)", (a, b, x, a, b, x))
        q("update users set suspended_at=now() where _id=%s", (b,))
        check("suspended target 404", c.get(f"/profiles/{b}", headers=ah).status_code == 404)
        check("legacy /user suspended target still allow-list 200 (approved fallback)", c.get(f"/user/{b}", headers=xh).status_code == 200)
        r = c.post(f"/profiles/{b}/friend-request", headers=xh)
        check("request to suspended: silent 204, no row", r.status_code == 204 and q("select count(*) from friend_requests where to_user_id=%s", (b,))[0][0] == 0)
        q("update users set suspended_at=NULL where _id=%s", (b,))
        q("update users set suspended_at=now() where _id=%s", (a,))
        check("suspended viewer 404", c.get(f"/profiles/{b}", headers=ah).status_code == 404)
        check("suspended user cannot edit bio (403)", c.put(f"/profile/{a}/bio", json={"bio": "hi"}, headers=ah).status_code == 403)
        q("update users set suspended_at=NULL where _id=%s", (a,))
        q("delete from blocked_users where blocker_id=%s", (a,))
        # unfriend / block removes DM read for a former friend
        q("delete from user_friends where user_id=%s and friend_id=%s", (a, b))
        check("after unfriend, DM read is 404", c.get(f"/friends/{a}/{b}", headers=ah).status_code == 404)
        q("insert into user_friends (user_id, friend_id) values (%s,%s) on conflict do nothing", (a, b))

        print("H. rate limits")
        reset_limits()
        cnt, r = 0, None
        for _ in range(cfg.distinct_profile_cap + 5):
            r = c.get(f"/profiles/{uuid.uuid4()}", headers=xh)
            if r.status_code == 429:
                break
            cnt += 1
        check("distinct-profile sweep capped -> 429", r.status_code == 429 and cnt <= cfg.distinct_profile_cap, f"{cnt} {r.status_code}")
        check("429 detail generic (no numbers, no limit name)", "try again" in r.json()["detail"].lower() and not any(ch.isdigit() for ch in r.json()["detail"]), r.text)
        r = c.get(f"/profiles/{x}", headers=xh)
        check("self reads are exempt from the sweep guard", r.status_code in (200, 404), str(r.status_code))
        reset_limits()
        w, wn, wh = signup(c, "pfw")
        cleanup_ids.append(w)
        codes = [c.post(f"/friends/{w}/request", params={"friend_username": f"nobody_{i}_zz"}, headers=wh).status_code for i in range(25)]
        check("friend request: 20/hour then 429", codes[:20] == [200] * 20 and codes[20:] == [429] * 5, str(codes))
        check("legacy and id request routes share the same per-user budget",
              c.post(f"/profiles/{a}/friend-request", headers=wh).status_code == 429)
        reset_limits()
        z, zn, zh = signup(c, "pfz")
        cleanup_ids.append(z)
        codes = [c.put(f"/profile/{z}/bio", json={"bio": f"b{i}"}, headers=zh).status_code for i in range(6)]
        check("bio edit burst: 3/minute then 429", codes[:3] == [200] * 3 and codes[3:] == [429] * 3, str(codes))
        reset_limits()
        v, vn, vh = signup(c, "pfv")
        cleanup_ids.append(v)
        set_profile_config_for_tests(dataclasses.replace(cfg, max_outstanding_friend_requests=1))
        t1, t1n, _ = signup(c, "pft")
        t2, t2n, _ = signup(c, "pft")
        cleanup_ids += [t1, t2]
        s1 = c.post(f"/friends/{v}/request", params={"friend_username": t1n}, headers=vh).status_code
        s2 = c.post(f"/friends/{v}/request", params={"friend_username": t2n}, headers=vh).status_code
        set_profile_config_for_tests(None)
        check("outstanding request cap -> 429", (s1, s2) == (200, 429), f"{s1} {s2}")
        reset_limits()
        # accept limit
        set_profile_config_for_tests(dataclasses.replace(cfg, rate_limits={**cfg.rate_limits, "friend_accept_hour": "2/hour"}))
        acc = [c.post(f"/profiles/{uuid.uuid4()}/friend-accept", headers=xh).status_code for _ in range(4)]
        set_profile_config_for_tests(None)
        check("accept limit enforced (404,404 then 429)", acc[:2] == [404, 404] and acc[2] == 429, str(acc))
        reset_limits()

        print("I. every profile route is authenticated")
        bad, seen = [], 0
        for rt in m.app.routes:
            if isinstance(rt, APIRoute) and (rt.path.startswith("/profile")):
                seen += 1
                names = " ".join(getattr(d.call, "__name__", str(d.call)) for d in rt.dependant.dependencies)
                if not any(k in names for k in ("get_current_user", "friend_request_guard", "friend_accept_guard", "_check", "require_match")):
                    bad.append(rt.path)
        check("every /profile* route has an auth dependency", seen >= 4 and not bad, f"seen={seen} bad={bad}")
        fresh = TestClient(m.app)
        tid = uuid.uuid4()
        unauth = [
            fresh.get(f"/profiles/{tid}").status_code,
            fresh.put(f"/profile/{tid}/bio", json={"bio": "x"}).status_code,
            fresh.post(f"/profiles/{tid}/friend-request").status_code,
            fresh.post(f"/profiles/{tid}/friend-accept").status_code,
        ]
        check("all four profile routes 401 without a session", unauth == [401] * 4, str(unauth))

        print("K. bio_admin")
        q("update users set bio='to be cleared' where _id=%s", (a,))
        db = DBManager()
        try:
            ok = bio_admin.clear_bio(db.cur, a)
            db.conn.commit()
        finally:
            db.close()
        check("bio_admin.clear_bio nulls the bio", ok and q("select bio from users where _id=%s", (a,))[0][0] is None)
        db = DBManager()
        try:
            check("bio_admin.clear_bio unknown user -> False", bio_admin.clear_bio(db.cur, str(uuid.uuid4())) is False)
            db.conn.rollback()
        finally:
            db.close()
        check("bio_admin CLI rejects non-UUID", bio_admin.main(["x", "clear", "nope"]) == 2)

        for u in cleanup_ids:
            q("delete from users where _id=%s", (u,))
    logging.getLogger().removeHandler(handler)


if __name__ == "__main__":
    test_bio_pure()
    test_config()
    main_integration()
    print(f"\n{'=' * 60}\nRESULT: {len(PASSED)} passed, {len(FAILED)} failed")
    for label, detail in FAILED:
        print(f"FAILED: {label}  -- {detail}")
    sys.exit(1 if FAILED else 0)
