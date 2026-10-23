// Task 20261022-reactions-live: end to end (real useMessaging + real ChatThread).
// A reaction added from the picker or a chip must render below the message with
// no reload, for history rows, a live inbound message, and my own just-sent
// message (ack id swap). Rollback on failure removes the chip and shows the error.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act, waitFor, within } from '@testing-library/react';
import { message } from 'antd';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';
import { useMessaging } from '../hooks/useMessaging.js';

vi.mock('./GroupInfoPanel.jsx', () => ({ default: () => null }));
import ChatThread from './ChatThread.jsx';

const USER = { user_id: 'u1', username: 'tester' };
const GROUP = { id: 'g1', type: 'group', group_id: 'g1', name: 'G', toUsers: ['u1'] };
const FEATURES = { message_reactions: true, chat_replies: true };
const ALLOW = { quick: ['👍', '❤️'], more: ['🔥'] };
const ok = (body) => ({ ok: true, status: 200, json: async () => body });

class MockWebSocket {
  static instances = [];
  constructor(url) { this.url = url; this.readyState = 1; this.sent = []; MockWebSocket.instances.push(this); }
  close() { this.readyState = 3; }
  send(d) { this.sent.push(d); }
}

let hook; let reactionResponder;
function Harness() {
  hook = useMessaging({ user: USER });
  return (
    <ChatThread contact={GROUP} messages={hook.messages} groupMembers={[]} user={USER}
      sessions={[]} activeSessionId={null} talkingUserId={null}
      onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()}
      onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()}
      videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()}
      onSend={hook.sendMessage} onBack={vi.fn()} onToggleReaction={hook.toggleReaction} />
  );
}

beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  Element.prototype.scrollIntoView = vi.fn();
  window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
  reactionResponder = (url, opts) => ok({ emoji: '👍', count: 1, viewer_reacted: true });
  global.fetch = vi.fn(async (url, opts) => {
    const u = String(url);
    if (u.includes('/message-reactions/')) return reactionResponder(u, opts);
    if (/\/groups\/u1\/g1(\?|$)/.test(u)) {
      return ok({ group: { title: 'G', users: ['u1'] }, messages: [{ id: 'h1', text: 'history', timestamp: '2026-10-01T10:00:01.000000Z', from_user: 'ada', mine: false, reactions: [] }], page: { has_more: false } });
    }
    return { ok: false, status: 404, json: async () => ({}) };
  });
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

async function mountOpen() {
  const features = FEATURES;
  render(
    <CapabilitiesContext.Provider value={{ features, isEnabled: (n) => features[n] === true, refresh: vi.fn(), reactionEmoji: ALLOW }}>
      <Harness />
    </CapabilitiesContext.Provider>,
  );
  act(() => { hook.connectWS(); });
  await act(async () => { await hook.openChat(GROUP); });
}
const bubbleOf = (id) => document.querySelector(`[data-mid="${id}"]`);
async function reactVia(id, emojiName) {
  fireEvent.click(within(bubbleOf(id)).getByRole('button', { name: 'React' }));
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: new RegExp(emojiName) })); });
}

vi.setConfig({ testTimeout: 30000 });

describe('reaction appears with no reload', () => {
  test('history message: chip renders right after picking', async () => {
    await mountOpen();
    await reactVia('h1', 'Thumbs up');
    await waitFor(() => expect(within(bubbleOf('h1')).getByRole('button', { name: 'Thumbs up, 1 reaction, you reacted' })).toBeInTheDocument());
  });

  test('live inbound message (id on the frame): chip renders after picking', async () => {
    await mountOpen();
    act(() => {
      MockWebSocket.instances[0].onmessage({ data: JSON.stringify({ id: 'live1', from_user: 'ada', text: 'hi', group_id: 'g1', timestamp: '2026-10-01T10:00:09.000000Z' }) });
    });
    await reactVia('live1', 'Thumbs up');
    await waitFor(() => expect(within(bubbleOf('live1')).getByRole('button', { name: 'Thumbs up, 1 reaction, you reacted' })).toBeInTheDocument());
  });

  test('my own just-sent message (ack swaps the local id): chip renders after picking', async () => {
    await mountOpen();
    await act(async () => { await hook.sendMessage('mine'); });
    const sent = hook.messages.find((m) => m.text === 'mine');
    act(() => {
      MockWebSocket.instances[0].onmessage({ data: JSON.stringify({ type: 'ack', client_ref: sent.clientRef, id: 'srv1', timestamp: '2026-10-01T10:00:20.000000Z' }) });
    });
    await waitFor(() => expect(bubbleOf('srv1')).not.toBeNull());
    await reactVia('srv1', 'Thumbs up');
    await waitFor(() => expect(within(bubbleOf('srv1')).getByRole('button', { name: 'Thumbs up, 1 reaction, you reacted' })).toBeInTheDocument());
  });

  test('server failure rolls the chip back and shows the error', async () => {
    reactionResponder = () => ({ ok: false, status: 500, json: async () => ({}) });
    await mountOpen();
    await reactVia('h1', 'Thumbs up');
    await waitFor(() => expect(message.error).toHaveBeenCalled());
    expect(within(bubbleOf('h1')).queryByRole('button', { name: /Thumbs up/ })).toBeNull();
  });
});
