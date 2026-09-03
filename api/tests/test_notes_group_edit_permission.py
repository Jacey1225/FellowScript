"""Tests for the notes.public repurposing (task
20260903-notes-public-repurpose): `public` no longer gates note visibility
(visibility is now group_id-only, see test_notes_reply_visibility.py case 2
and test_notes_reply_visibility.py's other cases) -- it now gates whether a
*non-owner* member of the note's group may EDIT that note. update_note
(api/routes/notes.py) gained a new authorization branch for this, plus an
IDOR guard preventing a non-owner from smuggling a different group_id through
the same request to escape or retarget the membership check that authorized
their edit.

Covers the acceptance criteria from
.claude/pipeline/20260903-notes-public-repurpose/intake-spec.md:
  1. A non-owner group member CAN edit a group note when public=True.
  2. A non-owner group member CANNOT edit a group note when public=False
     (403, deny-by-default).
  3. A non-member of the note's group CANNOT edit it even when public=True
     (403).
  4. The owner can always edit their own note regardless of public/group_id.
  5. delete_note stays owner-only even when public=True (non-owner group
     member gets 403 on DELETE despite being allowed to edit).
  6. IDOR guard: a non-owner's authorized edit cannot retarget the note's
     group_id to a different group, nor strip it to empty, in the same
     request (403).
  7. A personal note (no group_id) can never be edited by a non-owner, even
     if public were somehow True (no group to draw membership from).
  8. _can_view_note no longer grants visibility via public=True alone (a
     stranger with no group membership still can't reply -- covered more
     fully in test_notes_reply_visibility.py; spot-checked here too via the
     view-gated reply endpoint for a personal public=True note).

Run: cd api && ../.venv/bin/python tests/test_notes_group_edit_permission.py
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

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def cookie_header(token: str | None):
    return {"cookie": f"session={token}"} if token else {}


def signup(client, prefix: str):
    username = f"{prefix}_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    })
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def create_group(client, token, owner_id, member_ids):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner_id}", json={
        "group_id": gid, "title": "Edit-permission test group",
        "users": [owner_id] + member_ids,
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def make_note(client, owner_id, token, *, public, group_id="", title="T", text="B"):
    r = client.post(f"/notes/{owner_id}", json={
        "user": owner_id, "title": title, "text": text,
        "public": public, "group_id": group_id, "verses": [],
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_note failed: {r.status_code} {r.text}"
    return r.json()["id"]


def update_note(client, actor_id, token, note_id, *, title="Edited", text="Edited body",
                 public=None, group_id=None, base_public=False, base_group_id=""):
    body = {
        "title": title, "text": text,
        "public": base_public if public is None else public,
        "group_id": base_group_id if group_id is None else group_id,
        "verses": [],
    }
    return client.put(f"/notes/{actor_id}?note_id={note_id}", json=body,
                       headers=cookie_header(token))


def delete_note(client, actor_id, token, note_id):
    return client.delete(f"/notes/{actor_id}?note_id={note_id}", headers=cookie_header(token))


def reply(client, note_id, replier_id, token, text="reply text"):
    return client.post(f"/notes/reply/{note_id}", json={
        "user": replier_id, "title": "Re", "text": text, "public": False, "verses": [],
    }, headers=cookie_header(token))


def cleanup(*user_ids, group_ids=()):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
        for gid in group_ids:
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def main():
    import main as main_module
    with TestClient(main_module.app) as client:
        uid_owner, token_owner = signup(client, "editperm_owner")
        uid_member, token_member = signup(client, "editperm_member")
        uid_stranger, token_stranger = signup(client, "editperm_stranger")
        gid = create_group(client, token_owner, uid_owner, [uid_member])

        try:
            print("=== 1. Non-owner group member CAN edit a public=True group note ===")
            note_id = make_note(client, uid_owner, token_owner, public=True, group_id=gid)
            r = update_note(client, uid_member, token_member, note_id,
                             title="Edited by member", public=True, group_id=gid)
            check("non-owner member edit of public=True group note -> 200/204",
                  r.status_code in (200, 204), f"{r.status_code} {r.text}")
            # Confirm the write actually landed.
            db = DBManager()
            try:
                row = db.lookup("notes", {"_id": note_id})
                _, data = list(row.items())[0]
                check("edit persisted (title updated)", data.get("title") == "Edited by member", data)
            finally:
                db.close()

            print("\n=== 2. Non-owner group member CANNOT edit a public=False group note (403) ===")
            note_id_2 = make_note(client, uid_owner, token_owner, public=False, group_id=gid)
            r = update_note(client, uid_member, token_member, note_id_2,
                             title="Should not land", public=False, group_id=gid)
            check("non-owner member edit of public=False group note -> 403",
                  r.status_code == 403, f"{r.status_code} {r.text}")

            print("\n=== 3. Non-member of the note's group CANNOT edit it even when public=True (403) ===")
            note_id_3 = make_note(client, uid_owner, token_owner, public=True, group_id=gid)
            r = update_note(client, uid_stranger, token_stranger, note_id_3,
                             title="Should not land", public=True, group_id=gid)
            check("non-member edit of public=True group note -> 403",
                  r.status_code == 403, f"{r.status_code} {r.text}")

            print("\n=== 4. Owner can always edit their own note regardless of public/group_id ===")
            note_id_4 = make_note(client, uid_owner, token_owner, public=False, group_id="")
            r = update_note(client, uid_owner, token_owner, note_id_4,
                             title="Owner edited", public=False, group_id="")
            check("owner edit of own personal note -> 200/204",
                  r.status_code in (200, 204), f"{r.status_code} {r.text}")

            print("\n=== 5. delete_note stays owner-only even when public=True (non-owner gets 403) ===")
            note_id_5 = make_note(client, uid_owner, token_owner, public=True, group_id=gid)
            r = delete_note(client, uid_member, token_member, note_id_5)
            check("non-owner member DELETE of public=True group note -> 403 (edit != delete)",
                  r.status_code == 403, f"{r.status_code} {r.text}")
            r = delete_note(client, uid_owner, token_owner, note_id_5)
            check("owner DELETE of their own note -> 200/204",
                  r.status_code in (200, 204), f"{r.status_code} {r.text}")

            print("\n=== 6. IDOR guard: non-owner's authorized edit cannot retarget/strip group_id ===")
            note_id_6 = make_note(client, uid_owner, token_owner, public=True, group_id=gid)
            gid_other = create_group(client, token_stranger, uid_stranger, [])
            try:
                r = update_note(client, uid_member, token_member, note_id_6,
                                 title="Retarget attempt", public=True, group_id=gid_other)
                check("non-owner edit smuggling a different group_id -> 403 (retarget blocked)",
                      r.status_code == 403, f"{r.status_code} {r.text}")

                r2 = update_note(client, uid_member, token_member, note_id_6,
                                  title="Strip attempt", public=True, group_id="")
                check("non-owner edit smuggling an empty group_id -> 403 (strip blocked)",
                      r2.status_code == 403, f"{r2.status_code} {r2.text}")

                # Confirm neither smuggled write landed.
                db = DBManager()
                try:
                    row = db.lookup("notes", {"_id": note_id_6})
                    _, data = list(row.items())[0]
                    check("note's group_id unchanged after blocked retarget/strip attempts",
                          str(data.get("group_id")) == gid, data)
                    check("note's title unchanged after blocked retarget/strip attempts",
                          data.get("title") != "Retarget attempt" and data.get("title") != "Strip attempt",
                          data)
                finally:
                    db.close()
            finally:
                cleanup(group_ids=[gid_other])

            print("\n=== 7. Personal note (no group_id) can never be edited by a non-owner ===")
            note_id_7 = make_note(client, uid_owner, token_owner, public=True, group_id="")
            r = update_note(client, uid_member, token_member, note_id_7,
                             title="Should not land", public=True, group_id="")
            check("non-owner edit of a personal note (even public=True) -> 403 (no group to draw membership from)",
                  r.status_code == 403, f"{r.status_code} {r.text}")

            print("\n=== 8. public=True alone no longer grants view/reply access outside group membership ===")
            personal_public_note = make_note(client, uid_owner, token_owner, public=True, group_id="")
            r = reply(client, personal_public_note, uid_stranger, token_stranger)
            check("stranger cannot reply to a personal public=True note "
                  "(visibility is group_id-only now, public no longer grants it)",
                  r.status_code == 201 and r.json().get("error") == "cannot find note",
                  f"{r.status_code} {r.json()}")

        finally:
            print("\n=== cleanup ===")
            cleanup(uid_owner, uid_member, uid_stranger, group_ids=[gid])

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
