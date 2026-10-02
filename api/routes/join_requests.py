"""Join requests over HTTP (flag ``join_requests``).

  POST /join-requests/{user_id}/listings/{public_id}/request            ask to join a published listing
  GET  /join-requests/{user_id}/requests[?public_id=]                   my requests (optionally for one listing)
  POST /join-requests/{user_id}/requests/{request_id}/withdraw          withdraw my pending request
  GET  /join-requests/{user_id}/groups/{group_id}/requests              owner: pending list, pending_count, accepting_requests
  POST /join-requests/{user_id}/groups/{group_id}/requests/{request_id}/approve
  POST /join-requests/{user_id}/groups/{group_id}/requests/{request_id}/deny        body {block_reapply}
  POST /join-requests/{user_id}/groups/{group_id}/requests/{request_id}/undo-deny
  PUT  /join-requests/{user_id}/groups/{group_id}/accepting             body {"accepting": bool}

Rules: R-ROUTE (plain ``def``, runs in the threadpool because approve takes row
locks; every lock wait is bounded by ``join_requests.lock_timeout_ms`` and
answers 409 ``busy``). ``require_match`` resolves the path user against the
session first. The flag ``join_requests`` is evaluated for the CALLER on every
route and a flag-off hit is the same 404 as a missing resource. Creating a
request additionally needs ``explorer_browse`` on and the listing owner inside
the flag (a request an owner could not see is never created); the owner-facing
routes need only the caller's flag plus the approver check, so an owner can
still clear the queue or switch the intake off during a browse rollback.
Per-user and per-IP limits use ``shared_limit`` with FIXED scopes (slowapi
buckets by URL path otherwise, and these paths hold ids).

Behaviour lives in ``backend/interactions/join_requests.py``; this module is
auth, flags, rate limits, body validation and HTTP mapping. Push notifications
are post-commit background tasks (``join_request_notifier``).
"""
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, StrictBool

from backend.auth.dependencies import require_match
from backend.interactions import flags, listings
from backend.interactions import join_request_notifier
from backend.interactions.join_requests import JoinRequestError, JoinRequestsManager, canon, clean_note
from backend.interactions.join_requests_config import get_join_requests_config
from backend.moderation.content_filter import ContentRejected, check_clean, rejection_message
from backend.rate_limiting import limiter

join_requests_router = APIRouter(prefix="/join-requests")


class CreateRequestBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    note: str | None = None


class DenyBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    block_reapply: StrictBool = False


class AcceptingBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    accepting: StrictBool


def _rate(name: str):
    return lambda: get_join_requests_config().rate_limits[name]


def _user_key(request: Request) -> str:
    # Runs after require_match resolved the path user_id against the session.
    return f"jrq-user:{request.path_params.get('user_id')}"


def _off() -> HTTPException:
    return HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})


def _http(err: JoinRequestError) -> HTTPException:
    return HTTPException(status_code=err.status, detail=err.detail())


def _gate(user_id: str) -> None:
    """Flag ``join_requests`` for the caller; off is the uniform 404."""
    if not flags.is_enabled("join_requests", user_id):
        raise _off()


def _run(user_id: str, fn):
    """Open the manager, run ``fn(manager)``, always close; map domain errors."""
    manager = JoinRequestsManager(user_id)
    try:
        return fn(manager)
    except JoinRequestError as e:
        raise _http(e)
    finally:
        manager.close()


