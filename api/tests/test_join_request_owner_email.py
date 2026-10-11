"""Tests for task 20261011-join-requests-ios-email: owner email on a new join request.

Properties: flag join_request_email (off by default) gates it; one email per group per
window with its own claim (owner_emailed_at) independent of the push; no owner email,
suspended owner or mute -> no email and no claim; the body names only group title,
requester display name and note, escapes HTML, never carries the requester's email or id;
SES failure never raises or fails the request; logs carry no PII. Scratch DB only.
"""
import _pathfix  # noqa: F401

import asyncio
import time

import _jrq_common as J
from _jrq_common import check, make_listing, make_user, req, sql
from backend.email import ses_client
from backend.interactions import flags
from backend.interactions import join_request_notifier as N


def set_email_flag(owner, state):
    flags.set_flag("join_request_email", state, actor=owner)
    flags.invalidate()


def main():
    cli, cap = J.start()
    sent = []
    mode = {"fail": False}

    def fake_send(to, subject, html_body, text_body):
        if mode["fail"]:
            raise ses_client.EmailSendError("boom secret@example.com")
        sent.append((to, subject, html_body, text_body))

    real = ses_client.send_email
    ses_client.send_email = fake_send
    try:
        owner = make_user("ow")
        gid, pid = make_listing(owner, title="Quokka <b>Circle</b>")
        sql("UPDATE users SET email = %s WHERE _id = %s", ("owner-mail@example.com", owner))
        J.set_flags(owner)

        a = make_user("ap")
        sql("UPDATE users SET username = %s, email = %s WHERE _id = %s", ("visible_ap_zz", "secret-ap@example.com", a))
        r = req(cli, a, pid, note="hello <script>x</script>")
        time.sleep(0.4)
        check("flag off: request succeeds, no email, window not burned",
              r.status_code == 201 and sent == []
              and sql("SELECT owner_emailed_at FROM group_join_requests WHERE id = %s", (r.json()["id"],))[0][0] is None)

        set_email_flag(owner, "on")
        b = make_user("ap")
        sql("UPDATE users SET username = %s, email = %s WHERE _id = %s", ("visible_bp_zz", "secret-bp@example.com", b))
        rb = req(cli, b, pid, note="hi <script>x</script>")
        time.sleep(0.5)
        check("flag on: one email to the owner after commit", rb.status_code == 201 and len(sent) == 1 and sent[0][0] == "owner-mail@example.com", sent)
        to, subject, html_body, text_body = sent[0]
        blob = html_body + text_body + subject
        check("body has display name, escaped note and escaped title", "visible_bp_zz" in blob and "<script>" not in html_body
              and "&lt;script&gt;" in html_body and "<b>Circle" not in html_body, blob[:300])
        check("no requester email or id, subject fixed", "secret-bp@example.com" not in blob and b not in blob and subject == "New request to join your group")

        c = make_user("ap")
        req(cli, c, pid)
        time.sleep(0.4)
        check("second request inside the window is not emailed", len(sent) == 1, len(sent))
        check("email claim is independent of push claim",
              sql("SELECT count(*) FROM group_join_requests WHERE group_id = %s AND owner_notified_at IS NOT NULL", (gid,))[0][0] == 0)

        sql("UPDATE group_join_requests SET owner_emailed_at = NULL WHERE group_id = %s", (gid,))
        rows = sql("SELECT id::text FROM group_join_requests WHERE group_id = %s AND status = 'pending'", (gid,))
        before = len(sent)

        async def burst():
            await asyncio.gather(*(N.notify_owner_email_of_request(i[0]) for i in rows))

        asyncio.run(burst())
        check("concurrent notifications yield exactly one email", len(sent) - before == 1, len(sent) - before)

        # no email on file, suspended, muted: nothing and no claim
        rid = rows[0][0]
        for label, setup, undo in (
            ("owner without email", ("UPDATE users SET email = '' WHERE _id = %s", owner), ("UPDATE users SET email = 'owner-mail@example.com' WHERE _id = %s", owner)),
            ("suspended owner", ("UPDATE users SET suspended_at = NOW() WHERE _id = %s", owner), ("UPDATE users SET suspended_at = NULL WHERE _id = %s", owner)),
            ("muted owner", ("INSERT INTO group_mutes (group_id, user_id) VALUES (%s, %s)", gid, owner), ("DELETE FROM group_mutes WHERE group_id = %s", gid)),
        ):
            sql("UPDATE group_join_requests SET owner_emailed_at = NULL WHERE group_id = %s", (gid,))
            sql(setup[0], setup[1:])
            before = len(sent)
            asyncio.run(N.notify_owner_email_of_request(rid))
            ok = len(sent) == before and sql("SELECT owner_emailed_at FROM group_join_requests WHERE id = %s", (rid,))[0][0] is None
            sql(undo[0], undo[1:])
            check(f"{label}: no email, no claim", ok)

        # failures isolated
        sql("UPDATE group_join_requests SET owner_emailed_at = NULL WHERE group_id = %s", (gid,))
        mode["fail"] = True
        cap.clear()
        try:
            asyncio.run(N.notify_owner_email_of_request(rid))
            raised = False
        except Exception:
            raised = True
        check("SES failure never propagates", not raised)
        email_lines = [r for r in cap.records if "JOIN_REQUEST_EMAIL" in r.getMessage()]
        check("failure logs one WARNING with type only, no address or message",
              email_lines and all(r.levelname == "WARNING" for r in email_lines)
              and "example.com" not in "\n".join(cap.lines) and not cap.watchdog_hits(), [r.getMessage() for r in email_lines])
        check("non-uuid and unknown ids: no raise", asyncio.run(N.notify_owner_email_of_request("nope")) is None)
        mode["fail"] = False
    finally:
        ses_client.send_email = real
        J.finish()


if __name__ == "__main__":
    main()
