// Task 20260929-announcement-push-widget testing: widget under the group chat
// header. announcementsApi is mocked (fetchLatestAnnouncement).
// Run: cd frontend && npx vitest run src/components/GroupAnnouncementWidget.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach, beforeAll } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react';

vi.mock('../lib/announcementsApi.js', async () => {
  const actual = await vi.importActual('../lib/announcementsApi.js');
  return { ...actual, ANNOUNCEMENTS_ENABLED: true, fetchLatestAnnouncement: vi.fn() };
});
import * as api from '../lib/announcementsApi.js';
import GroupAnnouncementWidget, { _clearWidgetCache, dismissKey } from './GroupAnnouncementWidget.jsx';
import ChatThread from './ChatThread.jsx';

beforeAll(() => { if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = () => {}; });

const mk = (id, extra = {}) => ({
  id, title: `Title ${id}`, description: `Body ${id}`, banner_url: 'https://cdn.example/b.png',
  publish_at: '2026-01-01T00:00:00Z', published: true, can_edit: true, creator_username: 'ann', ...extra,
});
const mount = (props = {}) => render(<GroupAnnouncementWidget userId="u1" groupId="g1" {...props} />);

// This vitest environment exposes no usable window.localStorage; install a Map-backed one.
function installStorage() {
  const m = new Map();
  Object.defineProperty(window, 'localStorage', {
    configurable: true,
    value: { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)),
             removeItem: k => m.delete(k), clear: () => m.clear() },
  });
}

beforeEach(() => {
  _clearWidgetCache();
  installStorage();
  api.fetchLatestAnnouncement.mockReset();
});
afterEach(() => { cleanup(); vi.useRealTimers(); });

