// Task 20261030-user-profiles: /profile/<uuid> is the only profile shape the
// desktop shell may reach; base route list stays closed.
import { describe, test, expect } from 'vitest';
import { DESKTOP_ALLOWED_ROUTES, isAllowedDesktopRoute } from './desktopScope.js';

const ID = '123e4567-e89b-42d3-a456-426614174000';

describe('desktop scope: /profile/:userId', () => {
  test('allows /profile/<uuid>', () => { expect(isAllowedDesktopRoute(`/profile/${ID}`)).toBe(true); });
  test.each([
    ['/profile'], ['/profile/'], ['/profile/abc'], [`/profile/${ID}/x`], [`/profile/${ID}x`],
    [`//profile/${ID}`], [`/x/profile/${ID}`], [`/profile/${ID.slice(1)}`],
  ])('denies %s', (p) => { expect(isAllowedDesktopRoute(p)).toBe(false); });
  test('exact-route list is unchanged (no /profile entry)', () => {
    expect(DESKTOP_ALLOWED_ROUTES).not.toContain('/profile');
  });
});
