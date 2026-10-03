"""Registers the Explorer-listings lifecycle hooks and the ``group_listing``
report resolver, after-report hook (auto-hide) and remover.

Imported by ``backend.registrations.load_all`` (one line), which ``main.py``
and the ``python -m`` CLIs call. Every import of ``listings`` is FUNCTION-LEVEL:
``groups.py`` imports ``lifecycle`` and ``listings`` imports ``groups``, so a
module-level import here would be circular.

Group deletion: ``group_listings`` rows and their media rows cascade with the group;
``collect_listing_media_keys`` reports the media S3 keys for the outbox first. A
listing HIDE does not delete media (an admin restore must still work); a listing
removal does (``listings.remove_in_tx``).
"""
from __future__ import annotations

from backend.interactions import lifecycle, listing_reports, reports
from backend.moderation import removers


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
    from backend.interactions import listings_media

    # Collect the media keys BEFORE the rows (and their media rows) go.
    keys = listings_media.collect_owner_keys(cur, user_id)
    cur.execute(
        "DELETE FROM group_listings WHERE group_id IN (SELECT _id FROM groups WHERE creator_id = %s)",
        (str(user_id),),
    )
    return keys


def collect_listing_media_keys(cur, group_id: str) -> list[str]:
    """group_delete hook: the listing's media rows cascade with the group, so
    report their S3 keys (re-encoded derivatives only) for the outbox."""
    from backend.interactions import listings_media

    return listings_media.collect_group_keys(cur, group_id)


lifecycle.register("member_leave", hide_listing_when_owner_leaves)
lifecycle.register("user_delete", delete_listings_of_deleted_owner)
lifecycle.register("group_delete", collect_listing_media_keys)

# Moderation: report by public_id -> canonical listing _id, remover by stored _id,
# auto-hide after N distinct reporters (see listing_reports).
reports.register_resolver("group_listing", listing_reports.resolve_group_listing)
reports.register_after_report("group_listing", listing_reports.after_listing_report)
removers.register_remover("group_listing", listing_reports.remove_group_listing)
