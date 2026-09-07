import logging
import os
from datetime import datetime, timezone as tzmod
from schemas.users import User
from db import DBManager
from backend.errors import SaveFailedError
from backend.interactions.attachments import generate_download_url
from backend.interactions.blocks import BlockManager
from backend.interactions.bible_text import parse_highlight_key, verse_text

logger = logging.getLogger(__name__)

# ── Nudge feature config (task 20260906-friend-nudges) ──────────────────────
#
# Both env vars are treated as new *required* config, not optional knobs with
# a silently-guessed fallback (Configuration Philosophy Q4/Q1/Q8): the raw
# strings are only read here, at import time; validate_nudge_config() must be
# called eagerly at process startup (main.py's lifespan, alongside
# push.py's validate_apns_config()) to parse and populate the typed globals
# below -- a deploy that hasn't set them explicitly fails loudly at boot
# instead of the endpoint silently running with a guessed rate-limit window
# or an implicitly-on/off feature flag. NUDGE_FEATURE_ENABLED is expected to
# be deployed as "false" initially (off-by-default proactive-flagging
# stance) and flipped to "true" for rollout -- that's a deploy-time value
# choice, not a code-level fallback.
_NUDGE_FEATURE_ENABLED_RAW = os.getenv("NUDGE_FEATURE_ENABLED")
_NUDGE_RATE_LIMIT_HOURS_RAW = os.getenv("NUDGE_RATE_LIMIT_HOURS")

# Populated by validate_nudge_config(); read via is_nudge_enabled() rather
# than importing this name by value elsewhere, since `from module import
# NAME` binds the value at import time and would never observe the update
# validate_nudge_config() makes after that import runs.
NUDGE_FEATURE_ENABLED = False
NUDGE_RATE_LIMIT_HOURS = 0


class NudgeConfigError(RuntimeError):
    """NUDGE_FEATURE_ENABLED/NUDGE_RATE_LIMIT_HOURS are unset or invalid.

    Deliberately never swallowed -- mirrors push.py's APNsConfigError
    precedent exactly (see that class's docstring): a misconfigured nudge
    rollout must fail loudly at boot rather than the endpoint silently
    running with a guessed or nonsensical rate-limit window.
    """


def validate_nudge_config() -> None:
    """Eagerly validate and parse NUDGE_FEATURE_ENABLED/NUDGE_RATE_LIMIT_HOURS.

    Call once, at process startup (main.py's lifespan), before serving
    traffic -- same placement/reasoning as push.py's validate_apns_config()
    and attachments.py's validate_attachment_config().

    Raises:
        NudgeConfigError: If either var is unset, or NUDGE_FEATURE_ENABLED
            isn't exactly "true"/"false" (case-insensitive), or
            NUDGE_RATE_LIMIT_HOURS isn't a positive integer.
    """
    global NUDGE_FEATURE_ENABLED, NUDGE_RATE_LIMIT_HOURS

    if _NUDGE_FEATURE_ENABLED_RAW is None:
        raise NudgeConfigError(
            "NUDGE_FEATURE_ENABLED is not set. There is no implicit "
            "default -- set it explicitly to \"false\" (off) or \"true\" "
            "before this process can start."
        )
    normalized = _NUDGE_FEATURE_ENABLED_RAW.strip().lower()
    if normalized not in ("true", "false"):
        raise NudgeConfigError(
            f"NUDGE_FEATURE_ENABLED ({_NUDGE_FEATURE_ENABLED_RAW!r}) must be "
            "exactly \"true\" or \"false\"."
        )
    NUDGE_FEATURE_ENABLED = normalized == "true"

    if _NUDGE_RATE_LIMIT_HOURS_RAW is None or not _NUDGE_RATE_LIMIT_HOURS_RAW.strip():
        raise NudgeConfigError(
            "NUDGE_RATE_LIMIT_HOURS is not set. There is no implicit "
            "default for the nudge rate-limit window -- set it explicitly "
            "(e.g. 24)."
        )
    try:
        hours = int(_NUDGE_RATE_LIMIT_HOURS_RAW)
    except ValueError:
        raise NudgeConfigError(
            f"NUDGE_RATE_LIMIT_HOURS ({_NUDGE_RATE_LIMIT_HOURS_RAW!r}) is "
            "not a valid integer."
        )
    if hours <= 0:
        raise NudgeConfigError(
            f"NUDGE_RATE_LIMIT_HOURS ({hours}) must be a positive number of hours."
        )
    NUDGE_RATE_LIMIT_HOURS = hours


