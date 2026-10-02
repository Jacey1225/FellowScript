"""Server-side Terms gating.

``terms_current`` feeds ``GET /app/capabilities`` so a signed-in client can
show the existing "Updated Terms" gate at the next foreground after a version
bump (not only at the next login). ``require_current_terms`` is the helper
routes that create NEW user-generated content call; it answers
``403 {"code": "terms_reaccept_required"}``.

A missing user row counts as not current (fail closed).
"""
from __future__ import annotations

from fastapi import HTTPException

from schemas.users import CURRENT_TERMS_VERSION

TERMS_REACCEPT_CODE = "terms_reaccept_required"


def terms_current(cur, user_id: str) -> bool:
    cur.execute("SELECT terms_version FROM users WHERE _id = %s", (user_id,))
    row = cur.fetchone()
    return row is not None and row[0] == CURRENT_TERMS_VERSION


def require_current_terms(cur, user_id: str) -> None:
    if not terms_current(cur, user_id):
        raise HTTPException(status_code=403, detail={"code": TERMS_REACCEPT_CODE})
