"""Tests for task 20260902-group-tagged-devotions, backend step 1
(api/db.py, api/schemas/agent.py, api/backend/interactions/agent.py,
api/routes/agent.py) and its security-gate follow-up fix (ON DELETE SET NULL
on the new FK).

Correcting the original ambiguous request: the target entity is
`agent_heartbeats` (the scheduled-agent-event row), NOT `notes` or
`devotions` -- both of those were ruled out during intake. This suite
exercises the real bug-shaped gap the spec called out: heartbeat-generated
notes previously could never carry a group_id (note_via_hb only ever read
`data.get("group_id")` off the LLM's own response, which the model has no
reason to ever populate), even when the firing heartbeat itself was tied to
a group.

Covers, against a REAL Postgres DB and the REAL routes (never a mocked
manager for the route-level checks, matching every other heartbeat test in
this directory):

  1. Migration idempotency: `db.create_tables` can run twice without error,
     and `agent_heartbeats.group_id` exists as a nullable FK to `groups`.
  2. `POST /agent/{user_id}/{agent_id}/heartbeat` (add_heartbeat) persists a
     `group_id` the caller actually belongs to, and it round-trips through
     `GET /agent/{user_id}/{agent_id}/heartbeats` (get_heartbeats).
  3. `add_heartbeat` REJECTS (403) a `group_id` the caller is not a member
     of, via the new `_require_group_membership` IDOR guard -- and no
     heartbeat row is persisted for the rejected attempt (so a follow-up
     legitimate add still succeeds against the same free-tier `agent_events`
     cap of 1).
  4. `PUT /agent/{user_id}/{heartbeat_id}/update_heartbeats` (update_heartbeat)
     round-trips a valid `group_id` change onto an existing heartbeat.
  5. `update_heartbeat` REJECTS (403) changing `group_id` to a group the
     caller isn't a member of, and leaves the heartbeat's existing group_id
     untouched in the DB.
  6. Leaving `group_id` empty/omitted on add/update still works exactly as
     before (personal/ungrouped heartbeat) -- no regression to the
     pre-existing behavior.
  7. THE CORE FIX: a heartbeat with a `group_id` set, when fired, produces a
     note with that SAME `group_id` -- sourced from the heartbeat row itself,
     not from the LLM's response (proven by injecting a bogus `group_id` into
     the fake LLM response and confirming it's ignored) -- and that note is
     visible to another group member via the existing
     `GET /groups/{user_id}/{group_id}/notes` read path.
  8. Regression: an ungrouped heartbeat still fires and produces a personal
     (group_id-less) note exactly as before this feature existed.
  9. Fire-time defense-in-depth: if the user has left the group between
     setting `group_id` on the heartbeat and it firing, the fire still
     succeeds but generates an UNGROUPED note (fails closed, doesn't error
     the fire and doesn't write into a group membership no longer covers).
  10. No regression to the once-per-day claim: a grouped heartbeat still
      claims/skips a same-day repeat fire exactly like an ungrouped one.

Run:  cd api && ../.venv/bin/python tests/test_heartbeat_group_id.py
"""
import os
import uuid

import _pathfix  # noqa: F401

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

from db import DBManager, create_tables  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402
import main as main_module  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


class FakeManager(AgentManager):
    """Stubs the LLM call so commit_hb_response is exercised deterministically,
    without ever hitting the real OpenRouter API. `_RESPONSE` can be swapped
    per-test to inject e.g. a bogus group_id, proving it's ignored."""

    _RESPONSE = (
        '{"__action": "create_note", "title": "Reflection", '
        '"text": "Generated content.", "verses": []}'
    )

    def _call_api(self, agent_role, messages):
        return self._RESPONSE


def cookie_header(token: str):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, username):
    """Spoofs a distinct CF-Connecting-IP per call so this file's ~16
    signups (over the 5/minute per-IP /signup rate limit) don't trip it --
    same technique as test_friend_activity.py/test_security_hardening.py."""
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.113.{_signup_counter % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def create_group(client, token, owner_id, member_ids):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner_id}", json={
        "group_id": gid, "title": "HB Group Test", "users": [owner_id] + member_ids,
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def make_agent(user_id: str) -> str:
    agent_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agents (_id, user_id, role, chats) VALUES (%s, %s, %s, %s)",
            (agent_id, user_id, "", []),
        )
        db.conn.commit()
    finally:
        db.close()
    return agent_id


