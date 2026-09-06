// Minimal test for task 20260906-account-back-navigation's page-level back
// control on Account.jsx (Lightweight spec, frontend-gate-only -- no
// testing gate in this workflow, so this test is written by the frontend
// gate itself rather than a separate testing agent).
//
// AppNav/AppBloom/SubscriptionCard/DonationButton are stubbed exactly as in
// Account.agent-confirm.test.jsx (see that file's header comment for why).
//
// Run with: cd frontend && npm test -- --run src/pages/Account.back-navigation.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import Account from './Account.jsx';

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

function renderAccount({ initialEntries, initialIndex }) {
  mockUseAuth.mockReturnValue({ user: USER, signOut: vi.fn(), updateUser: vi.fn() });
  return render(
    <MemoryRouter initialEntries={initialEntries} initialIndex={initialIndex}>
      <Routes>
        <Route path="/prior-page" element={<div data-testid="prior-page" />} />
        <Route path="/reader" element={<div data-testid="reader-page" />} />
        <Route path="/account" element={<Account />} />
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  global.fetch = makeFetchMock();
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  // Reset any window.history.state a test set, so it can't leak into the next one.
  window.history.replaceState(null, '');
});

describe('Account — page-level back control', () => {
  test('renders a clearly visible, clickable Back control (not reliant on the browser gesture alone)', async () => {
    renderAccount({ initialEntries: ['/account'], initialIndex: 0 });
    const backBtn = await screen.findByRole('button', { name: 'Back' });
    expect(backBtn).toBeTruthy();
  });

  test('falls back to /reader when there is no prior in-app page (e.g. a fresh window load)', async () => {
    // jsdom's real window.history has no idx state here -- mirrors /account
    // being the first route this window ever loaded (fresh desktop window,
    // direct link, bookmark).
    window.history.replaceState(null, '');
    renderAccount({ initialEntries: ['/account'], initialIndex: 0 });

    const backBtn = await screen.findByRole('button', { name: 'Back' });
    fireEvent.click(backBtn);

    expect(await screen.findByTestId('reader-page')).toBeTruthy();
  });

  test('returns to the actual prior in-app page rather than the fallback when one exists', async () => {
    // Simulates react-router's own history.state.idx (see handleBack's
    // comment in Account.jsx) recording a page pushed before /account.
    window.history.replaceState({ idx: 1 }, '');
    renderAccount({ initialEntries: ['/prior-page', '/account'], initialIndex: 1 });

    const backBtn = await screen.findByRole('button', { name: 'Back' });
    fireEvent.click(backBtn);

    expect(await screen.findByTestId('prior-page')).toBeTruthy();
    expect(screen.queryByTestId('reader-page')).toBeNull();
  });
});
