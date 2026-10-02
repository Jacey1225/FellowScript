"""``CONTENT_REMOVERS``: how the moderation CLI removes reported content.

Lives in its own module (not ``admin_actions``) because the CLI runs as
``python -m backend.moderation.admin_actions``: that module is ``__main__``,
and a second import of it under its real name (which ``registrations.load_all``
would trigger) creates a SECOND registry that LST/THR registrations would land
in while ``main()`` reads the first. ``admin_actions`` re-exports the dict.

``CONTENT_REMOVERS[content_type](cur, content_id)`` runs on the CLI's cursor;
the CLI commits. LST and THR register ``group_listing`` / ``thread_message``
from their own modules (imported by ``backend.registrations.load_all``).
"""

CONTENT_REMOVERS: dict = {}


def register_remover(content_type: str, fn) -> None:
    CONTENT_REMOVERS[content_type] = fn


def _remove_note(cur, content_id) -> None:
    if content_id:
        cur.execute("DELETE FROM notes WHERE _id = %s", (content_id,))


def _remove_message(cur, content_id) -> None:
    if content_id:
        cur.execute("DELETE FROM messages WHERE _id = %s", (content_id,))


def _remove_devotion_prompt(cur, content_id) -> None:
    if content_id:
        cur.execute("UPDATE devotions SET prompts = '{}' WHERE _id = %s", (content_id,))


def _remove_group_title(cur, content_id) -> None:
    if content_id:
        cur.execute("UPDATE groups SET title = 'Group' WHERE _id = %s", (content_id,))


def _remove_user(cur, content_id) -> None:
    # The report is about the account itself; nothing to remove.
    return None


register_remover("note", _remove_note)
register_remover("message", _remove_message)
register_remover("devotion_prompt", _remove_devotion_prompt)
register_remover("group_title", _remove_group_title)
register_remover("user", _remove_user)
