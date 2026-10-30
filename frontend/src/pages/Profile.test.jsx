// Task 20261030-user-profiles testing step 8: the /profile/:userId page.
// Heavy chrome (nav, bloom, SEO, report modal) is stubbed; the page, hooks,
// cache and API wrappers are real, with fetch mocked at the network edge.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, act, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div data-testid="app-nav" /> }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../components/Seo.jsx', () => ({ default: () => null }));
vi.mock('../components/ContactsPanel.jsx', () => ({
  ReportUserModal: ({ target }) => (target ? <div data-testid="report-modal">{target.name}</div> : null),
}));
const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockUseAuth() }));

import Profile from './Profile.jsx';
import { getCachedProfile, setCachedProfile, clearProfileCache } from '../lib/profileCache.js';

// antd's first render is slow on a loaded CI box/laptop; the default 5s flaked once under full-suite load.
vi.setConfig({ testTimeout: 20000 });

const ME = { user_id: 'me-1', username: 'me' };
const TARGET = 't-1';
const prof = (state, extra = {}) => ({ user_id: TARGET, username: 'Ann', profile_photo_url: null, relationship: { state }, editable: false, ...extra });
const res = (body, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => body });

let fetchMock;
function LocationProbe() {
  const loc = useLocation();
  return <div data-testid="loc">{loc.pathname}{loc.state?.openDm ? `|dm:${loc.state.openDm.id}` : ''}</div>;
}
function renderPage(path = `/profile/${TARGET}`) {
  return render(
    <MemoryRouter initialEntries={['/reader', path]} initialIndex={1}>
      <LocationProbe />
      <Routes>
        <Route path="/profile/:userId" element={<Profile />} />
        <Route path="/reader" element={<div>reader</div>} />
        <Route path="/account" element={<div>account</div>} />
      </Routes>
    </MemoryRouter>,
  );
}
const calls = (re, method) => fetchMock.mock.calls.filter(([u, o]) => re.test(u) && (!method || (o?.method || 'GET') === method));

beforeEach(() => {
  clearProfileCache();
  mockUseAuth.mockReturnValue({ user: ME });
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.useRealTimers(); });

describe('Profile page visibility tiers', () => {
  test('stranger: username, Add friend, bio hidden line, no Message', async () => {
    fetchMock.mockResolvedValue(res(prof('none')));
    renderPage();
    expect(await screen.findByText('Ann')).toBeInTheDocument();
    expect(screen.getByText('Bio is shared with friends.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /add ann as a friend/i })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^message ann/i })).toBeNull();
  });

  test('friend: bio shown, Message and Friends chip', async () => {
    fetchMock.mockResolvedValue(res(prof('friends', { bio: 'Walking with Jesus' })));
    renderPage();
    expect(await screen.findByText('Walking with Jesus')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /message ann/i })).toBeInTheDocument();
    expect(screen.getByText('Friends')).toBeInTheDocument();
  });

  test('friend with null bio: "No bio yet."', async () => {
    fetchMock.mockResolvedValue(res(prof('friends', { bio: null })));
    renderPage();
    expect(await screen.findByText('No bio yet.')).toBeInTheDocument();
  });

  test('self: Add bio, no overflow menu', async () => {
    fetchMock.mockResolvedValue(res(prof('self', { bio: null, editable: true })));
    renderPage();
    expect(await screen.findByRole('button', { name: /add bio/i })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /more options/i })).toBeNull();
  });

  test('Message navigates to /reader with openDm state', async () => {
    fetchMock.mockResolvedValue(res(prof('friends', { bio: null, profile_photo_url: 'p.png' })));
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: /message ann/i }));
    await waitFor(() => expect(screen.getByTestId('loc').textContent).toBe(`/reader|dm:${TARGET}`));
  });
});

