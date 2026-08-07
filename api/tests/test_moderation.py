"""Tests for App Store Guideline 1.2 (User-Generated Content) compliance:
EULA gate, content filter, report/flag, block, and the admin moderation CLI.

Stubs the outbound email send (external third-party API, not the database)
so this runs without live AWS credentials, matching the existing MFA/
password-reset test pattern.

Run with: cd api && ../.venv/bin/python tests/test_moderation.py
"""
import os
import uuid

import _pathfix  # noqa: F401,E402

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
import main as main_module  # noqa: E402
import backend.interactions.reports as reports_mod  # noqa: E402
from backend.moderation import admin_actions  # noqa: E402
from db import DBManager  # noqa: E402

SENT_EMAILS = []
reports_mod.send_email = lambda to, subject, html, text: SENT_EMAILS.append((to, subject, html, text))

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def make_user(client, prefix, terms_accepted=True):
    uname = f"{prefix}_{uuid.uuid4().hex[:8]}"
    body = {"username": uname, "email": f"{uname}@example.com", "plain_pass": "TestPass123!"}
    if terms_accepted is not None:
        body["terms_accepted"] = terms_accepted
    r = client.post("/signup", json=body)
    return r, uname


def main():
    cleanup_uids = []
    with TestClient(main_module.app) as client:
        print("=== 1. EULA gate ===")
        r1, _ = make_user(client, "eula", terms_accepted=None)
        check("signup without terms_accepted -> 422", r1.status_code == 422, str(r1.status_code))

        r2, _ = make_user(client, "eula", terms_accepted=False)
        check("signup with terms_accepted=false -> 422", r2.status_code == 422, str(r2.status_code))

        r3, uname3 = make_user(client, "eula")
        check("signup with terms_accepted=true -> 201", r3.status_code == 201, str(r3.status_code))
        uid3 = r3.json()["user_id"]
        cleanup_uids.append((uid3, r3.cookies.get("session")))
        check("terms_version stamped server-side", bool(r3.json().get("terms_version")), str(r3.json()))

        print("\n=== 2. Content filter ===")
        cookies3 = {"session": r3.cookies.get("session")}
        rn_clean = client.post(f"/notes/{uid3}", json={"user": uid3, "title": "Genesis reflections", "text": "A wonderful passage."}, cookies=cookies3)
        check("clean note accepted", rn_clean.status_code == 201, str(rn_clean.status_code))

        rn_bible = client.post(
            f"/notes/{uid3}",
            json={
                "user": uid3,
                "title": "God's judgment on Sodom",
                "text": "Paul was told it is hard to kick against the pricks, and the donkey (ass) carried Mary into Bethlehem.",
            },
            cookies=cookies3,
        )
        check(
            "note with ordinary Bible vocabulary (God/Sodom/pricks/ass) not false-flagged",
            rn_bible.status_code == 201,
            str(rn_bible.status_code) + " " + str(rn_bible.text),
        )

        rn_dirty = client.post(f"/notes/{uid3}", json={"user": uid3, "title": "fuck this", "text": "whatever"}, cookies=cookies3)
        check("profane note title rejected -> 422", rn_dirty.status_code == 422, str(rn_dirty.status_code))

        rg_dirty = client.post(f"/groups/{uid3}", json={"group_id": str(uuid.uuid4()), "title": "shit group", "users": [uid3]}, cookies=cookies3)
        check("profane group title rejected -> 422", rg_dirty.status_code == 422, str(rg_dirty.status_code))

        print("\n=== 3. Report/flag mechanism ===")
        SENT_EMAILS.clear()
        note_id = rn_clean.json()["id"]
        rr1 = client.post("/reports/", json={"content_type": "note", "content_id": note_id, "reason": "harassment", "detail": "test"}, cookies=cookies3)
        check("report on own note -> 201", rr1.status_code == 201, str(rr1.status_code))
        check("report triggers a developer email", len(SENT_EMAILS) == 1, str(SENT_EMAILS))
        report_id = rr1.json()["id"]

        rr2 = client.post("/reports/", json={"content_type": "note", "reason": "x"}, cookies=cookies3)
        check("report missing content_id -> 422", rr2.status_code == 422, str(rr2.status_code))

        rr3 = client.post("/reports/", json={"content_type": "user", "reason": "x"}, cookies=cookies3)
        check("user-report missing reported_user_id -> 422", rr3.status_code == 422, str(rr3.status_code))

        db = DBManager()
        db.cur.execute("SELECT content_snippet FROM content_reports WHERE _id = %s", (report_id,))
        snippet = db.cur.fetchone()[0]
        db.close()
        check("report freezes the content snippet", "Genesis reflections" in snippet, snippet)

        print("\n=== 4. Block mechanism ===")
        r4, uname4 = make_user(client, "blk")
        uid4 = r4.json()["user_id"]
        cookies4 = {"session": r4.cookies.get("session")}
        cleanup_uids.append((uid4, r4.cookies.get("session")))

        client.post(f"/friends/{uid3}/request", params={"friend_username": uname4}, cookies=cookies3)
        client.post(f"/friends/{uid4}/add", params={"friend_username": uname3}, cookies=cookies4)
        check("friendship established", client.get(f"/friends/{uid3}/{uid4}", cookies=cookies3).status_code == 200)

        SENT_EMAILS.clear()
        rb = client.post(f"/blocks/{uid3}/{uid4}", cookies=cookies3)
        check("block -> 204", rb.status_code == 204, str(rb.status_code))
        check("blocking auto-files a report (developer notified)", len(SENT_EMAILS) == 1, str(SENT_EMAILS))

        check("friendship severed after block", client.get(f"/friends/{uid3}/{uid4}", cookies=cookies3).status_code == 404)

        r_readd = client.post(f"/friends/{uid4}/add", params={"friend_username": uname3}, cookies=cookies4)
        check("blocked user cannot re-add", r_readd.status_code == 404, str(r_readd.status_code))

        # A group note from the now-blocked uid4 must not appear in uid3's
        # group-notes fetch, even though both are still nominal group members.
        gid = str(uuid.uuid4())
        client.post(f"/groups/{uid3}", json={"group_id": gid, "title": "shared group", "users": [uid3, uid4]}, cookies=cookies3)
        rn_by_4 = client.post(
            f"/notes/{uid4}",
            json={"user": uid4, "title": "hidden note", "group_id": gid, "public": True, "text": "should not appear to blocker"},
            cookies=cookies4,
        )
        check("blocked user's group note created OK", rn_by_4.status_code == 201, str(rn_by_4.status_code))
        r_group_notes = client.get(f"/groups/{uid3}/{gid}/notes", cookies=cookies3)
        check(
            "blocked user's group note is excluded from the blocker's fetch",
            "hidden note" not in str(r_group_notes.json()),
            str(r_group_notes.json()),
        )

        r_list = client.get(f"/blocks/{uid3}", cookies=cookies3)
        check("blocked users list includes uid4", any(u["user_id"] == uid4 for u in r_list.json()), str(r_list.json()))

        ru = client.delete(f"/blocks/{uid3}/{uid4}", cookies=cookies3)
        check("unblock -> 204", ru.status_code == 204, str(ru.status_code))
        r_list2 = client.get(f"/blocks/{uid3}", cookies=cookies3)
        check("blocked list empty after unblock", r_list2.json() == [], str(r_list2.json()))

        print("\n=== 5. Admin moderation CLI (report -> resolve -> content gone, user ejected) ===")
        r5, uname5 = make_user(client, "eject")
        uid5 = r5.json()["user_id"]
        cookies5 = {"session": r5.cookies.get("session")}

        rn5 = client.post(f"/notes/{uid5}", json={"user": uid5, "title": "bad note", "text": "reported content"}, cookies=cookies5)
        note5_id = rn5.json()["id"]
        rr5 = client.post("/reports/", json={"content_type": "note", "content_id": note5_id, "reported_user_id": uid5, "reason": "harassment"}, cookies=cookies3)
        report5_id = rr5.json()["id"]

        admin_actions.resolve(report5_id, remove_content=True, eject=True, dismiss=False)

        db = DBManager()
        db.cur.execute("SELECT 1 FROM notes WHERE _id = %s", (note5_id,))
        check("reported note removed by admin CLI", db.cur.fetchone() is None)
        db.cur.execute("SELECT suspended_at FROM users WHERE _id = %s", (uid5,))
        check("reported user suspended", db.cur.fetchone()[0] is not None)
        db.cur.execute("SELECT status FROM content_reports WHERE _id = %s", (report5_id,))
        check("report marked actioned", db.cur.fetchone()[0] == "actioned")
        db.close()

        r_login5 = client.post("/login", json={"username": uname5, "plain_pass": "TestPass123!"})
        check("suspended user cannot log in -> 403", r_login5.status_code == 403, str(r_login5.status_code))

        # Dismiss path
        rn6 = client.post(f"/notes/{uid3}", json={"user": uid3, "title": "fine note", "text": "fine text"}, cookies=cookies3)
        rr6 = client.post("/reports/", json={"content_type": "note", "content_id": rn6.json()["id"], "reason": "other"}, cookies=cookies3)
        admin_actions.resolve(rr6.json()["id"], remove_content=False, eject=False, dismiss=True)
        db = DBManager()
        db.cur.execute("SELECT status FROM content_reports WHERE _id = %s", (rr6.json()["id"],))
        check("dismissed report marked dismissed, not actioned", db.cur.fetchone()[0] == "dismissed")
        db.cur.execute("SELECT 1 FROM notes WHERE _id = %s", (rn6.json()["id"],))
        check("dismissed report's content is NOT removed", db.cur.fetchone() is not None)
        db.close()

        for uid, token in cleanup_uids:
            client.delete(f"/user/{uid}", cookies={"session": token})

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
