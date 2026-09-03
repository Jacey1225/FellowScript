"""Tests for the note-reply visibility check (security audit finding 11, LOW):
api/routes/notes.py's post_reply let any authenticated user reply to any
note_id (including private ones they otherwise couldn't view), with no
parent-note visibility check. Low severity since note ids are non-enumerable
UUIDs, but still a real access-control gap: a caller who somehow learns a
private note_id (e.g. leaked in a client log, shared link, referrer) could
attach a reply to it despite never being able to see the note itself.

The fix: post_reply now checks _can_view_note(parent, current_user) — the
same visibility rule as reading a note (owner, public, or group member) —
before allowing a reply, returning the same generic {"error": "cannot find
note"} body for both a missing note_id and a not-visible one, so the endpoint
can't be used to probe which private note ids exist.

This proves:
  1. A non-owner, non-member caller cannot reply to another user's private
     (non-public, non-group) note — gets the generic "cannot find note" body.
  2. A personal note's `public` value no longer grants view/reply access to a
     stranger (task 20260903-notes-public-repurpose: `public` now means
     "group members may edit," not "visible to others" -- visibility is
     group_id-only, so a stranger still can't reply even when public=True).
  3. A group member can reply to a note shared in their group even when it's
     not "public" in the new edit-permission sense (behavior preserved —
     group sharing still works regardless of the edit-permission flag).
  4. A non-member cannot reply to a note shared in a group they don't belong
     to (the actual access-control gap this finding closes).
  5. The owner can always reply to their own note (behavior preserved).
  6. A nonexistent note_id gets the SAME generic error body as a
     not-visible one (no oracle for probing private ids).

Run with: cd api && ../.venv/bin/python tests/test_notes_reply_visibility.py
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


def reply(client, note_id, replier_id, token, text="reply text"):
    return client.post(f"/notes/reply/{note_id}", json={
        "user": replier_id, "title": "Re", "text": text, "public": False, "verses": [],
    }, headers=cookie_header(token))


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
        uid_owner, token_owner = signup(client, f"replyvis_owner_{uuid.uuid4().hex[:8]}")
        uid_stranger, token_stranger = signup(client, f"replyvis_stranger_{uuid.uuid4().hex[:8]}")
        uid_member, token_member = signup(client, f"replyvis_member_{uuid.uuid4().hex[:8]}")
        group_id = str(uuid.uuid4())

        try:
            r = client.post(f"/groups/{uid_owner}", json={
                "group_id": group_id, "title": "Study group", "users": [uid_owner, uid_member],
            }, headers=cookie_header(token_owner))
            check("group created with owner + member -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)

            print("=== 1. Private note (not public, not group-shared): stranger cannot reply ===")
            private_note_id = make_note(client, uid_owner, token_owner, public=False)
            r = reply(client, private_note_id, uid_stranger, token_stranger)
            check("stranger reply to private note -> generic 'cannot find note' error",
                  r.status_code == 201 and r.json().get("error") == "cannot find note", str(r.status_code) + " " + str(r.json()))
            check("no reply id returned to the stranger", "id" not in r.json(), str(r.json()))

            print("\n=== 2. Personal note with public=True: stranger still cannot reply "
                  "(public no longer grants visibility -- it's an edit-permission flag now) ===")
            public_note_id = make_note(client, uid_owner, token_owner, public=True)
            r = reply(client, public_note_id, uid_stranger, token_stranger)
            check("stranger reply to a personal public=True note -> generic 'cannot find note' error",
                  r.status_code == 201 and r.json().get("error") == "cannot find note",
                  str(r.status_code) + " " + str(r.json()))

            print("\n=== 3. Group-shared note (not public): group member CAN reply (behavior preserved) ===")
            group_note_id = make_note(client, uid_owner, token_owner, public=False, group_id=group_id)
            r = reply(client, group_note_id, uid_member, token_member)
            check("group member reply to non-public group-shared note -> succeeds with an id",
                  r.status_code == 201 and "id" in r.json(), str(r.status_code) + " " + str(r.json()))

            print("\n=== 4. Group-shared note (not public): non-member CANNOT reply (the actual fix) ===")
            group_note_id_2 = make_note(client, uid_owner, token_owner, public=False, group_id=group_id)
            r = reply(client, group_note_id_2, uid_stranger, token_stranger)
            check("non-member reply to group-shared note -> generic 'cannot find note' error",
                  r.status_code == 201 and r.json().get("error") == "cannot find note", str(r.status_code) + " " + str(r.json()))

            print("\n=== 5. Owner can always reply to their own note (behavior preserved) ===")
            r = reply(client, private_note_id, uid_owner, token_owner)
            check("owner reply to own private note -> succeeds with an id",
                  r.status_code == 201 and "id" in r.json(), str(r.status_code) + " " + str(r.json()))

            print("\n=== 6. Nonexistent note_id gets the SAME generic error (no probing oracle) ===")
            r = reply(client, str(uuid.uuid4()), uid_stranger, token_stranger)
            check("nonexistent note_id -> same generic 'cannot find note' error",
                  r.status_code == 201 and r.json().get("error") == "cannot find note", str(r.status_code) + " " + str(r.json()))

            print("\n=== 7. Impersonating another user as reply author is still rejected (unrelated, pre-existing check) ===")
            r = client.post(f"/notes/reply/{public_note_id}", json={
                "user": uid_owner, "title": "Re", "text": "forged author", "public": False, "verses": [],
            }, headers=cookie_header(token_stranger))
            check("reply body claiming user=owner while authenticated as stranger -> 403",
                  r.status_code == 403, str(r.status_code))

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
