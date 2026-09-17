// Regression coverage for task 20260915-fix-attachment-viewer (testing step
// 3). Diagnosis in this task's own backend.json/frontend.json found no code
// defect in either layer -- the full existing attachment suites
// (ChatThread.attachments/.lightbox/.gifBrowse/.gifGridPolish,
// useMessaging.attachments, test_messaging_attachments.py) already pass and
// were re-verified as part of this step. What that diagnosis surfaced,
// though, is a real coverage gap: every existing attachment test exercises
// the *sending* side (staging, uploading, the sender's own optimistic echo)
// or renders a message object constructed directly in the test. None of them
// exercise the *receiving* seam -- the WS onmessage handler and openChat's
// history-load path in useMessaging.js that turn a raw server payload
// (attachment_kind/attachment_meta/attachment_url, and DM/group history rows
// that may carry attachment_key too) into the camelCase message shape
// AttachmentContent actually renders from. That seam is exactly where the
// reported "GIFs/images/files aren't viewable" symptom would show up if the
// wire contract between backend and frontend ever drifted, so it's the
// regression net this step adds.
//
// Run with: cd frontend && npm test -- --run src/hooks/useMessaging.attachmentReceive.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useMessaging } from './useMessaging.js';

const USER = { user_id: 'u1', username: 'tester' };
const SENDER = { user_id: 'friend-1', username: 'ada' };

class MockWebSocket {
  static instances = [];
  constructor(url) {
    this.url = url;
    this.readyState = 1;
    this.sent = [];
    this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
    MockWebSocket.instances.push(this);
  }
  close() { this.readyState = 3; }
  send(data) { this.sent.push(data); }
}

beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  global.fetch = vi.fn();
});

afterEach(() => {
  vi.restoreAllMocks();
});

// useMessaging exposes no direct currentContact setter -- the WS onmessage
// handler only appends an incoming frame once currentContactRef is populated
// via the real openChat() flow (see that handler's own comment on reading a
// ref rather than a raw setter). So "connect + open an (empty-history) chat"
// is the real path to get into a state where a live WS frame is actually
// accepted, exactly like the app itself.
async function connectedTo(contact) {
  global.fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ host_msgs: [], other_msgs: [] }) });
  const { result } = renderHook(() => useMessaging({ user: USER }));
  act(() => { result.current.connectWS(); });
  await act(async () => { await result.current.openChat(contact); });
  return result;
}

describe('useMessaging — WS live delivery resolves the incoming attachment contract', () => {
  test('an image message from another user maps attachment_kind/meta/url straight through to the rendered message shape', async () => {
    const result = await connectedTo({ id: SENDER.user_id, type: 'friend', group_id: '' });
    const ws = MockWebSocket.instances[0];

    act(() => {
      ws.onmessage({ data: JSON.stringify({
        type: 'chat', text: '', from_user: SENDER.user_id, group_id: '', timestamp: 1,
        attachment_kind: 'image', attachment_meta: {}, attachment_url: 'https://s3.example.com/fresh-presigned',
      }) });
    });

    const msg = result.current.messages[result.current.messages.length - 1];
    expect(msg.attachmentKind).toBe('image');
    expect(msg.attachmentUrl).toBe('https://s3.example.com/fresh-presigned');
    expect(msg.mine).toBe(false);
  });

  test('a gif message from another user carries its playable url in attachmentMeta.url, matching AttachmentContent\'s gif branch', async () => {
    const result = await connectedTo({ id: SENDER.user_id, type: 'friend', group_id: '' });
    const ws = MockWebSocket.instances[0];

    act(() => {
      ws.onmessage({ data: JSON.stringify({
        type: 'chat', text: '', from_user: SENDER.user_id, group_id: '', timestamp: 1,
        attachment_kind: 'gif', attachment_meta: { url: 'https://example.com/g.gif', preview_url: 'https://example.com/g-static.gif' },
        attachment_url: null,
      }) });
    });

    const msg = result.current.messages[result.current.messages.length - 1];
    expect(msg.attachmentKind).toBe('gif');
    expect(msg.attachmentMeta.url).toBe('https://example.com/g.gif');
  });

  test('a raw attachment_key on the wire (a hypothetical backend leak) is never read onto the client message object', async () => {
    const result = await connectedTo({ id: SENDER.user_id, type: 'friend', group_id: '' });
    const ws = MockWebSocket.instances[0];

    act(() => {
      ws.onmessage({ data: JSON.stringify({
        type: 'chat', text: '', from_user: SENDER.user_id, group_id: '', timestamp: 1,
        attachment_kind: 'image', attachment_meta: {}, attachment_url: 'https://s3.example.com/fresh',
        attachment_key: 'attachments/friend-1/should-never-reach-the-client.jpg',
      }) });
    });

    const msg = result.current.messages[result.current.messages.length - 1];
    expect(msg).not.toHaveProperty('attachmentKey');
    expect(msg.attachment_key).toBeUndefined();
  });

  test('a plain text message with no attachment fields resolves all three to null, not undefined (matches AttachmentContent\'s `if (!kind) return null` guard)', async () => {
    const result = await connectedTo({ id: SENDER.user_id, type: 'friend', group_id: '' });
    const ws = MockWebSocket.instances[0];

    act(() => {
      ws.onmessage({ data: JSON.stringify({
        type: 'chat', text: 'hello', from_user: SENDER.user_id, group_id: '', timestamp: 1,
      }) });
    });

    const msg = result.current.messages[result.current.messages.length - 1];
    expect(msg.attachmentKind).toBeNull();
    expect(msg.attachmentMeta).toBeNull();
    expect(msg.attachmentUrl).toBeNull();
  });
});

