// Task 20260929-group-invite-links testing: /join/:token confirmation screen.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

const mockAuth = { user: null };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));
vi.mock('../lib/invitesApi.js', async () => {
  const actual = await vi.importActual('../lib/invitesApi.js');
  return { ...actual, previewInvite: vi.fn(), redeemInvite: vi.fn() };
});
import { previewInvite, redeemInvite, InviteApiError } from '../lib/invitesApi.js';
import { getPendingInvite, setPendingInvite, peekGroupToOpen } from '../lib/pendingInvite.js';
import JoinInvite, { COPY } from './JoinInvite.jsx';

const TOKEN = 'A'.repeat(43);
const PREVIEW = { kind: 'group', group_name: 'Bible Crew', photo_url: null, inviter_username: 'sam', member_count: 3 };

function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}|{JSON.stringify(l.state)}</div>; }
function renderAt(path) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/join/:token" element={<JoinInvite />} />
        <Route path="*" element={<Where />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => { sessionStorage.clear(); mockAuth.user = null; previewInvite.mockReset(); redeemInvite.mockReset(); });
afterEach(() => { cleanup(); delete window.__TAURI_INTERNALS__; });

describe('preview', () => {
  test('signed out: shows group, inviter, count and a sign-in path; keeps pending invite', async () => {
    previewInvite.mockResolvedValue(PREVIEW);
    renderAt(`/join/${TOKEN}`);
    expect(await screen.findByText('Bible Crew')).toBeInTheDocument();
    expect(screen.getByText(/Invited by sam/)).toBeInTheDocument();
    expect(screen.getByText(/3 members/)).toBeInTheDocument();
    expect(previewInvite).toHaveBeenCalledWith(TOKEN);
    expect(screen.queryByText('Join group')).toBeNull();
    expect(getPendingInvite()).toBe(TOKEN);
    fireEvent.click(screen.getByText('Sign in to join'));
    expect(screen.getByTestId('where').textContent).toContain('/signin');
    expect(getPendingInvite()).toBe(TOKEN); // survives the trip to sign-in
  });

  test('signed out: create account routes to signup tab and keeps the invite', async () => {
    previewInvite.mockResolvedValue(PREVIEW);
    renderAt(`/join/${TOKEN}`);
    fireEvent.click(await screen.findByText('Create an account'));
    expect(screen.getByTestId('where').textContent).toContain('"tab":"signup"');
    expect(getPendingInvite()).toBe(TOKEN);
  });

  test('singular member count', async () => {
    previewInvite.mockResolvedValue({ ...PREVIEW, member_count: 1 });
    renderAt(`/join/${TOKEN}`);
    expect(await screen.findByText(/1 member$/m)).toBeInTheDocument();
  });

  test('malformed token never calls the API and shows the uniform invalid message', () => {
    renderAt('/join/not-a-token');
    expect(screen.getByText(COPY.invalid.title)).toBeInTheDocument();
    expect(previewInvite).not.toHaveBeenCalled();
    expect(getPendingInvite()).toBeNull();
  });

  test('preview 404 shows the uniform not-found copy and clears the pending invite', async () => {
    previewInvite.mockRejectedValue(new InviteApiError('x', 404, 'not_found'));
    setPendingInvite(TOKEN);
    renderAt(`/join/${TOKEN}`);
    expect(await screen.findByText(COPY.invalid.title)).toBeInTheDocument();
    await waitFor(() => expect(getPendingInvite()).toBeNull());
  });

  test('preview network failure is visible, retryable, and keeps the invite', async () => {
    previewInvite.mockRejectedValueOnce(new InviteApiError('x', 0)).mockResolvedValueOnce(PREVIEW);
    renderAt(`/join/${TOKEN}`);
    expect(await screen.findByText(COPY.network.title)).toBeInTheDocument();
    expect(getPendingInvite()).toBe(TOKEN);
    fireEvent.click(screen.getByText('Try again'));
    expect(await screen.findByText('Bible Crew')).toBeInTheDocument();
  });
});