def is_nudge_enabled() -> bool:
    """Current NUDGE_FEATURE_ENABLED value -- always looked up fresh (see the
    module-global comment above) so callers see validate_nudge_config()'s
    result regardless of import order."""
    return NUDGE_FEATURE_ENABLED


class FriendsManager(DBManager):
    """Handles friend request, acceptance, removal, and DM retrieval."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = user_id
        result = self.lookup("users", {"_id": user_id})
        if result:
            uid, data = list(result.items())[0]
            self.user = User(user_id=uid, **data)
        else:
            self.user = User()

    def send_add_request(self, friend_username: str) -> dict | None:
        """Append the acting user's ID to the target user's friend_requests list.

        Args:
            friend_username: Username of the user to send the request to.

        Returns:
            dict | None: ``{"error": str}`` if the user is not found or the
                user attempts to add themselves; ``None`` on success.
        """
        result = self.lookup("users", {"username": friend_username})
        if not result:
            return {"error": "User not found"}
        friend_id = list(result.keys())[0]
        if friend_id == self.user_id:
            return {"error": "Cannot add yourself"}
        blocks = BlockManager(self.user_id)
        try:
            if blocks.is_blocked(friend_id):
                return {"error": "Cannot send request"}
        finally:
            blocks.close()
        if not self.insertion("friend_requests", {
            "to_user_id":   friend_id,
            "from_user_id": self.user_id,
        }):
            raise SaveFailedError()
        return None

    def add_friend(self, friend_username: str) -> dict | None:
        """Accept a pending friend request and establish a mutual friendship.

        Args:
            friend_username: Username of the user to accept as a friend.

        Returns:
            dict | None: ``{"error": str}`` if the user is not found;
                ``None`` on success.
        """
        result = self.lookup("users", {"username": friend_username})
        if not result:
            return {"error": "User not found"}
        friend_id = list(result.keys())[0]
        blocks = BlockManager(self.user_id)
        try:
            if blocks.is_blocked(friend_id):
                return {"error": "Cannot add this user"}
        finally:
            blocks.close()
        if not self.insertion("user_friends", {"user_id": self.user_id, "friend_id": friend_id}):
            raise SaveFailedError()
        if not self.insertion("user_friends", {"user_id": friend_id, "friend_id": self.user_id}):
            raise SaveFailedError()
        # Best-effort cleanup of the now-accepted request row -- the
        # friendship itself (the two inserts above) is already established,
        # so a stray/already-gone request row here is not treated as this
        # call's own failure (a real DB error is still visible via db.py's
        # DB_WRITE_FAILURE log line).
        self.delete("friend_requests", {"to_user_id": self.user_id, "from_user_id": friend_id})
        return None

    def get_requests(self) -> list[dict]:
        """Return pending *incoming* friend requests for the acting user.

        Each entry is the sender's public identity, so the account page can show
        who wants to connect.

        Returns:
            list[dict]: ``[{"user_id": str, "username": str,
                "profile_photo_url": str | None}, ...]``.
        """
        self.cur.execute(
            "SELECT u._id, u.username, u.profile_photo_key FROM users u "
            "JOIN friend_requests fr ON u._id = fr.from_user_id "
            "WHERE fr.to_user_id = %s",
            (self.user_id,)
        )
        return [
            {"user_id": r[0], "username": r[1], "profile_photo_url": generate_download_url(r[2])}
            for r in self.cur.fetchall()
        ]

    def get_friends(self) -> list[dict]:
        """Return the full friend list for the acting user.

        Returns:
            list[dict]: List of friend user records with ``hash_pass`` excluded.
        """
        self.cur.execute(
            "SELECT u._id, u.username, u.email, u.profile_photo_key FROM users u "
            "JOIN user_friends uf ON u._id = uf.friend_id "
            "WHERE uf.user_id = %s",
            (self.user_id,)
        )
        return [
            {"user_id": r[0], "username": r[1], "email": r[2], "profile_photo_url": generate_download_url(r[3])}
            for r in self.cur.fetchall()
        ]

    @staticmethod
    def _format_dm_row(from_username: str, row: tuple) -> dict:
        """Shape one ``messages`` row (as selected in ``read_friend``) into
        the dict the client expects, resolving ``attachment_key`` to a
        fresh presigned GET (never handing back the stored key itself --
        see backend/interactions/attachments.py)."""
        _id, text, timestamp, attachment_kind, attachment_key, attachment_meta = row
        return {
            "from_user": from_username,
            "text": text,
            "timestamp": str(timestamp),
            "attachment_kind": attachment_kind,
            "attachment_meta": attachment_meta or {},
            "attachment_url": generate_download_url(attachment_key) if attachment_key else None,
        }

    def read_friend(self, friend_id: str) -> dict:
        """Fetch a friend's profile and the shared DM history.

        Args:
            friend_id: UUID of the friend to retrieve.

        Returns:
            dict: Contains ``friend`` profile (without hash_pass), ``host_msgs``,
                and ``other_msgs``. Returns ``{"error": str}`` if not found.
        """
        result = self.lookup("users", {"_id": friend_id})
        if not result:
            return {"error": "Friend not found"}
        blocks = BlockManager(self.user_id)
        try:
            if blocks.is_blocked(friend_id):
                return {"error": "This contact is unavailable"}
        finally:
            blocks.close()
        _, friend_data = list(result.items())[0]
        # Task 20260904-messaging-attachments: attachment_kind/attachment_meta
        # ride along with text/timestamp; attachment_key itself is never
        # handed to the client -- it's resolved to a fresh, short-lived
        # presigned GET at read time instead (see _format_dm_row below).
        self.cur.execute(
            "SELECT m._id, m.text, m.timestamp, m.attachment_kind, m.attachment_key, m.attachment_meta "
            "FROM messages m "
            "JOIN message_recipients mr ON m._id = mr.message_id "
            "WHERE m.from_user = %s AND mr.user_id = %s AND m.group_id IS NULL",
            (self.user_id, friend_id)
        )
        host_msgs = [
            self._format_dm_row(self.user.username, r) for r in self.cur.fetchall()
        ]
        self.cur.execute(
            "SELECT m._id, m.text, m.timestamp, m.attachment_kind, m.attachment_key, m.attachment_meta "
            "FROM messages m "
            "JOIN message_recipients mr ON m._id = mr.message_id "
            "WHERE m.from_user = %s AND mr.user_id = %s AND m.group_id IS NULL",
            (friend_id, self.user_id)
        )
        other_msgs = [
            self._format_dm_row(friend_data.get("username", ""), r) for r in self.cur.fetchall()
        ]
        # Same raw-key-never-leaves-the-server treatment as hash_pass just
        # below -- friend_data here is a raw `lookup()` row, so
        # profile_photo_key must be popped unconditionally and resolved to a
        # fresh presigned GET (task 20260905-profile-photo).
        friend_view = {k: v for k, v in friend_data.items() if k != "hash_pass"}
        friend_view["profile_photo_url"] = generate_download_url(friend_view.pop("profile_photo_key", None))
        return {
            "friend":     friend_view,
            "host_msgs":  host_msgs,
            "other_msgs": other_msgs,
        }

    def remove_friend(self, friend_id: str) -> None:
        """Remove a friend from both users' friend lists.

        Args:
            friend_id: UUID of the friend to remove.
        """
        # Best-effort/idempotent: either direction may already be gone (a
        # partial prior removal, a race with block_user's own cleanup), so
        # a zero-rows False here is not treated as failure -- a real DB
        # error is still visible via db.py's DB_WRITE_FAILURE log line.
        self.delete("user_friends", {"user_id": self.user_id, "friend_id": friend_id})
        self.delete("user_friends", {"user_id": friend_id, "friend_id": self.user_id})

    # Size of the "check in" nudge candidate pool (see get_friend_activity).
    # Bounded rather than unbounded so the nudge keeps its stated purpose --
    # surfacing a genuinely-neglected friend -- instead of degrading into a
    # pick from the user's entire friend list regardless of recency.
    CHECK_IN_POOL_SIZE = 5

    def get_friend_activity(self, limit: int = 20) -> dict:
        """Friend-activity read surface for the dashboard's Friend Activity
        hero card: each friend's most recent note preview drawn from a
        group note the *viewer* (`self.user_id`) can also see -- plus their
        last-activity timestamp, ordered most-recently-active first, and a
        bounded "check in" nudge candidate pool -- the friends the acting
        user has gone longest without directly messaging.

        Note-preview data source (post `notes.public` repurposing, task
        20260903-notes-public-repurpose): `notes.public` no longer means
        visibility, and a friend's personal notes (`group_id IS NULL`) are
        now unconditionally private to their owner, so they are no longer a
        valid preview source at all -- a friendship alone never implies
        note visibility. Instead this pulls the friend's most recent
        *group* note (`group_id IS NOT NULL`, `is_reply = false`) whose
        group the viewer also currently belongs to (shared membership,
        checked against `groups.users`) -- i.e. only a note the viewer
        could already see for themselves via the group notes feed, never a
        friend's private content. A friend with no such shared-group note
        (including one with only personal notes, or group notes in groups
        the viewer isn't in) simply gets `note_preview: None`.

        The check-in pool is intentionally bounded (`CHECK_IN_POOL_SIZE`,
        capped at the user's actual friend count via `LIMIT`) rather than
        covering the whole friend list: the nudge's purpose is surfacing a
        genuinely-neglected friend, so the client is expected to pick
        (e.g. randomly) from within this "longest since contact" pool, not
        from friends who were recently contacted.

        Block-respecting in both directions via the same defense-in-depth
        `NOT EXISTS` pattern as `ActivityManager.friend_device_tokens`
        (this subsystem's prior IDOR history means block state is
        re-checked here rather than trusted to have fully unwound
        `user_friends` already).

        Highlights (task 20260904-friend-activity-push-triggers, Round 2):
        friendship alone is sufficient grant to see a friend's highlight,
        including its real verse content -- a deliberate widening of the
        prior rule (highlights had zero visibility to anyone, friend or
        not), since unlike notes a highlight never had any group/ownership
        scoping to preserve. This does NOT reopen note/reply visibility --
        the group-membership-gated `note_preview` above is untouched. Each
        friend's most recent highlight (by `highlights.timestamp`) is
        resolved to `highlight_preview`, still subject to the same
        block-respecting `NOT EXISTS` predicate as everything else in this
        query (defense-in-depth, same reasoning as
        `ActivityManager.friend_device_tokens`). Verse text is resolved via
        `bible_text.verse_text`; a lookup miss just leaves `verse_text: None`
        in the preview (client decides how to degrade) rather than dropping
        the whole entry.

        Args:
            limit: Max number of friends to return in `friends_active`
                (bounds the avatar-stack list; the mockup shows one primary
                + a handful of others).

        Returns:
            dict: ``{"friends_active": [{"friend_id", "username",
                "profile_photo_url": str | None, "last_active_at",
                "activity_type": str | None, "note_preview": {"note_id",
                "title", "text", "timestamp"} | None, "highlight_preview":
                {"book", "chapter", "verse", "color", "verse_text": str |
                None, "timestamp"} | None}, ...], "check_in_candidates":
                [{"friend_id", "username", "profile_photo_url": str | None,
                "days_since_contact": int | None}, ...]}``. `friends_active`
                is ordered by `last_active_at` descending (friends with no
                tracked activity sort last). `activity_type` is the friend's
                `last_activity_type` (one of activity.py's NOTE_CREATED/
                NOTE_EDITED/NOTE_REPLIED/VERSE_HIGHLIGHTED, or None) so the
                client can pick per-type title wording without a second
                round trip. `check_in_candidates` is ordered
                longest-since-contact first, capped at `CHECK_IN_POOL_SIZE`
                entries (or the friend count, whichever is smaller), and is
                an empty list only when the user has no friends; a
                candidate's `days_since_contact` is None when that pair has
                never messaged directly (still a valid, arguably stronger,
                nudge candidate -- it sorts as if "longest ago").
        """
        self.cur.execute(
            "SELECT uf.friend_id, u.username, u.profile_photo_key, ua.last_activity_at, ua.last_activity_type, "
            "n._id, n.title, n.text, n.timestamp, "
            "h.key, h.color, h.timestamp "
            "FROM user_friends uf "
            "JOIN users u ON u._id = uf.friend_id "
            "LEFT JOIN user_activity ua ON ua.user_id = uf.friend_id "
            "LEFT JOIN LATERAL ("
            "  SELECT _id, title, text, timestamp FROM notes "
            "  WHERE user_id = uf.friend_id AND is_reply = FALSE "
            "    AND group_id IS NOT NULL "
            "    AND EXISTS ("
            "      SELECT 1 FROM groups g "
            "      WHERE g._id = notes.group_id AND uf.user_id::text = ANY(g.users)"
            "    ) "
            "  ORDER BY timestamp DESC LIMIT 1"
            ") n ON TRUE "
            "LEFT JOIN LATERAL ("
            "  SELECT key, color, timestamp FROM highlights "
            "  WHERE user_id = uf.friend_id "
            "  ORDER BY timestamp DESC LIMIT 1"
            ") h ON TRUE "
            "WHERE uf.user_id = %s "
            "AND NOT EXISTS ("
            "  SELECT 1 FROM blocked_users b "
            "  WHERE (b.blocker_id = uf.friend_id AND b.blocked_id = uf.user_id) "
            "     OR (b.blocker_id = uf.user_id AND b.blocked_id = uf.friend_id)"
            ") "
            "ORDER BY ua.last_activity_at DESC NULLS LAST "
            "LIMIT %s",
            (self.user_id, limit),
        )
        friends_active = []
        for r in self.cur.fetchall():
            (friend_id, username, profile_photo_key, last_active_at, last_activity_type,
             note_id, note_title, note_text, note_ts,
             h_key, h_color, h_ts) = r
            highlight_preview = None
            if h_key:
                parsed = parse_highlight_key(h_key)
                if parsed:
                    book, chapter, verse = parsed
                    highlight_preview = {
                        "book": book,
                        "chapter": chapter,
                        "verse": verse,
                        "color": h_color,
                        "verse_text": verse_text(book, chapter, verse),
                        "timestamp": str(h_ts) if h_ts else None,
                    }
            friends_active.append({
                "friend_id": str(friend_id),
                "username": username,
                "profile_photo_url": generate_download_url(profile_photo_key),
                "last_active_at": str(last_active_at) if last_active_at else None,
                "activity_type": last_activity_type,
                "note_preview": (
                    {"note_id": str(note_id), "title": note_title, "text": note_text, "timestamp": str(note_ts)}
                    if note_id else None
                ),
                "highlight_preview": highlight_preview,
            })

        self.cur.execute(
            "SELECT uf.friend_id, u.username, u.profile_photo_key, "
            "  (SELECT MAX(m.timestamp) FROM messages m "
            "   JOIN message_recipients mr ON mr.message_id = m._id "
            "   WHERE m.group_id IS NULL "
            "     AND ((m.from_user = uf.user_id AND mr.user_id = uf.friend_id) "
            "       OR (m.from_user = uf.friend_id AND mr.user_id = uf.user_id))"
            "  ) AS last_contact "
            "FROM user_friends uf "
            "JOIN users u ON u._id = uf.friend_id "
            "WHERE uf.user_id = %s "
            "AND NOT EXISTS ("
            "  SELECT 1 FROM blocked_users b "
            "  WHERE (b.blocker_id = uf.friend_id AND b.blocked_id = uf.user_id) "
            "     OR (b.blocker_id = uf.user_id AND b.blocked_id = uf.friend_id)"
            ") "
            "ORDER BY last_contact ASC NULLS FIRST "
            "LIMIT %s",
            (self.user_id, self.CHECK_IN_POOL_SIZE),
        )
        check_in_candidates = []
        for friend_id, username, profile_photo_key, last_contact in self.cur.fetchall():
            days_since_contact = None
            if last_contact:
                if last_contact.tzinfo is None:
                    last_contact = last_contact.replace(tzinfo=tzmod.utc)
                days_since_contact = (datetime.now(tzmod.utc) - last_contact).days
            check_in_candidates.append({
                "friend_id": str(friend_id),
                "username": username,
                "profile_photo_url": generate_download_url(profile_photo_key),
                "days_since_contact": days_since_contact,
            })

        return {"friends_active": friends_active, "check_in_candidates": check_in_candidates}

    def check_nudge_allowed(self, friend_id: str) -> dict:
        """Authorize a "nudge" push against ``friend_id`` and resolve their
        device token -- the read-only friendship/block/reachability half
        of ``POST /friends/{user_id}/{friend_id}/nudge``. The rate-limit
        window is deliberately NOT checked here anymore (see
        ``claim_nudge_slot`` below) -- call ``claim_nudge_slot`` next, and
        only proceed to send if it returns ``True``.

        Deny-by-default / fail-closed (Security Posture Q5/Q7/Q14): every
        branch below is a check that must actively pass, not a check that
        must actively fail, to allow the nudge -- an unresolved case (not
        found, blocked, no token, no query rows) always denies.

        Friendship + block state is re-checked here directly against
        ``user_friends``/``blocked_users`` (the same defense-in-depth
        ``NOT EXISTS`` predicate as ``ActivityManager.friend_device_tokens``
        and ``get_friend_activity`` above) rather than trusted from
        whatever candidate list the client is calling from -- this
        subsystem has prior IDOR history.

        "Not a friend" and "blocked" are deliberately merged into one
        ``not_friends`` reason (never distinguished) -- same
        enumeration-avoidance reasoning as ``read_friend``'s merged 404 for
        "not found" vs. "blocked": a caller probing arbitrary ``friend_id``
        values must not be able to learn which case applies, or that the
        id even resolves to a real user.

        Args:
            friend_id: UUID of the intended nudge recipient.

        Returns:
            dict: ``{"token": str}`` on success. On denial:
                ``{"error": str, "reason": "not_friends" | "unreachable"}``
                -- ``"not_friends"`` covers not-a-friend and blocked
                (either direction); ``"unreachable"`` means the friendship
                is valid but the recipient has no registered device token.
                Rate-limit denial ("rate_limited") is now signalled by
                ``claim_nudge_slot`` returning ``False``, not by this
                method.
        """
        self.cur.execute(
            "SELECT dt.token FROM user_friends uf "
            "JOIN device_tokens dt ON dt.user_id = uf.friend_id "
            "WHERE uf.user_id = %s AND uf.friend_id = %s "
            "AND NOT EXISTS ("
            "  SELECT 1 FROM blocked_users b "
            "  WHERE (b.blocker_id = uf.friend_id AND b.blocked_id = uf.user_id) "
            "     OR (b.blocker_id = uf.user_id AND b.blocked_id = uf.friend_id)"
            ")",
            (self.user_id, friend_id),
        )
        row = self.cur.fetchone()
        if row is None:
            # Distinguish "not a valid, unblocked friendship" from "valid
            # friendship but no device token" -- same block-respecting
            # predicate, minus the device_tokens join.
            self.cur.execute(
                "SELECT 1 FROM user_friends uf "
                "WHERE uf.user_id = %s AND uf.friend_id = %s "
                "AND NOT EXISTS ("
                "  SELECT 1 FROM blocked_users b "
                "  WHERE (b.blocker_id = uf.friend_id AND b.blocked_id = uf.user_id) "
                "     OR (b.blocker_id = uf.user_id AND b.blocked_id = uf.friend_id)"
                ")",
                (self.user_id, friend_id),
            )
            if self.cur.fetchone() is None:
                return {"error": "Cannot nudge this user", "reason": "not_friends"}
            return {"error": "This friend can't be reached right now", "reason": "unreachable"}
        token = row[0]

        return {"token": token}

    def claim_nudge_slot(self, friend_id: str) -> bool:
        """Atomically check-and-claim the (sender, recipient) rate-limit
        window in a single round trip -- security bounce on task
        20260906-friend-nudges: the original shape (a separate
        ``SELECT ... friend_nudges`` read here, followed by a later
        ``mark_nudge_sent`` upsert only after the push sent) was two
        unsynchronized DB round trips, so concurrent requests for the
        same pair could each read the window as open before either one
        recorded a claim, bypassing the "exactly 1 per
        (sender, recipient) per NUDGE_RATE_LIMIT_HOURS" limit entirely.

        Must be called -- and must return ``True`` -- BEFORE the push is
        sent, never after: the single ``INSERT ... ON CONFLICT ... WHERE
        ... RETURNING`` below takes Postgres's own row lock on the
        conflicting ``(sender_id, recipient_id)`` row while evaluating
        the window guard, so two concurrent callers for the same pair
        serialize on that lock instead of both observing "window open" --
        the second one to actually run the check (after the first
        commits) re-evaluates the guard against the now-fresh
        ``last_nudged_at`` and correctly loses the claim. Call
        ``release_nudge_claim`` afterward if the send itself then fails,
        so a failed send doesn't consume the sender's window for nothing
        -- same "don't burn the window on a failure" guarantee the prior
        ``mark_nudge_sent`` documented, now implemented as an explicit
        claim/release pair instead of a call ordered after the send
        (mirrors ``AgentManager._claim_last_fired`` /
        ``_unset_last_fired``'s claim-then-external-call-then-conditional
        -unwind shape for the same "atomic claim, external call, unwind
        the claim only on failure" pattern).

        Returns:
            bool: ``True`` if this call claimed the slot (no prior claim
                for this pair, or the prior claim's ``last_nudged_at`` is
                already older than ``NUDGE_RATE_LIMIT_HOURS``) -- the
                caller may proceed to send. ``False`` if an existing
                claim is still within the window -- the caller must deny
                with reason ``"rate_limited"`` and must NOT send.
        """
        self.cur.execute(
            "INSERT INTO friend_nudges (sender_id, recipient_id, last_nudged_at) "
            "VALUES (%s, %s, NOW()) "
            "ON CONFLICT (sender_id, recipient_id) DO UPDATE "
            "SET last_nudged_at = NOW() "
            "WHERE friend_nudges.last_nudged_at < NOW() - (%s * INTERVAL '1 hour') "
            "RETURNING sender_id",
            (self.user_id, friend_id, NUDGE_RATE_LIMIT_HOURS),
        )
        claimed = self.cur.fetchone() is not None
        self.conn.commit()
        return claimed

    def release_nudge_claim(self, friend_id: str) -> None:
        """Undo a winning ``claim_nudge_slot`` call after the push send
        itself failed (raised, or returned a non-delivery result), so the
        sender's rate-limit window isn't consumed for a nudge that never
        actually reached the recipient.

        Only ever safe to call on behalf of a request that already knows
        IT won the claim (``claim_nudge_slot`` returned ``True``) --
        unconditional here for the same reason
        ``AgentManager._unset_last_fired`` is: a caller reaching this
        point necessarily won its own claim first, so there is no other
        legitimate claim on this exact ``(sender_id, recipient_id)`` pair
        to accidentally erase. Deletes the row outright rather than
        restoring some prior timestamp -- a claimed row's prior value, by
        construction, was already outside the rate-limit window (or
        didn't exist), so "gone entirely" is equivalent to "not recently
        nudged" for the next attempt.

        Best-effort/non-fatal on failure -- the push already failed by
        the time this is called, so a further error here must not mask
        that original failure. Mirrors ``_unset_last_fired``'s own
        try/except-and-log shape; a real DB error is still visible via
        this log line.
        """
        try:
            self.cur.execute(
                "DELETE FROM friend_nudges WHERE sender_id = %s AND recipient_id = %s",
                (self.user_id, friend_id),
            )
            self.conn.commit()
        except Exception as e:
            logger.error(
                "Failed to release nudge claim sender=%s recipient=%s: %s",
                self.user_id, friend_id, e,
            )
            self.conn.rollback()
