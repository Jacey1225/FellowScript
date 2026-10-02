"""Admin "User actions": list/search users and grant/revoke the admin role
(task 20261002-admin-user-actions).

Every route depends on ``require_admin`` (401 no/invalid session, 403
non-admin; ``is_admin`` is re-read from the DB per request so a revoke takes
effect immediately). Responses carry only id, username, email and is_admin --
the same user fields admins already handle elsewhere (e.g. promo owner
lookups) -- and are ``Cache-Control: no-store``. Role changes write an
``admin_role_audit`` row atomically (see backend/auth/admin_users.py) plus a
line on the ``admin_audit`` logger. Rate limits come from config/admin_users.json.
"""
import logging
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response

from backend.auth.admin_users import AdminUsersError, AdminUsersManager
from backend.auth.admin_users_config import get_admin_users_config
from backend.auth.dependencies import require_admin
from backend.rate_limiting import limiter

logger = logging.getLogger(__name__)
audit_logger = logging.getLogger("admin_audit")

admin_users_router = APIRouter(prefix="/admin/users")


def _rate(name: str):
    return lambda: get_admin_users_config().rate_limits[name]


def _admin_key(request: Request) -> str:
    return f"admin-users:{request.cookies.get('session', '')}"


def _parse_uuid(value: str) -> str:
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        raise HTTPException(status_code=404, detail="User not found")


@admin_users_router.get("")
@limiter.limit(_rate("list"))
async def list_users(
    request: Request,
    response: Response,
    q: str | None = Query(default=None),
    page: int = Query(default=1, ge=1, le=1_000_000),
    page_size: int | None = Query(default=None, ge=1),
    admin_id: str = Depends(require_admin),
) -> dict:
    cfg = get_admin_users_config()
    response.headers["Cache-Control"] = "no-store"
    search = q.strip() if q else None
    if search and "\x00" in search:
        raise HTTPException(status_code=422, detail="Invalid search")
    if search and len(search) > cfg.max_search_length:
        raise HTTPException(status_code=422, detail=f"Search is limited to {cfg.max_search_length} characters")
    size = min(page_size or cfg.default_page_size, cfg.max_page_size)
    db = AdminUsersManager()
    try:
        users, total = db.list_users(search or None, size, (page - 1) * size)
    finally:
        db.close()
    audit_logger.info("action=admin_users_list admin_id=%s page=%s searched=%s", admin_id, page, bool(search))
    return {"users": users, "total": total, "page": page, "page_size": size}


def _change(request: Request, response: Response, admin_id: str, user_id: str, make_admin: bool) -> dict:
    response.headers["Cache-Control"] = "no-store"
    target = _parse_uuid(user_id)
    action = "grant" if make_admin else "revoke"
    db = AdminUsersManager()
    try:
        result = db.set_admin(admin_id, target, make_admin)
    except AdminUsersError as e:
        audit_logger.info(
            "action=admin_role_%s_refused admin_id=%s target_id=%s code=%s", action, admin_id, target, e.code
        )
        raise HTTPException(status_code=e.status, detail=e.detail)
    finally:
        db.close()
    audit_logger.info(
        "action=admin_role_%s admin_id=%s target_id=%s changed=%s", action, admin_id, target, result["changed"]
    )
    return result


@admin_users_router.post("/{user_id}/grant-admin")
@limiter.limit(_rate("mutate"))
@limiter.limit(_rate("mutate_per_admin"), key_func=_admin_key)
async def grant_admin(
    request: Request, response: Response, user_id: str, admin_id: str = Depends(require_admin)
) -> dict:
    return _change(request, response, admin_id, user_id, True)


@admin_users_router.post("/{user_id}/revoke-admin")
@limiter.limit(_rate("mutate"))
@limiter.limit(_rate("mutate_per_admin"), key_func=_admin_key)
async def revoke_admin(
    request: Request, response: Response, user_id: str, admin_id: str = Depends(require_admin)
) -> dict:
    return _change(request, response, admin_id, user_id, False)
