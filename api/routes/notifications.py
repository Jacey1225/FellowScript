from fastapi import APIRouter, HTTPException, Depends
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
