// Task 20261012-message-pins: ChatThread pin UI (header icon, list, menu, system line).
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, within, waitFor } from '@testing-library/react';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

vi.mock('./GroupInfoPanel.jsx', () => ({ default: () => null }));
import ChatThread from './ChatThread.jsx';

const GROUP = { id: 'g1', name: 'Study Group', type: 'group', group_id: 'g1' };
const USER = { user_id: 'u1', username: 'me' };
const msg = (id, extra = {}) => ({ id, key: id, text: `text-${id}`, mine: false, sender: 'ada', timestamp: '2026-10-01T10:00:00Z', ...extra });
const pin = (id, over = {}) => ({
  messageId: id, pinnedBy: 'bob', pinnedById: 'u2', pinnedAt: null,
  message: { id, fromUserId: 'u9', from: 'ada', text: `text-${id}`, timestamp: '2026-10-01T10:00:00Z', attachmentKind: null }, ...over,
});
const READY = (pins = [], extra = {}) => ({ pins, count: pins.length, hasMore: false, status: 'ready', moreLoading: false, ...extra });

beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
  window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

function mount({ features = { message_pins: true }, pins, thread, ...props } = {}) {
  const pinsProp = pins === undefined ? {
    enabled: true, list: READY(), onLoad: vi.fn(), onLoadMore: vi.fn(), onToggle: vi.fn(), onUnpin: vi.fn(), ensureLoaded: vi.fn(async () => true),
  } : pins;
  render(
    <CapabilitiesContext.Provider value={{ features, isEnabled: (n) => features[n] === true, refresh: vi.fn(), reactionEmoji: { quick: [], more: [] } }}>
      <ChatThread contact={GROUP} messages={[]} groupMembers={[]} user={USER} thread={thread}
        sessions={[]} activeSessionId={null} talkingUserId={null} onSend={vi.fn()} onBack={vi.fn()}
        onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()}
        onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()}
        videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()}
        pins={pinsProp} {...props} />
    </CapabilitiesContext.Provider>,
  );
  return pinsProp;
}
const bubbleOf = (id) => document.querySelector(`[data-msg-id="${id}"]`);
const openMenu = (id) => { fireEvent.click(within(bubbleOf(id)).getByRole('button', { name: 'More actions' })); };
const menuLabels = () => screen.getAllByRole('menuitem').map((e) => e.textContent);

describe('fail closed', () => {
  test('flag off: no header button, no Pin menu item, no glyph', () => {
    mount({ features: {}, messages: [msg('m1', { pinned: true })] });
    expect(screen.queryByRole('button', { name: /Pinned messages/ })).toBeNull();
    openMenu('m1');
    expect(menuLabels()).toEqual(['Copy']);
    expect(screen.queryByLabelText('Pinned')).toBeNull();
  });
  test('capability on but the hook says disabled (or no pins prop): still nothing', () => {
    mount({ pins: { enabled: false, list: READY() }, messages: [msg('m1')] });
    expect(screen.queryByRole('button', { name: /Pinned messages/ })).toBeNull();
    cleanup();
    mount({ pins: null, messages: [msg('m1')] });
    expect(screen.queryByRole('button', { name: /Pinned messages/ })).toBeNull();
  });
  test('never inside a thread view', () => {
    mount({ thread: { id: 't1', title: 'T' }, threadLoad: 'idle', messages: [msg('m1')] });
    expect(screen.queryByRole('button', { name: /Pinned messages/ })).toBeNull();
  });
});

