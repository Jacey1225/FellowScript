"""Group message delete / undo (flag ``message_delete``).

  DELETE /groups/{user_id}/{group_id}/messages/{message_id}          soft delete (author only)
  POST   /groups/{user_id}/{group_id}/messages/{message_id}/restore  undo within ``undo_seconds``

Rules: R-ROUTE (plain ``def``, threadpool); ``require_match`` resolves the path
user against the session first; every other failure (flag off for the caller,
unknown or malformed id, not the author, not a current member, wrong group,
already deleted, outside the undo window, suspended author) is ONE identical
404, so the routes are no oracle for ids, membership or message state. Not
gated by ``require_current_terms``: a delete is not new user content. Rate
limits come from ``chat.json`` ``message_delete``. Live fan-out frames are
best effort and never fail the request. Behaviour lives in
``backend/interactions/message_delete.py``.
"""
import logging

import anyio.from_thread
from fastapi import APIRouter, Depends, HTTPException, Request

from backend.auth.dependencies import require_match
from backend.interactions import flags
from backend.interactions.message_delete import (
    MessageDeleteManager, audit, deleted_frame, fan_out, restored_frame,
)
from backend.interactions.threads_config import get_message_delete_config
from backend.rate_limiting import limiter
from routes.messaging import manager as ws_manager

messages_delete_router = APIRouter(prefix="/groups")
logger = logging.getLogger(__name__)


def _delete_rate() -> str:
    return get_message_delete_config().delete_rate


def _restore_rate() -> str:
    return get_message_delete_config().restore_rate


def _user_key(request: Request) -> str:
    # Runs after require_match resolved the path user_id against the session.
    # slowapi buckets by URL path (holds {message_id}); shared_limit with a fixed
    # scope on each decorator is what makes this one bucket per user.
    return f"message-delete-user:{request.path_params.get('user_id')}"


def _not_found() -> HTTPException:
    return HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})


def _push_frame(recipients: list[str], frame: dict) -> None:
    try:
        anyio.from_thread.run(fan_out, ws_manager, recipients, frame)
    except Exception as e:  # noqa: BLE001 - the delete already committed
        logger.warning("Message frame fan-out failed: %s", type(e).__name__)


@messages_delete_router.delete("/{user_id}/{group_id}/messages/{message_id}")
@limiter.shared_limit(_delete_rate, scope="message_delete", key_func=_user_key)
def delete_message(
    request: Request, user_id: str, group_id: str, message_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Soft-delete the caller's own message. Returns ``{"id", "undo_seconds"}``."""
    if not flags.is_enabled("message_delete", user_id):
        raise _not_found()
    db = MessageDeleteManager(user_id)
    try:
        result = db.delete(group_id, message_id)
        if result is None:
            raise _not_found()
        audit("DELETE", user_id, result["group_id"], result["id"])
        recipients = db.frame_recipients(result["group_id"], user_id.lower(), skip_blocked=False)
    finally:
        db.close()
    _push_frame(recipients, deleted_frame(result["group_id"], result["id"], result["deleted_at"]))
    return {"id": result["id"], "undo_seconds": result["undo_seconds"]}


@messages_delete_router.post("/{user_id}/{group_id}/messages/{message_id}/restore")
@limiter.shared_limit(_restore_rate, scope="message_restore", key_func=_user_key)
def restore_message(
    request: Request, user_id: str, group_id: str, message_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Undo a delete made by the caller within ``undo_seconds``. Returns ``{"id"}``."""
    if not flags.is_enabled("message_delete", user_id):
        raise _not_found()
    db = MessageDeleteManager(user_id)
    try:
        result = db.restore(group_id, message_id)
        if result is None:
            raise _not_found()
        audit("RESTORE", user_id, result["group_id"], result["id"])
        recipients = db.frame_recipients(result["group_id"], user_id.lower(), skip_blocked=True)
    finally:
        db.close()
    _push_frame(recipients, restored_frame(result))
    return {"id": result["id"]}
