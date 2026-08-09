"""Integration test for task 20260808-ios-backend-integration-audit,
step 5 (backend) notes+highlights domain finding.

POST /notes/{user_id} used to return {"id": note_id, "data": note.model_dump()}.
iOS's NetworkService.saveNote() decodes that response as [String: String] (a
flat dict of strings) via `try?`; the nested "data" object made that decode
throw, so decode() swallowed the error and saveNote() silently fell back to
`editingId ?? note.id` — for a fresh create (editingId == nil) that means the
CLIENT's locally-generated FSNote.id was used instead of the server-issued
note_id. The caller then cached the new note under that WRONG key, so a
subsequent edit/delete sent a note_id the server had never stored, producing
a 404 "Note not found" that the caller silently swallows with `try?` — a real,
reachable "unresponsive interaction" (todos's incident #1 error-swallowing
class stacked on incident #2's shape-mismatch class).

Fix: create_note now returns {"id": note_id} only.

This proves, end to end against the REAL app and a REAL Postgres connection
(no mocked DB, per this project's testing standard, see test_user_timezone.py):

  1. The POST /notes/{user_id} response body is EXACTLY {"id": <uuid>} —
     no "data" key, no other top-level keys — so iOS's [String: String]
     decode can never fail on it again.
  2. The id in that response is the note's REAL server-side id: a note
     fetched back via GET /notes/{user_id} is keyed under that exact id.
  3. Using that server-issued id, a subsequent PUT (edit) and DELETE both
     succeed (200) — the exact operations that 404'd under the old bug when
     the client used its own locally-generated id instead.
  4. Regression guard proving the OLD bug pattern is real: an id the client
     might have made up (never returned by the server) gets a 404 on PUT/
     DELETE, not a silent success — confirms the server correctly rejects an
     unknown note_id rather than papering over the mismatch.

Run:  cd api && ../.venv/bin/python tests/test_notes_create_response_shape.py
"""
import _pathfix  # noqa: F401,E402

import os
import sys
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402

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
    token = r.cookies.get("session")
    return r.json()["user_id"], token


def cleanup_user(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def cleanup_note(*note_ids):
    db = DBManager()
    try:
        for nid in note_ids:
            db.cur.execute("DELETE FROM note_verses WHERE note_id = %s", (nid,))
            db.cur.execute("DELETE FROM notes WHERE _id = %s", (nid,))
        db.conn.commit()
    finally:
        db.close()


def main():
    print("=== Boot the real app (main.app), lifespan included ===")
    with TestClient(main_module.app) as client:
        check("app boots and lifespan starts", True)

        uid, token = signup(client, f"notes_test_{uuid.uuid4().hex[:8]}")
        print(f"  created uid={uid}")
        created_note_ids = []

        try:
            note_body = {
                "user": uid, "title": "Test Note", "text": "This is a test note body.",
                "public": False, "group_id": "", "is_reply": False,
                "verses": [["John", 1, 1]],
            }

            # ── 1. Response shape: exactly {"id": <uuid>}, nothing else ──────
            print("\n=== 1. POST /notes/{user_id} response is exactly {\"id\": ...} ===")
            r = client.post(f"/notes/{uid}", json=note_body, headers=cookie_header(token))
            check("POST /notes/{user_id} -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
            body = r.json()
            check("response has exactly one top-level key", list(body.keys()) == ["id"], str(body.keys()))
            check("no leftover 'data' key (the bug that broke iOS's [String: String] decode)",
                  "data" not in body, str(body))
            server_id = body.get("id")
            created_note_ids.append(server_id)
            check("id looks like a real uuid", bool(server_id) and len(server_id) >= 32, server_id)

            # ── 2. The returned id is the note's REAL server-side id ─────────
            print("\n=== 2. Returned id matches what's actually stored server-side ===")
            r = client.get(f"/notes/{uid}", headers=cookie_header(token))
            check("GET /notes/{user_id} -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            notes = r.json()
            check("note is present under the server-issued id", server_id in notes, str(list(notes.keys())))
            if server_id in notes:
                check("stored title matches what was sent", notes[server_id]["title"] == "Test Note", notes[server_id])

            # ── 3. Using the server id, PUT and DELETE both succeed ──────────
            print("\n=== 3. PUT/DELETE with the server-issued id succeed (the old bug 404'd here) ===")
            edit_body = dict(note_body)
            edit_body["title"] = "Edited Test Note"
            r = client.put(f"/notes/{uid}", params={"note_id": server_id}, json=edit_body, headers=cookie_header(token))
            check("PUT with server id -> 200", r.status_code == 200, f"{r.status_code} {r.text}")

            r = client.get(f"/notes/{uid}", headers=cookie_header(token))
            check("edit persisted", r.json().get(server_id, {}).get("title") == "Edited Test Note", r.text)

            r = client.delete(f"/notes/{uid}", params={"note_id": server_id}, headers=cookie_header(token))
            check("DELETE with server id -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            created_note_ids.remove(server_id)

            r = client.get(f"/notes/{uid}", headers=cookie_header(token))
            check("note actually gone after delete", server_id not in r.json(), r.text)

            # ── 4. Regression guard: an id the server never issued 404s ──────
            print("\n=== 4. An unknown/made-up note_id (the old bug's failure mode) gets 404, not a silent success ===")
            r = client.post(f"/notes/{uid}", json=note_body, headers=cookie_header(token))
            check("second POST -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
            real_id = r.json()["id"]
            created_note_ids.append(real_id)

            fake_client_generated_id = str(uuid.uuid4())
            check("sanity: fake id is not the real one", fake_client_generated_id != real_id)

            r = client.put(f"/notes/{uid}", params={"note_id": fake_client_generated_id}, json=edit_body, headers=cookie_header(token))
            check("PUT with a client-fabricated id -> 404, not a false success", r.status_code == 404, f"{r.status_code} {r.text}")

            r = client.delete(f"/notes/{uid}", params={"note_id": fake_client_generated_id}, headers=cookie_header(token))
            check("DELETE with a client-fabricated id -> 404, not a false success", r.status_code == 404, f"{r.status_code} {r.text}")

            # The real note must be untouched by the failed operations above.
            r = client.get(f"/notes/{uid}", headers=cookie_header(token))
            check("real note untouched by the failed fake-id operations", real_id in r.json(), r.text)

        finally:
            print("\n=== cleanup ===")
            cleanup_note(*created_note_ids)
            cleanup_user(uid)

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
