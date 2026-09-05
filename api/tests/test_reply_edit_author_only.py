"""Tests for the per-reply Edit button task (20260904-reply-edit-button),
backend/security-corrected scope: `update_note` (api/routes/notes.py) must
treat a reply (`is_reply` True) as author-only for editing, with NO
owner-or-group-edit-permission exception -- unlike an ordinary (non-reply)
note, whose existing `public`/group-membership non-owner branch
(task 20260903-notes-public-repurpose) must be completely unaffected.

Covers the acceptance criteria from
.claude/pipeline/20260904-reply-edit-button/intake-spec.md and the
architecture-corrected step 1/4 instructions:
  1. A non-author group member's direct PUT against a reply row is rejected
     (403) even when the reply's own `public` flag is True and its
     `group_id` matches a group the caller belongs to.
  2. A non-member of the reply's group is rejected too (403).
  3. The reply's own author CAN edit it, and the edit persists to the
     correct row (verified via the real id surfaced by
     GET /groups/{user_id}/{note_id}/{group_id}/replies, not a synthesized
     client-side id).
  4. Editing a reply never mutates the parent note's row.
  5. Regression: an ordinary (non-reply) group note's existing
     owner-or-group-edit-permission behavior (public=True grants a non-owner
     group member an edit) is completely unchanged by the is_reply branch.

Run: cd api && ../.venv/bin/python tests/test_reply_edit_author_only.py
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
        "group_id": gid, "title": "Reply-edit-permission test group",
        "users": [owner_id] + member_ids,
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def make_note(client, owner_id, token, *, public, group_id, title="Parent", text="Body"):
    r = client.post(f"/notes/{owner_id}", json={
        "user": owner_id, "title": title, "text": text,
        "public": public, "group_id": group_id, "verses": [],
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_note failed: {r.status_code} {r.text}"
    return r.json()["id"]


def post_reply(client, note_id, replier_id, token, *, public=True, text="Reply body"):
    r = client.post(f"/notes/reply/{note_id}", json={
        "user": replier_id, "title": "", "text": text, "public": public, "verses": [],
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"post_reply failed: {r.status_code} {r.text}"
    return r.json()["id"]


def fetch_replies(client, viewer_id, token, note_id, group_id):
    return client.get(f"/groups/{viewer_id}/{note_id}/{group_id}/replies",
                       headers=cookie_header(token))


def update_note(client, actor_id, token, note_id, *, title="Edited", text="Edited body",
                 public=True, group_id=""):
    body = {"title": title, "text": text, "public": public, "group_id": group_id, "verses": []}
    return client.put(f"/notes/{actor_id}?note_id={note_id}", json=body,
                       headers=cookie_header(token))


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
        uid_owner, token_owner = signup(client, "replyedit_owner")
        uid_author, token_author = signup(client, "replyedit_author")     # posts the reply
        uid_member, token_member = signup(client, "replyedit_member")     # same group, not the reply's author
        uid_stranger, token_stranger = signup(client, "replyedit_stranger")  # not in the group at all
        gid = create_group(client, token_owner, uid_owner, [uid_author, uid_member])

        try:
            parent_note_id = make_note(client, uid_owner, token_owner, public=True, group_id=gid)

            print("=== 1. Non-author group member CANNOT edit a reply, even public=True + shared group_id ===")
            reply_id = post_reply(client, parent_note_id, uid_author, token_author, public=True)
            r = update_note(client, uid_member, token_member, reply_id,
                             title="Should not land", public=True, group_id=gid)
            check("non-author group member edit of a reply -> 403 (no group-edit exception for replies)",
                  r.status_code == 403, f"{r.status_code} {r.text}")

            print("\n=== 2. Non-member of the group CANNOT edit the reply either ===")
            r = update_note(client, uid_stranger, token_stranger, reply_id,
                             title="Should not land", public=True, group_id=gid)
            check("non-member edit of a reply -> 403",
                  r.status_code == 403, f"{r.status_code} {r.text}")

            print("\n=== 3. Reply's own author CAN edit it, and the edit persists to the correct row ===")
            fetch_r = fetch_replies(client, uid_owner, token_owner, parent_note_id, gid)
            check("fetch_replies -> 200", fetch_r.status_code == 200, f"{fetch_r.status_code} {fetch_r.text}")
            replies_payload = fetch_r.json()
            real_ids = [r_.get("id") for r_ in replies_payload] if isinstance(replies_payload, list) else []
            check("fetched reply carries its real backend id",
                  reply_id in real_ids, f"expected {reply_id} in {real_ids}")

            r = update_note(client, uid_author, token_author, reply_id,
                             title="Edited by author", text="Edited body", public=True, group_id=gid)
            check("author edit of own reply -> 200/204", r.status_code in (200, 204),
                  f"{r.status_code} {r.text}")

            db = DBManager()
            try:
                row = db.lookup("notes", {"_id": reply_id})
                _, data = list(row.items())[0]
                check("reply edit actually persisted (title updated on the real row)",
                      data.get("title") == "Edited by author", data)
            finally:
                db.close()

            print("\n=== 4. Editing the reply never mutates the parent note's row ===")
            db = DBManager()
            try:
                row = db.lookup("notes", {"_id": parent_note_id})
                _, parent_data = list(row.items())[0]
                check("parent note's title unchanged after the reply edit",
                      parent_data.get("title") == "Parent", parent_data)
            finally:
                db.close()

            print("\n=== 5. Regression: ordinary (non-reply) group note's public=True group-edit path is unchanged ===")
            ordinary_note_id = make_note(client, uid_owner, token_owner, public=True, group_id=gid,
                                          title="Ordinary note")
            r = update_note(client, uid_member, token_member, ordinary_note_id,
                             title="Edited by member", public=True, group_id=gid)
            check("non-owner member edit of an ordinary public=True group note still -> 200/204 (no regression)",
                  r.status_code in (200, 204), f"{r.status_code} {r.text}")

        finally:
            print("\n=== cleanup ===")
            cleanup(uid_owner, uid_author, uid_member, uid_stranger, group_ids=[gid])

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
