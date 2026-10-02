"""Shared keyset-cursor codec and page envelope (owned by shared-foundation).

ONE codec for every keyset list. Query params: ``limit``, ``cursor_timestamp``
(ISO 8601, normalised to UTC ``Z`` with microseconds), ``cursor_seq``
(integer >= 0, optional, only with ``with_seq``) and ``cursor_id`` (canonical
UUID for ``id_type='uuid'``, exactly 10 alphanumerics for ``id_type='text'``).

Rules: timestamp and id come together or neither; seq only alongside them;
any parse failure is ``422`` BEFORE any SQL; values are bound, never built
into SQL: ``%s::timestamptz``, ``%s::bigint``, ``%s::uuid`` / ``%s::text``.
Error bodies never echo the offending value.

SQL is per table and stays with the caller; this module only validates,
encodes and builds the envelope.
"""
from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Mapping

from fastapi import HTTPException

_UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_TEXT_ID_RE = re.compile(r"[0-9A-Za-z]{10}")
_SEQ_RE = re.compile(r"[0-9]{1,19}", re.ASCII)
_MAX_SEQ = 2**63 - 1
_MAX_TS_LEN = 64

ID_TYPES = ("uuid", "text")
TS_SQL = "%s::timestamptz"
SEQ_SQL = "%s::bigint"
ID_SQL = {"uuid": "%s::uuid", "text": "%s::text"}


def _invalid() -> HTTPException:
    return HTTPException(status_code=422, detail={"code": "invalid_cursor"})


@dataclass(frozen=True)
class Cursor:
    timestamp: str          # normalised UTC ISO with microseconds and Z
    seq: int | None         # None when the list has no seq
    id: str                 # lower-case uuid, or the 10-char text id
    id_type: str = "uuid"

    @property
    def id_sql(self) -> str:
        return ID_SQL[self.id_type]

    def params(self) -> tuple:
        """Bind values in (timestamp, seq, id) order; seq is 0 when absent."""
        return (self.timestamp, 0 if self.seq is None else self.seq, self.id)


def format_timestamp(ts: datetime | str) -> str:
    """UTC, microseconds, trailing Z. Naive datetimes are taken as UTC."""
    if isinstance(ts, str):
        ts = _parse_timestamp(ts)
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _parse_timestamp(raw: str) -> datetime:
    if not isinstance(raw, str) or not raw or len(raw) > _MAX_TS_LEN or raw != raw.strip():
        raise _invalid()
    text = raw[:-1] + "+00:00" if raw[-1] in "Zz" else raw
    try:
        dt = datetime.fromisoformat(text)
        if dt.tzinfo is None:
            raise ValueError("naive")
        return dt.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise _invalid() from None


def encode_cursor(ts: datetime | str, seq: int | None, row_id) -> dict:
    """The three ``next_cursor_*`` page fields for a row."""
    return {
        "next_cursor_timestamp": format_timestamp(ts),
        "next_cursor_seq": None if seq is None else int(seq),
        "next_cursor_id": str(row_id).lower() if isinstance(row_id, uuid.UUID) else str(row_id),
    }


def decode_cursor(params: Mapping[str, str], id_type: str = "uuid", with_seq: bool = True) -> Cursor | None:
    """Validate cursor query params; None when no cursor was sent; 422 otherwise."""
    if id_type not in ID_TYPES:
        raise ValueError(f"unknown id_type {id_type!r}")  # programmer error
    ts_raw = params.get("cursor_timestamp")
    id_raw = params.get("cursor_id")
    seq_raw = params.get("cursor_seq")
    if ts_raw is None and id_raw is None and seq_raw is None:
        return None
    if ts_raw is None or id_raw is None:
        raise _invalid()
    if seq_raw is not None and not with_seq:
        raise _invalid()
    ts = format_timestamp(_parse_timestamp(ts_raw))
    if id_type == "uuid":
        if not isinstance(id_raw, str) or not _UUID_RE.fullmatch(id_raw):
            raise _invalid()
        cursor_id = str(uuid.UUID(id_raw))
    else:
        if not isinstance(id_raw, str) or not _TEXT_ID_RE.fullmatch(id_raw):
            raise _invalid()
        cursor_id = id_raw
    seq: int | None = None
    if with_seq:
        seq = 0
        if seq_raw is not None:
            if not isinstance(seq_raw, str) or not _SEQ_RE.fullmatch(seq_raw):
                raise _invalid()
            seq = int(seq_raw)
            if seq > _MAX_SEQ:
                raise _invalid()
    return Cursor(timestamp=ts, seq=seq, id=cursor_id, id_type=id_type)


def clamp_limit(limit: int | None, default: int, maximum: int) -> int:
    """``limit`` bounded to [1, maximum]; None means ``default``.

    ``default`` and ``maximum`` come from the caller's config section (no
    hard-coded values live here).
    """
    if default < 1 or maximum < default:
        raise ValueError("invalid paging bounds")  # programmer error
    if limit is None:
        return default
    return max(1, min(int(limit), maximum))


def envelope(items_key: str, items: list, limit: int, has_more: bool, next_cursor: dict | None) -> dict:
    """``{<items_key>: items, "page": {...}}``; next_cursor_* are null unless has_more."""
    page = {
        "limit": limit,
        "has_more": bool(has_more),
        "next_cursor_timestamp": None,
        "next_cursor_seq": None,
        "next_cursor_id": None,
    }
    if has_more and next_cursor:
        page.update(next_cursor)
    return {items_key: items, "page": page}
