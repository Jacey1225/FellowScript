"""Activity tracking for the fixed-notification system.

Replaces the removed agentic/custom notification subsystem (see
.claude/pipeline/20260826-activity-based-notifications). No user-authored
state and no API surface: `record_activity` is called internally from the
note/highlight create paths (routes/notes.py), and the read-side methods
below back the three fixed scheduled jobs in
backend/interactions/scheduler.py (midday no-activity reminder, >24h guilt
reminder, friend-went-active cross-user notification).
"""

import logging
from datetime import date, datetime, timedelta, timezone as tzmod

from db import DBManager

logger = logging.getLogger(__name__)

# A user counts as having "gone inactive" once this long has passed since
# their last tracked activity (note or highlight creation). Both the >24h
# guilt reminder and the inactive→active transition detector key off the
# same threshold, so "you were inactive" and "you just went active" describe
# the same state boundary from either side.
INACTIVITY_THRESHOLD = timedelta(hours=24)

# Closed set of activity-type labels persisted on `user_activity.
# last_activity_type`, used only to pick action-specific wording in
# scheduler.py::_friend_went_active_notify. A reply (post_reply) folds into
# NOTE_CREATED rather than getting its own type -- nothing distinguishes how
# a friend should read "posted a note" vs. "replied to a note" today, and a
# 4th concrete type (e.g. a distinct reply wording) is easy to add to this
# set later if that changes. Deliberately just these three plain strings,
# not a speculative generic templating/i18n system.
NOTE_CREATED = "note_created"
NOTE_EDITED = "note_edited"
VERSE_HIGHLIGHTED = "verse_highlighted"


