// Task 20261001-admin-account-redesign (testing gate): the two new thin admin
// pages. AdminTrends wraps the unchanged AdminActivityMonitoring; AdminAccountActions
// wraps the unchanged AdminMembershipGrant, so its authz behavior (401 -> /signin,
// 403 -> /, POST to the same server-enforced endpoint) must be unchanged.
//
// Run with: cd frontend && npm test -- --run src/pages/AdminTrends.accounts.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';
import AdminTrends from './AdminTrends.jsx';
import AdminAccountActions from './AdminAccountActions.jsx';
import { API } from '../config.js';

vi.mock('../hooks/useIsDesktopViewport.js', () => ({ useIsDesktopViewport: () => true }));

function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}</div>; }
function renderAt(path, el) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path={path} element={el} />
        <Route path="*" element={<Where />} />
      </Routes>
    </MemoryRouter>,
  );
}
const res = (status, body = {}) => ({ ok: status >= 200 && status < 300, status, json: async () => body });

beforeEach(() => { global.fetch = vi.fn(); });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('AdminTrends', () => {
  test('renders the Trends page header and the activity-monitoring section, requesting all five series', async () => {
    global.fetch.mockResolvedValue(res(200, { points: [], series: [], title: 't' }));
    renderAt('/admin/trends', <AdminTrends />);
    expect(screen.getByRole('heading', { level: 1, name: 'Trends' })).toBeInTheDocument();
    expect(screen.getByText('Activity Monitoring')).toBeInTheDocument();
    await waitFor(() => {
      const urls = global.fetch.mock.calls.map((c) => String(c[0]));
      for (const k of ['notes', 'highlights', 'logins', 'messages', 'visits']) {
        expect(urls).toContain(`${API}/activity-monitoring/data/${k}`);
      }
    });
  });

  test('page h1 is programmatically focusable for the shell focus-move', () => {
    global.fetch.mockResolvedValue(res(200, {}));
    renderAt('/admin/trends', <AdminTrends />);
    const h = screen.getByRole('heading', { level: 1, name: 'Trends' });
    expect(h).toHaveAttribute('data-admin-heading');
    expect(h.tabIndex).toBe(-1);
  });
});

describe('AdminAccountActions (authz unchanged)', () => {
  const open = () => renderAt('/admin/accounts', <AdminAccountActions />);
  const grantBtn = () => screen.getByRole('button', { name: /Grant free individual membership/ });

  test('renders header and grant control', () => {
    open();
    expect(screen.getByRole('heading', { level: 1, name: 'Account actions' })).toBeInTheDocument();
    expect(grantBtn()).toBeInTheDocument();
  });

  test('click POSTs to the same admin grant endpoint and shows the active state', async () => {
    global.fetch.mockResolvedValueOnce(res(200, { status: 'active' }));
    open();
    fireEvent.click(grantBtn());
    expect(await screen.findByText('Individual membership active')).toBeInTheDocument();
    expect(global.fetch).toHaveBeenCalledWith(`${API}/subscriptions/admin/grant-individual`, { method: 'POST' });
  });

  test('401 redirects to /signin', async () => {
    global.fetch.mockResolvedValueOnce(res(401));
    open();
    fireEvent.click(grantBtn());
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/signin'));
  });

  test('403 (non-admin) redirects home', async () => {
    global.fetch.mockResolvedValueOnce(res(403));
    open();
    fireEvent.click(grantBtn());
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/'));
  });

  test('server error detail is surfaced', async () => {
    global.fetch.mockResolvedValueOnce(res(500, { detail: 'nope' }));
    open();
    fireEvent.click(grantBtn());
    expect(await screen.findByText('nope')).toBeInTheDocument();
  });
});
