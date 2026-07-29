import logging
import os
import uuid

from db import DBManager
from backend.email.ses_client import send_email, EmailSendError
from backend.email.templates import content_report_email

logger = logging.getLogger(__name__)


class ReportsManager(DBManager):
    """Guideline 1.2 report/flag queue. Every report is emailed to the
    developer immediately and also persisted, so the DB row is a manual-poll
    backstop if the email doesn't land — the report is never lost either way.
    """

    def __init__(self, reporter_id: str) -> None:
        super().__init__()
        self.reporter_id = reporter_id

    def _resolve_content(self, content_type: str, content_id: str | None,
                          reported_user_id: str) -> tuple[str, str]:
        """Look up the CURRENT authoritative author + text server-side — never
        trust the client for who/what is being reported, so a reporter can't
        spoof either. Returns (resolved_reported_user_id, content_snippet)."""
        if content_type == "note":
            self.cur.execute("SELECT user_id, title, text FROM notes WHERE _id = %s", (content_id,))
            row = self.cur.fetchone()
            if not row:
                return reported_user_id, ""
            uid, title, text = row
            return str(uid), f"{title}\n\n{text}".strip()

        if content_type == "message":
            self.cur.execute("SELECT from_user, text FROM messages WHERE _id = %s", (content_id,))
            row = self.cur.fetchone()
            if not row:
                return reported_user_id, ""
            uid, text = row
            return str(uid) if uid else reported_user_id, text or ""

        if content_type == "devotion_prompt":
            self.cur.execute("SELECT creator_id, prompts FROM devotions WHERE _id = %s", (content_id,))
            row = self.cur.fetchone()
            if not row:
                return reported_user_id, ""
            uid, prompts = row
            return str(uid) if uid else reported_user_id, " | ".join(prompts or [])

        if content_type == "group_title":
            # Groups have no single owner — the client must supply which
            # member is being reported for the title.
            self.cur.execute("SELECT title FROM groups WHERE _id = %s", (content_id,))
            row = self.cur.fetchone()
            return reported_user_id, (row[0] if row else "")

        # content_type == "user": a direct report of the account, no content item.
        return reported_user_id, ""

    def create_report(self, content_type: str, content_id: str | None,
                       reported_user_id: str, reason: str, detail: str) -> dict:
        resolved_user_id, snippet = self._resolve_content(content_type, content_id, reported_user_id)
        report_id = str(uuid.uuid4())
        self.insertion("content_reports", {
            "_id": report_id,
            "reporter_id": self.reporter_id,
            "reported_user_id": resolved_user_id or None,
            "content_type": content_type,
            "content_id": content_id,
            "content_snippet": snippet,
            "reason": reason,
            "detail": detail,
        })

        reporter_username = self._username(self.reporter_id)
        reported_username = self._username(resolved_user_id) if resolved_user_id else "(unknown)"
        subject, html_body, text_body = content_report_email(
            report_id, reporter_username, reported_username, resolved_user_id or "",
            content_type, content_id, snippet, reason, detail,
        )
        try:
            send_email(self._support_email(), subject, html_body, text_body)
        except EmailSendError:
            # The DB row above is the source of truth regardless of delivery —
            # log, don't fail the request, mirroring the password-reset pattern.
            logger.error("Failed to send content_report email for report %s", report_id)

        return {"id": report_id}

    def _username(self, user_id: str | None) -> str:
        if not user_id:
            return "(unknown)"
        self.cur.execute("SELECT username FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        return row[0] if row else "(deleted user)"

    @staticmethod
    def _support_email() -> str:
        return os.getenv("SUPPORT_EMAIL", "support@fellowscript.com")
