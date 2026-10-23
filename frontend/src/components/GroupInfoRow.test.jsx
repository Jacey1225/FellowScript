// Task 20261023-group-info-row: chip row + bottom submenu in ChatThread.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, within, waitFor } from '@testing-library/react';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';
import { MessagingPanelContext } from '../context/ReaderPanelContexts.jsx';

vi.mock('./GroupInfoPanel.jsx', () => ({ default: () => null }));
vi.mock('../lib/announcementsApi.js', async (orig) => ({
  ...(await orig()),
  fetchAnnouncements: vi.fn(),
  fetchLatestAnnouncement: vi.fn(async () => ({ announcement: { id: 'a1', title: 'Banner title', published: true } })),
}));
vi.mock('../lib/threadsApi.js', async (orig) => ({ ...(await orig()), listThreads: vi.fn() }));
vi.mock('../lib/groupMediaApi.js', async (orig) => ({ ...(await orig()), fetchGroupMedia: vi.fn() }));

import ChatThread from './ChatThread.jsx';
import { _clearGroupInfoListCaches } from './GroupInfoLists.jsx';
import { visibleChips } from './GroupInfoRow.jsx';
import { fetchAnnouncements, fetchLatestAnnouncement } from '../lib/announcementsApi.js';
import { listThreads } from '../lib/threadsApi.js';
import { fetchGroupMedia } from '../lib/groupMediaApi.js';

const GROUP = { id: 'g1', name: 'InterVars', type: 'group', group_id: 'g1' };
const DM = { id: 'f1', name: 'Bob', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };
const ALL = { threads: true, message_pins: true, group_media: true };
const pin = (id) => ({
  messageId: id, pinnedBy: 'bob', pinnedById: 'u2', pinnedAt: null,
  message: { id, fromUserId: 'u9', from: 'ada', text: `text-${id}`, timestamp: '2026-10-01T10:00:00Z', attachmentKind: null },
});
const READY = (pins = []) => ({ pins, count: pins.length, hasMore: false, status: 'ready', moreLoading: false });
const ann = (id, title, at) => ({ id, title, publish_at: at, published: true });
const thread = (id, title, n = 2) => ({ id, title, reply_count: n, last_activity_at: '2026-10-20T10:00:00Z' });
const media = (id, kind = 'image', extra = {}) => ({
  messageId: id, kind, thumbUrl: kind === 'video' ? null : `https://img/${id}.jpg`, url: `https://img/${id}.jpg`,
  width: 10, height: 10, duration: kind === 'video' ? 65 : null, senderId: 'u2', senderName: 'ada', createdAt: '2026-10-19T19:55:00Z', ...extra,
});

beforeEach(() => {
  _clearGroupInfoListCaches();
  Element.prototype.scrollIntoView = vi.fn();
  window.matchMedia = vi.fn(() => ({ matches: true, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
  fetchAnnouncements.mockReset(); fetchAnnouncements.mockResolvedValue({ announcements: [] });
  fetchLatestAnnouncement.mockClear();
  listThreads.mockReset(); listThreads.mockResolvedValue({ threads: [], hasMore: false, cursor: null });
  fetchGroupMedia.mockReset(); fetchGroupMedia.mockResolvedValue({ items: [], hasMore: false, cursor: null });
});
afterEach(() => { cleanup(); });

function mount({ features = ALL, contact = GROUP, pins, thread: th, panelCtx = null, ...props } = {}) {
  const pinsProp = pins === undefined ? {
    enabled: true, list: READY([pin('m1'), pin('m2')]), onLoad: vi.fn(), onLoadMore: vi.fn(), onToggle: vi.fn(), onUnpin: vi.fn(), ensureLoaded: vi.fn(async () => true),
  } : pins;
  const tree = (
    <CapabilitiesContext.Provider value={{ features, isEnabled: (n) => features[n] === true, refresh: vi.fn(), reactionEmoji: { quick: [], more: [] } }}>
      <ChatThread contact={contact} messages={[{ id: 'm1', key: 'm1', text: 'hello', mine: false, sender: 'ada', timestamp: '2026-10-01T10:00:00Z' }]}
        groupMembers={[]} user={USER} thread={th}
        sessions={[]} activeSessionId={null} talkingUserId={null} onSend={vi.fn()} onBack={vi.fn()}
        onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()}
        onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()}
        videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()}
        pins={pinsProp} {...props} />
    </CapabilitiesContext.Provider>
  );
  render(panelCtx ? <MessagingPanelContext.Provider value={panelCtx}>{tree}</MessagingPanelContext.Provider> : tree);
  return pinsProp;
}
const chip = (name) => screen.getByRole('button', { name });
const closed = () => expect(screen.queryByRole('dialog')).toBeNull();

