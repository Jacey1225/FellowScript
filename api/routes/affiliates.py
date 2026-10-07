"""Creator Affiliates page API (task 20261007-affiliates-page).

  GET /affiliates/overview                 metrics, day/week/month series, milestones, own codes/links
  GET /affiliates/resources                promotion resource manifest (sections of downloadable files)
  GET /affiliates/resources/{key}/file     one resource file (key must be in the config manifest)

Uniform 404 (before auth) while the ``affiliates`` flag is off. Then 401 with no
session and 403 (empty of data) unless the session user's account email is the
owner email of an active creator code (see backend/subscription/affiliates.py).
Nothing is taken from the client except the resource ``key``, which is only ever
looked up in the config manifest. No PII is logged; responses are aggregates only.
Plain ``def`` handlers (threadpool).
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import FileResponse

from backend.auth.dependencies import get_current_user
from backend.interactions import flags
from backend.rate_limiting import limiter
from backend.subscription.affiliates import AffiliateManager
from backend.subscription.affiliates_config import ASSETS_DIR, get_affiliates_config

logger = logging.getLogger(__name__)

FLAG = "affiliates"


def _require_enabled() -> None:
    if not flags.is_enabled(FLAG):
        raise HTTPException(status_code=404, detail="Not found")


affiliates_router = APIRouter(prefix="/affiliates", dependencies=[Depends(_require_enabled)])


def _rate() -> str:
    return get_affiliates_config().rate_limit


def _require_creator(request: Request) -> dict:
    """401 without a session; 403 unless the session user is an active creator."""
    user_id = get_current_user(request)
    db = AffiliateManager()
    try:
        affiliate = db.resolve_affiliate(user_id)
    finally:
        db.close()
    if affiliate is None:
        logger.info("affiliates denied user=%s", user_id)
        raise HTTPException(status_code=403, detail="Forbidden")
    return affiliate


@affiliates_router.get("/overview")
@limiter.limit(_rate)
def get_overview(request: Request, response: Response, affiliate: dict = Depends(_require_creator)) -> dict:
    response.headers["Cache-Control"] = "no-store"
    cfg = get_affiliates_config()
    db = AffiliateManager()
    try:
        return db.overview(affiliate, cfg)
    finally:
        db.close()


def _available(r) -> bool:
    return (ASSETS_DIR / r.asset_name).is_file()


@affiliates_router.get("/resources")
@limiter.limit(_rate)
def list_resources(request: Request, response: Response, affiliate: dict = Depends(_require_creator)) -> dict:
    response.headers["Cache-Control"] = "no-store"
    cfg = get_affiliates_config()
    return {"v": 1, "resources": [
        {"key": r.key, "section": r.section, "label": r.label, "content_type": r.content_type,
         "url": f"/affiliates/resources/{r.key}/file"}
        for r in cfg.resources if _available(r)]}


@affiliates_router.get("/resources/{key}/file")
@limiter.limit(_rate)
def get_resource(request: Request, key: str, affiliate: dict = Depends(_require_creator)) -> FileResponse:
    cfg = get_affiliates_config()
    r = next((x for x in cfg.resources if x.key == key), None)
    if r is None or not _available(r):
        raise HTTPException(status_code=404, detail="Not found")
    filename = r.file.rsplit("/", 1)[-1]
    return FileResponse(
        ASSETS_DIR / r.asset_name, media_type=r.content_type, filename=filename,
        content_disposition_type="inline" if r.content_type != "image/svg+xml" else "attachment",
        headers={"Cache-Control": "private, max-age=3600", "X-Content-Type-Options": "nosniff",
                 "Content-Security-Policy": "sandbox"})
