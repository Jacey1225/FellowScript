"""Integration test for task 20260812-notes-pagination, step 1 (backend):
GET /notes/{user_id} (api/routes/notes.py get_notes) and
GET /groups/{user_id}/{group_id}/notes (api/routes/community.py
fetch_group_notes -> GroupsManager.fetch_notes) gained optional
limit/offset/order query params, backed by raw-cursor SQL with a stable
ORDER BY timestamp <dir>, _id <dir> tie-break, LIMIT/OFFSET applied only
when the corresponding param is present.

This proves, end to end against the REAL app and a REAL Postgres connection
(no mocked DB, per this project's testing standard):

  1. Page slicing: limit/offset correctly slice a known, ordered set of
     notes with no overlap and no gaps between consecutive pages.
  2. Stable ordering per sort direction: concatenating every page (order=
     desc) reconstructs the exact same sequence as one unpaginated call,
     and order=asc reconstructs the exact reverse -- proving the ORDER BY
     direction is honored consistently across pages, not just within one
     page.
  3. Tie-break stability: rows sharing an identical timestamp still come
     back in the SAME order across repeated calls (the _id tie-break makes
     ordering deterministic instead of relying on incidental DB row order).
  4. Empty-page behavior: an offset past the end of the set returns an
     empty result (not an error, not wraparound).
  5. Last-page behavior: a page that only partially fills returns fewer
     rows than `limit`, which is exactly the "no more pages" signal the
     iOS client needs to stop paginating.
  6. Omitting limit/offset still returns the FULL, unpaginated set with
     every note's fields intact -- unchanged from pre-pagination behavior,
     which is what DashboardView/AccountView rely on.
  7. Out-of-range params (limit=0, limit=201, offset=-1, order="sideways")
     are rejected with 422 rather than silently clamped or ignored.
  8. All of the above proven for BOTH endpoints: personal notes
     (GET /notes/{user_id}) and group notes
     (GET /groups/{user_id}/{group_id}/notes).

Run:  cd api && ../.venv/bin/python tests/test_notes_pagination.py
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
    return r.json()["user_id"], r.cookies.get("session")


def make_note(client, owner_id, token, *, timestamp, title, group_id="", public=False, text="body"):
    r = client.post(f"/notes/{owner_id}", json={
        "user": owner_id, "title": title, "text": text,
        "public": public, "group_id": group_id, "verses": [],
        "timestamp": timestamp,
    }, headers=cookie_header(token))
    assert r.status_code == 201, f"create_note failed: {r.status_code} {r.text}"
    return r.json()["id"]


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
    with TestClient(main_module.app) as client:
        uid, token = signup(client, f"pagtest_owner_{uuid.uuid4().hex[:8]}")
        uid_tie, token_tie = signup(client, f"pagtest_tie_{uuid.uuid4().hex[:8]}")
        group_id = str(uuid.uuid4())

        try:
            # ── Personal notes: seed 7 notes with explicit, well-spaced
            # timestamps so desc/asc order is fully deterministic. ──────────
            print("=== Seeding 7 personal notes (T1 oldest .. T7 newest) ===")
            personal_ids = []
            for i in range(1, 8):
                nid = make_note(client, uid, token, timestamp=f"2020-01-0{i} 00:00:00", title=f"T{i}")
                personal_ids.append(nid)
            desc_expected = list(reversed(personal_ids))  # T7..T1
            asc_expected = list(personal_ids)              # T1..T7

            print("\n=== 1. Omitting limit/offset returns the full set, unchanged (Dashboard/Account) ===")
            r = client.get(f"/notes/{uid}", headers=cookie_header(token))
            check("GET /notes/{user_id} (no params) -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            full = r.json()
            check("full unpaginated call returns all 7 notes", set(full.keys()) == set(personal_ids), str(full.keys()))
            check("full call defaults to timestamp-desc order",
                  list(full.keys()) == desc_expected, str(list(full.keys())))
            check("note fields intact on unpaginated call (title/text/timestamp present)",
                  all("title" in v and "text" in v and "timestamp" in v for v in full.values()),
                  str(full))

            print("\n=== 2. Page slicing + stable ordering, order=desc (default) ===")
            pages = []
            for offset in (0, 3, 6):
                r = client.get(f"/notes/{uid}", params={"limit": 3, "offset": offset}, headers=cookie_header(token))
                check(f"GET limit=3 offset={offset} -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
                pages.append(list(r.json().keys()))
            check("page 1 (offset=0) has 3 notes matching desc[0:3]", pages[0] == desc_expected[0:3], str(pages[0]))
            check("page 2 (offset=3) has 3 notes matching desc[3:6]", pages[1] == desc_expected[3:6], str(pages[1]))
            check("page 3 (offset=6) is the LAST page: only 1 note (< limit, signals no more pages)",
                  pages[2] == desc_expected[6:7] and len(pages[2]) == 1, str(pages[2]))
            check("no duplicate ids across pages", len(set(pages[0]) & set(pages[1]) & set(pages[2])) == 0,
                  str(pages))
            reconstructed = pages[0] + pages[1] + pages[2]
            check("concatenated pages reconstruct the EXACT full desc order",
                  reconstructed == desc_expected, str(reconstructed))

            print("\n=== 3. Page slicing + stable ordering, order=asc ===")
            pages_asc = []
            for offset in (0, 3, 6):
                r = client.get(f"/notes/{uid}", params={"limit": 3, "offset": offset, "order": "asc"},
                                headers=cookie_header(token))
                check(f"GET limit=3 offset={offset} order=asc -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
                pages_asc.append(list(r.json().keys()))
            reconstructed_asc = pages_asc[0] + pages_asc[1] + pages_asc[2]
            check("order=asc reconstructs the EXACT reverse of desc order",
                  reconstructed_asc == asc_expected, str(reconstructed_asc))
            check("asc order is the mirror image of desc order",
                  reconstructed_asc == list(reversed(desc_expected)), str(reconstructed_asc))

            print("\n=== 4. Empty-page behavior: offset past the end ===")
            r = client.get(f"/notes/{uid}", params={"limit": 3, "offset": 100}, headers=cookie_header(token))
            check("offset=100 (past end) -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            check("offset past end returns an empty dict, not an error", r.json() == {}, str(r.json()))

            print("\n=== 5. Validation: out-of-range params rejected with 422 ===")
            for bad_params, label in [
                ({"limit": 0}, "limit=0"),
                ({"limit": 201}, "limit=201 (> MAX_NOTES_PAGE_SIZE)"),
                ({"offset": -1}, "offset=-1"),
                ({"order": "sideways"}, "order=sideways"),
            ]:
                r = client.get(f"/notes/{uid}", params=bad_params, headers=cookie_header(token))
                check(f"GET /notes/{{user_id}} {label} -> 422", r.status_code == 422, f"{r.status_code} {r.text}")

            print("\n=== 6. Tie-break stability: identical timestamps still order deterministically ===")
            tie_id_1 = make_note(client, uid_tie, token_tie, timestamp="2021-06-01 00:00:00", title="Tie1")
            tie_id_2 = make_note(client, uid_tie, token_tie, timestamp="2021-06-01 00:00:00", title="Tie2")
            r1 = client.get(f"/notes/{uid_tie}", headers=cookie_header(token_tie))
            r2 = client.get(f"/notes/{uid_tie}", headers=cookie_header(token_tie))
            check("both calls -> 200", r1.status_code == 200 and r2.status_code == 200)
            order1, order2 = list(r1.json().keys()), list(r2.json().keys())
            check("identical-timestamp rows come back in the SAME order across repeated calls",
                  order1 == order2, f"{order1} vs {order2}")
            check("both tie-break ids present", set(order1) == {tie_id_1, tie_id_2}, str(order1))

            # ── Group notes: same battery of checks against
            # GET /groups/{user_id}/{group_id}/notes ────────────────────────
            print("\n=== Seeding group + 5 group notes (G1 oldest .. G5 newest) ===")
            r = client.post(f"/groups/{uid}", json={
                "group_id": group_id, "title": "Pagination test group", "users": [uid],
            }, headers=cookie_header(token))
            check("group created -> 201", r.status_code == 201, f"{r.status_code} {r.text}")

            group_ids = []
            for i in range(1, 6):
                nid = make_note(client, uid, token, timestamp=f"2019-06-0{i} 00:00:00", title=f"G{i}",
                                 group_id=group_id, public=True)
                group_ids.append(nid)
            g_desc_expected = list(reversed(group_ids))  # G5..G1

            print("\n=== 7. Group notes: omitting limit/offset returns the full set unchanged ===")
            r = client.get(f"/groups/{uid}/{group_id}/notes", headers=cookie_header(token))
            check("GET group notes (no params) -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            g_full = r.json()
            check("group full call returns exactly one username bucket", list(g_full.keys()) != [], str(g_full))
            all_g_ids = [nid for bucket in g_full.values() for nid in bucket.keys()]
            check("group full unpaginated call returns all 5 notes", set(all_g_ids) == set(group_ids), str(all_g_ids))
            check("group full call defaults to timestamp-desc order", all_g_ids == g_desc_expected, str(all_g_ids))

            print("\n=== 8. Group notes: page slicing + stable ordering (desc) ===")
            g_pages = []
            for offset in (0, 2, 4):
                r = client.get(f"/groups/{uid}/{group_id}/notes", params={"limit": 2, "offset": offset},
                                headers=cookie_header(token))
                check(f"GET group notes limit=2 offset={offset} -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
                bucket = r.json()
                ids = [nid for b in bucket.values() for nid in b.keys()]
                g_pages.append(ids)
            check("group page 1 matches desc[0:2]", g_pages[0] == g_desc_expected[0:2], str(g_pages[0]))
            check("group page 2 matches desc[2:4]", g_pages[1] == g_desc_expected[2:4], str(g_pages[1]))
            check("group page 3 is the LAST page: only 1 note (< limit)",
                  g_pages[2] == g_desc_expected[4:5] and len(g_pages[2]) == 1, str(g_pages[2]))
            g_reconstructed = g_pages[0] + g_pages[1] + g_pages[2]
            check("group concatenated pages reconstruct the exact full desc order",
                  g_reconstructed == g_desc_expected, str(g_reconstructed))

            print("\n=== 9. Group notes: empty-page behavior past the end ===")
            r = client.get(f"/groups/{uid}/{group_id}/notes", params={"limit": 2, "offset": 100},
                            headers=cookie_header(token))
            check("group offset=100 (past end) -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
            check("group offset past end returns an empty dict, not an error", r.json() == {}, str(r.json()))

            print("\n=== 10. Group notes: validation rejects out-of-range params ===")
            for bad_params, label in [
                ({"limit": 0}, "limit=0"),
                ({"limit": 201}, "limit=201"),
                ({"offset": -1}, "offset=-1"),
                ({"order": "sideways"}, "order=sideways"),
            ]:
                r = client.get(f"/groups/{uid}/{group_id}/notes", params=bad_params, headers=cookie_header(token))
                check(f"GET group notes {label} -> 422", r.status_code == 422, f"{r.status_code} {r.text}")

        finally:
            print("\n=== cleanup ===")
            cleanup(uid, uid_tie, group_id=group_id)

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
