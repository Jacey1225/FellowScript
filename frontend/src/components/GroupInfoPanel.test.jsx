// Task 20260929-group-info-panel testing: GroupInfoPanel behavior and the
// ChatThread header entry point. API module is mocked.
// Run: cd frontend && npx vitest run src/components/GroupInfoPanel.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach, beforeAll } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor, act } from '@testing-library/react';

vi.mock('../lib/groupInfoApi.js', () => ({
  fetchGroupInfo: vi.fn(), renameGroup: vi.fn(), setGroupMuted: vi.fn(),
  uploadGroupPhoto: vi.fn(), removeGroupPhoto: vi.fn(), confirmGroupPhoto: vi.fn(),
  fetchGroupGallery: vi.fn(),
  GROUP_PHOTO_LIMITS: { maxBytes: 15 * 1024 * 1024, accept: ['image/png'], oversizeCopy: 'x' },
}));
import * as api from '../lib/groupInfoApi.js';
import GroupInfoPanel, { _clearGroupInfoCaches } from './GroupInfoPanel.jsx';
import ChatThread from './ChatThread.jsx';

beforeAll(() => { if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = () => {}; });

const CONTACT = { id: 'g1', name: 'Study Group', type: 'group' };
const USER = { user_id: 'u1', username: 'me' };
const INFO = { title: 'Study Group', photo_url: null, muted: false };
const page = (items, more = false) => ({ items, has_more: more, next_cursor_timestamp: 't', next_cursor_id: 9 });
const img = (id) => ({ id, kind: 'image', url: `https://x/${id}.png`, from_user: 'ann', timestamp: '2026-01-01T00:00:00Z' });

function panel(props = {}) {
  return render(<GroupInfoPanel open onClose={vi.fn()} contact={CONTACT} user={USER}
    groupMembers={[{ user_id: 'u2', username: 'ann' }]} onGroupChanged={vi.fn()} onGroupGone={vi.fn()} {...props} />);
}

beforeEach(() => {
  _clearGroupInfoCaches();
  Object.values(api).forEach(f => f.mockReset?.());
  api.fetchGroupInfo.mockResolvedValue(INFO);
  api.fetchGroupGallery.mockResolvedValue(page([]));
});
afterEach(cleanup);