describe('useMessaging.openChat — history load resolves the same attachment contract for both DM and group paths', () => {
  test('a DM history row (other_msgs) with an image attachment resolves attachmentKind/Url the same way the WS path does', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        host_msgs: [],
        other_msgs: [{
          text: '', from_user: SENDER.user_id, timestamp: 1,
          attachment_kind: 'image', attachment_meta: {}, attachment_url: 'https://s3.example.com/history-presigned',
        }],
      }),
    });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await act(async () => {
      await result.current.openChat({ id: SENDER.user_id, type: 'friend' });
    });

    expect(result.current.messages).toHaveLength(1);
    expect(result.current.messages[0].attachmentKind).toBe('image');
    expect(result.current.messages[0].attachmentUrl).toBe('https://s3.example.com/history-presigned');
  });

  test('a group history row never surfaces a raw attachment_key even if the server response happens to include one', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        group: { title: 'Bible Study', users: [USER.user_id, SENDER.user_id] },
        members: ['tester', 'ada'],
        host_msgs: [],
        other_msgs: [{
          text: '', from_user: SENDER.user_id, timestamp: 1,
          attachment_kind: 'file', attachment_meta: { filename: 'notes.pdf' },
          attachment_url: 'https://s3.example.com/group-presigned',
          attachment_key: 'attachments/friend-1/should-never-reach-the-client.pdf',
        }],
      }),
    });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await act(async () => {
      await result.current.openChat({ id: 'group-1', type: 'group', toUsers: [USER.user_id, SENDER.user_id] });
    });

    expect(result.current.messages).toHaveLength(1);
    const msg = result.current.messages[0];
    expect(msg.attachmentKind).toBe('file');
    expect(msg.attachmentUrl).toBe('https://s3.example.com/group-presigned');
    expect(msg).not.toHaveProperty('attachmentKey');
    expect(msg.attachment_key).toBeUndefined();
  });

  test('a text-only history row (no attachment fields at all) resolves to null across the board, not undefined', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        host_msgs: [{ text: 'hi', timestamp: 1 }],
        other_msgs: [],
      }),
    });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await act(async () => {
      await result.current.openChat({ id: SENDER.user_id, type: 'friend' });
    });

    expect(result.current.messages[0].attachmentKind).toBeNull();
    expect(result.current.messages[0].attachmentMeta).toBeNull();
    expect(result.current.messages[0].attachmentUrl).toBeNull();
  });
});
