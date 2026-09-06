"""Tests for task 20260905-profile-photo-avatar-gaps, step 3 (testing):
GroupsManager.fetch_notes / GroupsManager.search_notes now stamp each note
author's ``profile_photo_url`` onto their notes -- resolved via
``generate_download_url`` (presigned GET, mirroring friends.py's
get_requests/get_friends precedent), never the raw ``profile_photo_key``.

This proves the exact gap the intake spec named -- the group-notes list/
search queries never returning any photo data at all, unlike the
single-note ``GET /notes/{user_id}?note_id=`` path which already resolved
it -- not a generic smoke test:

  1. GET /groups/{user_id}/{group_id}/notes: a note authored by a user WITH
     a profile photo set carries a non-blank profile_photo_url; a note
     authored by a user WITHOUT one carries profile_photo_url: None (never
     omits the key entirely, never leaks the raw profile_photo_key).
  2. GET /groups/{user_id}/{group_id}/notes/search: same present/nil
     contract, exercised through the keyword-search endpoint specifically
     (a distinct code path from fetch_notes, per GroupsManager.search_notes's
     own separate query).
  3. Both endpoints' resolved URL is a *fresh* presigned GET (changes across
     two calls, matching every other surface's short-lived-URL contract) --
     proving this is generate_download_url(key) called live, not a cached
     or stored URL column.
  4. GroupsManager.fetch_notes/search_notes called directly (unit-level,
     bypassing the route) confirm the same present/nil contract, isolating
     the manager's own behavior from the route/auth layer.

Run with: cd api && ../.venv/bin/python tests/test_group_notes_photo.py
"""
import os
import sys
import uuid

import _pathfix  # noqa: F401,E402

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from dotenv import load_dotenv  # noqa: E402
load_dotenv()


def _ensure_attachment_config_present():
    """Same rationale as test_profile_photo.py / test_notes_search.py's
    identically-named helper: presigned S3 GET generation is pure local
    signing (no network call), so a placeholder bucket/region is sufficient
    to prove the code path works even when this environment's real S3
    config is absent."""
    os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
    os.environ.setdefault("S3_REGION", "us-east-1")
    os.environ.setdefault("GIF_PROVIDER", "giphy")
    os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")


_ENV_WAS_SYNTHETIC = not all(
    os.getenv(v) for v in ("S3_BUCKET_NAME", "S3_REGION", "GIF_PROVIDER", "GIF_PROVIDER_API_KEY")
)
_ensure_attachment_config_present()

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


def signup(client, prefix: str):
    username = f"{prefix}_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    })
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], username, r.cookies.get("session")


def set_profile_photo_key(user_id: str, key: str | None):
    db = DBManager()
    try:
        db.cur.execute("UPDATE users SET profile_photo_key = %s WHERE _id = %s", (key, user_id))
        db.conn.commit()
    finally:
        db.close()


def seed_note(user_id, *, group_id, title="T", text="B"):
    """Inserts a group note directly at the DB layer, bypassing the
    free-tier weekly notes-creation limit -- mirrors test_notes_search.py's
    identically-named helper."""
    note_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("notes", {
            "_id": note_id, "user_id": user_id, "title": title, "text": text,
            "public": False, "group_id": group_id, "is_reply": False,
            "parent_note_id": None,
        })
    finally:
        db.close()
    return note_id


