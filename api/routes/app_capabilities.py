"""``GET /app/capabilities``: what this server build offers THIS user.

Session auth via ``get_current_user`` (no user id in the path). Evaluated per
user (canary lists). ``features`` keys come from the flag registry (flags with
``exposed_in_capabilities``), so adding a flag never needs an edit here.
Exposes booleans only: no ids, no canary lists, no state strings.

Clients treat any non-200, network error or malformed body as "all features
off, terms_current true" (a missing endpoint must not trap users behind a
terms gate).
"""
from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from backend.auth.dependencies import get_current_user
from backend.auth.terms import terms_current
from backend.interactions import flags
from backend.interactions.invites_config import get_invites_config
from backend.interactions.message_reactions import capability_emoji
from db import DBManager

capabilities_router = APIRouter(prefix="/app")


@capabilities_router.get("/capabilities")
def get_capabilities(user_id: str = Depends(get_current_user)) -> JSONResponse:
    features = flags.evaluate_all(user_id, exposed_only=True)
    explore = None
    if features.get("explorer_browse"):
        explore = get_invites_config().public_base_url + "/#/explore"
    db = DBManager()
    try:
        current = terms_current(db.cur, user_id)
    finally:
        db.close()
    return JSONResponse(
        {"v": 1, "features": features, "links": {"explore": explore}, "terms_current": current,
         "reaction_emoji": capability_emoji(user_id)},
        headers={"Cache-Control": "no-store"},
    )
