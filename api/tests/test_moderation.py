"""Tests for App Store Guideline 1.2 (User-Generated Content) compliance:
EULA gate, content filter, report/flag, block, and the admin moderation CLI.

Stubs the outbound email send (external third-party API, not the database)
so this runs without live AWS credentials, matching the existing MFA/
password-reset test pattern.

Run with: cd api && ../.venv/bin/python tests/test_moderation.py
"""
import os
import time
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
from backend.moderation import content_filter  # noqa: E402
from db import DBManager  # noqa: E402

# A single, reusable genuinely-explicit marker term (from the real
# _EXPLICIT_TERMS wordlist) used throughout the "still blocked" cases below,
# so the DB-not-persisted checks can grep for one known needle.
EXPLICIT_MARKER = "blowjob"
assert EXPLICIT_MARKER in content_filter._EXPLICIT_TERMS, "test fixture drifted from the real wordlist"

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


def _fails_closed_to_strictest_tier() -> bool:
    """True if content_filter._active_terms() falls back to the strictest
    known severity tier when CONTENT_FILTER_SEVERITY holds an unrecognized
    value -- proving misconfiguration can't silently load an empty
    (permissive, effectively allow-everything) wordlist."""
    original = content_filter.CONTENT_FILTER_SEVERITY
    content_filter.CONTENT_FILTER_SEVERITY = "not-a-real-tier"
    try:
        return content_filter._active_terms() == content_filter._SEVERITY_TIERS[content_filter._FAIL_CLOSED_SEVERITY]
    finally:
        content_filter.CONTENT_FILTER_SEVERITY = original


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

        print("\n=== 2. Content filter -- severity-graded, app-wide (2026-08 relaxation) ===")
        # Policy (see content_filter.py docstring): ordinary profanity is now
        # ALLOWED everywhere check_clean() is used; only genuinely explicit
        # content (explicit sexual acts, sexual exploitation, hateful slurs)
        # is hard-rejected. This replaces the old "any profanity = reject"
        # all-or-nothing policy the tests below used to assume.
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

        print("\n--- 2a. Mild/borderline language is now allowed (new severity boundary, lower edge) ---")
        rn_mild = client.post(
            f"/notes/{uid3}",
            json={"user": uid3, "title": "fuck this chapter is dense", "text": "damn, hell, this ass of a translation is hard to parse"},
            cookies=cookies3,
        )
        check(
            "note with ordinary profanity (fuck/damn/hell/ass) allowed under relaxed policy -> 201, not 422",
            rn_mild.status_code == 201,
            str(rn_mild.status_code) + " " + str(rn_mild.text),
        )

        rg_mild = client.post(f"/groups/{uid3}", json={"group_id": str(uuid.uuid4()), "title": "shit group", "users": [uid3]}, cookies=cookies3)
        check(
            "group title with ordinary profanity (shit) allowed under relaxed policy -> 201, not 422",
            rg_mild.status_code == 201,
            str(rg_mild.status_code) + " " + str(rg_mild.text),
        )
        mild_group_id = rg_mild.json().get("group_id") if rg_mild.status_code == 201 else None

        rr_reply_mild = client.post(
            f"/notes/reply/{rn_clean.json()['id']}",
            json={"user": uid3, "title": "reply", "text": "damn, that's a good point"},
            cookies=cookies3,
        )
        check(
            "reply with mild profanity allowed under relaxed policy -> 201, not 422",
            rr_reply_mild.status_code == 201,
            str(rr_reply_mild.status_code) + " " + str(rr_reply_mild.text),
        )

        devo_mild_payload = {
            "devotion_id": str(uuid.uuid4()), "user_id": uid3,
            "devotion": {
                "id": str(uuid.uuid4()), "title": "damn, this study is hard", "creator_id": uid3,
                "prompts": ["what does this hell/damn passage mean to you?"],
            },
        }
        rdevo_mild = client.post("/devotions/", json=devo_mild_payload, cookies=cookies3)
        check(
            "devotion with mild profanity allowed app-wide -> 201, not 422",
            rdevo_mild.status_code == 201,
            str(rdevo_mild.status_code) + " " + str(rdevo_mild.text),
        )
        # No manual cleanup needed: DELETE /user/{uid3} at the end of this
        # test nulls devotions.creator_id (and from_user on any messages
        # sent below) before removing the user row -- see main.py's
        # delete_user docstring.

        print("\n--- 2b. Genuinely explicit content is still hard-rejected everywhere (upper edge, app-wide) ---")
        rn_explicit_title = client.post(
            f"/notes/{uid3}",
            json={"user": uid3, "title": f"note about {EXPLICIT_MARKER}", "text": "irrelevant"},
            cookies=cookies3,
        )
        check("note title with genuinely explicit content still rejected -> 422", rn_explicit_title.status_code == 422, str(rn_explicit_title.status_code))
        detail_title = rn_explicit_title.json().get("detail", "") if rn_explicit_title.status_code == 422 else ""
        check(
            "422 detail pinpoints the specific flagged content and names the field ('title')",
            EXPLICIT_MARKER in detail_title and "title" in detail_title,
            detail_title,
        )
        check(
            "422 detail keeps a warm, on-brand tone (mentions FellowScript, not the old clinical boilerplate)",
            "FellowScript" in detail_title and "isn't allowed under our community guidelines" not in detail_title,
            detail_title,
        )

        rn_explicit_text = client.post(
            f"/notes/{uid3}",
            json={"user": uid3, "title": "fine title", "text": f"this note is about {EXPLICIT_MARKER} and nothing else"},
            cookies=cookies3,
        )
        check("note text (not just title) with explicit content rejected -> 422", rn_explicit_text.status_code == 422, str(rn_explicit_text.status_code))
        detail_text = rn_explicit_text.json().get("detail", "") if rn_explicit_text.status_code == 422 else ""
        check("422 detail names the 'text' field, not 'title', when text is what's flagged", "text" in detail_text and EXPLICIT_MARKER in detail_text, detail_text)
        check("rejected explicit note response carries no note id (never created)", "id" not in rn_explicit_text.json(), rn_explicit_text.json())

        db_check = DBManager()
        db_check.cur.execute("SELECT 1 FROM notes WHERE text LIKE %s", (f"%{EXPLICIT_MARKER}%",))
        check("rejected explicit note is never persisted to the notes table", db_check.cur.fetchone() is None)
        db_check.close()

        rr_reply_explicit = client.post(
            f"/notes/reply/{rn_clean.json()['id']}",
            json={"user": uid3, "title": "reply", "text": f"{EXPLICIT_MARKER} content in a reply"},
            cookies=cookies3,
        )
        check("reply with explicit content rejected -> 422", rr_reply_explicit.status_code == 422, str(rr_reply_explicit.status_code))

        ru_explicit = client.put(
            f"/notes/{uid3}",
            params={"note_id": rn_clean.json()["id"]},
            json={"user": uid3, "title": "fine", "text": f"edited to include {EXPLICIT_MARKER}"},
            cookies=cookies3,
        )
        check("note update (PUT) with explicit content rejected -> 422", ru_explicit.status_code == 422, str(ru_explicit.status_code) + " " + str(ru_explicit.text))
        r_after_edit = client.get(f"/notes/{uid3}", cookies=cookies3)
        check(
            "note update rejection did not persist the explicit edit",
            EXPLICIT_MARKER not in str(r_after_edit.json()["notes"].get(rn_clean.json()["id"], {}).get("text", "")),
            r_after_edit.text,
        )

        rg_explicit = client.post(f"/groups/{uid3}", json={"group_id": str(uuid.uuid4()), "title": f"{EXPLICIT_MARKER} group", "users": [uid3]}, cookies=cookies3)
        check("group title with explicit content rejected -> 422", rg_explicit.status_code == 422, str(rg_explicit.status_code))

        if mild_group_id:
            rg_update_explicit = client.put(
                f"/groups/{uid3}/{mild_group_id}",
                json={"group_id": mild_group_id, "title": f"{EXPLICIT_MARKER} update", "users": [uid3]},
                cookies=cookies3,
            )
            check("group update (PUT) with explicit content rejected -> 422", rg_update_explicit.status_code == 422, str(rg_update_explicit.status_code))

        devo_explicit_payload = {
            "devotion_id": str(uuid.uuid4()), "user_id": uid3,
            "devotion": {"id": str(uuid.uuid4()), "title": f"{EXPLICIT_MARKER} study", "creator_id": uid3},
        }
        rdevo_explicit = client.post("/devotions/", json=devo_explicit_payload, cookies=cookies3)
        check("devotion with explicit title rejected -> 422", rdevo_explicit.status_code == 422, str(rdevo_explicit.status_code))

        print("\n--- 2c. Ambiguous input fails closed (Security Posture Q14) ---")
        # The wordlist match has no free-text disambiguation -- a hit fires
        # even in an innocuous, non-sexual context, so the system errs toward
        # rejection rather than guessing intent from surrounding words.
        rn_ambiguous = client.post(
            f"/notes/{uid3}",
            json={"user": uid3, "title": "doctor visit", "text": "Had an anal exam at the doctor today, all clear."},
            cookies=cookies3,
        )
        check(
            "ambiguous/non-sexual usage of an explicit-tier term still fails closed (rejected) -> 422",
            rn_ambiguous.status_code == 422,
            str(rn_ambiguous.status_code) + " " + str(rn_ambiguous.text),
        )

        print("\n--- 2d. Chat (websocket) shares the same relaxed-but-still-blocking policy ---")
        cookie_hdr = {"cookie": f"session={r3.cookies.get('session')}"}
        with client.websocket_connect(f"/message/ws/{uid3}", headers=cookie_hdr) as ws:
            ws.send_json({
                "to_users": [uid3],
                "text": f"chat message with {EXPLICIT_MARKER} in it",
                "group_id": None,
                "timestamp": "2026-08-30T00:00:00Z",
            })
            frame = ws.receive_json()
            check("explicit chat message gets an error frame back on the sender's own socket", frame.get("type") == "error", frame)
            check("error frame reason identifies a moderation rejection", frame.get("reason") == "message_rejected", frame)
            check(
                "chat rejection detail also pinpoints the flagged content, same warm shape as HTTP routes",
                EXPLICIT_MARKER in frame.get("detail", "") and "FellowScript" in frame.get("detail", ""),
                frame,
            )

            chat_marker = f"chat-mild-{uuid.uuid4().hex[:8]}"
            ws.send_json({
                "to_users": [uid3],
                "text": f"damn, {chat_marker}",
                "group_id": None,
                "timestamp": "2026-08-30T00:00:01Z",
            })
            # No live-delivery frame to read for the mild case (send_msg only
            # messages *other* recipients, and the sender is the sole
            # recipient here) -- assert via the persisted row instead, same
            # DB-is-truth approach test_websocket_from_user_spoofing.py uses
            # for this reason. Sleep while the socket is still open/
            # registered so the server-side coroutine has time to process
            # and persist the frame before the connection tears down.
            time.sleep(0.3)

        db_chat = DBManager()
        db_chat.cur.execute("SELECT 1 FROM messages WHERE text LIKE %s", (f"%{chat_marker}%",))
        check("chat message with mild profanity is allowed and persisted, not silently dropped", db_chat.cur.fetchone() is not None)
        db_chat.cur.execute("SELECT 1 FROM messages WHERE text LIKE %s", (f"%{EXPLICIT_MARKER}%",))
        check("rejected explicit chat message is never persisted", db_chat.cur.fetchone() is None)
        db_chat.close()

        print("\n=== 2e. Unit-level: check_clean/ContentRejected/rejection_message + fail-closed tier selection ===")
        check("check_clean allows mild profanity across several ordinary swear words (no exception raised)",
              content_filter.check_clean(text="damn, hell, shit, ass, bastard, bitch") is None)

        try:
            content_filter.check_clean(title="bad", text=f"contains {EXPLICIT_MARKER} explicitly")
            check("check_clean raises ContentRejected for explicit content", False, "no exception raised")
        except content_filter.ContentRejected as e:
            check("ContentRejected.field names the offending field", e.field == "text", e.field)
            check("ContentRejected.matched carries the specific flagged span", e.matched == EXPLICIT_MARKER, e.matched)
            msg = content_filter.rejection_message(e)
            check("rejection_message() quotes the matched span", f'"{EXPLICIT_MARKER}"' in msg, msg)
            check("rejection_message() names the field", "text" in msg, msg)
            check("rejection_message() reads warm/on-brand, not clinical", "FellowScript" in msg and "isn't allowed under our community guidelines" not in msg, msg)

        # Multi-word explicit terms: _flagged_span best-effort-isolates a
        # single word rather than misfiring or crashing on the word-count
        # mismatch between the original and censored text.
        try:
            content_filter.check_clean(text="they filmed a gang bang video")
            check("multi-word explicit term ('gang bang') still triggers rejection", False, "no exception raised")
        except content_filter.ContentRejected as e:
            check("multi-word match still yields a non-empty, usable matched span", bool(e.matched.strip()), repr(e.matched))

        check(
            "an unrecognized/misconfigured CONTENT_FILTER_SEVERITY fails closed to the strictest known tier, "
            "not an empty/permissive list",
            _fails_closed_to_strictest_tier(),
        )

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
