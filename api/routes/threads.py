"""Group message threads over HTTP (flag ``threads``).

  POST /groups/{user_id}/{group_id}/threads                          start (or open) the thread on a message
  GET  /groups/{user_id}/{group_id}/threads                          list, keyset on (last_activity_at, id)
  GET  /groups/{user_id}/{group_id}/threads/{thread_id}/messages     one page of a thread's messages
  POST /groups/{user_id}/{group_id}/threads/{thread_id}/read         mark the thread read for the caller
  POST   /groups/{u}/{g}/threads/{t}/messages/{message_id}/reactions     add a reaction, body {"emoji"}
  DELETE /groups/{u}/{g}/threads/{t}/messages/{message_id}/reactions?emoji=...
  POST   /groups/{u}/{g}/threads/{t}/messages/{message_id}/pin           pin inside the thread
  DELETE /groups/{u}/{g}/threads/{t}/messages/{message_id}/pin          unpin
  GET    /groups/{u}/{g}/threads/{t}/pins                                 the thread's pins, newest first
  PUT  /groups/{user_id}/{group_id}/threads/{thread_id}              rename (creator only)
  DELETE /groups/{user_id}/{group_id}/threads/{thread_id}            hard delete (creator or group owner)

Rules: R-ROUTE (plain ``def``, runs in the threadpool); ``require_match``
resolves the path user against the session first; every other denial (flag off
for the caller, malformed or unknown id, not a current member, a thread or
message of another group, a root the caller cannot see, not the creator) is ONE
identical 404 so the routes are no oracle. Thread create (not rename, not read)
calls ``require_current_terms`` (403 ``terms_reaccept_required``) after
membership is established. Per-user limits use ``shared_limit`` with a FIXED
scope (slowapi buckets by URL path otherwise, and these paths hold ids).
Sending to a thread is a WebSocket frame, see ``thread_send``. Behaviour lives
in ``backend/interactions/threads.py``; the list route is in the same router so
``group_info.py`` stays untouched.
"""
import logging
import re

import anyio.from_thread
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

from backend.auth.dependencies import require_match
from backend.auth.terms import require_current_terms
from backend.interactions import flags, paging
from backend.interactions.chat_config import get_pagination_config
from backend.interactions.threads import (
    InvalidTitleError, LIST_MAX_PAGE_SIZE, LIST_PAGE_SIZE, ThreadLimitError, ThreadsManager, audit,
    thread_deleted_frame,
)
from backend.interactions import thread_message_actions as tma
from backend.interactions.message_pins import FLAG as PINS_FLAG, list_rate as pins_list_rate, pin_rate
from backend.interactions.message_reactions import (
    FLAG as REACTIONS_FLAG, MAX_EMOJI_LENGTH, is_allowed_emoji, reaction_rate,
)
from backend.interactions.threads_config import get_threads_config
from backend.moderation.content_filter import ContentRejected, check_clean, rejection_message
from backend.interactions.message_delete import fan_out
from backend.rate_limiting import limiter
from routes.messaging import manager as ws_manager

threads_router = APIRouter(prefix="/groups")
logger = logging.getLogger(__name__)

_LIMIT_RE = re.compile(r"[+-]?[0-9]{1,64}", re.ASCII)


class CreateThreadRequest(BaseModel):
    message_id: str
    title: str | None = None


class RenameThreadRequest(BaseModel):
    title: str


class ThreadReactionRequest(BaseModel):
    emoji: str = Field(min_length=1, max_length=MAX_EMOJI_LENGTH)


def _create_rate() -> str:
    return get_threads_config().create_rate


def _read_rate() -> str:
    return get_pagination_config().rate_limits["messages_page"]


def _delete_rate() -> str:
    return get_threads_config().delete_rate


def _user_key(request: Request) -> str:
    return f"threads-user:{request.path_params.get('user_id')}"


def _not_found() -> HTTPException:
    return HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})


def _page_limit(raw: str | None, default: int, maximum: int) -> int:
    if raw is None:
        return default
    if not _LIMIT_RE.fullmatch(raw) or int(raw) < 1:
        raise HTTPException(status_code=422, detail={"code": "invalid_limit"})
    return paging.clamp_limit(int(raw), default, maximum)


