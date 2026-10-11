// Task 20261011-desktop-chat-replies-reactions: ChatThread UI for reactions + replies.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, within } from '@testing-library/react';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

vi.mock('./GroupInfoPanel.jsx', () => ({ default: () => null }));
import ChatThread from './ChatThread.jsx';

const GROUP = { id: 'g1', name: 'Study Group', type: 'group', group_id: 'g1' };
const FRIEND = { id: 'f1', name: 'Ada', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };
const msg = (id, extra = {}) => ({ id, key: id, text: `text-${id}`, mine: false, sender: 'ada', timestamp: '2026-10-01T10:00:00Z', ...extra });
const ALLOW = { quick: ['👍', '❤️'], more: ['🔥'] };
const ON = { message_reactions: true, chat_replies: true };

beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
  window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
});
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); });

function mount(props = {}, features = ON, reactionEmoji = ALLOW) {
  const handlers = { onSend: vi.fn(), onToggleReaction: vi.fn(async () => true), onBack: vi.fn() };
  render(
    <CapabilitiesContext.Provider value={{ features, isEnabled: (n) => features[n] === true, refresh: vi.fn(), reactionEmoji }}>
      <ChatThread contact={GROUP} messages={[]} groupMembers={[]} user={USER}
        sessions={[]} activeSessionId={null} talkingUserId={null}
        onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()}
        onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()}
        videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()}
        {...handlers} {...props} />
    </CapabilitiesContext.Provider>,
  );
  return handlers;
}
const bubbleOf = (id) => document.querySelector(`[data-msg-id="${id}"]`);
const openMenu = (id) => { fireEvent.click(within(bubbleOf(id)).getByRole('button', { name: 'More actions' })); };
const labels = () => screen.getAllByRole('menuitem').map((e) => e.textContent);
const input = () => screen.getByPlaceholderText('Message…');

