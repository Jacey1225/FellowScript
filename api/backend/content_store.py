"""The single read/write helper layer for encrypted content columns
(task 20261008-content-encryption-at-rest).

Every in-scope column goes through ``seal`` on write and ``open_`` on read; no
other module calls ``content_crypto`` directly. Contract:

- READ is always dual: plaintext, ``enc:p:`` escaped plaintext and ``enc:v1:``
  ciphertext all return the original text, in either flag state. A ciphertext
  that cannot be authenticated raises ``ContentDecryptError`` (fail closed:
  never ciphertext, never empty or fabricated text).
- WRITE encrypts only while the ``content_encryption_write`` feature flag is on
  (default OFF, fails closed to off). Otherwise the value is stored as
  plaintext (escaped when it starts with ``enc:``).

Field names are ``<table>.<column>`` and are the AAD namespace; the ``F_*``
constants below are the only strings callers should pass.
"""
from __future__ import annotations

import logging

from backend import content_crypto
from backend.content_crypto import ContentDecryptError, ContentKeyConfigError  # noqa: F401 (re-export)

logger = logging.getLogger(__name__)

WRITE_FLAG = "content_encryption_write"

F_NOTE_TITLE = "notes.title"
F_NOTE_TEXT = "notes.text"
F_NOTE_THEME = "notes.theme"
F_MESSAGE_TEXT = "messages.text"
F_THREAD_MESSAGE_TEXT = "thread_messages.text"
F_THREAD_ROOT_PREVIEW = "threads.root_preview"
F_AGENT_CONTENT = "agent_messages.content"
F_REPORT_SNIPPET = "content_reports.content_snippet"
F_REPORT_DETAIL = "content_reports.detail"
F_THREAD_TITLE = "threads.title"
F_AGENT_CHAT_TITLE = "agent_chats.title"
F_AGENT_CHAT_SUMMARY = "agent_chats.summary"

ALL_FIELDS = (
    F_NOTE_TITLE, F_NOTE_TEXT, F_NOTE_THEME, F_MESSAGE_TEXT, F_THREAD_MESSAGE_TEXT,
    F_THREAD_ROOT_PREVIEW, F_AGENT_CONTENT, F_REPORT_SNIPPET, F_REPORT_DETAIL,
    F_THREAD_TITLE, F_AGENT_CHAT_TITLE, F_AGENT_CHAT_SUMMARY,
)

# table -> {column: field}. The id column is always ``_id``. This registry is the
# in-scope list for the generic DBManager funnel, the backfill and the rotation
# script (docs/architecture/backend.md has the written IN/OUT scope table).
TABLE_COLUMNS: dict[str, dict[str, str]] = {
    "notes": {"title": F_NOTE_TITLE, "text": F_NOTE_TEXT, "theme": F_NOTE_THEME},
    "messages": {"text": F_MESSAGE_TEXT},
    "thread_messages": {"text": F_THREAD_MESSAGE_TEXT},
    "threads": {"root_preview": F_THREAD_ROOT_PREVIEW, "title": F_THREAD_TITLE},
    "agent_messages": {"content": F_AGENT_CONTENT},
    "agent_chats": {"title": F_AGENT_CHAT_TITLE, "summary": F_AGENT_CHAT_SUMMARY},
    "content_reports": {"content_snippet": F_REPORT_SNIPPET, "detail": F_REPORT_DETAIL},
}


def writes_enabled() -> bool:
    """True only when the write flag is on. Any failure reading it answers False."""
    try:
        from backend.interactions import flags

        return flags.is_enabled(WRITE_FLAG)
    except Exception:  # noqa: BLE001 - fail closed to plaintext writes
        return False


def seal(row_id, field: str, value, *, force: bool | None = None):
    """Stored form of ``value`` for ``field`` of ``row_id``.

    ``None`` and ``''`` are stored as-is (nothing to protect). ``force`` is for
    tooling (backfill/rotation) that must encrypt regardless of the flag.
    """
    if value is None or value == "":
        return value
    if not isinstance(value, str):
        return value
    do_encrypt = writes_enabled() if force is None else force
    if do_encrypt:
        return content_crypto.encrypt_field(str(row_id), field, value)
    return content_crypto.escape_plain(value)


def open_(row_id, field: str, stored):
    """Plaintext of a stored value (dual-read). Raises ContentDecryptError on a bad ciphertext."""
    return content_crypto.open_value(str(row_id), field, stored)


def open_or_none(row_id, field: str, stored, *, label: str = ""):
    """Like ``open_`` but for best-effort contexts (previews, feeds, prompts)
    where one undecryptable row must not take down the whole response.
    Logs only field + row id + key id, returns ``''`` for that row.

    Do NOT use this for the primary read of a record the caller is about to
    return as authoritative content to its owner: use ``open_`` so a decrypt
    failure surfaces instead of showing blank text.
    """
    try:
        return open_(row_id, field, stored)
    except ContentDecryptError as e:
        logger.warning("content decrypt failed (%s): field=%s row=%s key_id=%s", label or "skip", e.field, e.row_id, e.key_id)
        return ""


def is_encrypted(stored) -> bool:
    return content_crypto.is_ciphertext(stored)



def seal_values(table: str, values: dict, *, row_id=None) -> dict:
    """Copy of ``values`` with every in-scope column of ``table`` sealed.

    Requires the row id (``values['_id']`` or ``row_id``) whenever a sealed column
    is present: the id is part of the AAD, so a missing id is a programming error,
    raised rather than guessed.
    """
    cols = TABLE_COLUMNS.get(table)
    if not cols or not any(c in values for c in cols):
        return values
    rid = row_id if row_id is not None else values.get("_id")
    if rid is None:
        raise ValueError(f"row id required to write encrypted columns of {table}")
    out = dict(values)
    for col, field in cols.items():
        if col in out:
            out[col] = seal(rid, field, out[col])
    return out


def open_row(table: str, row_id, row: dict) -> dict:
    """Copy of a ``{column: value}`` row with every in-scope column opened."""
    cols = TABLE_COLUMNS.get(table)
    if not cols:
        return row
    out = dict(row)
    for col, field in cols.items():
        if col in out:
            out[col] = open_(row_id, field, out[col])
    return out
