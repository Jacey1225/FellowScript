"""Private per-user activity calendar (task 20261114-activity-calendar).

  GET  /activity-calendar/month?year=&month=   the caller's own month
  POST /activity-calendar/bible-day            record "read the Bible today"

Owner-only by construction: there is NO user_id in any path, query or body.
The identity is the session user from ``get_current_user`` (401 when missing),
so no other user's calendar is reachable. No leader/member/group view, no
sharing. Failures answer 500 rather than an empty calendar (fail closed); no
activity details are logged.
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response

from backend.auth.dependencies import get_current_user
from backend.interactions.activity_calendar import (
    MAX_YEAR,
    MIN_YEAR,
    ActivityCalendarManager,
)
from backend.rate_limiting import limiter
from schemas.activity_calendar import MonthActivity

logger = logging.getLogger(__name__)

activity_calendar_router = APIRouter(prefix="/activity-calendar")


@activity_calendar_router.get("/month")
@limiter.limit("120/minute")
def get_month(
    request: Request,
    response: Response,
    year: int = Query(ge=MIN_YEAR, le=MAX_YEAR),
    month: int = Query(ge=1, le=12),
    user_id: str = Depends(get_current_user),
) -> MonthActivity:
    """Return which activities (chat, note, bible) the caller did on each day.

    Raises:
        HTTPException 401: not authenticated. 422: year/month out of range.
        500: the read failed (never an empty calendar).
    """
    manager = ActivityCalendarManager(user_id)
    try:
        result = manager.month_activity(year, month)
    except Exception:
        logger.error("ACTIVITY_CALENDAR_READ_FAILED")
        raise HTTPException(status_code=500, detail="Could not load activity")
    finally:
        manager.close()
    if isinstance(result, dict) and "error" in result:
        raise HTTPException(status_code=422, detail=result["error"])
    response.headers["Cache-Control"] = "private, no-store"
    return result


@activity_calendar_router.post("/bible-day", status_code=204)
@limiter.limit("60/minute")
def record_bible_day(
    request: Request,
    response: Response,
    user_id: str = Depends(get_current_user),
) -> None:
    """Idempotently mark today (user's timezone) as a Bible-reading day.

    Takes no body: the day is server-computed, so it cannot be back-dated.
    """
    manager = ActivityCalendarManager(user_id)
    try:
        manager.record_bible_day()
    except Exception:
        logger.error("ACTIVITY_CALENDAR_WRITE_FAILED")
        raise HTTPException(status_code=500, detail="Could not record reading")
    finally:
        manager.close()