@join_requests_router.post("/{user_id}/listings/{public_id}/request", status_code=201)
@limiter.shared_limit(_rate("create"), scope="jrq_create", key_func=_user_key)
@limiter.shared_limit(_rate("create_ip"), scope="jrq_create_ip")
def create_request(
    request: Request, response: Response, background: BackgroundTasks,
    user_id: str, public_id: str, body: CreateRequestBody | None = None,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Ask to join the listing. 201 when a new request was created, 200 for an
    idempotent repeat or an ``already_member`` answer (given only to a member)."""
    _gate(user_id)
    if not flags.is_enabled("explorer_browse", user_id) or not listings.is_public_id(public_id):
        raise _off()
    cfg = get_join_requests_config()
    try:
        note = clean_note(body.note if body else None, cfg.note_max_length)
    except JoinRequestError as e:
        raise _http(e)
    if note:
        try:
            check_clean(note=note)
        except ContentRejected as e:
            raise HTTPException(status_code=422, detail={"code": "note_rejected", "message": rejection_message(e)})
    result = _run(user_id, lambda m: m.create(public_id, note))
    if not result["created"]:
        response.status_code = 200
    else:
        background.add_task(join_request_notifier.notify_owner_of_request, result["id"])
    return {k: v for k, v in result.items() if k != "created"}


@join_requests_router.get("/{user_id}/requests")
@limiter.shared_limit(_rate("mine"), scope="jrq_mine", key_func=_user_key)
def my_requests(
    request: Request, user_id: str, public_id: str | None = None,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """The caller's own requests, newest first (statuses pending, approved,
    not_approved, withdrawn); with ``public_id`` also ``already_member``."""
    _gate(user_id)
    return _run(user_id, lambda m: m.my_requests(public_id))


@join_requests_router.post("/{user_id}/requests/{request_id}/withdraw")
@limiter.shared_limit(_rate("withdraw"), scope="jrq_withdraw", key_func=_user_key)
def withdraw_request(
    request: Request, user_id: str, request_id: str, _: str = Depends(require_match("user_id")),
) -> dict:
    _gate(user_id)
    return _run(user_id, lambda m: m.withdraw(request_id))


@join_requests_router.get("/{user_id}/groups/{group_id}/requests")
@limiter.shared_limit(_rate("owner_read"), scope="jrq_owner_read", key_func=_user_key)
def list_group_requests(
    request: Request, user_id: str, group_id: str, _: str = Depends(require_match("user_id")),
) -> dict:
    """Owner only (404 for everyone else): ``{accepting_requests, pending_count,
    requests: [{id, applicant_user_id, username, profile_photo_url, note,
    created_at}]}``. ``applicant_user_id`` exists only for Report and Block."""
    _gate(user_id)
    return _run(user_id, lambda m: m.list_pending(group_id))


@join_requests_router.post("/{user_id}/groups/{group_id}/requests/{request_id}/approve")
@limiter.shared_limit(_rate("decide"), scope="jrq_decide", key_func=_user_key)
def approve_request(
    request: Request, background: BackgroundTasks,
    user_id: str, group_id: str, request_id: str, _: str = Depends(require_match("user_id")),
) -> dict:
    """Add the applicant to the group (cap and blocks re-checked under the group
    lock). 409 ``group_full`` leaves the request pending; 409 ``busy`` is a
    bounded lock-wait timeout."""
    _gate(user_id)
    result = _run(user_id, lambda m: m.approve(group_id, request_id))
    if result.pop("applied"):
        background.add_task(join_request_notifier.notify_requester_approved, canon(request_id))
    return result


@join_requests_router.post("/{user_id}/groups/{group_id}/requests/{request_id}/deny")
@limiter.shared_limit(_rate("decide"), scope="jrq_decide", key_func=_user_key)
def deny_request(
    request: Request, user_id: str, group_id: str, request_id: str, body: DenyBody | None = None,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Deny; the applicant is not notified. Undo is open for ``undo_seconds``."""
    _gate(user_id)
    block = bool(body.block_reapply) if body else False
    return _run(user_id, lambda m: m.deny(group_id, request_id, block))


@join_requests_router.post("/{user_id}/groups/{group_id}/requests/{request_id}/undo-deny")
@limiter.shared_limit(_rate("decide"), scope="jrq_decide", key_func=_user_key)
def undo_deny_request(
    request: Request, user_id: str, group_id: str, request_id: str, _: str = Depends(require_match("user_id")),
) -> dict:
    _gate(user_id)
    return _run(user_id, lambda m: m.undo_deny(group_id, request_id))


@join_requests_router.put("/{user_id}/groups/{group_id}/accepting")
@limiter.shared_limit(_rate("accepting"), scope="jrq_accepting", key_func=_user_key)
def set_accepting(
    request: Request, user_id: str, group_id: str, body: AcceptingBody,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Switch intake of NEW requests on or off for the group's listing. Needs
    only the ``join_requests`` flag (not ``explorer_browse``), so an owner can
    switch off during a rollback. Pending requests are untouched."""
    _gate(user_id)
    return _run(user_id, lambda m: m.set_accepting(group_id, body.accepting))
