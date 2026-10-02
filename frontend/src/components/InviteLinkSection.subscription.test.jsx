// Task 20260930-subscription-seat-invites testing: InviteLinkSection kind='subscription'.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react';

vi.mock('../lib/invitesApi.js', async () => {
  const actual = await vi.importActual('../lib/invitesApi.js');
  return {
    ...actual,
    listGroupInvites: vi.fn(), createGroupInvite: vi.fn(), resetGroupInvites: vi.fn(), revokeInvite: vi.fn(),
    revealGroupInvite: vi.fn(), listSubscriptionInvites: vi.fn(), createSubscriptionInvite: vi.fn(), resetSubscriptionInvites: vi.fn(),
  };
});
import * as api from '../lib/invitesApi.js';
import InviteLinkSection, { _clearInviteCaches } from './InviteLinkSection.jsx';

const OPTIONS = { default_expiry_days: 7, default_max_uses: 3, allowed_expiry_days: [1, 7], allowed_max_uses: [1, 3] };
const future = (d) => new Date(Date.now() + d * 86400000).toISOString();
const URL = 'https://fellowscript.com/join/' + 'Q'.repeat(43);
const INV = (id) => ({ invite_id: id, created_by_username: 'me', is_mine: true, created_at: future(-1), expires_at: future(5), max_uses: 3, use_count: 1, remaining_uses: 2 });
const mount = (p = {}) => render(<InviteLinkSection kind="subscription" userId="u1" subscriptionId="s1" reducedMotion {...p} />);

beforeEach(() => {
  _clearInviteCaches();
  Object.values(api).forEach((f) => f?.mockReset?.());
  Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue() } });
});
afterEach(cleanup);

describe('InviteLinkSection kind=subscription', () => {
  test('uses the subscription API only, with request (not join) copy', async () => {
    api.listSubscriptionInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    mount();
    expect(await screen.findByText(/ask to join your plan\. You approve each request/)).toBeInTheDocument();
    expect(api.listSubscriptionInvites).toHaveBeenCalledWith('u1', 's1');
    expect(api.listGroupInvites).not.toHaveBeenCalled();
    expect(screen.getByText(/Up to 3 requests/)).toBeInTheDocument();
    expect(screen.queryByText(/can join this group/)).toBeNull();
  });

  test('create shows the link once and calls createSubscriptionInvite, never the group call', async () => {
    api.listSubscriptionInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    api.createSubscriptionInvite.mockResolvedValue({ invite_id: 'n', url: URL, created_at: future(0), expires_at: future(7), max_uses: 3, use_count: 0 });
    const { container } = mount();
    fireEvent.click(await screen.findByText('Create invite link'));
    expect(await screen.findByText(URL)).toBeInTheDocument();
    expect(api.createSubscriptionInvite).toHaveBeenCalledWith('u1', 's1', { expiresInDays: 7, maxUses: 3 });
    expect(api.createGroupInvite).not.toHaveBeenCalled();
    fireEvent.click(screen.getByText('Done'));
    expect(container.textContent).not.toContain(URL);
    expect(screen.getByText(/3 of 3 requests left/)).toBeInTheDocument();
  });

  test('not_eligible 409 and 403 show plan copy', async () => {
    api.listSubscriptionInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    api.createSubscriptionInvite.mockRejectedValueOnce(new api.InviteApiError('x', 409, 'not_eligible'));
    mount();
    fireEvent.click(await screen.findByText('Create invite link'));
    expect(await screen.findByText(/active plan with more than one seat/)).toBeInTheDocument();
    api.createSubscriptionInvite.mockRejectedValueOnce(new api.InviteApiError('x', 403, null));
    fireEvent.click(screen.getByText('Create invite link'));
    expect(await screen.findByText("You can't create an invite link for this plan.")).toBeInTheDocument();
  });

  test('flag off (404) hides the section; list 403 calls onForbidden', async () => {
    api.listSubscriptionInvites.mockRejectedValueOnce(new api.InviteApiError('x', 404, 'not_found'));
    const { container } = mount();
    await waitFor(() => expect(container).toBeEmptyDOMElement());
    cleanup(); _clearInviteCaches();
    const onForbidden = vi.fn();
    api.listSubscriptionInvites.mockRejectedValueOnce(new api.InviteApiError('x', 403, null));
    mount({ onForbidden });
    await waitFor(() => expect(onForbidden).toHaveBeenCalled());
  });

  test('revoke-all uses subscription reset and plan copy', async () => {
    api.listSubscriptionInvites.mockResolvedValue({ invites: [INV('a'), INV('b')], options: OPTIONS });
    api.resetSubscriptionInvites.mockResolvedValue({ revoked: 2 });
    mount();
    fireEvent.click(await screen.findByText('Reset all links'));
    expect(screen.getByText(/Nobody will be able to request with them/)).toBeInTheDocument();
    fireEvent.click(screen.getByText('Revoke all'));
    await waitFor(() => expect(api.resetSubscriptionInvites).toHaveBeenCalledWith('u1', 's1'));
    expect(api.resetGroupInvites).not.toHaveBeenCalled();
  });

  test('cache is per kind: a group with the same id does not share the subscription list', async () => {
    api.listSubscriptionInvites.mockResolvedValue({ invites: [INV('a')], options: OPTIONS });
    const { unmount } = mount({ subscriptionId: 'same' });
    await screen.findByText(/2 of 3 requests left/);
    unmount();
    api.listGroupInvites.mockReturnValue(new Promise(() => {}));
    render(<InviteLinkSection userId="u1" groupId="same" reducedMotion />);
    expect(screen.queryByText(/requests left/)).toBeNull();
  });

  test('subscription rows keep the old copy and never offer Show link or legacy notice', async () => {
    api.listSubscriptionInvites.mockResolvedValue({ invites: [INV('a'), { ...INV('b'), revealable: false }], options: OPTIONS });
    const { container } = mount();
    await screen.findAllByText(/requests left/);
    expect(screen.getByText("Links can't be shown again after they're created.")).toBeInTheDocument();
    expect(screen.queryByText('Show link')).toBeNull();
    expect(screen.queryByText('Create new link')).toBeNull();
    expect(container.textContent).not.toMatch(/created before showing links/);
    expect(api.revealGroupInvite).not.toHaveBeenCalled();
  });
});
