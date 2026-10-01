// Task 20260929-group-invite-links testing: Invite link section behavior.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent, within } from '@testing-library/react';

vi.mock('../lib/invitesApi.js', async () => {
  const actual = await vi.importActual('../lib/invitesApi.js');
  return { ...actual, listGroupInvites: vi.fn(), createGroupInvite: vi.fn(), revokeInvite: vi.fn(), resetGroupInvites: vi.fn() };
});
import { listGroupInvites, createGroupInvite, revokeInvite, resetGroupInvites, InviteApiError } from '../lib/invitesApi.js';
import InviteLinkSection, { _clearInviteCaches } from './InviteLinkSection.jsx';

const OPTIONS = { default_expiry_days: 7, default_max_uses: 25, allowed_expiry_days: [1, 7, 30], allowed_max_uses: [1, 5, 25] };
const future = (days) => new Date(Date.now() + days * 86400000).toISOString();
const INV = (id, extra = {}) => ({
  invite_id: id, created_by_username: 'ann', is_mine: false, created_at: future(-1), expires_at: future(5),
  max_uses: 25, use_count: 3, remaining_uses: 22, ...extra,
});
const URL = 'https://fellowscript.com/join/' + 'Z'.repeat(43);

const mount = (props = {}) => render(<InviteLinkSection userId="u1" groupId="g1" reducedMotion {...props} />);

beforeEach(() => {
  _clearInviteCaches();
  [listGroupInvites, createGroupInvite, revokeInvite, resetGroupInvites].forEach((f) => f.mockReset());
  Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue() } });
});
afterEach(() => { cleanup(); delete navigator.share; });

