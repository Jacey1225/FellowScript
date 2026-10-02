import logging
import os
import uuid

from db import DBManager
from backend.errors import SaveFailedError
from backend.email.ses_client import send_email, EmailSendError
from backend.email.templates import content_report_email

logger = logging.getLogger(__name__)


class ContentNotFoundError(Exception):
    """The reported content does not exist (or no resolver is registered for
    its type). The route answers 404 and nothing is stored."""


# content_type -> resolver(cur, content_id, reported_user_id)
#   -> (author_id, snippet, canonical_content_id) | None
# None means "not found". The five original types are lenient (they return the
# input id and an empty snippet when the row is missing, as before); LST and
# THR register group_listing / thread_message here from their own modules.
CONTENT_RESOLVERS: dict = {}


def register_resolver(content_type: str, fn) -> None:
    CONTENT_RESOLVERS[content_type] = fn


# content_type -> fn(cur, canonical_content_id) -> callable | None, run on the
# manager's cursor right after the report row is stored. The hook may change
# state (the caller commits); a returned callable runs AFTER the commit (used
# for owner emails). A hook failure is logged and never fails the report.
CONTENT_AFTER_REPORT: dict = {}


def register_after_report(content_type: str, fn) -> None:
    CONTENT_AFTER_REPORT[content_type] = fn


def _resolve_note(cur, content_id, reported_user_id):
    cur.execute("SELECT user_id, title, text FROM notes WHERE _id = %s", (content_id,))
    row = cur.fetchone()
    if not row:
        return reported_user_id, "", content_id
    uid, title, text = row
    return str(uid), f"{title}\n\n{text}".strip(), content_id


def _resolve_message(cur, content_id, reported_user_id):
    cur.execute("SELECT from_user, text FROM messages WHERE _id = %s", (content_id,))
    row = cur.fetchone()
    if not row:
        return reported_user_id, "", content_id
    uid, text = row
    return (str(uid) if uid else reported_user_id), text or "", content_id


def _resolve_devotion_prompt(cur, content_id, reported_user_id):
    cur.execute("SELECT creator_id, prompts FROM devotions WHERE _id = %s", (content_id,))
    row = cur.fetchone()
    if not row:
        return reported_user_id, "", content_id
    uid, prompts = row
    return (str(uid) if uid else reported_user_id), " | ".join(prompts or []), content_id


def _resolve_group_title(cur, content_id, reported_user_id):
    # Groups have no single owner — the client must supply which member is
    # being reported for the title.
    cur.execute("SELECT title FROM groups WHERE _id = %s", (content_id,))
    row = cur.fetchone()
    return reported_user_id, (row[0] if row else ""), content_id


def _resolve_user(cur, content_id, reported_user_id):
    # A direct report of the account, no content item.
    return reported_user_id, "", content_id


register_resolver("note", _resolve_note)
register_resolver("message", _resolve_message)
register_resolver("devotion_prompt", _resolve_devotion_prompt)
register_resolver("group_title", _resolve_group_title)
register_resolver("user", _resolve_user)


class ReportsManager(DBManager):
    """Guideline 1.2 report/flag queue. Every report is emailed to the
    developer immediately and also persisted, so the DB row is a manual-poll
    backstop if the email doesn't land — the report is never lost either way.
    """

    def __init__(self, reporter_id: str) -> None:
        super().__init__()
        self.reporter_id = reporter_id

    def create_report(self, content_type: str, content_id: str | None,
                       reported_user_id: str, reason: str, detail: str) -> dict:
        resolved = self._resolve_content(content_type, content_id, reported_user_id)
        if resolved is None:
            # Listing/thread types (and any type with no registered resolver)
            # answer "not found" and store nothing.
            raise ContentNotFoundError()
        resolved_user_id, snippet, canonical_id = resolved
        report_id = str(uuid.uuid4())
        # A Guideline 1.2 report/flag is compliance-relevant -- a failed
        # write here must never look like a successfully filed report.
        if not self.insertion("content_reports", {
            "_id": report_id,
            "reporter_id": self.reporter_id,
            "reported_user_id": resolved_user_id or None,
            "content_type": content_type,
            "content_id": canonical_id,
            "content_snippet": snippet,
            "reason": reason,
            "detail": detail,
        }):
            raise SaveFailedError()
        self._run_after_report(content_type, canonical_id)

        reporter_username = self._username(self.reporter_id)
        reported_username = self._username(resolved_user_id) if resolved_user_id else "(unknown)"
        subject, html_body, text_body = content_report_email(
            report_id, reporter_username, reported_username, resolved_user_id or "",
            content_type, canonical_id, snippet, reason, detail,
        )
        try:
            send_email(self._support_email(), subject, html_body, text_body)
        except EmailSendError:
            # The DB row above is the source of truth regardless of delivery —
            # log, don't fail the request, mirroring the password-reset pattern.
            logger.error("Failed to send content_report email for report %s", report_id)

        return {"id": report_id}

    def _run_after_report(self, content_type: str, canonical_id: str | None) -> None:
        hook = CONTENT_AFTER_REPORT.get(content_type)
        if hook is None or not canonical_id:
            return
        try:
            after_commit = hook(self.cur, canonical_id)
            self.conn.commit()
        except Exception:  # noqa: BLE001 - the report itself is already stored
            self.conn.rollback()
            logger.warning("AFTER_REPORT_HOOK_FAILED type=%s", content_type)
            return
        if after_commit is not None:
            try:
                after_commit()
            except Exception:  # noqa: BLE001
                logger.warning("AFTER_REPORT_NOTIFY_FAILED type=%s", content_type)

    def _resolve_content(self, content_type: str, content_id: str | None,
                          reported_user_id: str) -> tuple[str, str, str | None] | None:
        """Look up the CURRENT authoritative author + text server-side — never
        trust the client for who/what is being reported, so a reporter can't
        spoof either. Dispatches through ``CONTENT_RESOLVERS``; returns
        (resolved_reported_user_id, content_snippet, canonical_content_id) or
        None when the type has no resolver or the resolver found nothing."""
        resolver = CONTENT_RESOLVERS.get(content_type)
        if resolver is None:
            return None
        return resolver(self.cur, content_id, reported_user_id)

    def _username(self, user_id: str | None) -> str:
        if not user_id:
            return "(unknown)"
        self.cur.execute("SELECT username FROM users WHERE _id = %s", (user_id,))
        row = self.cur.fetchone()
        return row[0] if row else "(deleted user)"

    @staticmethod
    def _support_email() -> str:
        return os.getenv("SUPPORT_EMAIL", "support@fellowscript.com")
