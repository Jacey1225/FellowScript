"""Discussion rooms over HTTP (flag ``discussion_rooms``). Task 20261009-discussion-rooms.

  GET    /session-rooms/{user_id}/sessions/{session_id}/rooms          list visible rooms of a live session
  POST   /session-rooms/{user_id}/sessions/{session_id}/rooms          create (mode open|invite_only, optional title, optional invites)
  POST   /session-rooms/{user_id}/rooms/{room_id}/join                 -> room + Chime Meeting + Attendee
  POST   /session-rooms/{user_id}/rooms/{room_id}/leave
  POST   /session-rooms/{user_id}/rooms/{room_id}/heartbeat            presence ping (client: every ~30s)
  PATCH  /session-rooms/{user_id}/rooms/{room_id}                      rename (creator)
  DELETE /session-rooms/{user_id}/rooms/{room_id}                      end (room creator or session host)
  GET    /session-rooms/{user_id}/rooms/{room_id}/invites              invite-only: creator or a current member
  POST   /session-rooms/{user_id}/rooms/{room_id}/invites              invite-only: creator or a current member
  DELETE /session-rooms/{user_id}/rooms/{room_id}/invites/{target_id}  invite-only: creator revokes

Rules: every route depends on ``require_match("user_id")`` (session user == path
user) and evaluates the flag for the CALLER; flag off is the same 404 as a
missing resource. Plain ``def`` handlers (row locks and Chime calls run in the
threadpool; every lock wait is bounded). Limits use ``shared_limit`` with FIXED
scopes keyed per user, never per path parameter. Behaviour and every
authorization decision live in ``backend/interactions/session_rooms.py``.
"""
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from backend.auth.dependencies import require_match
from backend.interactions import flags
from backend.interactions.session_rooms import RoomError, SessionRoomsManager
from backend.interactions.session_rooms_config import get_session_rooms_config
from backend.moderation.content_filter import ContentRejected, check_clean, rejection_message
from backend.rate_limiting import limiter

session_rooms_router = APIRouter(prefix="/session-rooms")


class CreateRoomBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str | None = None
    mode: str = "open"
    invite_user_ids: list[str] = Field(default_factory=list, max_length=250)


class RenameBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str | None = None


class InviteBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    user_ids: list[str] = Field(min_length=1, max_length=250)


def _rate(name: str):
    return lambda: get_session_rooms_config().rate_limits[name]


def _user_key(request: Request) -> str:
    # Runs after require_match resolved the path user_id against the session.
    return f"rooms-user:{request.path_params.get('user_id')}"


def _off() -> HTTPException:
    return HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})


def _gate(user_id: str) -> None:
    if not flags.is_enabled("discussion_rooms", user_id):
        raise _off()


def _clean_title(raw: str | None) -> str:
    """Strip, cap and content-filter an optional room name ('' = default "Room N")."""
    title = " ".join((raw or "").split())
    if not title:
        return ""
    if len(title) > get_session_rooms_config().title_max_length:
        raise HTTPException(
            status_code=422,
            detail={"code": "title_too_long", "message": "Room names are limited to "
                    f"{get_session_rooms_config().title_max_length} characters."},
        )
    try:
        check_clean(title=title)
    except ContentRejected as e:
        raise HTTPException(status_code=422, detail={"code": "title_rejected", "message": rejection_message(e)})
    return title


def _run(fn):
    """Open the manager, run ``fn(manager)``, always close; map domain errors."""
    manager = SessionRoomsManager()
    try:
        return fn(manager)
    except RoomError as e:
        raise HTTPException(status_code=e.status, detail=e.detail())
    finally:
        manager.close()


@session_rooms_router.get("/{user_id}/sessions/{session_id}/rooms")
@limiter.shared_limit(_rate("list"), scope="rooms_list", key_func=_user_key)
def list_rooms(request: Request, user_id: str, session_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    _gate(user_id)
    return _run(lambda m: m.list_rooms(user_id, session_id))


@session_rooms_router.post("/{user_id}/sessions/{session_id}/rooms", status_code=201)
@limiter.shared_limit(_rate("create"), scope="rooms_create", key_func=_user_key)
def create_room(
    request: Request, user_id: str, session_id: str, body: CreateRoomBody | None = None,
    _: str = Depends(require_match("user_id")),
) -> dict:
    _gate(user_id)
    body = body or CreateRoomBody()
    title = _clean_title(body.title)
    return _run(lambda m: m.create_room(user_id, session_id, title, body.mode, body.invite_user_ids))


@session_rooms_router.post("/{user_id}/rooms/{room_id}/join")
@limiter.shared_limit(_rate("join"), scope="rooms_join", key_func=_user_key)
def join_room(request: Request, user_id: str, room_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    _gate(user_id)
    return _run(lambda m: m.join_room(user_id, room_id))


@session_rooms_router.post("/{user_id}/rooms/{room_id}/leave")
@limiter.shared_limit(_rate("other"), scope="rooms_other", key_func=_user_key)
def leave_room(request: Request, user_id: str, room_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    _gate(user_id)
    return _run(lambda m: m.leave_room(user_id, room_id))


@session_rooms_router.post("/{user_id}/rooms/{room_id}/heartbeat")
@limiter.shared_limit(_rate("heartbeat"), scope="rooms_heartbeat", key_func=_user_key)
def heartbeat(request: Request, user_id: str, room_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    _gate(user_id)
    return _run(lambda m: m.heartbeat(user_id, room_id))


@session_rooms_router.patch("/{user_id}/rooms/{room_id}")
@limiter.shared_limit(_rate("other"), scope="rooms_other", key_func=_user_key)
def rename_room(
    request: Request, user_id: str, room_id: str, body: RenameBody,
    _: str = Depends(require_match("user_id")),
) -> dict:
    _gate(user_id)
    title = _clean_title(body.title)
    return _run(lambda m: m.rename_room(user_id, room_id, title))


@session_rooms_router.delete("/{user_id}/rooms/{room_id}")
@limiter.shared_limit(_rate("other"), scope="rooms_other", key_func=_user_key)
def end_room(request: Request, user_id: str, room_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    _gate(user_id)
    return _run(lambda m: m.end_room(user_id, room_id))


@session_rooms_router.get("/{user_id}/rooms/{room_id}/invites")
@limiter.shared_limit(_rate("other"), scope="rooms_other", key_func=_user_key)
def list_invites(request: Request, user_id: str, room_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    _gate(user_id)
    return _run(lambda m: m.list_invites(user_id, room_id))


@session_rooms_router.post("/{user_id}/rooms/{room_id}/invites", status_code=201)
@limiter.shared_limit(_rate("other"), scope="rooms_other", key_func=_user_key)
def invite(
    request: Request, user_id: str, room_id: str, body: InviteBody,
    _: str = Depends(require_match("user_id")),
) -> dict:
    _gate(user_id)
    return _run(lambda m: m.invite(user_id, room_id, body.user_ids))


@session_rooms_router.delete("/{user_id}/rooms/{room_id}/invites/{target_id}")
@limiter.shared_limit(_rate("other"), scope="rooms_other", key_func=_user_key)
def revoke_invite(
    request: Request, user_id: str, room_id: str, target_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    _gate(user_id)
    return _run(lambda m: m.revoke_invite(user_id, room_id, target_id))
