import json
import time
import uuid
import logging
from datetime import datetime
from typing import Optional

from backend.interactions.agent import AgentManager
from db import DBManager
from schemas.notifications import Notification

logger = logging.getLogger(__name__)

INSTRUCTION = (
    "You are to create a short, encouraging reminder for a user based on the following instructions. "
    "Respond ONLY in JSON format with a single key 'body' whose value is the reminder text. "
    "Example: {\"body\": \"Your reminder text here.\"}\n\nInstructions: "
)


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
        # Retry transient LLM/API failures (rate-limits, timeouts, 5xx) instead of
        # letting one bad call propagate as an error — which the client would turn
        # into a fallback that shows the raw prompt.
        response = ""
        for attempt in range(3):
            try:
                response = self.assistant._call_api(
                    "", [{"role": "user", "content": INSTRUCTION + prompt}]
                )
                if response.strip():
                    break
            except Exception as e:
                logger.warning("Notification content call failed (attempt %d): %s", attempt + 1, e)
                response = ""
            if attempt < 2:
                time.sleep(0.8)

        # Try to parse {"body": "..."} from the response
        if "{" in response and "}" in response:
            try:
                start = response.find("{")
                end   = response.rfind("}") + 1  # rfind+1 to include the closing brace
                content_dict: dict = json.loads(response[start:end])
                body = content_dict.get("body", "").strip()
                if body:
                    return body
            except (json.JSONDecodeError, ValueError):
                pass
        # Fall back to the raw response text if JSON parsing fails or is absent
        return response.strip() or "error"

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
            # Re-raise (don't just log+swallow) — this is the exact class of bug
            # noted on the `agents` table above: silently discarding the write
            # while still returning a generated id lets the route respond 201
            # with a fake success even though nothing was persisted. Letting the
            # exception propagate turns it into a real 500 the client can see.
            logger.error("Error creating notification: %s", e)
            self.conn.rollback()
            raise
        return notif_id

    def get_notifications(self) -> list[dict]:
        result = self.lookup(self._table, {"user_id": self.user_id})
        return [{"_id": k, **v} for k, v in result.items()]

    def get_notification(self, notif_id: str) -> dict | None:
        # Scoped by user_id like update/set_timestamp/delete below — without
        # this, any authenticated user could read (and even AI-trigger, via
        # /trigger) another user's notification by guessing/observing a
        # notif_id, since require_match on the route only checks the caller
        # IS user_id, not that notif_id belongs to them.
        result = self.lookup(self._table, {"_id": notif_id, "user_id": self.user_id})
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
                # Re-raise — the route returns {"ok": True} unconditionally after
                # calling this, so swallowing here silently told the client its
                # schedule change saved when it didn't (incident #1's pattern).
                logger.error("Error updating timestamps: %s", e)
                self.conn.rollback()
                raise

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
            # Re-raise — same false-success risk as create_notification/
            # update_notification above: the route returns {"ok": True}
            # unconditionally after this call.
            logger.error("Error setting timestamp slot %d: %s", day, e)
            self.conn.rollback()
            raise

    def delete_notification(self, notif_id: str) -> None:
        self.delete(self._table, {"_id": notif_id, "user_id": self.user_id})

    # ── Trigger ───────────────────────────────────────────────────────────────

    def trigger(self, notif_id: str) -> dict:
        """Generate AI content for a notification using its saved prompt."""
        notif = self.get_notification(notif_id)
        if not notif:
            return {"error": "notification not found"}
        content = self.get_content(notif["prompt"])
        if content == "error":
            return {"error": "cannot retrieve notification content"}
        return {"name": notif["name"], "content": content}
