"""Transient, in-memory store for a live session call transcript.

Privacy contract (user decision, task 20261013-session-call-live-transcript-
summary): the raw transcript is held ONLY in this process's memory, readable
only by the summarize route, deleted right after the summary is produced, on
call teardown, and on TTL expiry. It is never written to the DB, notes, logs,
API responses or any participant-visible channel. Nothing in this module logs
transcript text (only session ids and counts).

Single-process by design (no Redis in this deployment): with multiple workers a
summarize request landing on another worker simply finds nothing and falls back
to the prompts/verses summary. Never fabricates.

``ingest`` is the only write path and has NO HTTP route. A server-side
collector (e.g. a Chime SDK media-insights pipeline consumer, which needs user
approval for infra/IAM) would call it. Chime's StartMeetingTranscription itself
delivers text only to attendee clients, not to the server.
"""
from __future__ import annotations

import threading
import time

from backend.interactions.session_transcription_config import get_session_transcription_config

_HARD_CAP_FACTOR = 4          # stop accepting text beyond max_transcript_chars * this
_OMITTED = "[... middle of the conversation omitted for length ...]"

_lock = threading.Lock()
_transcripts: dict[str, dict] = {}   # session_id -> {"lines": [(speaker, text)], "chars": int, "expires": float}
_active: dict[str, tuple[str, float]] = {}   # session_id -> (chime meeting_id, expiry); transcription started for THAT meeting (drives consent banner)


def _now() -> float:
    return time.time()


def _purge_locked(now: float) -> None:
    for k in [k for k, v in _transcripts.items() if v["expires"] <= now]:
        del _transcripts[k]
    for k in [k for k, (_mid, exp) in _active.items() if exp <= now]:
        del _active[k]


def mark_active(session_id: str, meeting_id: str = "") -> None:
    """Record that transcription runs for ``meeting_id`` of this session. The
    marker is meeting-scoped so a recreated meeting never inherits it."""
    ttl = get_session_transcription_config().ttl_seconds
    with _lock:
        _purge_locked(_now())
        _active[session_id] = (str(meeting_id or ""), _now() + ttl)


def is_active(session_id: str, meeting_id: str | None = None) -> bool:
    """Without ``meeting_id``: any marker for the session. With it: only a
    marker set for that same meeting."""
    with _lock:
        _purge_locked(_now())
        entry = _active.get(session_id)
        if entry is None:
            return False
        return meeting_id is None or entry[0] == str(meeting_id or "")


def clear_active(session_id: str) -> bool:
    """Drop only the active marker (transcript lines are kept: summarize runs
    after the last leave). Returns True if a marker was removed. Idempotent."""
    with _lock:
        return _active.pop(session_id, None) is not None


def ingest(session_id: str, speaker: str, text: str) -> bool:
    """Append one final transcript segment. Returns False if dropped (empty or
    over the hard memory cap). Never logs ``text``."""
    text = (text or "").strip()
    if not session_id or not text:
        return False
    cfg = get_session_transcription_config()
    with _lock:
        now = _now()
        _purge_locked(now)
        entry = _transcripts.setdefault(
            session_id, {"lines": [], "chars": 0, "expires": now + cfg.ttl_seconds})
        if entry["chars"] + len(text) > cfg.max_transcript_chars * _HARD_CAP_FACTOR:
            return False
        entry["lines"].append(((speaker or "Participant").strip() or "Participant", text))
        entry["chars"] += len(text)
        return True


def peek_lines(session_id: str) -> list[tuple[str, str]]:
    with _lock:
        _purge_locked(_now())
        entry = _transcripts.get(session_id)
        return list(entry["lines"]) if entry else []


def discard(session_id: str) -> None:
    """Delete the transcript and active marker. Idempotent; safe under retries."""
    with _lock:
        _transcripts.pop(session_id, None)
        _active.pop(session_id, None)


def fit_transcript(lines: list[tuple[str, str]], max_chars: int) -> str:
    """Render ``Speaker: text`` lines, deterministically capped to ``max_chars``.

    Over the cap, keep whole lines from the start and from the end (half the
    budget each) and mark the gap; same input always gives the same output.
    """
    rendered = [f"{s}: {t}" for s, t in lines]
    total = sum(len(r) + 1 for r in rendered)
    if total <= max_chars:
        return "\n".join(rendered)
    half = max(max_chars // 2, 1)
    head: list[str] = []
    used = 0
    for r in rendered:
        if used + len(r) + 1 > half:
            break
        head.append(r); used += len(r) + 1
    tail: list[str] = []
    used = 0
    for r in reversed(rendered):
        if used + len(r) + 1 > half:
            break
        tail.append(r); used += len(r) + 1
    tail.reverse()
    return "\n".join(head + [_OMITTED] + tail)


def transcript_for_summary(session_id: str) -> str | None:
    """Capped transcript text, or None when absent/too short to be real content
    (caller then falls back to the prompts/verses summary)."""
    cfg = get_session_transcription_config()
    lines = peek_lines(session_id)
    if sum(len(t) for _, t in lines) < max(cfg.min_transcript_chars, 1):
        return None
    return fit_transcript(lines, cfg.max_transcript_chars)
