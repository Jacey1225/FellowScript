// Display-only mirror of api/config/seat_pricing.json (server: price_for in
// api/schemas/subscription.py). The server stays the source of truth and
// re-prices every checkout; seatPricing.test.js fails if these drift.
export const SEAT_PRICING = {
  minMembers: 1,
  maxMembers: 100,
  basePerSeatCents: 500,
  groupDiscountPercent: 10,
  discountStartSeats: 2,
};

// Monthly price in cents for n seats, or null when n is not a whole number in range.
export function seatPriceCents(n) {
  const c = SEAT_PRICING;
  if (!Number.isInteger(n) || n < c.minMembers || n > c.maxMembers) return null;
  const pct = n >= c.discountStartSeats ? 100 - c.groupDiscountPercent : 100;
  return Math.round((n * c.basePerSeatCents * pct) / 100);
}

// Seat count carried by a checkout link such as "#/account?subscribe=1&seats=20"
// (the iOS app in the US storefront opens it). Whole numbers inside the allowed
// range only; anything else is null so the picker keeps its default.
export function seatsFromHash(hash) {
  const q = String(hash || '').split('?')[1];
  if (!q) return null;
  const raw = new URLSearchParams(q).get('seats');
  if (raw === null || !/^\d+$/.test(raw)) return null;
  const n = Number(raw);
  return seatPriceCents(n) === null ? null : n;
}