class ActivityManager(DBManager):
    """Reads/writes `user_activity` — no `__init__` override needed since
    every method here takes the relevant user_id(s) as a parameter rather
    than operating on one fixed acting user (Style B in the manager
    convention, matching DevotionManager)."""

    # ── Write path (called from note/highlight creation) ───────────────────

    def record_activity(
        self, user_id: str, activity_type: str | None = None, now: datetime | None = None
    ) -> None:
        """Bump `last_activity_at` for user_id; mark a transition if they
        were inactive (no prior row, or prior activity older than
        INACTIVITY_THRESHOLD).

        A transition resets the midday/guilt reminder dedup markers (a fresh
        activity window has started) and nulls `friend_notified_at`, which
        queues `_friend_went_active_notify` to broadcast it once.

        `activity_type` (one of NOTE_CREATED / NOTE_EDITED / VERSE_HIGHLIGHTED,
        or None) is persisted to `last_activity_type` on every call, not just
        on a transition, so it always reflects the most recent activity --
        `_friend_went_active_notify` reads it to compose action-specific push
        text. Left optional (default None) rather than required so call
        sites/tests that only care about the transition/dedup semantics
        aren't forced to supply one; a None or unrecognized value just means
        the notification falls back to generic text, it never fails the write.
        """
        now = now or datetime.now(tzmod.utc)
        self.cur.execute(
            "SELECT last_activity_at FROM user_activity WHERE user_id = %s",
            (user_id,),
        )
        row = self.cur.fetchone()
        prev = row[0] if row else None
        went_active = prev is None or (now - prev) > INACTIVITY_THRESHOLD

        try:
            if went_active:
                self.cur.execute(
                    "INSERT INTO user_activity "
                    "(user_id, last_activity_at, became_active_at, "
                    " friend_notified_at, midday_reminder_sent_date, guilt_reminder_sent_at, "
                    " last_activity_type) "
                    "VALUES (%s, %s, %s, NULL, NULL, NULL, %s) "
                    "ON CONFLICT (user_id) DO UPDATE SET "
                    "last_activity_at = EXCLUDED.last_activity_at, "
                    "became_active_at = EXCLUDED.became_active_at, "
                    "friend_notified_at = NULL, "
                    "midday_reminder_sent_date = NULL, "
                    "guilt_reminder_sent_at = NULL, "
                    "last_activity_type = EXCLUDED.last_activity_type",
                    (user_id, now, now, activity_type),
                )
            else:
                self.cur.execute(
                    "INSERT INTO user_activity (user_id, last_activity_at, last_activity_type) "
                    "VALUES (%s, %s, %s) "
                    "ON CONFLICT (user_id) DO UPDATE SET "
                    "last_activity_at = EXCLUDED.last_activity_at, "
                    "last_activity_type = EXCLUDED.last_activity_type",
                    (user_id, now, activity_type),
                )
            self.conn.commit()
        except Exception as e:
            logger.error("Error recording activity for %s: %s", user_id, e)
            self.conn.rollback()

    # ── Read path (scheduler jobs) ──────────────────────────────────────────

    def users_with_tokens(self) -> list[tuple]:
        """(user_id, timezone, last_activity_at, midday_reminder_sent_date,
        guilt_reminder_sent_at, device_token) for every user who has a
        registered device token — no token means no push is possible, so
        skip them entirely rather than doing per-job window math for nothing.
        `user_activity` is left-joined since a user with no tracked activity
        yet still has a row here (all fields NULL).
        """
        self.cur.execute(
            "SELECT u._id, u.timezone, ua.last_activity_at, "
            "ua.midday_reminder_sent_date, ua.guilt_reminder_sent_at, dt.token "
            "FROM users u "
            "JOIN device_tokens dt ON dt.user_id = u._id "
            "LEFT JOIN user_activity ua ON ua.user_id = u._id"
        )
        return self.cur.fetchall()

    def mark_midday_sent(self, user_id: str, local_date: date) -> None:
        self.cur.execute(
            "INSERT INTO user_activity (user_id, midday_reminder_sent_date) "
            "VALUES (%s, %s) "
            "ON CONFLICT (user_id) DO UPDATE SET midday_reminder_sent_date = EXCLUDED.midday_reminder_sent_date",
            (user_id, local_date),
        )
        self.conn.commit()

    def mark_guilt_sent(self, user_id: str, when: datetime) -> None:
        self.cur.execute(
            "INSERT INTO user_activity (user_id, guilt_reminder_sent_at) "
            "VALUES (%s, %s) "
            "ON CONFLICT (user_id) DO UPDATE SET guilt_reminder_sent_at = EXCLUDED.guilt_reminder_sent_at",
            (user_id, when),
        )
        self.conn.commit()

    def pending_friend_notifications(self) -> list[tuple]:
        """(user_id, username, became_active_at, last_activity_type) for
        every user whose most recent inactive→active transition hasn't been
        broadcast to friends yet. last_activity_type lets the caller compose
        action-specific text without a second query; it may be NULL (pre-
        migration row, or a write that didn't pass a recognized type)."""
        self.cur.execute(
            "SELECT u._id, u.username, ua.became_active_at, ua.last_activity_type "
            "FROM user_activity ua "
            "JOIN users u ON u._id = ua.user_id "
            "WHERE ua.became_active_at IS NOT NULL AND ua.friend_notified_at IS NULL"
        )
        return self.cur.fetchall()

    def friend_device_tokens(self, user_id: str) -> list[tuple]:
        """(friend_id, token) for user_id's friends with a registered device
        token, excluding either direction of a block. Defense in depth
        alongside BlockManager.block_user already severing the user_friends
        rows both ways on block — this subsystem has prior IDOR history, so
        the friend-went-active job re-checks blocks itself rather than
        trusting the friendship table alone.
        """
        self.cur.execute(
            "SELECT uf.friend_id, dt.token FROM user_friends uf "
            "JOIN device_tokens dt ON dt.user_id = uf.friend_id "
            "WHERE uf.user_id = %s "
            "AND NOT EXISTS ("
            "  SELECT 1 FROM blocked_users b "
            "  WHERE (b.blocker_id = uf.friend_id AND b.blocked_id = uf.user_id) "
            "     OR (b.blocker_id = uf.user_id AND b.blocked_id = uf.friend_id)"
            ")",
            (user_id,),
        )
        return self.cur.fetchall()

    def friend_device_tokens_bulk(self, user_ids: list[str]) -> list[tuple]:
        """(user_id, friend_id, token) for every user in ``user_ids``' friends
        with a registered device token, excluding either direction of a
        block — same predicate as ``friend_device_tokens`` but batched with
        one ``ANY(%s)`` query instead of one call per transitioning user, for
        callers (e.g. ``_friend_went_active_notify``) that process a whole
        pending set at once.
        """
        if not user_ids:
            return []
        self.cur.execute(
            "SELECT uf.user_id, uf.friend_id, dt.token FROM user_friends uf "
            "JOIN device_tokens dt ON dt.user_id = uf.friend_id "
            "WHERE uf.user_id = ANY(%s::uuid[]) "
            "AND NOT EXISTS ("
            "  SELECT 1 FROM blocked_users b "
            "  WHERE (b.blocker_id = uf.friend_id AND b.blocked_id = uf.user_id) "
            "     OR (b.blocker_id = uf.user_id AND b.blocked_id = uf.friend_id)"
            ")",
            (list(user_ids),),
        )
        return self.cur.fetchall()

    def mark_friends_notified(self, user_id: str, became_active_at: datetime) -> None:
        """Marks the transition notified only if it's still the same
        transition read by pending_friend_notifications() — guards against
        clobbering a newer transition's NULL marker if the user went
        inactive→active again while this job was mid-run."""
        self.cur.execute(
            "UPDATE user_activity SET friend_notified_at = %s "
            "WHERE user_id = %s AND became_active_at = %s",
            (datetime.now(tzmod.utc), user_id, became_active_at),
        )
        self.conn.commit()
