from fastapi import APIRouter, HTTPException
from backend.interactions.notifications import NotificationManager
from schemas.notifications import Notification
from db import DBManager
import logging

notification_router = APIRouter(prefix="/notification")
logger = logging.getLogger(__name__)


# ── Device token registration ─────────────────────────────────────────────────

@notification_router.post("/{user_id}/device-token", status_code=204)
async def register_device_token(user_id: str, body: dict) -> None:
    """Store or update a user's APNs device token."""
    token = body.get("token", "").strip()
    if not token:
        raise HTTPException(status_code=400, detail="token required")
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO device_tokens (user_id, token, updated_at) "
            "VALUES (%s, %s, NOW()) "
            "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token, updated_at = NOW()",
            (user_id, token),
        )
        db.conn.commit()
    except Exception as e:
        logger.error("Error saving device token: %s", e)
        db.conn.rollback()
        raise HTTPException(status_code=500, detail="Failed to save token")
    finally:
        db.close()


# ── List / fetch ──────────────────────────────────────────────────────────────

@notification_router.get("/{user_id}")
async def get_notifications(user_id: str) -> list:
    """Return all notifications belonging to user_id."""
    db = NotificationManager(user_id)
    try:
        return db.get_notifications()
    finally:
        db.close()


@notification_router.get("/{user_id}/{notif_id}")
async def get_notification(user_id: str, notif_id: str) -> dict:
    """Return a single notification by ID."""
    db = NotificationManager(user_id)
    try:
        notif = db.get_notification(notif_id)
        if not notif:
            raise HTTPException(status_code=404, detail="Notification not found")
        return notif
    finally:
        db.close()


# ── Create ────────────────────────────────────────────────────────────────────

@notification_router.post("/{user_id}", status_code=201)
async def create_notification(user_id: str, body: dict) -> dict:
    """Create a new notification.

    Body fields:
        name (str): Display name for the notification.
        prompt (str): AI prompt used when the notification fires.
        timestamps (list[str|None], optional): 31-item schedule array.
    """
    db = NotificationManager(user_id)
    try:
        notif = Notification(
            user_id=user_id,
            name=body.get("name", ""),
            prompt=body.get("prompt", ""),
            timestamps=body.get("timestamps", [None] * 31),
        )
        notif_id = db.create_notification(notif)
        return {"id": notif_id}
    finally:
        db.close()


# ── Update ────────────────────────────────────────────────────────────────────

@notification_router.put("/{user_id}/{notif_id}")
async def update_notification(user_id: str, notif_id: str, body: dict) -> dict:
    """Update a notification's name and/or prompt."""
    db = NotificationManager(user_id)
    try:
        if not db.get_notification(notif_id):
            raise HTTPException(status_code=404, detail="Notification not found")
        db.update_notification(notif_id, body)
        return {"ok": True}
    finally:
        db.close()


@notification_router.patch("/{user_id}/{notif_id}/timestamp")
async def set_timestamp(user_id: str, notif_id: str, body: dict) -> dict:
    """Set or clear the timestamp for one day slot.

    Body fields:
        day (int): 0-indexed day slot (0 = day 1 of month … 30 = day 31).
        timestamp (str|None): ISO-8601 time string, or null to clear the slot.
    """
    day = body.get("day")
    if day is None or not isinstance(day, int) or not (0 <= day <= 30):
        raise HTTPException(status_code=400, detail="'day' must be an integer 0–30")

    db = NotificationManager(user_id)
    try:
        if not db.get_notification(notif_id):
            raise HTTPException(status_code=404, detail="Notification not found")
        db.set_timestamp(notif_id, day, body.get("timestamp"))
        return {"ok": True}
    finally:
        db.close()


# ── Delete ────────────────────────────────────────────────────────────────────

@notification_router.delete("/{user_id}/{notif_id}", status_code=204)
async def delete_notification(user_id: str, notif_id: str) -> None:
    """Permanently delete a notification."""
    db = NotificationManager(user_id)
    try:
        db.delete_notification(notif_id)
    finally:
        db.close()


# ── Trigger / scheduling ──────────────────────────────────────────────────────

@notification_router.post("/{user_id}/{notif_id}/trigger")
async def trigger_notification(user_id: str, notif_id: str) -> dict:
    """Generate AI content for a notification using its saved prompt.

    Returns:
        dict: {name, content} where content is the AI-generated text.
    """
    db = NotificationManager(user_id)
    try:
        result = db.trigger(notif_id)
        if "error" in result:
            raise HTTPException(status_code=404, detail=result["error"])
        return result
    finally:
        db.close()


@notification_router.get("/{user_id}/{notif_id}/next")
async def next_notification(user_id: str, notif_id: str) -> dict:
    """Return the next scheduled month/day/time for a notification.

    Returns:
        dict: {month, day, time} for the next non-null timestamp slot, or
              {error} if no slots are scheduled.
    """
    db = NotificationManager(user_id)
    try:
        notif = db.get_notification(notif_id)
        if not notif:
            raise HTTPException(status_code=404, detail="Notification not found")
        return db.next_notify(notif.get("timestamps", []))
    finally:
        db.close()
