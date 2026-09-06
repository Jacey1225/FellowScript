// Regression tests for task 20260906-desktop-scope-lockdown (testing gate,
// step 4): the primary in-SPA enforcement layer. Mirrors App.jsx's actual
// route table (rather than a toy set of routes) so this exercises the real
// acceptance criterion -- "from the desktop app, no UI path leads anywhere
// other than reader, account, and the auth-flow surface" -- for every route
// the live app actually defines, not a hand-picked subset.
//
// Run with: cd frontend && npm test -- --run src/components/DesktopRouteGuard.test.jsx
import React from 'react';
import { describe, test, expect, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import DesktopRouteGuard from './DesktopRouteGuard.jsx';
import { DESKTOP_ALLOWED_ROUTES, DESKTOP_FALLBACK_ROUTE } from '../lib/desktopScope.js';

// Mirrors every path App.jsx registers (Home, Reader, Account, the 4
// auth-flow routes, Privacy, Terms, and the two hidden admin routes), each
// rendering a testid'd marker rather than the real page component, so these
// tests assert on routing/redirect behavior only.
const ALL_APP_ROUTES = [
  '/',
  '/reader',
  '/account',
  '/signin',
  '/forgot-password',
  '/reset-password',
  '/verify-2fa',
  '/privacy',
  '/terms',
  '/admin',
  '/admin/detections/123',
];

function Marker({ path }) {
  return <div data-testid={`page:${path}`} />;
}

function renderAppRoutesAt(initialPath) {
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <DesktopRouteGuard>
        <Routes>
          {ALL_APP_ROUTES.map((path) => (
            <Route key={path} path={path} element={<Marker path={path} />} />
          ))}
        </Routes>
      </DesktopRouteGuard>
    </MemoryRouter>
  );
}

afterEach(() => {
  cleanup();
  delete window.__TAURI_INTERNALS__;
});

describe('DesktopRouteGuard — desktop mode (window.__TAURI_INTERNALS__ present)', () => {
  test('every disallowed route redirects to the fallback instead of ever mounting its own page', () => {
    window.__TAURI_INTERNALS__ = {};
    for (const path of ALL_APP_ROUTES.filter((p) => !DESKTOP_ALLOWED_ROUTES.includes(p))) {
      const { unmount } = renderAppRoutesAt(path);
      expect(
        screen.queryByTestId(`page:${path}`),
        `expected ${path} to never mount its own page in desktop mode`
      ).toBeNull();
      expect(screen.getByTestId(`page:${DESKTOP_FALLBACK_ROUTE}`)).toBeTruthy();
      unmount();
    }
  });

  test('every allowed route (reader, account, and the 4 auth-flow routes) mounts normally, not redirected', () => {
    window.__TAURI_INTERNALS__ = {};
    for (const path of DESKTOP_ALLOWED_ROUTES) {
      const { unmount } = renderAppRoutesAt(path);
      expect(screen.getByTestId(`page:${path}`), `expected ${path} to mount normally`).toBeTruthy();
      unmount();
    }
  });
});

describe('DesktopRouteGuard — ordinary web frontend (no Tauri global)', () => {
  test('is a complete no-op: every one of the app\'s routes mounts its own page, none redirected', () => {
    for (const path of ALL_APP_ROUTES) {
      const { unmount } = renderAppRoutesAt(path);
      expect(screen.getByTestId(`page:${path}`), `expected ${path} to render unaffected on web`).toBeTruthy();
      unmount();
    }
  });
});
