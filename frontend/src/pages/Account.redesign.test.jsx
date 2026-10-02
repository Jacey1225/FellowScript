// Task 20261001-admin-account-redesign (testing gate): Account page regression
// after the visual restyle. Uses the REAL SubscriptionCard (inside the
// .fs-sub-scope wrapper) so the restyle's wrapper can't silently break
// plan display or the cancel flow. SubscriptionCard's own tests are untouched.
// Note: the web SubscriptionCard has Cancel Plan only; there is no "restore"
// control on web (restore purchases is iOS/StoreKit).
//
// Run with: cd frontend && npm test -- --run src/pages/Account.redesign.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import Account from './Account.jsx';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div data-testid="app-nav" /> }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../components/DonationButton.jsx', () => ({ default: () => null }));

const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockUseAuth() }));

const USER = { user_id: 'user-1', username: 'tester', email: 't@example.com' };
const PLAN = {
  id: 'sub-1', user_id: 'user-1', plan_type: 'group', status: 'active', is_trial: false,
  price_cents: 1215, max_members: 3, next_billing_date: null, card_brand: null, card_last4: null,
};
const jr = (body, ok = true, status = ok ? 200 : 500) => ({ ok, status, json: async () => body });

function makeFetch({ plan = null, photo = null, usage, cancelStatus = 204 } = {}) {
  return vi.fn(async (url, opts = {}) => {
    const u = String(url);
    if (opts.method === 'DELETE' && /\/subscriptions\/sub-1$/.test(u)) return { ok: cancelStatus < 300, status: cancelStatus, json: async () => ({}) };
    if (/\/notes\/highlight\/user-1$/.test(u)) return jr({ 'Gen 1:1': {}, 'Gen 1:2': {}, 'Gen 1:3': {} });
    if (/\/notes\/user-1$/.test(u)) return jr({ n1: {}, n2: {} });
    if (/\/agent\/user-1$/.test(u)) return jr({});
    if (/\/subscriptions\/user\/user-1\/usage$/.test(u)) {
      return jr(usage || { subscribed: false, window_days: 7, resources: {
        notes: { used: 3, limit: 10 }, agent_events: { used: 1, limit: 5 }, agent_notifications: { used: 0, limit: 5 } } });
    }
    if (/\/subscriptions\/user\/user-1\/requests$/.test(u)) return jr([]);
    if (/\/subscriptions\/user\/user-1$/.test(u)) return plan ? jr(plan) : jr({}, false, 404);
    if (/\/subscriptions\/sub-1\/(members|requests)$/.test(u)) return jr([]);
    if (/\/friends\/user-1$/.test(u)) return jr([]);
    if (/\/user\/user-1$/.test(u)) return jr({ ...USER, profile_photo_url: photo, friends: ['a', 'b', 'c'], groups: [], friend_requests: [] });
    if (/\/blocks\/user-1$/.test(u)) return jr([]);
    return jr({}, false, 404);
  });
}

function renderAccount() {
  mockUseAuth.mockReturnValue({ user: USER, signOut: vi.fn(), updateUser: vi.fn() });
  return render(
    <MemoryRouter initialEntries={['/account']}>
      <Routes><Route path="/account" element={<Account />} /></Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => { global.fetch = makeFetch(); });
afterEach(() => { cleanup(); vi.restoreAllMocks(); window.history.replaceState(null, ''); });

describe('Account page after restyle', () => {
  test('header: initial avatar, username, email, add-photo camera badge', async () => {
    const { container } = renderAccount();
    expect(await screen.findByRole('heading', { name: 'tester' })).toBeInTheDocument();
    expect(screen.getByText('t@example.com')).toBeInTheDocument();
    expect(container.querySelector('.fs-account-head')).not.toBeNull();
    expect(container.querySelector('.ant-avatar')).toHaveTextContent('T');
    expect(screen.getByRole('button', { name: 'Add a profile photo' })).toBeInTheDocument();
  });

  test('with a photo: badge label changes and Remove photo is offered', async () => {
    global.fetch = makeFetch({ photo: 'https://img.test/p.png' });
    renderAccount();
    expect(await screen.findByRole('button', { name: 'Change profile photo' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Remove photo' })).toBeInTheDocument();
  });

  test('overview stats render in the fs-stats grid with correct values', async () => {
    const { container } = renderAccount();
    await waitFor(() => expect(container.querySelectorAll('.fs-stats .fs-stat').length).toBe(4));
    const stats = Object.fromEntries([...container.querySelectorAll('.fs-stat')].map((s) => [
      s.querySelector('.fs-stat__label').textContent, s.querySelector('.fs-stat__num').textContent]));
    expect(stats).toEqual({ Friends: '3', Groups: '0', Notes: '2', Verses: '3' });
  });

  test('subscription card renders inside the .fs-sub-scope wrapper with plan details', async () => {
    global.fetch = makeFetch({ plan: PLAN });
    const { container } = renderAccount();
    const scope = container.querySelector('.fs-sub-scope');
    expect(scope).not.toBeNull();
    expect(await within(scope).findByRole('button', { name: /Cancel Plan/ })).toBeInTheDocument();
    expect(scope.textContent).toMatch(/12\.15/);
  });

  test('plan usage meters for the free plan show used / limit and the upgrade notice', async () => {
    renderAccount();
    expect(await screen.findByText('Plan Usage')).toBeInTheDocument();
    expect(screen.getByText('3 / 10')).toBeInTheDocument();
    expect(screen.getByText('1 / 5')).toBeInTheDocument();
    expect(screen.getByText(/You're on the Free plan\. Subscribe for unlimited/)).toBeInTheDocument();
  });

  test('plan usage shows Unlimited when subscribed, without the upgrade notice', async () => {
    global.fetch = makeFetch({ usage: { subscribed: true, window_days: 7, resources: {
      notes: { unlimited: true }, agent_events: { unlimited: true }, agent_notifications: { unlimited: true } } } });
    renderAccount();
    expect((await screen.findAllByText('Unlimited')).length).toBe(3);
    expect(screen.queryByText(/You're on the Free plan/)).toBeNull();
  });

  test('cancel flow: confirm issues DELETE to the plan and reports success', async () => {
    global.fetch = makeFetch({ plan: PLAN });
    renderAccount();
    fireEvent.click(await screen.findByRole('button', { name: /Cancel Plan/ }));
    fireEvent.click(await screen.findByRole('button', { name: 'Cancel plan' }));
    await waitFor(() => expect(global.fetch.mock.calls.some(
      ([u, o]) => /\/subscriptions\/sub-1$/.test(String(u)) && o && o.method === 'DELETE')).toBe(true));
    expect(await screen.findByText('Plan canceled.')).toBeInTheDocument();
  });

  test('cancel flow: failed DELETE shows error, not success', async () => {
    global.fetch = makeFetch({ plan: PLAN, cancelStatus: 500 });
    renderAccount();
    fireEvent.click(await screen.findByRole('button', { name: /Cancel Plan/ }));
    fireEvent.click(await screen.findByRole('button', { name: 'Cancel plan' }));
    expect(await screen.findByText(/Could not cancel plan/)).toBeInTheDocument();
    expect(screen.queryByText('Plan canceled.')).toBeNull();
  });

  test('sign out control still present', async () => {
    renderAccount();
    expect(await screen.findByRole('button', { name: /Sign Out/ })).toBeInTheDocument();
  });
});
