"""Bio text normalization and validation (task 20261030-user-profiles, D7).

Pure functions, no I/O. A bio is short plain text: it is normalized, then
rejected (never silently truncated or rewritten beyond whitespace/invisible
character cleanup) if it is too long, looks like a link, email or HTML tag, or
trips the explicit-content filter. ``BioRejected.message`` is always a warm,
user-facing sentence and never contains the full bio. The bio text must never be
logged; callers log only ``BioRejected.code``.
"""
from __future__ import annotations

import re
import unicodedata

from backend.moderation.content_filter import ContentRejected, check_clean, rejection_message


class BioRejected(Exception):
    """The bio failed validation. ``code`` is log-safe; ``message`` is for the user."""

    def __init__(self, code: str, message: str):
        self.code = code
        self.message = message
        super().__init__(code)


_TLDS = (
    "com|net|org|io|co|me|app|dev|edu|gov|info|biz|xyz|us|uk|ly|gg|tv|ai|to|cc|"
    "ca|de|fr|ru|cn|in|au|link|site|online|store|shop|page|church"
)
_LINK_RE = re.compile(
    r"(https?:|ftp:|mailto:|javascript:|data:|tel:|sms:|www\.|//[a-z0-9])"
    rf"|\b[a-z0-9][a-z0-9-]*\.(?:{_TLDS})\b",
    re.IGNORECASE,
)
_EMAIL_RE = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")
_TAG_RE = re.compile(r"<\s*/?\s*[a-zA-Z!?]")
_MAX_COMBINING_RUN = 4


def _clean_chars(text: str) -> str:
    out: list[str] = []
    for ch in text:
        cat = unicodedata.category(ch)
        if cat in ("Zs", "Zl", "Zp") or ch in "\t\n\r\x0b\x0c":
            out.append(" ")
        elif cat in ("Cc", "Cf", "Cs", "Co", "Cn"):
            continue  # control, zero-width, bidi override/isolate, private-use, unassigned
        else:
            out.append(ch)
    return "".join(out)


def _combining_run_too_long(text: str) -> bool:
    run = 0
    for ch in text:
        if unicodedata.category(ch) in ("Mn", "Me"):
            run += 1
            if run > _MAX_COMBINING_RUN:
                return True
        else:
            run = 0
    return False


def normalize_bio(raw: str | None) -> str | None:
    """NFC-normalize, strip invisible/control characters, collapse all
    whitespace (including newlines) to single spaces, trim. Empty -> None."""
    if raw is None:
        return None
    text = unicodedata.normalize("NFC", raw)
    text = _clean_chars(text)
    text = re.sub(r" {2,}", " ", text).strip()
    return text or None


def validate_bio(raw: str | None, max_length: int) -> str | None:
    """Return the bio to store (None clears it) or raise ``BioRejected``."""
    text = normalize_bio(raw)
    if text is None:
        return None
    if len(text) > max_length:
        raise BioRejected(
            "too_long",
            f"Your bio can be up to {max_length} characters. Mind trimming it a little?",
        )
    if _combining_run_too_long(text):
        raise BioRejected("odd_characters", "That bio has some unusual characters we can't save. Mind simplifying it?")
    folded = unicodedata.normalize("NFKC", text)
    if _LINK_RE.search(folded) or _EMAIL_RE.search(folded) or _TAG_RE.search(folded):
        raise BioRejected(
            "link_or_markup",
            "Bios are plain text, so links, email addresses and markup can't be saved. Mind removing them?",
        )
    try:
        check_clean(bio=text)
        if folded != text:
            check_clean(bio=folded)
    except ContentRejected as e:
        raise BioRejected("content_filter", rejection_message(e)) from None
    return text
