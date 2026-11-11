// Task 20261030-profile-everywhere (step 14): the Account "Friend Requests" row
// gets a Decline button beside Accept. Heavy chrome is stubbed as in
// Account.back-navigation.test.jsx.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import Account from './Account.jsx';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div data-testid="app-nav" /> }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../components/SubscriptionCard.jsx', () => ({ default: () => <div data-testid="subscription-card" /> }));
vi.mock('../components/DonationButton.jsx', () => ({ default: () => null }));
const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockUseAuth() }));

vi.setConfig({ testTimeout: 20000 });

const ME = '99999999-9999-4999-8999-999999999999';
const ANN = '11111111-1111-4111-8111-111111111111';
const BOB = '22222222-2222-4222-8222-222222222222';
const USER = { user_id: ME, username: 'tester', email: 't@example.com' };
const jsonRes = (body, ok = true, status = ok ? 200 : 500) => ({ ok, status, json: async () => body });

let declineStatus;
function makeFetch() {
  return vi.fn(async (url, opts) => {
    const u = String(url);
    if (/\/decline$/.test(u)) return declineStatus === 204 ? jsonRes({}, true, 204) : jsonRes({ detail: 'internal sql boom' }, false, declineStatus);
    if (u.endsWith(`/user/${ME}`)) return jsonRes({ ...USER, groups: [], friend_requests: [ANN, BOB] });
    if (u.endsWith(`/user/${ANN}`)) return jsonRes({ username: 'ann' });
    if (u.endsWith(`/user/${BOB}`)) return jsonRes({ username: 'bob' });
    if (/\/subscriptions\/user\/.*\/usage$/.test(u)) return jsonRes({ subscribed: false, window_days: 7, resources: {} });
    if (/\/blocks\//.test(u)) return jsonRes([]);
    if (/\/(notes|agent)\//.test(u)) return jsonRes({});
    return jsonRes({}, false, 404);
  });
}

function renderAccount() {
  mockUseAuth.mockReturnValue({ user: USER, signOut: vi.fn(), updateUser: vi.fn() });
  return render(
    <MemoryRouter initialEntries={['/account']}>
      <Routes>
        <Route path="/account" element={<Account />} />
        <Route path="/profile/:userId" element={<div data-testid="profile-page" />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => { declineStatus = 204; global.fetch = makeFetch(); });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('Account friend-request Decline', () => {
  test('each request shows Accept and Decline', async () => {
    renderAccount();
    expect(await screen.findByRole('button', { name: /decline friend request from ann/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /decline friend request from bob/i })).toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: /^accept$/i }).length).toBeGreaterThanOrEqual(2);
  });

  test('Decline POSTs the recipient-only route and removes only that row after 204', async () => {
    renderAccount();
    fireEvent.click(await screen.findByRole('button', { name: /decline friend request from ann/i }));
    await waitFor(() => expect(screen.queryByRole('button', { name: /decline friend request from ann/i })).toBeNull());
    const hit = global.fetch.mock.calls.filter(([u]) => /\/decline$/.test(u));
    expect(hit).toHaveLength(1);
    expect(hit[0][0]).toMatch(new RegExp(`/friends/${ME}/requests/${ANN}/decline$`));
    expect(hit[0][1].method).toBe('POST');
    expect(screen.getByRole('button', { name: /decline friend request from bob/i })).toBeInTheDocument();
  });

  test('a failed Decline keeps the row and shows no server error text', async () => {
    declineStatus = 500;
    renderAccount();
    fireEvent.click(await screen.findByRole('button', { name: /decline friend request from ann/i }));
    await waitFor(() => expect(global.fetch.mock.calls.some(([u]) => /\/decline$/.test(u))).toBe(true));
    await waitFor(() => expect(screen.getByRole('button', { name: /decline friend request from ann/i })).not.toBeDisabled());
    expect(screen.getByRole('button', { name: /decline friend request from ann/i })).toBeInTheDocument();
    expect(document.body.textContent).not.toContain('internal sql boom');
  });
});
