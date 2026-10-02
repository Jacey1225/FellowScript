"""Registers the shared-foundation lifecycle hooks.

Imported lazily by ``backend.interactions.lifecycle`` and by
``backend.registrations.load_all``. Every import of another feature module is
FUNCTION-LEVEL: ``groups.py`` imports ``lifecycle``, and this wiring needs
``groups.py`` at call time, so a module-level import would be circular.

Collectors only report keys that the owning helper can prove are
app-generated for that exact group (``is_group_photo_key`` and friends), so
a tampered column can never make the outbox delete an arbitrary object.
"""
from __future__ import annotations

from backend.interactions import lifecycle


def collect_group_photo_key(cur, group_id: str) -> list[str]:
    from backend.interactions.group_photo import is_group_photo_key

    cur.execute("SELECT photo_key FROM groups WHERE _id = %s", (group_id,))
    row = cur.fetchone()
    if row and is_group_photo_key(group_id, row[0]):
        return [row[0]]
    return []


def collect_announcement_banner_keys(cur, group_id: str) -> list[str]:
    from backend.interactions.announcement_banner import is_announcement_banner_key

    cur.execute(
        "SELECT banner_key FROM group_announcements "
        "WHERE group_id = %s AND banner_key IS NOT NULL",
        (group_id,),
    )
    return [r[0] for r in cur.fetchall() if is_announcement_banner_key(group_id, r[0])]


def remove_user_from_groups(cur, user_id: str) -> list[str]:
    """user_delete hook: take the id out of every group's member list.

    Runs the same transaction body as ``leave_group`` for each group (a
    last-member group is deleted, never left empty). Ids are processed in
    sorted order so two concurrent deletions cannot deadlock on group rows.
    Keys are enqueued inside ``remove_member_in_tx`` itself, so nothing is
    returned here.
    """
    from backend.interactions.groups import GroupsManager

    cur.execute("SELECT _id::text FROM groups WHERE %s = ANY(users) ORDER BY _id", (str(user_id),))
    for (group_id,) in cur.fetchall():
        GroupsManager.remove_member_in_tx(cur, group_id, str(user_id))
    return []


lifecycle.register("group_delete", collect_group_photo_key)
lifecycle.register("group_delete", collect_announcement_banner_keys)
lifecycle.register("user_delete", remove_user_from_groups)
