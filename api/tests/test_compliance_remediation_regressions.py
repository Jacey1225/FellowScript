"""Regression tests for the 20260830-compliance-remediation task's backend
fixes (steps 1-2 of that pipeline) that had no prior dedicated coverage.

Each section below proves the specific bug that finding fixed would be
caught by a regression, not just a generic smoke test:

  H1 + note-authorship-spoofing (security-gate-discovered, api/routes/notes.py
     create_note/update_note): a client-supplied group_id must require real
     group membership, AND a client-supplied "user" body field must NOT be
     able to attribute a note to a victim user_id other than the verified
     caller.

  H2 (api/routes/messaging.py chime_router): join_meeting must 403 a caller
     who is not authorized on the underlying devotion session (mirrors
     devotion.py::join_call's check, which this parallel implementation was
     missing).

  H3 (api/main.py GET /user/{user_id}): a lookup of someone else's user_id
     must have email/mfa_enabled/friend_requests/suspended_at blanked; a
     self-lookup must still see real values.

  H4 (api/routes/subscription.py delete_subscription): a failed Stripe
     cancellation must 502 and leave the local plan row intact, not silently
     delete it out from under a still-billing Stripe subscription.

  H5 (api/backend/interactions/agent.py commit_hb_response): an OpenRouter
     API failure after the heartbeat claim is taken must unset last_fired so
     a retry can go through, not permanently burn the day's claim.

  M2 (api/main.py mfa_confirm/mfa_disable): must be rate-limited like the
     sibling mfa_verify_login/login endpoints.

  M4 (api/backend/monitoring/cloudwatch_mcp_client.py _subprocess_env):
     must only forward an explicit AWS/PATH/HOME allowlist, not the full
     process environment (which would leak DB_PASSWORD/STRIPE_SECRET_KEY/etc.
     to the MCP subprocess).

  L1 (api/db.py create_tables admin seed): ADMIN_SEED_EMAIL env var must
     override the hardcoded default.

  L2 (api/main.py CORS): allow_credentials must be explicitly False (no
     Access-Control-Allow-Credentials header echoed back).

  M3 (api/backend/interactions/agent.py connect_agent): a per-connection
     sliding-window cap of 20 messages/60s must reject the 21st rapid
     message with a client-visible error frame (not silently drop it, not
     disconnect), while the first 20 still get normal assistant replies.

  M6 (api/db.py): importing db with DB_PASSWORD unset/empty must fail fast
     with a clear RuntimeError naming DB_PASSWORD, not proceed and fail
     opaquely inside the first real Postgres connection attempt.

  dependency-errors #3 (api/routes/agent.py summarize_session): an
     OpenRouter failure during session summarization must surface as a 502,
     not an unhandled 500, matching the Stripe-checkout error-handling
     pattern used elsewhere in the same file.

Run with: cd api && ../.venv/bin/python tests/test_compliance_remediation_regressions.py
"""
import _pathfix  # noqa: F401,E402

import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import db as db_module  # noqa: E402
import main as main_module  # noqa: E402
from backend.interactions.groups import GroupsManager  # noqa: E402
from backend.interactions.devotion import DevotionManager  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402
from schemas.agent import AgentHeartbeats  # noqa: E402
from schemas.devotion import DevotionPlan  # noqa: E402
from schemas.subscription import SubscriptionCreate  # noqa: E402
from backend.subscription.subscriptions import SubscriptionsManager  # noqa: E402
from backend.subscription import stripe_service  # noqa: E402
from backend.monitoring.cloudwatch_mcp_client import _subprocess_env, _SUBPROCESS_ENV_ALLOWLIST  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def cookie_header(token: str):
    return {"cookie": f"session={token}"} if token else {}


