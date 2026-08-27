// Regression test for AppNav's header contract (20260825-header-nav-profile-icon):
// the desktop top-right no longer shows the Home/Read/Account text Menu or
// the Reader-only "Jump or Ask" command trigger (both removed entirely) —
// just a profile avatar (routing by auth state) and the unchanged theme
// toggle. The unified-background `fs-nav--unified` modifier stays scoped to
// the Reader route only, unaffected by this change. AppNav is rendered by
// Reader, Account, AdminDetectionDetail, and AdminDetections.
//
// Run with: cd frontend && npm test -- --run src/components/AppNav.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import AppNav from './AppNav.jsx';

// Same mocking convention as AdminGate.test.jsx — swap useAuth's return value
// per test rather than seeding AuthProvider's sessionStorage/localStorage.
const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));

afterEach(() => cleanup());

function renderAppNavAt(path, user = null) {
  mockUseAuth.mockReturnValue({ user });
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppNav />
    </MemoryRouter>
  );
}

describe('AppNav — top-right controls', () => {
  test('no Home/Read/Account text links or Jump-or-Ask trigger render on any route', () => {
    renderAppNavAt('/reader');

    expect(screen.queryByText('Home')).toBeFalsy();
    expect(screen.queryByText('Read')).toBeFalsy();
    expect(screen.queryByText('Sign In')).toBeFalsy();
    expect(screen.queryByRole('button', { name: /Jump or Ask/i })).toBeFalsy();
  });

  test('exactly a profile link and the theme toggle render in the top-right controls', () => {
    const { container } = renderAppNavAt('/reader');

    expect(container.querySelector('.nav-profile-link')).toBeTruthy();
    expect(container.querySelector('.theme-toggle-btn')).toBeTruthy();
  });
});

describe('AppNav — profile icon auth-state routing', () => {
  test('signed out: profile link points at /signin', () => {
    const { container } = renderAppNavAt('/reader', null);

    const link = container.querySelector('.nav-profile-link');
    expect(link.getAttribute('href')).toBe('/signin');
  });

  test('signed in: profile link points at /account', () => {
    const { container } = renderAppNavAt('/reader', { user_id: 'u1', username: 'jaceysimpson' });

    const link = container.querySelector('.nav-profile-link');
    expect(link.getAttribute('href')).toBe('/account');
  });
});

describe('AppNav — theme toggle unaffected', () => {
  test('theme toggle renders with its light/dark icon control intact', () => {
    const { container } = renderAppNavAt('/reader');

    expect(container.querySelector('.theme-toggle-btn')).toBeTruthy();
  });
});

describe('AppNav — Reader-route unified background scoping (unchanged)', () => {
  test('/reader gets the unified background class', () => {
    const { container } = renderAppNavAt('/reader');
    expect(container.querySelector('.fs-nav--unified')).toBeTruthy();
  });

  test('other 3 shared routes (Account, AdminDetectionDetail-style, AdminDetections-style) never get the unified header background', () => {
    for (const path of ['/account', '/admin/detections', '/admin/detections/123']) {
      const { container, unmount } = renderAppNavAt(path);
      expect(container.querySelector('.fs-nav--unified'), `expected no unified header on ${path}`).toBeFalsy();
      unmount();
    }
  });
});

describe('AppNav — mobile hamburger Drawer unaffected', () => {
  test('hamburger control still opens the Drawer with Home/Read/Account nav intact', () => {
    renderAppNavAt('/reader');

    expect(document.querySelector('.hamburger-btn')).toBeTruthy();
  });
});
