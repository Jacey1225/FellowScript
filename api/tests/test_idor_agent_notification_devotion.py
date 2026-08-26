"""Tests for the IDOR fixes (security audit findings 3, 5 — HIGH):

Finding 3 — Agent subsystem (api/backend/interactions/agent.py +
api/routes/agent.py): every /agent/{user_id}/... route checked the CALLER is
user_id (require_match), but never checked the referenced agent_id/
heartbeat_id/message_id BELONGS to that user_id. An attacker who is a
legitimate authenticated user of their own account could read/mutate/delete
another user's agent, messages, and heartbeats by guessing/observing their
UUIDs, and could connect to another user's agent WebSocket.

Finding 4 (formerly covered here) — api/backend/interactions/notifications.py's
get_notification() (used by GET /notification/{user_id}/{notif_id}, /trigger,
/next) had no user_id filter, letting any authenticated user read (and
AI-trigger) another user's notification via require_match on their OWN
user_id plus someone else's notif_id. That coverage was removed here on
2026-08-26 (.claude/pipeline/20260826-activity-based-notifications) because
the entire agentic/custom notification CRUD subsystem it tested — routes,
NotificationManager, schema, and the `notifications` table — was removed in
full, not because the underlying IDOR concern stopped mattering: the new
activity-tracked/fixed-notification system introduces its OWN cross-user
"friend went active" notification path, which gets fresh IDOR/privacy
coverage of its own once that system lands (per that task's step 3/4).

Finding 5 — api/routes/devotion.py + api/backend/interactions/devotion.py:
fetch/join/leave/join-call operated on any session_id with only
get_current_user/require_match(user_id) — no participant/group-membership
check, letting any authenticated user read a private session's prompts/
verses/Chime data, or join/leave/join-call on it uninvited.

Finding 5b — (added by the 20260808-ios-backend-integration-audit pipeline,
step 20/security) api/routes/devotion.py's update_devotion() was not part of
Finding 5's original fix: it only checked req.user_id == current_user (a
self-identity check, not an authorization check) before overwriting an
EXISTING session's title/prompts/verses by devotion_id — so any authenticated
user who knew/guessed another user's devotion_id could overwrite that
session's content even though they were never a participant/group member.
Fixed by adding the same db.get_session() + db.is_authorized() check the
other four routes in this finding already use. Covered below.

Every case below follows the same shape: a VICTIM creates a resource, an
ATTACKER (a different, otherwise-legitimate authenticated user) tries to
read/mutate/delete it by ID while authenticating as themselves, and the
resource must be inaccessible/unaffected — contrasted with the OWNER still
being able to access their own resource (regression check).

Run with: cd api && ../.venv/bin/python tests/test_idor_agent_notification_devotion.py
"""
import os
import sys
import uuid

