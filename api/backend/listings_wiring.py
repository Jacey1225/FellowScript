"""Registers the Explorer-listings lifecycle hooks (and, in a later step, the
``group_listing`` report resolver and remover).

Imported by ``backend.registrations.load_all`` (one line), which ``main.py``
and the ``python -m`` CLIs call. Every import of ``listings`` is FUNCTION-LEVEL:
``groups.py`` imports ``lifecycle`` and ``listings`` imports ``groups``, so a
module-level import here would be circular.

Group deletion needs no collector: ``group_listings`` rows (and their media rows)
cascade with the group. Media S3 keys are added by the media task.
"""
from __future__ import annotations

from backend.interactions import lifecycle


def hide_listing_when_owner_leaves(cur, group_id: str, user_id: str) -> list[str]:
    """member_leave hook: the creator left (the group survives), so the listing
    is hidden (``owner_gone``) and the ``listing_hidden`` hooks run, inside the
    caller's locked leave transaction. The listing is not transferred."""
    from backend.interactions.listings import REASON_OWNER_GONE, hide_in_tx

    cur.execute("SELECT creator_id::text FROM groups WHERE _id = %s", (group_id,))
    row = cur.fetchone()
    if row and row[0] is not None and row[0] == str(user_id).lower():
        hide_in_tx(cur, group_id, REASON_OWNER_GONE)
    return []


def delete_listings_of_deleted_owner(cur, user_id: str) -> list[str]:
    """user_delete hook: delete the listings of every group whose creator is the
    deleted account. (Groups the user was the last member of are already gone,
    with their listings, via the group_delete path.)"""
    cur.execute(
        "DELETE FROM group_listings WHERE group_id IN (SELECT _id FROM groups WHERE creator_id = %s)",
        (str(user_id),),
    )
    return []


lifecycle.register("member_leave", hide_listing_when_owner_leaves)
lifecycle.register("user_delete", delete_listings_of_deleted_owner)
