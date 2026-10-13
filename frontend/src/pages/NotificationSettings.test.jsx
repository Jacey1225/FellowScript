// Task 20261012-notification-settings (testing gate): /account/notifications
// sub-page, its fetch/save client, the Account entry row, and the route wiring.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import NotificationSettings from './NotificationSettings.jsx';
import { PUSH_TYPE_GROUPS, visibleGroups, fetchPushPreferences, savePushPreference } from '../lib/notificationPreferences.js';
import { DESKTOP_ALLOWED_ROUTES } from '../lib/desktopScope.js';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div data-testid="app-nav" /> }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../components/Seo.jsx', () => ({ default: () => null }));

const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockUseAuth() }));
const mockCaps = vi.fn();
vi.mock('../hooks/useCapabilities.js', () => ({ useCapabilities: () => mockCaps() }));

const USER = { user_id: 'user-1', username: 'tester' };
const ALL_KEYS = PUSH_TYPE_GROUPS.flatMap((g) => g.types.map((t) => t.key));
const allOn = () => Object.fromEntries(ALL_KEYS.map((k) => [k, true]));
const res = (body, ok = true, status = ok ? 200 : 500) => ({ ok, status, json: async () => body });
const flags = (on) => ({ isEnabled: (f) => on.includes(f) });

