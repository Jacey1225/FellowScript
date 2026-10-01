// Task 20260930-subscription-seat-invites testing: /join for a subscription link.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

const mockAuth = { user: null };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));
vi.mock('../lib/invitesApi.js', async () => {
  const actual = await vi.importActual('../lib/invitesApi.js');
  return { ...actual, previewInvite: vi.fn(), redeemInvite: vi.fn() };
});
import { previewInvite, redeemInvite, InviteApiError } from '../lib/invitesApi.js';
import { getPendingInvite, setPendingInvite } from '../lib/pendingInvite.js';
import JoinInvite, { COPY } from './JoinInvite.jsx';

const TOKEN = 'B'.repeat(43);
const PREVIEW = { kind: 'subscription', inviter_username: 'olivia', plan_type: 'group' };
function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}|{JSON.stringify(l.state)}</div>; }
const renderAt = () => render(
  <MemoryRouter initialEntries={[`/join/${TOKEN}`]}>
    <Routes><Route path="/join/:token" element={<JoinInvite />} /><Route path="*" element={<Where />} /></Routes>
  </MemoryRouter>,
);

beforeEach(() => { sessionStorage.clear(); mockAuth.user = null; previewInvite.mockReset(); redeemInvite.mockReset(); previewInvite.mockResolvedValue(PREVIEW); });
afterEach(() => { cleanup(); delete window.__TAURI_INTERNALS__; });

describe('subscription join link', () => {
  test('signed out: request-to-join copy, sign-in prompt, pending invite kept', async () => {
    renderAt();
    expect(await screen.findByText("Request to join olivia's plan")).toBeInTheDocument();
    expect(screen.getByText(/approve each request before you get access/)).toBeInTheDocument();
    expect(screen.queryByText('Join group')).toBeNull();
    expect(getPendingInvite()).toBe(TOKEN);
    fireEvent.click(screen.getByText('Sign in to request'));
    expect(screen.getByTestId('where').textContent).toContain('/signin');
    expect(getPendingInvite()).toBe(TOKEN);
  });

  test('signed in: request shows "Request sent", never claims membership, clears pending invite', async () => {
    mockAuth.user = { user_id: 'u9' };
    redeemInvite.mockResolvedValue({ kind: 'subscription', joined: false, target_id: 's1', already_member: false });
    renderAt();
    fireEvent.click(await screen.findByText('Request to join'));
    expect(await screen.findByText('Request sent')).toBeInTheDocument();
    expect(screen.getByText(/olivia has to approve your request/)).toBeInTheDocument();
    expect(redeemInvite).toHaveBeenCalledWith('u9', TOKEN);
    expect(getPendingInvite()).toBeNull();
    expect(document.body.textContent).not.toMatch(/You joined|You're in/i);
  });

  test('already on the plan shows the already-member state', async () => {
    mockAuth.user = { user_id: 'u9' };
    redeemInvite.mockResolvedValue({ kind: 'subscription', already_member: true, target_id: 's1' });
    renderAt();
    fireEvent.click(await screen.findByText('Request to join'));
    expect(await screen.findByText("You're already on this plan")).toBeInTheDocument();
  });

  test('409 other_plan shows paid-plan copy; other 409 stays the limit copy', async () => {
    mockAuth.user = { user_id: 'u9' };
    redeemInvite.mockRejectedValueOnce(new InviteApiError('x', 409, 'other_plan'));
    renderAt();
    fireEvent.click(await screen.findByText('Request to join'));
    expect(await screen.findByText(COPY.otherPlan.title)).toBeInTheDocument();
    cleanup();
    redeemInvite.mockRejectedValueOnce(new InviteApiError('x', 409, 'full'));
    renderAt();
    fireEvent.click(await screen.findByText('Request to join'));
    expect(await screen.findByText(COPY.full.title)).toBeInTheDocument();
  });

  test('403 blocked uses plan wording', async () => {
    mockAuth.user = { user_id: 'u9' };
    redeemInvite.mockRejectedValueOnce(new InviteApiError('x', 403, 'blocked'));
    renderAt();
    fireEvent.click(await screen.findByText('Request to join'));
    expect(await screen.findByText(COPY.blockedPlan.title)).toBeInTheDocument();
  });

  test('Cancel clears the pending invite', async () => {
    mockAuth.user = { user_id: 'u9' };
    setPendingInvite(TOKEN);
    renderAt();
    fireEvent.click(await screen.findByText('Cancel'));
    expect(getPendingInvite()).toBeNull();
  });
});
