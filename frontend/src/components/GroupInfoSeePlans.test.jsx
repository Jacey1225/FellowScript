// Task 20261003-web-reader-ios-parity step 5: the announcement limit card's
// "See plans" must navigate inside the HashRouter (#/account). The old
// window.location.assign('/account') was a full navigation: Home on the web,
// and blocked by the desktop shell's navigation allowlist.
// Run: npx vitest run src/components/GroupInfoSeePlans.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach, beforeAll } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react';

vi.mock('../lib/announcementsApi.js', async () => {
  const actual = await vi.importActual('../lib/announcementsApi.js');
  return { ...actual, ANNOUNCEMENTS_ENABLED: true, fetchAnnouncements: vi.fn() };
});
vi.mock('../lib/groupInfoApi.js', () => ({
  fetchGroupInfo: vi.fn(), renameGroup: vi.fn(), setGroupMuted: vi.fn(), setGroupMaxMembers: vi.fn(),
  uploadGroupPhoto: vi.fn(), removeGroupPhoto: vi.fn(), confirmGroupPhoto: vi.fn(), fetchGroupGallery: vi.fn(),
  GROUP_PHOTO_LIMITS: { maxBytes: 1, accept: ['image/png'], oversizeCopy: 'x' },
}));
import * as api from '../lib/announcementsApi.js';
import * as infoApi from '../lib/groupInfoApi.js';
import GroupInfoPanel, { _clearGroupInfoCaches } from './GroupInfoPanel.jsx';

beforeAll(() => { if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = () => {}; });
beforeEach(() => {
  _clearGroupInfoCaches();
  window.location.hash = '#/reader';
  infoApi.fetchGroupInfo.mockResolvedValue({ title: 'G', photo_url: null, muted: false });
  infoApi.fetchGroupGallery.mockResolvedValue({ items: [], has_more: false });
  api.fetchAnnouncements.mockResolvedValue({
    announcements: [{ id: 'a', title: 'T', description: 'D', banner_url: null, publish_at: '2026-01-01T00:00:00Z', published: true, can_edit: true, creator_username: 'ann' }],
    gate: { allowed: false, used: 1, limit: 1 }, truncated: false,
  });
});
afterEach(cleanup);

describe('Announcement limit card: See plans', () => {
  test('goes to the in-app Account route via the hash, never a path navigation', async () => {
    render(<GroupInfoPanel open onClose={vi.fn()} contact={{ id: 'g1', name: 'G', type: 'group' }} user={{ user_id: 'u1', username: 'me' }} />);
    fireEvent.click(await screen.findByLabelText('Announcements'));
    await screen.findByText('T');
    fireEvent.click(screen.getByLabelText('New announcement'));
    fireEvent.click(screen.getByText('See plans'));
    await waitFor(() => expect(window.location.hash).toBe('#/account'));
    expect(window.location.pathname).toBe('/');
  });
});
