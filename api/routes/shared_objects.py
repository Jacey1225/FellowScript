"""Read-only access to a note shared into a chat (flag ``chat_shared_objects``).

  GET /shared-objects/{user_id}/note/{message_id}

The share grant is the chat message itself (see
``backend/interactions/shared_objects.py``). Flag off, malformed or unknown id,
not a participant, blocked pair, soft-deleted message, note gone, or sender no
longer allowed to share it: ONE identical 404, no oracle. Never writes.
"""
from fastapi import APIRouter, Depends, HTTPException, Request

from backend.auth.dependencies import require_match
from backend.interactions import flags
from backend.interactions.shared_objects import FLAG, SharedNoteReader, view_rate
from backend.rate_limiting import limiter

shared_objects_router = APIRouter(prefix="/shared-objects")


def _user_key(request: Request) -> str:
    return f"shared-objects-user:{request.path_params.get('user_id')}"


@shared_objects_router.get("/{user_id}/note/{message_id}")
@limiter.shared_limit(view_rate, scope="shared_objects_view", key_func=_user_key)
def get_shared_note(
    request: Request, user_id: str, message_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    if not flags.is_enabled(FLAG, user_id):
        raise HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})
    db = SharedNoteReader(user_id)
    try:
        note = db.open_note(message_id)
    finally:
        db.close()
    if note is None:
        raise HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})
    return note
