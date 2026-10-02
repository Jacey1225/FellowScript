import re
import uuid
from typing import Literal

from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel

from backend.auth.dependencies import get_current_user
from backend.interactions.reports import ContentNotFoundError, ReportsManager

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


@report_router.post("/", status_code=201)
async def create_report(req: ReportRequest, current_user: str = Depends(get_current_user)) -> dict:
    """File a report on objectionable content or an abusive user (Guideline 1.2).

    Every report is emailed to the developer immediately and persisted for
    manual follow-up within 24 hours — see backend/moderation/admin_actions.py.

    Raises:
        HTTPException 422: If content_id is missing for a content report, is
            malformed, or reported_user_id is missing for a direct user report.
        HTTPException 404: If the reported listing/thread content doesn't exist.
    """
    if req.content_type != "user" and not req.content_id:
        raise HTTPException(status_code=422, detail="content_id is required unless content_type is 'user'")
    if req.content_type == "user" and not req.reported_user_id:
        raise HTTPException(status_code=422, detail="reported_user_id is required when content_type is 'user'")

    content_id = _validated_content_id(req.content_type, req.content_id)

    manager = ReportsManager(current_user)
    try:
        return manager.create_report(req.content_type, content_id, req.reported_user_id, req.reason, req.detail)
    except ContentNotFoundError:
        raise HTTPException(status_code=404, detail="Content not found")
    finally:
        manager.close()
