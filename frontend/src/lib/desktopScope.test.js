// Regression tests for task 20260906-desktop-scope-lockdown (testing gate,
// step 4): the single-source-of-truth allowlist and desktop-detection
// helper every enforcement layer (DesktopRouteGuard, AppNav, Account,
// SignIn, and the Rust-side on_navigation mirror) is built on.
//
// Run with: cd frontend && npm test -- --run src/lib/desktopScope.test.js
import { describe, test, expect, afterEach } from 'vitest';
import {
  DESKTOP_ALLOWED_ROUTES,
  DESKTOP_FALLBACK_ROUTE,
  isDesktopApp,
  isAllowedDesktopRoute,
} from './desktopScope.js';

afterEach(() => {
  delete window.__TAURI_INTERNALS__;
});

describe('isDesktopApp', () => {
  test('reports false in the ordinary web frontend (no Tauri global present)', () => {
    expect(isDesktopApp()).toBe(false);
  });

  test('reports true once Tauri v2 injects its IPC bridge global', () => {
    window.__TAURI_INTERNALS__ = {};
    expect(isDesktopApp()).toBe(true);
  });
});

describe('DESKTOP_ALLOWED_ROUTES — the closed, deny-by-default allowlist', () => {
  test('contains exactly reader, account, and the four auth-flow routes finalized by the security gate', () => {
    expect([...DESKTOP_ALLOWED_ROUTES].sort()).toEqual(
      [
        '/reader',
        '/account',
        '/signin',
        '/forgot-password',
        '/reset-password',
        '/verify-2fa',
      ].sort()
    );
  });

  test('excludes Home, Privacy, Terms, and the hidden admin surface by name', () => {
    for (const disallowed of ['/', '/privacy', '/terms', '/admin', '/admin/detections/:id']) {
      expect(DESKTOP_ALLOWED_ROUTES).not.toContain(disallowed);
    }
  });

  test('the fallback route is itself always on the allowlist (no redirect-to-a-dead-end loop)', () => {
    expect(DESKTOP_ALLOWED_ROUTES).toContain(DESKTOP_FALLBACK_ROUTE);
  });
});

describe('isAllowedDesktopRoute', () => {
  test('allows every route on the allowlist', () => {
    for (const route of DESKTOP_ALLOWED_ROUTES) {
      expect(isAllowedDesktopRoute(route)).toBe(true);
    }
  });

  test('denies Home, Privacy, Terms, and admin', () => {
    for (const route of ['/', '/privacy', '/terms', '/admin', '/admin/detections/123']) {
      expect(isAllowedDesktopRoute(route)).toBe(false);
    }
  });

  test('denies an unknown/typo\'d path rather than failing open', () => {
    expect(isAllowedDesktopRoute('/reade')).toBe(false);
    expect(isAllowedDesktopRoute('')).toBe(false);
  });
});
