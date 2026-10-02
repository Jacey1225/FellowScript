"""Explorer routes (``/explorer``).

  GET    /explorer/config                                       public probe, ALWAYS 200 ``{"browse": bool}``
  GET    /explorer/{user_id}/options                            vocabularies and limits for the owner form
  GET    /explorer/{user_id}/groups                             groups the caller created + listing status
  GET    /explorer/{user_id}/groups/{group_id}/listing          the caller's own listing
  PUT    /explorer/{user_id}/groups/{group_id}/listing          create the draft / save fields
  POST   /explorer/{user_id}/groups/{group_id}/listing/submit   consent + adult attestation -> review
  POST   /explorer/{user_id}/groups/{group_id}/listing/unpublish
  DELETE /explorer/{user_id}/groups/{group_id}/listing

The public list and detail routes (backend step 4) and the admin and report
routes (step 6) are added here later.

Rules (R-ROUTE): authenticated routes are plain ``def`` (threadpool) because
they take ``FOR UPDATE`` row locks; ``require_match`` resolves the path user
against the session first. Owner routes answer a uniform 404 while the
``explorer_publish`` flag is off for the caller (flags are DB rows, 10 s
cache, fail closed). Every write calls ``require_current_terms`` (403
``terms_reaccept_required``). Behaviour lives in
``backend/interactions/listings.py``; this module is auth, flags, rate limits
and HTTP mapping only.

``GET /explorer/config`` is the signed-out probe the website runs on every Home
page view: it answers 200 with ``{"browse": true|false}`` no matter what (the
flag read failing means false), never 404, so a dark feature does not produce
a 4xx per page view in the access log. Anonymous callers only ever see the
``on`` state (``explorer_browse`` has no canary).
"""
import logging
from typing import Any

import anyio.to_thread
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, StrictBool

from backend import public_guard
from backend.auth.dependencies import require_match
from backend.interactions import flags
from backend.interactions.listing_content import ListingError, options_payload
from backend.interactions.listings import ListingsManager
from backend.interactions.listings_config import get_listings_config
from backend.observability import feature_summary
from backend.rate_limiting import limiter

explorer_router = APIRouter(prefix="/explorer")
logger = logging.getLogger(__name__)

# Cached briefly: the probe runs on every Home view and flags change by hand.
_PROBE_CACHE_CONTROL = "public, max-age=30"


def _rate(name: str):
    return lambda: get_listings_config().rate_limits[name]


def _global_rate():
    return get_listings_config().public_global_rate_limit


def _user_key(request: Request) -> str:
    # Runs after require_match resolved the path user_id against the session.
    return f"explorer-user:{request.path_params.get('user_id')}"


def _off() -> HTTPException:
    return HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})


def _http(err: ListingError) -> HTTPException:
    return HTTPException(status_code=err.status, detail=err.detail())


def _browse_enabled() -> bool:
    return bool(flags.is_enabled("explorer_browse"))


@explorer_router.get("/config")
@limiter.limit(_rate("config"))
@public_guard.global_limit(_global_rate)
async def explorer_config(request: Request) -> JSONResponse:
    """Signed-out probe: ``{"browse": bool}``, always HTTP 200 (R3-4)."""
    try:
        # A flag cache hit is instant; a miss reads the DB, so it never runs on the event loop.
        browse = await anyio.to_thread.run_sync(_browse_enabled)
    except Exception:  # noqa: BLE001 - the probe must answer 200 whatever happens
        browse = False
    if not browse:
        feature_summary.incr("probe_off_hits")
    return JSONResponse({"browse": browse}, headers={"Cache-Control": _PROBE_CACHE_CONTROL})


