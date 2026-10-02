"""Explorer listing moderation glue: the ``group_listing`` report resolver and
remover, the auto-hide hook, and owner emails on reject/hide.

Registered by ``backend.listings_wiring`` (one import line in
``registrations.load_all``). Everything here takes the caller's cursor and never
commits, except ``notify_owner`` which opens its own short connection and is
called AFTER the moderation transaction committed (callers run in a threadpool
or a CLI process, never on the event loop).

Logging rule: ids, codes and counts only. No listing text, no email addresses.
"""
from __future__ import annotations

import logging

from backend.interactions import listings
from backend.interactions.listings_config import get_listings_config

logger = logging.getLogger(__name__)

SNAPSHOT_MAX_CHARS = 5000

# Plain-language reason labels shown to owners (drafted for J5 approval). Codes
# come from config; an unknown code falls back to a neutral sentence.
REASON_LABELS = {
    "inappropriate": "The listing contains content that does not fit FellowScript's community guidelines.",
    "not_adults_only": "Explorer listings are for adult groups only, and this listing appeared to be aimed at people under 18.",
    "misleading": "The listing was unclear or misleading about the group.",
    "spam": "The listing looked like advertising or spam.",
    "duplicate": "A listing for this group already exists.",
    "incomplete": "The listing did not have enough information to be approved.",
    "reported": "Several members of the community reported the listing, so it is hidden while we review it.",
    "other": "The listing did not meet our guidelines.",
}
_DEFAULT_LABEL = "The listing did not meet our guidelines."


def resolve_group_listing(cur, content_id, reported_user_id):
    """``CONTENT_RESOLVERS['group_listing']``: ``content_id`` is the listing's
    ``public_id``. Returns ``(creator_id, snapshot, listing _id)`` or None when
    unknown (the route answers 404 and stores nothing). The snapshot (title,
    summary, description text, status, public_id) is capped at 5000 chars so it
    survives a later edit or delete of the listing."""
    if not listings.is_public_id(content_id):
        return None
    cur.execute(
        "SELECT gl._id::text, g.creator_id::text, gl.title, gl.summary, gl.description_text, gl.status, gl.public_id "
        "FROM group_listings gl LEFT JOIN groups g ON g._id = gl.group_id WHERE gl.public_id = %s",
        (content_id,),
    )
    row = cur.fetchone()
    if row is None:
        return None
    listing_id, creator, title, summary, description, status, public_id = row
    snapshot = (
        f"public_id: {public_id}\nstatus: {status}\ntitle: {title or ''}\n"
        f"summary: {summary or ''}\ndescription: {description or ''}"
    )[:SNAPSHOT_MAX_CHARS]
    return creator or reported_user_id or None, snapshot, listing_id


def remove_group_listing(cur, content_id) -> None:
    """``CONTENT_REMOVERS['group_listing']``: ``content_id`` is the stored
    canonical listing ``_id``. Deletes the listing (``listing_hidden`` hooks run
    first). A listing that is already gone is not an error."""
    if not content_id:
        return
    cur.execute("SELECT group_id::text FROM group_listings WHERE _id = %s", (str(content_id),))
    row = cur.fetchone()
    if row is None:
        return
    cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (row[0],))
    listings.remove_in_tx(cur, row[0], "reported_removed")


def after_listing_report(cur, listing_id):
    """After-report hook: auto-hide at the configured distinct-reporter
    threshold. Returns a callable that emails the owner after the commit."""
    hidden = listings.auto_hide_if_reported(cur, listing_id)
    if hidden is None:
        return None
    return lambda: notify_owner(hidden["group_id"], "hide", hidden["reason"])


def reason_label(code: str | None) -> str:
    return REASON_LABELS.get(code or "", _DEFAULT_LABEL)


def notify_owner(group_id: str, action: str, reason_code: str | None) -> bool:
    """Email the group's owner that the listing was rejected or hidden. Own
    connection; never raises (a failed email is one WARNING with ids only).
    Returns True when an email was handed to SES."""
    from backend.email.ses_client import EmailSendError, send_email
    from backend.email.templates import listing_moderation_email
    from db import DBManager

    db = DBManager()
    try:
        db.cur.execute(
            "SELECT u.email, gl.title FROM group_listings gl JOIN groups g ON g._id = gl.group_id "
            "JOIN users u ON u._id = g.creator_id WHERE gl.group_id = %s",
            (group_id,),
        )
        row = db.cur.fetchone()
        db.conn.rollback()
    except Exception:  # noqa: BLE001
        logger.warning("LISTING_NOTIFY_LOOKUP_FAILED group=%s", group_id)
        return False
    finally:
        db.close()
    if row is None or not row[0]:
        return False
    subject, html_body, text_body = listing_moderation_email(action, row[1] or "", reason_label(reason_code))
    try:
        send_email(row[0], subject, html_body, text_body)
    except EmailSendError:
        logger.warning("LISTING_NOTIFY_SEND_FAILED group=%s action=%s", group_id, action)
        return False
    except Exception:  # noqa: BLE001
        logger.warning("LISTING_NOTIFY_SEND_FAILED group=%s action=%s", group_id, action)
        return False
    return True


def reason_codes_ok() -> bool:
    """True when every configured reject/hide code has an owner-facing label
    (used by tests to keep config and labels in step)."""
    cfg = get_listings_config()
    return all(c in REASON_LABELS for c in (*cfg.reject_reason_codes, *cfg.hide_reason_codes))
