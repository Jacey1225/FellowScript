import logging

from fastapi import Request, Response, HTTPException, WebSocket
from backend.auth.sessions import SessionManager, SESSION_TTL_SECONDS
from db import DBManager

SESSION_COOKIE = "session"

logger = logging.getLogger(__name__)


def set_session_cookie(response: Response, token: str, max_age: int = SESSION_TTL_SECONDS) -> None:
    """Set the login cookie. Single source of cookie attributes for login,
    signup (via issue_session) and sliding renewal. The cookie carries only the
    opaque token and is httponly so injected JS cannot read it."""
    response.set_cookie(
        key=SESSION_COOKIE, value=token, httponly=True, secure=True,
        max_age=max_age, samesite="lax",
    )

# Stable machine-readable code the web client matches on (403 detail.code).
MFA_REQUIRED_CODE = "mfa_required"
MFA_REQUIRED_MESSAGE = "Two-factor authentication is required for admin accounts. Enable it to continue."


def get_current_user(request: Request, response: Response = None) -> str:
    """FastAPI dependency: resolve the caller's verified user_id from the session cookie.

    Raises 401 if the cookie is missing, unknown, or expired. This is the only
    place in the API that should ever trust "who is making this request" —
    every route handling a specific user's data must depend on this (directly
    or via ``require_match``) rather than trusting a path/query/body user_id.

    Sliding renewal: after a successful resolve (never before, so an expired
    session is never extended), and only when FastAPI injected ``response``,
    the session's expiry is slid forward (capped at SESSION_MAX_AGE_DAYS from
    sign-in) and the cookie is re-issued with the renewed remaining lifetime.
    Callers that invoke this function directly without a response skip
    renewal entirely, because extending the row without refreshing the cookie
    would let the cookie expire first.
    """
    token = request.cookies.get(SESSION_COOKIE)
    db = SessionManager()
    try:
        user_id = db.resolve(token)
        max_age = db.renew(token) if (user_id and response is not None) else None
    finally:
        db.close()
    if not user_id:
        raise HTTPException(status_code=401, detail="Not authenticated")
    if max_age is not None:
        set_session_cookie(response, token, max_age)
    return user_id


def require_match(field_name: str = "user_id"):
    """Dependency factory: verify the session user matches a path/query field.

    Use for routes shaped like ``/notes/{user_id}`` where ``user_id`` names
    whose data is being accessed. Reads the field from either path or query
    params by name (so it works for ``/{user_id}`` paths and ``?user_id=``
    query args alike) and 403s on any mismatch.
    """
    def _check(request: Request, response: Response) -> str:
        current_user = get_current_user(request, response)
        value = request.path_params.get(field_name)
        if value is None:
            value = request.query_params.get(field_name)
        if value != current_user:
            raise HTTPException(status_code=403, detail="Forbidden")
        return current_user
    return _check


def require_admin(request: Request, response: Response) -> str:
    """Dependency: verify the session user is an authenticated admin.

    Reuses ``get_current_user`` for session verification (401 if the cookie
    is missing/unknown/expired -- there is no separate admin auth path), then
    looks up the resolved user's ``is_admin`` flag directly (not cached on
    the session) and 403s if the caller is authenticated but not an admin.
    Use in place of ``get_current_user`` for admin-only surfaces, e.g. the
    CloudWatch error-detection monitoring endpoints in ``routes/monitoring.py``.
    """
    user_id = get_current_user(request, response)
    db = DBManager()
    try:
        result = db.lookup("users", {"_id": user_id})
    finally:
        db.close()
    if not result:
        # Session resolved to a user_id with no matching row (e.g. deleted
        # account) -- treat as unauthenticated rather than leaking a 403 for
        # an account that no longer exists.
        raise HTTPException(status_code=401, detail="Not authenticated")
    _, data = list(result.items())[0]
    if not data.get("is_admin"):
        raise HTTPException(status_code=403, detail="Admin access required")
    # Admins must have 2FA. Fail closed: only an explicit True passes, so a
    # missing/NULL/unexpected flag is treated as not enabled. Read from the DB
    # per request (never cached on the session) so enabling takes effect
    # immediately. The structured detail is distinct from the plain-string
    # "Admin access required" 403 above.
    if data.get("mfa_enabled") is not True:
        logger.warning("admin access denied: mfa_required user_id=%s", user_id)
        raise HTTPException(
            status_code=403,
            detail={"code": MFA_REQUIRED_CODE, "message": MFA_REQUIRED_MESSAGE},
        )
    return user_id


async def authenticate_ws(websocket: WebSocket) -> str | None:
    """Resolve the session user for a WebSocket handshake, or None if invalid.

    Callers must close the socket (e.g. ``websocket.close(code=4401)``) and
    return without accepting when this returns None — there is no exception
    path for WebSocket routes the way there is for HTTP.

    Renewal rule for sockets: NONE. This is a pure read (resolve only). A
    handshake cannot re-issue Set-Cookie, and extending the DB row without
    refreshing the cookie would only put the row ahead of a cookie that
    expires first. Sessions are renewed by ordinary REST traffic, which
    re-issues the cookie; an expired session is rejected here (close before
    accept, HTTP 403 at the handshake) and never revived. The rejection is
    logged without any token or cookie value.
    """
    token = websocket.cookies.get(SESSION_COOKIE)
    db = SessionManager()
    try:
        user_id = db.resolve(token)
    finally:
        db.close()
    if user_id is None:
        logger.info("ws auth rejected: %s", "no_cookie" if not token else "invalid_or_expired_session")
    return user_id
