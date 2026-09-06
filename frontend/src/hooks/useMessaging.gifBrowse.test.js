// Tests for the default/trending GIF-browse addition to useMessaging.js
// (task 20260905-gif-picker-default-browse, testing step 4): browseGifs
// hits the same GET /message/gif-search endpoint as searchGifs but in
// browse mode (no `q`), threads an opaque page_token straight through, and
// unwraps the {results, next_page_token, has_more} envelope into the
// camelCase shape GifSearchModal expects.
//
// Run with: cd frontend && npm test -- --run src/hooks/useMessaging.gifBrowse.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useMessaging } from './useMessaging.js';

const USER = { user_id: 'u1', username: 'tester' };

beforeEach(() => {
  global.fetch = vi.fn();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('useMessaging.browseGifs', () => {
  test('the first page (no token) hits GET /message/gif-search with no page_token param', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ results: [{ id: 'g1' }], next_page_token: 'tok-2', has_more: true }),
    });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    let page;
    await act(async () => { page = await result.current.browseGifs(); });

    const calledUrl = global.fetch.mock.calls[0][0];
    expect(calledUrl).toContain('/message/gif-search');
    expect(calledUrl).not.toContain('page_token');
    expect(calledUrl).not.toContain('?q=');
    expect(page).toEqual({ results: [{ id: 'g1' }], nextPageToken: 'tok-2', hasMore: true });
  });

  test('a subsequent page passes the opaque page_token straight through, URL-encoded', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ results: [{ id: 'g2' }], next_page_token: null, has_more: false }),
    });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    let page;
    await act(async () => { page = await result.current.browseGifs('opaque token/with-special+chars'); });

    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`page_token=${encodeURIComponent('opaque token/with-special+chars')}`)
    );
    expect(page).toEqual({ results: [{ id: 'g2' }], nextPageToken: null, hasMore: false });
  });

  test('has_more false / next_page_token absent degrades to hasMore:false, nextPageToken:null', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ results: [] }) });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    let page;
    await act(async () => { page = await result.current.browseGifs(); });
    expect(page).toEqual({ results: [], nextPageToken: null, hasMore: false });
  });

  test('a non-ok response throws the same warm, non-technical copy as searchGifs', async () => {
    global.fetch.mockResolvedValueOnce({ ok: false, status: 502 });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await expect(
      act(async () => { await result.current.browseGifs(); })
    ).rejects.toThrow("Couldn't load GIFs right now — try again in a moment.");
  });
});
