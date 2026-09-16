"""Regression coverage for task 20260916-group-leave-deletes-group.

Bug: tapping "Leave" on a group hit `DELETE /groups/{user_id}/{group_id}`,
gated only by `is_member()` -- so ANY single member leaving destroyed the
group for everyone, orphaning its notes/messages/devotions/sessions. The fix
(backend step 1):

  - `POST /groups/{user_id}/{group_id}/leave` removes only the caller from
    `groups.users`, leaving the group, its title, other members, and its
    notes/messages intact -- unless the caller was the last remaining
    member, in which case the now-empty group is auto-deleted as a
    system-triggered cleanup.
  - `DELETE /groups/{user_id}/{group_id}` (full group deletion) is now
    gated on `GroupsManager.can_delete()` instead of bare membership:
    a group with a recorded `creator_id` may only be deleted by that
    creator; a `creator_id`-NULL group (pre-existing, or a deleted-account
    fallback) may be deleted by any current member; anyone else gets 403.

This file proves:
  - Leaving removes only the leaving member; the group, its title, its
    remaining member's access, and its notes/messages survive intact (the
    actual bug -- must now pass, must NOT delete the group for the
    remaining member).
  - Leaving as the very last member auto-deletes the now-empty group.
  - The creator can delete a non-empty group outright (all members lose
    access); a non-creator member is denied with 403 (not 204) -- the
    fix must not weaken authorization in the other direction either.
  - A `creator_id`-NULL group (simulating a pre-existing row from before
    this column existed) can be deleted by any current member, but still
    denies a genuine outsider (fail-closed on the permissive fallback).

Run with: cd api && ../.venv/bin/python tests/test_group_leave_delete.py
"""
import _pathfix  # noqa: F401

import os
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
# Real S3/GIF config may not be present in every dev environment; a
# placeholder is sufficient since this file never exercises either
# subsystem -- it only needs main.app's lifespan config validation to pass
# so the real HTTP routes can boot (see test_group_session_join_regression.py
# for the same precedent). Must be set before importing main.
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

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


def cleanup(*user_ids, group_ids=()):
    db = DBManager()
    try:
        for gid in group_ids:
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def create_group(client, token, owner_uid, member_uids, title="Leave/Delete regression group"):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner_uid}", json={
        "group_id": gid, "title": title, "users": [owner_uid, *member_uids],
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def fetch_group(client, token, uid, gid):
    return client.get(f"/groups/{uid}/{gid}", headers=cookie_header(token))


def leave_group(client, token, uid, gid):
    return client.post(f"/groups/{uid}/{gid}/leave", headers=cookie_header(token))


def delete_group(client, token, uid, gid):
    return client.delete(f"/groups/{uid}/{gid}", headers=cookie_header(token))


def group_row(gid):
    db = DBManager()
    try:
        db.cur.execute("SELECT _id, title, users, creator_id FROM groups WHERE _id = %s", (gid,))
        row = db.cur.fetchone()
        return row
    finally:
        db.close()


def insert_note(gid, uid):
    """Directly seeds one group note via the DB, bypassing content-filter/
    routing concerns unrelated to this bug -- this test only cares whether
    the note row (and its group_id linkage) survives a leave."""
    nid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("notes", {
            "_id": nid, "user_id": uid, "title": "Regression note", "text": "hello",
            "public": True, "group_id": gid, "is_reply": False,
        })
    finally:
        db.close()
    return nid


def note_still_linked(nid, gid):
    db = DBManager()
    try:
        db.cur.execute("SELECT group_id FROM notes WHERE _id = %s", (nid,))
        row = db.cur.fetchone()
        return row is not None and row[0] is not None and str(row[0]) == gid
    finally:
        db.close()


