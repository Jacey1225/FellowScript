import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('./threadsApi.js', () => ({ listThreads: vi.fn() }));
import { listThreads } from './threadsApi.js';
import {
  canShareToThreads, loadShareThreads, shareThreadLabel, pendingShareStatus, SHARE_THREAD_CAP,
} from './threadShare.js';

const caps = (on) => ({ isEnabled: (k) => on.includes(k) });

describe('canShareToThreads', () => {
  it('needs both flags and fails closed', () => {
    expect(canShareToThreads(caps(['threads', 'chat_shared_objects']))).toBe(true);
    expect(canShareToThreads(caps(['threads']))).toBe(false);
    expect(canShareToThreads(caps(['chat_shared_objects']))).toBe(false);
    expect(canShareToThreads(null)).toBe(false);
  });
});

describe('loadShareThreads', () => {
  beforeEach(() => { listThreads.mockReset(); });
  it('caps to the most recent threads', async () => {
    listThreads.mockResolvedValue({ threads: Array.from({ length: 14 }, (_, i) => ({ id: `t${i}` })) });
    const out = await loadShareThreads('u', 'g');
    expect(out).toHaveLength(SHARE_THREAD_CAP);
    expect(out[0].id).toBe('t0');
    expect(listThreads).toHaveBeenCalledWith('u', 'g', null);
  });
  it('rejects on failure instead of returning an empty list', async () => {
    listThreads.mockImplementation(async () => { throw new Error('x'); });
    await expect(loadShareThreads('u', 'g')).rejects.toThrow();
  });
});

describe('shareThreadLabel', () => {
  it('falls back from title to root preview to Thread', () => {
    expect(shareThreadLabel({ title: 'A', root_preview: 'B' })).toBe('A');
    expect(shareThreadLabel({ root_preview: 'B' })).toBe('B');
    expect(shareThreadLabel({})).toBe('Thread');
  });
});

describe('pendingShareStatus', () => {
  const thread = { id: 't1' };
  const p = (o = {}) => ({ contactId: 'g', attachment: {}, thread, opened: true, ...o });
  const ctx = (o = {}) => ({ contact: { id: 'g' }, threadView: { thread }, threadLoad: 'idle', ...o });
  it('waits for the chat to open', () => {
    expect(pendingShareStatus(p({ opened: false }), ctx())).toBe('wait');
    expect(pendingShareStatus(p(), ctx({ contact: { id: 'other' } }))).toBe('wait');
  });
  it('sends chat shares once opened', () => {
    expect(pendingShareStatus(p({ thread: null }), ctx({ threadView: null }))).toBe('send');
  });
  it('sends thread shares only after the first page loaded', () => {
    expect(pendingShareStatus(p(), ctx({ threadLoad: 'loading' }))).toBe('wait');
    expect(pendingShareStatus(p(), ctx())).toBe('send');
  });
  it('drops (never sends) when the thread failed or vanished', () => {
    expect(pendingShareStatus(p(), ctx({ threadLoad: 'error' }))).toBe('drop');
    expect(pendingShareStatus(p(), ctx({ threadView: null }))).toBe('drop');
    expect(pendingShareStatus(p(), ctx({ threadView: { thread: { id: 'zz' } } }))).toBe('drop');
  });
});