def signup(client, username):
    # This file signs up more users than /signup's 5-per-minute-per-IP rate
    # limit (M2's sibling finding, already covered by test_security_hardening.py)
    # allows from a single "IP" -- give each signup its own CF-Connecting-IP
    # so this file's fixture setup doesn't trip the very limiter it isn't
    # testing here. Mirrors get_client_ip's real Cloudflare-header precedence.
    fake_ip = f"203.0.113.{uuid.uuid4().int % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def cleanup_users(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            # notes.user_id has no ON DELETE CASCADE -- clear any notes this
            # user authored first so the user row itself can be deleted.
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def test_h1_group_membership_and_authorship_spoofing(client):
    print("\n=== H1 + note-authorship-spoofing: create_note ===")
    uid_owner, tok_owner = signup(client, f"h1_owner_{uuid.uuid4().hex[:8]}")
    uid_outsider, tok_outsider = signup(client, f"h1_outsider_{uuid.uuid4().hex[:8]}")
    uid_victim, tok_victim = signup(client, f"h1_victim_{uuid.uuid4().hex[:8]}")
    try:
        gid = str(uuid.uuid4())
        r = client.post(f"/groups/{uid_owner}", json={"group_id": gid, "title": "H1 group", "users": [uid_owner]},
                         headers=cookie_header(tok_owner))
        check("group created", r.status_code == 201, str(r.status_code) + " " + r.text)

        # H1: outsider (not a member of gid) tries to post a note into it.
        r = client.post(f"/notes/{uid_outsider}", json={
            "user": uid_outsider, "title": "sneaky", "text": "body", "public": True,
            "group_id": gid, "verses": [[], []],
        }, headers=cookie_header(tok_outsider))
        check("non-member posting into group_id -> 403", r.status_code == 403, str(r.status_code) + " " + r.text)

        # Authorship spoofing: outsider posts a PERSONAL note (no group_id)
        # but sets body "user" to the victim's id -- must be attributed to
        # the verified caller (outsider), never the victim.
        r = client.post(f"/notes/{uid_outsider}", json={
            "user": uid_victim, "title": "spoofed", "text": "body", "public": False,
            "group_id": "", "verses": [[], []],
        }, headers=cookie_header(tok_outsider))
        check("spoofed-author note create -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)
        note_id = r.json()["id"]

        db = DBManager()
        try:
            db.cur.execute("SELECT user_id FROM notes WHERE _id = %s", (note_id,))
            row = db.cur.fetchone()
        finally:
            db.close()
        check("note attributed to real caller (outsider), NOT the spoofed 'user' field",
              row is not None and str(row[0]) == uid_outsider, str(row))

        # Regression guard: victim's own notes list must NOT show this note.
        r = client.get(f"/notes/{uid_victim}", headers=cookie_header(tok_victim))
        check("spoofed note does not appear under the victim's own notes",
              note_id not in r.json().get("notes", {}), str(r.json()))

        # Member of the group CAN post into it (regression check the fix
        # didn't overtighten legitimate access).
        r = client.post(f"/notes/{uid_owner}", json={
            "user": uid_owner, "title": "legit", "text": "body", "public": True,
            "group_id": gid, "verses": [[], []],
        }, headers=cookie_header(tok_owner))
        check("member posting into their own group -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)

        # H1 on update_note: outsider cannot re-target an existing owned note
        # at a group they don't belong to.
        r = client.post(f"/notes/{uid_outsider}", json={
            "user": uid_outsider, "title": "mine", "text": "body", "public": False,
            "group_id": "", "verses": [[], []],
        }, headers=cookie_header(tok_outsider))
        own_note_id = r.json()["id"]
        r = client.put(f"/notes/{uid_outsider}?note_id={own_note_id}", json={
            "user": uid_outsider, "title": "mine", "text": "body2", "public": False,
            "group_id": gid, "verses": [[], []],
        }, headers=cookie_header(tok_outsider))
        check("update_note re-targeting a group the caller doesn't belong to -> 403",
              r.status_code == 403, str(r.status_code) + " " + r.text)
    finally:
        cleanup_users(uid_owner, uid_outsider, uid_victim)


def test_h2_chime_join_meeting_authorization(client):
    print("\n=== H2: messaging.py chime_router join_meeting authorization ===")
    uid_owner, tok_owner = signup(client, f"h2_owner_{uuid.uuid4().hex[:8]}")
    uid_outsider, tok_outsider = signup(client, f"h2_outsider_{uuid.uuid4().hex[:8]}")
    session_id = str(uuid.uuid4())
    try:
        dm = DevotionManager()
        try:
            dm.save_devotion(DevotionPlan(
                id=session_id, title="H2 session", creator_id=uid_owner,
                participants=[uid_owner], group_id="",
            ))
        finally:
            dm.close()

        r = client.post(f"/chime/{session_id}/{uid_outsider}/attend", headers=cookie_header(tok_outsider))
        check("non-participant attend -> 403", r.status_code == 403, str(r.status_code) + " " + r.text)

        # Owner IS authorized -- gets past the auth check to the "no active
        # meeting yet" business-logic branch (400), proving is_authorized
        # passed for a legitimate participant (regression check).
        r = client.post(f"/chime/{session_id}/{uid_owner}/attend", headers=cookie_header(tok_owner))
        check("participant attend with no active meeting -> 400 (authorized, business-logic branch)",
              r.status_code == 400, str(r.status_code) + " " + r.text)
    finally:
        dm2 = DevotionManager()
        try:
            dm2.delete("devotions", {"_id": session_id})
        finally:
            dm2.close()
        cleanup_users(uid_owner, uid_outsider)


def test_h3_user_lookup_data_exposure(client):
    print("\n=== H3: GET /user/{user_id} data exposure ===")
    uid_a, tok_a = signup(client, f"h3_a_{uuid.uuid4().hex[:8]}")
    uid_b, tok_b = signup(client, f"h3_b_{uuid.uuid4().hex[:8]}")
    try:
        r = client.get(f"/user/{uid_a}", headers=cookie_header(tok_a))
        check("self-lookup returns real email", r.status_code == 200 and "@example.com" in r.json().get("email", ""),
              str(r.json()))

        r = client.get(f"/user/{uid_a}", headers=cookie_header(tok_b))
        data = r.json()
        check("cross-user lookup: email blanked", data.get("email") == "", str(data))
        check("cross-user lookup: mfa_enabled blanked", data.get("mfa_enabled") is False, str(data))
        check("cross-user lookup: friend_requests blanked", data.get("friend_requests") == [], str(data))
        check("cross-user lookup: suspended_at blanked", data.get("suspended_at") is None, str(data))
        check("cross-user lookup: username still visible (legit use case)",
              data.get("username", "").startswith("h3_a_"), str(data))
    finally:
        cleanup_users(uid_a, uid_b)


def test_h4_stripe_cancel_failure_preserves_local_row(client):
    print("\n=== H4: delete_subscription does not delete local row on Stripe failure ===")
    uid, tok = signup(client, f"h4_host_{uuid.uuid4().hex[:8]}")
    try:
        sm = SubscriptionsManager()
        try:
            sub_id = sm.create_subscription(SubscriptionCreate(
                user_id=uid, provider="stripe", member_count=1,
                stripe_customer_id="cus_test", default_payment_method_id="",
                card_brand="", card_last4="", card_exp_month="", card_exp_year="",
            ))
            sm.cur.execute("UPDATE subscriptions SET stripe_subscription_id = %s WHERE _id = %s",
                            ("sub_fake_123", sub_id))
            sm.conn.commit()
        finally:
            sm.close()

        orig_cancel = stripe_service.cancel_subscription
        stripe_service.cancel_subscription = lambda sub: False
        try:
            r = client.delete(f"/subscriptions/{sub_id}", headers=cookie_header(tok))
            check("failed Stripe cancellation -> 502", r.status_code == 502, str(r.status_code) + " " + r.text)
        finally:
            stripe_service.cancel_subscription = orig_cancel

        db = DBManager()
        try:
            db.cur.execute("SELECT 1 FROM subscriptions WHERE _id = %s", (sub_id,))
            still_there = db.cur.fetchone() is not None
        finally:
            db.close()
        check("local subscription row NOT deleted after a failed Stripe cancel", still_there, str(still_there))

        # Regression check: a successful cancel still deletes the row.
        stripe_service.cancel_subscription = lambda sub: True
        try:
            r = client.delete(f"/subscriptions/{sub_id}", headers=cookie_header(tok))
            check("successful Stripe cancellation -> 204", r.status_code == 204, str(r.status_code) + " " + r.text)
        finally:
            stripe_service.cancel_subscription = orig_cancel
    finally:
        cleanup_users(uid)


def test_h5_heartbeat_claim_rollback_on_api_failure():
    print("\n=== H5: commit_hb_response rolls back the claim on _call_api failure ===")
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"h5_{uid[:8]}", "email": f"h5_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
    agent_id = str(uuid.uuid4())
    hb_id = str(uuid.uuid4())
    try:
        dbi = DBManager()
        try:
            dbi.cur.execute("INSERT INTO agents (_id, user_id, role, chats) VALUES (%s, %s, %s, %s)",
                            (agent_id, uid, "", []))
            dbi.conn.commit()
        finally:
            dbi.close()

        am = AgentManager(uid)
        am.add_heartbeat(AgentHeartbeats(agent_id=agent_id, user_id=uid, prompt="daily prompt"))
        hb_rows = am.get_heartbeats(agent_id)
        hb_id = list(hb_rows.keys())[0] if isinstance(hb_rows, dict) else hb_rows[0]["_id"]

        class BoomAgentManager(AgentManager):
            def _call_api(self, agent_role, messages):
                raise RuntimeError("simulated OpenRouter outage")

        boom = BoomAgentManager(uid)
        try:
            result = boom.commit_hb_response(agent_id, hb_id, "daily prompt")
        finally:
            boom.close()
        check("API failure returns an error dict, not an exception escaping",
              isinstance(result, dict) and "error" in result, str(result))

        db2 = DBManager()
        try:
            db2.cur.execute("SELECT last_fired FROM agent_heartbeats WHERE _id = %s", (hb_id,))
            row = db2.cur.fetchone()
        finally:
            db2.close()
        check("last_fired rolled back to NULL after the API failure (claim not permanently burned)",
              row is not None and row[0] is None, str(row))

        # Regression: a retry (this time succeeding) can now claim the slot.
        class OkAgentManager(AgentManager):
            def _call_api(self, agent_role, messages):
                return '{"__action": "create_note", "title": "t", "text": "b"}'

        ok = OkAgentManager(uid)
        try:
            result2 = ok.commit_hb_response(agent_id, hb_id, "daily prompt")
        finally:
            ok.close()
        check("retry after rollback succeeds", result2 == {"success": "saved note"}, str(result2))
    finally:
        cleanup_users(uid)


def test_m2_mfa_confirm_disable_rate_limited(client):
    print("\n=== M2: mfa_confirm/mfa_disable rate limiting ===")
    uid, tok = signup(client, f"m2_{uuid.uuid4().hex[:8]}")
    try:
        codes_confirm = [
            client.post("/auth/mfa/confirm", json={"user_id": uid, "code": "000000"},
                        headers=cookie_header(tok)).status_code
            for _ in range(12)
        ]
        check("mfa_confirm brute-forcing eventually hits 429", 429 in codes_confirm, str(codes_confirm))

        codes_disable = [
            client.post("/auth/mfa/disable", json={"plain_pass": "wrong"},
                        headers=cookie_header(tok)).status_code
            for _ in range(12)
        ]
        check("mfa_disable brute-forcing eventually hits 429", 429 in codes_disable, str(codes_disable))
    finally:
        cleanup_users(uid)


def test_m4_cloudwatch_subprocess_env_allowlist():
    print("\n=== M4: cloudwatch_mcp_client subprocess env allowlist ===")
    sentinel = f"leak-me-{uuid.uuid4().hex[:8]}"
    os.environ["DB_PASSWORD_TEST_SENTINEL_STRIPE_SECRET_KEY_LEAK_PROBE"] = sentinel
    try:
        env = _subprocess_env()
        check("only allowlisted keys are forwarded",
              set(env.keys()) <= set(_SUBPROCESS_ENV_ALLOWLIST), str(set(env.keys()) - set(_SUBPROCESS_ENV_ALLOWLIST)))
        check("the arbitrary non-allowlisted var is NOT forwarded",
              "DB_PASSWORD_TEST_SENTINEL_STRIPE_SECRET_KEY_LEAK_PROBE" not in env, str(env))
        check("PATH is still forwarded (subprocess needs it to resolve the binary)",
              "PATH" in env or "PATH" not in os.environ, str(env))
    finally:
        del os.environ["DB_PASSWORD_TEST_SENTINEL_STRIPE_SECRET_KEY_LEAK_PROBE"]


def test_l1_admin_seed_email_env_override():
    print("\n=== L1: ADMIN_SEED_EMAIL env var override ===")
    decoy_email = f"decoy_admin_{uuid.uuid4().hex[:8]}@example.com"
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"l1_{uid[:8]}", "email": decoy_email, "hash_pass": "x"})
    finally:
        db.close()

    orig_env = os.environ.get("ADMIN_SEED_EMAIL")
    os.environ["ADMIN_SEED_EMAIL"] = decoy_email
    try:
        conn = db_module._connect()
        cur = conn.cursor()
        try:
            db_module.create_tables(cur)
            conn.commit()
        finally:
            cur.close()
            conn.close()

        db2 = DBManager()
        try:
            db2.cur.execute("SELECT is_admin FROM users WHERE _id = %s", (uid,))
            row = db2.cur.fetchone()
        finally:
            db2.close()
        check("decoy account promoted to admin via ADMIN_SEED_EMAIL override",
              row is not None and row[0] is True, str(row))
    finally:
        if orig_env is None:
            os.environ.pop("ADMIN_SEED_EMAIL", None)
        else:
            os.environ["ADMIN_SEED_EMAIL"] = orig_env
        cleanup_users(uid)
        # Restore the real default admin seed (idempotent, matches production
        # deploy behavior) now that ADMIN_SEED_EMAIL is unset again.
        conn = db_module._connect()
        cur = conn.cursor()
        try:
            db_module.create_tables(cur)
            conn.commit()
        finally:
            cur.close()
            conn.close()


