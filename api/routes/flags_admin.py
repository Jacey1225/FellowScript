"""Admin write surface for feature flags (``PUT /admin/flags/{name}``).

Plain ``def`` handler (runs in the threadpool). Admin only via
``require_admin`` (401 without a session, 403 for a non-admin). Validation and
the INFO ``FLAG_CHANGE`` audit line live in ``flags.set_flag``.
"""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from backend.auth.dependencies import require_admin
from backend.interactions import flags

flags_admin_router = APIRouter(prefix="/admin/flags")


class FlagUpdate(BaseModel):
    state: Literal["off", "canary", "on"]
    # Omitted keeps the stored list; given, it replaces it.
    canary_user_ids: list[str] | None = Field(default=None, max_length=flags.MAX_CANARY_IDS)


@flags_admin_router.put("/{name}")
def put_flag(name: str, body: FlagUpdate, admin_id: str = Depends(require_admin)) -> dict:
    try:
        return flags.set_flag(name, body.state, body.canary_user_ids, actor=admin_id)
    except flags.UnknownFlagError:
        raise HTTPException(status_code=404, detail="Unknown flag")
    except flags.InvalidFlagStateError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except flags.InvalidCanaryError:
        raise HTTPException(status_code=422, detail="Invalid canary list")
