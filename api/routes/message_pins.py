"""Pinned chat messages (flag ``message_pins``, default OFF).

  POST   /message-pins/{user_id}/{message_id}          pin (idempotent)
  DELETE /message-pins/{user_id}/{message_id}          unpin (idempotent)
  GET    /message-pins/{user_id}/group/{group_id}      list, newest pin first
  GET    /message-pins/{user_id}/dm/{friend_id}        list, newest pin first

Rules: R-ROUTE (plain ``def``); ``require_match`` resolves the path user against
the session first. Flag off, unknown / malformed id, not a member or
participant, blocked pair, soft-deleted message: ONE identical 404 (no oracle).
There is no cap on pins. Pin requires current terms; unpin and list do not.
Rate limits from ``chat.json`` ``message_pins``, one bucket per user. Live frames
are best effort and never fail the request. A newly added pin also writes a
server-generated system line and sends a push to the other members, both
throttled by one atomic claim. Behaviour lives in
``backend/interactions/message_pins.py``.
"""
import logging

import anyio.from_thread
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request

from backend.auth.dependencies import require_match
from backend.auth.terms import require_current_terms
from backend.interactions import flags, paging
from backend.interactions.message_delete import fan_out
from backend.interactions.message_pins import (
    FLAG, MessagePinsManager, SYSTEM_KIND, list_rate, pin_frame, pin_rate,
)
from backend.interactions.pin_push import notify_message_pin
from backend.rate_limiting import limiter
from routes.messaging import manager as ws_manager

message_pins_router = APIRouter(prefix="/message-pins")
logger = logging.getLogger(__name__)


def _user_key(request: Request) -> str:
    return f"message-pins-user:{request.path_params.get('user_id')}"


def _not_found() -> HTTPException:
    return HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})


def _push_frame(recipients: list[str], frame: dict) -> None:
    try:
        anyio.from_thread.run(fan_out, ws_manager, recipients, frame)
    except Exception as e:  # noqa: BLE001 - the write already committed
        logger.warning("Pin frame fan-out failed: %s", type(e).__name__)


def _line_frame(result: dict, user_id: str) -> dict:
    line = result["system_line"]
    return {
        "from_user": user_id.lower(), "text": line["text"], "group_id": result["group_id"],
        "timestamp": paging.format_timestamp(line["timestamp"]), "attachment_kind": None,
        "attachment_meta": {}, "attachment_url": None, "id": line["id"], "system_kind": SYSTEM_KIND,
    }


@message_pins_router.post("/{user_id}/{message_id}")
@limiter.shared_limit(pin_rate, scope="message_pins", key_func=_user_key)
def pin_message(
    request: Request, background: BackgroundTasks, user_id: str, message_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotently pin. Returns ``{message_id, pinned: true}``."""
    if not flags.is_enabled(FLAG, user_id):
        raise _not_found()
    db = MessagePinsManager(user_id)
    try:
        require_current_terms(db.cur, user_id)
        result = db.pin(message_id)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    if result["changed"]:
        _push_frame(result["recipients"], pin_frame(result["message_id"], result["group_id"], True, user_id.lower()))
        if result["system_line"]:
            _push_frame(result["recipients"], _line_frame(result, user_id))
        if result["notify"]:
            background.add_task(
                notify_message_pin, result["group_id"], user_id, result["message_id"], result["recipients"],
            )
    return {"message_id": result["message_id"], "pinned": True}


@message_pins_router.delete("/{user_id}/{message_id}")
@limiter.shared_limit(pin_rate, scope="message_pins", key_func=_user_key)
def unpin_message(
    request: Request, user_id: str, message_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotently unpin. Returns ``{message_id, pinned: false}``."""
    if not flags.is_enabled(FLAG, user_id):
        raise _not_found()
    db = MessagePinsManager(user_id)
    try:
        result = db.unpin(message_id)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    if result["changed"]:
        _push_frame(result["recipients"], pin_frame(result["message_id"], result["group_id"], False, user_id.lower()))
    return {"message_id": result["message_id"], "pinned": False}


def _list(user_id: str, limit: int, offset: int, **scope) -> dict:
    if not flags.is_enabled(FLAG, user_id):
        raise _not_found()
    db = MessagePinsManager(user_id)
    try:
        result = db.list_pins(limit=limit, offset=offset, **scope)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    return result


@message_pins_router.get("/{user_id}/group/{group_id}")
@limiter.shared_limit(list_rate, scope="message_pins_list", key_func=_user_key)
def list_group_pins(
    request: Request, user_id: str, group_id: str,
    limit: int = Query(50, ge=1, le=1000), offset: int = Query(0, ge=0, le=100000),
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Pinned messages of a group the caller belongs to."""
    return _list(user_id, limit, offset, group_id=group_id)


@message_pins_router.get("/{user_id}/dm/{friend_id}")
@limiter.shared_limit(list_rate, scope="message_pins_list", key_func=_user_key)
def list_dm_pins(
    request: Request, user_id: str, friend_id: str,
    limit: int = Query(50, ge=1, le=1000), offset: int = Query(0, ge=0, le=100000),
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Pinned messages of the DM between the caller and ``friend_id``."""
    return _list(user_id, limit, offset, friend_id=friend_id)
