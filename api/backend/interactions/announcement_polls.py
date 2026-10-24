"""Polls inside group announcements (task 20261024-announcement-polls).

``normalize_poll`` is a pure validator (no DB). ``PollsMixin`` adds the poll
reads and writes to ``AnnouncementsManager`` (it relies on that class's
``cur``, ``conn``, ``user_id``, ``group_id`` and ``_blocked_set``).

Rules: members only (the caller is verified before any method here runs); one
poll per announcement; 2-6 options; single choice unless the poll allows
several answers; votes are anonymous (only counts are ever returned, plus the
caller's own selection); a vote replaces the caller's previous selection; a
closed poll keeps its results and takes no new votes. Votes from people who
have left the group are not counted. Every write that touches votes locks the
poll row (FOR UPDATE) so concurrent votes cannot break the single-choice or
option-count rules. Everything is deny-by-default 404 while the flag is off.
"""

import re
import unicodedata
import uuid
from datetime import datetime, timedelta, timezone

from backend.errors import SaveFailedError
from backend.interactions import flags

POLLS_FLAG = "announcement_polls"
MIN_OPTIONS = 2
MAX_OPTIONS = 6
MAX_QUESTION_LENGTH = 200
MAX_OPTION_LENGTH = 80
MAX_HORIZON_DAYS = 365

_BAD_CHARS = re.compile(r"[\x00-\x08\x0b-\x1f\x7f‪-‮⁦-⁩​-‏]")


class PollNotFound(Exception):
    """No votable poll for this announcement (404)."""


class PollClosed(Exception):
    """The poll has closed (409)."""


class PollForbidden(Exception):
    """Caller may not change or close this poll (403)."""


def _line(value, field: str, limit: int) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be text")
    text = unicodedata.normalize("NFC", value).strip()
    text = re.sub(r"\s+", " ", text)
    if not text:
        raise ValueError(f"{field} can't be blank")
    if len(text) > limit:
        raise ValueError(f"{field} can be at most {limit} characters")
    if _BAD_CHARS.search(text):
        raise ValueError(f"{field} has characters that aren't allowed")
    return text


def normalize_poll(raw, now: datetime | None = None) -> dict:
    """Validate a poll definition: ``{"question", "options": [str], "multiple": bool,
    "closes_at": ISO str | None}``. Returns ``{"question", "options", "multiple",
    "closes_at": datetime | None}``. Raises ValueError; never repairs bad input."""
    if not isinstance(raw, dict):
        raise ValueError("poll must be an object")
    extra = set(raw) - {"question", "options", "multiple", "closes_at"}
    if extra:
        raise ValueError("poll has unknown fields")
    question = _line(raw.get("question"), "question", MAX_QUESTION_LENGTH)
    options_in = raw.get("options")
    if not isinstance(options_in, list):
        raise ValueError("options must be a list")
    if not MIN_OPTIONS <= len(options_in) <= MAX_OPTIONS:
        raise ValueError(f"a poll needs {MIN_OPTIONS} to {MAX_OPTIONS} options")
    options = [_line(o, "option", MAX_OPTION_LENGTH) for o in options_in]
    if len({o.casefold() for o in options}) != len(options):
        raise ValueError("options must be different from each other")
    multiple = raw.get("multiple", False)
    if not isinstance(multiple, bool):
        raise ValueError("multiple must be true or false")
    closes_at = raw.get("closes_at")
    if closes_at is not None:
        if not isinstance(closes_at, str):
            raise ValueError("closes_at must be an ISO-8601 time")
        try:
            closes_at = datetime.fromisoformat(closes_at.replace("Z", "+00:00"))
        except ValueError:
            raise ValueError("closes_at must be an ISO-8601 time")
        if closes_at.tzinfo is None:
            raise ValueError("closes_at needs a time zone offset")
        now = now or datetime.now(timezone.utc)
        if closes_at <= now:
            raise ValueError("closes_at must be in the future")
        if closes_at > now + timedelta(days=MAX_HORIZON_DAYS):
            raise ValueError(f"closes_at can be at most {MAX_HORIZON_DAYS} days ahead")
    return {"question": question, "options": options, "multiple": multiple, "closes_at": closes_at}


