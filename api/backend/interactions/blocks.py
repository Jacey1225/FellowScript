from db import DBManager
from backend.errors import SaveFailedError
from backend.interactions.reports import ReportsManager


class BlockManager(DBManager):
    """Guideline 1.2 block mechanism: severs contact both directions and
    files an automatic report so there's one unified developer queue instead
    of a parallel notification system."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = user_id

    def block_user(self, blocked_id: str) -> dict | None:
        if blocked_id == self.user_id:
            return {"error": "Cannot block yourself"}
        if not self.insertion("blocked_users", {"blocker_id": self.user_id, "blocked_id": blocked_id}):
            raise SaveFailedError()
        # Sever any existing friendship/pending request both ways — otherwise a
        # blocked "friend" would still surface via user_friends-keyed views.
        # Best-effort/idempotent: neither relationship is guaranteed to
        # exist (they may never have been friends), so a zero-rows False
        # here is not treated as failure -- a real DB error is still
        # visible via db.py's DB_WRITE_FAILURE log line.
        self.delete("user_friends", {"user_id": self.user_id, "friend_id": blocked_id})
        self.delete("user_friends", {"user_id": blocked_id, "friend_id": self.user_id})
        self.delete("friend_requests", {"to_user_id": self.user_id, "from_user_id": blocked_id})
        self.delete("friend_requests", {"to_user_id": blocked_id, "from_user_id": self.user_id})

        reports = ReportsManager(self.user_id)
        try:
            reports.create_report("user", None, blocked_id, "blocked", "User blocked another user.")
        finally:
            reports.close()
        return None

    def unblock_user(self, blocked_id: str) -> None:
        # Idempotent: unblocking someone not currently blocked is a no-op,
        # not a failure -- a real DB error is still visible via db.py's
        # DB_WRITE_FAILURE log line.
        self.delete("blocked_users", {"blocker_id": self.user_id, "blocked_id": blocked_id})

    def is_blocked(self, other_id: str) -> bool:
        """True if EITHER direction has blocked the other."""
        self.cur.execute(
            "SELECT 1 FROM blocked_users WHERE (blocker_id=%s AND blocked_id=%s) OR (blocker_id=%s AND blocked_id=%s)",
            (self.user_id, other_id, other_id, self.user_id),
        )
        return self.cur.fetchone() is not None

    def list_blocked(self) -> list[dict]:
        self.cur.execute(
            "SELECT u._id, u.username FROM users u JOIN blocked_users b ON u._id = b.blocked_id "
            "WHERE b.blocker_id = %s",
            (self.user_id,),
        )
        return [{"user_id": str(r[0]), "username": r[1]} for r in self.cur.fetchall()]
