// Task 20261017-chat-mentions: the @ picker in the composer and bold rendering.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor, act } from '@testing-library/react';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

vi.mock('./GroupInfoPanel.jsx', () => ({ default: () => null }));
import ChatThread from './ChatThread.jsx';

const FRIEND = { id: 'f1', name: 'Ada', type: 'friend', toUsers: ['f1'] };
const GROUP = { id: 'g1', name: 'Study', type: 'group', group_id: 'g1', toUsers: ['u1', 'a', 'b'] };
const USER = { user_id: 'u1', username: 'me' };
const ON = { chat_mentions: true };

beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
  window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

function mount(props = {}, features = ON) {
  const handlers = { onSend: vi.fn(), onBack: vi.fn() };
  render(
    <CapabilitiesContext.Provider value={{ features, isEnabled: (n) => features[n] === true, refresh: vi.fn(), reactionEmoji: { quick: [], more: [] } }}>
      <ChatThread contact={FRIEND} messages={[]} groupMembers={[]} user={USER}
        sessions={[]} activeSessionId={null} talkingUserId={null}
        onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()}
        onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()}
        videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()}
        {...handlers} {...props} />
    </CapabilitiesContext.Provider>,
  );
  return handlers;
}
const input = () => screen.getByPlaceholderText('Message…');
const type = (v) => fireEvent.change(input(), { target: { value: v } });

describe('picker', () => {
  test('flag off: no picker, plain input, onSend call shape unchanged', () => {
    const h = mount({}, {});
    type('@');
    expect(screen.queryByRole('listbox')).toBeNull();
    expect(input()).not.toHaveAttribute('role', 'combobox');
    type('@Ada hi');
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
    expect(h.onSend.mock.calls[0]).toEqual(['@Ada hi']);
  });

  test('DM: @ lists the other person with listbox/option/combobox semantics', () => {
    mount();
    type('hi @');
    const list = screen.getByRole('listbox', { name: 'Mention a member' });
    const opt = screen.getByRole('option', { name: /Ada/ });
    expect(list).toContainElement(opt);
    expect(opt).toHaveAttribute('aria-selected', 'true');
    expect(input()).toHaveAttribute('role', 'combobox');
    expect(input()).toHaveAttribute('aria-expanded', 'true');
    expect(input()).toHaveAttribute('aria-controls', list.id);
    expect(input()).toHaveAttribute('aria-activedescendant', opt.id);
  });

  test('Enter inserts, does not send; sending then carries the structured mention', () => {
    const h = mount();
    type('hi @a');
    fireEvent.keyDown(input(), { key: 'Enter' });
    expect(h.onSend).not.toHaveBeenCalled();
    expect(input().value).toBe('hi @Ada ');
    expect(screen.queryByRole('listbox')).toBeNull();
    fireEvent.keyUp(input(), { key: 'Enter' });
    type('hi @Ada thanks');
    fireEvent.keyDown(input(), { key: 'Enter' });
    expect(h.onSend).toHaveBeenCalledTimes(1);
    expect(h.onSend.mock.calls[0]).toEqual(['hi @Ada thanks', null, null,
      [{ userId: 'f1', username: 'Ada', start: 3, length: 4 }]]);
  });

  test('typing inside a picked mention drops it: send is plain', () => {
    const h = mount();
    type('@');
    fireEvent.keyDown(input(), { key: 'Tab' });
    expect(input().value).toBe('@Ada ');
    type('@Aa ');
    type('@Aa hi');
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
    expect(h.onSend.mock.calls[0]).toEqual(['@Aa hi']);
  });

  test('Backspace at the end of a mention removes it whole', () => {
    mount();
    type('@');
    fireEvent.keyDown(input(), { key: 'Enter' });
    input().setSelectionRange(4, 4);
    fireEvent.keyDown(input(), { key: 'Backspace' });
    expect(input().value).toBe(' ');
  });

  test('Escape closes only the picker; mid-word @ never opens', () => {
    mount();
    type('@a');
    expect(screen.getByRole('listbox')).toBeInTheDocument();
    fireEvent.keyDown(input(), { key: 'Escape' });
    expect(screen.queryByRole('listbox')).toBeNull();
    expect(input().value).toBe('@a');
    type('mail a@b');
    expect(screen.queryByRole('listbox')).toBeNull();
  });

  test('No one matches shows and Enter then sends normally', () => {
    const h = mount();
    type('@zzz');
    expect(screen.getByRole('listbox')).toHaveTextContent('No one matches');
    expect(screen.getByRole('status')).toHaveTextContent('No one matches');
    expect(screen.queryAllByRole('option')).toHaveLength(0);
    fireEvent.keyDown(input(), { key: 'Enter' });
    expect(h.onSend).toHaveBeenCalledTimes(1);
    expect(h.onSend.mock.calls[0]).toEqual(['@zzz']);
  });

  test('click on a row inserts', () => {
    mount();
    type('@');
    fireEvent.mouseDown(screen.getByRole('option', { name: /Ada/ }));
    expect(input().value).toBe('@Ada ');
  });
});

