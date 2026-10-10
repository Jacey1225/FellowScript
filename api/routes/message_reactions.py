"""Chat message emoji reactions (flag ``message_reactions``).

  POST   /message-reactions/{user_id}/{message_id}             body {"emoji"}
  DELETE /message-reactions/{user_id}/{message_id}?emoji=...

Rules: R-ROUTE (plain ``def``); ``require_match`` resolves the path user
against the session first. Flag off, unknown / malformed id, not a member or
participant, blocked pair, soft-deleted message: ONE identical 404 (no
oracle). A bad emoji is 422 (allowlist), a cap hit is 409. Add requires
current terms; remove does not. Rate limit from ``chat.json``
``message_reactions``, one bucket per user. Live frames are best effort and
never fail the request. Behaviour lives in
``backend/interactions/message_reactions.py``.
"""
import logging

import anyio.from_thread
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field

from backend.auth.dependencies import require_match
from backend.auth.terms import require_current_terms
from backend.interactions import flags
from backend.interactions.message_delete import fan_out
from backend.interactions.message_reactions import (
    FLAG, MAX_EMOJI_LENGTH, MessageReactionsManager, is_allowed_emoji, reaction_frame, reaction_rate,
)
from backend.interactions.reaction_highlight_push import notify_message_reaction
from backend.rate_limiting import limiter
from routes.messaging import manager as ws_manager

message_reactions_router = APIRouter(prefix="/message-reactions")
logger = logging.getLogger(__name__)


class ReactionRequest(BaseModel):
    emoji: str = Field(min_length=1, max_length=MAX_EMOJI_LENGTH)


def _user_key(request: Request) -> str:
    return f"message-reactions-user:{request.path_params.get('user_id')}"


def _not_found() -> HTTPException:
    return HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})


def _check_emoji(emoji: str) -> None:
    if not is_allowed_emoji(emoji):
        raise HTTPException(status_code=422, detail={"code": "invalid_emoji"})


def _push_frame(recipients: list[str], frame: dict) -> None:
    try:
        anyio.from_thread.run(fan_out, ws_manager, recipients, frame)
    except Exception as e:  # noqa: BLE001 - the write already committed
        logger.warning("Reaction frame fan-out failed: %s", type(e).__name__)


def _finish(result: dict, user_id: str) -> dict:
    reaction = result["reaction"]
    if result["changed"]:
        _push_frame(result["recipients"], reaction_frame(
            result["message_id"], result["group_id"], reaction["emoji"], reaction["count"], user_id.lower(),
        ))
    return reaction


@message_reactions_router.post("/{user_id}/{message_id}")
@limiter.shared_limit(reaction_rate, scope="message_reactions", key_func=_user_key)
def add_reaction(
    request: Request, background: BackgroundTasks, user_id: str, message_id: str, body: ReactionRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotently add the caller's reaction. Returns ``{emoji, count, viewer_reacted}``."""
    if not flags.is_enabled(FLAG, user_id):
        raise _not_found()
    _check_emoji(body.emoji)
    db = MessageReactionsManager(user_id)
    try:
        require_current_terms(db.cur, user_id)
        result = db.add(message_id, body.emoji)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    if "cap" in result:
        raise HTTPException(status_code=409, detail={"code": result["cap"]})
    if result["changed"]:
        # Reaction push to the message author (flag message_reaction_push): post-commit,
        # coalesced, best-effort. Removal never pushes.
        background.add_task(
            notify_message_reaction, result["message_id"], user_id, body.emoji, result["group_id"],
        )
    return _finish(result, user_id)


@message_reactions_router.delete("/{user_id}/{message_id}")
@limiter.shared_limit(reaction_rate, scope="message_reactions", key_func=_user_key)
def remove_reaction(
    request: Request, user_id: str, message_id: str,
    emoji: str = Query(min_length=1, max_length=MAX_EMOJI_LENGTH),
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotently remove the caller's reaction. Returns ``{emoji, count, viewer_reacted}``."""
    if not flags.is_enabled(FLAG, user_id):
        raise _not_found()
    _check_emoji(emoji)
    db = MessageReactionsManager(user_id)
    try:
        result = db.remove(message_id, emoji)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    return _finish(result, user_id)