describe('GroupInfoPanel', () => {
  test('renders nothing for closed or non-group', () => {
    const { container, rerender } = panel({ open: false });
    expect(container).toBeEmptyDOMElement();
    rerender(<GroupInfoPanel open onClose={vi.fn()} contact={{ ...CONTACT, type: 'friend' }} user={USER} />);
    expect(container).toBeEmptyDOMElement();
  });

  test('shows title, members incl. you, and empty gallery copy', async () => {
    panel();
    await screen.findByText(/Nothing shared yet/);
    expect(screen.getByText('Members · 2')).toBeInTheDocument();
    expect(screen.getByText('me (you)')).toBeInTheDocument();
    expect(screen.getByText('ann')).toBeInTheDocument();
  });

  test('rename success calls API with trimmed title and notifies parent', async () => {
    api.renameGroup.mockResolvedValue({ title: 'New Name' });
    const onGroupChanged = vi.fn();
    panel({ onGroupChanged });
    await screen.findByText(/Nothing shared yet/);
    fireEvent.click(screen.getByLabelText('Edit group name'));
    fireEvent.change(screen.getByLabelText('Group name'), { target: { value: '  New Name  ' } });
    fireEvent.click(screen.getByText('Save'));
    await waitFor(() => expect(api.renameGroup).toHaveBeenCalledWith('u1', 'g1', 'New Name'));
    await waitFor(() => expect(onGroupChanged).toHaveBeenCalledWith({ title: 'New Name' }));
    expect(screen.getByText('New Name')).toBeInTheDocument();
  });

  test('blank rename disables Save and never calls API', async () => {
    panel();
    await screen.findByText(/Nothing shared yet/);
    fireEvent.click(screen.getByLabelText('Edit group name'));
    fireEvent.change(screen.getByLabelText('Group name'), { target: { value: '   ' } });
    expect(screen.getByText('Save').closest('button')).toBeDisabled();
    expect(screen.getByText('Give the group a name.')).toBeInTheDocument();
    expect(api.renameGroup).not.toHaveBeenCalled();
  });

  test('rename 422 shows server error and keeps old title (no fabricated success)', async () => {
    api.renameGroup.mockRejectedValue(Object.assign(new Error('Not allowed'), { status: 422 }));
    const onGroupChanged = vi.fn();
    panel({ onGroupChanged });
    await screen.findByText(/Nothing shared yet/);
    fireEvent.click(screen.getByLabelText('Edit group name'));
    fireEvent.change(screen.getByLabelText('Group name'), { target: { value: 'Bad' } });
    fireEvent.click(screen.getByText('Save'));
    expect(await screen.findByText('Not allowed')).toBeInTheDocument();
    expect(onGroupChanged).not.toHaveBeenCalled();
  });

  test('mute toggles to server-confirmed value; failure leaves switch unchanged', async () => {
    api.setGroupMuted.mockResolvedValueOnce({ muted: true });
    panel();
    const sw = await screen.findByRole('switch');
    expect(sw).toHaveAttribute('aria-checked', 'false');
    fireEvent.click(sw);
    await waitFor(() => expect(screen.getByRole('switch')).toHaveAttribute('aria-checked', 'true'));
    expect(api.setGroupMuted).toHaveBeenCalledWith('u1', 'g1', true);

    api.setGroupMuted.mockRejectedValueOnce(Object.assign(new Error('x'), { status: 500 }));
    fireEvent.click(screen.getByRole('switch'));
    expect(await screen.findByText(/Couldn't update notifications/)).toBeInTheDocument();
    expect(screen.getByRole('switch')).toHaveAttribute('aria-checked', 'true');
  });

  test('failed refresh keeps cached info and offers retry', async () => {
    api.fetchGroupInfo.mockResolvedValueOnce({ ...INFO, title: 'Cached Title' });
    const { unmount } = panel();
    await screen.findByText('Cached Title');
    unmount();
    api.fetchGroupInfo.mockRejectedValue(Object.assign(new Error('x'), { status: 0 }));
    panel();
    expect(screen.getByText('Cached Title')).toBeInTheDocument();
    expect(await screen.findByText(/Couldn't refresh just now/)).toBeInTheDocument();
    expect(screen.getByText('Cached Title')).toBeInTheDocument();
  });

  test('403 on refresh calls onGroupGone', async () => {
    api.fetchGroupInfo.mockRejectedValue(Object.assign(new Error('x'), { status: 403 }));
    const onGroupGone = vi.fn();
    panel({ onGroupGone });
    await waitFor(() => expect(onGroupGone).toHaveBeenCalled());
  });

  test('gallery: load more appends via cursor, filter re-queries by kind', async () => {
    api.fetchGroupGallery
      .mockResolvedValueOnce(page([img(1)], true))
      .mockResolvedValueOnce(page([img(2)], false));
    panel();
    const more = await screen.findByLabelText('Load more shared items');
    fireEvent.click(more);
    await waitFor(() => expect(api.fetchGroupGallery).toHaveBeenCalledTimes(2));
    expect(api.fetchGroupGallery.mock.calls[1][2]).toEqual({ kind: null, cursor: { timestamp: 't', id: 9 } });
    await waitFor(() => expect(screen.queryByLabelText('Load more shared items')).toBeNull());
    expect(screen.getAllByLabelText(/^Photo from ann/)).toHaveLength(2);

    api.fetchGroupGallery.mockResolvedValue(page([]));
    fireEvent.click(screen.getByRole('tab', { name: 'GIFs' }));
    await waitFor(() => expect(api.fetchGroupGallery).toHaveBeenLastCalledWith('u1', 'g1', { kind: 'gif' }));
    expect(await screen.findByText('No GIFs yet.')).toBeInTheDocument();
  });

  test('gallery load-more failure keeps existing items and shows retry', async () => {
    api.fetchGroupGallery.mockResolvedValueOnce(page([img(1)], true));
    panel();
    const more = await screen.findByLabelText('Load more shared items');
    api.fetchGroupGallery.mockRejectedValueOnce(Object.assign(new Error('boom'), { status: 500 }));
    fireEvent.click(more);
    expect(await screen.findByText('boom')).toBeInTheDocument();
    expect(screen.getAllByLabelText(/^Photo from ann/)).toHaveLength(1);
  });

  test('remove photo shows undo; undo restores via confirm', async () => {
    api.fetchGroupInfo.mockResolvedValue({ ...INFO, photo_url: 'https://x/p.png' });
    api.removeGroupPhoto.mockResolvedValue({ restore_key: 'group-photos/g1/old' });
    api.confirmGroupPhoto.mockResolvedValue({ photo_url: 'https://x/p.png' });
    const onGroupChanged = vi.fn();
    panel({ onGroupChanged });
    await waitFor(() => expect(screen.getByLabelText('Change group photo')).not.toBeDisabled());
    await screen.findByText(/Nothing shared yet/);
    fireEvent.click(screen.getByLabelText('Change group photo'));
    fireEvent.click(screen.getByText('Remove photo'));
    expect(await screen.findByText('Group photo removed.')).toBeInTheDocument();
    expect(onGroupChanged).toHaveBeenCalledWith({ photoUrl: null });
    fireEvent.click(screen.getByText('Undo'));
    await waitFor(() => expect(api.confirmGroupPhoto).toHaveBeenCalledWith('u1', 'g1', 'group-photos/g1/old'));
    await waitFor(() => expect(screen.queryByText('Group photo removed.')).toBeNull());
  });

  test('Escape closes the panel', async () => {
    const onClose = vi.fn();
    panel({ onClose });
    await screen.findByText(/Nothing shared yet/);
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalled();
  });
});

describe('ChatThread group header entry point', () => {
  const props = (contact) => ({
    contact, messages: [], groupMembers: [], user: USER, onBack: vi.fn(), onSend: vi.fn(),
    onRequestUploadUrl: vi.fn(), onUploadToS3: vi.fn(), onSearchGifs: vi.fn().mockResolvedValue([]),
    sessions: [], activeSessionId: null, talkingUserId: null, onJoinSession: vi.fn(), onLeaveSession: vi.fn(),
    onOpenSessionCreator: vi.fn(), onEditSession: vi.fn(), onDeleteSession: vi.fn(), onNavigateVerse: vi.fn(),
    videoEnabled: false, videoTiles: {}, onToggleVideo: vi.fn(), bindVideoTile: vi.fn(),
  });

  test('clicking group header opens panel; DM header has no group info button', async () => {
    const { unmount } = render(<ChatThread {...props(CONTACT)} />);
    const btn = screen.getByLabelText('Group info, Study Group');
    expect(btn).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(btn);
    expect(await screen.findByRole('dialog', { name: 'Group info' })).toBeInTheDocument();
    expect(btn).toHaveAttribute('aria-expanded', 'true');
    unmount();
    render(<ChatThread {...props({ id: 'f1', name: 'Ada', type: 'friend' })} />);
    expect(screen.queryByLabelText(/Group info,/)).toBeNull();
    expect(api.fetchGroupInfo).toHaveBeenCalledTimes(1);
  });
});
