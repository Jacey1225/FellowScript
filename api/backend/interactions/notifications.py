import json
import uuid
import logging
from datetime import datetime
from typing import Optional

from backend.interactions.agent import AgentManager
from db import DBManager
from schemas.notifications import Notification

logger = logging.getLogger(__name__)

INSTRUCTION = ""


class NotificationManager(DBManager):
    _table = "notifications"

    def __init__(self, user_id: str):
        super().__init__()
        self.assistant = AgentManager(user_id)
        self.user_id = user_id

    def close(self) -> None:
        self.assistant.close()
        super().close()

    # ── AI helper ─────────────────────────────────────────────────────────────

    def get_content(self, prompt: str) -> str:
        return self.assistant._call_api("", [{"role": "user", "content": prompt}])

    # ── Scheduling helper ─────────────────────────────────────────────────────

    def next_notify(self, timestamps: list[Optional[str]]) -> dict:
        """Return the next scheduled month/day/time after today.

        The timestamps list is 0-indexed where index i represents day i+1 of
        the month (index 0 → day 1, index 30 → day 31).
        """
        now_day = datetime.now().day        # 1-31
        month   = datetime.now().month
        day     = now_day % len(timestamps) # start from tomorrow (wraps at month end)
        counter = 0

        while True:
            if counter > len(timestamps) * 2:
                return {"error": "no scheduled timestamps found"}
            if day >= len(timestamps):
                day = 0
                month += 1
            if timestamps[day]:
                return {"month": month, "day": day + 1, "time": timestamps[day]}
            day += 1
            counter += 1

    # ── CRUD ──────────────────────────────────────────────────────────────────

    def create_notification(self, notification: Notification) -> str:
        notif_id = str(uuid.uuid4())
        try:
            self.cur.execute(
                f"INSERT INTO {self._table} (_id, user_id, name, prompt, timestamps) "
                "VALUES (%s, %s, %s, %s, %s::jsonb)",
                (notif_id, self.user_id, notification.name,
                 notification.prompt, json.dumps(notification.timestamps))
            )
            self.conn.commit()
        except Exception as e:
            logger.error("Error creating notification: %s", e)
            self.conn.rollback()
        return notif_id

    def get_notifications(self) -> list[dict]:
        result = self.lookup(self._table, {"user_id": self.user_id})
        return [{"_id": k, **v} for k, v in result.items()]

    def get_notification(self, notif_id: str) -> dict | None:
        result = self.lookup(self._table, {"_id": notif_id})
        if not result:
            return None
        k, v = next(iter(result.items()))
        return {"_id": k, **v}

    def update_notification(self, notif_id: str, fields: dict) -> None:
        allowed = {k: fields[k] for k in ("name", "prompt") if k in fields}
        if allowed:
            self.update(self._table, allowed,
                        {"_id": notif_id, "user_id": self.user_id})
        if "timestamps" in fields:
            try:
                self.cur.execute(
                    f"UPDATE {self._table} SET timestamps = %s::jsonb "
                    "WHERE _id = %s AND user_id = %s",
                    (json.dumps(fields["timestamps"]), notif_id, self.user_id)
                )
                self.conn.commit()
            except Exception as e:
                logger.error("Error updating timestamps: %s", e)
                self.conn.rollback()

    def set_timestamp(self, notif_id: str, day: int, timestamp: Optional[str]) -> None:
        """Set or clear the timestamp for a specific day slot (0-indexed, 0–30)."""
        try:
            self.cur.execute(
                f"UPDATE {self._table} "
                f"SET timestamps = jsonb_set(timestamps, '{{{day}}}', %s::jsonb) "
                "WHERE _id = %s AND user_id = %s",
                (json.dumps(timestamp), notif_id, self.user_id)
            )
            self.conn.commit()
        except Exception as e:
            logger.error("Error setting timestamp slot %d: %s", day, e)
            self.conn.rollback()

    def delete_notification(self, notif_id: str) -> None:
        self.delete(self._table, {"_id": notif_id, "user_id": self.user_id})

    # ── Trigger ───────────────────────────────────────────────────────────────

    def trigger(self, notif_id: str) -> dict:
        """Generate AI content for a notification using its saved prompt."""
        notif = self.get_notification(notif_id)
        if not notif:
            return {"error": "notification not found"}
        content = self.get_content(notif["prompt"])
        return {"name": notif["name"], "content": content}