import _pathfix  # noqa: F401,E402

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402

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
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    })
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def main():
    import main as main_module
    with TestClient(main_module.app) as client:
        uid_v, token_v = signup(client, f"idor_victim_{uuid.uuid4().hex[:8]}")   # owner of the resources
        uid_x, token_x = signup(client, f"idor_attacker_{uuid.uuid4().hex[:8]}")  # a different authenticated user

        try:
            # ── Finding 3: Agent subsystem IDOR ─────────────────────────────
            print("=== Agent subsystem ===")
            # NOTE: POST /agent/{user_id} (create_agent) is broken independent
            # of this security pass — it inserts "name"/"enabled" keys that
            # don't exist as columns on the local "agents" table (no
            # migration ever added them; db.insertion() swallows the
            # resulting psycopg2 error and still returns 201 with a fake id,
            # so the row is silently never persisted). That's a pre-existing
            # schema-drift bug unrelated to and untouched by this audit's
            # findings/fixes — flagged separately in the test report, not
            # fixed here. Work around it by seeding the agent row directly
            # with only the columns that actually exist, so the IDOR fixes
            # under test (update/delete/messages/heartbeats/ws ownership
            # checks) can be exercised against a real persisted row.
            agent_id = str(uuid.uuid4())
            db = DBManager()
            try:
                db.cur.execute(
                    "INSERT INTO agents (_id, user_id, role, chats) VALUES (%s, %s, %s, %s)",
                    (agent_id, uid_v, "Victim's Guide", []),
                )
                db.conn.commit()
            finally:
                db.close()

            r = client.get(f"/agent/{uid_x}/{agent_id}/messages", headers=cookie_header(token_x))
            check("attacker: get_messages on victim's agent -> empty, not 200-with-data",
                  r.status_code == 200 and r.json() == {}, str(r.status_code) + " " + str(r.json()))

            r = client.put(f"/agent/{uid_x}/{agent_id}", json={"role": "pwned"}, headers=cookie_header(token_x))
            check("attacker: update_agent on victim's agent -> 404", r.status_code == 404, str(r.status_code))

            db = DBManager()
            try:
                db.cur.execute("SELECT role FROM agents WHERE _id = %s", (agent_id,))
                row = db.cur.fetchone()
                check("victim's agent role untouched after attacker's update attempt",
                      row is not None and row[0] == "Victim's Guide", str(row))
            finally:
                db.close()

            r = client.delete(f"/agent/{uid_x}/{agent_id}", headers=cookie_header(token_x))
            # delete_agent has no separate not-found branch (idempotent DELETE
            # semantics), but critically the scoped delete must NOT remove
            # the victim's row — verified by the ownership-check below.
            check("attacker: delete_agent on victim's agent -> 204 (idempotent no-op)",
                  r.status_code == 204, str(r.status_code))
            r = client.get(f"/agent/{uid_v}", headers=cookie_header(token_v))
            check("victim's agent still exists after attacker's delete attempt",
                  agent_id in r.json(), str(r.json()))

            # Heartbeat: victim adds one (free-tier agent_events cap is 1/user).
            r = client.post(f"/agent/{uid_v}/{agent_id}/heartbeat",
                             json={"prompt": "victim's private heartbeat prompt", "timestamps": [None] * 31},
                             headers=cookie_header(token_v))
            check("victim adds a heartbeat -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)

            r = client.get(f"/agent/{uid_v}/{agent_id}/heartbeats", headers=cookie_header(token_v))
            check("victim can list own heartbeats -> 200 with 1 row",
                  r.status_code == 200 and len(r.json()) == 1, str(r.status_code) + " " + str(r.json()))
            hb_id = r.json()[0].get("_id") if r.json() else None

            r = client.get(f"/agent/{uid_x}/{agent_id}/heartbeats", headers=cookie_header(token_x))
            check("attacker: get_heartbeats on victim's agent -> empty list",
                  r.status_code == 200 and r.json() == [], str(r.status_code) + " " + str(r.json()))

            if hb_id:
                r = client.put(f"/agent/{uid_x}/{hb_id}/update_heartbeats",
                                json={"agent_id": agent_id, "prompt": "pwned prompt", "timestamps": [None] * 31},
                                headers=cookie_header(token_x))
                # Scoped UPDATE affects 0 rows either way, route still returns {"ok": True} —
                # the real assertion is that the underlying row is untouched.
                db = DBManager()
                try:
                    db.cur.execute("SELECT prompt FROM agent_heartbeats WHERE _id = %s", (hb_id,))
                    row = db.cur.fetchone()
                    check("victim's heartbeat prompt untouched by attacker's update_heartbeat call",
                          row is not None and row[0] == "victim's private heartbeat prompt", str(row))
                finally:
                    db.close()

                r = client.post(f"/agent/{uid_x}/{agent_id}/{hb_id}/commit_heartbeat",
                                 json={"prompt": "trigger"}, headers=cookie_header(token_x))
                check("attacker: commit_heartbeat on victim's heartbeat -> {'error': ...}, not a real fire",
                      r.status_code == 200 and "error" in r.json(), str(r.status_code) + " " + str(r.json()))

                r = client.delete(f"/agent/{uid_x}/{agent_id}/heartbeat/{hb_id}", headers=cookie_header(token_x))
                check("attacker: delete_heartbeat on victim's heartbeat -> 204 (scoped no-op)",
                      r.status_code == 204, str(r.status_code))
                r = client.get(f"/agent/{uid_v}/{agent_id}/heartbeats", headers=cookie_header(token_v))
                check("victim's heartbeat still exists after attacker's delete attempt",
                      len(r.json()) == 1, str(r.json()))

            # Agent WebSocket ownership. connect_agent() calls ws.accept()
            # BEFORE the owns_agent() check (so the handshake itself always
            # succeeds — this differs from the handshake-time identity check
            # in messaging/agent_ws_endpoint), then immediately closes with
            # code 4403 if the caller doesn't own agent_id. So the rejection
            # surfaces on the first receive after connecting, not on connect.
            from starlette.websockets import WebSocketDisconnect as _WSDisconnect
            try:
                with client.websocket_connect(f"/agent/ws/{agent_id}/{uid_x}", headers=cookie_header(token_x)) as ws:
                    ws.receive_json()
                    check("attacker connecting to victim's agent WS -> rejected", False, "server did not close")
            except _WSDisconnect as e:
                check("attacker connecting to victim's agent WS -> rejected (closed 4403)",
                      e.code == 4403, f"code={e.code}")

            try:
                with client.websocket_connect(f"/agent/ws/{agent_id}/{uid_v}", headers=cookie_header(token_v)) as ws:
                    check("owner connecting to own agent WS -> accepted", True)
                    ws.close()
            except Exception as e:
                check("owner connecting to own agent WS -> accepted", False, str(e))

            # ── Finding 4: Notification IDOR ─────────────────────────────────
            # Removed 2026-08-26: the notification CRUD/read routes this
            # section exercised (GET/PUT/PATCH/DELETE/trigger/next on
            # /notification/{user_id}/{notif_id}) no longer exist — the
            # entire agentic/custom notification subsystem was removed. See
            # this file's module docstring for why the coverage was dropped
            # here rather than ported, and where its successor coverage lands.

            # ── Finding 5: Devotion session authorization ───────────────────
            print("\n=== Devotions ===")
            devo_id = str(uuid.uuid4())
            devo_payload = {
                "devotion_id": devo_id, "user_id": uid_v,
                "devotion": {"id": devo_id, "title": "Private study", "creator_id": uid_v,
                             "prompts": ["p1"], "verses": []},
            }
            r = client.post("/devotions/", json=devo_payload, headers=cookie_header(token_v))
            check("victim creates own private devotion session -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)

            r = client.get("/devotions/", params={"devotion_id": devo_id}, headers=cookie_header(token_v))
            check("victim (creator) can fetch own session -> 200", r.status_code == 200, str(r.status_code))

            r = client.get("/devotions/", params={"devotion_id": devo_id}, headers=cookie_header(token_x))
            check("attacker (not creator/participant/group member) fetch -> 403", r.status_code == 403, str(r.status_code))

            r = client.post("/devotions/join", params={"user_id": uid_x, "session_id": devo_id}, headers=cookie_header(token_x))
            check("attacker join -> 403", r.status_code == 403, str(r.status_code))

            r = client.post("/devotions/leave", params={"user_id": uid_x, "session_id": devo_id}, headers=cookie_header(token_x))
            check("attacker leave (never joined) -> 403", r.status_code == 403, str(r.status_code))

            r = client.post("/devotions/join-call", params={"session_id": devo_id, "user_id": uid_x}, headers=cookie_header(token_x))
            check("attacker join-call -> 403", r.status_code == 403, str(r.status_code))

            # Finding 5b: update_devotion — attacker (never a participant/group
            # member) tries to overwrite the victim's private session content
            # by devotion_id. Prior to the fix this only checked
            # req.user_id == current_user (self-identity), not that the
            # caller has any relationship to the EXISTING session, so an
            # attacker could rename/rewrite another user's private devotion.
            attacker_update_payload = {
                "devotion_id": devo_id, "user_id": uid_x,
                "devotion": {"id": devo_id, "title": "PWNED", "creator_id": uid_v,
                             "prompts": ["pwned prompt"], "verses": []},
            }
            r = client.put("/devotions/", json=attacker_update_payload, headers=cookie_header(token_x))
            check("attacker: update_devotion on victim's session -> 403",
                  r.status_code == 403, str(r.status_code) + " " + r.text)

            r = client.get("/devotions/", params={"devotion_id": devo_id}, headers=cookie_header(token_v))
            check("victim's session title/prompts untouched after attacker's update_devotion attempt",
                  r.status_code == 200 and r.json().get("title") == "Private study"
                  and r.json().get("prompts") == ["p1"], str(r.status_code) + " " + str(r.json()))

            # Regression: the legitimate owner can still update their own session.
            owner_update_payload = {
                "devotion_id": devo_id, "user_id": uid_v,
                "devotion": {"id": devo_id, "title": "Private study (edited)", "creator_id": uid_v,
                             "prompts": ["p1", "p2"], "verses": []},
            }
            r = client.put("/devotions/", json=owner_update_payload, headers=cookie_header(token_v))
            check("owner: update_devotion on own session -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)

            r = client.get("/devotions/", params={"devotion_id": devo_id}, headers=cookie_header(token_v))
            check("owner's edit actually persisted",
                  r.status_code == 200 and r.json().get("title") == "Private study (edited)"
                  and r.json().get("prompts") == ["p1", "p2"], str(r.status_code) + " " + str(r.json()))

            # Also confirm a non-existent devotion_id 404s for update (not a
            # bare 403/500), matching fetch_devotion's own not-found handling.
            r = client.put("/devotions/", json={
                "devotion_id": str(uuid.uuid4()), "user_id": uid_v,
                "devotion": {"id": str(uuid.uuid4()), "title": "ghost", "creator_id": uid_v, "prompts": [], "verses": []},
            }, headers=cookie_header(token_v))
            check("update_devotion on a nonexistent session -> 404", r.status_code == 404, str(r.status_code))

            # Cleanup the devotion (host-only delete, already covered elsewhere).
            del_payload = {"devotion_id": devo_id, "user_id": uid_v, "devotion": devo_payload["devotion"]}
            client.request("DELETE", "/devotions/", json=del_payload, headers=cookie_header(token_v))

        finally:
            print("\n=== cleanup ===")
            cleanup(uid_v, uid_x)

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
