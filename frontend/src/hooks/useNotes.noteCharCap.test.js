// Tests for the per-note character cap in useNotes.js
// (task 20260929-free-note-char-cap): the limit + plan are read from the
// usage endpoint (never hardcoded), a 403 note_chars response is surfaced
// with the chars-over count and the draft/cache are preserved, and only free
// users see the upgrade call to action.
//
// Run with: cd frontend && npm test -- --run src/hooks/useNotes.noteCharCap.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { message } from 'antd';
import { useNotes } from './useNotes.js';
import { getUpgradePrompt, dismissUpgradePrompt } from '../lib/upgradePrompt.js';

const USER = { user_id: 'user-1', username: 'tester' };

const usage = (limit, subscribed) => ({
  ok: true, status: 200,
  json: async () => ({ subscribed, plan_type: subscribed ? 'plus' : 'free', note_chars: { unlimited: false, limit } }),
});
const charLimit403 = (used, limit) => ({
  ok: false, status: 403,
  json: async () => ({ detail: { resource: 'note_chars', allowed: false, unlimited: false, used, limit, remaining: 0 } }),
});
const weekly403 = () => ({
  ok: false, status: 403,
  json: async () => ({ detail: { resource: 'notes', allowed: false, used: 10, limit: 10, remaining: 0 } }),
});

beforeEach(() => {
  global.fetch = vi.fn();
  vi.spyOn(message, 'warning').mockImplementation(() => {});
  vi.spyOn(message, 'error').mockImplementation(() => {});
  message.warning.mockClear();
  message.error.mockClear();
});

describe('useNotes.loadNoteCharLimit — reads the per-plan limit from the server', () => {
  test('free user: limit 30000 and subscribed=false come from GET /subscriptions/user/{id}/usage', async () => {
    global.fetch.mockResolvedValueOnce(usage(30000, false));
    const { result } = renderHook(() => useNotes({ user: USER }));
    expect(result.current.noteCharInfo).toEqual({ limit: null, subscribed: null });

    await act(async () => { await result.current.loadNoteCharLimit(); });

    expect(global.fetch.mock.calls[0][0]).toMatch(/\/subscriptions\/user\/user-1\/usage$/);
    expect(result.current.noteCharInfo).toEqual({ limit: 30000, subscribed: false });
  });

  test('paid user: limit 100000 and subscribed=true', async () => {
    global.fetch.mockResolvedValueOnce(usage(100000, true));
    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNoteCharLimit(); });
    expect(result.current.noteCharInfo).toEqual({ limit: 100000, subscribed: true });
  });

  test('a limit value other than the defaults is honored (nothing hardcoded)', async () => {
    global.fetch.mockResolvedValueOnce(usage(12345, false));
    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNoteCharLimit(); });
    expect(result.current.noteCharInfo.limit).toBe(12345);
  });

  test('missing note_chars (older server) leaves the limit null', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ subscribed: false }) });
    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNoteCharLimit(); });
    expect(result.current.noteCharInfo).toEqual({ limit: null, subscribed: null });
  });

  test('non-ok response and network failure keep the previous value and do not throw', async () => {
    global.fetch.mockResolvedValueOnce(usage(30000, false));
    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNoteCharLimit(); });

    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    await act(async () => { await result.current.loadNoteCharLimit(); });
    expect(result.current.noteCharInfo.limit).toBe(30000);

    vi.spyOn(console, 'error').mockImplementation(() => {});
    global.fetch.mockRejectedValueOnce(new Error('offline'));
    await act(async () => { await result.current.loadNoteCharLimit(); });
    expect(result.current.noteCharInfo.limit).toBe(30000);
  });

  test('no user means no request', async () => {
    const { result } = renderHook(() => useNotes({ user: null }));
    await act(async () => { await result.current.loadNoteCharLimit(); });
    expect(global.fetch).not.toHaveBeenCalled();
  });
});