def test_l2_cors_no_implicit_credentials(client):
    print("\n=== L2: CORS allow_credentials is explicitly False ===")
    r = client.options("/login", headers={
        "Origin": "https://fellowscript.com",
        "Access-Control-Request-Method": "POST",
    })
    check("allowed origin preflight has no Access-Control-Allow-Credentials header",
          r.headers.get("access-control-allow-credentials") is None,
          str(r.headers.get("access-control-allow-credentials")))


def test_m3_agent_ws_chat_rate_limit(client):
    print("\n=== M3: agent WS chat loop per-connection rate cap ===")
    import backend.interactions.agent as agent_module

    uid, tok = signup(client, f"m3_{uuid.uuid4().hex[:8]}")
    agent_id = str(uuid.uuid4())
    try:
        db = DBManager()
        try:
            db.cur.execute("INSERT INTO agents (_id, user_id, role, chats) VALUES (%s, %s, %s, %s)",
                            (agent_id, uid, "", []))
            db.conn.commit()
        finally:
            db.close()

        orig_call_api = agent_module.AgentManager._call_api
        agent_module.AgentManager._call_api = lambda self, agent_role, messages: "ok"
        try:
            cap = agent_module._CHAT_RATE_LIMIT_MESSAGES
            with client.websocket_connect(f"/agent/ws/{agent_id}/{uid}", headers=cookie_header(tok)) as ws:
                roles = []
                for i in range(cap + 3):
                    ws.send_json({"content": f"msg {i}"})
                    roles.append(ws.receive_json().get("role"))
                check(f"first {cap} messages are NOT rate-limited (all 'assistant')",
                      roles[:cap] == ["assistant"] * cap, str(roles[:cap]))
                check("messages beyond the cap ARE rate-limited ('error' role)",
                      all(r == "error" for r in roles[cap:]), str(roles[cap:]))
        finally:
            agent_module.AgentManager._call_api = orig_call_api
    finally:
        db2 = DBManager()
        try:
            db2.delete("agents", {"_id": agent_id})
        finally:
            db2.close()
        cleanup_users(uid)