def make_heartbeat(agent_id: str, user_id: str, group_id: str | None = None) -> str:
    """Seeds a heartbeat directly, bypassing the route's free-tier
    agent_events cap (limit=1) -- matches the pre-existing
    test_commit_heartbeat_force_fire.py::make_heartbeat pattern, extended
    with an optional group_id column."""
    hb_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt, group_id) "
            "VALUES (%s, %s, %s, %s::jsonb, %s, %s)",
            (hb_id, agent_id, user_id, "[]", "Write a reflection.", group_id),
        )
        db.conn.commit()
    finally:
        db.close()
    return hb_id


def get_heartbeat_row(hb_id: str) -> dict | None:
    db = DBManager()
    try:
        db.cur.execute("SELECT * FROM agent_heartbeats WHERE _id = %s", (hb_id,))
        row = db.cur.fetchone()
        if not row:
            return None
        cols = [d[0] for d in db.cur.description]
        return dict(zip(cols, row))
    finally:
        db.close()


def heartbeat_count(user_id: str) -> int:
    db = DBManager()
    try:
        db.cur.execute("SELECT COUNT(*) FROM agent_heartbeats WHERE user_id = %s", (user_id,))
        return db.cur.fetchone()[0]
    finally:
        db.close()


def latest_note_for_user(user_id: str) -> dict | None:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT _id, group_id, title FROM notes WHERE user_id = %s ORDER BY timestamp DESC LIMIT 1",
            (user_id,),
        )
        row = db.cur.fetchone()
        if not row:
            return None
        return {"_id": str(row[0]), "group_id": str(row[1]) if row[1] else None, "title": row[2]}
    finally:
        db.close()


def remove_member(group_id: str, user_id: str) -> None:
    db = DBManager()
    try:
        db.cur.execute("SELECT users FROM groups WHERE _id = %s", (group_id,))
        users = db.cur.fetchone()[0] or []
        users = [u for u in users if u != user_id]
        db.cur.execute("UPDATE groups SET users = %s WHERE _id = %s", (users, group_id))
        db.conn.commit()
    finally:
        db.close()


def cleanup(*user_ids, group_ids=()):
    db = DBManager()
    try:
        for gid in group_ids:
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            # notes.user_id has no ON DELETE CASCADE, so drop notes first
            # (matches test_commit_heartbeat_force_fire.py's cleanup()).
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def test_migration_is_idempotent():
    print("\n=== 1. Migration idempotency: create_tables can run twice; "
          "agent_heartbeats.group_id exists as a nullable FK to groups ===")
    db = DBManager()
    try:
        try:
            create_tables(db.cur)
            db.conn.commit()
            create_tables(db.cur)
            db.conn.commit()
            ran_twice_ok = True
        except Exception as e:
            db.conn.rollback()
            ran_twice_ok = False
            print(f"    exception: {e}")
        check("create_tables (which includes the agent_heartbeats.group_id "
              "migration) runs twice without error", ran_twice_ok)

        db.cur.execute(
            "SELECT is_nullable, udt_name FROM information_schema.columns "
            "WHERE table_name = 'agent_heartbeats' AND column_name = 'group_id'"
        )
        row = db.cur.fetchone()
        check("agent_heartbeats.group_id column exists", row is not None, str(row))
        if row:
            check("agent_heartbeats.group_id is nullable", row[0] == "YES", str(row))
            check("agent_heartbeats.group_id is a uuid column", row[1] == "uuid", str(row))

        db.cur.execute(
            "SELECT confdeltype FROM pg_constraint "
            "WHERE conrelid = 'agent_heartbeats'::regclass "
            "AND confrelid = 'groups'::regclass"
        )
        fk_row = db.cur.fetchone()
        check("agent_heartbeats has an FK to groups with ON DELETE SET NULL",
              fk_row is not None and fk_row[0] == "n", str(fk_row))
    finally:
        db.close()


