// Task 20261012-notification-settings: Account page has a Notifications entry
// that navigates to /account/notifications.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import Account from './Account.jsx';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div /> }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../components/SubscriptionCard.jsx', () => ({ default: () => <div /> }));
vi.mock('../components/DonationButton.jsx', () => ({ default: () => null }));
const USER = { user_id: 'user-1', username: 'tester', email: 't@example.com' };
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => ({ user: USER, signOut: vi.fn(), updateUser: vi.fn() }),
}));
const jr = (body, ok = true, status = ok ? 200 : 500) => ({ ok, status, json: async () => body });

beforeEach(() => {
  global.fetch = vi.fn(async (url) => {
    if (/\/user\/user-1$/.test(url)) return jr({ ...USER, groups: [], friend_requests: [] });
    if (/\/subscriptions\/user\/user-1\/usage$/.test(url)) return jr({ subscribed: false, window_days: 7, resources: {} });
    if (/\/blocks\/user-1$/.test(url)) return jr([]);
    return jr({}, false, 404);
  });
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('Account Notifications entry', () => {
  test('is a labelled link to /account/notifications and navigates there', async () => {
    render(
      <MemoryRouter initialEntries={['/account']}>
        <Routes>
          <Route path="/account" element={<Account />} />
          <Route path="/account/notifications" element={<div data-testid="notif-page" />} />
        </Routes>
      </MemoryRouter>
    );
    const link = await screen.findByRole('link', { name: 'Notifications settings' });
    expect(link.getAttribute('href')).toBe('/account/notifications');
    fireEvent.click(link);
    expect(await screen.findByTestId('notif-page')).toBeTruthy();
  });

  test('is hidden inside the desktop app shell', async () => {
    window.__TAURI_INTERNALS__ = {};
    try {
      render(
        <MemoryRouter initialEntries={['/account']}>
          <Routes><Route path="/account" element={<Account />} /></Routes>
        </MemoryRouter>
      );
      await screen.findByText('Blocked Users');
      expect(screen.queryByRole('link', { name: 'Notifications settings' })).toBeNull();
    } finally {
      delete window.__TAURI_INTERNALS__;
    }
  });
});
