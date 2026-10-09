"""App-side note search over encrypted columns
(task 20261008-content-encryption-at-rest).

Title/text are ciphertext at rest, so SQL ``ILIKE`` cannot match them. The
callers keep every scoping rule in SQL (owner / group, non-reply, block filter)
and this module streams those candidate rows newest-first in keyset-paged
batches, opens (decrypts) title/text in the app and keeps the rows whose title
or text contains the query.

Semantics vs. the old ``ILIKE '%q%'``:
- case-insensitive substring over title OR text, same newest-first order
  (``created_at DESC, _id DESC``) and the same per-row shape;
- ``q`` is now matched LITERALLY: ``%`` and ``_`` were SQL wildcards before
  (an accidental behavior), they are ordinary characters now;
- plaintext, escaped and ciphertext rows are all matched (mixed state during
  migration needs no special case: every row goes through ``content_store.open_``).

Bounds: at most ``scan_cap`` candidate rows are examined per request, in
batches of ``search_batch_size``. When the cap is reached before the candidate
set is exhausted the search stops and returns the matches found so far (the
newest ones, because the scan is newest-first), and logs ONE warning with the
counts. The response shape is unchanged (no truncation flag is added, to keep
iOS/web untouched). A row that cannot be decrypted aborts the request with
ContentDecryptError (fail closed): it is never skipped silently or matched on
ciphertext.
"""
from __future__ import annotations

import logging

from backend import content_store
from backend.content_config import get_content_config

logger = logging.getLogger(__name__)


def scan_matches(
    cur,
    select_sql: str,
    where_sql: str,
    where_params: list,
    q: str,
    *,
    idx_id: int,
    idx_created: int,
    idx_title: int,
    idx_text: int,
    created_expr: str,
    id_expr: str,
    scan_cap: int,
    batch_size: int | None = None,
) -> tuple[list[tuple], bool]:
    """Return ``(matching_rows, truncated)``; rows have title/text already opened.

    ``select_sql`` is the full ``SELECT ... FROM notes ...`` text with NO WHERE;
    ``where_sql`` uses ``%s`` placeholders for ``where_params`` (parameterized
    only: ``q`` never reaches SQL). ``created_expr``/``id_expr`` are the SQL
    expressions of the keyset (e.g. ``n.created_at`` / ``n._id``).
    """
    batch = batch_size or get_content_config().search_batch_size
    needle = q.casefold()
    matches: list[tuple] = []
    scanned = 0
    cursor: tuple | None = None
    exhausted = False
    while scanned < scan_cap:
        limit = min(batch, scan_cap - scanned)
        where = where_sql
        params = list(where_params)
        if cursor is not None:
            where += f" AND ({created_expr}, {id_expr}) < (%s::timestamptz, %s::uuid)"
            params += [cursor[0], cursor[1]]
        cur.execute(
            f"{select_sql} WHERE {where} ORDER BY {created_expr} DESC, {id_expr} DESC LIMIT %s",
            params + [limit],
        )
        rows = cur.fetchall()
        for row in rows:
            rid = row[idx_id]
            title = content_store.open_(rid, content_store.F_NOTE_TITLE, row[idx_title])
            text = content_store.open_(rid, content_store.F_NOTE_TEXT, row[idx_text])
            if needle in (title or "").casefold() or needle in (text or "").casefold():
                opened = list(row)
                opened[idx_title], opened[idx_text] = title, text
                matches.append(tuple(opened))
        scanned += len(rows)
        if len(rows) < limit:
            exhausted = True
            break
        last = rows[-1]
        cursor = (last[idx_created], last[idx_id])
    truncated = not exhausted
    if truncated:
        logger.warning("note search hit scan cap: scanned=%d cap=%d matches=%d", scanned, scan_cap, len(matches))
    return matches, truncated
