"""Sender user id on chat history rows (task 20261030-profile-everywhere, step 11).

Older (paged) history rows only carried the sender's username, so clients could
not open the sender's profile. This adds one additive key, ``from_user_id``
(lowercase UUID string), and nothing else: the id is already visible to every
member through member lists, and the row sets are already filtered for blocks
and soft deletes by the callers, so this helper never widens who a row is shown
to. The key is emitted only when the author resolved to a live ``users`` row
(``from_user`` username was found), so agent / system / deleted / placeholder
authors get no key and clients stay deny-by-default.
"""
from __future__ import annotations


def sender_id_entry(from_uid, usernames: dict[str, str]) -> dict:
    """``{"from_user_id": <lowercase uuid>}`` for a resolved author, else ``{}``.

    ``usernames`` is the page's author lookup (stringified user id -> username),
    keyed exactly as the callers already build it.
    """
    uid = str(from_uid) if from_uid else ""
    if uid and uid in usernames:
        return {"from_user_id": uid.lower()}
    return {}


def dm_sender_id_entry(mine: bool, caller_id: str, friend_id: str) -> dict:
    """DM rows have exactly two possible authors, both already established by the
    caller (the session user and the peer that passed the friend / block gate)."""
    return {"from_user_id": str(caller_id if mine else friend_id).lower()}
