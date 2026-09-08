"""Tests for task 20260908-group-notes-verses (backend gate):
GroupsManager.fetch_notes / GroupsManager.search_notes now stamp each note's
attached verses onto its response data -- resolved via a batched
``note_verses`` lookup keyed by ``note_id = ANY(...)`` -- exactly mirroring
the shape routes/notes.py's personal-notes equivalents (GET /{user_id},
/{user_id}/search) already produce.

Root cause this proves fixed: the group-notes backend path never queried
note_verges at all, so "verses" was always absent from the response; the iOS
client's fetchGroupNotes then defaulted the missing key to [] and NoteRow
correctly hid the (empty) verse-chip row -- even though the note genuinely
had attached verses. This is why the bug only ever showed up for group
notes: the identical NoteRow view renders verse chips correctly once the
data is actually present, same as it always has for personal notes.

  1. GET /groups/{user_id}/{group_id}/notes: a group note with attached
     verses returns them, correctly ordered by position and shaped as
     [book, chapter, verse] triples -- matching a personal note with the
     same verses fetched via GET /notes/{user_id}.
  2. GET /groups/{user_id}/{group_id}/notes/search: same contract via the
     keyword-search endpoint (a distinct code path from fetch_notes, per
     GroupsManager.search_notes's own separate query).
  3. A group note with zero attached verses still returns "verses": [] --
     no regression to the existing no-verses case (present key, empty list,
     not an omitted key).
  4. GroupsManager.fetch_notes/search_notes called directly (unit-level,
     bypassing the route) confirm the same contract, isolating the
     manager's own behavior from the route/auth layer.
  5. Paginated second page (fetch_notes with a cursor) also carries verses
     -- proves the fix isn't limited to the first page.
  6. Regression guard: profile_photo_url (task 20260905) is still present
     and correct alongside the new verses field -- proves this fix didn't
     disturb that prior fix's behavior in the same two methods.

Run with: cd api && ../.venv/bin/python tests/test_group_notes_verses.py
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
    """Same rationale as test_group_notes_photo.py's identically-named
    helper: profile_photo_url resolution (exercised incidentally here since
    it shares the two methods under test) needs a placeholder bucket/region
    even when this environment's real S3 config is absent."""
    os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
    os.environ.setdefault("S3_REGION", "us-east-1")
    os.environ.setdefault("GIF_PROVIDER", "giphy")
    os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")


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


def seed_note(user_id, *, group_id=None, title="T", text="B", verses=None):
    """Inserts a note directly at the DB layer (personal if group_id is
    None, group otherwise), bypassing the free-tier weekly notes-creation
    limit -- mirrors test_group_notes_photo.py's identically-named helper,
    extended with an optional verses list inserted into note_verses the
    same way test_backup.py's add_note helper does."""
    note_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("notes", {
            "_id": note_id, "user_id": user_id, "title": title, "text": text,
            "public": False, "group_id": group_id, "is_reply": False,
            "parent_note_id": None,
        })
        for i, v in enumerate(verses or []):
            db.cur.execute(
                "INSERT INTO note_verses (note_id, position, book, chapter, verse) "
                "VALUES (%s,%s,%s,%s,%s)",
                (note_id, i, v[0], v[1], v[2]),
            )
        db.conn.commit()
    finally:
        db.close()
    return note_id


def find_note(notes_by_username: dict, username: str, note_id: str):
    return (notes_by_username.get(username) or {}).get(note_id)


