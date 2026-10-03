"""Home announcement headline routes (task 20261002-home-announcement-headline).

  GET    /app/home-message              session auth, rate limited, fail-soft
  GET    /admin/home-messages           admin only (require_admin)
  POST   /admin/home-messages           admin only; new messages start disabled
  PATCH  /admin/home-messages/{id}      admin only (text/priority/window/enabled)
  DELETE /admin/home-messages/{id}      admin only

Plain ``def`` handlers (threadpool). The read route answers 200 with
``{"v": 1, "message": null}`` for "nothing active" and on any internal failure;
401 only when unauthenticated. Admin mutations write one ``admin_audit`` line
(actor id, action, message id; never the free text). Tunables come from
config/home_messages.json.
"""
import logging
import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field

from backend.auth.dependencies import get_current_user, require_admin
from backend.interactions import home_messages as hm
from backend.interactions.home_messages_config import get_home_messages_config
from backend.rate_limiting import limiter
from db import DBManager

logger = logging.getLogger(__name__)
audit_logger = logging.getLogger("admin_audit")

home_message_router = APIRouter(prefix="/app")
home_messages_admin_router = APIRouter(prefix="/admin/home-messages")


def _read_rate() -> str:
    return get_home_messages_config().rate_limits["read"]


def _admin_rate() -> str:
    return get_home_messages_config().rate_limits["admin"]


@home_message_router.get("/home-message")
@limiter.limit(_read_rate)
def get_home_message(request: Request, response: Response, user_id: str = Depends(get_current_user)) -> dict:
    message = hm.current_message()
    try:
        ttl = get_home_messages_config().cache_ttl_seconds
        response.headers["Cache-Control"] = f"private, max-age={ttl}"
    except Exception:  # noqa: BLE001
        response.headers["Cache-Control"] = "no-store"
    return {"v": 1, "message": message}


class HomeMessageCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # Generous transport bound only; the configured cap is enforced after cleaning.
    text: str = Field(max_length=2000)
    priority: int = Field(default=0, ge=-1000, le=1000)
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    enabled: bool = False


class HomeMessageUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str | None = Field(default=None, max_length=2000)
    priority: int | None = Field(default=None, ge=-1000, le=1000)
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    enabled: bool | None = None


def _run(action: str, admin_id: str, fn, message_id: str | None = None):
    """One transaction: ``fn(cur)``; commit, audit, map errors to HTTP."""
    if message_id is not None:
        try:
            message_id = str(uuid.UUID(message_id))
        except (ValueError, AttributeError, TypeError):
            message_id = "invalid"  # never log raw path input (log injection)
    db = DBManager()
    try:
        try:
            result = fn(db.cur)
            db.conn.commit()
            hm.invalidate()  # after commit so a racing read cannot re-cache pre-commit rows
        except hm.HomeMessageError as e:
            db.conn.rollback()
            audit_logger.info(
                "action=home_message_%s_refused admin_id=%s message_id=%s status=%s",
                action, admin_id, message_id, e.status,
            )
            raise HTTPException(status_code=e.status, detail=e.detail)
        except Exception:
            db.conn.rollback()
            raise
    finally:
        db.close()
    mid = message_id or (result.get("id") if isinstance(result, dict) else None)
    audit_logger.info("action=home_message_%s admin_id=%s message_id=%s", action, admin_id, mid)
    return result


@home_messages_admin_router.get("")
@limiter.limit(_admin_rate)
def list_home_messages(request: Request, response: Response, admin_id: str = Depends(require_admin)) -> dict:
    response.headers["Cache-Control"] = "no-store"
    db = DBManager()
    try:
        try:
            items = hm.admin_list(db.cur)
        finally:
            db.conn.rollback()
    finally:
        db.close()
    return {"items": items, "text_max_length": get_home_messages_config().text_max_length,
            "max_enabled": get_home_messages_config().max_enabled}


@home_messages_admin_router.post("", status_code=201)
@limiter.limit(_admin_rate)
def create_home_message(
    request: Request, response: Response, body: HomeMessageCreate, admin_id: str = Depends(require_admin),
) -> dict:
    response.headers["Cache-Control"] = "no-store"
    return _run(
        "create", admin_id,
        lambda cur: hm.create(cur, admin_id, body.text, body.priority, body.starts_at, body.ends_at, body.enabled),
    )


@home_messages_admin_router.patch("/{message_id}")
@limiter.limit(_admin_rate)
def update_home_message(
    request: Request, response: Response, message_id: str, body: HomeMessageUpdate,
    admin_id: str = Depends(require_admin),
) -> dict:
    response.headers["Cache-Control"] = "no-store"
    changes = {k: getattr(body, k) for k in body.model_fields_set}
    # Null is only meaningful for the optional window ends; never for the rest.
    for key in ("text", "priority", "enabled"):
        if key in changes and changes[key] is None:
            raise HTTPException(status_code=422, detail=f"{key} cannot be null")
    if not changes:
        raise HTTPException(status_code=422, detail="No changes given")
    if set(changes) == {"enabled"}:
        action = "enable" if changes["enabled"] else "disable"
    else:
        action = "update"
    return _run(action, admin_id, lambda cur: hm.update(cur, admin_id, message_id, changes), message_id)


@home_messages_admin_router.delete("/{message_id}")
@limiter.limit(_admin_rate)
def delete_home_message(
    request: Request, response: Response, message_id: str, admin_id: str = Depends(require_admin),
) -> dict:
    response.headers["Cache-Control"] = "no-store"
    _run("delete", admin_id, lambda cur: hm.delete(cur, message_id), message_id)
    return {"deleted": True}