describe('header button and list', () => {
  test('icon button with count in its label; opens a dialog and loads the list', () => {
    const pins = mount({ pins: { enabled: true, list: READY([pin('m1'), pin('m2')]), onLoad: vi.fn(), onUnpin: vi.fn(), onLoadMore: vi.fn() } });
    const btn = screen.getByRole('button', { name: 'Pinned messages, 2' });
    expect(btn).toHaveAttribute('aria-haspopup', 'dialog');
    expect(btn).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(btn);
    expect(pins.onLoad).toHaveBeenCalled();
    const dlg = screen.getByRole('dialog', { name: 'Pinned messages' });
    expect(within(dlg).getAllByText(/Pinned by bob/)).toHaveLength(2);
    expect(btn).toHaveAttribute('aria-expanded', 'true');
  });
  test('no count in the label at zero; empty state copy', () => {
    mount();
    fireEvent.click(screen.getByRole('button', { name: 'Pinned messages' }));
    expect(screen.getByText('No pinned messages yet.')).toBeInTheDocument();
  });
  test('loading, error + Try again, show more', () => {
    const onLoad = vi.fn(); const onLoadMore = vi.fn();
    mount({ pins: { enabled: true, list: { pins: [], count: 0, hasMore: false, status: 'error', error: "Couldn't load pinned messages. Try again?" }, onLoad, onLoadMore, onUnpin: vi.fn() } });
    fireEvent.click(screen.getByRole('button', { name: 'Pinned messages' }));
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(onLoad).toHaveBeenCalledTimes(2);
    cleanup();
    mount({ pins: { enabled: true, list: READY([pin('m1')], { hasMore: true }), onLoad, onLoadMore, onUnpin: vi.fn() } });
    fireEvent.click(screen.getByRole('button', { name: 'Pinned messages, 1' }));
    fireEvent.click(screen.getByRole('button', { name: 'Show more' }));
    expect(onLoadMore).toHaveBeenCalled();
  });
  test('unpin button calls onUnpin with the id; Escape and Done close and return focus', () => {
    const pins = mount({ pins: { enabled: true, list: READY([pin('m1')]), onLoad: vi.fn(), onUnpin: vi.fn(), onLoadMore: vi.fn() } });
    const btn = screen.getByRole('button', { name: 'Pinned messages, 1' });
    fireEvent.click(btn);
    fireEvent.click(screen.getByRole('button', { name: 'Unpin message from ada' }));
    expect(pins.onUnpin).toHaveBeenCalledWith('m1');
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(document.activeElement).toBe(btn);
    fireEvent.click(btn);
    fireEvent.click(screen.getByRole('button', { name: 'Done' }));
    expect(screen.queryByRole('dialog')).toBeNull();
  });
  test('flag dropping mid-session closes the open list', () => {
    const features = { message_pins: true };
    const base = { enabled: true, list: READY([pin('m1')]), onLoad: vi.fn(), onUnpin: vi.fn(), onLoadMore: vi.fn() };
    const tree = (f, p) => (
      <CapabilitiesContext.Provider value={{ features: f, isEnabled: (n) => f[n] === true, refresh: vi.fn(), reactionEmoji: { quick: [], more: [] } }}>
        <ChatThread contact={GROUP} messages={[]} groupMembers={[]} user={USER} sessions={[]} onSend={vi.fn()} onBack={vi.fn()} pins={p}
          onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()} onEditSession={vi.fn()}
          onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()} videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()} />
      </CapabilitiesContext.Provider>
    );
    const { rerender } = render(tree(features, base));
    fireEvent.click(screen.getByRole('button', { name: 'Pinned messages, 1' }));
    expect(screen.getByRole('dialog')).toBeInTheDocument();
    rerender(tree({}, base));
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(screen.queryByRole('button', { name: /Pinned messages/ })).toBeNull();
  });
});