describe('Profile page load failure handling', () => {
  test('404: "This profile isn\'t available." and the cached entry is evicted', async () => {
    setCachedProfile(ME.user_id, TARGET, prof('friends', { bio: 'old secret bio' }));
    fetchMock.mockResolvedValue(res({ detail: 'User not found' }, 404));
    renderPage();
    expect(await screen.findByText("This profile isn't available.")).toBeInTheDocument();
    expect(screen.queryByText('old secret bio')).toBeNull();
    expect(getCachedProfile(ME.user_id, TARGET)).toBeNull();
  });

  test('network failure with cache: keeps showing the cached profile with the stale notice and Retry', async () => {
    setCachedProfile(ME.user_id, TARGET, prof('friends', { bio: 'cached bio' }));
    fetchMock.mockRejectedValue(new TypeError('offline'));
    renderPage();
    expect(await screen.findByText(/Couldn't refresh\. Showing what we had\./)).toBeInTheDocument();
    expect(screen.getByText('cached bio')).toBeInTheDocument();
    expect(getCachedProfile(ME.user_id, TARGET)).not.toBeNull();
    fetchMock.mockResolvedValue(res(prof('friends', { bio: 'fresh bio' })));
    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    expect(await screen.findByText('fresh bio')).toBeInTheDocument();
  });

  test('500 with cache keeps the cache', async () => {
    setCachedProfile(ME.user_id, TARGET, prof('friends', { bio: 'cached bio' }));
    fetchMock.mockResolvedValue(res({ detail: 'boom' }, 500));
    renderPage();
    expect(await screen.findByText(/Showing what we had/)).toBeInTheDocument();
    expect(screen.getByText('cached bio')).toBeInTheDocument();
  });

  test('first-load failure with no cache: error screen with Try again, nothing fabricated', async () => {
    fetchMock.mockRejectedValue(new TypeError('offline'));
    renderPage();
    expect(await screen.findByText("Couldn't load this profile.")).toBeInTheDocument();
    expect(screen.queryByText('Ann')).toBeNull();
    fetchMock.mockResolvedValue(res(prof('none')));
    fireEvent.click(screen.getByRole('button', { name: /try again/i }));
    expect(await screen.findByText('Ann')).toBeInTheDocument();
  });
});

describe('Profile page bio editing', () => {
  const type = (t) => fireEvent.change(screen.getByLabelText('Bio'), { target: { value: t } });

  test('save success shows the stored (normalized) bio and PUTs exactly {bio}', async () => {
    fetchMock.mockImplementation(async (u, o) => {
      if (/\/bio$/.test(u)) return res({ bio: 'Hello there' });
      return res(prof('self', { bio: null, editable: true }));
    });
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: /add bio/i }));
    type('Hello   there');
    fireEvent.click(screen.getByRole('button', { name: /save/i }));
    // (the textarea mirrors its draft into textContent, so wait for the editor to close first)
    await waitFor(() => expect(screen.queryByLabelText('Bio')).toBeNull(), { timeout: 5000 });
    expect(screen.getByText('Hello there')).toBeInTheDocument();
    const put = calls(/\/profile\/me-1\/bio$/, 'PUT')[0];
    expect(JSON.parse(put[1].body)).toEqual({ bio: 'Hello   there' });
    expect(getCachedProfile(ME.user_id, TARGET).bio).toBe('Hello there');
  });

  test('save failure keeps the draft verbatim and shows the server message inline', async () => {
    fetchMock.mockImplementation(async (u) => {
      if (/\/bio$/.test(u)) return res({ detail: 'Bios are plain text, so links can not be saved.' }, 422);
      return res(prof('self', { bio: null, editable: true }));
    });
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: /add bio/i }));
    type('see evil.com please');
    fireEvent.click(screen.getByRole('button', { name: /save/i }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Bios are plain text');
    expect(screen.getByLabelText('Bio')).toHaveValue('see evil.com please');
  });

  test('clearing the text saves null', async () => {
    fetchMock.mockImplementation(async (u) => {
      if (/\/bio$/.test(u)) return res({ bio: null });
      return res(prof('self', { bio: 'old', editable: true }));
    });
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: /edit bio/i }));
    type('   ');
    fireEvent.click(screen.getByRole('button', { name: /save/i }));
    await waitFor(() => expect(calls(/\/bio$/, 'PUT')).toHaveLength(1));
    expect(JSON.parse(calls(/\/bio$/, 'PUT')[0][1].body)).toEqual({ bio: null });
  });
});

