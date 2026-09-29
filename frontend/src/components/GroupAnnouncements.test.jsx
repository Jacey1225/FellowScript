// Task 20260929-group-announcements testing: list/viewer/form behavior and the
// GroupInfoPanel entry row. announcementsApi + groupInfoApi are mocked.
// Run: cd frontend && npx vitest run src/components/GroupAnnouncements.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach, beforeAll } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor, act } from '@testing-library/react';

vi.mock('../lib/announcementsApi.js', async () => {
  const actual = await vi.importActual('../lib/announcementsApi.js');
  return {
    ...actual,
    ANNOUNCEMENTS_ENABLED: true,
    fetchAnnouncements: vi.fn(), createAnnouncement: vi.fn(), updateAnnouncement: vi.fn(),
    deleteAnnouncement: vi.fn(), uploadAnnouncementBanner: vi.fn(),
  };
});
vi.mock('../lib/groupInfoApi.js', () => ({
  fetchGroupInfo: vi.fn(), renameGroup: vi.fn(), setGroupMuted: vi.fn(),
  uploadGroupPhoto: vi.fn(), removeGroupPhoto: vi.fn(), confirmGroupPhoto: vi.fn(),
  fetchGroupGallery: vi.fn(),
  GROUP_PHOTO_LIMITS: { maxBytes: 15 * 1024 * 1024, accept: ['image/png'], oversizeCopy: 'x' },
}));
import * as api from '../lib/announcementsApi.js';
import * as infoApi from '../lib/groupInfoApi.js';
import GroupAnnouncements, { _clearAnnouncementCaches } from './GroupAnnouncements.jsx';
import GroupAnnouncementViewer from './GroupAnnouncementViewer.jsx';
import GroupInfoPanel, { _clearGroupInfoCaches } from './GroupInfoPanel.jsx';

beforeAll(() => { if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = () => {}; });

const mk = (id, extra = {}) => ({
  id, title: `Title ${id}`, description: `Body ${id}`, banner_url: null, publish_at: '2026-01-01T00:00:00Z',
  published: true, can_edit: true, creator_username: 'ann', ...extra,
});
const list = (announcements, gate = null, extra = {}) => ({ announcements, gate, truncated: false, ...extra });

function mount(props = {}) {
  return render(<GroupAnnouncements userId="u1" groupId="g1" onBack={vi.fn()} onGroupGone={vi.fn()} onUpgrade={vi.fn()} {...props} />);
}

beforeEach(() => {
  _clearAnnouncementCaches(); _clearGroupInfoCaches();
  Object.values(api).forEach(f => f.mockReset?.());
  Object.values(infoApi).forEach(f => f.mockReset?.());
  infoApi.fetchGroupInfo.mockResolvedValue({ title: 'Study Group', photo_url: null, muted: false });
  infoApi.fetchGroupGallery.mockResolvedValue({ items: [], has_more: false });
});
afterEach(() => { cleanup(); vi.useRealTimers(); });

