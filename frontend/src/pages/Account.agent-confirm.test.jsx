// Regression tests for task 20260904-compliance-reliability-bugs's fix to
// Account.jsx's handleToggleAgent/handleRenameAgent: both used to apply the
// optimistic UI change and stop there -- toggle ignored the response status
// entirely, and rename never reverted or surfaced any failure. They now
// mirror iOS NetworkService.updateAgent/renameAgent + AccountView's
// revert-on-catch pattern: apply optimistically, then only *keep* the change
// once the write is confirmed to have succeeded server-side (Architecture
// Q27 -- a rejected write must not be silently indistinguishable from a
// successful one).
//
// AppNav/AppBloom/SubscriptionCard/DonationButton are stubbed out -- AppNav
// pulls in useTheme, which reads a bare `localStorage` global that is
// undefined in this repo's current jsdom/vitest environment (a pre-existing,
// unrelated Node-version issue -- see js/notes.delete-refresh.test.js's
// header comment); SubscriptionCard/DonationButton just add unrelated fetch
// noise to a test scoped to the Agents section.
//
// Run with: cd frontend && npm test -- --run src/pages/Account.agent-confirm.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, within, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { message } from 'antd';
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
const AGENT_ID = 'agent-1';

function jsonRes(body, ok = true, status = ok ? 200 : 500) {
  return { ok, status, json: async () => body };
}

// Set per-test to control what the agent-write PUT resolves/throws.
let putBehavior;

function makeFetchMock() {
  return vi.fn(async (url, opts = {}) => {
    const method = (opts.method || 'GET').toUpperCase();
    if (/\/user\/user-1$/.test(url) && method === 'GET') {
      return jsonRes({ ...USER, groups: [], friend_requests: [] });
    }
    if (/\/notes\/highlight\/user-1$/.test(url)) return jsonRes({});
    if (/\/notes\/user-1$/.test(url)) return jsonRes({});
    if (/\/agent\/user-1$/.test(url) && method === 'GET') {
      return jsonRes({ [AGENT_ID]: { name: 'Guide', enabled: true, role: '' } });
    }
    if (/\/agent\/user-1\/agent-1\/heartbeats$/.test(url)) return jsonRes([]);
    if (/\/agent\/user-1\/agent-1$/.test(url) && method === 'PUT') {
      if (putBehavior === 'throw') throw new Error('network down');
      return putBehavior;
    }
    if (/\/subscriptions\/user\/user-1\/usage$/.test(url)) {
      return jsonRes({ subscribed: false, window_days: 7, resources: {} });
    }
    if (/\/blocks\/user-1$/.test(url)) return jsonRes([]);
    return jsonRes({}, false, 404);
  });
}

function renderAccount() {
  mockUseAuth.mockReturnValue({ user: USER, signOut: vi.fn(), updateUser: vi.fn() });
  return render(
    <MemoryRouter initialEntries={['/account']}>
      <Account />
    </MemoryRouter>
  );
}

beforeEach(() => {
  putBehavior = jsonRes({}, true, 200);
  global.fetch = makeFetchMock();
  vi.spyOn(message, 'error').mockImplementation(() => {});
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('Account — agent toggle only keeps the optimistic state once the write is confirmed', () => {
  test('a successful PUT keeps the toggled-off state and surfaces no error', async () => {
    renderAccount();
    const renameBtn = await screen.findByTitle('Rename agent');
    const toggle = within(renameBtn.parentElement).getByRole('switch');
    expect(toggle.getAttribute('aria-checked')).toBe('true');

    fireEvent.click(toggle); // optimistic: React batches this to the settled state directly under act's flush, but must land on the confirmed value below regardless
    await waitFor(() => expect(toggle.getAttribute('aria-checked')).toBe('false'));
    expect(message.error).not.toHaveBeenCalled();
  });

  test('a failed PUT (500) reverts the switch back on and surfaces message.error', async () => {
    putBehavior = jsonRes({}, false, 500);
    renderAccount();
    const renameBtn = await screen.findByTitle('Rename agent');
    const toggle = within(renameBtn.parentElement).getByRole('switch');
    expect(toggle.getAttribute('aria-checked')).toBe('true');

    fireEvent.click(toggle);
    await waitFor(() => expect(toggle.getAttribute('aria-checked')).toBe('true')); // reverted
    expect(message.error).toHaveBeenCalled();
  });

  test('a network-throwing PUT also reverts the switch and surfaces message.error', async () => {
    putBehavior = 'throw';
    renderAccount();
    const renameBtn = await screen.findByTitle('Rename agent');
    const toggle = within(renameBtn.parentElement).getByRole('switch');

    fireEvent.click(toggle);
    await waitFor(() => expect(toggle.getAttribute('aria-checked')).toBe('true')); // reverted
    expect(message.error).toHaveBeenCalled();
  });
});

describe('Account — agent rename only keeps the optimistic name once the write is confirmed', () => {
  test('a successful rename PUT keeps the new name and surfaces no error', async () => {
    renderAccount();
    await screen.findByText('Guide');
    const renameBtn = screen.getByTitle('Rename agent');
    const row = renameBtn.parentElement;

    fireEvent.click(renameBtn);
    const input = within(row).getByRole('textbox');
    fireEvent.change(input, { target: { value: 'New Name' } });
    fireEvent.keyDown(input, { key: 'Enter', code: 'Enter' });

    await waitFor(() => expect(within(row).getByText('New Name')).toBeTruthy());
    expect(message.error).not.toHaveBeenCalled();
  });

  test('a failed rename PUT (500) reverts to the previous name and surfaces message.error', async () => {
    putBehavior = jsonRes({}, false, 500);
    renderAccount();
    await screen.findByText('Guide');
    const renameBtn = screen.getByTitle('Rename agent');
    const row = renameBtn.parentElement;

    fireEvent.click(renameBtn);
    const input = within(row).getByRole('textbox');
    fireEvent.change(input, { target: { value: 'Bad Rename' } });
    fireEvent.keyDown(input, { key: 'Enter', code: 'Enter' });

    await waitFor(() => expect(within(row).getByText('Guide')).toBeTruthy());
    expect(within(row).queryByText('Bad Rename')).toBeNull();
    expect(message.error).toHaveBeenCalled();
  });

  test('a network-throwing rename PUT also reverts to the previous name and surfaces message.error', async () => {
    putBehavior = 'throw';
    renderAccount();
    await screen.findByText('Guide');
    const renameBtn = screen.getByTitle('Rename agent');
    const row = renameBtn.parentElement;

    fireEvent.click(renameBtn);
    const input = within(row).getByRole('textbox');
    fireEvent.change(input, { target: { value: 'Bad Rename' } });
    fireEvent.keyDown(input, { key: 'Enter', code: 'Enter' });

    await waitFor(() => expect(within(row).getByText('Guide')).toBeTruthy());
    expect(within(row).queryByText('Bad Rename')).toBeNull();
    expect(message.error).toHaveBeenCalled();
  });
});
