"""Registers the message-thread hooks: the ``thread_message`` report resolver
and remover, and the ``group_delete`` collector for thread attachment keys.

Imported by ``backend.registrations.load_all`` (one line), which ``main.py``
and the ``python -m`` CLIs call; registration at bare import would not run in
the separate CLI processes. No ``user_delete`` hook: ``thread_messages.from_user``
is ``ON DELETE SET NULL`` and the content is kept (decision D12). Imports of
``send_guard`` are function-level where ``groups`` is involved, for the same
circular-import reason as ``listings_wiring``.

Keys are only ever reported or queued when they are provably the author's own
(``send_guard.validate_attachment_key``) and no other row still uses them, so a
tampered or shared key can never make the outbox delete someone else's object.
"""
from __future__ import annotations

from backend import content_store
from backend.interactions import lifecycle, reports
from backend.interactions.lifecycle import enqueue_s3_deletes
from backend.moderation import removers


def resolve_thread_message(cur, content_id, reported_user_id):
    """Report resolver (3-tuple contract). The id is ``thread_messages._id``,
    which clients already hold as ``id``, so canonical equals input. Like the
    ``message`` resolver there is deliberately NO ``deleted_at`` filter: a late
    report of a just-deleted message still captures its text (evidence
    retention). Unknown id -> ``None`` (the route answers 404, nothing stored)."""
    cur.execute("SELECT from_user::text, text FROM thread_messages WHERE _id = %s", (content_id,))
    row = cur.fetchone()
    if not row:
        return None
    author, text = row
    text = content_store.open_(content_id, content_store.F_THREAD_MESSAGE_TEXT, text)
    return (author if author else reported_user_id), text or "", str(content_id)


def _key_used_elsewhere(cur, key: str, thread_message_id: str) -> bool:
    cur.execute(
        "SELECT 1 FROM messages WHERE attachment_key = %s "
        "UNION ALL SELECT 1 FROM thread_messages WHERE attachment_key = %s AND _id <> %s LIMIT 1",
        (key, key, thread_message_id),
    )
    return cur.fetchone() is not None


def remove_thread_message(cur, content_id) -> None:
    """Moderation CLI remover: hard-delete the row and queue its attachment key
    to the ``pending_s3_deletes`` outbox (never a per-key ``delete_object``).
    The CLI commits."""
    from backend.interactions.send_guard import validate_attachment_key

    if not content_id:
        return
    cur.execute(
        "DELETE FROM thread_messages WHERE _id = %s RETURNING from_user::text, attachment_kind, attachment_key",
        (content_id,),
    )
    row = cur.fetchone()
    if not row:
        return
    author, kind, key = row
    if key and author and validate_attachment_key(author, kind, key) and not _key_used_elsewhere(cur, key, content_id):
        enqueue_s3_deletes(cur, [key])


def collect_thread_attachment_keys(cur, group_id: str) -> list[str]:
    """``group_delete`` collector (runs before the group row is deleted, while
    its threads still exist): the author-owned keys of the group's thread
    messages that no row OUTSIDE this group still references."""
    from backend.interactions.send_guard import validate_attachment_key

    cur.execute(
        "SELECT DISTINCT tm.from_user::text, tm.attachment_kind, tm.attachment_key "
        "FROM thread_messages tm JOIN threads t ON t._id = tm.thread_id "
        "WHERE t.group_id = %s AND tm.attachment_key IS NOT NULL "
        "AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.attachment_key = tm.attachment_key "
        "                AND m.group_id IS DISTINCT FROM t.group_id) "
        "AND NOT EXISTS (SELECT 1 FROM thread_messages o JOIN threads ot ON ot._id = o.thread_id "
        "                WHERE o.attachment_key = tm.attachment_key AND ot.group_id <> t.group_id)",
        (group_id,),
    )
    return [
        key for author, kind, key in cur.fetchall()
        if author and validate_attachment_key(author, kind, key)
    ]


reports.register_resolver("thread_message", resolve_thread_message)
removers.register_remover("thread_message", remove_thread_message)
lifecycle.register("group_delete", collect_thread_attachment_keys)