describe('gating', () => {
  test('visibleChips is ordered and flag-gated per item', () => {
    expect(visibleChips({ features: ALL, pinsOn: true })).toEqual(['announcements', 'threads', 'pinned', 'media']);
    expect(visibleChips({ features: {}, pinsOn: false })).toEqual(['announcements']);
    expect(visibleChips({ features: { threads: true }, pinsOn: true })).toEqual(['announcements', 'threads', 'pinned']);
    expect(visibleChips({ features: { group_media: true }, pinsOn: false })).toEqual(['announcements', 'media']);
    expect(visibleChips({ features: ALL, pinsOn: true, hasUser: false })).toEqual(['pinned']);
  });
  test('group chat shows four chips in order then Sessions, Pinned carries its count', () => {
    mount();
    const row = screen.getByRole('group', { name: 'Group sections' });
    expect(within(row).getAllByRole('button').map((b) => b.textContent)).toEqual(['Announcements', 'Threads', 'Pinned2', 'Media', 'Sessions']);
    expect(chip('Pinned, 2')).toBeInTheDocument();
    expect(chip('Media')).toHaveAttribute('aria-controls', 'group-info-panel');
  });
  test('Media chip hidden while group_media is off; Threads while threads is off', () => {
    mount({ features: { message_pins: true } });
    expect(screen.queryByRole('button', { name: 'Media' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Threads' })).toBeNull();
    expect(chip('Announcements')).toBeInTheDocument();
  });
  test('absent in a DM and inside a thread view', () => {
    mount({ contact: DM });
    expect(screen.queryByRole('group', { name: 'Group sections' })).toBeNull();
    cleanup();
    mount({ thread: { id: 't1', title: 'T' } });
    expect(screen.queryByRole('group', { name: 'Group sections' })).toBeNull();
  });
  test('no list request is made until a chip is opened', () => {
    mount();
    expect(fetchAnnouncements).not.toHaveBeenCalled();
    expect(listThreads).not.toHaveBeenCalled();
    expect(fetchGroupMedia).not.toHaveBeenCalled();
  });
});

describe('banner and floating pin button removal', () => {
  test('group chat: no announcement banner (no latest fetch) and no floating pin button', () => {
    mount();
    expect(fetchLatestAnnouncement).not.toHaveBeenCalled();
    expect(document.querySelector('.announce-widget')).toBeNull();
    expect(document.querySelector('.pins-btn-row')).toBeNull();
    expect(screen.queryByRole('button', { name: /^Pinned messages/ })).toBeNull();
  });
  test('DM keeps the floating pin button and its anchored popover', () => {
    mount({ contact: DM });
    const btn = screen.getByRole('button', { name: 'Pinned messages, 2' });
    expect(document.querySelector('.pins-btn-row')).not.toBeNull();
    fireEvent.click(btn);
    expect(screen.getByRole('dialog', { name: 'Pinned messages' })).toBeInTheDocument();
  });
});

describe('submenu', () => {
  test('opens from a chip: selected state, dialog label, one at a time, swap in place', async () => {
    mount();
    const a = chip('Announcements');
    expect(a).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(a);
    expect(a).toHaveAttribute('aria-expanded', 'true');
    expect(a.className).toContain('group-info-chip-selected');
    expect(screen.getByRole('dialog', { name: 'Announcements' })).toHaveAttribute('id', 'group-info-panel');
    fireEvent.click(chip('Threads'));
    expect(screen.getAllByRole('dialog')).toHaveLength(1);
    expect(screen.getByRole('dialog', { name: 'Threads' })).toBeInTheDocument();
    expect(a).toHaveAttribute('aria-expanded', 'false');
    await waitFor(() => expect(listThreads).toHaveBeenCalled());
  });
  test('closes: active chip again, close button, scrim, Escape (focus returns to the chip)', () => {
    mount();
    const a = chip('Announcements');
    fireEvent.click(a); fireEvent.click(a); closed();
    fireEvent.click(a); fireEvent.click(screen.getByRole('button', { name: 'Close Announcements' })); closed();
    fireEvent.click(a); fireEvent.click(screen.getByTestId('group-info-scrim')); closed();
    fireEvent.click(a);
    fireEvent.keyDown(document, { key: 'Escape' });
    closed();
    expect(document.activeElement).toBe(a);
  });
  test('focusing the composer closes the panel; opening Sessions closes it too', () => {
    mount();
    fireEvent.click(chip('Media'));
    fireEvent.focus(screen.getByPlaceholderText('Message…'));
    closed();
    fireEvent.click(chip('Media'));
    fireEvent.click(screen.getByRole('button', { name: /^Sessions/ }));
    expect(screen.queryByRole('dialog', { name: 'Media' })).toBeNull();
  });
  test('a flag dropping mid-session closes the open panel', () => {
    const tree = (f) => (
      <CapabilitiesContext.Provider value={{ features: f, isEnabled: (n) => f[n] === true, refresh: vi.fn(), reactionEmoji: { quick: [], more: [] } }}>
        <ChatThread contact={GROUP} messages={[]} groupMembers={[]} user={USER} sessions={[]} onSend={vi.fn()} onBack={vi.fn()} pins={null}
          onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()} onEditSession={vi.fn()}
          onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()} videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()} />
      </CapabilitiesContext.Provider>
    );
    const { rerender } = render(tree({ group_media: true }));
    fireEvent.click(chip('Media'));
    expect(screen.getByRole('dialog')).toBeInTheDocument();
    rerender(tree({}));
    closed();
    expect(screen.queryByRole('button', { name: 'Media' })).toBeNull();
  });
});

