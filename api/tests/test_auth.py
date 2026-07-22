"""Pre-deployment smoke test for the session/cookie auth fix.

Boots the REAL app (main.app, including its lifespan) rather than a per-router
stub, so cross-router route-ordering and startup issues would surface here.
Covers the security boundary (unauthorized/cross-user access is rejected) and
the happy path (legitimate access still works) for every router touched by
the auth change, including the two paths not covered by the earlier ad hoc
curl testing: WebSocket auth and the subscription host/member logic.

Run with: cd api && ../.venv/bin/python test_auth.py
"""
import os
import sys
import uuid

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
    })
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    token = r.cookies.get("session")
    return r.json()["user_id"], token, username


def login(client, username):
    r = client.post("/login", json={"username": username, "plain_pass": "TestPass123!"})
    assert r.status_code == 200, f"login failed: {r.status_code} {r.text}"
    return r.cookies.get("session")


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def main():
    print("=== 1. Boot the real app (main.app), lifespan included ===")
    import main as main_module
    with TestClient(main_module.app) as client:
        check("app boots and lifespan starts", True)

        uid_a, token_a, uname_a = signup(client, f"auth_a_{uuid.uuid4().hex[:8]}")
        uid_b, token_b, uname_b = signup(client, f"auth_b_{uuid.uuid4().hex[:8]}")
        print(f"  created uid_a={uid_a} uid_b={uid_b}")

        try:
            # ── Core cookie/session behavior ──────────────────────────────
            print("\n=== 2. Core session behavior ===")
            r = client.post("/login", json={"username": "nope_no_such_user", "plain_pass": "x"})
            check("login unknown user -> 404", r.status_code == 404, str(r.status_code))

            r = client.get(f"/notes/{uid_a}", headers=cookie_header(token_a))
            check("notes: owner reads own -> 200", r.status_code == 200, str(r.status_code))

            r = client.get(f"/notes/{uid_b}", headers=cookie_header(token_a))
            check("notes: A reads B's with A's valid cookie -> 403", r.status_code == 403, str(r.status_code))

            r = client.get(f"/notes/{uid_a}")
            check("notes: no cookie -> 401", r.status_code == 401, str(r.status_code))

            r = client.get(f"/notes/{uid_a}", headers=cookie_header("garbage-token"))
            check("notes: forged garbage cookie -> 401", r.status_code == 401, str(r.status_code))

            r = client.get(f"/notes/{uid_b}", headers=cookie_header(uid_b))
            check("notes: cookie=raw uid (the ORIGINAL exploit) -> 401", r.status_code == 401, str(r.status_code))

            r = client.post("/logout", headers=cookie_header(token_a))
            check("logout -> 204", r.status_code == 204, str(r.status_code))
            r = client.get(f"/notes/{uid_a}", headers=cookie_header(token_a))
            check("notes: reused post-logout cookie -> 401", r.status_code == 401, str(r.status_code))
            # Re-login A since we just killed that session; every check below needs a live one.
            token_a = login(client, uname_a)

            # ── /user/{id} ─────────────────────────────────────────────────
            print("\n=== 3. /user/{id} ===")
            r = client.get(f"/user/{uid_b}", headers=cookie_header(token_a))
            check("user: any logged-in user can view another's profile -> 200", r.status_code == 200, str(r.status_code))
            r = client.get(f"/user/{uid_b}")
            check("user: view profile with no session -> 401", r.status_code == 401, str(r.status_code))
            r = client.put(f"/user/{uid_b}", json={"username": None, "email": None, "plain_pass": None}, headers=cookie_header(token_a))
            check("user: A edits B's profile -> 403", r.status_code == 403, str(r.status_code))
            r = client.delete(f"/user/{uid_b}", headers=cookie_header(token_a))
            check("user: A deletes B's account -> 403", r.status_code == 403, str(r.status_code))

            # ── Groups: identity + membership ───────────────────────────────
            print("\n=== 4. Groups ===")
            gid = str(uuid.uuid4())
            r = client.post(f"/groups/{uid_a}", json={"group_id": gid, "title": "A-only", "users": [uid_a]},
                             headers=cookie_header(token_a))
            check("groups: A creates group -> 201", r.status_code == 201, str(r.status_code))
            r = client.get(f"/groups/{uid_a}/{gid}", headers=cookie_header(token_a))
            check("groups: A fetches own group -> 200", r.status_code == 200, str(r.status_code))
            r = client.get(f"/groups/{uid_b}/{gid}", headers=cookie_header(token_b))
            check("groups: B (valid session, not a member) fetches A's group -> 403", r.status_code == 403, str(r.status_code))
            r = client.get(f"/groups/{uid_a}/{gid}", headers=cookie_header(token_b))
            check("groups: B tries to impersonate uid_a in path -> 403", r.status_code == 403, str(r.status_code))
            r = client.delete(f"/groups/{uid_a}/{gid}", headers=cookie_header(token_a))
            check("groups: A deletes own group -> 204", r.status_code == 204, str(r.status_code))

            # ── Agent: HTTP + WebSocket ──────────────────────────────────────
            print("\n=== 5. Agent (HTTP + WebSocket) ===")
            r = client.get(f"/agent/{uid_a}", headers=cookie_header(token_a))
            check("agent: A lists own agents -> 200", r.status_code == 200, str(r.status_code))
            r = client.get(f"/agent/{uid_b}", headers=cookie_header(token_a))
            check("agent: A lists B's agents -> 403", r.status_code == 403, str(r.status_code))

            agent_id = str(uuid.uuid4())
            try:
                with client.websocket_connect(f"/agent/ws/{agent_id}/{uid_a}", headers=cookie_header(token_a)) as ws:
                    check("agent ws: valid session for self -> connects", True)
                    ws.close()
            except Exception as e:
                check("agent ws: valid session for self -> connects", False, str(e))

            try:
                with client.websocket_connect(f"/agent/ws/{agent_id}/{uid_b}", headers=cookie_header(token_a)) as ws:
                    check("agent ws: A impersonating B -> rejected", False, "connection was accepted")
                    ws.close()
            except Exception as e:
                check("agent ws: A impersonating B -> rejected", True, f"{type(e).__name__}: {e}")

            try:
                with client.websocket_connect(f"/agent/ws/{agent_id}/{uid_a}") as ws:
                    check("agent ws: no cookie -> rejected", False, "connection was accepted")
                    ws.close()
            except Exception as e:
                check("agent ws: no cookie -> rejected", True, f"{type(e).__name__}: {e}")

            # ── Messaging: DM read + WebSocket ────────────────────────────
            print("\n=== 6. Messaging (HTTP + WebSocket) ===")
            r = client.get(f"/message/messages/{uid_a}/", params={"guest_user": uid_b}, headers=cookie_header(token_a))
            check("messaging: host reads own DM thread -> 200", r.status_code == 200, str(r.status_code))
            r = client.get(f"/message/messages/{uid_a}/", params={"guest_user": uid_b}, headers=cookie_header(token_b))
            check("messaging: B impersonating host_user=A -> 403", r.status_code == 403, str(r.status_code))

            try:
                with client.websocket_connect(f"/message/ws/{uid_a}", headers=cookie_header(token_a)) as ws:
                    check("message ws: valid session for self -> connects", True)
                    ws.close()
            except Exception as e:
                check("message ws: valid session for self -> connects", False, str(e))

            try:
                with client.websocket_connect(f"/message/ws/{uid_a}", headers=cookie_header(token_b)) as ws:
                    check("message ws: B impersonating A -> rejected", False, "connection was accepted")
                    ws.close()
            except Exception as e:
                check("message ws: B impersonating A -> rejected", True, f"{type(e).__name__}: {e}")

            # ── Devotion: identity nested in request body ───────────────────
            print("\n=== 7. Devotion (body-nested user_id) ===")
            devo_id = str(uuid.uuid4())
            devo_payload = {
                "devotion_id": devo_id, "user_id": uid_a,
                "devotion": {"id": devo_id, "title": "T", "creator_id": uid_a},
            }
            r = client.post("/devotions/", json=devo_payload, headers=cookie_header(token_a))
            check("devotion: A creates as self -> 201", r.status_code == 201, str(r.status_code))
            r = client.post("/devotions/", json=devo_payload, headers=cookie_header(token_b))
            check("devotion: B creates claiming user_id=A in body -> 403", r.status_code == 403, str(r.status_code))
            del_as_b = {"devotion_id": devo_id, "user_id": uid_b, "devotion": devo_payload["devotion"]}
            r = client.request("DELETE", "/devotions/", json=del_as_b, headers=cookie_header(token_b))
            check("devotion: B (authenticated as self, not the host) deletes A's session -> 403",
                  r.status_code == 403, str(r.status_code))
            del_as_a = {"devotion_id": devo_id, "user_id": uid_a, "devotion": devo_payload["devotion"]}
            r = client.request("DELETE", "/devotions/", json=del_as_a, headers=cookie_header(token_a))
            check("devotion: A (real creator/host) deletes own session -> 200", r.status_code == 200, str(r.status_code))

            # ── Notifications ────────────────────────────────────────────
            print("\n=== 8. Notifications ===")
            r = client.get(f"/notification/{uid_a}", headers=cookie_header(token_a))
            check("notifications: A lists own -> 200", r.status_code == 200, str(r.status_code))
            r = client.get(f"/notification/{uid_a}", headers=cookie_header(token_b))
            check("notifications: B lists A's -> 403", r.status_code == 403, str(r.status_code))

            # ── Subscription: host vs member logic ──────────────────────────
            print("\n=== 9. Subscription (host/member authorization) ===")
            r = client.get(f"/subscriptions/user/{uid_a}", headers=cookie_header(token_a))
            check("subscription: A reads own auto-created free plan -> 200", r.status_code == 200, str(r.status_code))
            r = client.get(f"/subscriptions/user/{uid_a}", headers=cookie_header(token_b))
            check("subscription: B reads A's plan via path -> 403", r.status_code == 403, str(r.status_code))

            r = client.post("/subscriptions/", json={"user_id": uid_a, "plan_type": "group"}, headers=cookie_header(token_a))
            check("subscription: A creates a group plan (becomes host) -> 201", r.status_code == 201, str(r.status_code))
            sub_id = r.json()["id"]

            r = client.put(f"/subscriptions/{sub_id}", json={"status": "active"}, headers=cookie_header(token_b))
            check("subscription: non-host B updates A's plan -> 403", r.status_code == 403, str(r.status_code))
            r = client.put(f"/subscriptions/{sub_id}", json={"status": "active"}, headers=cookie_header(token_a))
            check("subscription: host A updates own plan -> 200", r.status_code == 200, str(r.status_code))

            r = client.post(f"/subscriptions/{sub_id}/requests", params={"from_user_id": uid_a},
                             headers=cookie_header(token_b))
            check("subscription: B requests to join claiming from_user_id=A -> 403", r.status_code == 403, str(r.status_code))
            r = client.post(f"/subscriptions/{sub_id}/requests", params={"from_user_id": uid_b},
                             headers=cookie_header(token_b))
            check("subscription: B requests to join as self -> 201", r.status_code == 201, str(r.status_code))

            r = client.post(f"/subscriptions/{sub_id}/requests/{uid_b}/accept", headers=cookie_header(token_b))
            check("subscription: non-host B accepts own request -> 403", r.status_code == 403, str(r.status_code))
            r = client.post(f"/subscriptions/{sub_id}/requests/{uid_b}/accept", headers=cookie_header(token_a))
            check("subscription: host A accepts B's request -> 200", r.status_code == 200, str(r.status_code))

            r = client.delete(f"/subscriptions/{sub_id}/members/{uid_b}", headers=cookie_header(token_b))
            check("subscription: member B removes self -> 204", r.status_code == 204, str(r.status_code))

            r = client.delete(f"/subscriptions/{sub_id}", headers=cookie_header(token_b))
            check("subscription: non-host B deletes A's plan -> 403", r.status_code == 403, str(r.status_code))
            r = client.delete(f"/subscriptions/{sub_id}", headers=cookie_header(token_a))
            check("subscription: host A deletes own plan -> 204", r.status_code == 204, str(r.status_code))

            # ── Filtering (baseline auth only) ───────────────────────────────
            print("\n=== 10. Filtering (baseline login required) ===")
            r = client.post("/filter/", json={"notes": {}, "to_filter": {"users": None, "date": None, "book": None, "title": None}})
            check("filter: no session -> 401", r.status_code == 401, str(r.status_code))
            r = client.post("/filter/", json={"notes": {}, "to_filter": {"users": None, "date": None, "book": None, "title": None}},
                             headers=cookie_header(token_a))
            check("filter: valid session -> 200", r.status_code == 200, str(r.status_code))

        finally:
            print("\n=== cleanup ===")
            cleanup(uid_a, uid_b)

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