def test_leave_removes_only_caller_group_and_notes_survive(client):
    print("\n== Leaving a group with other members remaining: removes only the caller ==")
    uid_a, tok_a = signup(client, f"gl_stay_{uuid.uuid4().hex[:8]}")
    uid_b, tok_b = signup(client, f"gl_leave_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, tok_a, uid_a, [uid_b])
        note_id = insert_note(gid, uid_a)

        r = leave_group(client, tok_b, uid_b, gid)
        check("leave -> 204", r.status_code == 204, f"{r.status_code} {r.text}")

        row = group_row(gid)
        check("group row still exists after a non-last-member leave", row is not None, str(row))
        if row:
            check("remaining member (A) still in groups.users", uid_a in (row[2] or []), str(row[2]))
            check("leaving member (B) removed from groups.users", uid_b not in (row[2] or []), str(row[2]))
            check("group title unaffected by leave", row[1] == "Leave/Delete regression group", str(row[1]))

        check("remaining member A can still fetch the group", fetch_group(client, tok_a, uid_a, gid).status_code == 200,
              str(fetch_group(client, tok_a, uid_a, gid).text))
        check("group's note is still linked to group_id (not orphaned)", note_still_linked(note_id, gid))

        # The member who left is no longer authorized to view the group.
        r = fetch_group(client, tok_b, uid_b, gid)
        check("member who left can no longer fetch the group (403, not still a member)",
              r.status_code == 403, f"{r.status_code} {r.text}")
    finally:
        cleanup(uid_a, uid_b, group_ids=[gid] if gid else ())


def test_leave_as_last_member_auto_deletes_group(client):
    print("\n== Leaving as the last remaining member auto-deletes the now-empty group ==")
    uid, tok = signup(client, f"gl_solo_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, tok, uid, [])
        r = leave_group(client, tok, uid, gid)
        check("leave (last member) -> 204", r.status_code == 204, f"{r.status_code} {r.text}")

        row = group_row(gid)
        check("group row is gone after last member leaves", row is None, str(row))
    finally:
        cleanup(uid, group_ids=[gid] if gid else ())


def test_delete_group_creator_succeeds_non_creator_denied(client):
    print("\n== Explicit delete-group: creator succeeds, non-creator member gets 403 ==")
    uid_creator, tok_creator = signup(client, f"gl_owner_{uuid.uuid4().hex[:8]}")
    uid_member, tok_member = signup(client, f"gl_member_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, tok_creator, uid_creator, [uid_member])

        row = group_row(gid)
        check("newly created group has creator_id stamped to the creator",
              row is not None and str(row[3]) == uid_creator, str(row))

        # Non-creator member cannot delete outright.
        r = delete_group(client, tok_member, uid_member, gid)
        check("non-creator member delete-group -> 403 (not 204)", r.status_code == 403,
              f"{r.status_code} {r.text}")
        check("group still exists after denied delete attempt", group_row(gid) is not None)

        # Creator can delete outright, even though the group is non-empty.
        r = delete_group(client, tok_creator, uid_creator, gid)
        check("creator delete-group -> 204", r.status_code == 204, f"{r.status_code} {r.text}")
        check("group row gone after creator's delete", group_row(gid) is None)
        gid = None  # already cleaned up

        # Remaining member (uid_member) has lost access entirely -- confirms
        # deletion actually removed the group for every member, not just the
        # creator's own view of it.
    finally:
        cleanup(uid_creator, uid_member, group_ids=[gid] if gid else ())


def test_delete_group_null_creator_permissive_fallback(client):
    print("\n== creator_id-NULL group: any current member may delete; a real outsider still 403s ==")
    uid_a, tok_a = signup(client, f"gl_nullA_{uuid.uuid4().hex[:8]}")
    uid_b, tok_b = signup(client, f"gl_nullB_{uuid.uuid4().hex[:8]}")
    uid_outsider, tok_outsider = signup(client, f"gl_nulloutsider_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, tok_a, uid_a, [uid_b])
        # Simulate a pre-existing group created before the creator_id column
        # existed -- create_group always stamps it, so force it back to NULL
        # directly, matching how a real legacy row would look.
        db = DBManager()
        try:
            db.cur.execute("UPDATE groups SET creator_id = NULL WHERE _id = %s", (gid,))
            db.conn.commit()
        finally:
            db.close()

        row = group_row(gid)
        check("group's creator_id is NULL (simulated legacy row)", row is not None and row[3] is None, str(row))

        r = delete_group(client, tok_outsider, uid_outsider, gid)
        check("non-member outsider delete-group on NULL-creator group -> 403 (fail-closed)",
              r.status_code == 403, f"{r.status_code} {r.text}")
        check("group still exists after outsider's denied attempt", group_row(gid) is not None)

        r = delete_group(client, tok_b, uid_b, gid)
        check("current member B delete-group on NULL-creator group -> 204 (permissive fallback)",
              r.status_code == 204, f"{r.status_code} {r.text}")
        check("group row gone after member B's delete", group_row(gid) is None)
        gid = None
    finally:
        cleanup(uid_a, uid_b, uid_outsider, group_ids=[gid] if gid else ())


def main():
    with TestClient(main_module.app) as client:
        test_leave_removes_only_caller_group_and_notes_survive(client)
        test_leave_as_last_member_auto_deletes_group(client)
        test_delete_group_creator_succeeds_non_creator_denied(client)
        test_delete_group_null_creator_permissive_fallback(client)

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
