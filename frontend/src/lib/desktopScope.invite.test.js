// Task 20260929-group-invite-links testing: desktop allowlist gains only the
// exact /join/<43-char token> shape; the base list stays closed.
import { describe, test, expect } from 'vitest';
import { isAllowedDesktopRoute, DESKTOP_ALLOWED_ROUTES } from './desktopScope.js';

const T = 'A'.repeat(43);
describe('desktop allowlist for invite links', () => {
  test('allows /join/<valid token>', () => { expect(isAllowedDesktopRoute(`/join/${T}`)).toBe(true); });
  test.each([
    ['/join'], ['/join/'], ['/join/short'], [`/join/${T}/x`], [`/join/${T}x`],
    [`/join/${'A'.repeat(42)}.`], [`//join/${T}`], [`/x/join/${T}`], ['/admin'], ['/'],
  ])('denies %s', (p) => { expect(isAllowedDesktopRoute(p)).toBe(false); });
  test('exact-route list is unchanged (no /join entry)', () => {
    expect(DESKTOP_ALLOWED_ROUTES).not.toContain('/join');
    expect(DESKTOP_ALLOWED_ROUTES).toHaveLength(6);
  });
});
