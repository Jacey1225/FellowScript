"""Authorization for the main-chat WebSocket send path.

``authorize_send`` is the single owner of main-chat send authorization. It is
pure and stateless: every database read goes through the ``cur`` object the
caller passes in (``ConnectionManager`` passes an adapter that delegates to its
stale-cursor-repairing ``_execute``). Any failure inside the guard fails closed as ``Unavailable`` (retriable
``send_failed``), distinct from ``Reject`` (``not_allowed``).

Rules:
  * group send (``group_id`` truthy): the id must be a UUID and the sender a
    current, non-suspended member. Recipients are derived server-side as the
    group's live member list (sender included); client ``to_users`` is ignored.
  * DM send (``group_id`` falsy): ``to_users`` is exactly one string, not the
    sender, an existing user and a friend. A blocked pair is dropped silently.
  * image/video/file attachment keys must be under ``attachments/<sender_id>/``.

Logging: callers log the internal ``cause`` at INFO with ids only. This module
logs at most a WARNING with the exception type name, never message content.
"""
import logging
import uuid
from dataclasses import dataclass

from backend.interactions.attachments import ATTACHMENT_KEY_PREFIX
from backend.interactions.groups import live_member_ids

logger = logging.getLogger(__name__)

MAX_ATTACHMENT_KEY_LEN = 512
_KEYED_KINDS = ("image", "video", "file")


@dataclass(frozen=True)
class SendDecision:
    kind: str                      # "group" | "dm"
    group_id: str | None
    recipients: list[str]


@dataclass(frozen=True)
class Reject:
    cause: str                     # internal only, never sent to the client


@dataclass(frozen=True)
class Unavailable:
    """Infrastructure failure inside the guard (database unreachable, query
    error, timeout). Still fail closed (nothing is saved) but the caller tells
    the sender the retriable ``send_failed``, never ``not_allowed``."""
    cause: str = "guard_error"     # internal only


@dataclass(frozen=True)
class Drop:
    cause: str = "blocked"         # stop silently, send nothing


def _canonical_uuid(value) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def validate_attachment_key(sender_id: str, kind, key) -> bool:
    """True when ``key`` is acceptable for ``kind`` sent by ``sender_id``.

    GIFs and messages with no attachment carry no key and always pass.
    """
    if kind not in _KEYED_KINDS:
        return True
    if not isinstance(key, str) or not isinstance(sender_id, str) or not sender_id:
        return False
    if len(key) > MAX_ATTACHMENT_KEY_LEN:
        return False
    if ".." in key or "\\" in key or "\x00" in key:
        return False
    prefix = f"{ATTACHMENT_KEY_PREFIX}/{sender_id}/"
    return key.startswith(prefix) and len(key) > len(prefix)


def is_current_member(cur, group_id: str, user_id: str) -> bool:
    """True when ``user_id`` is in ``groups.users`` of ``group_id`` and is not
    suspended. One query; False for malformed ids or an unknown group."""
    gid = _canonical_uuid(group_id)
    uid = _canonical_uuid(user_id)
    if gid is None or uid is None:
        return False
    cur.execute(
        "SELECT 1 FROM groups g JOIN users u ON u._id = %s::uuid "
        "WHERE g._id = %s::uuid AND u.suspended_at IS NULL AND %s = ANY(g.users)",
        (uid, gid, uid),
    )
    return cur.fetchone() is not None


def resolve_main_chat_recipients(cur, sender_id: str, group_id: str) -> "list[str] | None":
    """Full live member list of the group (sender included), or None when the
    sender is not a current, non-suspended member or ``group_id`` is not a UUID.
    Members come from ``groups.live_member_ids`` (dead and junk ids ignored)."""
    if not is_current_member(cur, group_id, sender_id):
        return None
    members = live_member_ids(cur, group_id)
    me = _canonical_uuid(sender_id)
    if me not in members:
        return None
    return members


def is_friend(cur, a: str, b: str) -> bool:
    """True when a ``user_friends`` row (a, b) exists (rows are symmetric)."""
    ua, ub = _canonical_uuid(a), _canonical_uuid(b)
    if ua is None or ub is None:
        return False
    cur.execute(
        "SELECT 1 FROM user_friends WHERE user_id = %s::uuid AND friend_id = %s::uuid",
        (ua, ub),
    )
    return cur.fetchone() is not None


def _is_blocked_pair(cur, a: str, b: str) -> bool:
    cur.execute(
        "SELECT 1 FROM blocked_users WHERE (blocker_id = %s::uuid AND blocked_id = %s::uuid) "
        "OR (blocker_id = %s::uuid AND blocked_id = %s::uuid)",
        (a, b, b, a),
    )
    return cur.fetchone() is not None


def _authorize_dm(cur, sender: str, payload: dict) -> "SendDecision | Reject | Drop | Unavailable":
    to_users = payload.get("to_users")
    if not isinstance(to_users, list) or len(to_users) != 1 or not isinstance(to_users[0], str):
        return Reject("bad_recipients")
    recipient = _canonical_uuid(to_users[0])
    if recipient is None:
        return Reject("bad_recipients")
    if recipient == sender:
        return Reject("self_dm")
    # One query: sender not suspended, recipient exists, friendship row exists.
    cur.execute(
        "SELECT "
        "EXISTS(SELECT 1 FROM users WHERE _id = %s::uuid AND suspended_at IS NULL), "
        "EXISTS(SELECT 1 FROM users WHERE _id = %s::uuid), "
        "EXISTS(SELECT 1 FROM user_friends WHERE user_id = %s::uuid AND friend_id = %s::uuid)",
        (sender, recipient, sender, recipient),
    )
    row = cur.fetchone()
    sender_ok, recipient_exists, friends = (bool(row[0]), bool(row[1]), bool(row[2])) if row else (False, False, False)
    if sender_ok and recipient_exists and friends:
        # Preserve the id string the client sent, as it did before the guard.
        return SendDecision("dm", None, [to_users[0]])
    # Rejection path only: a blocked pair is dropped silently (blocking deletes
    # the friendship rows, so it would otherwise surface as a visible error).
    if recipient_exists and _is_blocked_pair(cur, sender, recipient):
        return Drop("blocked")
    if not sender_ok:
        return Reject("sender_unavailable")
    if not recipient_exists:
        return Reject("unknown_user")
    return Reject("not_friend")


def authorize_send(cur, sender_id: str, payload: dict) -> "SendDecision | Reject | Drop | Unavailable":
    """Decide whether ``sender_id`` may send ``payload`` on the main chat.

    Fails closed: any exception inside the guard (infrastructure failure, since
    genuine denials are returned, not raised) is ``Unavailable("guard_error")``.
    """
    try:
        sender = _canonical_uuid(sender_id)
        if sender is None:
            return Reject("bad_sender")
        if not validate_attachment_key(
            sender_id, payload.get("attachment_kind"), payload.get("attachment_key")
        ):
            return Reject("bad_attachment_key")

        group_id = payload.get("group_id")
        if group_id:
            if _canonical_uuid(group_id) is None:
                return Reject("bad_group_id")
            recipients = resolve_main_chat_recipients(cur, sender, group_id)
            if recipients is None:
                return Reject("not_member")
            return SendDecision("group", group_id, recipients)
        return _authorize_dm(cur, sender, payload)
    except Exception as e:  # fail closed; type name only, never str(e)
        logger.warning("send_guard failed closed: %s", type(e).__name__)
        return Unavailable("guard_error")
