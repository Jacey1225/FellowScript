"""Tests for GET /notes/{user_id}/note/{note_id} (task
20260903-friend-activity-note-navigation): the new single-note-fetch endpoint
that backs the iOS Friend Activity hero card's "tap the note preview to open
the full note" flow.

Per the up-front threat model (security gate, step 1) and its implementation
(backend gate, step 2), this endpoint must:
  - Require the authenticated caller (path user_id) to actually pass
    _can_view_note (owner, or shared group membership) before returning note
    content -- never trust the friend-activity feed's own prior filtering, or
    any client-supplied preview data, as proof of access (deny-by-default).
  - Return the byte-identical {"error": "cannot find note"} body (implicit
    200, not an HTTPException) for BOTH a missing note_id and a
    found-but-not-visible note, so note-id enumeration can't distinguish
    "doesn't exist" from "exists but you can't see it" -- mirroring
    post_reply's existing IDOR-safe pattern (test_notes_reply_visibility.py).
  - On success, return the full note including a "username" field (the
    owner's display name), which GET /{user_id} and GET /{user_id}/search
    omit (they only ever return the caller's own notes) but which
    NoteDetailView.canEdit needs to compare against the viewer's own
    username.

This proves:
  1. The owner can always fetch their own note.
  2. A shared-group member can fetch a group-shared note (even when not
     "public" in the edit-permission sense -- visibility is group_id-only).
  3. A non-member stranger cannot fetch a group-shared note -- generic
     "cannot find note" error, not a 403/404.
  4. A stranger cannot fetch another user's private (non-group) note, even
     if it's marked public=True (public no longer grants visibility; it only
     gates non-owner group-member edit permission).
  5. A nonexistent note_id gets the SAME generic error as a not-visible one
     (no oracle for probing which private note ids exist).
  6. A deleted note (existed, then removed) also gets the same generic error
     -- covers the "friend's note gets deleted between preview-load and tap
     time" case the iOS error-alert flow depends on.
  7. On success, the response includes "verses", "replies": [], and a
     correctly-populated "username" field for the owner.
  8. Auth boundary: fetching as a different, non-matching authenticated user
     (path user_id != session user) is rejected before any note lookup runs
     (require_match's existing 403 behavior, unrelated to _can_view_note).

Run with: cd api && ../.venv/bin/python tests/test_notes_get_single_note.py
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


def make_note(client, owner_id, token, *, public, group_id="", title="T", text="B"):
    r = client.post(f"/notes/{owner_id}", json={
        "user": owner_id, "title": title, "text": text,
        "public": public, "group_id": group_id, "verses": [],
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_note failed: {r.status_code} {r.text}"
    return r.json()["id"]


def get_note(client, viewer_id, token, note_id):
    return client.get(f"/notes/{viewer_id}/note/{note_id}", headers=cookie_header(token))


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
        uid_owner, token_owner = signup(client, f"getnote_owner_{uuid.uuid4().hex[:8]}")
        uid_stranger, token_stranger = signup(client, f"getnote_stranger_{uuid.uuid4().hex[:8]}")
        uid_member, token_member = signup(client, f"getnote_member_{uuid.uuid4().hex[:8]}")
        group_id = str(uuid.uuid4())

        try:
            r = client.post(f"/groups/{uid_owner}", json={
                "group_id": group_id, "title": "Study group", "users": [uid_owner, uid_member],
            }, headers=cookie_header(token_owner))
            check("group created with owner + member -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)

            print("=== 1. Owner can always fetch their own note ===")
            private_note_id = make_note(client, uid_owner, token_owner, public=False, title="Private", text="mine")
            r = get_note(client, uid_owner, token_owner, private_note_id)
            body = r.json()
            check("owner fetch own private note -> 200, no error",
                  r.status_code == 200 and "error" not in body, str(r.status_code) + " " + str(body))
            check("owner fetch own note -> correct text returned",
                  body.get("text") == "mine", str(body))
            check("owner fetch own note -> username field populated",
                  bool(body.get("username")), str(body))
            check("owner fetch own note -> verses/replies shape present",
                  "verses" in body and body.get("replies") == [], str(body))

            print("\n=== 2. Shared-group member CAN fetch a group-shared note (behavior preserved) ===")
            group_note_id = make_note(client, uid_owner, token_owner, public=False, group_id=group_id, text="group note")
            r = get_note(client, uid_member, token_member, group_note_id)
            body = r.json()
            check("group member fetch group-shared note -> 200, correct text",
                  r.status_code == 200 and body.get("text") == "group note", str(r.status_code) + " " + str(body))
            check("group member fetch -> owner username surfaced (not just user_id)",
                  body.get("username") not in (None, ""), str(body))

            print("\n=== 3. Non-member stranger CANNOT fetch a group-shared note ===")
            r = get_note(client, uid_stranger, token_stranger, group_note_id)
            body = r.json()
            check("stranger fetch group-shared note -> generic 'cannot find note' error",
                  r.status_code == 200 and body.get("error") == "cannot find note", str(r.status_code) + " " + str(body))
            check("stranger fetch -> no note content leaked (no 'text' key)",
                  "text" not in body, str(body))

            print("\n=== 4. Stranger cannot fetch a personal note even when public=True "
                  "(public no longer grants visibility -- group_id-only) ===")
            public_personal_note_id = make_note(client, uid_owner, token_owner, public=True, text="public but personal")
            r = get_note(client, uid_stranger, token_stranger, public_personal_note_id)
            body = r.json()
            check("stranger fetch personal public=True note -> generic 'cannot find note' error",
                  r.status_code == 200 and body.get("error") == "cannot find note", str(r.status_code) + " " + str(body))

            print("\n=== 5. Nonexistent note_id gets the SAME generic error (no probing oracle) ===")
            r = get_note(client, uid_stranger, token_stranger, str(uuid.uuid4()))
            body_missing = r.json()
            check("nonexistent note_id -> generic 'cannot find note' error",
                  r.status_code == 200 and body_missing.get("error") == "cannot find note",
                  str(r.status_code) + " " + str(body_missing))
            r2 = get_note(client, uid_stranger, token_stranger, public_personal_note_id)
            body_denied = r2.json()
            check("missing-note response is byte-identical to not-visible-note response (IDOR-safe)",
                  body_missing == body_denied and r.status_code == r2.status_code,
                  f"missing={body_missing!r} denied={body_denied!r}")

            print("\n=== 6. A note deleted after creation gets the same generic error "
                  "(covers the iOS 'deleted between preview-load and tap' failure alert) ===")
            deleted_note_id = make_note(client, uid_owner, token_owner, public=False, group_id=group_id, text="soon gone")
            r = client.delete(f"/notes/{uid_owner}?note_id={deleted_note_id}", headers=cookie_header(token_owner))
            check("owner delete note -> success status", r.status_code in (200, 204), str(r.status_code) + " " + r.text)
            r = get_note(client, uid_member, token_member, deleted_note_id)
            body = r.json()
            check("group member fetch a since-deleted note -> generic 'cannot find note' error, not a crash",
                  r.status_code == 200 and body.get("error") == "cannot find note", str(r.status_code) + " " + str(body))

            print("\n=== 7. Auth boundary: path user_id must match the authenticated session ===")
            r = get_note(client, uid_stranger, token_member, private_note_id)
            check("mismatched path user_id vs. session -> 403 (require_match, before any note lookup)",
                  r.status_code == 403, str(r.status_code) + " " + r.text)

        finally:
            print("\n=== cleanup ===")
            cleanup(uid_owner, uid_stranger, uid_member, group_id=group_id)

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