describe('GroupAnnouncements list', () => {
  test('empty state is minimal', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([]));
    mount();
    await screen.findByText('No announcements yet.');
  });

  test('renders scheduled section separately from published', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([mk('a'), mk('b', { published: false, publish_at: '2030-01-01T00:00:00Z' })]));
    mount();
    await screen.findByText('Title a');
    expect(screen.getByText('Scheduled')).toBeInTheDocument();
    expect(screen.getByText('Title b')).toBeInTheDocument();
  });

  test('failed first load shows error + Retry, never an empty state', async () => {
    api.fetchAnnouncements.mockRejectedValue(Object.assign(new Error('x'), { status: 500 }));
    mount();
    await screen.findByText(/Couldn't load announcements\./);
    expect(screen.queryByText('No announcements yet.')).not.toBeInTheDocument();
    api.fetchAnnouncements.mockResolvedValue(list([mk('a')]));
    fireEvent.click(screen.getByText('Retry'));
    await screen.findByText('Title a');
  });

  test('failed refresh preserves the cached list and shows a banner', async () => {
    api.fetchAnnouncements.mockResolvedValueOnce(list([mk('a')]));
    const first = mount();
    await screen.findByText('Title a');
    first.unmount();
    api.fetchAnnouncements.mockRejectedValue(Object.assign(new Error('x'), { status: 0 }));
    mount();
    expect(screen.getByText('Title a')).toBeInTheDocument(); // cache-first
    await screen.findByText(/Showing your last loaded list/);
    expect(screen.getByText('Title a')).toBeInTheDocument();
    expect(screen.queryByText('No announcements yet.')).not.toBeInTheDocument();
  });

  test('plain 403 on load means removed from group', async () => {
    api.fetchAnnouncements.mockRejectedValue(Object.assign(new Error('no'), { status: 403 }));
    const onGroupGone = vi.fn();
    mount({ onGroupGone });
    await waitFor(() => expect(onGroupGone).toHaveBeenCalled());
  });

  test('rows without can_edit have no kebab actions', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([mk('a', { can_edit: false })]));
    mount();
    await screen.findByText('Title a');
    expect(screen.queryByLabelText('More actions for Title a')).not.toBeInTheDocument();
  });

  test('when gate says not allowed, New shows upgrade card and never opens the form', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([mk('a')], { allowed: false, used: 1, limit: 1 }));
    const onUpgrade = vi.fn();
    mount({ onUpgrade });
    await screen.findByText('Title a');
    fireEvent.click(screen.getByLabelText('New announcement'));
    expect(screen.getByRole('region', { name: 'Announcement limit reached' })).toBeInTheDocument();
    expect(screen.queryByText('New announcement', { selector: 'h3' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByText('See plans'));
    expect(onUpgrade).toHaveBeenCalled();
  });

  test('tap opens viewer; Edit shown for can_edit; Back returns', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([mk('a')]));
    mount();
    fireEvent.click(await screen.findByText('Title a'));
    expect(screen.getByRole('heading', { name: 'Title a' })).toBeInTheDocument();
    expect(screen.getByText('Edit')).toBeInTheDocument();
    fireEvent.click(screen.getByLabelText('Back to announcements'));
    await screen.findByText('Announcements');
  });
});

describe('delete with undo grace', () => {
  test('delete hides row, does not call API until grace ends, Undo restores', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([mk('a')]));
    mount();
    await screen.findByText('Title a');
    vi.useFakeTimers({ shouldAdvanceTime: true });
    fireEvent.click(screen.getByLabelText('More actions for Title a'));
    fireEvent.click(screen.getByText('Delete'));
    expect(screen.queryByText('Title a')).not.toBeInTheDocument();
    expect(api.deleteAnnouncement).not.toHaveBeenCalled();
    fireEvent.click(screen.getByText('Undo'));
    expect(screen.getByText('Title a')).toBeInTheDocument();
    await act(async () => { vi.advanceTimersByTime(9000); });
    expect(api.deleteAnnouncement).not.toHaveBeenCalled();
  });

  test('delete commits to server after the grace window', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([mk('a')]));
    api.deleteAnnouncement.mockResolvedValue({});
    mount();
    await screen.findByText('Title a');
    vi.useFakeTimers({ shouldAdvanceTime: true });
    fireEvent.click(screen.getByLabelText('More actions for Title a'));
    fireEvent.click(screen.getByText('Delete'));
    await act(async () => { vi.advanceTimersByTime(8100); });
    expect(api.deleteAnnouncement).toHaveBeenCalledWith('u1', 'g1', 'a');
    expect(screen.queryByText('Title a')).not.toBeInTheDocument();
  });

  test('failed delete restores the row and reports the error (no fabricated success)', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([mk('a')]));
    api.deleteAnnouncement.mockRejectedValue(Object.assign(new Error('x'), { status: 500 }));
    mount();
    await screen.findByText('Title a');
    vi.useFakeTimers({ shouldAdvanceTime: true });
    fireEvent.click(screen.getByLabelText('More actions for Title a'));
    fireEvent.click(screen.getByText('Delete'));
    await act(async () => { vi.advanceTimersByTime(8100); });
    expect(screen.getByText('Title a')).toBeInTheDocument();
    expect(screen.getByRole('alert')).toHaveTextContent(/couldn't be deleted/);
  });

  test('closing the sub-view flushes a pending delete', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([mk('a')]));
    api.deleteAnnouncement.mockResolvedValue({});
    const { unmount } = mount();
    await screen.findByText('Title a');
    fireEvent.click(screen.getByLabelText('More actions for Title a'));
    fireEvent.click(screen.getByText('Delete'));
    unmount();
    expect(api.deleteAnnouncement).toHaveBeenCalledWith('u1', 'g1', 'a');
  });
});

