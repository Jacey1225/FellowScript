// Regression tests for task 20260906-desktop-scope-lockdown's SignIn.jsx
// change (testing gate, step 4): unlike AppNav/Account.jsx's purely
// navigational Privacy/Terms links (hidden outright in desktop mode), the
// ones woven into SignIn's required consent-disclosure text must stay
// visible -- so they're forced target="_blank"/rel="noopener noreferrer"
// instead, routing through the existing hardened on_new_window ->
// system-browser handoff rather than an in-app SPA navigation. Confirms
// that behavior is scoped to desktop mode only and doesn't touch the two
// other /terms links already elsewhere in this file (the signup-tab
// checkbox and the terms-reaccept modal), which stay plain target="_blank"
// unconditionally regardless of platform.
//
// Run with: cd frontend && npm test -- --run src/pages/SignIn.desktop-scope.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import SignIn from './SignIn.jsx';

vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => ({ signIn: vi.fn() }),
}));

function renderSignIn({ desktop = false } = {}) {
  if (desktop) window.__TAURI_INTERNALS__ = {};
  else delete window.__TAURI_INTERNALS__;
  return render(
    <MemoryRouter initialEntries={['/signin']}>
      <SignIn />
    </MemoryRouter>
  );
}

afterEach(() => {
  cleanup();
  delete window.__TAURI_INTERNALS__;
  vi.restoreAllMocks();
});

describe('SignIn — desktop-mode Terms/Privacy consent links (task 20260906-desktop-scope-lockdown)', () => {
  test('desktop: the footer consent disclosure\'s Terms/Privacy links are forced external (target="_blank", rel="noopener noreferrer")', () => {
    renderSignIn({ desktop: true });

    const terms = screen.getByText('Terms of Service');
    const privacy = screen.getByText('Privacy Policy');
    expect(terms.getAttribute('target')).toBe('_blank');
    expect(terms.getAttribute('rel')).toBe('noopener noreferrer');
    expect(privacy.getAttribute('target')).toBe('_blank');
    expect(privacy.getAttribute('rel')).toBe('noopener noreferrer');
    // Still real in-app hrefs (so the on_new_window handoff has a same-origin
    // https URL to hand to the system browser) -- not stripped/emptied.
    expect(terms.getAttribute('href')).toBe('/terms');
    expect(privacy.getAttribute('href')).toBe('/privacy');
  });

  test('web: the same links stay plain in-app SPA links (no target/rel)', () => {
    renderSignIn({ desktop: false });

    const terms = screen.getByText('Terms of Service');
    const privacy = screen.getByText('Privacy Policy');
    expect(terms.getAttribute('target')).toBeNull();
    expect(terms.getAttribute('rel')).toBeNull();
    expect(privacy.getAttribute('target')).toBeNull();
    expect(privacy.getAttribute('rel')).toBeNull();
  });
});