def test_m6_db_password_fail_fast():
    print("\n=== M6: DB_PASSWORD fail-fast at import time ===")
    import subprocess
    import sys as _sys

    api_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ)
    env["DB_PASSWORD"] = ""  # present but empty -- must NOT be silently accepted
    proc = subprocess.run(
        [_sys.executable, "-c", "import db"],
        cwd=api_dir, env=env, capture_output=True, text=True, timeout=30,
    )
    check("importing db with empty DB_PASSWORD exits non-zero",
          proc.returncode != 0, f"returncode={proc.returncode} stderr={proc.stderr[-800:]}")
    check("failure names DB_PASSWORD, not an opaque psycopg2 connection error",
          "DB_PASSWORD" in proc.stderr, proc.stderr[-800:])


def test_dependency_errors_3_summarize_session_502_on_api_failure(client):
    print("\n=== dependency-errors #3: summarize_session surfaces 502 on _call_api failure ===")
    import backend.interactions.agent as agent_module

    uid, tok = signup(client, f"dep3_{uuid.uuid4().hex[:8]}")
    agent_id = str(uuid.uuid4())
    try:
        db = DBManager()
        try:
            db.cur.execute("INSERT INTO agents (_id, user_id, role, chats) VALUES (%s, %s, %s, %s)",
                            (agent_id, uid, "", []))
            db.conn.commit()
        finally:
            db.close()

        orig_call_api = agent_module.AgentManager._call_api

        def boom(self, agent_role, messages):
            raise RuntimeError("simulated OpenRouter outage")
        agent_module.AgentManager._call_api = boom
        try:
            r = client.post(f"/agent/{uid}/{agent_id}/summarize", json={
                "session": {"title": "T", "prompts": ["p1"], "verses": ["Gen 1:1"]},
            }, headers=cookie_header(tok))
            check("OpenRouter failure during summarize -> 502, not 500",
                  r.status_code == 502, str(r.status_code) + " " + r.text)
        finally:
            agent_module.AgentManager._call_api = orig_call_api

        # Regression: a successful call still creates the note as before.
        agent_module.AgentManager._call_api = lambda self, agent_role, messages: "a fine summary"
        try:
            r = client.post(f"/agent/{uid}/{agent_id}/summarize", json={
                "session": {"title": "T", "prompts": ["p1"], "verses": ["Gen 1:1"]},
            }, headers=cookie_header(tok))
            check("successful summarize still returns 201 with a note_id",
                  r.status_code == 201 and "note_id" in r.json(), str(r.status_code) + " " + r.text)
        finally:
            agent_module.AgentManager._call_api = orig_call_api
    finally:
        db2 = DBManager()
        try:
            db2.delete("agents", {"_id": agent_id})
        finally:
            db2.close()
        cleanup_users(uid)


def main():
    with TestClient(main_module.app) as client:
        test_h1_group_membership_and_authorship_spoofing(client)
        test_h2_chime_join_meeting_authorization(client)
        test_h3_user_lookup_data_exposure(client)
        test_h4_stripe_cancel_failure_preserves_local_row(client)
        test_h5_heartbeat_claim_rollback_on_api_failure()
        test_m2_mfa_confirm_disable_rate_limited(client)
        test_m3_agent_ws_chat_rate_limit(client)
        test_m4_cloudwatch_subprocess_env_allowlist()
        test_l1_admin_seed_email_env_override()
        test_l2_cors_no_implicit_credentials(client)
        test_dependency_errors_3_summarize_session_502_on_api_failure(client)

    # Run outside the TestClient's lifespan context -- this spawns its own
    # subprocess and doesn't touch the live app/db connection.
    test_m6_db_password_fail_fast()

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