class PollsMixin:
    """Poll queries for ``AnnouncementsManager``."""

    def _polls_on(self) -> bool:
        return flags.is_enabled(POLLS_FLAG, self.user_id)

    # ── reads ─────────────────────────────────────────────────────────────

    def poll_summaries(self, ids: list[str]) -> dict[str, dict]:
        """``{announcement_id: poll}`` for the announcements that have one. Counts
        include only current group members. Never lists who voted."""
        if not ids or not self._polls_on():
            return {}
        self.cur.execute(
            "SELECT p.announcement_id, p.question, p.multiple, p.closes_at, p.closed_at "
            "FROM group_announcement_polls p WHERE p.announcement_id = ANY(%s::uuid[])",
            (ids,),
        )
        polls = {str(a): {"question": q, "multiple": bool(m), "closes_at": ca, "closed_at": cl}
                 for a, q, m, ca, cl in self.cur.fetchall()}
        if not polls:
            return {}
        pids = list(polls)
        self.cur.execute(
            "SELECT o.announcement_id, o._id, o.label, o.position, "
            "count(v.user_id) FILTER (WHERE v.user_id::text = ANY(g.users)), "
            "COALESCE(bool_or(v.user_id::text = %s) FILTER (WHERE v.user_id::text = ANY(g.users)), FALSE) "
            "FROM group_announcement_poll_options o "
            "JOIN group_announcements a ON a._id = o.announcement_id "
            "JOIN groups g ON g._id = a.group_id "
            "LEFT JOIN group_announcement_poll_votes v ON v.option_id = o._id "
            "WHERE o.announcement_id = ANY(%s::uuid[]) "
            "GROUP BY o.announcement_id, o._id, o.label, o.position, g.users ORDER BY o.announcement_id, o.position",
            (self.user_id, pids),
        )
        options: dict[str, list] = {}
        for aid, oid, label, pos, n, mine in self.cur.fetchall():
            options.setdefault(str(aid), []).append({"id": str(oid), "label": label, "votes": int(n), "mine": bool(mine)})
        self.cur.execute(
            "SELECT v.announcement_id, count(DISTINCT v.user_id) "
            "FROM group_announcement_poll_votes v "
            "JOIN group_announcements a ON a._id = v.announcement_id "
            "JOIN groups g ON g._id = a.group_id "
            "WHERE v.announcement_id = ANY(%s::uuid[]) AND v.user_id::text = ANY(g.users) "
            "GROUP BY v.announcement_id",
            (pids,),
        )
        voters = {str(a): int(n) for a, n in self.cur.fetchall()}
        now = datetime.now(timezone.utc)
        out = {}
        for aid, p in polls.items():
            opts = options.get(aid, [])
            total = voters.get(aid, 0)
            closed = p["closed_at"] is not None or (p["closes_at"] is not None and p["closes_at"] <= now)
            out[aid] = {
                "question": p["question"],
                "multiple": p["multiple"],
                "closes_at": p["closes_at"].isoformat() if p["closes_at"] else None,
                "closed": closed,
                "total_voters": total,
                "options": [{"id": o["id"], "label": o["label"], "votes": o["votes"],
                             "percent": round(100 * o["votes"] / total) if total else 0} for o in opts],
                "my_votes": [o["id"] for o in opts if o["mine"]],
            }
        return out

    def _poll_vote_count(self, announcement_id: str) -> int:
        self.cur.execute(
            "SELECT count(*) FROM group_announcement_poll_votes WHERE announcement_id = %s", (announcement_id,))
        return int(self.cur.fetchone()[0])

    # ── writes that ride on create/update (caller commits or rolls back) ──

    def _insert_poll(self, announcement_id: str, poll: dict) -> None:
        self.cur.execute(
            "INSERT INTO group_announcement_polls (announcement_id, question, multiple, closes_at) "
            "VALUES (%s, %s, %s, %s)",
            (announcement_id, poll["question"], poll["multiple"], poll["closes_at"]),
        )
        for i, label in enumerate(poll["options"]):
            self.cur.execute(
                "INSERT INTO group_announcement_poll_options (announcement_id, position, label) VALUES (%s, %s, %s)",
                (announcement_id, i, label),
            )

    def _apply_poll_edit(self, announcement_id: str, raw) -> None:
        """Edit rules: ``None`` removes the poll (and its votes); a poll object on an
        announcement without one adds it; on one with votes only the question and
        close time may change (options and multiple are locked); with no votes it
        is replaced. Raises ValueError (422) or PollNotFound (flag off)."""
        if not self._polls_on():
            raise PollNotFound()
        self.cur.execute(
            "SELECT question, multiple FROM group_announcement_polls WHERE announcement_id = %s FOR UPDATE",
            (announcement_id,))
        existing = self.cur.fetchone()
        if raw is None:
            if existing:
                self.cur.execute("DELETE FROM group_announcement_polls WHERE announcement_id = %s", (announcement_id,))
            return
        poll = normalize_poll(raw)
        if not existing:
            self._insert_poll(announcement_id, poll)
            return
        if self._poll_vote_count(announcement_id) == 0:
            self.cur.execute("DELETE FROM group_announcement_polls WHERE announcement_id = %s", (announcement_id,))
            self._insert_poll(announcement_id, poll)
            return
        self.cur.execute(
            "SELECT label FROM group_announcement_poll_options WHERE announcement_id = %s ORDER BY position",
            (announcement_id,))
        current = [r[0] for r in self.cur.fetchall()]
        if poll["options"] != current or poll["multiple"] != bool(existing[1]):
            raise ValueError("Options can't change once people have voted")
        self.cur.execute(
            "UPDATE group_announcement_polls SET question = %s, closes_at = %s WHERE announcement_id = %s",
            (poll["question"], poll["closes_at"], announcement_id))

    # ── voting ────────────────────────────────────────────────────────────

    def _poll_lock(self, announcement_id: str) -> tuple:
        """Lock the poll row and return ``(multiple, closes_at, closed_at, creator_id)``.
        Deny by default: flag off, no poll, deleted or scheduled announcement, wrong
        group, or an author in a block relationship with the caller all raise
        PollNotFound. The caller is already a verified member."""
        if not self._polls_on():
            raise PollNotFound()
        try:
            uuid.UUID(str(announcement_id))
        except ValueError:
            raise PollNotFound()
        self.cur.execute(
            "SELECT p.multiple, p.closes_at, p.closed_at, a.creator_id "
            "FROM group_announcement_polls p JOIN group_announcements a ON a._id = p.announcement_id "
            "WHERE p.announcement_id = %s AND a.group_id = %s AND a.deleted_at IS NULL "
            "AND a.publish_at <= now() FOR UPDATE OF p",
            (announcement_id, self.group_id),
        )
        row = self.cur.fetchone()
        if not row or (row[3] is not None and str(row[3]) in self._blocked_set()):
            self.conn.rollback()
            raise PollNotFound()
        return row

    @staticmethod
    def _is_closed(row: tuple) -> bool:
        return row[2] is not None or (row[1] is not None and row[1] <= datetime.now(timezone.utc))

    def poll_vote(self, announcement_id: str, option_ids: list[str]) -> None:
        """Replace the caller's selection. Idempotent. Raises PollNotFound,
        PollClosed, ValueError (bad options), SaveFailedError."""
        try:
            row = self._poll_lock(announcement_id)
            if self._is_closed(row):
                self.conn.rollback()
                raise PollClosed()
            if (not isinstance(option_ids, list) or not option_ids
                    or not all(isinstance(o, str) for o in option_ids)):
                self.conn.rollback()
                raise ValueError("Pick at least one option")
            try:
                wanted = {str(uuid.UUID(o)) for o in option_ids}
            except ValueError:
                self.conn.rollback()
                raise ValueError("Unknown option")
            if len(wanted) != len(option_ids) or (len(wanted) > 1 and not row[0]):
                self.conn.rollback()
                raise ValueError("This poll allows one answer" if not row[0] else "Duplicate options")
            self.cur.execute(
                "SELECT _id FROM group_announcement_poll_options WHERE announcement_id = %s", (announcement_id,))
            valid = {str(r[0]) for r in self.cur.fetchall()}
            if not wanted <= valid:
                self.conn.rollback()
                raise ValueError("Unknown option")
            self.cur.execute(
                "DELETE FROM group_announcement_poll_votes WHERE announcement_id = %s AND user_id = %s",
                (announcement_id, self.user_id))
            for oid in sorted(wanted):
                self.cur.execute(
                    "INSERT INTO group_announcement_poll_votes (option_id, announcement_id, user_id) VALUES (%s, %s, %s)",
                    (oid, announcement_id, self.user_id))
            self.conn.commit()
        except (PollNotFound, PollClosed, ValueError):
            raise
        except Exception:
            self.conn.rollback()
            raise SaveFailedError()

    def poll_retract(self, announcement_id: str) -> None:
        """Clear the caller's selection. Idempotent."""
        try:
            row = self._poll_lock(announcement_id)
            if self._is_closed(row):
                self.conn.rollback()
                raise PollClosed()
            self.cur.execute(
                "DELETE FROM group_announcement_poll_votes WHERE announcement_id = %s AND user_id = %s",
                (announcement_id, self.user_id))
            self.conn.commit()
        except (PollNotFound, PollClosed):
            raise
        except Exception:
            self.conn.rollback()
            raise SaveFailedError()

    def poll_close(self, announcement_id: str) -> None:
        """Close a poll now (announcement creator or group creator). Idempotent."""
        try:
            row = self._poll_lock(announcement_id)
            creator = str(row[3]) if row[3] else None
            if self.user_id != creator and self.user_id != self._group_creator_id():
                self.conn.rollback()
                raise PollForbidden()
            self.cur.execute(
                "UPDATE group_announcement_polls SET closed_at = COALESCE(closed_at, now()) WHERE announcement_id = %s",
                (announcement_id,))
            self.conn.commit()
        except (PollNotFound, PollForbidden):
            raise
        except Exception:
            self.conn.rollback()
            raise SaveFailedError()
