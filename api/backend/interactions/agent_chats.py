"""Multiple chats per (user, agent) (flag ``agent_chats``).

``AgentChatStore`` wraps an open ``AgentManager`` connection. Every method is
scoped to ``db.user_id`` and every chat lookup re-checks the chat belongs to
BOTH the caller and the named agent, so a guessed chat id never reads or
writes another user's (or another agent's) chat. Callers must have confirmed
``owns_agent(agent_id)`` first. Unknown or unowned ids resolve to ``None``
(the route answers 404); nothing is ever created or substituted on a miss.

Legacy rows (``agent_messages.chat_id IS NULL``) are adopted into one
deterministic default chat per (user, agent) the first time it is needed.

Never logs message content or titles: ids only.
"""
from __future__ import annotations

import logging
import uuid
from typing import Optional

import psycopg2

from backend.errors import SaveFailedError
from backend.interactions.agent_chats_config import get_agent_chats_config

logger = logging.getLogger(__name__)

_DEFAULT_NS = uuid.UUID("6f1d3a52-0c43-4e0e-9d57-5d1b7a0c9a11")
_COLS = "_id, title, created_at, last_message_at"


class ChatLimitError(Exception):
    """The agent already has ``max_chats_per_agent`` chats."""


def default_chat_id(user_id: str, agent_id: str) -> str:
    return str(uuid.uuid5(_DEFAULT_NS, f"{user_id}:{agent_id}"))


def valid_uuid(value) -> bool:
    try:
        uuid.UUID(str(value))
        return True
    except (ValueError, AttributeError, TypeError):
        return False


def make_title(text: str) -> str:
    return " ".join(text.split())[: get_agent_chats_config().auto_title_length]


def _row(r) -> dict:
    return {
        "id": str(r[0]),
        "title": r[1] or "",
        "created_at": r[2].isoformat() if r[2] else None,
        "last_message_at": r[3].isoformat() if r[3] else None,
    }


class AgentChatStore:
    def __init__(self, db):
        self.db = db
        self.user_id = db.user_id

    def _fail(self, op: str, e: Exception):
        self.db.conn.rollback()
        logger.error("DB_WRITE_FAILURE op=%s table=agent_chats error=%s", op, type(e).__name__)
        raise SaveFailedError()

    def ensure_default_chat(self, agent_id: str) -> str:
        """Create the default chat if missing and adopt legacy NULL rows. Idempotent."""
        cid = default_chat_id(self.user_id, agent_id)
        cur = self.db.cur
        try:
            cur.execute(
                "SELECT MIN(timestamp), MAX(timestamp) FROM agent_messages "
                "WHERE user_id = %s AND agent_id = %s AND chat_id IS NULL",
                (self.user_id, agent_id),
            )
            first_ts, last_ts = cur.fetchone()
            cur.execute(
                "INSERT INTO agent_chats (_id, user_id, agent_id, title, created_at, last_message_at) "
                "VALUES (%s, %s, %s, COALESCE((SELECT LEFT(content, %s) FROM agent_messages "
                "WHERE user_id = %s AND agent_id = %s AND chat_id IS NULL AND title = 'user' "
                "ORDER BY timestamp LIMIT 1), ''), COALESCE(%s, NOW()), COALESCE(%s, NOW())) "
                "ON CONFLICT (_id) DO NOTHING",
                (cid, self.user_id, agent_id, get_agent_chats_config().auto_title_length,
                 self.user_id, agent_id, first_ts, last_ts),
            )
            if last_ts is not None:
                cur.execute(
                    "UPDATE agent_messages SET chat_id = %s "
                    "WHERE user_id = %s AND agent_id = %s AND chat_id IS NULL",
                    (cid, self.user_id, agent_id),
                )
                cur.execute(
                    "UPDATE agent_chats SET last_message_at = GREATEST(last_message_at, %s) "
                    "WHERE _id = %s AND user_id = %s AND agent_id = %s",
                    (last_ts, cid, self.user_id, agent_id),
                )
            self.db.conn.commit()
        except psycopg2.Error as e:
            self._fail("ensure_default", e)
        return cid

    def list_chats(self, agent_id: str) -> list[dict]:
        self.ensure_default_chat(agent_id)
        cur = self.db.cur
        try:
            cur.execute(
                f"SELECT {_COLS} FROM agent_chats WHERE user_id = %s AND agent_id = %s "
                "ORDER BY last_message_at DESC, _id DESC",
                (self.user_id, agent_id),
            )
            rows = cur.fetchall()
        except psycopg2.Error:
            self.db.conn.rollback()
            raise
        return [_row(r) for r in rows]

    def create_chat(self, agent_id: str) -> dict:
        self.ensure_default_chat(agent_id)
        cur = self.db.cur
        try:
            cur.execute(
                "SELECT COUNT(*) FROM agent_chats WHERE user_id = %s AND agent_id = %s",
                (self.user_id, agent_id),
            )
            if cur.fetchone()[0] >= get_agent_chats_config().max_chats_per_agent:
                self.db.conn.rollback()
                raise ChatLimitError()
            cur.execute(
                f"INSERT INTO agent_chats (user_id, agent_id) VALUES (%s, %s) RETURNING {_COLS}",
                (self.user_id, agent_id),
            )
            row = cur.fetchone()
            self.db.conn.commit()
        except psycopg2.Error as e:
            self._fail("insert", e)
        return _row(row)

    def get_chat(self, agent_id: str, chat_id: str) -> Optional[dict]:
        """The chat iff it belongs to (caller, agent); otherwise None."""
        if not valid_uuid(chat_id):
            return None
        cur = self.db.cur
        try:
            cur.execute(
                f"SELECT {_COLS} FROM agent_chats WHERE _id = %s AND user_id = %s AND agent_id = %s",
                (str(uuid.UUID(str(chat_id))), self.user_id, agent_id),
            )
            row = cur.fetchone()
        except psycopg2.Error:
            self.db.conn.rollback()
            raise
        return _row(row) if row else None

    def resolve(self, agent_id: str, chat_id: Optional[str]) -> Optional[str]:
        """Absent/empty chat_id -> the default chat (legacy clients); a given
        chat_id must be owned or the result is None (fail closed)."""
        if not chat_id:
            return self.ensure_default_chat(agent_id)
        chat = self.get_chat(agent_id, chat_id)
        return chat["id"] if chat else None

    def get_messages(self, agent_id: str, chat_id: str) -> dict:
        return self.db.lookup(
            self.db.msg_table,
            {"agent_id": agent_id, "user_id": self.user_id, "chat_id": chat_id},
        )

    def touch(self, agent_id: str, chat_id: str, first_user_text: Optional[str] = None) -> None:
        """Bump last_message_at; set the auto-title if still blank."""
        try:
            self.db.cur.execute(
                "UPDATE agent_chats SET last_message_at = NOW(), "
                "title = CASE WHEN title = '' AND %s <> '' THEN %s ELSE title END "
                "WHERE _id = %s AND user_id = %s AND agent_id = %s",
                (make_title(first_user_text or ""), make_title(first_user_text or ""),
                 chat_id, self.user_id, agent_id),
            )
            self.db.conn.commit()
        except psycopg2.Error as e:
            self._fail("touch", e)
