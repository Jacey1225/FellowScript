from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel, StrictBool
from backend.auth.dependencies import require_match
from db import DBManager
import logging

notification_router = APIRouter(prefix="/notification")
logger = logging.getLogger(__name__)


# ── Device token registration ─────────────────────────────────────────────────
#
# This is the only surface left in this router. The former CRUD/trigger/next
# endpoints for user-authored ("agentic") notifications — and the
# NotificationManager/Notification schema/`notifications` table they used —
# were removed in full: that subsystem let a user author their own AI-prompt
# reminders on a 31-day schedule, which was replaced by a backend
# activity-tracked/fixed-notification system (see
# .claude/pipeline/20260826-activity-based-notifications). Device-token
# registration is generic APNs push plumbing, not part of that subsystem, and
# is retained unchanged — the new fixed notifications reuse it via the same
# `device_tokens` table and `send_push` pipeline.

@notification_router.post("/{user_id}/device-token", status_code=204)
async def register_device_token(user_id: str, body: dict, _: str = Depends(require_match("user_id"))) -> None:
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


# Task 20260916-callkit-voip-ring: a VoIP push token is a distinct token
# type in Apple's system, registered client-side via PKPushRegistry (not
# UIApplication.registerForRemoteNotifications()) -- this parallels
# register_device_token above rather than replacing or merging into it, per
# the same reasoning as voip_device_tokens's own table comment in db.py.
@notification_router.post("/{user_id}/voip-device-token", status_code=204)
async def register_voip_device_token(user_id: str, body: dict, _: str = Depends(require_match("user_id"))) -> None:
    """Store or update a user's PushKit VoIP device token."""
    token = body.get("token", "").strip()
    if not token:
        raise HTTPException(status_code=400, detail="token required")
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO voip_device_tokens (user_id, token, updated_at) "
            "VALUES (%s, %s, NOW()) "
            "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token, updated_at = NOW()",
            (user_id, token),
        )
        db.conn.commit()
    except Exception as e:
        logger.error("Error saving VoIP device token: %s", e)
        db.conn.rollback()
        raise HTTPException(status_code=500, detail="Failed to save token")
    finally:
        db.close()


# ── Push preferences (task 20261010-reaction-highlight-push) ──────────────────
#
# Per-user opt-out for friend-highlight pushes. Default ON: a missing row means
# on. Path user is matched against the session by require_match, so a caller can
# only read or write their own setting. Not flag-gated (the stored value is
# harmless while the push flag is off); iOS hides the toggle via capabilities.

class PushPreferences(BaseModel):
    friend_highlight: StrictBool


@notification_router.get("/{user_id}/push-preferences")
async def get_push_preferences(user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DBManager()
    try:
        db.cur.execute("SELECT friend_highlight FROM push_preferences WHERE user_id = %s", (user_id,))
        row = db.cur.fetchone()
        db.conn.rollback()
        return {"friend_highlight": True if row is None else bool(row[0])}
    finally:
        db.close()


@notification_router.put("/{user_id}/push-preferences")
async def set_push_preferences(
    user_id: str, body: PushPreferences, _: str = Depends(require_match("user_id")),
) -> dict:
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO push_preferences (user_id, friend_highlight, updated_at) VALUES (%s, %s, NOW()) "
            "ON CONFLICT (user_id) DO UPDATE SET friend_highlight = EXCLUDED.friend_highlight, updated_at = NOW()",
            (user_id, body.friend_highlight),
        )
        db.conn.commit()
        return {"friend_highlight": body.friend_highlight}
    except Exception as e:
        db.conn.rollback()
        logger.error("Error saving push preferences: %s", type(e).__name__)
        raise HTTPException(status_code=500, detail="Failed to save preferences")
    finally:
        db.close()