def test_add_heartbeat_round_trips_group_id(client):
    print("\n=== 2. add_heartbeat persists a group_id the caller belongs to, "
          "and it round-trips through get_heartbeats ===")
    uid_a, token_a = signup(client, f"hbgrp_a_{uuid.uuid4().hex[:8]}")
    uid_b, token_b = signup(client, f"hbgrp_b_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, token_a, uid_a, [uid_b])
        agent_id = make_agent(uid_a)

        r = client.post(
            f"/agent/{uid_a}/{agent_id}/heartbeat",
            json={"timestamps": [None] * 31, "prompt": "Reflect.", "group_id": gid},
            headers=cookie_header(token_a),
        )
        check("add_heartbeat with a group the caller belongs to succeeds (201)",
              r.status_code == 201, f"{r.status_code} {r.text}")

        r = client.get(f"/agent/{uid_a}/{agent_id}/heartbeats", headers=cookie_header(token_a))
        check("get_heartbeats succeeds", r.status_code == 200, str(r.status_code))
        hbs = r.json()
        check("exactly one heartbeat exists", len(hbs) == 1, str(hbs))
        check("get_heartbeats surfaces the persisted group_id unchanged",
              hbs and hbs[0].get("group_id") == gid, str(hbs))
    finally:
        cleanup(uid_a, uid_b, group_ids=[gid] if gid else [])


def test_add_heartbeat_rejects_non_member_group(client):
    print("\n=== 3. add_heartbeat REJECTS a group_id the caller isn't a member "
          "of (403), persists nothing, and a follow-up legitimate add still "
          "succeeds against the free-tier cap of 1 ===")
    uid_owner, token_owner = signup(client, f"hbgrp_owner_{uuid.uuid4().hex[:8]}")
    uid_outsider, token_outsider = signup(client, f"hbgrp_outsider_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, token_owner, uid_owner, [])
        agent_id = make_agent(uid_outsider)

        r = client.post(
            f"/agent/{uid_outsider}/{agent_id}/heartbeat",
            json={"timestamps": [None] * 31, "prompt": "Reflect.", "group_id": gid},
            headers=cookie_header(token_outsider),
        )
        check("add_heartbeat with a group_id the caller does NOT belong to is rejected (403)",
              r.status_code == 403, f"{r.status_code} {r.text}")
        check("no heartbeat row was persisted for the rejected attempt",
              heartbeat_count(uid_outsider) == 0, str(heartbeat_count(uid_outsider)))

        # The rejected attempt must not have burned the free-tier
        # agent_events quota (limit=1) -- a legitimate, ungrouped add
        # right after must still succeed.
        r2 = client.post(
            f"/agent/{uid_outsider}/{agent_id}/heartbeat",
            json={"timestamps": [None] * 31, "prompt": "Reflect.", "group_id": ""},
            headers=cookie_header(token_outsider),
        )
        check("a follow-up legitimate (ungrouped) add still succeeds after the rejection",
              r2.status_code == 201, f"{r2.status_code} {r2.text}")
    finally:
        cleanup(uid_owner, uid_outsider, group_ids=[gid] if gid else [])


def test_update_heartbeat_round_trips_group_id(client):
    print("\n=== 4. update_heartbeat round-trips a valid group_id change onto "
          "an existing heartbeat ===")
    uid_a, token_a = signup(client, f"hbgrp_upd_a_{uuid.uuid4().hex[:8]}")
    uid_b, token_b = signup(client, f"hbgrp_upd_b_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, token_a, uid_a, [uid_b])
        agent_id = make_agent(uid_a)
        hb_id = make_heartbeat(agent_id, uid_a)  # starts ungrouped

        r = client.put(
            f"/agent/{uid_a}/{hb_id}/update_heartbeats",
            json={"agent_id": agent_id, "timestamps": [None] * 31, "prompt": "Reflect.", "group_id": gid},
            headers=cookie_header(token_a),
        )
        check("update_heartbeat to a group the caller belongs to succeeds",
              r.status_code == 200, f"{r.status_code} {r.text}")

        row = get_heartbeat_row(hb_id)
        check("group_id is persisted on the row after update",
              row is not None and str(row.get("group_id")) == gid, str(row))

        r = client.get(f"/agent/{uid_a}/{agent_id}/heartbeats", headers=cookie_header(token_a))
        hbs = r.json()
        check("get_heartbeats reflects the updated group_id",
              hbs and hbs[0].get("group_id") == gid, str(hbs))
    finally:
        cleanup(uid_a, uid_b, group_ids=[gid] if gid else [])


def test_update_heartbeat_rejects_non_member_group(client):
    print("\n=== 5. update_heartbeat REJECTS changing group_id to a group the "
          "caller isn't a member of, leaving the existing value untouched ===")
    uid_owner, token_owner = signup(client, f"hbgrp_updowner_{uuid.uuid4().hex[:8]}")
    uid_caller, token_caller = signup(client, f"hbgrp_updcaller_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, token_owner, uid_owner, [])
        agent_id = make_agent(uid_caller)
        hb_id = make_heartbeat(agent_id, uid_caller)  # starts ungrouped

        r = client.put(
            f"/agent/{uid_caller}/{hb_id}/update_heartbeats",
            json={"agent_id": agent_id, "timestamps": [None] * 31, "prompt": "Reflect.", "group_id": gid},
            headers=cookie_header(token_caller),
        )
        check("update_heartbeat to a non-member group is rejected (403)",
              r.status_code == 403, f"{r.status_code} {r.text}")

        row = get_heartbeat_row(hb_id)
        check("the heartbeat's group_id remains untouched (still ungrouped) after the rejection",
              row is not None and row.get("group_id") is None, str(row))
    finally:
        cleanup(uid_owner, uid_caller, group_ids=[gid] if gid else [])


def test_ungrouped_add_and_update_still_work(client):
    print("\n=== 6. Leaving group_id empty/omitted on add/update still works "
          "exactly as before (no regression to personal events) ===")
    uid, token = signup(client, f"hbgrp_ungrp_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        r = client.post(
            f"/agent/{uid}/{agent_id}/heartbeat",
            json={"timestamps": [None] * 31, "prompt": "Reflect."},  # group_id omitted entirely
            headers=cookie_header(token),
        )
        check("add_heartbeat with group_id omitted entirely still succeeds",
              r.status_code == 201, f"{r.status_code} {r.text}")

        r = client.get(f"/agent/{uid}/{agent_id}/heartbeats", headers=cookie_header(token))
        hbs = r.json()
        check("the created heartbeat has no group_id", hbs and not hbs[0].get("group_id"), str(hbs))

        hb_id = hbs[0]["_id"]
        r = client.put(
            f"/agent/{uid}/{hb_id}/update_heartbeats",
            json={"agent_id": agent_id, "timestamps": [None] * 31, "prompt": "Reflect more.", "group_id": ""},
            headers=cookie_header(token),
        )
        check("update_heartbeat with group_id='' still succeeds", r.status_code == 200, str(r.status_code))
        row = get_heartbeat_row(hb_id)
        check("group_id remains None after an empty-string update", row and row.get("group_id") is None, str(row))
    finally:
        cleanup(uid)


def test_fired_grouped_heartbeat_note_propagates_to_group(client):
    print("\n=== 7. CORE FIX: a fired grouped heartbeat produces a note with "
          "the HEARTBEAT's own group_id (not the LLM's), visible to another "
          "group member via GET /groups/{user_id}/{group_id}/notes ===")
    uid_owner, token_owner = signup(client, f"hbgrp_fire_owner_{uuid.uuid4().hex[:8]}")
    uid_member, token_member = signup(client, f"hbgrp_fire_member_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, token_owner, uid_owner, [uid_member])
        agent_id = make_agent(uid_owner)
        hb_id = make_heartbeat(agent_id, uid_owner, group_id=gid)

        # Inject a bogus group_id into the fake LLM response to prove the
        # fix: commit_hb_response must use the HEARTBEAT's own group_id,
        # never trust response_dict.get("group_id").
        bogus_gid = str(uuid.uuid4())
        FakeManager._RESPONSE = (
            '{"__action": "create_note", "title": "Grouped Reflection", '
            f'"text": "Body.", "verses": [], "group_id": "{bogus_gid}"}}'
        )
        manager = FakeManager(uid_owner)
        try:
            result = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        finally:
            manager.close()
        check("firing the grouped heartbeat succeeds", result == {"success": "saved note"}, str(result))

        note = latest_note_for_user(uid_owner)
        check("a note was created", note is not None, str(note))
        check("the note's group_id is the HEARTBEAT's own group_id, not the LLM's bogus one",
              note is not None and note["group_id"] == gid, str(note))

        r = client.get(
            f"/groups/{uid_member}/{gid}/notes", headers=cookie_header(token_member),
        )
        check("the other group member can list group notes", r.status_code == 200, str(r.status_code))
        body = r.json()
        all_notes = [n for by_user in body.get("notes", {}).values() for n in by_user.values()]
        check("the heartbeat-generated note is visible to the other group member",
              any(n.get("title") == "Grouped Reflection" for n in all_notes), str(body))
    finally:
        FakeManager._RESPONSE = (
            '{"__action": "create_note", "title": "Reflection", '
            '"text": "Generated content.", "verses": []}'
        )
        cleanup(uid_owner, uid_member, group_ids=[gid] if gid else [])


def test_fired_ungrouped_heartbeat_produces_personal_note():
    print("\n=== 8. Regression: an ungrouped heartbeat still fires and "
          "produces a personal (group_id-less) note exactly as before ===")
    db = DBManager()
    try:
        uid = str(uuid.uuid4())
        db.insertion("users", {"_id": uid, "username": f"hbgrp_solo_{uid[:8]}",
                                "email": f"hbgrp_solo_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
    try:
        agent_id = make_agent(uid)
        hb_id = make_heartbeat(agent_id, uid)  # group_id=None
        manager = FakeManager(uid)
        try:
            result = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        finally:
            manager.close()
        check("firing the ungrouped heartbeat succeeds", result == {"success": "saved note"}, str(result))
        note = latest_note_for_user(uid)
        check("the resulting note has no group_id (stays personal)",
              note is not None and note["group_id"] is None, str(note))
    finally:
        cleanup(uid)


def test_fire_time_membership_recheck_ungroups_note(client):
    print("\n=== 9. Fire-time defense-in-depth: user left the group after "
          "setting group_id on the heartbeat -> fire still succeeds but "
          "generates an UNGROUPED note (fails closed) ===")
    uid_owner, token_owner = signup(client, f"hbgrp_left_owner_{uuid.uuid4().hex[:8]}")
    uid_other, token_other = signup(client, f"hbgrp_left_other_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, token_owner, uid_owner, [uid_other])
        agent_id = make_agent(uid_owner)
        hb_id = make_heartbeat(agent_id, uid_owner, group_id=gid)

        # Simulate the owner leaving the group after the heartbeat's
        # group_id was already set.
        remove_member(gid, uid_owner)

        manager = FakeManager(uid_owner)
        try:
            result = manager.commit_hb_response(agent_id, hb_id, "Reflect on today.")
        finally:
            manager.close()
        check("firing still succeeds even though membership no longer holds",
              result == {"success": "saved note"}, str(result))
        note = latest_note_for_user(uid_owner)
        check("the note is generated UNGROUPED, not written into a group the user left",
              note is not None and note["group_id"] is None, str(note))
    finally:
        cleanup(uid_owner, uid_other, group_ids=[gid] if gid else [])


def test_grouped_heartbeat_still_respects_once_per_day_claim(client):
    print("\n=== 10. No regression: a grouped heartbeat still claims/skips a "
          "same-day repeat fire exactly like an ungrouped one ===")
    uid_owner, token_owner = signup(client, f"hbgrp_daily_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, token_owner, uid_owner, [])
        agent_id = make_agent(uid_owner)
        hb_id = make_heartbeat(agent_id, uid_owner, group_id=gid)

        manager = FakeManager(uid_owner)
        try:
            result1 = manager.commit_hb_response(agent_id, hb_id, "Reflect.")
            check("first (unforced) fire of a grouped heartbeat succeeds",
                  result1 == {"success": "saved note"}, str(result1))
            result2 = manager.commit_hb_response(agent_id, hb_id, "Reflect.")
            check("a same-day repeat fire of a grouped heartbeat is still skipped, "
                  "unchanged from ungrouped behavior",
                  result2 == {"skipped": "already fired today"}, str(result2))
        finally:
            manager.close()
    finally:
        cleanup(uid_owner, group_ids=[gid] if gid else [])


def main():
    test_migration_is_idempotent()
    test_fired_ungrouped_heartbeat_produces_personal_note()

    # Single shared TestClient/app lifespan for every route-level test --
    # the scheduler is a module-level singleton, so a second independent
    # TestClient(main_module.app) lifespan in the same process fails trying
    # to re-register jobs against a closed event loop (same rationale as
    # test_friend_activity.py/test_activity_notifications.py).
    with TestClient(main_module.app) as client:
        test_add_heartbeat_round_trips_group_id(client)
        test_add_heartbeat_rejects_non_member_group(client)
        test_update_heartbeat_round_trips_group_id(client)
        test_update_heartbeat_rejects_non_member_group(client)
        test_ungrouped_add_and_update_still_work(client)
        test_fired_grouped_heartbeat_note_propagates_to_group(client)
        test_fire_time_membership_recheck_ungroups_note(client)
        test_grouped_heartbeat_still_respects_once_per_day_claim(client)

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