describe('create / edit form', () => {
  const openForm = async () => {
    fireEvent.click(await screen.findByLabelText('New announcement'));
    await screen.findByText('New announcement', { selector: 'h3' });
  };

  test('Post disabled until title and message present', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([]));
    mount();
    await screen.findByText('No announcements yet.');
    await openForm();
    expect(screen.getByText('Post').closest('button')).toBeDisabled();
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Hi' } });
    expect(screen.getByText('Post').closest('button')).toBeDisabled();
    fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'There' } });
    expect(screen.getByText('Post').closest('button')).not.toBeDisabled();
  });

  test('post now sends trimmed body with publish_at null and no banner_key', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([]));
    const created = mk('n', { title: 'Hi', description: 'There' });
    api.createAnnouncement.mockImplementation(async () => { api.fetchAnnouncements.mockResolvedValue(list([created])); return created; });
    mount();
    await screen.findByText('No announcements yet.');
    await openForm();
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: '  Hi  ' } });
    fireEvent.change(screen.getByLabelText('Message'), { target: { value: ' There ' } });
    fireEvent.click(screen.getByText('Post'));
    await waitFor(() => expect(api.createAnnouncement).toHaveBeenCalled());
    const body = api.createAnnouncement.mock.calls[0][2];
    expect(body).toEqual({ title: 'Hi', description: 'There', publish_at: null });
    await screen.findByRole('heading', { name: 'Hi' });
  });

  test('schedule mode requires a time and sends an ISO publish_at', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([]));
    api.createAnnouncement.mockResolvedValue(mk('n', { published: false }));
    mount();
    await screen.findByText('No announcements yet.');
    await openForm();
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Hi' } });
    fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'There' } });
    fireEvent.click(screen.getByRole('radio', { name: 'Schedule' }));
    expect(screen.getByText('Schedule', { selector: 'button.group-info-pill' }).closest('button')).toBeDisabled();
    const future = new Date(Date.now() + 2 * 86400000);
    const pad = (n) => String(n).padStart(2, '0');
    const local = `${future.getFullYear()}-${pad(future.getMonth() + 1)}-${pad(future.getDate())}T10:30`;
    fireEvent.change(screen.getByLabelText('Publish date and time'), { target: { value: local } });
    fireEvent.click(screen.getByText('Schedule', { selector: 'button.group-info-pill' }));
    await waitFor(() => expect(api.createAnnouncement).toHaveBeenCalled());
    expect(api.createAnnouncement.mock.calls[0][2].publish_at).toBe(new Date(local).toISOString());
  });

  test('banner is uploaded then its key sent as banner_key', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([]));
    api.uploadAnnouncementBanner.mockResolvedValue('group-announcements/g1/k');
    api.createAnnouncement.mockResolvedValue(mk('n'));
    mount();
    await screen.findByText('No announcements yet.');
    await openForm();
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Hi' } });
    fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'There' } });
    const file = new File(['x'], 'a.png', { type: 'image/png' });
    fireEvent.change(screen.getByTestId('announcement-banner-input'), { target: { files: [file] } });
    await waitFor(() => expect(api.uploadAnnouncementBanner).toHaveBeenCalledWith('u1', 'g1', file));
    await screen.findByText('Replace');
    fireEvent.click(screen.getByText('Post'));
    await waitFor(() => expect(api.createAnnouncement).toHaveBeenCalled());
    expect(api.createAnnouncement.mock.calls[0][2].banner_key).toBe('group-announcements/g1/k');
  });

  test('free-limit 403 on create shows the upgrade card, keeps the form and writes nothing to the list', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([]));
    const gate = { resource: 'announcements', allowed: false, used: 1, limit: 1 };
    api.createAnnouncement.mockRejectedValue(Object.assign(new Error('x'), { status: 403, gate }));
    mount();
    await screen.findByText('No announcements yet.');
    await openForm();
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Hi' } });
    fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'There' } });
    fireEvent.click(screen.getByText('Post'));
    await screen.findByRole('region', { name: 'Announcement limit reached' });
    expect(screen.getByLabelText('Title')).toHaveValue('Hi');
  });

  test('422 shows the server message inline and stays on the form', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([]));
    api.createAnnouncement.mockRejectedValue(Object.assign(new Error('Contains blocked words'), { status: 422 }));
    mount();
    await screen.findByText('No announcements yet.');
    await openForm();
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Hi' } });
    fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'There' } });
    fireEvent.click(screen.getByText('Post'));
    await screen.findByText('Contains blocked words');
    expect(screen.getByLabelText('Title')).toBeInTheDocument();
  });

  test('cancel on a dirty form asks before discarding; clean cancel leaves at once', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([]));
    mount();
    await screen.findByText('No announcements yet.');
    await openForm();
    fireEvent.click(screen.getByText('Cancel'));
    await screen.findByText('No announcements yet.');
    await openForm();
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'x' } });
    fireEvent.click(screen.getByText('Cancel'));
    expect(screen.getByRole('alertdialog')).toBeInTheDocument();
    fireEvent.click(screen.getByText('Discard'));
    await screen.findByText('No announcements yet.');
  });

  test('editing a published announcement hides the schedule control and uses PUT', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([mk('a')]));
    api.updateAnnouncement.mockResolvedValue(mk('a', { title: 'Changed' }));
    mount();
    await screen.findByText('Title a');
    fireEvent.click(screen.getByLabelText('More actions for Title a'));
    fireEvent.click(screen.getByText('Edit'));
    await screen.findByText('Edit announcement');
    expect(screen.queryByRole('radiogroup')).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Changed' } });
    fireEvent.click(screen.getByText('Save'));
    await waitFor(() => expect(api.updateAnnouncement).toHaveBeenCalledWith('u1', 'g1', 'a', { title: 'Changed', description: 'Body a' }));
  });
});

