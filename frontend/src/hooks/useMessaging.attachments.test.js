// Tests for the attachment-support additions to useMessaging.js (task
// 20260904-messaging-attachments, testing step 6): requestUploadUrl,
// uploadToS3, searchGifs, and sendMessage's extended attachment payload/
// optimistic-echo shape.
//
// Run with: cd frontend && npm test -- --run src/hooks/useMessaging.attachments.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useMessaging } from './useMessaging.js';

const USER = { user_id: 'u1', username: 'tester' };

class MockWebSocket {
  static instances = [];
  constructor(url) {
    this.url = url;
    this.readyState = 1; // opens as connected for these tests
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

function connected() {
  const { result } = renderHook(() => useMessaging({ user: USER }));
  act(() => { result.current.connectWS(); });
  act(() => {
    result.current.openChat?.({ id: 'friend-1', type: 'friend', toUsers: ['friend-1'] });
  });
  return result;
}

describe('useMessaging.requestUploadUrl', () => {
  test('POSTs attachment_kind/content_type/size_bytes and resolves the presigned-policy shape', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ url: 'https://s3.example.com', fields: { a: '1' }, object_key: 'attachments/u1/x.jpg', expires_in: 300 }),
    });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    let info;
    await act(async () => { info = await result.current.requestUploadUrl('image', 'image/jpeg', 1024); });

    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining('/message/upload-url/u1'),
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ attachment_kind: 'image', content_type: 'image/jpeg', size_bytes: 1024 }),
      }),
    );
    expect(info).toEqual({ url: 'https://s3.example.com', fields: { a: '1' }, object_key: 'attachments/u1/x.jpg', expires_in: 300 });
  });

  test('a rejected/4xx response throws using the server-provided detail, not a generic message', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: false, status: 400, json: async () => ({ detail: 'Videos can be up to 250MB.' }),
    });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await expect(
      act(async () => { await result.current.requestUploadUrl('video', 'video/mp4', 999999999); })
    ).rejects.toThrow('Videos can be up to 250MB.');
  });

  test('rejects immediately (no fetch) when there is no signed-in user', async () => {
    const { result } = renderHook(() => useMessaging({ user: null }));
    await expect(
      act(async () => { await result.current.requestUploadUrl('image', 'image/jpeg', 100); })
    ).rejects.toThrow();
    expect(global.fetch).not.toHaveBeenCalled();
  });
});

describe('useMessaging.uploadToS3', () => {
  test('POSTs a multipart form (presigned fields + file) directly to the presigned URL, not this app\'s API', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 204 });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    const file = new File(['x'], 'a.jpg', { type: 'image/jpeg' });
    const uploadInfo = { url: 'https://s3.example.com/bucket', fields: { key: 'attachments/u1/a.jpg', policy: 'p' } };

    await act(async () => { await result.current.uploadToS3(uploadInfo, file); });

    expect(global.fetch).toHaveBeenCalledWith('https://s3.example.com/bucket', expect.objectContaining({ method: 'POST' }));
    const formArg = global.fetch.mock.calls[0][1].body;
    expect(formArg).toBeInstanceOf(FormData);
    expect(formArg.get('key')).toBe('attachments/u1/a.jpg');
    expect(formArg.get('policy')).toBe('p');
    expect(formArg.get('file')).toBe(file);
  });

  test('a failed (non-2xx, non-204) upload throws', async () => {
    global.fetch.mockResolvedValueOnce({ ok: false, status: 403 });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    const file = new File(['x'], 'a.jpg', { type: 'image/jpeg' });
    await expect(
      act(async () => { await result.current.uploadToS3({ url: 'https://s3.example.com', fields: {} }, file); })
    ).rejects.toThrow('Upload failed');
  });
});

describe('useMessaging.searchGifs', () => {
  test('a blank query short-circuits to an empty array without a network call', async () => {
    const { result } = renderHook(() => useMessaging({ user: USER }));
    const gifs = await act(async () => result.current.searchGifs('   '));
    expect(gifs).toEqual([]);
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test('a real query hits GET /message/gif-search and unwraps .results', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ results: [{ id: 'g1' }] }) });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    const gifs = await act(async () => result.current.searchGifs('cats'));
    expect(global.fetch).toHaveBeenCalledWith(expect.stringContaining('/message/gif-search?q=cats'));
    expect(gifs).toEqual([{ id: 'g1' }]);
  });

  test('a non-ok response throws the warm, non-technical copy (never a raw status)', async () => {
    global.fetch.mockResolvedValueOnce({ ok: false, status: 502 });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await expect(
      act(async () => { await result.current.searchGifs('cats'); })
    ).rejects.toThrow("Couldn't load GIFs right now — try again in a moment.");
  });
});

describe('useMessaging.sendMessage — attachment payload + optimistic echo', () => {
  test('an image/video/file attachment sends attachment_kind/meta/key over the WS frame', () => {
    const result = connected();
    act(() => {
      result.current.sendMessage('look at this', {
        kind: 'image', meta: { width: 10, height: 20 }, objectKey: 'attachments/u1/x.jpg', localUrl: 'blob:preview',
      });
    });
    const sentFrame = JSON.parse(MockWebSocket.instances[0].sent[0]);
    expect(sentFrame.attachment_kind).toBe('image');
    expect(sentFrame.attachment_meta).toEqual({ width: 10, height: 20 });
    expect(sentFrame.attachment_key).toBe('attachments/u1/x.jpg');
    expect(sentFrame.text).toBe('look at this');
  });

  test('a gif attachment never sends attachment_key (no S3 object of our own to reference)', () => {
    const result = connected();
    act(() => {
      result.current.sendMessage('', { kind: 'gif', meta: { url: 'https://example.com/g.gif' }, objectKey: null });
    });
    const sentFrame = JSON.parse(MockWebSocket.instances[0].sent[0]);
    expect(sentFrame.attachment_kind).toBe('gif');
    expect(sentFrame.attachment_key).toBeUndefined();
  });

  test('the sender\'s own optimistic echo never carries an attachmentUrl for a gif (renders from attachmentMeta.url instead)', () => {
    const result = connected();
    act(() => {
      result.current.sendMessage('', { kind: 'gif', meta: { url: 'https://example.com/g.gif' }, objectKey: null, localUrl: null });
    });
    const echoed = result.current.messages[result.current.messages.length - 1];
    expect(echoed.attachmentKind).toBe('gif');
    expect(echoed.attachmentUrl).toBeNull();
  });

  test('the sender\'s own optimistic echo for image/video uses the local (blob) preview URL', () => {
    const result = connected();
    act(() => {
      result.current.sendMessage('', { kind: 'image', meta: {}, objectKey: 'attachments/u1/x.jpg', localUrl: 'blob:local-preview' });
    });
    const echoed = result.current.messages[result.current.messages.length - 1];
    expect(echoed.attachmentUrl).toBe('blob:local-preview');
  });

  test('a plain text-only send (no attachment arg) omits all attachment fields from the WS frame', () => {
    const result = connected();
    act(() => { result.current.sendMessage('just text'); });
    const sentFrame = JSON.parse(MockWebSocket.instances[0].sent[0]);
    expect(sentFrame.attachment_kind).toBeUndefined();
    expect(sentFrame.attachment_meta).toBeUndefined();
    expect(sentFrame.attachment_key).toBeUndefined();
  });
});
