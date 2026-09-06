// Regression tests for task 20260906-desktop-scope-lockdown's Account.jsx
// change (testing gate, step 4):
//
//  1. The purely-navigational "Legal links" footer (Privacy Policy / Terms
//     of Service) is hidden entirely in desktop mode, since neither route
//     is on the desktop allowlist and -- unlike SignIn.jsx's consent
//     disclosure -- there's no required legal copy tying it to the page.
//  2. The concurrent task 20260906-account-back-navigation's page-level
//     Back control (handleBack, `navigate(-1)`) can't be used to escape the
//     allowlist when combined with DesktopRouteGuard: since a disallowed
//     route can never be pushed onto in-app history in desktop mode in the
//     first place (DesktopRouteGuard redirects before it ever mounts),
//     Back can only ever land on an already-allowed prior entry. This is
//     the specific interaction the intake spec's Open Questions flagged for
//     the implementing/testing gates to double-check.
//
// AppNav/AppBloom/SubscriptionCard/DonationButton are stubbed exactly as in
// Account.agent-confirm.test.jsx and Account.back-navigation.test.jsx.
//
// Run with: cd frontend && npm test -- --run src/pages/Account.desktop-scope.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import Account from './Account.jsx';
import DesktopRouteGuard from '../components/DesktopRouteGuard.jsx';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div data-testid="app-nav" /> }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../components/SubscriptionCard.jsx', () => ({ default: () => <div data-testid="subscription-card" /> }));
vi.mock('../components/DonationButton.jsx', () => ({ default: () => null }));

const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));

const USER = { user_id: 'user-1', username: 'tester', email: 't@example.com' };

function jsonRes(body, ok = true, status = ok ? 200 : 500) {
  return { ok, status, json: async () => body };
}

function makeFetchMock() {
  return vi.fn(async (url) => {
    if (/\/user\/user-1$/.test(url)) return jsonRes({ ...USER, groups: [], friend_requests: [] });
    if (/\/notes\/highlight\/user-1$/.test(url)) return jsonRes({});
    if (/\/notes\/user-1$/.test(url)) return jsonRes({});
    if (/\/agent\/user-1$/.test(url)) return jsonRes({});
    if (/\/subscriptions\/user\/user-1\/usage$/.test(url)) {
      return jsonRes({ subscribed: false, window_days: 7, resources: {} });
    }
    if (/\/blocks\/user-1$/.test(url)) return jsonRes([]);
    return jsonRes({}, false, 404);
  });
}

function renderAccount({ desktop = false } = {}) {
  if (desktop) window.__TAURI_INTERNALS__ = {};
  else delete window.__TAURI_INTERNALS__;
  mockUseAuth.mockReturnValue({ user: USER, signOut: vi.fn(), updateUser: vi.fn() });
  return render(
    <MemoryRouter initialEntries={['/account']}>
      <Account />
    </MemoryRouter>
  );
}

beforeEach(() => {
  global.fetch = makeFetchMock();
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  delete window.__TAURI_INTERNALS__;
  window.history.replaceState(null, '');
});

describe('Account — desktop-mode Legal links footer (task 20260906-desktop-scope-lockdown)', () => {
  test('desktop: Privacy Policy / Terms of Service footer is hidden entirely (/privacy and /terms are not on the allowlist)', async () => {
    renderAccount({ desktop: true });
    await screen.findByText('tester');

    expect(screen.queryByText('Privacy Policy')).toBeNull();
    expect(screen.queryByText('Terms of Service')).toBeNull();
  });

  test('web: the same footer still renders both links', async () => {
    renderAccount({ desktop: false });
    await screen.findByText('tester');

    expect(screen.getByText('Privacy Policy')).toBeTruthy();
    expect(screen.getByText('Terms of Service')).toBeTruthy();
  });
});

describe('Account — Back control cannot escape the desktop allowlist when guarded (interaction with 20260906-account-back-navigation)', () => {
  test('desktop: navigating reader -> account then clicking Back lands back on reader, never off the allowlist', async () => {
    window.__TAURI_INTERNALS__ = {};
    mockUseAuth.mockReturnValue({ user: USER, signOut: vi.fn(), updateUser: vi.fn() });
    window.history.replaceState({ idx: 1 }, '');

    render(
      <MemoryRouter initialEntries={['/reader', '/account']} initialIndex={1}>
        <DesktopRouteGuard>
          <Routes>
            <Route path="/reader" element={<div data-testid="reader-page" />} />
            <Route path="/account" element={<Account />} />
          </Routes>
        </DesktopRouteGuard>
      </MemoryRouter>
    );

    const backBtn = await screen.findByRole('button', { name: 'Back' });
    fireEvent.click(backBtn);

    await waitFor(() => {
      expect(screen.getByTestId('reader-page')).toBeTruthy();
    });
  });
});
