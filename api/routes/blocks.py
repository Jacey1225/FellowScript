from fastapi import APIRouter, HTTPException, Depends

from backend.auth.dependencies import require_match
from backend.interactions.blocks import BlockManager

block_router = APIRouter(prefix="/blocks")


@block_router.get("/{user_id}")
async def get_blocked(user_id: str, _: str = Depends(require_match("user_id"))) -> list[dict]:
    """List every user the caller has blocked."""
    manager = BlockManager(user_id)
    try:
        return manager.list_blocked()
    finally:
        manager.close()


@block_router.post("/{user_id}/{blocked_id}", status_code=204)
async def block_user(user_id: str, blocked_id: str, _: str = Depends(require_match("user_id"))) -> None:
    """Block another user (Guideline 1.2).

    Immediately severs any existing friendship/pending request both
    directions and files an automatic report so the developer is notified,
    per the 24-hour response commitment.

    Raises:
        HTTPException 400: If attempting to block yourself.
    """
    manager = BlockManager(user_id)
    try:
        result = manager.block_user(blocked_id)
        if result and "error" in result:
            raise HTTPException(status_code=400, detail=result["error"])
    finally:
        manager.close()


@block_router.delete("/{user_id}/{blocked_id}", status_code=204)
async def unblock_user(user_id: str, blocked_id: str, _: str = Depends(require_match("user_id"))) -> None:
    manager = BlockManager(user_id)
    try:
        manager.unblock_user(blocked_id)
    finally:
        manager.close()
