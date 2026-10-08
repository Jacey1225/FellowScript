// mfa_required 403 on an admin surface ends the session and routes to sign-in
// (task 20261008-admin-require-2fa); a plain 403 still goes home.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

const signOut = vi.fn();
const mockAuth = { user: { user_id: 'u-me' }, signOut };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));
vi.mock('../components/AppNav.jsx', () => ({ default: () => null }));
vi.mock('../lib/adminUsersApi.js', async () => {
  const actual = await vi.importActual('../lib/adminUsersApi.js');
  return { ...actual, fetchUsers: vi.fn() };
});
import { fetchUsers, AdminUsersApiError } from '../lib/adminUsersApi.js';
import { hasMfaRequiredFlag } from '../lib/adminMfa.js';
import AdminUserActions from './AdminUserActions.jsx';

function Where() {
  const l = useLocation();
  return <div data-testid="where">{l.pathname}|{l.state?.mfaRequired ? 'mfa' : ''}</div>;
}
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

beforeEach(() => { fetchUsers.mockReset(); signOut.mockReset(); sessionStorage.clear(); });
afterEach(() => cleanup());

describe('AdminUserActions mfa_required', () => {
  test('signs out, sets the flag, routes to /signin with the notice state', async () => {
    const e = new AdminUsersApiError('2FA required', 403); e.code = 'mfa_required';
    fetchUsers.mockRejectedValue(e);
    renderPage();
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/signin|mfa'));
    expect(signOut).toHaveBeenCalledTimes(1);
    expect(hasMfaRequiredFlag()).toBe(true);
  });

  test('plain 403 (non-admin) still goes home without signing out', async () => {
    fetchUsers.mockRejectedValue(new AdminUsersApiError('Admin access required', 403));
    renderPage();
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/|'));
    expect(signOut).not.toHaveBeenCalled();
    expect(hasMfaRequiredFlag()).toBe(false);
  });
});
