"""Tests for task 20260817-notes-pagination-backend: keyset/cursor pagination
on GET /notes/{user_id} and GET /{user_id}/{group_id}/notes, replacing both
the never-shipped OFFSET-based attempt (feature/notes-pagination, 264b4779)
and any client-side "load everything then slice" behavior.

This proves the specific properties the architecture decision called for --
not a generic smoke test:

  1. Both endpoints cap every response at NOTES_PAGE_SIZE (15) via the SQL
     query itself (LIMIT), in stable (created_at DESC, _id DESC) order.
  2. Keyset pagination is drift-proof: deleting a note that was already
     returned on page 1, and inserting a brand-new note, between fetching
     page 1 and page 2 causes NEITHER a duplicate NOR a skipped note on
     page 2 -- the exact class of bug OFFSET pagination is vulnerable to
     (a shifted row position silently re-serving or skipping a row).
  3. has_more is True iff exactly NOTES_PAGE_SIZE rows came back, including
     the documented edge case where the true end of the list lands on an
     exactly-full page (has_more True there; the following empty page then
     reports has_more False) -- and the true-end case where the last page is
     short (has_more False immediately, no extra round trip needed).
  4. Group notes: a blocked user's notes are excluded in the SQL WHERE
     clause itself, not filtered post-fetch in Python -- so a full page of
     15 visible notes is still 15 rows even when a blocked member has notes
     interleaved in the same group.
  5. GET /notes/{user_id}/count returns an accurate, unpaginated total (SQL
     COUNT(*)) matching what AccountView.noteCount now relies on instead of
     paging through the whole (now-capped) collection.

Note: note creation in these tests goes directly through the DB (seed_note),
not POST /notes/{user_id}, because that endpoint is gated by the (unrelated,
out-of-scope for this task) free-tier weekly notes-creation limit -- these
tests need >10 notes per user to exercise a 15-per-page cap, which check_limit
would otherwise block. Signups are also kept to the minimum distinct users
(reused across sections) to stay under the /signup rate limit (5/minute).

Run with: cd api && ../.venv/bin/python tests/test_notes_pagination.py
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


def seed_note(user_id, *, public=False, group_id=None, is_reply=False, parent_note_id=None, title="T", text="B"):
    """Inserts a note directly at the DB layer, bypassing the free-tier
    weekly notes-creation limit (check_limit) -- an unrelated concept from
    the pagination page-size cap this task adds, and not something these
    tests should be constrained by when they need to seed >10 notes to
    exercise a 15-per-page cap. Mirrors exactly the columns create_note
    writes (api/routes/notes.py)."""
    note_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("notes", {
            "_id": note_id, "user_id": user_id, "title": title, "text": text,
            "public": public, "group_id": group_id, "is_reply": is_reply,
            "parent_note_id": parent_note_id,
        })
    finally:
        db.close()
    return note_id


def delete_note_direct(user_id, note_id):
    """Delete a note directly at the DB layer to simulate a concurrent
    deletion between two page fetches (no HTTP delete-by-id-alone route)."""
    db = DBManager()
    try:
        db.cur.execute("DELETE FROM notes WHERE _id = %s AND user_id = %s", (note_id, user_id))
        db.conn.commit()
    finally:
        db.close()


def clear_notes(*user_ids):
    """Deletes only this user's notes, leaving the account itself intact so
    it can be reused across multiple pagination scenarios without burning
    more of the /signup rate limit (5/minute)."""
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


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

        # Only 3 distinct users for the whole file (well under the /signup
        # 5/minute rate limit), reused across scenarios.
        uid_p, token_p = signup(client, f"pgnotes_personal_{uuid.uuid4().hex[:8]}")
        uid_owner, token_owner = signup(client, f"pgnotes_gowner_{uuid.uuid4().hex[:8]}")
        uid_blocked, token_blocked = signup(client, f"pgnotes_gblocked_{uuid.uuid4().hex[:8]}")
        group_id = str(uuid.uuid4())

        try:
            # ══════════════════════════════════════════════════════════════
            # 1. Personal notes GET /notes/{user_id}: page size, ordering,
            #    has_more accuracy at both an exact-multiple and a short
            #    final page.
            # ══════════════════════════════════════════════════════════════
            print("=== 1. Personal notes: page size cap + ordering ===")
            note_ids = [seed_note(uid_p, title=f"note-{i}") for i in range(17)]

            r = client.get(f"/notes/{uid_p}", headers=cookie_header(token_p))
            check("first page -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)
            body = r.json()
            check("first page capped at 15 notes (SQL LIMIT, not client slice)",
                  len(body["notes"]) == 15, str(len(body["notes"])))
            check("first page has_more == True (17 notes exist, 15 returned)",
                  body["has_more"] is True, str(body))
            check("first page carries a next cursor", bool(body["next_cursor_created_at"]) and bool(body["next_cursor_id"]),
                  str(body.get("next_cursor_created_at")) + " " + str(body.get("next_cursor_id")))

            page1_ids = set(body["notes"].keys())

            r2 = client.get(
                f"/notes/{uid_p}"
                f"?cursor_created_at={body['next_cursor_created_at']}&cursor_id={body['next_cursor_id']}",
                headers=cookie_header(token_p),
            )
            check("second page -> 200", r2.status_code == 200, str(r2.status_code) + " " + r2.text)
            body2 = r2.json()
            check("second page has the remaining 2 notes", len(body2["notes"]) == 2, str(len(body2["notes"])))
            check("second page has_more == False (true end reached)", body2["has_more"] is False, str(body2))

            page2_ids = set(body2["notes"].keys())
            check("no duplicate notes across the two pages", page1_ids.isdisjoint(page2_ids),
                  str(page1_ids & page2_ids))
            check("every created note appears exactly once across both pages",
                  (page1_ids | page2_ids) == set(note_ids), str((page1_ids | page2_ids) ^ set(note_ids)))

            clear_notes(uid_p)

            # ══════════════════════════════════════════════════════════════
            # 2. has_more edge case: exact-multiple end (15 total).
            # ══════════════════════════════════════════════════════════════
            print("\n=== 2. has_more edge case: exact-multiple end (15 total) ===")
            exact_ids = [seed_note(uid_p, title=f"e-{i}") for i in range(15)]
            r = client.get(f"/notes/{uid_p}", headers=cookie_header(token_p))
            b = r.json()
            check("exactly-15-notes first page returns all 15", len(b["notes"]) == 15, str(len(b["notes"])))
            check("has_more True on the exact-multiple page (documented trade-off: one more empty round trip needed)",
                  b["has_more"] is True, str(b))
            r2 = client.get(
                f"/notes/{uid_p}?cursor_created_at={b['next_cursor_created_at']}&cursor_id={b['next_cursor_id']}",
                headers=cookie_header(token_p),
            )
            b2 = r2.json()
            check("following page is empty", len(b2["notes"]) == 0, str(b2))
            check("has_more now False -- client correctly stops here", b2["has_more"] is False, str(b2))
            check("no exact-15 note lost between the full page and the empty confirmation page",
                  set(b["notes"].keys()) == set(exact_ids), str(set(b["notes"].keys()) ^ set(exact_ids)))
            clear_notes(uid_p)

            # ══════════════════════════════════════════════════════════════
            # 3. has_more true-end case: short final page (< 15 total).
            # ══════════════════════════════════════════════════════════════
            print("\n=== 3. has_more true-end case: short final page (< 15 total), no extra round trip ===")
            short_ids = [seed_note(uid_p, title=f"s-{i}") for i in range(4)]
            r = client.get(f"/notes/{uid_p}", headers=cookie_header(token_p))
            b = r.json()
            check("short first page returns all 4", len(b["notes"]) == 4, str(len(b["notes"])))
            check("has_more False immediately -- no phantom next page", b["has_more"] is False, str(b))
            check("all 4 short-page notes present", set(b["notes"].keys()) == set(short_ids),
                  str(set(b["notes"].keys()) ^ set(short_ids)))
            clear_notes(uid_p)

            # ══════════════════════════════════════════════════════════════
            # 4. The core architectural property: keyset pagination survives
            #    a delete (of an already-seen row) and an insert happening
            #    between page 1 and page 2 -- no duplicate, no skip. This is
            #    the exact drift scenario OFFSET pagination is broken under.
            # ══════════════════════════════════════════════════════════════
            print("\n=== 4. Drift resistance: delete + insert between page loads ===")
            drift_ids = [seed_note(uid_p, title=f"d-{i}") for i in range(20)]

            r1 = client.get(f"/notes/{uid_p}", headers=cookie_header(token_p))
            b1 = r1.json()
            check("drift setup: page 1 returns 15", len(b1["notes"]) == 15, str(len(b1["notes"])))
            drift_page1_ids = set(b1["notes"].keys())

            # Simulate another request/user deleting a note that page 1
            # already returned (an "already seen" row) ...
            already_seen_to_delete = next(iter(drift_page1_ids))
            delete_note_direct(uid_p, already_seen_to_delete)
            # ... and a brand-new note being created concurrently. Its
            # created_at is newer than every existing note, so it sorts
            # ahead of the cursor and must NOT reappear on page 2.
            new_note_id = seed_note(uid_p, title="d-new-concurrent")

            r2 = client.get(
                f"/notes/{uid_p}"
                f"?cursor_created_at={b1['next_cursor_created_at']}&cursor_id={b1['next_cursor_id']}",
                headers=cookie_header(token_p),
            )
            b2 = r2.json()
            drift_page2_ids = set(b2["notes"].keys())

            check("page 2 has no duplicate of any page-1 note (no re-serve from a shifted position)",
                  drift_page1_ids.isdisjoint(drift_page2_ids), str(drift_page1_ids & drift_page2_ids))
            check("the newly-inserted (newer) note does not leak into page 2",
                  new_note_id not in drift_page2_ids, str(drift_page2_ids))
            # The 20 originals minus the one we deleted = 19 notes must still
            # be findable across page 1 + page 2 with no skips.
            remaining_originals = set(drift_ids) - {already_seen_to_delete}
            found = (drift_page1_ids | drift_page2_ids) & remaining_originals
            check("no note is skipped: every surviving original note appears in page 1 or page 2",
                  found == remaining_originals, str(remaining_originals - found))
            clear_notes(uid_p)

            # ══════════════════════════════════════════════════════════════
            # 6. GET /notes/{user_id}/count -- accurate, unpaginated total.
            # ══════════════════════════════════════════════════════════════
            print("\n=== 6. Count endpoint accuracy (AccountView/DashboardView summary path) ===")
            group_id_c = str(uuid.uuid4())
            try:
                for i in range(23):
                    seed_note(uid_p, title=f"c-{i}")

                r = client.post(f"/groups/{uid_p}", json={
                    "group_id": group_id_c, "title": "Count-test group", "users": [uid_p],
                }, headers=cookie_header(token_p))
                check("count-test group created -> 201", r.status_code == 201, str(r.status_code))
                # Group notes and replies must NOT be counted by the personal count.
                group_note_id = seed_note(uid_p, public=True, group_id=group_id_c, title="group-note")
                seed_note(uid_p, is_reply=True, parent_note_id=group_note_id, title="Re", text="reply")

                r = client.get(f"/notes/{uid_p}/count", headers=cookie_header(token_p))
                check("count endpoint -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)
                check("count == 23 (personal, non-reply, non-group notes only -- excludes the group note and the reply)",
                      r.json().get("count") == 23, str(r.json()))

                # Cross-check against actually paging through everything.
                seen = set()
                cursor_c, cursor_id = None, None
                for _ in range(10):
                    qs = f"?cursor_created_at={cursor_c}&cursor_id={cursor_id}" if cursor_c else ""
                    pr = client.get(f"/notes/{uid_p}{qs}", headers=cookie_header(token_p))
                    pb = pr.json()
                    seen |= set(pb["notes"].keys())
                    if not pb["has_more"]:
                        break
                    cursor_c, cursor_id = pb["next_cursor_created_at"], pb["next_cursor_id"]
                check("count endpoint matches the number of notes actually reachable by paging through everything",
                      len(seen) == 23, f"count endpoint said 23, paging found {len(seen)}")
            finally:
                db = DBManager()
                try:
                    db.cur.execute("DELETE FROM groups WHERE _id = %s", (group_id_c,))
                    db.conn.commit()
                finally:
                    db.close()
                clear_notes(uid_p)

            # ══════════════════════════════════════════════════════════════
            # 5. Group notes GET /{user_id}/{group_id}/notes: blocked-user
            #    exclusion happens in SQL, not post-fetch -- so a full page
            #    is still `limit` VISIBLE notes even with a blocked member's
            #    notes interleaved in the same group.
            # ══════════════════════════════════════════════════════════════
            print("\n=== 5. Group notes: blocked-user exclusion at the SQL level ===")
            r = client.post(f"/groups/{uid_owner}", json={
                "group_id": group_id, "title": "Pagination test group",
                "users": [uid_owner, uid_blocked],
            }, headers=cookie_header(token_owner))
            check("group created -> 201", r.status_code == 201, str(r.status_code) + " " + r.text)

            r = client.post(f"/blocks/{uid_owner}/{uid_blocked}", headers=cookie_header(token_owner))
            check("owner blocks the other member -> 204", r.status_code == 204, str(r.status_code) + " " + r.text)

            owner_note_ids = [
                seed_note(uid_owner, public=True, group_id=group_id, title=f"go-{i}")
                for i in range(17)
            ]
            blocked_note_ids = [
                seed_note(uid_blocked, public=True, group_id=group_id, title=f"gb-{i}")
                for i in range(5)
            ]

            r = client.get(f"/groups/{uid_owner}/{group_id}/notes", headers=cookie_header(token_owner))
            check("group notes first page -> 200", r.status_code == 200, str(r.status_code) + " " + r.text)
            body = r.json()
            all_returned_ids_p1 = {nid for user_notes in body["notes"].values() for nid in user_notes}
            check("group notes first page capped at 15 VISIBLE notes despite 22 total rows",
                  len(all_returned_ids_p1) == 15, str(len(all_returned_ids_p1)))
            check("no note from the blocked user ever appears on page 1",
                  all_returned_ids_p1.isdisjoint(set(blocked_note_ids)),
                  str(all_returned_ids_p1 & set(blocked_note_ids)))

            r2 = client.get(
                f"/groups/{uid_owner}/{group_id}/notes"
                f"?cursor_created_at={body['next_cursor_created_at']}&cursor_id={body['next_cursor_id']}",
                headers=cookie_header(token_owner),
            )
            body2 = r2.json()
            all_returned_ids_p2 = {nid for user_notes in body2["notes"].values() for nid in user_notes}
            check("group notes second page has the remaining 2 visible notes",
                  len(all_returned_ids_p2) == 2, str(len(all_returned_ids_p2)))
            check("second page also excludes every blocked-user note",
                  all_returned_ids_p2.isdisjoint(set(blocked_note_ids)),
                  str(all_returned_ids_p2 & set(blocked_note_ids)))
            check("all 17 owner notes accounted for across both pages, none duplicated",
                  (all_returned_ids_p1 | all_returned_ids_p2) == set(owner_note_ids)
                  and all_returned_ids_p1.isdisjoint(all_returned_ids_p2),
                  str((all_returned_ids_p1 | all_returned_ids_p2) ^ set(owner_note_ids)))

            # ══════════════════════════════════════════════════════════════
            # 7. Security boundary regression guard: pagination params must
            #    not let a caller read another user's notes (unaffected by
            #    this task, but the query shape changed enough to be worth
            #    re-confirming). Reuses uid_owner/uid_blocked as A/B.
            # ══════════════════════════════════════════════════════════════
            print("\n=== 7. Security boundary: pagination cannot be used to read another user's notes ===")
            r = client.get(f"/notes/{uid_owner}", headers=cookie_header(token_blocked))
            check("uid_blocked requesting uid_owner's notes (even paginated) -> 403, not owner's data",
                  r.status_code == 403, str(r.status_code) + " " + r.text)

            r = client.get(f"/groups/{uid_blocked}/{group_id}/notes", headers=cookie_header(token_blocked))
            check("blocked-but-still-a-member can still read group notes (blocking hides content, not membership)",
                  r.status_code == 200, str(r.status_code) + " " + r.text)

        finally:
            print("\n=== cleanup ===")
            cleanup(uid_p, uid_owner, uid_blocked, group_id=group_id)

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
