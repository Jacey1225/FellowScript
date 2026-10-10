"""Highlight search over the viewer's own highlights plus accepted friends'
(task 20261009-highlight-search).

Scope (deny by default, fail closed): a row is visible only when its owner is
the viewer, or an accepted friend (``user_friends`` row owned by the viewer)
with NO block in either direction -- the same predicate as
``FriendsManager.get_friend_activity``. Group co-members who are not friends
are never included. This reuses the existing friendship grant; it widens
nothing.

Matching (all SQL parameterized; the query text is never logged):
- ``"John 3:16"`` -> that verse; ``"John 3"`` -> that chapter; the book part
  is an exact book name, else a case-insensitive prefix ("Gen" -> Genesis).
- plain text -> books whose name matches (exact, else prefix) OR owners whose
  username contains the text (LIKE wildcards escaped).
Verse text misses degrade to ``verse_text: null``; the row is kept.
"""
from __future__ import annotations

import re

from fastapi import HTTPException

from db import DBManager
from backend.interactions import paging
from backend.interactions.bible_text import _load_raw, parse_highlight_key, verse_text

MAX_QUERY_LENGTH = 100
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 50

_REF_RE = re.compile(r"^(?P<book>.+?)\s+(?P<chapter>\d{1,3})(?::(?P<verse>\d{1,3}))?$")
_KEY_RE = re.compile(r"[A-Za-z0-9 ]{1,64}-\d{1,3}-\d{1,3}")


def _invalid(detail: str) -> HTTPException:
    return HTTPException(status_code=422, detail=detail)


def validate_query(q: str | None) -> str:
    """Strip and validate the raw query; 422 on empty, over-long, or NUL."""
    if q is None:
        raise _invalid("Query is required")
    q = q.strip()
    if not q:
        raise _invalid("Query is required")
    if len(q) > MAX_QUERY_LENGTH:
        raise _invalid(f"Search is limited to {MAX_QUERY_LENGTH} characters")
    if "\x00" in q:
        raise _invalid("Invalid query")
    return q


def _escape_like(s: str) -> str:
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _match_books(name: str) -> list[str]:
    """Exact (case-insensitive) book match, else prefix matches."""
    needle = " ".join(name.casefold().split())
    books = list(_load_raw().keys())
    exact = [b for b in books if b.casefold() == needle]
    if exact:
        return exact
    return [b for b in books if b.casefold().startswith(needle)]


def _key_patterns(q: str) -> tuple[list[str], bool]:
    """Return ``(key LIKE patterns, was_reference)``. Book names contain no
    LIKE metacharacters (letters, digits, spaces)."""
    m = _REF_RE.match(q)
    if m:
        books = _match_books(m.group("book"))
        chapter, verse = m.group("chapter"), m.group("verse")
        if books:
            if verse is not None:
                return [f"{b}-{int(chapter)}-{int(verse)}" for b in books], True
            return [f"{b}-{int(chapter)}-%" for b in books], True
        # Looks like a reference but names no book: nothing to match by key.
        return [], True
    return [f"{b}-%" for b in _match_books(q)], False


class HighlightSearch(DBManager):
    """Read-only search; one instance per request, caller closes it."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = user_id

    def search(self, q: str, limit: int | None, params: dict) -> dict:
        q = validate_query(q)
        limit = paging.clamp_limit(limit, DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE)
        cursor = paging.decode_cursor(params, id_type="uuid", with_seq=False)
        cursor_key = params.get("cursor_key")
        if cursor is None and cursor_key is not None:
            raise _invalid("invalid_cursor")
        if cursor is not None:
            if cursor_key is None or not _KEY_RE.fullmatch(cursor_key):
                raise _invalid("invalid_cursor")

        patterns, is_ref = _key_patterns(q)
        match_clauses: list[str] = []
        match_params: list = []
        if patterns:
            match_clauses.append("h.key LIKE ANY(%s)")
            match_params.append(patterns)
        if not is_ref:
            match_clauses.append("u.username ILIKE %s ESCAPE '\\'")
            match_params.append(f"%{_escape_like(q)}%")
        if not match_clauses:
            return paging.envelope("highlights", [], limit, False, None)

        sql = (
            "SELECT h.user_id, u.username, h.key, h.color, h.emoji, "
            "COALESCE(h.timestamp, 'epoch'::timestamptz) AS ts "
            "FROM highlights h JOIN users u ON u._id = h.user_id "
            "WHERE (h.user_id = %s OR ("
            "  EXISTS (SELECT 1 FROM user_friends uf "
            "          WHERE uf.user_id = %s AND uf.friend_id = h.user_id) "
            "  AND NOT EXISTS ("
            "    SELECT 1 FROM blocked_users b "
            "    WHERE (b.blocker_id = h.user_id AND b.blocked_id = %s) "
            "       OR (b.blocker_id = %s AND b.blocked_id = h.user_id))"
            ")) "
            "AND (" + " OR ".join(match_clauses) + ") "
        )
        sql_params: list = [self.user_id, self.user_id, self.user_id, self.user_id] + match_params
        if cursor is not None:
            sql += (
                "AND (COALESCE(h.timestamp, 'epoch'::timestamptz), h.user_id, h.key) "
                "< (%s::timestamptz, %s::uuid, %s) "
            )
            sql_params += [cursor.timestamp, cursor.id, cursor_key]
        sql += "ORDER BY ts DESC, h.user_id DESC, h.key DESC LIMIT %s"
        sql_params.append(limit + 1)

        self.cur.execute(sql, sql_params)
        rows = self.cur.fetchall()
        has_more = len(rows) > limit
        rows = rows[:limit]

        items = []
        for owner_id, username, key, color, emoji, ts in rows:
            parsed = parse_highlight_key(key)
            if not parsed:
                continue
            book, chapter, verse = parsed
            items.append({
                "owner_id": str(owner_id),
                "owner_username": username,
                "is_self": str(owner_id) == self.user_id,
                "key": key,
                "book": book,
                "chapter": chapter,
                "verse": verse,
                "color": color,
                "emoji": emoji,
                "verse_text": verse_text(book, chapter, verse),
                "timestamp": str(ts) if ts else None,
            })

        next_cursor = None
        if has_more and rows:
            o, _u, k, _c, _e, ts = rows[-1]
            next_cursor = paging.encode_cursor(ts, None, o)
            next_cursor["next_cursor_key"] = k
        return paging.envelope("highlights", items, limit, has_more, next_cursor)
