import re
import uuid
from typing import Literal

from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel

from backend.auth.dependencies import get_current_user
from limits import parse as parse_rate

from backend.interactions.listings_config import get_listings_config
from backend.interactions.reports import ContentNotFoundError, ReportsManager
from backend.rate_limiting import limiter

report_router = APIRouter(prefix="/reports")

# group_listing content ids are the listing's public_id, not a UUID.
_PUBLIC_ID_RE = re.compile(r"[0-9A-Za-z]{10}")


def _validated_content_id(content_type: str, content_id: str | None) -> str | None:
    """422 (not a 500 from a bad cast later) for a malformed content id.
    UUID-typed types are normalised to the canonical lowercase form."""
    if content_id is None:
        return None
    if content_type == "group_listing":
        if not _PUBLIC_ID_RE.fullmatch(content_id):
            raise HTTPException(status_code=422, detail="content_id is not valid")
        return content_id
    try:
        return str(uuid.UUID(content_id))
    except (ValueError, AttributeError):
        raise HTTPException(status_code=422, detail="content_id is not valid")


class ReportRequest(BaseModel):
    content_type: Literal[
        "note", "message", "devotion_prompt", "group_title", "user",
        "group_listing", "thread_message",
    ]
    content_id: str | None = None
    reported_user_id: str = ""
    reason: str
    detail: str = ""


def _listing_report_limited(user_id: str) -> bool:
    """Per-reporter limit for listing reports (config ``rate_limits.report``).
    Applied only to ``group_listing`` so the existing report types keep their
    behaviour. True when the caller is over the limit."""
    rate = parse_rate(get_listings_config().rate_limits["report"])
    return not limiter.limiter.hit(rate, "listing-report", user_id)


# Plain ``def``: the manager does blocking DB work, an after-report hook that
# takes row locks, and an SES send, so it must run in the threadpool.
@report_router.post("/", status_code=201)
def create_report(req: ReportRequest, current_user: str = Depends(get_current_user)) -> dict:
    """File a report on objectionable content or an abusive user (Guideline 1.2).

    Every report is emailed to the developer immediately and persisted for
    manual follow-up within 24 hours — see backend/moderation/admin_actions.py.

    Raises:
        HTTPException 422: If content_id is missing for a content report, is
            malformed, or reported_user_id is missing for a direct user report.
        HTTPException 404: If the reported listing/thread content doesn't exist.
        HTTPException 429: If a listing report exceeds the per-reporter limit.
    """
    if req.content_type != "user" and not req.content_id:
        raise HTTPException(status_code=422, detail="content_id is required unless content_type is 'user'")
    if req.content_type == "user" and not req.reported_user_id:
        raise HTTPException(status_code=422, detail="reported_user_id is required when content_type is 'user'")

    content_id = _validated_content_id(req.content_type, req.content_id)
    if req.content_type == "group_listing" and _listing_report_limited(current_user):
        raise HTTPException(status_code=429, detail="Too many reports. Please try again later.")

    manager = ReportsManager(current_user)
    try:
        return manager.create_report(req.content_type, content_id, req.reported_user_id, req.reason, req.detail)
    except ContentNotFoundError:
        raise HTTPException(status_code=404, detail="Content not found")
    finally:
        manager.close()
