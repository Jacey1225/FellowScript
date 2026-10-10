"""Discussion rooms: private breakout Chime meetings tied to a live session.

Task 20261009-discussion-rooms (flag ``discussion_rooms``). A room is its own
Chime meeting hanging off one session (``devotions`` row); a participant of the
session can create a room, others join it, and each room is isolated media.

Authorization is explicit and deny-by-default, in this module, per operation:
the caller must be positively authorized on the MAIN session
(``DevotionManager.is_authorized``, fail-closed), a room can only be created or
joined while the main call is live (``devotions.chime_meeting_id`` set), and a
user may not join a room that holds someone they block or who blocks them. The
room list hides such rooms entirely, so membership never leaks across a block.
A room is only ever reachable through its own session: every room lookup goes
room -> its ``session_id`` -> authorization on that session.

Concurrency: caps are enforced inside one transaction.
  - create takes a per-session advisory lock (``pg_advisory_xact_lock``), then
    counts active rooms; the partial unique index on (session_id, slot) is the
    backstop;
  - join takes the room row ``FOR UPDATE``, counts live members and inserts the
    caller in the same transaction, so two joiners cannot both take the last seat;
  - every lock wait is bounded by ``lock_timeout_ms`` (409 ``busy``).
Chime calls (create meeting, create attendee) happen inside the join
transaction under the room lock, on a client with short timeouts, so a room can
never end up with two meetings.

Presence: a member is live when ``left_at IS NULL`` and ``last_seen`` is within
``member_stale_seconds``. ``last_seen`` is refreshed by join and by the client
heartbeat; a killed app simply goes stale.

Logging never includes join tokens, meeting media placement, titles or
usernames; only ids' presence and counts.
"""
from __future__ import annotations

import json
import logging
import uuid

from botocore.exceptions import ClientError
from psycopg2 import errors as pg_errors

from backend.interactions import chime_meetings
from backend.interactions.devotion import DevotionManager
from backend.interactions.session_rooms_config import get_session_rooms_config

logger = logging.getLogger(__name__)

EXTERNAL_MEETING_PREFIX = "room:"


class RoomError(Exception):
    """A deliberate HTTP-level outcome; the route maps it to ``HTTPException``."""

    def __init__(self, status: int, code: str, message: str | None = None) -> None:
        super().__init__(code)
        self.status = status
        self.code = code
        self.message = message or code

    def detail(self) -> dict:
        return {"code": self.code, "message": self.message}


def is_uuid(value: str) -> bool:
    try:
        uuid.UUID(str(value))
        return True
    except (ValueError, AttributeError, TypeError):
        return False


def live_member_sql(alias: str = "m") -> str:
    """SQL predicate (one ``%s`` = stale seconds) for a live room member row."""
    return f"({alias}.left_at IS NULL AND {alias}.last_seen > NOW() - (%s * INTERVAL '1 second'))"


def session_room_occupied_sql(session_col: str = "devotions._id") -> str:
    """SQL predicate (one ``%s`` = stale seconds): the session has an active room
    with at least one live member. Used inside the atomic auto-delete and
    recurring-advance statements so a session is never removed or reset out from
    under people who are in a room."""
    return (
        "EXISTS (SELECT 1 FROM session_rooms r JOIN session_room_members m ON m.room_id = r.id "
        f"WHERE r.session_id = {session_col} AND r.ended_at IS NULL AND {live_member_sql('m')})"
    )


def _expired_empty_sql(room_alias: str = "r") -> str:
    """SQL predicate (two ``%s``: stale seconds, grace seconds): an active room
    with no live member whose last activity is older than the empty grace."""
    return (
        f"({room_alias}.ended_at IS NULL "
        f"AND NOT EXISTS (SELECT 1 FROM session_room_members m WHERE m.room_id = {room_alias}.id AND {live_member_sql('m')}) "
        f"AND COALESCE((SELECT MAX(GREATEST(m2.last_seen, COALESCE(m2.left_at, m2.last_seen))) "
        f"FROM session_room_members m2 WHERE m2.room_id = {room_alias}.id), {room_alias}.created_at) "
        f"< NOW() - (%s * INTERVAL '1 second'))"
    )