describe('redeem', () => {
  beforeEach(() => { mockAuth.user = { user_id: 'u1' }; previewInvite.mockResolvedValue(PREVIEW); });

  test('success on web: shows "You\'re in", clears pending, no redirect anywhere else', async () => {
    redeemInvite.mockResolvedValue({ joined: true, target_id: 'g1' });
    renderAt(`/join/${TOKEN}`);
    fireEvent.click(await screen.findByText('Join group'));
    expect(await screen.findByText("You're in")).toBeInTheDocument();
    expect(redeemInvite).toHaveBeenCalledWith('u1', TOKEN);
    expect(getPendingInvite()).toBeNull();
    expect(peekGroupToOpen()).toBeNull();
  });

  test('success on desktop: stores group to open and goes to /reader only', async () => {
    window.__TAURI_INTERNALS__ = {};
    redeemInvite.mockResolvedValue({ joined: false, already_member: true, target_id: 'g9' });
    renderAt(`/join/${TOKEN}`);
    fireEvent.click(await screen.findByText('Join group'));
    await waitFor(() => expect(screen.getByTestId('where').textContent).toContain('/reader'));
    expect(peekGroupToOpen()).toBe('g9');
    expect(getPendingInvite()).toBeNull();
  });

  test('double-tap only redeems once', async () => {
    let resolve;
    redeemInvite.mockReturnValue(new Promise((r) => { resolve = r; }));
    renderAt(`/join/${TOKEN}`);
    const btn = await screen.findByText('Join group');
    fireEvent.click(btn); fireEvent.click(btn);
    expect(redeemInvite).toHaveBeenCalledTimes(1);
    resolve({ target_id: 'g1' });
    await screen.findByText("You're in");
  });

  test.each([
    ['expired', 410, 'expired', COPY.expired.title],
    ['revoked', 410, 'revoked', COPY.revoked.title],
    ['full', 409, 'full', COPY.full.title],
    ['not found', 404, 'not_found', COPY.invalid.title],
    ['blocked', 403, 'blocked', COPY.blocked.title],
  ])('terminal error %s shows exact copy and clears the pending invite', async (_n, status, code, title) => {
    redeemInvite.mockRejectedValue(new InviteApiError('server text', status, code));
    renderAt(`/join/${TOKEN}`);
    fireEvent.click(await screen.findByText('Join group'));
    expect(await screen.findByText(title)).toBeInTheDocument();
    expect(getPendingInvite()).toBeNull();
    expect(screen.queryByText('Try again')).toBeNull();
  });

  test('blocked copy is generic and leaks nothing about who blocked whom', () => {
    expect(COPY.blocked.title).toBe("You can't join this group.");
    expect(COPY.blocked.body).toBeNull();
  });

  test('429 keeps the pending invite and offers Try again that re-redeems', async () => {
    redeemInvite.mockRejectedValueOnce(new InviteApiError('x', 429)).mockResolvedValueOnce({ target_id: 'g1' });
    renderAt(`/join/${TOKEN}`);
    fireEvent.click(await screen.findByText('Join group'));
    expect(await screen.findByText(COPY.rate.title)).toBeInTheDocument();
    expect(getPendingInvite()).toBe(TOKEN);
    fireEvent.click(screen.getByText('Try again'));
    expect(await screen.findByText("You're in")).toBeInTheDocument();
    expect(redeemInvite).toHaveBeenCalledTimes(2);
  });

  test('401 keeps the pending invite and sends the user to sign in', async () => {
    redeemInvite.mockRejectedValue(new InviteApiError('x', 401));
    renderAt(`/join/${TOKEN}`);
    fireEvent.click(await screen.findByText('Join group'));
    await waitFor(() => expect(screen.getByTestId('where').textContent).toContain('/signin'));
    expect(getPendingInvite()).toBe(TOKEN);
  });

  test('Cancel clears the pending invite and goes home (fixed destination)', async () => {
    renderAt(`/join/${TOKEN}`);
    fireEvent.click(await screen.findByText('Cancel'));
    expect(screen.getByTestId('where').textContent.startsWith('/|')).toBe(true);
    expect(getPendingInvite()).toBeNull();
    expect(redeemInvite).not.toHaveBeenCalled();
  });
});

describe('open-redirect safety', () => {
  test('no route param, query or state can choose a destination: only fixed paths are navigated to', async () => {
    previewInvite.mockResolvedValue(PREVIEW);
    mockAuth.user = { user_id: 'u1' };
    redeemInvite.mockRejectedValue(new InviteApiError('x', 403, 'blocked'));
    renderAt(`/join/${TOKEN}?redirect=https://evil.com&next=//evil.com`);
    fireEvent.click(await screen.findByText('Join group'));
    fireEvent.click(await screen.findByText('Back to FellowScript'));
    expect(screen.getByTestId('where').textContent.startsWith('/|')).toBe(true);
  });

  test('a path-traversal style token is rejected before any request', () => {
    renderAt('/join/..%2F..%2Fevil');
    expect(previewInvite).not.toHaveBeenCalled();
    expect(screen.getByText(COPY.invalid.title)).toBeInTheDocument();
  });
});