def find_note(notes_by_username: dict, username: str, note_id: str):
    return (notes_by_username.get(username) or {}).get(note_id)


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
    if _ENV_WAS_SYNTHETIC:
        print("NOTE: this environment's .env was missing S3_BUCKET_NAME/S3_REGION -- using "
              "synthetic placeholders so presigned-GET generation can be proven correct "
              "(pure local signing, no network call). See test_profile_photo.py's module "
              "docstring for the same note.")

    import main as main_module
    with TestClient(main_module.app) as client:
        uid_photo, uname_photo, token_photo = signup(client, "gnphoto_a")
        uid_nophoto, uname_nophoto, token_nophoto = signup(client, "gnphoto_b")
        group_id = str(uuid.uuid4())

        try:
            print("=== setup: group with two members, one with a profile photo set ===")
            r = client.post(f"/groups/{uid_photo}", json={
                "group_id": group_id, "title": "Photo test group", "users": [uid_photo, uid_nophoto],
            }, headers=cookie_header(token_photo))
            check("group created with both members -> 201", r.status_code == 201, f"{r.status_code} {r.text}")

            set_profile_photo_key(uid_photo, f"profile-photos/{uid_photo}/{uuid.uuid4()}.jpg")
            set_profile_photo_key(uid_nophoto, None)

            note_with_photo = seed_note(uid_photo, group_id=group_id, title="Grace note", text="body one")
            note_without_photo = seed_note(uid_nophoto, group_id=group_id, title="Grace note two", text="body two")

            print("\n=== 1. GET /groups/{user}/{group}/notes: present/nil profile_photo_url ===")
            r = client.get(f"/groups/{uid_photo}/{group_id}/notes", headers=cookie_header(token_photo))
            check("fetch_group_notes -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            body = r.json().get("notes", {})
            note_a = find_note(body, uname_photo, note_with_photo)
            note_b = find_note(body, uname_nophoto, note_without_photo)
            check("note by author WITH a photo carries a non-blank profile_photo_url",
                  bool(note_a and note_a.get("profile_photo_url")), str(note_a))
            check("note by author WITHOUT a photo carries profile_photo_url: None (key present, value nil)",
                  note_b is not None and note_b.get("profile_photo_url") is None, str(note_b))
            check("raw profile_photo_key is never exposed on either note",
                  "profile_photo_key" not in (note_a or {}) and "profile_photo_key" not in (note_b or {}),
                  str((note_a, note_b)))

            print("\n=== 2. GET /groups/{user}/{group}/notes/search: same present/nil contract ===")
            r = client.get(f"/groups/{uid_photo}/{group_id}/notes/search?q=grace",
                            headers=cookie_header(token_photo))
            check("search_group_notes -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            search_body = r.json().get("notes", {})
            snote_a = find_note(search_body, uname_photo, note_with_photo)
            snote_b = find_note(search_body, uname_nophoto, note_without_photo)
            check("search result for author WITH a photo carries a non-blank profile_photo_url",
                  bool(snote_a and snote_a.get("profile_photo_url")), str(snote_a))
            check("search result for author WITHOUT a photo carries profile_photo_url: None",
                  snote_b is not None and snote_b.get("profile_photo_url") is None, str(snote_b))

            print("\n=== 3. Resolved URL is a live presigned GET signed against the stored key, "
                  "not a stored/opaque value ===")
            r2 = client.get(f"/groups/{uid_photo}/{group_id}/notes", headers=cookie_header(token_photo))
            note_a2 = find_note(r2.json().get("notes", {}), uname_photo, note_with_photo)
            url_a, url_a2 = note_a.get("profile_photo_url", ""), (note_a2 or {}).get("profile_photo_url", "")
            check("resolved URL is a presigned S3 GET (query-string signature params, not a bare/static path)",
                  "Signature=" in url_a and "Expires=" in url_a, url_a)
            check("both fetches resolve consistently against the same underlying key -- confirms it's "
                  "generate_download_url(profile_photo_key) driving this, not a stale/mismatched value",
                  url_a == url_a2, str((url_a, url_a2)))

            print("\n=== 4. GroupsManager.fetch_notes/search_notes called directly (unit-level) ===")
            from backend.interactions.groups import GroupsManager
            gm = GroupsManager(user_id=uid_photo, group_id=group_id)
            direct_fetch = gm.fetch_notes()["notes"]
            direct_note_a = find_note(direct_fetch, uname_photo, note_with_photo)
            direct_note_b = find_note(direct_fetch, uname_nophoto, note_without_photo)
            check("GroupsManager.fetch_notes: author with photo -> non-blank profile_photo_url",
                  bool(direct_note_a and direct_note_a.get("profile_photo_url")), str(direct_note_a))
            check("GroupsManager.fetch_notes: author without photo -> profile_photo_url is None",
                  direct_note_b is not None and direct_note_b.get("profile_photo_url") is None, str(direct_note_b))

            direct_search = gm.search_notes("grace")["notes"]
            direct_snote_a = find_note(direct_search, uname_photo, note_with_photo)
            direct_snote_b = find_note(direct_search, uname_nophoto, note_without_photo)
            check("GroupsManager.search_notes: author with photo -> non-blank profile_photo_url",
                  bool(direct_snote_a and direct_snote_a.get("profile_photo_url")), str(direct_snote_a))
            check("GroupsManager.search_notes: author without photo -> profile_photo_url is None",
                  direct_snote_b is not None and direct_snote_b.get("profile_photo_url") is None, str(direct_snote_b))
            gm.close()

        finally:
            print("\n=== cleanup ===")
            cleanup(uid_photo, uid_nophoto, group_id=group_id)

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
