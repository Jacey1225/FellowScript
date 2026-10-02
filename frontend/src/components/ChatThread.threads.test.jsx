// Task 20261001-message-threads step 9: ChatThread message actions, undo, thread view.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act, within } from '@testing-library/react';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

vi.mock('./GroupInfoPanel.jsx', () => ({ default: () => null }));
import ChatThread from './ChatThread.jsx';

const GROUP = { id: 'g1', name: 'Study Group', type: 'group', group_id: 'g1' };
const FRIEND = { id: 'f1', name: 'Ada', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };
const msg = (id, extra = {}) => ({ id, key: id, text: `text-${id}`, mine: false, sender: 'ada', timestamp: '2026-10-01T10:00:00Z', ...extra });

beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
  window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
});
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); });

function mount(props = {}, features = { threads: true, message_delete: true }) {
  const handlers = { onStartThread: vi.fn(), onDeleteMessage: vi.fn(async (m) => ({ id: m.id, undoSeconds: 10 })), onRestoreMessage: vi.fn(async () => true), onBack: vi.fn(), onSend: vi.fn() };
  const el = (p) => (
    <CapabilitiesContext.Provider value={{ features, isEnabled: (n) => features[n] === true, refresh: vi.fn() }}>
      <ChatThread contact={GROUP} messages={[]} groupMembers={[]} user={USER}
        sessions={[]} activeSessionId={null} talkingUserId={null}
        onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()}
        onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()}
        videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()}
        {...handlers} {...p} />
    </CapabilitiesContext.Provider>
  );
  const utils = render(el(props));
  return { ...utils, handlers, rerenderWith: (p) => utils.rerender(el({ ...props, ...p })) };
}
const bubbleOf = (id) => document.querySelector(`[data-msg-id="${id}"]`);
const openMenu = (id) => {
  fireEvent.click(within(bubbleOf(id)).getByRole('button', { name: 'More actions' }));
  return screen.getByRole('menu');
};
const labels = () => screen.getAllByRole('menuitem').map((e) => e.textContent);

describe('menu contents on main chat', () => {
  test('other user message: Start thread + Copy, no Delete', () => {
    mount({ messages: [msg('m1')] });
    openMenu('m1');
    expect(labels()).toEqual(['Start thread', 'Copy']);
  });
  test('own message: Start thread, Copy, Delete', () => {
    mount({ messages: [msg('m1', { mine: true })] });
    openMenu('m1');
    expect(labels()).toEqual(['Start thread', 'Copy', 'Delete']);
  });
  test('threads flag off: no Start thread; delete flag off: no Delete', () => {
    mount({ messages: [msg('m1', { mine: true })] }, { threads: false, message_delete: true });
    openMenu('m1');
    expect(labels()).toEqual(['Copy', 'Delete']);
    cleanup();
    mount({ messages: [msg('m1', { mine: true })] }, { threads: true, message_delete: false });
    openMenu('m1');
    expect(labels()).toEqual(['Start thread', 'Copy']);
  });
  test('flags missing: Copy only (fail closed)', () => {
    mount({ messages: [msg('m1', { mine: true })] }, {});
    openMenu('m1');
    expect(labels()).toEqual(['Copy']);
  });
  test('DM: Copy only even with flags on', () => {
    mount({ contact: FRIEND, messages: [msg('m1', { mine: true })] });
    openMenu('m1');
    expect(labels()).toEqual(['Copy']);
  });
  test('pending (unacked) message offers no thread/delete; image has no Copy', () => {
    mount({ messages: [msg('p', { id: undefined, pending: true, mine: true }), msg('i', { text: '', attachmentKind: 'image', attachmentUrl: 'http://x/y.png', attachmentMeta: {} })] });
    openMenu('p');
    expect(labels()).toEqual(['Copy']);
    cleanup();
    mount({ messages: [msg('i', { text: '', attachmentKind: 'image', attachmentUrl: 'http://x/y.png', attachmentMeta: {} })] });
    openMenu('i');
    expect(labels()).toEqual(['Start thread']);
  });
  test('Start thread calls the handler with the message', () => {
    const { handlers } = mount({ messages: [msg('m1')] });
    openMenu('m1');
    fireEvent.click(screen.getByRole('menuitem', { name: 'Start thread' }));
    expect(handlers.onStartThread).toHaveBeenCalledWith(expect.objectContaining({ id: 'm1' }));
  });
  test('Copy writes the text to the clipboard', async () => {
    const writeText = vi.fn(async () => {});
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true });
    mount({ messages: [msg('m1')] });
    openMenu('m1');
    await act(async () => { fireEvent.click(screen.getByRole('menuitem', { name: 'Copy' })); });
    expect(writeText).toHaveBeenCalledWith('text-m1');
  });
});