describe('flags off (default): chat unchanged', () => {
  test('no Reply/React menu items, no quick buttons, no chips, no quote, no reply bar', () => {
    mount({ messages: [msg('m1', { reactions: [{ emoji: '👍', count: 2, viewerReacted: true }], reply: { id: 'x', text: 'q', author: 'bob', authorId: null, deleted: false } })] }, {}, { quick: [], more: [] });
    openMenu('m1');
    expect(labels()).toEqual(['Copy']);
    expect(screen.queryByRole('button', { name: 'Reply' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'React' })).toBeNull();
    expect(document.querySelector('.msg-reactions')).toBeNull();
    expect(document.querySelector('.msg-quote')).toBeNull();
  });
  test('onSend call shape is exactly (text) with no extra args', () => {
    const h = mount({ messages: [msg('m1')] }, {}, { quick: [], more: [] });
    fireEvent.change(input(), { target: { value: 'hello' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
    expect(h.onSend).toHaveBeenCalledTimes(1);
    expect(h.onSend.mock.calls[0]).toEqual(['hello']);
  });
  test('reactions flag on but empty allowlist: still no reaction UI', () => {
    mount({ messages: [msg('m1', { reactions: [{ emoji: '👍', count: 1, viewerReacted: false }] })] }, ON, { quick: [], more: [] });
    expect(document.querySelector('.msg-reactions')).toBeNull();
  });
});

describe('reactions on', () => {
  const withChips = () => msg('m1', { reactions: [{ emoji: '👍', count: 2, viewerReacted: true }, { emoji: '🔥', count: 1, viewerReacted: false }] });
  test('chips show label and aria-pressed; click toggles via onToggleReaction', () => {
    const h = mount({ messages: [withChips()] });
    const own = screen.getByRole('button', { name: 'Thumbs up, 2 reactions, you reacted' });
    expect(own).toHaveAttribute('aria-pressed', 'true');
    const other = screen.getByRole('button', { name: 'Fire, 1 reaction' });
    expect(other).toHaveAttribute('aria-pressed', 'false');
    fireEvent.click(other);
    expect(h.onToggleReaction).toHaveBeenCalledWith(expect.objectContaining({ id: 'm1' }), '🔥');
  });
  test('React menu item opens the picker with the server allowlist; picking toggles', () => {
    const h = mount({ messages: [msg('m1')] });
    openMenu('m1');
    expect(labels()).toContain('React');
    fireEvent.click(screen.getByRole('menuitem', { name: /React/ }));
    const dlg = screen.getByRole('dialog', { name: 'Add reaction' });
    fireEvent.click(within(dlg).getByRole('button', { name: 'Heart' }));
    expect(h.onToggleReaction).toHaveBeenCalledWith(expect.objectContaining({ id: 'm1' }), '❤️');
    expect(screen.queryByRole('dialog', { name: 'Add reaction' })).toBeNull();
  });
  test('unsettled (pending) messages offer no React', () => {
    mount({ messages: [msg('p', { id: undefined, pending: true, mine: true })] });
    openMenu('p');
    expect(labels()).not.toContain('React');
  });
  test('works in a DM too', () => {
    mount({ contact: FRIEND, messages: [withChips()] });
    expect(screen.getByRole('button', { name: 'Fire, 1 reaction' })).toBeInTheDocument();
  });
  test('no reaction UI inside a thread view', () => {
    mount({ thread: { id: 't1', title: 'T', root_message_id: 'r1', root_deleted: false }, threadLoad: 'idle', messages: [withChips()] });
    expect(document.querySelector('.msg-reactions')).toBeNull();
  });
});

describe('replies on', () => {
  test('Reply shows composer preview; Escape cancels it', () => {
    mount({ messages: [msg('m1', { text: 'quote me' })] });
    openMenu('m1');
    fireEvent.click(screen.getByRole('menuitem', { name: /Reply/ }));
    const bar = document.querySelector('.reply-bar');
    expect(bar).toBeTruthy();
    expect(bar.textContent).toContain('Replying to ada');
    expect(bar.textContent).toContain('quote me');
    fireEvent.keyDown(input(), { key: 'Escape' });
    expect(document.querySelector('.reply-bar')).toBeNull();
  });
  test('Cancel button clears the preview', () => {
    mount({ messages: [msg('m1')] });
    openMenu('m1');
    fireEvent.click(screen.getByRole('menuitem', { name: /Reply/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Cancel reply' }));
    expect(document.querySelector('.reply-bar')).toBeNull();
  });
  test('sending with a reply passes it as third arg, then the bar clears', () => {
    const h = mount({ messages: [msg('m1', { text: 'orig' })] });
    openMenu('m1');
    fireEvent.click(screen.getByRole('menuitem', { name: /Reply/ }));
    fireEvent.change(input(), { target: { value: 'answer' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
    expect(h.onSend).toHaveBeenCalledWith('answer', null, expect.objectContaining({ id: 'm1', text: 'orig', author: 'ada' }));
    expect(document.querySelector('.reply-bar')).toBeNull();
  });
  test('quoted block of a loaded original is a labelled button that jumps; highlight applied', () => {
    const reply = { id: 'm1', text: 'orig', author: 'ada', authorId: null, deleted: false };
    mount({ messages: [msg('m1', { text: 'orig' }), msg('m2', { mine: true, reply })] });
    const q = screen.getByRole('button', { name: 'Replying to ada: orig. Go to original message' });
    fireEvent.click(q);
    expect(Element.prototype.scrollIntoView).toHaveBeenCalled();
  });
  test('quote with original not loaded is non-interactive', () => {
    const reply = { id: 'gone-from-page', text: 'old', author: 'ada', authorId: null, deleted: false };
    mount({ messages: [msg('m2', { reply })] });
    expect(document.querySelector('.msg-quote').textContent).toContain('old');
    expect(screen.queryByRole('button', { name: /Go to original message/ })).toBeNull();
  });
  test('deleted original shows the unavailable label, not jumpable, no text leaked', () => {
    const reply = { id: 'm1', text: null, author: null, authorId: null, deleted: true };
    mount({ messages: [msg('m1'), msg('m2', { reply })] });
    expect(screen.getByText('Original message unavailable')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Go to original message/ })).toBeNull();
  });
  test('server text is rendered as plain text, not HTML', () => {
    const reply = { id: 'zz', text: '<img src=x onerror=alert(1)>', author: '<b>evil</b>', authorId: null, deleted: false };
    mount({ messages: [msg('m2', { reply })] });
    expect(document.querySelector('.msg-quote img')).toBeNull();
    expect(document.querySelector('.msg-quote b')).toBeNull();
  });
  test('no Reply item inside a thread view', () => {
    mount({ thread: { id: 't1', title: 'T', root_message_id: 'r1', root_deleted: false }, threadLoad: 'idle', messages: [msg('m1')] });
    openMenu('m1');
    expect(labels()).not.toContain('Reply');
  });
  test('chat_replies off but reactions on: React present, Reply absent', () => {
    mount({ messages: [msg('m1')] }, { message_reactions: true, chat_replies: false });
    openMenu('m1');
    expect(labels()).toContain('React');
    expect(labels()).not.toContain('Reply');
  });
});
