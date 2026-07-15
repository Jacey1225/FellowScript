from fastapi import APIRouter, HTTPException
from backend.subscription.subscriptions import SubscriptionsManager
from schemas.subscription import SubscriptionCreate, SubscriptionUpdate

subscription_router = APIRouter(prefix="/subscriptions")


# ── Plans: CRUD ────────────────────────────────────────────────────────────────

@subscription_router.post("/", status_code=201)
async def create_subscription(sub: SubscriptionCreate) -> dict:
    """Start a new subscription plan; the host becomes its first member.

    Args:
        sub: Plan payload. ``plan_type`` ('individual' | 'group') determines the
            price and member cap server-side.

    Returns:
        dict: ``{"id": str}`` of the created plan.
    """
    db = SubscriptionsManager()
    try:
        return {"id": db.create_subscription(sub)}
    finally:
        db.close()


# NOTE: static-prefix routes ("/user/...") are declared before the "/{subscription_id}"
# wildcard so their literal segment matches first.

@subscription_router.get("/user/{user_id}")
async def get_user_subscription(user_id: str) -> dict:
    """Return the plan the given user currently belongs to.

    Raises:
        HTTPException 404: If the user is not on any plan.
    """
    db = SubscriptionsManager()
    try:
        result = db.get_user_subscription(user_id)
        if result is None:
            raise HTTPException(status_code=404, detail="No active subscription")
        return result
    finally:
        db.close()


@subscription_router.get("/user/{user_id}/requests")
async def get_user_requests(user_id: str) -> list[dict]:
    """List the group plans this user has an outstanding join request for."""
    db = SubscriptionsManager()
    try:
        return db.get_user_requests(user_id)
    finally:
        db.close()


@subscription_router.get("/{subscription_id}")
async def get_subscription(subscription_id: str) -> dict:
    """Fetch a single plan by id.

    Raises:
        HTTPException 404: If the plan does not exist.
    """
    db = SubscriptionsManager()
    try:
        result = db.get_subscription(subscription_id)
        if result is None:
            raise HTTPException(status_code=404, detail="Subscription not found")
        return result
    finally:
        db.close()


@subscription_router.put("/{subscription_id}")
async def update_subscription(subscription_id: str, upd: SubscriptionUpdate) -> dict:
    """Update a plan (payment method, status, or plan_type — which re-derives price).

    Raises:
        HTTPException 404: If the plan does not exist.
    """
    db = SubscriptionsManager()
    try:
        if not db.update_subscription(subscription_id, upd):
            raise HTTPException(status_code=404, detail="Subscription not found")
        return {"ok": True}
    finally:
        db.close()


@subscription_router.delete("/{subscription_id}", status_code=204)
async def delete_subscription(subscription_id: str) -> None:
    """Cancel a plan and detach all of its members."""
    db = SubscriptionsManager()
    try:
        db.delete_subscription(subscription_id)
    finally:
        db.close()


# ── Members ────────────────────────────────────────────────────────────────────

@subscription_router.get("/{subscription_id}/members")
async def get_members(subscription_id: str) -> list[dict]:
    """List every user enrolled in the plan (host included)."""
    db = SubscriptionsManager()
    try:
        return db.get_members(subscription_id)
    finally:
        db.close()


@subscription_router.delete("/{subscription_id}/members/{user_id}", status_code=204)
async def remove_member(subscription_id: str, user_id: str) -> None:
    """Remove a member from a group plan (host removes, or member leaves).

    Raises:
        HTTPException 400: If the plan is missing or the target is the host.
    """
    db = SubscriptionsManager()
    try:
        result = db.remove_member(subscription_id, user_id)
        if result and "error" in result:
            raise HTTPException(status_code=400, detail=result["error"])
    finally:
        db.close()


# ── Group join requests ────────────────────────────────────────────────────────

@subscription_router.post("/{subscription_id}/requests", status_code=201)
async def create_request(subscription_id: str, from_user_id: str) -> dict:
    """Request to join a host's group plan.

    Args:
        subscription_id: The group plan to join.
        from_user_id: UUID of the requesting user (query parameter).

    Raises:
        HTTPException 400: If the plan is missing, not a group, full, or the
            user is already the host/a member.
    """
    db = SubscriptionsManager()
    try:
        result = db.create_request(subscription_id, from_user_id)
        if result and "error" in result:
            raise HTTPException(status_code=400, detail=result["error"])
        return {"ok": True}
    finally:
        db.close()


@subscription_router.get("/{subscription_id}/requests")
async def get_requests(subscription_id: str) -> list[dict]:
    """List pending join requests for a plan (for the host to review)."""
    db = SubscriptionsManager()
    try:
        return db.get_requests(subscription_id)
    finally:
        db.close()


@subscription_router.post("/{subscription_id}/requests/{from_user_id}/accept")
async def accept_request(subscription_id: str, from_user_id: str) -> dict:
    """Host accepts a pending request, enrolling the user in the plan.

    Raises:
        HTTPException 400: If the plan is missing, no such request exists, or
            the plan is full.
    """
    db = SubscriptionsManager()
    try:
        result = db.accept_request(subscription_id, from_user_id)
        if result and "error" in result:
            raise HTTPException(status_code=400, detail=result["error"])
        return {"ok": True}
    finally:
        db.close()


@subscription_router.delete("/{subscription_id}/requests/{from_user_id}", status_code=204)
async def decline_request(subscription_id: str, from_user_id: str) -> None:
    """Decline (host) or cancel (requester) a pending join request."""
    db = SubscriptionsManager()
    try:
        db.delete_request(subscription_id, from_user_id)
    finally:
        db.close()
