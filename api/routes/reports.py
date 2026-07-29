from typing import Literal

from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel

from backend.auth.dependencies import get_current_user
from backend.interactions.reports import ReportsManager

report_router = APIRouter(prefix="/reports")


class ReportRequest(BaseModel):
    content_type: Literal["note", "message", "devotion_prompt", "group_title", "user"]
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
        HTTPException 422: If content_id is missing for a content report, or
            reported_user_id is missing for a direct user report.
    """
    if req.content_type != "user" and not req.content_id:
        raise HTTPException(status_code=422, detail="content_id is required unless content_type is 'user'")
    if req.content_type == "user" and not req.reported_user_id:
        raise HTTPException(status_code=422, detail="reported_user_id is required when content_type is 'user'")

    manager = ReportsManager(current_user)
    try:
        return manager.create_report(req.content_type, req.content_id, req.reported_user_id, req.reason, req.detail)
    finally:
        manager.close()