def _tx(fn):
    """Run ``fn`` as one transaction: bounded lock wait, rollback on any error,
    409 ``busy`` on a lock timeout."""

    def wrapper(self, *args, **kwargs):
        try:
            self.cur.execute(
                "SELECT set_config('lock_timeout', %s, true)", (f"{int(self.cfg.lock_timeout_ms)}ms",)
            )
            result = fn(self, *args, **kwargs)
            self.conn.commit()
            return result
        except pg_errors.LockNotAvailable:
            self.conn.rollback()
            logger.info("SESSION_ROOMS busy: lock wait exceeded lock_timeout_ms")
            raise RoomError(409, "busy", "That's busy right now. Please try again.") from None
        except BaseException:
            self.conn.rollback()
            raise

    wrapper.__name__ = fn.__name__
    wrapper.__doc__ = fn.__doc__
    return wrapper


class SessionRoomsManager(DevotionManager):
    """Room operations. Subclasses ``DevotionManager`` to reuse the one
    ``is_authorized`` / ``get_session`` implementation for the main session."""

    def __init__(self) -> None:
        super().__init__()
        self.cfg = get_session_rooms_config()

    # -- shared reads ---------------------------------------------------------

    def _session_or_404(self, session_id: str) -> dict:
        if not is_uuid(session_id):
            raise RoomError(404, "not_found", "Not found")
        session = self.get_session(session_id)
        if not session:
            raise RoomError(404, "not_found", "Not found")
        return session

    def _require_member(self, session: dict, user_id: str) -> None:
        if not self.is_authorized(session, user_id):
            raise RoomError(403, "forbidden", "You're not part of this session.")

    @staticmethod
    def _require_live_main(session: dict) -> None:
        if not (session.get("chime_meeting_id") or ""):
            raise RoomError(409, "main_not_live", "The session call isn't running right now.")

    def _room_row(self, room_id: str, *, lock: bool = False) -> dict:
        if not is_uuid(room_id):
            raise RoomError(404, "not_found", "Room not found")
        self.cur.execute(
            "SELECT id, session_id, creator_id, slot, title, chime_meeting_id, chime_meeting, created_at, ended_at, visibility "
            "FROM session_rooms WHERE id = %s" + (" FOR UPDATE" if lock else ""),
            (room_id,),
        )
        row = self.cur.fetchone()
        if not row:
            raise RoomError(404, "not_found", "Room not found")
        meeting = row[6]
        if isinstance(meeting, str):
            meeting = json.loads(meeting)
        return {
            "id": str(row[0]), "session_id": str(row[1]),
            "creator_id": str(row[2]) if row[2] else "", "slot": row[3], "title": row[4] or "",
            "chime_meeting_id": row[5] or "", "chime_meeting": meeting or {},
            "created_at": row[7], "ended_at": row[8], "visibility": row[9],
        }

    def blocked_ids(self, user_id: str) -> set[str]:
        """Users with a block relation to ``user_id`` in EITHER direction."""
        self.cur.execute(
            "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
            "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s",
            (user_id, user_id),
        )
        return {str(r[0]) for r in self.cur.fetchall()}

    def _live_members(self, room_ids: list[str]) -> dict[str, list[dict]]:
        out: dict[str, list[dict]] = {rid: [] for rid in room_ids}
        if not room_ids:
            return out
        self.cur.execute(
            "SELECT m.room_id, m.user_id, u.username FROM session_room_members m "
            "JOIN users u ON u._id = m.user_id "
            "WHERE m.room_id = ANY(%s::uuid[]) AND " + live_member_sql("m") + " ORDER BY m.joined_at",
            (room_ids, self.cfg.member_stale_seconds),
        )
        for room_id, member_id, username in self.cur.fetchall():
            out[str(room_id)].append({"user_id": str(member_id), "username": username or ""})
        return out

    def _invited_room_ids(self, user_id: str, room_ids: list[str]) -> set[str]:
        if not room_ids:
            return set()
        self.cur.execute(
            "SELECT room_id FROM session_room_invites WHERE user_id = %s AND room_id = ANY(%s::uuid[])",
            (user_id, room_ids),
        )
        return {str(r[0]) for r in self.cur.fetchall()}

    def _views(self, session: dict, viewer_id: str, room_id: str | None = None) -> list[dict]:
        """Visible active rooms of ``session`` for ``viewer_id`` (block-filtered,
        expired-empty rooms omitted). Chime ids are never included."""
        sql = (
            "SELECT r.id, r.slot, r.title, r.creator_id, r.created_at, r.visibility FROM session_rooms r "
            "WHERE r.session_id = %s AND r.ended_at IS NULL AND NOT " + _expired_empty_sql("r")
        )
        params: list = [session["id"], self.cfg.member_stale_seconds, self.cfg.empty_grace_seconds]
        if room_id:
            sql += " AND r.id = %s"
            params.append(room_id)
        sql += " ORDER BY r.slot"
        self.cur.execute(sql, tuple(params))
        rows = self.cur.fetchall()
        members = self._live_members([str(r[0]) for r in rows])
        blocked = self.blocked_ids(viewer_id)
        session_creator = str(session.get("creator_id") or "")
        views = []
        invited_to = self._invited_room_ids(viewer_id, [str(r[0]) for r in rows])
        for rid, slot, title, creator_id, created_at, visibility in rows:
            rid = str(rid)
            roster = members[rid]
            is_member = any(m["user_id"] == viewer_id for m in roster)
            is_creator = str(creator_id or "") == viewer_id
            is_invited = rid in invited_to
            if visibility == "invite_only" and not (is_creator or is_invited or is_member):
                continue  # an invite-only room does not exist for anyone else
            if any(m["user_id"] in blocked for m in roster):
                continue  # never reveal a room that holds someone the viewer has a block with
            views.append({
                "id": rid,
                "session_id": str(session["id"]),
                "slot": slot,
                "title": title or "",
                "name": title or f"Room {slot}",
                "visibility": visibility,
                "is_invited": is_invited,
                "can_join": visibility == "open" or is_creator or is_invited,
                "member_count": len(roster),
                "members": roster,
                "max_members": self.cfg.max_members_per_room,
                "is_full": len(roster) >= self.cfg.max_members_per_room,
                "is_member": is_member,
                "can_end": viewer_id in (str(creator_id or ""), session_creator),
                "is_creator": is_creator,
                "can_invite": visibility == "invite_only" and (is_creator or is_member),
                "created_at": created_at.isoformat() if created_at else "",
            })
        return views

    # -- operations -----------------------------------------------------------

    def list_rooms(self, user_id: str, session_id: str) -> dict:
        session = self._session_or_404(session_id)
        self._require_member(session, user_id)
        rooms = self._views(session, user_id)
        self.conn.rollback()  # read-only: release the snapshot
        return {
            "rooms": rooms,
            "max_members": self.cfg.max_members_per_room,
            "max_rooms": self.cfg.max_rooms_per_session,
            "main_live": bool(session.get("chime_meeting_id")),
        }

    def _validate_invitees(self, session: dict, inviter_id: str, invitee_ids: list[str]) -> list[str]:
        """Each invitee must be a real user, a participant of THIS session (same
        fail-closed ``is_authorized``) and not in a block relation with the inviter.
        One generic message per class of failure; no per-user detail."""
        ids = []
        for raw in invitee_ids:
            if not is_uuid(raw):
                raise RoomError(422, "invalid_invitee", "One of those people can't be invited.")
            uid = str(uuid.UUID(str(raw)))
            if uid != inviter_id and uid not in ids:
                ids.append(uid)
        if not ids:
            return []
        if len(ids) > self.cfg.max_invites_per_room:
            raise RoomError(422, "too_many_invites", "That's too many people to invite at once.")
        self.cur.execute("SELECT _id FROM users WHERE _id = ANY(%s::uuid[])", (ids,))
        existing = {str(r[0]) for r in self.cur.fetchall()}
        self.conn.rollback()
        blocked = self.blocked_ids(inviter_id)
        self.conn.rollback()
        for uid in ids:
            if uid not in existing or uid in blocked or not self.is_authorized(session, uid):
                raise RoomError(422, "invalid_invitee", "One of those people can't be invited.")
        return ids

    def create_room(
        self, user_id: str, session_id: str, title: str,
        visibility: str = "open", invite_user_ids: list[str] | None = None,
    ) -> dict:
        if visibility not in ("open", "invite_only"):
            raise RoomError(422, "invalid_mode", "Rooms are either open or invite-only.")
        session = self._session_or_404(session_id)
        self._require_member(session, user_id)
        self._require_live_main(session)
        invitees = self._validate_invitees(session, user_id, invite_user_ids or [])
        if invitees and visibility != "invite_only":
            raise RoomError(422, "invalid_mode", "Only invite-only rooms take invitations.")
        room_id = self._create_room_tx(user_id, session["id"], title, visibility, invitees)
        session = self._session_or_404(session_id)
        views = self._views(session, user_id, room_id)
        self.conn.rollback()
        if not views:  # created and instantly expired/ended: treat as gone
            raise RoomError(409, "room_ended", "That room has ended.")
        return views[0]

    @_tx
    def _create_room_tx(
        self, user_id: str, session_id: str, title: str, visibility: str, invitees: list[str]
    ) -> str:
        cfg = self.cfg
        self.cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 7))", (f"session_rooms:{session_id}",))
        # Re-check main liveness inside the lock: the session may have advanced or gone.
        self.cur.execute("SELECT COALESCE(chime_meeting_id, '') FROM devotions WHERE _id = %s", (session_id,))
        row = self.cur.fetchone()
        if not row:
            raise RoomError(404, "not_found", "Not found")
        if not row[0]:
            raise RoomError(409, "main_not_live", "The session call isn't running right now.")
        # Free seats held by rooms that were abandoned past the grace period.
        self.cur.execute(
            "UPDATE session_rooms r SET ended_at = NOW() WHERE r.session_id = %s AND " + _expired_empty_sql("r"),
            (session_id, cfg.member_stale_seconds, cfg.empty_grace_seconds),
        )
        # Per-user creation rate (server-side, in addition to the HTTP limiter).
        self.cur.execute(
            "SELECT COUNT(*) FROM session_rooms WHERE creator_id = %s AND created_at > NOW() - INTERVAL '60 seconds'",
            (user_id,),
        )
        if self.cur.fetchone()[0] >= cfg.max_creates_per_user_per_minute:
            raise RoomError(429, "rate_limited", "You're opening rooms too quickly. Try again in a minute.")
        self.cur.execute(
            "SELECT slot FROM session_rooms WHERE session_id = %s AND ended_at IS NULL", (session_id,)
        )
        used = {r[0] for r in self.cur.fetchall()}
        slot = next((s for s in range(1, cfg.max_rooms_per_session + 1) if s not in used), None)
        if slot is None:
            raise RoomError(409, "rooms_full", "This session already has the maximum number of rooms.")
        room_id = str(uuid.uuid4())
        self.cur.execute(
            "INSERT INTO session_rooms (id, session_id, creator_id, slot, title, visibility) "
            "VALUES (%s, %s, %s, %s, %s, %s)",
            (room_id, session_id, user_id, slot, title, visibility),
        )
        for invitee in invitees:
            self.cur.execute(
                "INSERT INTO session_room_invites (room_id, user_id, invited_by) VALUES (%s, %s, %s) "
                "ON CONFLICT DO NOTHING",
                (room_id, invitee, user_id),
            )
        logger.info("SESSION_ROOMS created slot=%s visibility=%s", slot, visibility)
        return room_id

    def join_room(self, user_id: str, room_id: str) -> dict:
        room = self._room_row(room_id)
        self.conn.rollback()
        session = self._session_or_404(room["session_id"])
        self._require_member(session, user_id)
        self._require_live_main(session)
        if room["ended_at"] is not None:
            raise RoomError(410, "room_ended", "That room has ended.")
        meeting, attendee = self._join_tx(user_id, room_id, room["session_id"])
        session = self._session_or_404(room["session_id"])
        views = self._views(session, user_id, room_id)
        self.conn.rollback()
        return {"room": views[0] if views else None, "Meeting": meeting, "Attendee": attendee}

    @_tx
    def _join_tx(self, user_id: str, room_id: str, session_id: str) -> tuple[dict, dict]:
        cfg = self.cfg
        room = self._room_row(room_id, lock=True)
        if room["ended_at"] is not None:
            raise RoomError(410, "room_ended", "That room has ended.")
        self.cur.execute("SELECT COALESCE(chime_meeting_id, '') FROM devotions WHERE _id = %s", (session_id,))
        row = self.cur.fetchone()
        if not row or not row[0]:
            raise RoomError(409, "main_not_live", "The session call isn't running right now.")
        if room["visibility"] == "invite_only" and user_id != room["creator_id"]:
            self.cur.execute(
                "SELECT 1 FROM session_room_invites WHERE room_id = %s AND user_id = %s", (room_id, user_id)
            )
            if self.cur.fetchone() is None:
                # Same generic denial as a block: no hint that the room exists or why.
                raise RoomError(403, "cannot_join", "You can't join this room right now.")
        self.cur.execute(
            "SELECT m.user_id FROM session_room_members m WHERE m.room_id = %s AND " + live_member_sql("m"),
            (room_id, cfg.member_stale_seconds),
        )
        others = {str(r[0]) for r in self.cur.fetchall()} - {user_id}
        if others & self.blocked_ids(user_id):
            # One generic denial: no hint about who is in the room or why.
            raise RoomError(403, "cannot_join", "You can't join this room right now.")
        if len(others) >= cfg.max_members_per_room:
            raise RoomError(409, "room_full", "This room is full.")
        # One room at a time per session: leave any other room of this session.
        self.cur.execute(
            "UPDATE session_room_members SET left_at = NOW() WHERE user_id = %s AND left_at IS NULL "
            "AND room_id IN (SELECT id FROM session_rooms WHERE session_id = %s AND id <> %s)",
            (user_id, session_id, room_id),
        )
        try:
            meeting, attendee, recreated = chime_meetings.create_attendee_with_recreate(
                room["chime_meeting"], EXTERNAL_MEETING_PREFIX + room_id, user_id
            )
        except ClientError as e:
            logger.error("Chime room call failed (code=%s)", e.response.get("Error", {}).get("Code"))
            raise RoomError(502, "chime_error", "Couldn't start the room call. Please try again.") from None
        if recreated:
            self.cur.execute(
                "UPDATE session_rooms SET chime_meeting_id = %s, chime_meeting = %s WHERE id = %s",
                (meeting["MeetingId"], json.dumps(meeting), room_id),
            )
        self.cur.execute(
            "INSERT INTO session_room_members (room_id, user_id) VALUES (%s, %s) "
            "ON CONFLICT (room_id, user_id) DO UPDATE SET "
            "joined_at = CASE WHEN session_room_members.left_at IS NOT NULL THEN NOW() "
            "ELSE session_room_members.joined_at END, left_at = NULL, last_seen = NOW()",
            (room_id, user_id),
        )
        return meeting, attendee

    @_tx
    def leave_room(self, user_id: str, room_id: str) -> dict:
        """Idempotent and oracle-free: leaving a room you are not in is a no-op."""
        if not is_uuid(room_id):
            return {"ok": True}
        self.cur.execute(
            "UPDATE session_room_members SET left_at = NOW() WHERE room_id = %s AND user_id = %s AND left_at IS NULL",
            (room_id, user_id),
        )
        return {"ok": True}

    def rename_room(self, user_id: str, room_id: str, title: str) -> dict:
        """Creator only. ``title`` is already stripped, length-capped and
        content-filtered by the route; '' reverts to the default "Room N"."""
        room = self._room_row(room_id)
        self.conn.rollback()
        session = self._session_or_404(room["session_id"])
        if user_id != room["creator_id"]:
            raise RoomError(403, "forbidden", "Only the person who made this room can rename it.")
        self._require_member(session, user_id)
        if room["ended_at"] is not None:
            raise RoomError(410, "room_ended", "That room has ended.")
        self._rename_tx(room_id, title)
        views = self._views(session, user_id, room_id)
        self.conn.rollback()
        if not views:
            raise RoomError(410, "room_ended", "That room has ended.")
        return views[0]

    @_tx
    def _rename_tx(self, room_id: str, title: str) -> None:
        self.cur.execute(
            "UPDATE session_rooms SET title = %s WHERE id = %s AND ended_at IS NULL", (title, room_id)
        )
        if self.cur.rowcount == 0:
            raise RoomError(410, "room_ended", "That room has ended.")

    def _invite_context(self, user_id: str, room_id: str, *, creator_only: bool) -> tuple[dict, dict]:
        """Load room+session and authorize an invite-management caller. Creator
        always; a current live member too unless ``creator_only``. A non-creator
        outsider gets the uniform 404 so an invite-only room is not an oracle."""
        room = self._room_row(room_id)
        self.conn.rollback()
        session = self._session_or_404(room["session_id"])
        self._require_member(session, user_id)
        if room["ended_at"] is not None:
            raise RoomError(410, "room_ended", "That room has ended.")
        if room["visibility"] != "invite_only":
            raise RoomError(409, "not_invite_only", "This room is open to everyone in the session.")
        is_creator = user_id == room["creator_id"]
        if not is_creator:
            if creator_only:
                raise RoomError(403, "forbidden", "Only the person who made this room can do that.")
            members = self._live_members([room_id])[room_id]
            self.conn.rollback()
            if not any(m["user_id"] == user_id for m in members):
                raise RoomError(404, "not_found", "Room not found")
        return room, session

    def invite(self, user_id: str, room_id: str, invitee_ids: list[str]) -> dict:
        room, session = self._invite_context(user_id, room_id, creator_only=False)
        ids = self._validate_invitees(session, user_id, invitee_ids)
        if not ids:
            raise RoomError(422, "invalid_invitee", "Choose at least one person to invite.")
        self._invite_tx(user_id, room_id, ids)
        return {"ok": True, "invited": len(ids)}

    @_tx
    def _invite_tx(self, inviter_id: str, room_id: str, ids: list[str]) -> None:
        self._room_row(room_id, lock=True)
        self.cur.execute("SELECT COUNT(*) FROM session_room_invites WHERE room_id = %s", (room_id,))
        have = self.cur.fetchone()[0]
        self.cur.execute(
            "SELECT user_id FROM session_room_invites WHERE room_id = %s AND user_id = ANY(%s::uuid[])",
            (room_id, ids),
        )
        fresh = [i for i in ids if i not in {str(r[0]) for r in self.cur.fetchall()}]
        if have + len(fresh) > self.cfg.max_invites_per_room:
            raise RoomError(409, "invite_limit", "This room has reached its invitation limit.")
        for invitee in fresh:
            self.cur.execute(
                "INSERT INTO session_room_invites (room_id, user_id, invited_by) VALUES (%s, %s, %s) "
                "ON CONFLICT DO NOTHING",
                (room_id, invitee, inviter_id),
            )

    def list_invites(self, user_id: str, room_id: str) -> dict:
        self._invite_context(user_id, room_id, creator_only=False)
        self.cur.execute(
            "SELECT i.user_id, u.username FROM session_room_invites i JOIN users u ON u._id = i.user_id "
            "WHERE i.room_id = %s ORDER BY i.created_at",
            (room_id,),
        )
        invitees = [{"user_id": str(r[0]), "username": r[1] or ""} for r in self.cur.fetchall()]
        blocked = self.blocked_ids(user_id)
        self.conn.rollback()
        return {"invites": [i for i in invitees if i["user_id"] not in blocked]}

    def revoke_invite(self, user_id: str, room_id: str, target_id: str) -> dict:
        """Creator only. Idempotent. Does not remove someone already in the room."""
        self._invite_context(user_id, room_id, creator_only=True)
        if not is_uuid(target_id):
            raise RoomError(404, "not_found", "Not found")
        self._revoke_tx(room_id, target_id)
        return {"ok": True}

    @_tx
    def _revoke_tx(self, room_id: str, target_id: str) -> None:
        self.cur.execute(
            "DELETE FROM session_room_invites WHERE room_id = %s AND user_id = %s", (room_id, target_id)
        )

    def end_room(self, user_id: str, room_id: str) -> dict:
        room = self._room_row(room_id)
        self.conn.rollback()
        session = self._session_or_404(room["session_id"])
        if user_id not in (room["creator_id"], str(session.get("creator_id") or "")):
            raise RoomError(403, "forbidden", "Only the room's creator or the session host can end it.")
        self._end_room_tx(room_id)
        # Best-effort teardown; the sweeper retries anything that fails here.
        self.teardown_ended_room_meeting(room_id)
        return {"ok": True}

    @_tx
    def _end_room_tx(self, room_id: str) -> None:
        self.cur.execute(
            "UPDATE session_rooms SET ended_at = COALESCE(ended_at, NOW()) WHERE id = %s", (room_id,)
        )
        self.cur.execute(
            "UPDATE session_room_members SET left_at = NOW() WHERE room_id = %s AND left_at IS NULL", (room_id,)
        )

    def heartbeat(self, user_id: str, room_id: str) -> dict:
        if not is_uuid(room_id):
            raise RoomError(404, "not_found", "Room not found")
        self.cur.execute(
            "UPDATE session_room_members m SET last_seen = NOW() FROM session_rooms r "
            "WHERE m.room_id = r.id AND m.room_id = %s AND m.user_id = %s "
            "AND m.left_at IS NULL AND r.ended_at IS NULL",
            (room_id, user_id),
        )
        if self.cur.rowcount > 0:
            self.conn.commit()
            return {"ok": True}
        self.conn.rollback()
        # Distinguish for a caller that WAS in the room (no oracle for anyone else).
        self.cur.execute(
            "SELECT r.ended_at IS NOT NULL FROM session_room_members m JOIN session_rooms r ON r.id = m.room_id "
            "WHERE m.room_id = %s AND m.user_id = %s",
            (room_id, user_id),
        )
        row = self.cur.fetchone()
        self.conn.rollback()
        if row is None:
            raise RoomError(404, "not_found", "Room not found")
        if row[0]:
            raise RoomError(410, "room_ended", "That room has ended.")
        raise RoomError(409, "not_in_room", "You've left this room.")

    # -- lifecycle ------------------------------------------------------------

    def teardown_ended_room_meeting(self, room_id: str) -> bool:
        """Best-effort ``DeleteMeeting`` for an ended room; blanks the stored
        meeting id only on confirmed success so the sweeper retries failures."""
        self.cur.execute(
            "SELECT chime_meeting_id FROM session_rooms WHERE id = %s AND ended_at IS NOT NULL", (room_id,)
        )
        row = self.cur.fetchone()
        self.conn.rollback()
        if not row or not row[0]:
            return True
        if not chime_meetings.delete_meeting(row[0]):
            return False
        self.cur.execute(
            "UPDATE session_rooms SET chime_meeting_id = '', chime_meeting = '{}' "
            "WHERE id = %s AND chime_meeting_id = %s",
            (room_id, row[0]),
        )
        self.conn.commit()
        return True

    def session_room_meeting_ids(self, session_id: str) -> list[str]:
        """Every non-empty room meeting id for a session (call BEFORE deleting the
        session, whose rows cascade away)."""
        if not is_uuid(session_id):
            return []
        self.cur.execute(
            "SELECT chime_meeting_id FROM session_rooms WHERE session_id = %s AND chime_meeting_id <> ''",
            (session_id,),
        )
        ids = [r[0] for r in self.cur.fetchall()]
        self.conn.rollback()
        return ids


def end_rooms_for_session_sql() -> tuple[str, str]:
    """The two statements (``%s`` = session id) that end every active room of a
    session; run inside the caller's transaction (recurring advance)."""
    return (
        "UPDATE session_room_members SET left_at = NOW() WHERE left_at IS NULL "
        "AND room_id IN (SELECT id FROM session_rooms WHERE session_id = %s AND ended_at IS NULL)",
        "UPDATE session_rooms SET ended_at = NOW() WHERE session_id = %s AND ended_at IS NULL",
    )


def teardown_meetings_best_effort(meeting_ids: list[str]) -> None:
    """Delete room meetings after their session was removed. Never raises."""
    for meeting_id in meeting_ids:
        chime_meetings.delete_meeting(meeting_id)