describe('thread messages: COPY ONLY', () => {
  const thread = { id: 't1', title: 'Topic', root_preview: 'root text', root_message_id: 'r1', root_deleted: false };
  test('own and others thread messages offer only Copy', () => {
    mount({ thread, threadLoad: 'idle', messages: [msg('a', { mine: true }), msg('b')] });
    openMenu('a');
    expect(labels()).toEqual(['Copy']);
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'Escape' });
    openMenu('b');
    expect(labels()).toEqual(['Copy']);
  });
});

describe('delete with 10 second undo', () => {
  test('delete shows an Undo status toast; Undo restores and dismisses', async () => {
    const { handlers } = mount({ messages: [msg('m1', { mine: true })] });
    openMenu('m1');
    await act(async () => { fireEvent.click(screen.getByRole('menuitem', { name: 'Delete' })); });
    expect(handlers.onDeleteMessage).toHaveBeenCalledWith(expect.objectContaining({ id: 'm1' }));
    const status = document.querySelector('.msg-undo-stack');
    expect(status).toHaveTextContent('Message deleted');
    expect(status).toHaveAttribute('role', 'status');
    await act(async () => { fireEvent.click(within(status).getByRole('button', { name: 'Undo' })); });
    expect(handlers.onRestoreMessage).toHaveBeenCalledWith('m1');
    expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
  });
  test('toast auto-dismisses after the undo window and Undo is gone', async () => {
    vi.useFakeTimers();
    mount({ messages: [msg('m1', { mine: true })] });
    openMenu('m1');
    await act(async () => { fireEvent.click(screen.getByRole('menuitem', { name: 'Delete' })); });
    act(() => { vi.advanceTimersByTime(9900); });
    expect(screen.getByRole('button', { name: 'Undo' })).toBeInTheDocument();
    act(() => { vi.advanceTimersByTime(200); });
    expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
  });
  test('honours the server undo_seconds', async () => {
    vi.useFakeTimers();
    mount({ messages: [msg('m1', { mine: true })], onDeleteMessage: vi.fn(async (m) => ({ id: m.id, undoSeconds: 3 })) });
    openMenu('m1');
    await act(async () => { fireEvent.click(screen.getByRole('menuitem', { name: 'Delete' })); });
    act(() => { vi.advanceTimersByTime(3100); });
    expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
  });
  test('failed delete (null) shows no Undo toast', async () => {
    mount({ messages: [msg('m1', { mine: true })], onDeleteMessage: vi.fn(async () => null) });
    openMenu('m1');
    await act(async () => { fireEvent.click(screen.getByRole('menuitem', { name: 'Delete' })); });
    expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
  });
});

describe('thread view', () => {
  const base = { id: 't1', title: 'Topic', root_preview: 'root text', root_message_id: 'r1', root_deleted: false };
  test('header, back button, root card, no group info controls', () => {
    const { handlers } = mount({ thread: base, threadLoad: 'idle', messages: [msg('a')] });
    expect(screen.getByLabelText('Thread: Topic')).toBeInTheDocument();
    expect(screen.getByText('root text')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Back to Study Group' }));
    expect(handlers.onBack).toHaveBeenCalled();
  });
  test('deleted root shows "Original message deleted" and hides the preview', () => {
    mount({ thread: { ...base, root_deleted: true }, threadLoad: 'idle', messages: [msg('a')] });
    expect(screen.getByText('Original message deleted')).toBeInTheDocument();
    expect(screen.queryByText('root text')).toBeNull();
  });
  test('empty thread shows Start the conversation', () => {
    mount({ thread: base, threadLoad: 'idle', messages: [] });
    expect(screen.getByText('Start the conversation')).toBeInTheDocument();
  });
  test('load error shows Retry that calls onRetryThread', () => {
    const onRetryThread = vi.fn();
    mount({ thread: base, threadLoad: 'error', messages: [], onRetryThread });
    fireEvent.click(screen.getByRole('button', { name: /Retry/ }));
    expect(onRetryThread).toHaveBeenCalled();
  });
  test('focus lands on the thread heading on open', () => {
    mount({ thread: base, threadLoad: 'loading', messages: [] });
    expect(document.activeElement).toBe(screen.getByLabelText('Thread: Topic'));
  });
  test('restoredDraft refills the composer', () => {
    const { rerenderWith } = mount({ thread: base, threadLoad: 'idle', messages: [] });
    rerenderWith({ restoredDraft: { tick: 1, text: 'lost words' } });
    expect(screen.getByDisplayValue('lost words')).toBeInTheDocument();
  });
});