describe('useNotes.saveNote — server 403 note_chars', () => {
  const NOTE = { title: 'T', text: 'x'.repeat(40), verses: [[], []], group_id: '' };

  async function setup(plan) {
    global.fetch.mockResolvedValueOnce(usage(plan.limit, plan.subscribed));
    const hook = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await hook.result.current.loadNoteCharLimit(); });
    return hook;
  }

  test('free: returns false, shows chars over with the limit and an upgrade CTA; text kept message', async () => {
    const { result } = await setup({ limit: 30000, subscribed: false });
    global.fetch.mockResolvedValueOnce(charLimit403(30500, 30000));

    let ok;
    await act(async () => { ok = await result.current.saveNote(NOTE, null); });

    expect(ok).toBe(false);
    expect(message.warning).toHaveBeenCalledTimes(1);
    const msg = message.warning.mock.calls[0][0];
    expect(msg).toContain('30,000');
    expect(msg).toContain('500 over');
    expect(msg).toContain('your text is kept');
    expect(msg).toContain('Upgrade for a higher limit');
    // Not the weekly-count wording
    expect(msg).not.toContain('this week');
  });

  test('paid: same rejection message but NO upgrade CTA', async () => {
    const { result } = await setup({ limit: 100000, subscribed: true });
    global.fetch.mockResolvedValueOnce(charLimit403(100200, 100000));

    let ok;
    await act(async () => { ok = await result.current.saveNote(NOTE, null); });

    expect(ok).toBe(false);
    const msg = message.warning.mock.calls[0][0];
    expect(msg).toContain('100,000');
    expect(msg).toContain('200 over');
    expect(msg).not.toMatch(/upgrade/i);
  });

  test('before the plan is known (usage never loaded) there is no upgrade CTA', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    global.fetch.mockResolvedValueOnce(charLimit403(30100, 30000));
    await act(async () => { await result.current.saveNote(NOTE, null); });
    expect(message.warning.mock.calls[0][0]).not.toMatch(/upgrade/i);
  });

  test('rejected update does not touch the cached note (preserve-cache-on-failed-save)', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: { 'n1': { title: 'Orig', text: 'original body', public: false, verses: [[], []] } },
        next_cursor_created_at: null, next_cursor_id: null, has_more: false,
      }),
    });
    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNotes(); });
    await waitFor(() => expect(result.current.allNotes['n1']).toBeDefined());
    const before = result.current.allNotes['n1'];

    global.fetch.mockResolvedValueOnce(charLimit403(30500, 30000));
    let ok;
    await act(async () => { ok = await result.current.saveNote({ ...NOTE, text: 'x'.repeat(50) }, 'n1'); });

    expect(ok).toBe(false);
    expect(result.current.allNotes['n1']).toEqual(before);
    expect(result.current.allNotes['n1'].text).toBe('original body');
    // and the request was a PUT (update path)
    const putCall = global.fetch.mock.calls.find(c => c[1]?.method === 'PUT');
    expect(putCall).toBeTruthy();
  });

  test('rejected create adds nothing to the cache', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    global.fetch.mockResolvedValueOnce(charLimit403(30001, 30000));
    await act(async () => { await result.current.saveNote(NOTE, null); });
    expect(Object.keys(result.current.allNotes)).toHaveLength(0);
  });

  test('network failure keeps the cache and returns false (draft stays in the editor)', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const { result } = renderHook(() => useNotes({ user: USER }));
    global.fetch.mockRejectedValueOnce(new Error('down'));
    let ok;
    await act(async () => { ok = await result.current.saveNote(NOTE, 'n1'); });
    expect(ok).toBe(false);
    expect(message.error).toHaveBeenCalled();
    expect(result.current.allNotes['n1']).toBeUndefined();
  });

  test('the weekly notes-count 403 now opens the shared upgrade modal (no inline toast)', async () => {
    dismissUpgradePrompt();
    const { result } = renderHook(() => useNotes({ user: USER }));
    global.fetch.mockResolvedValueOnce(weekly403());
    let ok;
    await act(async () => { ok = await result.current.saveNote(NOTE, null); });
    expect(ok).toBe(false);
    expect(message.warning).not.toHaveBeenCalled();
    expect(getUpgradePrompt().info).toEqual({ resource: 'notes', paidOnly: false, used: 10, limit: 10 });
    dismissUpgradePrompt();
  });
});

describe('useNotes.postReply — 403 note_chars', () => {
  test('returns false and surfaces the char-limit message (no cache change)', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    // postReply requires a selected group; loading its notes is irrelevant here.
    global.fetch.mockResolvedValue({ ok: true, json: async () => ({ notes: {}, has_more: false }) });
    await act(async () => { await result.current.selectGroup('g1'); });
    global.fetch.mockReset();
    global.fetch.mockResolvedValueOnce(charLimit403(30040, 30000));

    let ok;
    await act(async () => { ok = await result.current.postReply('note-1', 'reply text'); });

    expect(ok).toBe(false);
    const replyCall = global.fetch.mock.calls.find(c => String(c[0]).includes('/notes/reply/note-1'));
    expect(replyCall).toBeTruthy();
    expect(message.warning).toHaveBeenCalledTimes(1);
    expect(message.warning.mock.calls[0][0]).toContain('40 over');
    expect(message.error).not.toHaveBeenCalled();
  });
});
