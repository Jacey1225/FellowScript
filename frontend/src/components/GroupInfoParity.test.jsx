// Task 20261003-web-reader-ios-parity step 3: add-members from group info and
// the Publish to Explorer paid-only pre-check.
// Run: cd frontend && npx vitest run src/components/GroupInfoParity.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react';

vi.mock('../lib/groupInfoApi.js', () => ({
  fetchGroupInfo: vi.fn(), renameGroup: vi.fn(), setGroupMuted: vi.fn(), setGroupMaxMembers: vi.fn(),
  uploadGroupPhoto: vi.fn(), removeGroupPhoto: vi.fn(), confirmGroupPhoto: vi.fn(),
  fetchGroupGallery: vi.fn(),
  GROUP_PHOTO_LIMITS: { maxBytes: 1, accept: ['image/png'], oversizeCopy: 'x' },
}));
import * as api from '../lib/groupInfoApi.js';
import GroupInfoPanel, { _clearGroupInfoCaches } from './GroupInfoPanel.jsx';
import GroupPublishSection from './GroupPublishSection.jsx';
import { isPublishBlocked } from '../lib/publishGate.js';
import { getUpgradePrompt, dismissUpgradePrompt } from '../lib/upgradePrompt.js';

const CONTACT = { id: 'g1', name: 'Study Group', type: 'group', toUsers: ['u1', 'u2'] };
const USER = { user_id: 'u1', username: 'me' };
const FRIENDS = [
  { id: 'u2', name: 'ann', type: 'friend' },
  { id: 'u3', name: 'bob', type: 'friend', photoUrl: null },
];

beforeEach(() => {
  _clearGroupInfoCaches();
  dismissUpgradePrompt();
  api.fetchGroupInfo.mockReset().mockResolvedValue({ title: 'Study Group', photo_url: null, muted: false });
  api.fetchGroupGallery.mockReset().mockResolvedValue({ items: [], has_more: false });
  global.fetch = vi.fn();
});
afterEach(cleanup);

function panel(props = {}) {
  return render(<GroupInfoPanel open onClose={vi.fn()} contact={CONTACT} user={USER}
    groupMembers={[{ user_id: 'u2', username: 'ann' }]} friends={FRIENDS}
    onGroupChanged={vi.fn()} onGroupGone={vi.fn()} {...props} />);
}

describe('Add friends from group info', () => {
  test('no Add control when the host provides no add handler', async () => {
    panel();
    await screen.findByText(/Nothing shared yet/);
    expect(screen.queryByText('Add friends')).toBeNull();
  });

  test('lists only friends not already in the group and adds the selection', async () => {
    const onAddMembers = vi.fn().mockResolvedValue({ ok: true });
    panel({ onAddMembers });
    await screen.findByText(/Nothing shared yet/);
    fireEvent.click(screen.getByText('Add friends'));
    expect(screen.queryByRole('checkbox', { name: /^ann\./ })).toBeNull();
    fireEvent.click(screen.getByRole('checkbox', { name: 'bob. Not selected' }));
    fireEvent.click(screen.getByRole('button', { name: 'Add (1)' }));
    await waitFor(() => expect(onAddMembers).toHaveBeenCalledWith('g1', [{ user_id: 'u3', username: 'bob', photoUrl: null }]));
    // Closing resets the selection; reopening shows nothing selected.
    fireEvent.click(screen.getByText('Add friends'));
    await waitFor(() => expect(screen.getByRole('checkbox', { name: 'bob. Not selected' })).toBeInTheDocument());
  });

  test('a server refusal (group full) is shown and the dialog stays open', async () => {
    const onAddMembers = vi.fn().mockResolvedValue({ ok: false, detail: 'This group is full.' });
    panel({ onAddMembers });
    await screen.findByText(/Nothing shared yet/);
    fireEvent.click(screen.getByText('Add friends'));
    fireEvent.click(screen.getByRole('checkbox', { name: /bob/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Add (1)' }));
    expect(await screen.findByText('This group is full.')).toBeInTheDocument();
    expect(screen.getByText('Add Members')).toBeInTheDocument();
  });

  test('empty candidates shows the all-friends-added copy', async () => {
    panel({ onAddMembers: vi.fn(), friends: [FRIENDS[0]] });
    await screen.findByText(/Nothing shared yet/);
    fireEvent.click(screen.getByText('Add friends'));
    expect(screen.getByText('All your friends are already in this group.')).toBeInTheDocument();
  });
});

describe('isPublishBlocked', () => {
  test('blocks only on an explicit allowed:false', async () => {
    global.fetch.mockResolvedValue({ ok: true, json: async () => ({ paid_only: { explorer_publish: { allowed: false } } }) });
    expect(await isPublishBlocked('u1')).toBe(true);
    global.fetch.mockResolvedValue({ ok: true, json: async () => ({ paid_only: { explorer_publish: { allowed: true } } }) });
    expect(await isPublishBlocked('u1')).toBe(false);
  });
  test('fails open on http error, network error and odd shapes', async () => {
    global.fetch.mockResolvedValue({ ok: false, status: 500, json: async () => ({}) });
    expect(await isPublishBlocked('u1')).toBe(false);
    global.fetch.mockRejectedValue(new Error('down'));
    expect(await isPublishBlocked('u1')).toBe(false);
    global.fetch.mockResolvedValue({ ok: true, json: async () => ({}) });
    expect(await isPublishBlocked('u1')).toBe(false);
    expect(await isPublishBlocked('')).toBe(false);
  });
});

describe('GroupPublishSection', () => {
  test('blocked: shows the upgrade prompt and does not open the website', async () => {
    const open = vi.spyOn(window, 'open').mockImplementation(() => null);
    global.fetch.mockResolvedValue({ ok: true, json: async () => ({ paid_only: { explorer_publish: { allowed: false } } }) });
    render(<GroupPublishSection groupId="g1" userId="u1" />);
    fireEvent.click(screen.getByRole('button', { name: /Publish to Explorer/ }));
    await waitFor(() => expect(getUpgradePrompt()?.info).toMatchObject({ resource: 'explorer_publish' }));
    expect(open).not.toHaveBeenCalled();
    open.mockRestore();
  });
  test('usage fetch failure never blocks: opens the manage page', async () => {
    const open = vi.spyOn(window, 'open').mockImplementation(() => null);
    global.fetch.mockRejectedValue(new Error('down'));
    render(<GroupPublishSection groupId="g1" userId="u1" />);
    fireEvent.click(screen.getByRole('button', { name: /Publish to Explorer/ }));
    await waitFor(() => expect(open).toHaveBeenCalled());
    expect(open.mock.calls[0][0]).toContain('/#/explore/manage?group=g1');
    expect(open.mock.calls[0][2]).toBe('noopener,noreferrer');
    open.mockRestore();
  });
});
