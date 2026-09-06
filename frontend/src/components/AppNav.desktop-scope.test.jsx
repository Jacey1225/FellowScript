// Regression tests for task 20260906-desktop-scope-lockdown's nav-UI changes
// to AppNav.jsx (testing gate, step 4): Home is dropped from the hamburger
// Drawer's menu, the Drawer's Privacy/Terms footer links are hidden, and
// both logo marks point at the desktop fallback route instead of "/" --
// all only when running inside the desktop shell, and a no-op otherwise.
//
// Separate file from the existing AppNav.test.jsx (which predates this task
// and already covers unrelated header behavior) rather than editing it, per
// this repo's convention of task-scoped test files (see
// Account.back-navigation.test.jsx for the same pattern on Account.jsx).
//
// Mocks useTheme rather than rendering the real hook: this repo's current
// jsdom/vitest environment has a pre-existing, unrelated bug where the bare
// `localStorage` global is undefined (see js/notes.delete-refresh.test.js's
// header comment), which useTheme reads directly and which otherwise crashes
// every AppNav render, including the existing AppNav.test.jsx suite,
// independent of anything in this task's diff. Isolating that one hook here
// is the same convention Account.agent-confirm.test.jsx uses (there, by
// mocking AppNav out entirely).
//
// Run with: cd frontend && npm test -- --run src/components/AppNav.desktop-scope.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import AppNav from './AppNav.jsx';

vi.mock('../hooks/useTheme.js', () => ({
  useTheme: () => ({ isDark: true, toggleTheme: vi.fn() }),
}));

const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));

function renderAppNavAt(path, { desktop = false, user = null } = {}) {
  if (desktop) window.__TAURI_INTERNALS__ = {};
  else delete window.__TAURI_INTERNALS__;
  mockUseAuth.mockReturnValue({ user });
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppNav />
    </MemoryRouter>
  );
}

function openDrawer() {
  fireEvent.click(document.querySelector('.hamburger-btn'));
}

afterEach(() => {
  cleanup();
  delete window.__TAURI_INTERNALS__;
});

describe('AppNav — desktop mode nav restriction (task 20260906-desktop-scope-lockdown)', () => {
  test('desktop: Drawer menu omits the Home entry entirely', () => {
    renderAppNavAt('/reader', { desktop: true });
    openDrawer();

    expect(screen.queryByText('Home')).toBeNull();
    expect(screen.getByText('Read')).toBeTruthy();
  });

  test('web: Drawer menu still includes Home', () => {
    renderAppNavAt('/reader', { desktop: false });
    openDrawer();

    expect(screen.getByText('Home')).toBeTruthy();
  });

  test('desktop: Drawer\'s Privacy/Terms footer links are hidden entirely', () => {
    renderAppNavAt('/reader', { desktop: true });
    openDrawer();

    expect(screen.queryByText('Privacy')).toBeNull();
    expect(screen.queryByText('Terms')).toBeNull();
  });

  test('web: Drawer\'s Privacy/Terms footer links still render', () => {
    renderAppNavAt('/reader', { desktop: false });
    openDrawer();

    expect(screen.getByText('Privacy')).toBeTruthy();
    expect(screen.getByText('Terms')).toBeTruthy();
  });

  test('desktop: both the header logo and the Drawer title logo point at the fallback route, not "/"', () => {
    renderAppNavAt('/reader', { desktop: true });
    openDrawer();

    const logoLinks = document.querySelectorAll('a.nav-logo');
    expect(logoLinks.length).toBeGreaterThan(0);
    for (const link of logoLinks) {
      expect(link.getAttribute('href')).toBe('/reader');
    }
  });

  test('web: the logo still points at "/"', () => {
    renderAppNavAt('/reader', { desktop: false });
    openDrawer();

    const logoLinks = document.querySelectorAll('a.nav-logo');
    expect(logoLinks.length).toBeGreaterThan(0);
    for (const link of logoLinks) {
      expect(link.getAttribute('href')).toBe('/');
    }
  });
});
