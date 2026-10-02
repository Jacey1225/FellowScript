// Admin user-actions page: search, paginate, confirm-before grant/revoke, self row disabled.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent, within } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

const mockAuth = { user: { user_id: 'u-me' } };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));
vi.mock('../components/AppNav.jsx', () => ({ default: () => null }));
vi.mock('../lib/adminUsersApi.js', async () => {
  const actual = await vi.importActual('../lib/adminUsersApi.js');
  return { ...actual, fetchUsers: vi.fn(), grantAdmin: vi.fn(), revokeAdmin: vi.fn() };
});
import { fetchUsers, grantAdmin, revokeAdmin, AdminUsersApiError } from '../lib/adminUsersApi.js';
import AdminUserActions from './AdminUserActions.jsx';

function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}</div>; }
function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/admin/users']}>
      <Routes>
        <Route path="/admin/users" element={<AdminUserActions />} />
        <Route path="*" element={<Where />} />
      </Routes>
    </MemoryRouter>,
  );
}
const ME = { id: 'u-me', username: 'me', email: 'me@x.com', is_admin: true };
const BOB = { id: 'u-bob', username: 'bob', email: 'bob@x.com', is_admin: false };
const ANN = { id: 'u-ann', username: 'ann', email: 'ann@x.com', is_admin: true };
const page = (users, extra = {}) => ({ users, total: users.length, page: 1, page_size: 25, ...extra });

beforeEach(() => {
  [fetchUsers, grantAdmin, revokeAdmin].forEach((f) => f.mockReset());
  fetchUsers.mockResolvedValue(page([ME, BOB, ANN]));
});
afterEach(() => cleanup());

describe('AdminUserActions', () => {
  test('lists users with role and disables own row with an explanation', async () => {
    renderPage();
    expect(await screen.findByText('bob')).toBeInTheDocument();
    expect(fetchUsers).toHaveBeenCalledWith({ q: '', page: 1 });
    const mine = screen.getByTestId('user-u-me');
    expect(within(mine).getByRole('button', { name: 'Revoke admin' })).toBeDisabled();
    expect(within(mine).getByText("You can't change your own role.")).toBeInTheDocument();
  });

  test('grant requires confirmation, then calls the API and reloads', async () => {
    grantAdmin.mockResolvedValue({ id: 'u-bob', is_admin: true, changed: true });
    renderPage();
    const card = await screen.findByTestId('user-u-bob');
    fireEvent.click(within(card).getByRole('button', { name: 'Grant admin' }));
    expect(grantAdmin).not.toHaveBeenCalled();
    fireEvent.click(within(card).getByRole('button', { name: 'Confirm grant' }));
    await waitFor(() => expect(grantAdmin).toHaveBeenCalledWith('u-bob'));
    await waitFor(() => expect(fetchUsers).toHaveBeenCalledTimes(2));
    expect(await screen.findByText('bob is now an admin.')).toBeInTheDocument();
  });

  test('cancel abandons the pending revoke', async () => {
    renderPage();
    const card = await screen.findByTestId('user-u-ann');
    fireEvent.click(within(card).getByRole('button', { name: 'Revoke admin' }));
    fireEvent.click(within(card).getByRole('button', { name: 'Cancel' }));
    expect(revokeAdmin).not.toHaveBeenCalled();
    expect(within(card).getByRole('button', { name: 'Revoke admin' })).toBeInTheDocument();
  });

  test('revoke confirmed; server refusal (last admin) is shown', async () => {
    revokeAdmin.mockRejectedValue(new AdminUsersApiError('Cannot revoke the last remaining admin', 409));
    renderPage();
    const card = await screen.findByTestId('user-u-ann');
    fireEvent.click(within(card).getByRole('button', { name: 'Revoke admin' }));
    fireEvent.click(within(card).getByRole('button', { name: 'Confirm revoke' }));
    expect(await screen.findByText('Cannot revoke the last remaining admin')).toBeInTheDocument();
    expect(revokeAdmin).toHaveBeenCalledWith('u-ann');
  });

  test('search submits the trimmed query and resets to page 1', async () => {
    renderPage();
    await screen.findByText('bob');
    fireEvent.change(screen.getByLabelText('Search users'), { target: { value: '  bo ' } });
    fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    await waitFor(() => expect(fetchUsers).toHaveBeenLastCalledWith({ q: 'bo', page: 1 }));
  });

  test('empty search result shows empty copy', async () => {
    fetchUsers.mockResolvedValueOnce(page([ME]));
    renderPage();
    await screen.findByText('me (you)');
    fetchUsers.mockResolvedValue(page([]));
    fireEvent.change(screen.getByLabelText('Search users'), { target: { value: 'zzz' } });
    fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    expect(await screen.findByText('No users match that search.')).toBeInTheDocument();
  });

  test('pagination requests the next page', async () => {
    fetchUsers.mockResolvedValue(page([ME, BOB], { total: 60, page_size: 25 }));
    renderPage();
    await screen.findByText('bob');
    fireEvent.click(screen.getByTitle('2'));
    await waitFor(() => expect(fetchUsers).toHaveBeenLastCalledWith({ q: '', page: 2 }));
  });

  test('403 sends a non-admin home; load errors are shown', async () => {
    fetchUsers.mockRejectedValueOnce(new AdminUsersApiError('Forbidden', 403));
    renderPage();
    expect(await screen.findByTestId('where')).toHaveTextContent('/');
    cleanup();
    fetchUsers.mockRejectedValueOnce(new AdminUsersApiError('Boom', 500));
    renderPage();
    expect(await screen.findByText('Boom')).toBeInTheDocument();
  });
});