describe('Profile page friend actions', () => {
  test('Add friend POSTs the request then refetches for the real state (no assumption)', async () => {
    let state = 'none';
    fetchMock.mockImplementation(async (u, o) => {
      if (/friend-request$/.test(u)) { return { ok: true, status: 204, json: async () => ({}) }; }
      return res(prof(state));
    });
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: /add ann as a friend/i }));
    await waitFor(() => expect(calls(/friend-request$/, 'POST')).toHaveLength(1));
    // server (uniform response) still says none: UI must not claim "Request sent"
    await waitFor(() => expect(calls(/\/profiles\/t-1$/).length).toBeGreaterThanOrEqual(2));
    expect(screen.queryByRole('button', { name: 'Request sent' })).toBeNull();
    expect(screen.getByRole('button', { name: /add ann as a friend/i })).toBeInTheDocument();
  });

  test('429 on request shows the generic slow-down copy', async () => {
    fetchMock.mockImplementation(async (u) => {
      if (/friend-request$/.test(u)) return res({ detail: 'Too many requests. Please try again later.' }, 429);
      return res(prof('none'));
    });
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: /add ann as a friend/i }));
    expect(await screen.findByText('Slow down a little and try again in a moment.')).toBeInTheDocument();
  });

  test('Accept POSTs friend-accept and shows the refetched friend state', async () => {
    let accepted = false;
    fetchMock.mockImplementation(async (u) => {
      if (/friend-accept$/.test(u)) { accepted = true; return { ok: true, status: 204, json: async () => ({}) }; }
      return res(accepted ? prof('friends', { bio: null }) : prof('request_received'));
    });
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: /accept friend request from ann/i }));
    expect(await screen.findByRole('button', { name: /message ann/i })).toBeInTheDocument();
  });
});

describe('Profile page deferred unfriend', () => {
  const openMenuAndUnfriend = async () => {
    fireEvent.click(await screen.findByRole('button', { name: /more options for ann/i }));
    fireEvent.click(await screen.findByText('Unfriend'));
  };

  test('Unfriend hides the bio immediately, does not call the API until 6s, then commits', async () => {
    fetchMock.mockImplementation(async (u, o) => {
      if ((o?.method) === 'DELETE') return res({});
      return res(prof('friends', { bio: 'friend-only bio' }));
    });
    renderPage();
    await screen.findByText('friend-only bio');
    vi.useFakeTimers({ shouldAdvanceTime: true });
    await openMenuAndUnfriend();
    expect(screen.queryByText('friend-only bio')).toBeNull();
    expect(calls(/\/friends\/me-1\/t-1$/, 'DELETE')).toHaveLength(0);
    await act(async () => { vi.advanceTimersByTime(5900); });
    expect(calls(/\/friends\/me-1\/t-1$/, 'DELETE')).toHaveLength(0);
    await act(async () => { vi.advanceTimersByTime(300); });
    await waitFor(() => expect(calls(/\/friends\/me-1\/t-1$/, 'DELETE')).toHaveLength(1));
  });

  test('Undo within the window restores the friend state and never calls DELETE', async () => {
    fetchMock.mockImplementation(async (u, o) => {
      if ((o?.method) === 'DELETE') return res({});
      return res(prof('friends', { bio: 'friend-only bio' }));
    });
    renderPage();
    await screen.findByText('friend-only bio');
    vi.useFakeTimers({ shouldAdvanceTime: true });
    await openMenuAndUnfriend();
    fireEvent.click(await screen.findByRole('button', { name: 'Undo' }));
    expect(await screen.findByText('friend-only bio')).toBeInTheDocument();
    await act(async () => { vi.advanceTimersByTime(20000); });
    expect(calls(/\/friends\/me-1\/t-1$/, 'DELETE')).toHaveLength(0);
  });

  test('leaving the page during the window commits the unfriend', async () => {
    fetchMock.mockImplementation(async (u, o) => {
      if ((o?.method) === 'DELETE') return res({});
      return res(prof('friends', { bio: 'x' }));
    });
    const { unmount } = renderPage();
    await screen.findByText('x');
    await openMenuAndUnfriend();
    unmount();
    await waitFor(() => expect(calls(/\/friends\/me-1\/t-1$/, 'DELETE')).toHaveLength(1));
  });
});

describe('Profile page overflow menu', () => {
  test('stranger menu: Block and Report, no Unfriend; Report opens the report modal', async () => {
    fetchMock.mockResolvedValue(res(prof('none')));
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: /more options for ann/i }));
    expect(await screen.findByText('Block')).toBeInTheDocument();
    expect(screen.queryByText('Unfriend')).toBeNull();
    fireEvent.click(screen.getByText('Report'));
    expect(await screen.findByTestId('report-modal')).toHaveTextContent('Ann');
  });
});
