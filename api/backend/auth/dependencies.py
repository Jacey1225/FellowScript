from fastapi import Request, HTTPException, WebSocket
from backend.auth.sessions import SessionManager
from db import DBManager

SESSION_COOKIE = "session"


def get_current_user(request: Request) -> str:
    """FastAPI dependency: resolve the caller's verified user_id from the session cookie.

    Raises 401 if the cookie is missing, unknown, or expired. This is the only
    place in the API that should ever trust "who is making this request" —
    every route handling a specific user's data must depend on this (directly
    or via ``require_match``) rather than trusting a path/query/body user_id.
    """
    token = request.cookies.get(SESSION_COOKIE)
    db = SessionManager()
    try:
        user_id = db.resolve(token)
    finally:
        db.close()
    if not user_id:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return user_id


def require_match(field_name: str = "user_id"):
    """Dependency factory: verify the session user matches a path/query field.

    Use for routes shaped like ``/notes/{user_id}`` where ``user_id`` names
    whose data is being accessed. Reads the field from either path or query
    params by name (so it works for ``/{user_id}`` paths and ``?user_id=``
    query args alike) and 403s on any mismatch.
    """
    def _check(request: Request) -> str:
        current_user = get_current_user(request)
        value = request.path_params.get(field_name)
        if value is None:
            value = request.query_params.get(field_name)
        if value != current_user:
            raise HTTPException(status_code=403, detail="Forbidden")
        return current_user
    return _check


def require_admin(request: Request) -> str:
    """Dependency: verify the session user is an authenticated admin.

    Reuses ``get_current_user`` for session verification (401 if the cookie
    is missing/unknown/expired -- there is no separate admin auth path), then
    looks up the resolved user's ``is_admin`` flag directly (not cached on
    the session) and 403s if the caller is authenticated but not an admin.
    Use in place of ``get_current_user`` for admin-only surfaces, e.g. the
    CloudWatch error-detection monitoring endpoints in ``routes/monitoring.py``.
    """
    user_id = get_current_user(request)
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
    return user_id


async def authenticate_ws(websocket: WebSocket) -> str | None:
    """Resolve the session user for a WebSocket handshake, or None if invalid.

    Callers must close the socket (e.g. ``websocket.close(code=4401)``) and
    return without accepting when this returns None — there is no exception
    path for WebSocket routes the way there is for HTTP.
    """
    token = websocket.cookies.get(SESSION_COOKIE)
    db = SessionManager()
    try:
        return db.resolve(token)
    finally:
        db.close()
