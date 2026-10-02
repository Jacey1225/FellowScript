"""Admin user listing and admin-role grant/revoke (task 20261002-admin-user-actions).

Role changes run in one transaction serialized by a transaction-scoped
advisory lock, so the "last admin" and "actor still admin" checks cannot race
with a concurrent change. The audit row is written in the same transaction.
Failures raise ``AdminUsersError`` (carrying an HTTP status and a stable code);
nothing is fabricated or swallowed.
"""
from __future__ import annotations

from db import DBManager

# Arbitrary fixed key for pg_advisory_xact_lock; serializes all role changes.
_ROLE_LOCK_KEY = 20261002


class AdminUsersError(Exception):
    def __init__(self, status: int, code: str, detail: str):
        super().__init__(detail)
        self.status = status
        self.code = code
        self.detail = detail


def escape_like(term: str) -> str:
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


class AdminUsersManager(DBManager):
    def list_users(self, search: str | None, limit: int, offset: int) -> tuple[list[dict], int]:
        """Return (page, total). Only id, username, email and is_admin are
        selected; ordered by username then _id for a stable page order."""
        where, params = "", []
        if search:
            where = "WHERE username ILIKE %s ESCAPE '\\' OR email ILIKE %s ESCAPE '\\'"
            pat = f"%{escape_like(search)}%"
            params = [pat, pat]
        self.cur.execute(f"SELECT COUNT(*) FROM users {where}", params)
        total = self.cur.fetchone()[0]
        self.cur.execute(
            f"SELECT _id, username, email, is_admin FROM users {where} "
            "ORDER BY username ASC, _id ASC LIMIT %s OFFSET %s",
            params + [limit, offset],
        )
        rows = [
            {"id": str(r[0]), "username": r[1], "email": r[2], "is_admin": bool(r[3])}
            for r in self.cur.fetchall()
        ]
        self.conn.rollback()  # read-only; end the implicit transaction
        return rows, total

    def set_admin(self, actor_id: str, target_id: str, make_admin: bool) -> dict:
        """Grant or revoke admin for ``target_id``. Returns
        ``{"id", "is_admin", "changed"}``; ``changed`` is False for a no-op."""
        try:
            self.cur.execute("SELECT pg_advisory_xact_lock(%s)", (_ROLE_LOCK_KEY,))
            self.cur.execute("SELECT is_admin FROM users WHERE _id = %s FOR UPDATE", (actor_id,))
            actor = self.cur.fetchone()
            if not actor or not actor[0]:
                raise AdminUsersError(403, "not_admin", "Admin access required")
            self.cur.execute("SELECT is_admin FROM users WHERE _id = %s FOR UPDATE", (target_id,))
            target = self.cur.fetchone()
            if not target:
                raise AdminUsersError(404, "user_not_found", "User not found")
            current = bool(target[0])
            if not make_admin:
                if target_id == actor_id:
                    raise AdminUsersError(409, "cannot_revoke_self", "You cannot revoke your own admin role")
                if current:
                    self.cur.execute("SELECT COUNT(*) FROM users WHERE is_admin")
                    if self.cur.fetchone()[0] <= 1:
                        raise AdminUsersError(409, "last_admin", "Cannot revoke the last remaining admin")
            if current == make_admin:
                self.conn.rollback()
                return {"id": target_id, "is_admin": current, "changed": False}
            self.cur.execute("UPDATE users SET is_admin = %s WHERE _id = %s", (make_admin, target_id))
            self.cur.execute(
                "INSERT INTO admin_role_audit (actor_user_id, target_user_id, action, previous_value, new_value) "
                "VALUES (%s, %s, %s, %s, %s)",
                (actor_id, target_id, "grant" if make_admin else "revoke", current, make_admin),
            )
            self.conn.commit()
            return {"id": target_id, "is_admin": make_admin, "changed": True}
        except BaseException:
            self.conn.rollback()
            raise