describe('Announcements list', () => {
  test('newest first, card lines, opens the existing viewer and Back returns to the list', async () => {
    fetchAnnouncements.mockResolvedValue({ announcements: [
      ann('a1', 'Older one', '2026-10-01T10:00:00Z'), ann('a2', 'Newest one', '2026-10-19T19:55:00Z'),
      { ...ann('a3', 'Draft', '2026-10-25T10:00:00Z'), published: false },
    ] });
    mount();
    fireEvent.click(chip('Announcements'));
    const cards = await screen.findAllByRole('button', { name: /^Announcement:/ });
    expect(cards.map((c) => c.querySelector('.group-info-ann-title').textContent)).toEqual(['Newest one', 'Older one']);
    expect(within(cards[0]).getByText('InterVars')).toBeInTheDocument();
    expect(within(cards[0]).getByText(/Oct 19, 2026 at /)).toBeInTheDocument();
    fireEvent.click(cards[0]);
    const viewer = screen.getByRole('dialog', { name: 'Announcement' });
    fireEvent.click(within(viewer).getByRole('button', { name: 'Back to announcements' }));
    expect(screen.queryByRole('dialog', { name: 'Announcement' })).toBeNull();
    expect(screen.getByRole('dialog', { name: 'Announcements' })).toBeInTheDocument();
  });
  test('empty, error then retry, and a failed refresh keeps the cached list', async () => {
    mount();
    fireEvent.click(chip('Announcements'));
    expect(await screen.findByText('No announcements yet.')).toBeInTheDocument();
    cleanup(); _clearGroupInfoListCaches();
    fetchAnnouncements.mockRejectedValueOnce(new Error('boom 500'));
    mount();
    fireEvent.click(chip('Announcements'));
    expect(await screen.findByText("We couldn't load announcements just now.")).toBeInTheDocument();
    expect(screen.queryByText(/boom|500/)).toBeNull();
    fetchAnnouncements.mockResolvedValueOnce({ announcements: [ann('a1', 'Kept', '2026-10-01T10:00:00Z')] });
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByText('Kept')).toBeInTheDocument();
    // Reopen: cached list paints, the refresh fails, the list stays with a note.
    fetchAnnouncements.mockRejectedValue(new Error('offline'));
    fireEvent.click(chip('Announcements')); // close
    fireEvent.click(chip('Announcements')); // reopen
    expect(screen.getByText('Kept')).toBeInTheDocument();
    expect(await screen.findByText(/Couldn.t refresh\. Showing what we had\./)).toBeInTheDocument();
    expect(screen.getByText('Kept')).toBeInTheDocument();
  });
});

describe('Threads list', () => {
  test('rows show replies and relative time; tapping closes the panel and opens the thread', async () => {
    listThreads.mockResolvedValue({ threads: [thread('t1', 'Lunch plans', 1), thread('t2', 'Study notes', 5)], hasMore: false, cursor: null });
    const onOpenThread = vi.fn();
    mount({ onOpenThread });
    fireEvent.click(chip('Threads'));
    const row = await screen.findByRole('button', { name: /Lunch plans/ });
    expect(row.textContent).toContain('1 reply');
    expect(screen.getByRole('button', { name: /Study notes/ }).textContent).toContain('5 replies');
    fireEvent.click(row);
    expect(onOpenThread).toHaveBeenCalledWith(expect.objectContaining({ id: 't1' }));
    closed();
  });
  test('falls back to the messaging panel context onOpenThread', async () => {
    listThreads.mockResolvedValue({ threads: [thread('t1', 'Lunch plans')], hasMore: false, cursor: null });
    const ctxOpen = vi.fn();
    mount({ panelCtx: { onOpenThread: ctxOpen } });
    fireEvent.click(chip('Threads'));
    fireEvent.click(await screen.findByRole('button', { name: /Lunch plans/ }));
    expect(ctxOpen).toHaveBeenCalled();
  });
  test('empty and error copy', async () => {
    mount();
    fireEvent.click(chip('Threads'));
    expect(await screen.findByText('No threads yet.')).toBeInTheDocument();
    expect(screen.getByText('Start one from any message to keep a conversation tidy.')).toBeInTheDocument();
    cleanup(); _clearGroupInfoListCaches();
    listThreads.mockRejectedValue(new Error('x'));
    mount();
    fireEvent.click(chip('Threads'));
    expect(await screen.findByText("We couldn't load threads just now.")).toBeInTheDocument();
  });
});