def _cursor(request: Request, *, with_seq: bool):
    params = {
        k: request.query_params[k]
        for k in ("cursor_timestamp", "cursor_seq", "cursor_id")
        if k in request.query_params
    }
    return paging.decode_cursor(params, id_type="uuid", with_seq=with_seq)


def _title_error(e: InvalidTitleError) -> HTTPException:
    return HTTPException(status_code=422, detail={"code": "invalid_title"})


def _filter_title(title) -> None:
    if isinstance(title, str) and title.strip():
        try:
            check_clean(title=title)
        except ContentRejected as e:
            raise HTTPException(status_code=422, detail=rejection_message(e))


@threads_router.post("/{user_id}/{group_id}/threads", status_code=201)
@limiter.shared_limit(_create_rate, scope="thread_create", key_func=_user_key)
def create_thread(
    request: Request, response: Response, user_id: str, group_id: str, body: CreateThreadRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Start the thread anchored on ``message_id`` or open the one that exists.

    Returns the thread summary ``{id, group_id, title, root_preview,
    root_message_id, root_deleted, reply_count, last_activity_at, created_by,
    created}``; status 201 when created, 200 when it already existed. A blank
    ``title`` is auto-generated from the root message.
    """
    if not flags.is_enabled("threads", user_id):
        raise _not_found()
    db = ThreadsManager(user_id)
    try:
        if not db.is_member(group_id):
            raise _not_found()
        require_current_terms(db.cur, user_id)
        db.conn.rollback()
        _filter_title(body.title)
        try:
            result = db.create_thread(group_id, body.message_id, body.title)
        except InvalidTitleError as e:
            raise _title_error(e)
        except ThreadLimitError:
            raise HTTPException(status_code=409, detail={"code": "thread_limit"})
        if result is None:
            raise _not_found()
        summary, created = result
    finally:
        db.close()
    if created:
        audit("CREATE", user_id, summary["group_id"], summary["id"])
    else:
        response.status_code = 200
    return {**summary, "created": created}


@threads_router.get("/{user_id}/{group_id}/threads")
@limiter.shared_limit(_read_rate, scope="threads_list", key_func=_user_key)
def list_threads(
    request: Request, user_id: str, group_id: str,
    limit: str | None = None, cursor_timestamp: str | None = None, cursor_id: str | None = None,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """The group's threads, most recently active first.

    Returns ``{"threads": [{id, title, root_preview, root_deleted, reply_count,
    last_activity_at, created_by, unread_count}], "page": {...}}``; ``unread_count``
    is the caller's per-thread unread total (others' live messages past the
    caller's read marker; own and blocked senders never count); ``next_cursor_seq`` is
    always null and clients omit ``cursor_seq``.
    """
    if not flags.is_enabled("threads", user_id):
        raise _not_found()
    page_limit = _page_limit(limit, LIST_PAGE_SIZE, LIST_MAX_PAGE_SIZE)
    cursor = _cursor(request, with_seq=False)
    db = ThreadsManager(user_id)
    try:
        page = db.list_threads(group_id, page_limit, cursor)
    finally:
        db.close()
    if page is None:
        raise _not_found()
    return paging.envelope("threads", page["threads"], page_limit, page["has_more"], page["next_cursor"])


@threads_router.get("/{user_id}/{group_id}/threads/{thread_id}/messages")
@limiter.shared_limit(_read_rate, scope="thread_messages_page", key_func=_user_key)
def read_thread_messages(
    request: Request, user_id: str, group_id: str, thread_id: str,
    limit: str | None = None, cursor_timestamp: str | None = None,
    cursor_seq: str | None = None, cursor_id: str | None = None,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """One page of a thread's messages: the main chat's page envelope and row
    shape plus ``thread_id`` on each row. Membership, the thread's own group
    and the author set are re-checked on every page."""
    if not flags.is_enabled("threads", user_id):
        raise _not_found()
    cfg = get_pagination_config()
    page_limit = _page_limit(limit, cfg.page_size, cfg.max_page_size)
    cursor = _cursor(request, with_seq=True)
    db = ThreadsManager(user_id)
    try:
        page = db.read_messages(group_id, thread_id, page_limit, cursor)
    finally:
        db.close()
    if page is None:
        raise _not_found()
    return paging.envelope("messages", page["messages"], page_limit, page["has_more"], page["next_cursor"])


@threads_router.post("/{user_id}/{group_id}/threads/{thread_id}/read")
@limiter.shared_limit(_read_rate, scope="thread_mark_read", key_func=_user_key)
def mark_thread_read(
    request: Request, user_id: str, group_id: str, thread_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Mark the thread read for the caller: ``{"thread_id", "unread_count": 0}``.
    Non-members and unknown or other-group threads get the uniform 404."""
    if not flags.is_enabled("threads", user_id):
        raise _not_found()
    db = ThreadsManager(user_id)
    try:
        result = db.mark_read(group_id, thread_id)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    return result


@threads_router.put("/{user_id}/{group_id}/threads/{thread_id}")
@limiter.shared_limit(_create_rate, scope="thread_rename", key_func=_user_key)
def rename_thread(
    request: Request, user_id: str, group_id: str, thread_id: str, body: RenameThreadRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Rename a thread. Only its creator may; anyone else gets the uniform 404."""
    if not flags.is_enabled("threads", user_id):
        raise _not_found()
    _filter_title(body.title)
    db = ThreadsManager(user_id)
    try:
        try:
            result = db.rename_thread(group_id, thread_id, body.title)
        except InvalidTitleError as e:
            raise _title_error(e)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    audit("RENAME", user_id, group_id.lower(), result["id"])
    return result


@threads_router.delete("/{user_id}/{group_id}/threads/{thread_id}", status_code=204)
@limiter.shared_limit(_delete_rate, scope="thread_delete", key_func=_user_key)
def delete_thread(
    request: Request, user_id: str, group_id: str, thread_id: str,
    _: str = Depends(require_match("user_id")),
) -> Response:
    """Hard-delete a thread and its messages. Only its creator or the group
    owner may; every other case (including a repeat delete) is the uniform 404.
    Members' open sockets get a ``thread_deleted`` frame; no push."""
    if not flags.is_enabled("threads", user_id):
        raise _not_found()
    db = ThreadsManager(user_id)
    try:
        result = db.delete_thread(group_id, thread_id)
        if result is None:
            raise _not_found()
        audit("DELETE", user_id, result["group_id"], result["id"])
        recipients = db.frame_recipients(result["group_id"])
    finally:
        db.close()
    try:
        anyio.from_thread.run(fan_out, ws_manager, recipients, thread_deleted_frame(result["group_id"], result["id"]))
    except Exception as e:  # noqa: BLE001 - the delete already committed
        logger.warning("Thread-deleted fan-out failed: %s", type(e).__name__)
    return Response(status_code=204)


# ---- thread message reactions and pins (see backend/interactions/thread_message_actions.py) ----

def _push_frame(recipients: list[str], frame: dict) -> None:
    try:
        anyio.from_thread.run(fan_out, ws_manager, recipients, frame)
    except Exception as e:  # noqa: BLE001 - the write already committed
        logger.warning("Thread action frame fan-out failed: %s", type(e).__name__)


def _gate(user_id: str, flag: str) -> None:
    """Both the ``threads`` flag and the feature flag must be on for the caller."""
    if not flags.is_enabled("threads", user_id) or not flags.is_enabled(flag, user_id):
        raise _not_found()


def _check_emoji(emoji: str) -> None:
    if not is_allowed_emoji(emoji):
        raise HTTPException(status_code=422, detail={"code": "invalid_emoji"})


def _reaction_done(result: dict, user_id: str) -> dict:
    reaction = result["reaction"]
    if result["changed"]:
        _push_frame(result["recipients"], tma.reaction_frame(
            result["thread_id"], result["group_id"], result["message_id"],
            reaction["emoji"], reaction["count"], user_id.lower(),
        ))
    return reaction


@threads_router.post("/{user_id}/{group_id}/threads/{thread_id}/messages/{message_id}/reactions")
@limiter.shared_limit(reaction_rate, scope="thread_message_reactions", key_func=_user_key)
def add_thread_reaction(
    request: Request, user_id: str, group_id: str, thread_id: str, message_id: str, body: ThreadReactionRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotently add the caller's reaction. Returns ``{emoji, count, viewer_reacted}``;
    422 bad emoji, 409 ``message_cap`` / ``user_cap``, uniform 404 otherwise."""
    _gate(user_id, REACTIONS_FLAG)
    _check_emoji(body.emoji)
    db = tma.ThreadMessageActions(user_id)
    try:
        if not db.is_member_quiet(group_id):
            raise _not_found()
        require_current_terms(db.cur, user_id)
        db.conn.rollback()
        result = db.add_reaction(group_id, thread_id, message_id, body.emoji)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    if "cap" in result:
        raise HTTPException(status_code=409, detail={"code": result["cap"]})
    return _reaction_done(result, user_id)


@threads_router.delete("/{user_id}/{group_id}/threads/{thread_id}/messages/{message_id}/reactions")
@limiter.shared_limit(reaction_rate, scope="thread_message_reactions", key_func=_user_key)
def remove_thread_reaction(
    request: Request, user_id: str, group_id: str, thread_id: str, message_id: str,
    emoji: str = Query(min_length=1, max_length=MAX_EMOJI_LENGTH),
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotently remove the caller's reaction. Returns ``{emoji, count, viewer_reacted}``."""
    _gate(user_id, REACTIONS_FLAG)
    _check_emoji(emoji)
    db = tma.ThreadMessageActions(user_id)
    try:
        result = db.remove_reaction(group_id, thread_id, message_id, emoji)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    return _reaction_done(result, user_id)


@threads_router.post("/{user_id}/{group_id}/threads/{thread_id}/messages/{message_id}/pin")
@limiter.shared_limit(pin_rate, scope="thread_message_pins", key_func=_user_key)
def pin_thread_message(
    request: Request, user_id: str, group_id: str, thread_id: str, message_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotently pin inside the thread. Returns ``{message_id, thread_id, pinned: true}``."""
    _gate(user_id, PINS_FLAG)
    db = tma.ThreadMessageActions(user_id)
    try:
        if not db.is_member_quiet(group_id):
            raise _not_found()
        require_current_terms(db.cur, user_id)
        db.conn.rollback()
        result = db.pin(group_id, thread_id, message_id)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    if result["changed"]:
        _push_frame(result["recipients"], tma.pin_frame(
            result["thread_id"], result["group_id"], result["message_id"], True, user_id.lower()))
    return {"message_id": result["message_id"], "thread_id": result["thread_id"], "pinned": True}


@threads_router.delete("/{user_id}/{group_id}/threads/{thread_id}/messages/{message_id}/pin")
@limiter.shared_limit(pin_rate, scope="thread_message_pins", key_func=_user_key)
def unpin_thread_message(
    request: Request, user_id: str, group_id: str, thread_id: str, message_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotently unpin. Returns ``{message_id, thread_id, pinned: false}``."""
    _gate(user_id, PINS_FLAG)
    db = tma.ThreadMessageActions(user_id)
    try:
        result = db.unpin(group_id, thread_id, message_id)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    if result["changed"]:
        _push_frame(result["recipients"], tma.pin_frame(
            result["thread_id"], result["group_id"], result["message_id"], False, user_id.lower()))
    return {"message_id": result["message_id"], "thread_id": result["thread_id"], "pinned": False}


@threads_router.get("/{user_id}/{group_id}/threads/{thread_id}/pins")
@limiter.shared_limit(pins_list_rate, scope="thread_pins_list", key_func=_user_key)
def list_thread_pins(
    request: Request, user_id: str, group_id: str, thread_id: str,
    limit: int = Query(50, ge=1, le=1000), offset: int = Query(0, ge=0, le=100000),
    _: str = Depends(require_match("user_id")),
) -> dict:
    """The thread's pinned messages, newest pin first: ``{pins: [{message_id,
    pinned_by_id, pinned_by, pinned_at, message: {id, thread_id, from_user_id,
    from_user, text, timestamp, attachment_kind}}], has_more, count}``."""
    _gate(user_id, PINS_FLAG)
    db = tma.ThreadMessageActions(user_id)
    try:
        result = db.list_pins(group_id, thread_id, limit, offset)
    finally:
        db.close()
    if result is None:
        raise _not_found()
    return result