describe('GroupAnnouncementWidget', () => {
  test('renders title, banner image, and View affordance with accessible labels', async () => {
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('a') });
    const { container } = mount();
    const card = await screen.findByRole('button', { name: /Announcement: Title a/ });
    expect(screen.getByRole('region', { name: 'Latest announcement' })).toBeTruthy();
    expect(card.textContent).toContain('Title a');
    expect(card.textContent).toContain('View');
    expect(container.querySelector('img.announce-widget-img').getAttribute('src')).toBe('https://cdn.example/b.png');
    expect(api.fetchLatestAnnouncement).toHaveBeenCalledWith('u1', 'g1');
  });

  test('no announcement -> renders nothing', async () => {
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: null });
    const { container } = mount();
    await waitFor(() => expect(api.fetchLatestAnnouncement).toHaveBeenCalled());
    expect(container.querySelector('.announce-widget')).toBeNull();
  });

  test('missing banner -> gradient fallback class, no image', async () => {
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('a', { banner_url: null }) });
    const { container } = mount();
    await screen.findByText('Title a');
    expect(container.querySelector('.announce-widget-fallback')).toBeTruthy();
    expect(container.querySelector('img.announce-widget-img')).toBeNull();
  });

  test('banner load error falls back to the gradient', async () => {
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('a') });
    const { container } = mount();
    await screen.findByText('Title a');
    fireEvent.error(container.querySelector('img.announce-widget-img'));
    await waitFor(() => expect(container.querySelector('.announce-widget-fallback')).toBeTruthy());
    expect(container.querySelector('img.announce-widget-img')).toBeNull();
  });

  test('tap opens the read-only viewer dialog', async () => {
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('a', { can_edit: true }) });
    mount();
    fireEvent.click(await screen.findByRole('button', { name: /Announcement: Title a/ }));
    const dialog = await screen.findByRole('dialog', { name: 'Announcement' });
    expect(dialog.textContent).toContain('Body a');
    expect(screen.queryByText(/^Edit$/)).toBeNull();
    expect(screen.queryByText(/^Delete$/)).toBeNull();
  });

  test('dismiss hides it, persists per device keyed by id, and a newer id reappears', async () => {
    window.matchMedia = window.matchMedia || (() => ({ matches: true }));
    const mm = vi.spyOn(window, 'matchMedia').mockImplementation(() => ({ matches: true, addListener() {}, removeListener() {} }));
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('a') });
    const onAfterDismiss = vi.fn();
    const first = mount({ onAfterDismiss });
    fireEvent.click(await screen.findByRole('button', { name: 'Dismiss announcement' }));
    await waitFor(() => expect(first.container.querySelector('.announce-widget')).toBeNull());
    expect(window.localStorage.getItem(dismissKey('u1', 'g1'))).toBe('a');
    expect(onAfterDismiss).toHaveBeenCalled();
    cleanup();

    // remount with the same id stays dismissed
    _clearWidgetCache();
    const again = mount();
    await waitFor(() => expect(api.fetchLatestAnnouncement).toHaveBeenCalledTimes(2));
    expect(again.container.querySelector('.announce-widget')).toBeNull();
    cleanup();

    // a newer announcement id reappears
    _clearWidgetCache();
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('b') });
    mount();
    await screen.findByText('Title b');
    mm.mockRestore();
  });

  test('failed refresh preserves the previously shown widget (no error UI)', async () => {
    api.fetchLatestAnnouncement.mockResolvedValueOnce({ announcement: mk('a') });
    mount();
    await screen.findByText('Title a');
    api.fetchLatestAnnouncement.mockRejectedValue(new Error('offline'));
    fireEvent(window, new Event('focus'));
    await waitFor(() => expect(api.fetchLatestAnnouncement).toHaveBeenCalledTimes(2));
    await new Promise(r => setTimeout(r, 20));
    expect(screen.getByText('Title a')).toBeTruthy();
    expect(screen.queryByText(/couldn't|error/i)).toBeNull();
  });

  test('cached last-good shown on remount while a failing fetch never blanks it', async () => {
    api.fetchLatestAnnouncement.mockResolvedValueOnce({ announcement: mk('a') });
    mount();
    await screen.findByText('Title a');
    cleanup();
    api.fetchLatestAnnouncement.mockRejectedValue(new Error('offline'));
    mount();
    expect(screen.getByText('Title a')).toBeTruthy();
    await waitFor(() => expect(api.fetchLatestAnnouncement).toHaveBeenCalledTimes(2));
    expect(screen.getByText('Title a')).toBeTruthy();
  });

  test('never-loaded + failing fetch renders nothing', async () => {
    api.fetchLatestAnnouncement.mockRejectedValue(new Error('offline'));
    const { container } = mount();
    await waitFor(() => expect(api.fetchLatestAnnouncement).toHaveBeenCalled());
    await new Promise(r => setTimeout(r, 10));
    expect(container.querySelector('.announce-widget')).toBeNull();
  });

  test('unpublished item is not rendered', async () => {
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('a', { published: false }) });
    const { container } = mount();
    await waitFor(() => expect(api.fetchLatestAnnouncement).toHaveBeenCalled());
    await new Promise(r => setTimeout(r, 10));
    expect(container.querySelector('.announce-widget')).toBeNull();
  });
});

describe('ChatThread integration: groups only', () => {
  const props = (contact) => ({
    contact, messages: [], groupMembers: [], user: { user_id: 'u1', username: 'me' }, onBack: vi.fn(), onSend: vi.fn(),
    sessions: [], activeSessionId: null, talkingUserId: null, onJoinSession: vi.fn(), onLeaveSession: vi.fn(),
    onOpenSessionCreator: vi.fn(), onEditSession: vi.fn(), onDeleteSession: vi.fn(), onNavigateVerse: vi.fn(),
    videoEnabled: false, videoTiles: {}, onToggleVideo: vi.fn(), bindVideoTile: vi.fn(),
  });

  test('group chat shows the widget directly after the header, before the transcript', async () => {
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('g') });
    const { container } = render(<ChatThread {...props({ id: 'g1', name: 'Study', type: 'group' })} />);
    const widget = await screen.findByRole('region', { name: 'Latest announcement' });
    expect(api.fetchLatestAnnouncement).toHaveBeenCalledWith('u1', 'g1');
    const header = screen.getByText('Study');
    // widget follows the header in document order
    expect(header.compareDocumentPosition(widget) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(container.contains(widget)).toBe(true);
  });

  test('DM (friend) chat never fetches or shows the widget', async () => {
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('g') });
    render(<ChatThread {...props({ id: 'c1', name: 'Ada', type: 'friend' })} />);
    await new Promise(r => setTimeout(r, 20));
    expect(api.fetchLatestAnnouncement).not.toHaveBeenCalled();
    expect(screen.queryByRole('region', { name: 'Latest announcement' })).toBeNull();
  });
});