function renderPage() {
  mockUseAuth.mockReturnValue({ user: USER });
  return render(
    <MemoryRouter initialEntries={['/account/notifications']}>
      <Routes>
        <Route path="/account" element={<div data-testid="account-page" />} />
        <Route path="/signin" element={<div data-testid="signin-page" />} />
        <Route path="/account/notifications" element={<NotificationSettings />} />
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => { mockCaps.mockReturnValue(flags([])); });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('notificationPreferences client', () => {
  test('fetch returns the strict flat map and hits the own-user URL', async () => {
    global.fetch = vi.fn(async () => res({ ...allOn(), friend_highlight: false }));
    const m = await fetchPushPreferences('user-1');
    expect(m.friend_highlight).toBe(false);
    expect(Object.keys(m).sort()).toEqual([...ALL_KEYS].sort());
    expect(global.fetch.mock.calls[0][0]).toMatch(/\/notification\/user-1\/push-preferences$/);
  });
  test('fetch throws on non-ok, missing key, non-boolean value, and non-object body', async () => {
    global.fetch = vi.fn(async () => res({}, false, 500));
    await expect(fetchPushPreferences('user-1')).rejects.toThrow();
    const missing = allOn(); delete missing.pins;
    global.fetch = vi.fn(async () => res(missing));
    await expect(fetchPushPreferences('user-1')).rejects.toThrow();
    global.fetch = vi.fn(async () => res({ ...allOn(), pins: 'yes' }));
    await expect(fetchPushPreferences('user-1')).rejects.toThrow();
    global.fetch = vi.fn(async () => res([true]));
    await expect(fetchPushPreferences('user-1')).rejects.toThrow();
  });
  test('save PUTs only the single changed key as a boolean and throws on failure', async () => {
    global.fetch = vi.fn(async () => res({ ...allOn(), pins: false }));
    const m = await savePushPreference('user-1', 'pins', false);
    expect(m.pins).toBe(false);
    const [, init] = global.fetch.mock.calls[0];
    expect(init.method).toBe('PUT');
    expect(JSON.parse(init.body)).toEqual({ pins: false });
    global.fetch = vi.fn(async () => res({}, false, 422));
    await expect(savePushPreference('user-1', 'pins', true)).rejects.toThrow();
  });
  test('user id is URL-encoded', async () => {
    global.fetch = vi.fn(async () => res(allOn()));
    await fetchPushPreferences('a/b?c');
    expect(global.fetch.mock.calls[0][0]).toContain('a%2Fb%3Fc');
  });
  test('essential push types (ring, join approval) are never listed', () => {
    expect(ALL_KEYS).not.toContain('ring');
    expect(ALL_KEYS).not.toContain('join_approval');
    expect(ALL_KEYS).toHaveLength(9);
  });
  test('visibleGroups hides flagged types and drops empty groups', () => {
    const none = visibleGroups(() => false).flatMap((g) => g.types.map((t) => t.key));
    for (const k of ['pins', 'reactions', 'join_requests', 'friend_highlight']) expect(none).not.toContain(k);
    expect(none).toContain('messages');
    const all = visibleGroups(() => true).flatMap((g) => g.types.map((t) => t.key));
    expect(all).toHaveLength(9);
  });
});

describe('NotificationSettings page', () => {
  test('renders confirmed values, hides flagged types when capability is off', async () => {
    global.fetch = vi.fn(async () => res({ ...allOn(), messages: false }));
    renderPage();
    const sw = await screen.findByRole('switch', { name: 'Messages notifications' });
    expect(sw.getAttribute('aria-checked')).toBe('false');
    expect(screen.getByRole('switch', { name: 'Announcements notifications' }).getAttribute('aria-checked')).toBe('true');
    expect(screen.queryByRole('switch', { name: 'Pinned messages notifications' })).toBeNull();
    expect(screen.queryByRole('switch', { name: 'Friend highlights notifications' })).toBeNull();
    expect(screen.queryByRole('switch', { name: 'Reactions notifications' })).toBeNull();
    expect(screen.queryByRole('switch', { name: 'Join requests notifications' })).toBeNull();
    expect(screen.getAllByRole('switch')).toHaveLength(5);
  });
  test('shows flagged types when their capability is on', async () => {
    mockCaps.mockReturnValue(flags(['message_pins', 'friend_highlight_push']));
    global.fetch = vi.fn(async () => res(allOn()));
    renderPage();
    await screen.findByRole('switch', { name: 'Pinned messages notifications' });
    expect(screen.getByRole('switch', { name: 'Friend highlights notifications' })).toBeTruthy();
    expect(screen.queryByRole('switch', { name: 'Reactions notifications' })).toBeNull();
  });
  test('toggle saves the one key and reflects the server-confirmed result', async () => {
    global.fetch = vi.fn(async (_u, init) => {
      if (init?.method === 'PUT') return res({ ...allOn(), messages: false });
      return res(allOn());
    });
    renderPage();
    const sw = await screen.findByRole('switch', { name: 'Messages notifications' });
    fireEvent.click(sw);
    await waitFor(() => expect(screen.getByRole('switch', { name: 'Messages notifications' }).getAttribute('aria-checked')).toBe('false'));
    const put = global.fetch.mock.calls.find(([, i]) => i?.method === 'PUT');
    expect(JSON.parse(put[1].body)).toEqual({ messages: false });
  });
  test('failed save keeps the confirmed value and shows an inline alert', async () => {
    global.fetch = vi.fn(async (_u, init) => (init?.method === 'PUT' ? res({}, false, 500) : res(allOn())));
    renderPage();
    const sw = await screen.findByRole('switch', { name: 'Messages notifications' });
    fireEvent.click(sw);
    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toMatch(/Couldn't save "Messages"/);
    expect(screen.getByRole('switch', { name: 'Messages notifications' }).getAttribute('aria-checked')).toBe('true');
  });
  test('load failure shows an alert and no switches, retry recovers', async () => {
    let fail = true;
    global.fetch = vi.fn(async () => (fail ? res({}, false, 500) : res(allOn())));
    renderPage();
    expect((await screen.findByRole('alert')).textContent).toMatch(/Couldn't load/);
    expect(screen.queryAllByRole('switch')).toHaveLength(0);
    fail = false;
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    await screen.findByRole('switch', { name: 'Messages notifications' });
  });
  test('malformed server body is treated as a load failure, not defaults', async () => {
    global.fetch = vi.fn(async () => res({ messages: true }));
    renderPage();
    await screen.findByRole('alert');
    expect(screen.queryAllByRole('switch')).toHaveLength(0);
  });
  test('back control returns to /account', async () => {
    global.fetch = vi.fn(async () => res(allOn()));
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: 'Back to account' }));
    expect(await screen.findByTestId('account-page')).toBeTruthy();
  });
  test('signed-out user is redirected to /signin and nothing is fetched', async () => {
    mockUseAuth.mockReturnValue({ user: null });
    global.fetch = vi.fn();
    render(
      <MemoryRouter initialEntries={['/account/notifications']}>
        <Routes>
          <Route path="/signin" element={<div data-testid="signin-page" />} />
          <Route path="/account/notifications" element={<NotificationSettings />} />
        </Routes>
      </MemoryRouter>
    );
    expect(await screen.findByTestId('signin-page')).toBeTruthy();
    expect(global.fetch).not.toHaveBeenCalled();
  });
});

describe('wiring', () => {
  test('desktop scope allowlist stays closed to /account/notifications', () => {
    expect([...DESKTOP_ALLOWED_ROUTES]).not.toContain('/account/notifications');
  });
});
