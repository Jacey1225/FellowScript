"""Regression coverage for task 20260907-session-summary-wireup, backend
step 1: the `summarize` field added to `DevotionPlan`
(api/schemas/devotion.py), the idempotent `devotions.summarize` column
(api/db.py), and the DevotionManager.save_devotion/_to_plan plumbing
(api/backend/interactions/devotion.py) that carries it through.

Before this fix, the client-side "Summarize" toggle set `summarize: bool` on
`FSSession`, but `DevotionPlan` had no matching field -- Pydantic silently
dropped it on POST /devotions/, so a session created with Summarize ON was
indistinguishable from one created with it OFF by the time it reached
`CallController` at call-end. This test proves the flag now survives the
full round trip through the real HTTP routes (not just a schema-level
`DevotionPlan(...)` construction, which would miss a broken INSERT/column or
a `_to_plan` that forgot to read it back):

  POST /devotions/ (summarize=True)  -> DB column
  POST /devotions/ (summarize omitted, i.e. default False) -> DB column
  GET /devotions/contact/{contact_id} -> both come back with the right flag,
    not flipped, not dropped, not defaulted-true.

Also covers the direct GET /devotions/?devotion_id=... single-session read
path (`read_devotion` -> `_to_plan`), since `get_contact_devotions` and
`fetch_devotion` exercise two different DevotionManager read methods
(`fetch_by_contact` vs `read_devotion`) that both call `_to_plan`.

Run with: cd api && ../.venv/bin/python tests/test_devotion_summarize_roundtrip.py
"""
import _pathfix  # noqa: F401,E402

import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
# Real S3/GIF config may not be present in every dev environment; a
# placeholder is sufficient since this file never exercises either
# subsystem -- it only needs `main.app`'s lifespan config validation to pass
# so the real HTTP routes can boot. See test_messaging_attachments.py's
# `_ensure_attachment_config_present` for the same precedent. This MUST run
# before importing `_fake_timeline` (which pulls in AgentManager ->
# GroupsManager -> backend.interactions.attachments, whose S3_BUCKET_NAME/
# S3_REGION are read into module-level constants at import time) or the
# placeholders below arrive too late for validate_attachment_config() to see.
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

import _fake_timeline  # noqa: F401,E402

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
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
    fake_ip = f"203.0.113.{uuid.uuid4().int % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM devotions WHERE creator_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def create_devotion(client, token, uid, group_id, *, summarize=None, title="Summarize round-trip test"):
    devo_id = str(uuid.uuid4())
    devotion = {
        "id": devo_id, "title": title, "creator_id": uid,
        "participants": [uid], "prompts": ["p1"], "verses": ["Gen 1:1"],
        "group_id": group_id,
    }
    if summarize is not None:
        devotion["summarize"] = summarize
    payload = {"devotion_id": devo_id, "user_id": uid, "devotion": devotion}
    r = client.post("/devotions/", json=payload, headers=cookie_header(token))
    assert r.status_code == 201, f"create_devotion failed: {r.status_code} {r.text}"
    return devo_id


def test_summarize_true_round_trips_via_contact_list(client):
    print("\n== summarize: true survives POST /devotions/ -> GET /devotions/contact/{contact_id} ==")
    uid, tok = signup(client, f"summ_true_{uuid.uuid4().hex[:8]}")
    group_id = f"dm_{uuid.uuid4().hex[:8]}"
    try:
        devo_id = create_devotion(client, tok, uid, group_id, summarize=True)

        r = client.get(f"/devotions/contact/{group_id}", headers=cookie_header(tok))
        check("GET contact devotions -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)
        sessions = r.json().get("sessions", [])
        match = next((s for s in sessions if s.get("id") == devo_id), None)
        check("created session appears in contact list", match is not None, str(sessions))
        if match is not None:
            check("summarize round-trips as True (not dropped, not flipped)",
                  match.get("summarize") is True, str(match))
    finally:
        cleanup(uid)


def test_summarize_default_false_round_trips(client):
    print("\n== summarize omitted on create -> defaults to False and round-trips as False ==")
    uid, tok = signup(client, f"summ_false_{uuid.uuid4().hex[:8]}")
    group_id = f"dm_{uuid.uuid4().hex[:8]}"
    try:
        # Deliberately omit `summarize` entirely, matching a client that
        # never sends the key (pre-fix DevotionPlan shape / default toggle
        # state) -- Pydantic's `summarize: bool = False` default must apply,
        # not silently error or come back None/True.
        devo_id = create_devotion(client, tok, uid, group_id, summarize=None)

        r = client.get(f"/devotions/contact/{group_id}", headers=cookie_header(tok))
        check("GET contact devotions -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)
        sessions = r.json().get("sessions", [])
        match = next((s for s in sessions if s.get("id") == devo_id), None)
        check("created session appears in contact list", match is not None, str(sessions))
        if match is not None:
            check("summarize defaults to False when omitted by the client",
                  match.get("summarize") is False, str(match))
    finally:
        cleanup(uid)


def test_summarize_explicit_false_round_trips(client):
    print("\n== summarize: false round-trips as False (not coerced True) ==")
    uid, tok = signup(client, f"summ_expfalse_{uuid.uuid4().hex[:8]}")
    group_id = f"dm_{uuid.uuid4().hex[:8]}"
    try:
        devo_id = create_devotion(client, tok, uid, group_id, summarize=False)

        r = client.get(f"/devotions/contact/{group_id}", headers=cookie_header(tok))
        sessions = r.json().get("sessions", [])
        match = next((s for s in sessions if s.get("id") == devo_id), None)
        check("created session appears in contact list", match is not None, str(sessions))
        if match is not None:
            check("explicit summarize=False round-trips as False",
                  match.get("summarize") is False, str(match))
    finally:
        cleanup(uid)


def test_summarize_true_round_trips_via_single_session_read(client):
    print("\n== summarize: true survives the single-session GET /devotions/?devotion_id=... path (read_devotion/_to_plan) ==")
    uid, tok = signup(client, f"summ_single_{uuid.uuid4().hex[:8]}")
    group_id = f"dm_{uuid.uuid4().hex[:8]}"
    try:
        devo_id = create_devotion(client, tok, uid, group_id, summarize=True)

        r = client.get("/devotions/", params={"devotion_id": devo_id}, headers=cookie_header(tok))
        check("GET single devotion -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)
        body = r.json()
        check("summarize round-trips as True via read_devotion/_to_plan",
              body.get("summarize") is True, str(body))
    finally:
        cleanup(uid)


def main():
    with TestClient(main_module.app) as client:
        test_summarize_true_round_trips_via_contact_list(client)
        test_summarize_default_false_round_trips(client)
        test_summarize_explicit_false_round_trips(client)
        test_summarize_true_round_trips_via_single_session_read(client)

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        import sys
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
