"""Lifecycle registries: cleanup hooks that run inside the caller's transaction.

Four registries (kinds):

- ``group_delete``   fn(cur, group_id) -> keys    runs BEFORE the group row is deleted
- ``member_leave``   fn(cur, group_id, user_id) -> keys   a member left, group survives
- ``user_delete``    fn(cur, user_id) -> keys     runs BEFORE ``DELETE FROM users``
- ``listing_hidden`` fn(cur, group_id, reason) -> keys  a group's listing was hidden or removed
  (``reason`` is a short code such as ``owner_gone``; the listing's owner module
  calls ``run('listing_hidden', cur, group_id, reason)``)

A hook returns an iterable of S3 object keys to delete (or ``None``). ``run``
collects them and the CALLER enqueues them with ``enqueue_s3_deletes`` in the
same transaction. Nothing here flushes: a 60 s scheduler job
(``backend.interactions.s3_outbox``) drains the table off the event loop.

A hook that raises aborts the whole delete (the caller rolls back): chosen
over silently losing keys.

The SF collectors are registered by ``backend.lifecycle_wiring``, which this
module imports lazily on first ``run`` (function-level, so ``groups.py`` and
the wiring never import each other at module load).
"""
from __future__ import annotations

from typing import Callable, Iterable

KINDS = ("group_delete", "member_leave", "user_delete", "listing_hidden")

# S3 keys are app-generated; refuse anything that does not look like one.
MAX_KEY_LENGTH = 1024

_registry: dict[str, list[Callable]] = {kind: [] for kind in KINDS}
_wired = False


def register(kind: str, fn: Callable) -> None:
    """Add ``fn`` to a registry. Idempotent for the same function object."""
    if kind not in _registry:
        raise ValueError(f"unknown lifecycle kind {kind!r}")
    if not callable(fn):
        raise TypeError("lifecycle hook must be callable")
    if fn not in _registry[kind]:
        _registry[kind].append(fn)


def hooks(kind: str) -> tuple[Callable, ...]:
    """Registered hooks for a kind (after wiring), in registration order."""
    _ensure_wired()
    return tuple(_registry[kind])


def _ensure_wired() -> None:
    global _wired
    if _wired:
        return
    _wired = True
    from backend import lifecycle_wiring  # noqa: F401  (registers on import)


def _valid_key(key) -> bool:
    return isinstance(key, str) and 0 < len(key) <= MAX_KEY_LENGTH and ".." not in key


def run(kind: str, cur, *args) -> list[str]:
    """Run every hook of ``kind`` on the caller's cursor.

    Returns the de-duplicated, order-preserving list of valid S3 keys the hooks
    reported. Exceptions propagate (the caller aborts and rolls back).
    """
    if kind not in _registry:
        raise ValueError(f"unknown lifecycle kind {kind!r}")
    _ensure_wired()
    keys: list[str] = []
    for fn in list(_registry[kind]):
        result = fn(cur, *args)
        if result:
            keys.extend(k for k in result if _valid_key(k))
    return list(dict.fromkeys(keys))


def enqueue_s3_deletes(cur, keys: Iterable[str]) -> int:
    """INSERT keys into ``pending_s3_deletes`` on the caller's cursor.

    Same transaction as the row deletion; the caller commits. Never flushes and
    never touches S3. Returns the number of rows newly queued.
    """
    clean = [k for k in dict.fromkeys(keys or ()) if _valid_key(k)]
    if not clean:
        return 0
    cur.execute(
        "INSERT INTO pending_s3_deletes (key) SELECT unnest(%s::text[]) "
        "ON CONFLICT (key) DO NOTHING",
        (clean,),
    )
    return cur.rowcount