describe('Pinned list', () => {
  test('reuses the pinned rows; loads on open; jump closes the panel', () => {
    const pins = mount();
    fireEvent.click(chip('Pinned, 2'));
    expect(pins.onLoad).toHaveBeenCalledTimes(1);
    const dlg = screen.getByRole('dialog', { name: 'Pinned' });
    expect(within(dlg).getAllByText(/Pinned by bob/)).toHaveLength(2);
    fireEvent.click(within(dlg).getByText('text-m1', { selector: '.pins-row-preview' }));
    closed();
    expect(Element.prototype.scrollIntoView).toHaveBeenCalled();
  });
});

describe('Media grid', () => {
  test('cells are labeled; image opens the lightbox over the open panel; video jumps to its message', async () => {
    fetchGroupMedia.mockResolvedValue({ items: [media('m1'), media('v1', 'video'), media('g1', 'gif')], hasMore: false, cursor: null });
    mount();
    fireEvent.click(chip('Media'));
    const photo = await screen.findByRole('button', { name: /^Photo from ada, Oct 19, 2026/ });
    expect(screen.getByRole('button', { name: /^GIF from ada/ })).toBeInTheDocument();
    const video = screen.getByRole('button', { name: /^Video from ada/ });
    expect(within(video).getByText('1:05')).toBeInTheDocument();
    fireEvent.click(photo);
    expect(screen.getByRole('dialog', { name: 'Expanded image attachment' })).toBeInTheDocument();
    expect(screen.getByRole('dialog', { name: 'Media' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Close' }));
    await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Expanded image attachment' })).toBeNull(), { timeout: 1000 });
    fireEvent.click(video);
    expect(screen.queryByRole('dialog', { name: 'Media' })).toBeNull();
    expect(Element.prototype.scrollIntoView).toHaveBeenCalled();
  });
  test('Show in chat jumps; empty and error copy', async () => {
    fetchGroupMedia.mockResolvedValue({ items: [media('m1')], hasMore: false, cursor: null });
    mount();
    fireEvent.click(chip('Media'));
    fireEvent.click(await screen.findByRole('button', { name: /^Show in chat/ }));
    closed();
    cleanup(); _clearGroupInfoListCaches();
    fetchGroupMedia.mockResolvedValue({ items: [], hasMore: false, cursor: null });
    mount();
    fireEvent.click(chip('Media'));
    expect(await screen.findByText('No photos or videos yet.')).toBeInTheDocument();
    cleanup(); _clearGroupInfoListCaches();
    fetchGroupMedia.mockRejectedValue(new Error('403'));
    mount();
    fireEvent.click(chip('Media'));
    expect(await screen.findByText("We couldn't load media just now.")).toBeInTheDocument();
    expect(chip('Media')).toBeInTheDocument();
  });
});

describe('Sessions button placement', () => {
  test('group: Sessions is the trailing item of the row, not in the header; row renders even with no chips', () => {
    mount();
    const row = screen.getByRole('group', { name: 'Group sections' });
    const buttons = within(row).getAllByRole('button');
    expect(buttons[buttons.length - 1].textContent).toContain('Sessions');
    expect(buttons).toHaveLength(5);
    cleanup();
    mount({ features: {}, pins: null });
    const row2 = screen.getByRole('group', { name: 'Group sections' });
    expect(within(row2).getByRole('button', { name: /^Sessions/ })).toBeInTheDocument();
  });
  test('DM: Sessions stays in the header (no row)', () => {
    mount({ contact: DM });
    expect(screen.getByRole('button', { name: /^Sessions/ })).toBeInTheDocument();
    expect(screen.queryByRole('group', { name: 'Group sections' })).toBeNull();
  });
  test('inside a thread view there is no Sessions control', () => {
    mount({ thread: { id: 't1', title: 'T' } });
    expect(screen.queryByRole('button', { name: /^Sessions/ })).toBeNull();
  });
});
