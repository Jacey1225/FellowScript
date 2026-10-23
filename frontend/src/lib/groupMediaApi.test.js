import { describe, test, expect, vi, afterEach } from 'vitest';
import { fetchGroupMedia, parseMediaPage, mediaColumns, mediaCellLabel, formatDuration, GroupMediaError } from './groupMediaApi.js';

afterEach(() => { vi.restoreAllMocks(); });

const wire = (over = {}) => ({
  message_id: 'm1', kind: 'image', thumb_url: 'https://t/1', url: 'https://u/1', width: 4, height: 3,
  duration: null, sender_id: 'u2', sender_name: 'Ada', created_at: '2026-10-19T19:55:00.000000Z', ...over,
});

describe('parseMediaPage', () => {
  test('maps rows, drops unusable ones, builds the next cursor only when has_more', () => {
    const page = parseMediaPage({
      media: [wire(), wire({ message_id: undefined }), wire({ kind: 'file' }), wire({ message_id: 'm2', kind: 'video', thumb_url: null })],
      page: { has_more: true, next_cursor_timestamp: 'T', next_cursor_seq: 7, next_cursor_id: 'm2' },
    });
    expect(page.items.map((i) => i.messageId)).toEqual(['m1', 'm2']);
    expect(page.items[1].thumbUrl).toBeNull();
    expect(page.cursor).toEqual({ timestamp: 'T', seq: 7, id: 'm2' });
    expect(parseMediaPage({ media: [], page: { has_more: false, next_cursor_timestamp: 'T', next_cursor_id: 'x' } }).cursor).toBeNull();
  });
  test('a body without a media array is not a page', () => {
    expect(parseMediaPage({})).toBeNull();
    expect(parseMediaPage(null)).toBeNull();
  });
});

describe('fetchGroupMedia', () => {
  test('requests kinds, limit 30 and echoes the cursor', async () => {
    const f = vi.fn(async () => ({ ok: true, status: 200, json: async () => ({ media: [wire()], page: {} }) }));
    vi.stubGlobal('fetch', f);
    await fetchGroupMedia('u1', 'g1', { timestamp: 'T', seq: 3, id: 'm9' });
    const url = f.mock.calls[0][0];
    expect(url).toContain('/groups/u1/g1/media?');
    expect(url).toContain('limit=30');
    expect(url).toContain('kind=image%2Cvideo%2Cgif'.replace(/%2C/g, ',')) ;
    expect(url).toContain('cursor_timestamp=T');
    expect(url).toContain('cursor_seq=3');
    expect(url).toContain('cursor_id=m9');
  });
  test('throws (never fabricates) on non-2xx, network failure and undecodable bodies', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 403, json: async () => ({}) })));
    await expect(fetchGroupMedia('u1', 'g1')).rejects.toMatchObject({ name: 'GroupMediaError', status: 403 });
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('net'); }));
    await expect(fetchGroupMedia('u1', 'g1')).rejects.toBeInstanceOf(GroupMediaError);
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, status: 200, json: async () => ({ nope: 1 }) })));
    await expect(fetchGroupMedia('u1', 'g1')).rejects.toBeInstanceOf(GroupMediaError);
  });
});

describe('helpers', () => {
  test('columns by panel width', () => {
    expect([320, 599, 600, 899, 900, 1400].map(mediaColumns)).toEqual([3, 3, 4, 4, 5, 5]);
  });
  test('labels and duration', () => {
    expect(mediaCellLabel({ kind: 'video', senderName: 'Ada' }, 'Oct 19')).toBe('Video from Ada, Oct 19');
    expect(mediaCellLabel({ kind: 'gif', senderName: 'Ada' }, '')).toBe('GIF from Ada');
    expect(mediaCellLabel({ kind: 'image', senderName: 'Ada' }, 'x')).toBe('Photo from Ada, x');
    expect([65, 5, 0, null, -1].map(formatDuration)).toEqual(['1:05', '0:05', '0:00', '', '']);
  });
});