class ListingBody(BaseModel):
    """PUT body. Every field is optional: an omitted field is left unchanged, an
    explicit ``null`` clears it. Precise rules (lengths, vocabulary, text policy)
    live in ``listing_content.normalise``; the bounds here only stop absurd bodies."""
    model_config = ConfigDict(extra="forbid")

    title: str | None = Field(default=None, max_length=1000)
    summary: str | None = Field(default=None, max_length=5000)
    description_blocks: list[dict[str, Any]] | None = Field(default=None, max_length=100)
    denominations: list[str] | None = Field(default=None, max_length=50)
    goals: list[str] | None = Field(default=None, max_length=50)
    practices: list[str] | None = Field(default=None, max_length=50)
    hobbies: list[str] | None = Field(default=None, max_length=50)
    free_tags: list[str] | None = Field(default=None, max_length=50)
    age_ranges: list[str] | None = Field(default=None, max_length=50)
    life_stages: list[str] | None = Field(default=None, max_length=50)
    languages: list[str] | None = Field(default=None, max_length=50)
    gender_makeup: str | None = Field(default=None, max_length=100)
    meeting_format: str | None = Field(default=None, max_length=100)
    frequency: str | None = Field(default=None, max_length=100)
    country: str | None = Field(default=None, max_length=10)
    region: str | None = Field(default=None, max_length=1000)
    city: str | None = Field(default=None, max_length=1000)
    church_name: str | None = Field(default=None, max_length=1000)
    # Initial/updated "let people ask to join" value. Omitted: unchanged (a new
    # listing's column default is FALSE, i.e. closed).
    accepting_requests: StrictBool | None = None

    def content_fields(self) -> dict:
        return {
            name: getattr(self, name)
            for name in self.model_fields_set
            if name != "accepting_requests"
        }


class SubmitBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    consent: StrictBool = False
    adult_attested: StrictBool = False
    accepting_requests: StrictBool | None = None


def _manager(user_id: str) -> ListingsManager:
    """Flag gate then manager. A flag-off hit is the same 404 as a missing group."""
    if not flags.is_enabled("explorer_publish", user_id):
        raise _off()
    return ListingsManager(user_id)


@explorer_router.get("/{user_id}/options")
@limiter.limit(_rate("owner_read"), key_func=_user_key)
def listing_options(request: Request, user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Vocabularies and limits the owner form needs (from config)."""
    if not flags.is_enabled("explorer_publish", user_id):
        raise _off()
    return options_payload(get_listings_config())


@explorer_router.get("/{user_id}/groups")
@limiter.limit(_rate("owner_read"), key_func=_user_key)
def list_my_groups(request: Request, user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Groups the caller created, each with its listing status (or null)."""
    manager = _manager(user_id)
    try:
        return manager.list_groups()
    finally:
        manager.close()


@explorer_router.get("/{user_id}/groups/{group_id}/listing")
@limiter.limit(_rate("owner_read"), key_func=_user_key)
def get_my_listing(
    request: Request, user_id: str, group_id: str, _: str = Depends(require_match("user_id")),
) -> dict:
    manager = _manager(user_id)
    try:
        return manager.get_listing(group_id)
    except ListingError as e:
        raise _http(e)
    finally:
        manager.close()


@explorer_router.put("/{user_id}/groups/{group_id}/listing")
@limiter.limit(_rate("owner_write"), key_func=_user_key)
def save_my_listing(
    request: Request, user_id: str, group_id: str, body: ListingBody,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Create the draft (first save) or update fields. Never publishes by itself."""
    manager = _manager(user_id)
    try:
        manager.require_terms()
        return manager.save(group_id, body.content_fields(), body.accepting_requests)
    except ListingError as e:
        raise _http(e)
    finally:
        manager.close()


@explorer_router.post("/{user_id}/groups/{group_id}/listing/submit")
@limiter.limit(_rate("owner_write"), key_func=_user_key)
def submit_my_listing(
    request: Request, user_id: str, group_id: str, body: SubmitBody,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Consent + adult attestation, then review (or publish when review is off)."""
    manager = _manager(user_id)
    try:
        manager.require_terms()
        return manager.submit(
            group_id,
            consent=body.consent,
            adult_attested=body.adult_attested,
            accepting_requests=body.accepting_requests,
        )
    except ListingError as e:
        raise _http(e)
    finally:
        manager.close()


@explorer_router.post("/{user_id}/groups/{group_id}/listing/unpublish")
@limiter.limit(_rate("owner_write"), key_func=_user_key)
def unpublish_my_listing(
    request: Request, user_id: str, group_id: str, _: str = Depends(require_match("user_id")),
) -> dict:
    manager = _manager(user_id)
    try:
        return manager.unpublish(group_id)
    except ListingError as e:
        raise _http(e)
    finally:
        manager.close()


@explorer_router.delete("/{user_id}/groups/{group_id}/listing", status_code=204)
@limiter.limit(_rate("owner_write"), key_func=_user_key)
def delete_my_listing(
    request: Request, user_id: str, group_id: str, _: str = Depends(require_match("user_id")),
) -> None:
    manager = _manager(user_id)
    try:
        manager.delete_listing(group_id)
    except ListingError as e:
        raise _http(e)
    finally:
        manager.close()
