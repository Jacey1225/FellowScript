"""Registers the join-requests lifecycle hooks.

Imported by ``backend.registrations.load_all`` (one line), which ``main.py`` and
the ``python -m`` CLIs call; registration at a bare, unrelated import would not
run in the separate CLI processes. Hooks run on the CALLER's cursor inside its
transaction (they commit or roll back with the leave, delete or hide that
triggered them), are plain sync functions and report no S3 keys.

Group deletion needs no hook: ``group_join_requests.group_id`` is ``ON DELETE
CASCADE``, which covers both deletion paths (``delete_group`` and the
last-member branch of ``leave_group``). A deleted applicant's own requests
cascade the same way (``user_id``).

The hooks never import the listings module (and ``listings`` never imports this
one): ``listing_hidden`` is a registry kind the listings module only calls.
"""
from __future__ import annotations

from backend.interactions import lifecycle


def _expire_pending(cur, group_id: str) -> None:
    cur.execute(
        "UPDATE group_join_requests SET status = 'expired', decided_at = NOW() "
        "WHERE group_id = %s AND status = 'pending'",
        (group_id,),
    )


def expire_requests_when_owner_leaves(cur, group_id: str, user_id: str) -> list[str]:
    """member_leave hook: the leaver is the group's creator (the group survives
    but nobody can approve), so its pending requests expire."""
    cur.execute("SELECT creator_id::text FROM groups WHERE _id = %s", (group_id,))
    row = cur.fetchone()
    if row and row[0] is not None and row[0] == str(user_id).lower():
        _expire_pending(cur, group_id)
    return []


def expire_requests_of_deleted_owner(cur, user_id: str) -> list[str]:
    """user_delete hook: pending requests for every group the deleted account
    created expire (the requests the account itself made cascade by FK)."""
    cur.execute(
        "UPDATE group_join_requests SET status = 'expired', decided_at = NOW() "
        "WHERE status = 'pending' AND group_id IN (SELECT _id FROM groups WHERE creator_id = %s)",
        (str(user_id),),
    )
    return []


def expire_requests_when_listing_hidden(cur, group_id: str, reason: str) -> list[str]:
    """listing_hidden hook: the group's listing was hidden or removed, so its
    pending requests expire (``reason`` is the listing module's short code)."""
    _expire_pending(cur, group_id)
    return []


lifecycle.register("member_leave", expire_requests_when_owner_leaves)
lifecycle.register("user_delete", expire_requests_of_deleted_owner)
lifecycle.register("listing_hidden", expire_requests_when_listing_hidden)