describe('GroupAnnouncementViewer', () => {
  const base = { item: mk('a'), onBack: vi.fn(), onEdit: vi.fn(), onDelete: vi.fn() };

  test('hides Edit and Delete when not can_edit', () => {
    render(<GroupAnnouncementViewer {...base} item={mk('a', { can_edit: false })} />);
    expect(screen.queryByText('Edit')).not.toBeInTheDocument();
    expect(screen.queryByText('Delete')).not.toBeInTheDocument();
  });

  test('Edit and Delete call back with the item; Escape goes back', () => {
    const onEdit = vi.fn(); const onDelete = vi.fn(); const onBack = vi.fn();
    render(<GroupAnnouncementViewer {...base} onEdit={onEdit} onDelete={onDelete} onBack={onBack} />);
    fireEvent.click(screen.getByText('Edit'));
    fireEvent.click(screen.getByText('Delete'));
    expect(onEdit).toHaveBeenCalledWith(base.item);
    expect(onDelete).toHaveBeenCalledWith(base.item);
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onBack).toHaveBeenCalled();
  });

  test('scheduled chip shown for unpublished; banner opens lightbox', () => {
    const onOpenLightbox = vi.fn();
    render(<GroupAnnouncementViewer {...base} onOpenLightbox={onOpenLightbox}
      item={mk('a', { published: false, banner_url: 'https://x/b.png' })} />);
    expect(screen.getByText(/^Scheduled for/)).toBeInTheDocument();
    fireEvent.click(screen.getByLabelText(/Banner for Title a/));
    expect(onOpenLightbox).toHaveBeenCalledWith('image', 'https://x/b.png', expect.anything());
  });
});

describe('GroupInfoPanel Announcements entry row', () => {
  const CONTACT = { id: 'g1', name: 'Study Group', type: 'group' };
  const USER = { user_id: 'u1', username: 'me' };
  const panel = () => render(<GroupInfoPanel open onClose={vi.fn()} contact={CONTACT} user={USER}
    groupMembers={[]} onGroupChanged={vi.fn()} onGroupGone={vi.fn()} />);

  test('row opens the sub-view and Back returns to group info', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([]));
    panel();
    fireEvent.click(await screen.findByLabelText('Announcements'));
    await screen.findByText('No announcements yet.');
    expect(api.fetchAnnouncements).toHaveBeenCalledWith('u1', 'g1');
    fireEvent.click(screen.getByLabelText('Back to group info'));
    await waitFor(() => expect(screen.queryByText('No announcements yet.')).not.toBeInTheDocument());
    expect(screen.getByLabelText('Announcements')).toBeInTheDocument();
  });

  test('Announcements is not fetched until the row is opened', async () => {
    panel();
    await screen.findByLabelText('Announcements');
    expect(api.fetchAnnouncements).not.toHaveBeenCalled();
  });
});