describe('InviteLinkSection', () => {
  test('feature flag off (uniform 404) hides the whole section', async () => {
    listGroupInvites.mockRejectedValue(new InviteApiError('x', 404, 'not_found'));
    const { container } = mount();
    await waitFor(() => expect(container).toBeEmptyDOMElement());
  });

  test('list shows metadata only: expiry, spots left, creator, and never a link', async () => {
    listGroupInvites.mockResolvedValue({ invites: [INV('i1', { is_mine: true }), INV('i2')], options: OPTIONS });
    const { container } = mount();
    expect(await screen.findByText(/22 of 25 spots left · Created by you/)).toBeInTheDocument();
    expect(screen.getByText(/Created by ann/)).toBeInTheDocument();
    expect(container.textContent).not.toMatch(/fellowscript\.com\/join/);
    expect(screen.getByText("Links can't be shown again after they're created.")).toBeInTheDocument();
    expect(screen.getByText('Reset all links')).toBeInTheDocument();
  });

  test('create shows the link once with Copy, then Done hides it for good', async () => {
    listGroupInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    createGroupInvite.mockResolvedValue({
      invite_id: 'n1', token: 'Z'.repeat(43), url: URL, created_at: future(0), expires_at: null, max_uses: 25, use_count: 0,
    });
    const { container } = mount();
    fireEvent.click(await screen.findByText('Create invite link'));
    expect(await screen.findByText(URL)).toBeInTheDocument();
    expect(createGroupInvite).toHaveBeenCalledWith('u1', 'g1', { maxUses: 25 }); // group links never send an expiry
    expect(screen.getByText(/shown once/)).toBeInTheDocument();
    fireEvent.click(screen.getByText('Copy'));
    await waitFor(() => expect(navigator.clipboard.writeText).toHaveBeenCalledWith(URL));
    expect(await screen.findByText('Copied')).toBeInTheDocument();
    fireEvent.click(screen.getByText('Done'));
    expect(container.textContent).not.toContain(URL);
    expect(screen.getByText(/25 of 25 spots left · Created by you/)).toBeInTheDocument(); // metadata row remains
  });

  test('Share button only when navigator.share exists and passes the url', async () => {
    listGroupInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    createGroupInvite.mockResolvedValue({ invite_id: 'n1', url: URL, created_at: future(0), expires_at: future(7), max_uses: 25, use_count: 0 });
    navigator.share = vi.fn().mockResolvedValue();
    mount();
    fireEvent.click(await screen.findByText('Create invite link'));
    fireEvent.click(await screen.findByText('Share'));
    expect(navigator.share).toHaveBeenCalledWith({ url: URL });
  });

  test('clipboard failure is surfaced, not swallowed', async () => {
    listGroupInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    createGroupInvite.mockResolvedValue({ invite_id: 'n1', url: URL, created_at: future(0), expires_at: future(7), max_uses: 25, use_count: 0 });
    navigator.clipboard.writeText.mockRejectedValue(new Error('denied'));
    mount();
    fireEvent.click(await screen.findByText('Create invite link'));
    fireEvent.click(await screen.findByText('Copy'));
    expect(await screen.findByText(/Couldn't copy/)).toBeInTheDocument();
  });

  test('group options show no expiry choice; chosen uses option is sent without expiry', async () => {
    listGroupInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    createGroupInvite.mockResolvedValue({ invite_id: 'n1', url: URL, created_at: future(0), expires_at: null, max_uses: 5, use_count: 0 });
    mount();
    const toggle = await screen.findByText(/Up to 25 people/);
    expect(toggle.textContent).not.toMatch(/Expires/);
    fireEvent.click(toggle);
    expect(screen.queryByRole('radiogroup', { name: 'Link expires in' })).toBeNull();
    expect(screen.queryByRole('radio', { name: '30 days' })).toBeNull();
    fireEvent.click(screen.getByRole('radio', { name: '5' }));
    fireEvent.click(screen.getByText('Create invite link'));
    await screen.findByText(URL);
    expect(createGroupInvite).toHaveBeenCalledWith('u1', 'g1', { maxUses: 5 });
    expect(createGroupInvite.mock.calls[0][2]).not.toHaveProperty('expiresInDays');
  });

  test('permanent links (expires_at null) render "Never expires"; legacy links keep their expiry', async () => {
    listGroupInvites.mockResolvedValue({
      invites: [INV('p1', { expires_at: null, is_mine: true }), INV('l1', { expires_at: future(5) })], options: OPTIONS,
    });
    mount();
    await screen.findAllByText(/spots left/);
    expect(screen.getByText(/Never expires/)).toBeInTheDocument();
    expect(screen.getAllByText(/spots left/)).toHaveLength(2);
    // legacy link keeps its real expiry (surfaced in the revoke button's label)
    expect(screen.getByRole('button', { name: /Revoke link expires .*created by ann/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Revoke link never expires/i })).toBeInTheDocument();
  });

  test('empty group state says links last until revoked (no expiry promise)', async () => {
    listGroupInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    mount();
    expect(await screen.findByText(/until you revoke it/)).toBeInTheDocument();
    expect(screen.queryByText(/until it expires/)).toBeNull();
  });

  test('a freshly created permanent link row says Never expires and offers Revoke', async () => {
    listGroupInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    createGroupInvite.mockResolvedValue({ invite_id: 'n1', url: URL, created_at: future(0), expires_at: null, max_uses: 25, use_count: 0 });
    mount();
    fireEvent.click(await screen.findByText('Create invite link'));
    await screen.findByText(URL);
    fireEvent.click(screen.getByText('Done'));
    expect(screen.getByText(/Never expires/)).toBeInTheDocument();
    expect(screen.getByText('Revoke')).toBeInTheDocument();
  });

  test('revoked permanent link disappears from the list and a re-list stays empty', async () => {
    listGroupInvites.mockResolvedValue({ invites: [INV('p1', { expires_at: null, is_mine: true })], options: OPTIONS });
    revokeInvite.mockResolvedValue({});
    mount();
    await screen.findByText(/Never expires/);
    fireEvent.click(screen.getByText('Revoke'));
    fireEvent.click(within(screen.getByRole('group', { name: 'Confirm revoke' })).getByText('Revoke'));
    await waitFor(() => expect(revokeInvite).toHaveBeenCalledWith('u1', 'p1'));
    await waitFor(() => expect(screen.queryByText(/Never expires/)).toBeNull());
  });

  test('create errors are shown: link limit and rate limit', async () => {
    listGroupInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    createGroupInvite.mockRejectedValueOnce(new InviteApiError('x', 409, 'link_limit'));
    mount();
    fireEvent.click(await screen.findByText('Create invite link'));
    expect(await screen.findByText(/maximum number of active links/)).toBeInTheDocument();
    createGroupInvite.mockRejectedValueOnce(new InviteApiError('x', 429));
    fireEvent.click(screen.getByText('Create invite link'));
    expect(await screen.findByText(/Too many tries/)).toBeInTheDocument();
  });

  test('create 404 (flag flipped off) hides the section', async () => {
    listGroupInvites.mockResolvedValue({ invites: [], options: OPTIONS });
    createGroupInvite.mockRejectedValue(new InviteApiError('x', 404));
    const { container } = mount();
    fireEvent.click(await screen.findByText('Create invite link'));
    await waitFor(() => expect(container).toBeEmptyDOMElement());
  });

  test('revoke needs confirmation, then calls the API and removes the row', async () => {
    listGroupInvites.mockResolvedValue({ invites: [INV('i1', { is_mine: true }), INV('i2')], options: OPTIONS });
    revokeInvite.mockResolvedValue({});
    mount();
    await screen.findAllByText(/spots left/);
    fireEvent.click(screen.getAllByText('Revoke')[0]);
    expect(revokeInvite).not.toHaveBeenCalled();
    const group = screen.getByRole('group', { name: 'Confirm revoke' });
    fireEvent.click(within(group).getByText('Revoke'));
    await waitFor(() => expect(revokeInvite).toHaveBeenCalledWith('u1', 'i1'));
    await waitFor(() => expect(screen.getAllByText(/spots left/)).toHaveLength(1));
  });

  test('revoke 403 shows a row error and keeps the row', async () => {
    listGroupInvites.mockResolvedValue({ invites: [INV('i2')], options: OPTIONS });
    revokeInvite.mockRejectedValue(new InviteApiError('x', 403));
    mount();
    fireEvent.click(await screen.findByText('Revoke'));
    fireEvent.click(within(screen.getByRole('group', { name: 'Confirm revoke' })).getByText('Revoke'));
    expect(await screen.findByText(/Only the person who made this link/)).toBeInTheDocument();
    expect(screen.getByText(/spots left/)).toBeInTheDocument();
  });

  test('reset all revokes and reports the count', async () => {
    listGroupInvites.mockResolvedValue({ invites: [INV('i1'), INV('i2')], options: OPTIONS });
    resetGroupInvites.mockResolvedValue({ revoked: 2 });
    mount();
    fireEvent.click(await screen.findByText('Reset all links'));
    fireEvent.click(screen.getByText('Revoke all'));
    expect(await screen.findByText('2 links revoked')).toBeInTheDocument();
    expect(resetGroupInvites).toHaveBeenCalledWith('u1', 'g1');
    expect(screen.queryAllByText(/spots left/)).toHaveLength(0);
  });

  test('failed first load shows an error with retry; failed refresh keeps the cached list', async () => {
    listGroupInvites.mockRejectedValueOnce(new InviteApiError('x', 500));
    const first = mount();
    expect(await screen.findByText(/Couldn't load invite links/)).toBeInTheDocument();
    listGroupInvites.mockResolvedValueOnce({ invites: [INV('i2')], options: OPTIONS });
    fireEvent.click(screen.getByText('Try again'));
    await screen.findByText(/spots left/);
    first.unmount();
    listGroupInvites.mockRejectedValueOnce(new InviteApiError('x', 0));
    mount();
    expect(await screen.findByText(/Couldn't refresh just now/)).toBeInTheDocument();
    expect(screen.getByText(/spots left/)).toBeInTheDocument();
  });

  test('403 on list is delegated to onForbidden', async () => {
    listGroupInvites.mockRejectedValue(new InviteApiError('x', 403));
    const onForbidden = vi.fn();
    mount({ onForbidden });
    await waitFor(() => expect(onForbidden).toHaveBeenCalled());
  });
});