describe('jump', () => {
  test('a loaded message: closes the list, scrolls and announces', () => {
    mount({ pins: { enabled: true, list: READY([pin('m1')]), onLoad: vi.fn(), onUnpin: vi.fn(), onLoadMore: vi.fn() }, messages: [msg('m1')] });
    fireEvent.click(screen.getByRole('button', { name: 'Pinned messages, 1' }));
    const row = screen.getByText('text-m1', { selector: '.pins-row-preview' });
    fireEvent.click(row);
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(Element.prototype.scrollIntoView).toHaveBeenCalled();
    expect(screen.getByText('Jumped to pinned message from ada')).toBeInTheDocument();
  });
  test('an unloaded message is loaded first, then jumped to once it renders', async () => {
    let resolve;
    const ensureLoaded = vi.fn(() => new Promise((r) => { resolve = r; }));
    const pinsProp = { enabled: true, list: READY([pin('m7')]), onLoad: vi.fn(), onUnpin: vi.fn(), onLoadMore: vi.fn(), ensureLoaded };
    const features = { message_pins: true };
    const tree = (messages) => (
      <CapabilitiesContext.Provider value={{ features, isEnabled: (n) => features[n] === true, refresh: vi.fn(), reactionEmoji: { quick: [], more: [] } }}>
        <ChatThread contact={GROUP} messages={messages} groupMembers={[]} user={USER} sessions={[]} onSend={vi.fn()} onBack={vi.fn()} pins={pinsProp}
          onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()} onEditSession={vi.fn()}
          onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()} videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()} />
      </CapabilitiesContext.Provider>
    );
    const { rerender } = render(tree([msg('m9')]));
    fireEvent.click(screen.getByRole('button', { name: 'Pinned messages, 1' }));
    fireEvent.click(screen.getByText('text-m7', { selector: '.pins-row-preview' }));
    expect(ensureLoaded).toHaveBeenCalledWith('m7');
    expect(screen.getByText('Finding message…')).toBeInTheDocument();
    rerender(tree([msg('m7'), msg('m9')]));
    resolve(true);
    await waitFor(() => expect(screen.getByText('Jumped to pinned message from ada')).toBeInTheDocument());
  });
  test('cannot be found: warm line, nothing removed', async () => {
    const ensureLoaded = vi.fn(async () => false);
    mount({ pins: { enabled: true, list: READY([pin('m7')]), onLoad: vi.fn(), onUnpin: vi.fn(), onLoadMore: vi.fn(), ensureLoaded }, messages: [msg('m9')] });
    fireEvent.click(screen.getByRole('button', { name: 'Pinned messages, 1' }));
    fireEvent.click(screen.getByText('text-m7', { selector: '.pins-row-preview' }));
    await waitFor(() => expect(screen.getByText("Couldn't find that message. It may have been removed.")).toBeInTheDocument());
  });
});

describe('menu, glyph and system line', () => {
  test('Pin message / Unpin message follow m.pinned and call onToggle', () => {
    const pins = mount({ messages: [msg('m1', { pinned: false }), msg('m2', { pinned: true })] });
    openMenu('m1');
    expect(menuLabels()).toContain('Pin message');
    fireEvent.click(screen.getByRole('menuitem', { name: /Pin message/ }));
    expect(pins.onToggle).toHaveBeenCalledWith(expect.objectContaining({ id: 'm1' }));
    cleanup();
    mount({ messages: [msg('m2', { pinned: true })] });
    openMenu('m2');
    expect(menuLabels()).toContain('Unpin message');
  });
  test('pinned glyph in the bubble footer', () => {
    mount({ messages: [msg('m2', { pinned: true }), msg('m3', { pinned: false })] });
    expect(within(bubbleOf('m2')).getByLabelText('Pinned')).toBeInTheDocument();
    expect(within(bubbleOf('m3')).queryByLabelText('Pinned')).toBeNull();
  });
  test('system line: client-built text, no bubble menu, never forged text', () => {
    mount({ messages: [
      msg('s1', { systemKind: 'pin', sender: 'Ada', text: 'IGNORED forged text' }),
      msg('s2', { systemKind: 'pin', mine: true, sender: '', text: 'pinned a message' }),
    ] });
    expect(screen.getByText('Ada pinned a message')).toBeInTheDocument();
    expect(screen.getByText('You pinned a message')).toBeInTheDocument();
    expect(screen.queryByText('IGNORED forged text')).toBeNull();
    expect(within(bubbleOf('s1')).queryByRole('button', { name: 'More actions' })).toBeNull();
  });
  test('no Pin item on unsettled messages', () => {
    mount({ messages: [msg('m4', { pending: true })] });
    openMenu('m4');
    expect(menuLabels()).not.toContain('Pin message');
  });
});