// Other widgets inside ChatThread fetch too; only mention-members is under test.
const routed = (impl) => vi.fn(async (url) => (String(url).includes('mention-members')
  ? impl(url) : { ok: false, status: 404, json: async () => ({}) }));
const mentionCalls = (m) => m.mock.calls.filter(c => String(c[0]).includes('mention-members'));

describe('group member list', () => {
  const members = [{ user_id: 'a', username: 'Matthew' }, { user_id: 'b', username: 'Mary' }, { user_id: 'c', username: 'Zed' }];
  test('fetches mention-members, filters as you type, arrows move, 5-row cap scrolls via CSS', async () => {
    const fetchMock = routed(async () => ({ status: 200, json: async () => ({ members }) }));
    vi.stubGlobal('fetch', fetchMock);
    mount({ contact: GROUP });
    await waitFor(() => expect(mentionCalls(fetchMock)).toHaveLength(1));
    expect(String(mentionCalls(fetchMock)[0][0])).toContain('/groups/u1/g1/mention-members');
    await act(async () => {});
    type('@m');
    expect(screen.getAllByRole('option').map(o => o.textContent)).toEqual(['MMatthew', 'MMary']);
    fireEvent.keyDown(input(), { key: 'ArrowDown' });
    expect(screen.getAllByRole('option')[1]).toHaveAttribute('aria-selected', 'true');
    fireEvent.keyDown(input(), { key: 'ArrowDown' });
    expect(screen.getAllByRole('option')[0]).toHaveAttribute('aria-selected', 'true');
    fireEvent.keyDown(input(), { key: 'ArrowUp' });
    fireEvent.keyDown(input(), { key: 'Enter' });
    expect(input().value).toBe('@Mary ');
  });

  test('already mentioned people are not offered again', async () => {
    vi.stubGlobal('fetch', routed(async () => ({ status: 200, json: async () => ({ members }) })));
    mount({ contact: GROUP });
    await act(async () => {});
    type('@Mary');
    fireEvent.keyDown(input(), { key: 'Enter' });
    type('@Mary @M');
    expect(screen.getAllByRole('option').map(o => o.textContent)).toEqual(['MMatthew']);
  });

  test.each([
    ['non-200', async () => ({ status: 404, json: async () => ({}) })],
    ['malformed body', async () => ({ status: 200, json: async () => ({ members: [{ user_id: 'a' }] }) })],
    ['network error', async () => { throw new Error('down'); }],
  ])('%s: no picker and no invented list', async (_n, impl) => {
    vi.stubGlobal('fetch', routed(impl));
    mount({ contact: GROUP });
    await act(async () => {});
    type('@');
    expect(screen.queryByRole('listbox')).toBeNull();
  });

  test('flag off: the endpoint is never called', async () => {
    const fetchMock = routed(async () => ({ status: 200, json: async () => ({ members }) }));
    vi.stubGlobal('fetch', fetchMock);
    mount({ contact: GROUP }, {});
    await act(async () => {});
    expect(mentionCalls(fetchMock)).toHaveLength(0);
  });
});

describe('rendering', () => {
  const base = { id: 'm1', key: 'm1', mine: false, sender: 'ada', timestamp: '2026-10-17T10:00:00Z' };
  test('mention runs are bold, text unchanged; thread-style and caption bubbles too', () => {
    mount({
      messages: [
        { ...base, text: 'yo @Matthew!', mentions: [{ userId: 'a', start: 3, length: 8, username: 'Matthew' }] },
        { ...base, id: 'm2', key: 'm2', text: 'cap @Matthew', attachmentKind: 'file', attachmentMeta: { filename: 'x.pdf' },
          mentions: [{ userId: 'a', start: 4, length: 8 }] },
      ],
    }, {});
    const strongs = document.querySelectorAll('strong.msg-mention');
    expect(strongs).toHaveLength(2);
    expect(strongs[0].textContent).toBe('@Matthew');
    expect(strongs[0].parentElement.textContent).toContain('yo @Matthew!');
    expect(strongs[1].parentElement.textContent).toBe('cap @Matthew');
  });
  test('an out-of-bounds range renders plain, no crash', () => {
    mount({ messages: [{ ...base, text: 'short', mentions: [{ userId: 'a', start: 10, length: 8 }] }] }, {});
    expect(document.querySelector('strong.msg-mention')).toBeNull();
    expect(screen.getByText('short')).toBeInTheDocument();
  });
  test('messages without a mentions key are untouched', () => {
    mount({ messages: [{ ...base, text: 'hello' }] }, {});
    expect(screen.getByText('hello')).toBeInTheDocument();
  });
});
