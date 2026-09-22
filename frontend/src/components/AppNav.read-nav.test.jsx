// Regression tests for task 20260922-reader-nav-download-page's change to
// AppNav.jsx's hamburger Drawer "Read" menu item (design-notes.md §5):
// previously this item unconditionally navigated to `/reader` with no
// device or shell branching at all, even though AppNav is shared by
// Account/AdminDetectionDetail/AdminDetections (pages with no "Open app"
// shortcut of their own) — a leaking-nav occurrence in the ordinary web
// frontend. Inside the desktop Tauri shell, `/reader` stays: that's
// legitimate in-app navigation within the native app the visitor already
// has, explicitly protected by the spec's out-of-bounds section.
//
// Separate file from AppNav.desktop-scope.test.jsx/AppNav.test.jsx (this
// repo's convention of task-scoped test files, per those files' own
// comments), and mocks useTheme for the same pre-existing jsdom/localStorage
// reason AppNav.desktop-scope.test.jsx documents.
//
// Run with: cd frontend && npm test -- --run src/components/AppNav.read-nav.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';
import AppNav from './AppNav.jsx';

vi.mock('../hooks/useTheme.js', () => ({
  useTheme: () => ({ isDark: true, toggleTheme: vi.fn() }),
}));

const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));

function LocationMarker() {
  const location = useLocation();
  return <div data-testid="current-path">{location.pathname}</div>;
}

// AppNav navigates imperatively via useNavigate() rather than rendering a
// <Link> for the hamburger menu items, so a real <Routes> table (matching
// App.jsx's own /reader and /download routes) is needed to observe where a
// click actually lands, not just an href attribute.
function renderAppNavWithRoutes(initialPath, { desktop = false, user = null } = {}) {
  if (desktop) window.__TAURI_INTERNALS__ = {};
  else delete window.__TAURI_INTERNALS__;
  mockUseAuth.mockReturnValue({ user });
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <AppNav />
      <LocationMarker />
      <Routes>
        <Route path="/reader" element={null} />
        <Route path="/download" element={null} />
        <Route path="/account" element={null} />
      </Routes>
    </MemoryRouter>
  );
}

function openDrawerAndClickRead() {
  fireEvent.click(document.querySelector('.hamburger-btn'));
  fireEvent.click(screen.getByText('Read'));
}

afterEach(() => {
  cleanup();
  delete window.__TAURI_INTERNALS__;
});

describe('AppNav — hamburger "Read" item routing (task 20260922-reader-nav-download-page)', () => {
  test('web, signed out: clicking Read navigates to /download, not /reader', () => {
    renderAppNavWithRoutes('/account', { desktop: false, user: null });
    openDrawerAndClickRead();

    expect(screen.getByTestId('current-path').textContent).toBe('/download');
  });

  test('web, signed in: clicking Read still navigates to /download — not gambling on /reader for an authenticated web visitor', () => {
    renderAppNavWithRoutes('/account', {
      desktop: false,
      user: { user_id: 'u1', username: 'jaceysimpson' },
    });
    openDrawerAndClickRead();

    expect(screen.getByTestId('current-path').textContent).toBe('/download');
  });

  test('desktop shell: clicking Read still navigates to /reader — legitimate in-app nav, unaffected by this task', () => {
    renderAppNavWithRoutes('/account', { desktop: true, user: null });
    openDrawerAndClickRead();

    expect(screen.getByTestId('current-path').textContent).toBe('/reader');
  });
});