def cleanup(*user_ids, group_id=None):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute(
                "DELETE FROM note_verses WHERE note_id IN (SELECT _id FROM notes WHERE user_id = %s)",
                (uid,),
            )
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
        uid_a, uname_a, token_a = signup(client, "gnv_a")
        uid_b, uname_b, token_b = signup(client, "gnv_b")
        group_id = str(uuid.uuid4())

        try:
            print("=== setup: group with two members ===")
            r = client.post(f"/groups/{uid_a}", json={
                "group_id": group_id, "title": "Verses test group", "users": [uid_a, uid_b],
            }, headers=cookie_header(token_a))
            check("group created with both members -> 201", r.status_code == 201, f"{r.status_code} {r.text}")

            note_with_verses = seed_note(
                uid_a, group_id=group_id, title="Numbers reading", text="chapter one",
                verses=[["Numbers", 1, 9], ["Numbers", 1, 10], ["Numbers", 1, 11]],
            )
            note_no_verses = seed_note(uid_b, group_id=group_id, title="Numbers reading two", text="no verses here")
            # A personal note with the same verses, as the reference shape to match.
            personal_note = seed_note(
                uid_a, group_id=None, title="Personal Numbers reading", text="personal",
                verses=[["Numbers", 1, 9], ["Numbers", 1, 10], ["Numbers", 1, 11]],
            )

            print("\n=== 1. GET /groups/{user}/{group}/notes: verses present + correctly ordered/shaped ===")
            r = client.get(f"/groups/{uid_a}/{group_id}/notes", headers=cookie_header(token_a))
            check("fetch_group_notes -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            body = r.json().get("notes", {})
            note_a = find_note(body, uname_a, note_with_verses)
            note_b = find_note(body, uname_b, note_no_verses)
            check("group note with attached verses carries the correct ordered [book, chapter, verse] triples",
                  note_a is not None and note_a.get("verses") == [["Numbers", "1", "9"], ["Numbers", "1", "10"], ["Numbers", "1", "11"]],
                  str(note_a))
            check("group note with zero attached verses still returns verses: [] (no regression, key present)",
                  note_b is not None and note_b.get("verses") == [],
                  str(note_b))

            print("\n=== 2. Personal note (reference shape) has the identical verses payload ===")
            rp = client.get(f"/notes/{uid_a}", headers=cookie_header(token_a))
            check("GET /notes/{user_id} -> 200", rp.status_code == 200, f"{rp.status_code} {rp.text}")
            personal_body = rp.json().get("notes", {})
            personal = personal_body.get(personal_note)
            check("personal note's verses payload matches the group note's (same shape/order)",
                  personal is not None and personal.get("verses") == (note_a or {}).get("verses"),
                  str((personal, note_a)))

            print("\n=== 3. GET /groups/{user}/{group}/notes/search: same verses contract ===")
            r = client.get(f"/groups/{uid_a}/{group_id}/notes/search?q=numbers",
                            headers=cookie_header(token_a))
            check("search_group_notes -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            search_body = r.json().get("notes", {})
            snote_a = find_note(search_body, uname_a, note_with_verses)
            snote_b = find_note(search_body, uname_b, note_no_verses)
            check("search result for note with attached verses carries the correct ordered triples",
                  snote_a is not None and snote_a.get("verses") == [["Numbers", "1", "9"], ["Numbers", "1", "10"], ["Numbers", "1", "11"]],
                  str(snote_a))
            check("search result for note with zero attached verses still returns verses: []",
                  snote_b is not None and snote_b.get("verses") == [],
                  str(snote_b))

            print("\n=== 4. GroupsManager.fetch_notes/search_notes called directly (unit-level) ===")
            from backend.interactions.groups import GroupsManager
            gm = GroupsManager(user_id=uid_a, group_id=group_id)
            direct_fetch = gm.fetch_notes()["notes"]
            direct_note_a = find_note(direct_fetch, uname_a, note_with_verses)
            direct_note_b = find_note(direct_fetch, uname_b, note_no_verses)
            check("GroupsManager.fetch_notes: note with verses -> correct ordered triples",
                  direct_note_a is not None and direct_note_a.get("verses") == [["Numbers", "1", "9"], ["Numbers", "1", "10"], ["Numbers", "1", "11"]],
                  str(direct_note_a))
            check("GroupsManager.fetch_notes: note with no verses -> []",
                  direct_note_b is not None and direct_note_b.get("verses") == [],
                  str(direct_note_b))

            direct_search = gm.search_notes("numbers")["notes"]
            direct_snote_a = find_note(direct_search, uname_a, note_with_verses)
            check("GroupsManager.search_notes: note with verses -> correct ordered triples",
                  direct_snote_a is not None and direct_snote_a.get("verses") == [["Numbers", "1", "9"], ["Numbers", "1", "10"], ["Numbers", "1", "11"]],
                  str(direct_snote_a))

            print("\n=== 5. Regression guard: profile_photo_url (task 20260905) still present alongside verses ===")
            check("profile_photo_url key is still present on a note (key exists, may be None with no photo set)",
                  "profile_photo_url" in (note_a or {}) and "profile_photo_url" in (note_b or {}),
                  str((note_a, note_b)))

            print("\n=== 6. Paginated second page also carries verses ===")
            extra_ids = [
                seed_note(uid_a, group_id=group_id, title=f"filler {i}", text="x")
                for i in range(15)
            ]
            r1 = client.get(f"/groups/{uid_a}/{group_id}/notes", headers=cookie_header(token_a))
            page1 = r1.json()
            check("first page has_more is True with 15+ extra notes seeded", page1.get("has_more") is True, str(page1.get("has_more")))
            r2 = client.get(
                f"/groups/{uid_a}/{group_id}/notes",
                params={
                    "cursor_created_at": page1["next_cursor_created_at"],
                    "cursor_id": page1["next_cursor_id"],
                },
                headers=cookie_header(token_a),
            )
            check("second page -> 200", r2.status_code == 200, f"{r2.status_code} {r2.text}")
            page2_notes = r2.json().get("notes", {})
            page2_note_a = find_note(page2_notes, uname_a, note_with_verses) or find_note(page2_notes, uname_b, note_no_verses)
            # note_with_verses/note_no_verses are the oldest two group notes seeded, so they land
            # on the second (older) page once 15 newer filler notes push them off page one.
            second_page_target = find_note(page2_notes, uname_a, note_with_verses)
            check("second (paginated) page still carries the correct verses for an older note",
                  second_page_target is not None and second_page_target.get("verses") == [["Numbers", "1", "9"], ["Numbers", "1", "10"], ["Numbers", "1", "11"]],
                  str((second_page_target, list(page2_notes.keys()))))

            gm.close()

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
