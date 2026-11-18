// Seat price mirror: exact numbers, and drift check against api/config/seat_pricing.json.
// Run: cd frontend && npm test -- --run src/lib/seatPricing.test.js
import { describe, test, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { SEAT_PRICING, seatPriceCents, seatsFromHash } from './seatPricing.js';

describe('seatPriceCents', () => {
  test.each([[1, 500], [2, 900], [9, 4050], [10, 4500], [20, 9000], [100, 45000]])('%i seats = %i cents', (n, c) => {
    expect(seatPriceCents(n)).toBe(c);
  });
  test('out of range or non-integer is null', () => {
    for (const n of [0, 101, 1.5, -1, null, undefined, NaN]) expect(seatPriceCents(n)).toBeNull();
  });
  test('matches api/config/seat_pricing.json', () => {
    const cfg = JSON.parse(readFileSync(resolve(process.cwd(), '../api/config/seat_pricing.json'), 'utf8')).seat_pricing;
    expect(SEAT_PRICING).toEqual({
      minMembers: cfg.min_members, maxMembers: cfg.max_members, basePerSeatCents: cfg.base_per_seat_cents,
      groupDiscountPercent: cfg.group_discount_percent, discountStartSeats: cfg.discount_start_seats,
    });
  });
});

describe('seatsFromHash', () => {
  test.each([
    ['#/account?subscribe=1&seats=20', 20],
    ['#/account?seats=1', 1],
    ['#/account?seats=100', 100],
  ])('%s -> %s', (h, n) => { expect(seatsFromHash(h)).toBe(n); });
  test.each(['', '#/account', '#/account?seats=0', '#/account?seats=101', '#/account?seats=abc', '#/account?seats=2.5', '#/account?seats=-3', null, undefined])(
    'invalid %s -> null', (h) => { expect(seatsFromHash(h)).toBeNull(); });
});
