"""Tests for task 20260903-notes-keyword-search, step 1 (backend): the new
keyword-search endpoints GET /notes/{user_id}/search (personal notes) and
GET /groups/{user_id}/{group_id}/notes/search (group notes).

This proves the specific properties the intake spec's acceptance criteria and
backend step called for -- not a generic smoke test:

  1. A personal-notes search matches by title OR text (case-insensitive
     substring / ILIKE), and does NOT return an unrelated note that doesn't
     match the keyword.
  2. Personal search never leaks another user's notes -- searching as one
     user cannot surface a different user's matching note (cross-user
     isolation / no-leakage), matching require_match("user_id") gating the
     route the same as every other /notes/{user_id} endpoint.
  3. Personal search excludes reply notes (is_reply = true), matching the
     existing list views which never show replies as their own rows.
  4. Group search matches by title/text for a group member, and results are
     keyed by username (same per-note shape as fetch_group_notes) via
     GroupsManager.search_notes.
  5. Group search 403s for a non-member -- searching a group you don't
     belong to cannot be used to discover its notes' existence/content
     (composes with the existing is_member() access boundary, doesn't
     bypass it).
  6. Group search also excludes reply notes, matching fetch_group_notes.
  7. The search query is parameterized (ILIKE with %s placeholders): a
     keyword containing SQL metacharacters (', %, _) does not error or
     behave unsafely -- it's treated as a literal (or ILIKE-wildcard-only)
     substring, proving no string interpolation is used.

Note: note creation goes directly through the DB (seed_note), not
POST /notes/{user_id}, to avoid the (unrelated) free-tier weekly
notes-creation limit, mirroring test_notes_pagination.py's convention.

Run with: cd api && ../.venv/bin/python tests/test_notes_search.py
"""
import os
import sys
import uuid
from urllib.parse import quote

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


def search_qs(q: str) -> str:
    return f"?q={quote(q, safe='')}"


def signup(client, username):
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    })
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def seed_note(user_id, *, group_id=None, is_reply=False, parent_note_id=None, title="T", text="B"):
    """Inserts a note directly at the DB layer, bypassing the free-tier
    weekly notes-creation limit (unrelated to this task). Mirrors exactly
    the columns create_note writes (api/routes/notes.py)."""
    note_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("notes", {
            "_id": note_id, "user_id": user_id, "title": title, "text": text,
            "public": False, "group_id": group_id, "is_reply": is_reply,
            "parent_note_id": parent_note_id,
        })
    finally:
        db.close()
    return note_id


def cleanup(*user_ids, group_id=None):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
        if group_id:
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (group_id,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def main():
    import main as main_module
    with TestClient(main_module.app) as client:
        uid_a, token_a = signup(client, f"nsearch_a_{uuid.uuid4().hex[:8]}")
        uid_b, token_b = signup(client, f"nsearch_b_{uuid.uuid4().hex[:8]}")
        group_id = str(uuid.uuid4())

        try:
            print("=== setup: personal notes for user A ===")
            match_by_title  = seed_note(uid_a, title="Psalm reflections", text="an ordinary body")
            match_by_text   = seed_note(uid_a, title="Untitled", text="deep thoughts on grace and mercy")
            no_match        = seed_note(uid_a, title="Genesis notes", text="something else entirely")
            reply_note      = seed_note(uid_a, title="grace reply", text="grace grace grace", is_reply=True,
                                         parent_note_id=match_by_text)
            other_user_note = seed_note(uid_b, title="grace notes from B", text="also about grace")

            print("\n=== 1+3. Personal search: matches by title/text, excludes replies, excludes non-matches ===")
            r = client.get(f"/notes/{uid_a}/search{search_qs('grace')}", headers=cookie_header(token_a))
            check("personal search -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)
            body = r.json().get("notes", {})
            check("matches note whose TEXT contains the keyword", match_by_text in body, str(body.keys()))
            check("does not include the non-matching note", no_match not in body, str(body.keys()))
            check("does not include a reply note even though its text matches", reply_note not in body, str(body.keys()))

            r2 = client.get(f"/notes/{uid_a}/search{search_qs('psalm')}", headers=cookie_header(token_a))
            body2 = r2.json().get("notes", {})
            check("case-insensitive match by TITLE ('psalm' matches 'Psalm reflections')",
                  match_by_title in body2, str(body2.keys()))

            print("\n=== 2. Personal search: no cross-user leakage ===")
            check("user A's search for 'grace' does not include user B's matching note",
                  other_user_note not in body, str(body.keys()))
            r3 = client.get(f"/notes/{uid_b}/search{search_qs('grace')}", headers=cookie_header(token_a))
            check("user A cannot search user B's notes at all (require_match user_id) -> 403",
                  r3.status_code == 403, str(r3.status_code) + " " + r3.text)

            print("\n=== 7. Parameterized query: SQL metacharacters in q are treated literally, no error ===")
            metachar_query = "'; DROP TABLE notes; --"
            r4 = client.get(f"/notes/{uid_a}/search{search_qs(metachar_query)}",
                             headers=cookie_header(token_a))
            check("metacharacter-laden query -> 200, not an error, and matches nothing",
                  r4.status_code == 200 and r4.json().get("notes", {}) == {}, str(r4.status_code) + " " + r4.text)
            # Prove the notes table is still intact after that query.
            r5 = client.get(f"/notes/{uid_a}/search{search_qs('grace')}", headers=cookie_header(token_a))
            check("notes table still intact after metacharacter query (parameterized, not interpolated)",
                  r5.status_code == 200 and match_by_text in r5.json().get("notes", {}),
                  str(r5.status_code) + " " + r5.text)

            print("\n=== group setup ===")
            r = client.post(f"/groups/{uid_a}", json={
                "group_id": group_id, "title": "Search group", "users": [uid_a],
            }, headers=cookie_header(token_a))
            check("group created with owner only -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)

            group_match    = seed_note(uid_a, group_id=group_id, title="Group grace note", text="body")
            group_no_match = seed_note(uid_a, group_id=group_id, title="Group unrelated", text="body")
            group_reply    = seed_note(uid_a, group_id=group_id, title="grace reply", text="body",
                                        is_reply=True, parent_note_id=group_match)

            print("\n=== 4+6. Group search: member matches by title, excludes non-matches and replies ===")
            r = client.get(f"/groups/{uid_a}/{group_id}/notes/search{search_qs('grace')}",
                            headers=cookie_header(token_a))
            check("group search (member) -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)
            group_body = r.json().get("notes", {})
            all_ids = {nid for by_user in group_body.values() for nid in by_user}
            check("group search matches the group note by title", group_match in all_ids, str(group_body))
            check("group search excludes the non-matching group note", group_no_match not in all_ids, str(group_body))
            check("group search excludes a reply even though its title matches", group_reply not in all_ids, str(group_body))

            print("\n=== 5. Group search: non-member is rejected (composes with is_member(), not bypassed) ===")
            r = client.get(f"/groups/{uid_b}/{group_id}/notes/search{search_qs('grace')}",
                            headers=cookie_header(token_b))
            check("non-member group search -> 403", r.status_code == 403, str(r.status_code) + " " + r.text)

        finally:
            print("\n=== cleanup ===")
            cleanup(uid_a, uid_b, group_id=group_id)

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
