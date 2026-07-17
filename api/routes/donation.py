from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import logging
from backend.subscription import stripe_service

donation_router = APIRouter(prefix="/donate")
logger = logging.getLogger(__name__)

MIN_CENTS = 100          # $1
MAX_CENTS = 1_000_000    # $10,000


class DonationRequest(BaseModel):
    amount_cents: int
    email: str = ""


@donation_router.post("/checkout")
async def donate_checkout(req: DonationRequest) -> dict:
    """Create a one-time Stripe Checkout Session for a donation.

    Returns ``{"url": str}`` for the browser to redirect to. The amount is
    validated server-side so it can't be tampered outside a sane range.
    """
    if not stripe_service.is_configured():
        raise HTTPException(status_code=503, detail="Payments are not configured.")
    if req.amount_cents < MIN_CENTS or req.amount_cents > MAX_CENTS:
        raise HTTPException(status_code=400, detail="Donation must be between $1 and $10,000.")
    try:
        url = stripe_service.create_donation_session(req.amount_cents, req.email)
        return {"url": url}
    except Exception as e:
        logger.error("Donation checkout error: %s", e)
        raise HTTPException(status_code=502, detail="Could not start donation.")
