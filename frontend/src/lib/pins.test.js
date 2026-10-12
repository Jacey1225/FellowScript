// Task 20261012-message-pins: pins client + pure helpers.
import { describe, test, expect, vi, afterEach } from 'vitest';
import {
  pinFields, parsePin, parsePinList, pinPreview, pinnedByLabel, pinButtonLabel, badgeText, systemLineText,
  pinMessageRequest, unpinMessageRequest, fetchPins, PinError, PIN_FALLBACK, PIN_LIST_ERROR,
} from './pins.js';
import { toMessage } from './chatPaging.js';

afterEach(() => { vi.restoreAllMocks(); });
const resp = (status, body, bad) => ({ status, ok: status >= 200 && status < 300, json: bad ? () => Promise.reject(new Error('bad')) : () => Promise.resolve(body) });
const raw = (id, over = {}) => ({
  message_id: id, pinned_by: 'ada', pinned_by_id: 'U1', pinned_at: '2026-10-12T00:00:00+00:00',
  message: { id, from_user_id: 'u2', from_user: 'bob', text: 'hello', timestamp: '2026-10-12T00:00:00.000000Z', attachment_kind: null, ...over },
});

describe('wire parsing', () => {
  test('pinFields: only booleans and the pin system kind; absent when flag off', () => {
    expect(pinFields({})).toEqual({});
    expect(pinFields({ pinned: true })).toEqual({ pinned: true });
    expect(pinFields({ pinned: 'yes' })).toEqual({});
    expect(pinFields({ system_kind: 'pin' })).toEqual({ systemKind: 'pin' });
    expect(pinFields({ system_kind: 'other' })).toEqual({});
  });
  test('history rows carry pinned/systemKind through toMessage', () => {
    expect(toMessage({ id: 'm1', text: 't', timestamp: 'x', pinned: true }, false)).toMatchObject({ pinned: true });
    expect(toMessage({ id: 'm2', text: 'pinned a message', timestamp: 'x', system_kind: 'pin', from_user: 'ada' }, false).systemKind).toBe('pin');
    expect('pinned' in toMessage({ id: 'm3', text: 't', timestamp: 'x' }, false)).toBe(false);
  });
  test('parsePin / parsePinList normalise and drop malformed rows', () => {
    expect(parsePin(raw('m1'))).toMatchObject({ messageId: 'm1', pinnedBy: 'ada', message: { from: 'bob', text: 'hello' } });
    expect(parsePin({ message_id: '', message: {} })).toBeNull();
    expect(parsePin({ message_id: 'm', message: null })).toBeNull();
    expect(parsePinList(null)).toBeNull();
    expect(parsePinList({ pins: 'x' })).toBeNull();
    const l = parsePinList({ pins: [raw('m1'), { bad: 1 }], has_more: true, count: 7 });
    expect(l.pins).toHaveLength(1);
    expect(l).toMatchObject({ hasMore: true, count: 7 });
    expect(parsePinList({ pins: [raw('m1')] }).count).toBe(1);
  });
});

describe('labels', () => {
  test('preview falls back to the attachment label', () => {
    expect(pinPreview(parsePin(raw('m', { text: '  ' , attachment_kind: 'image' })))).toBe('Photo');
    expect(pinPreview(parsePin(raw('m', { text: '', attachment_kind: null })))).toBe('Message');
    expect(pinPreview(parsePin(raw('m')))).toBe('hello');
  });
  test('pinned-by is case-insensitive for the viewer', () => {
    expect(pinnedByLabel(parsePin(raw('m')), 'u1')).toBe('Pinned by you');
    expect(pinnedByLabel(parsePin(raw('m')), 'u9')).toBe('Pinned by ada');
  });
  test('button label, badge cap, system line', () => {
    expect(pinButtonLabel(0)).toBe('Pinned messages');
    expect(pinButtonLabel(3)).toBe('Pinned messages, 3');
    expect(badgeText(120)).toBe('99+');
    expect(badgeText(4)).toBe('4');
    expect(systemLineText({ mine: true })).toBe('You pinned a message');
    expect(systemLineText({ mine: false, sender: 'Ada' })).toBe('Ada pinned a message');
    expect(systemLineText({ mine: false, sender: '', text: 'forged' })).toBe('Someone pinned a message');
  });
});

describe('requests', () => {
  test('pin and unpin hit the contract and return the new state', async () => {
    const f = vi.fn().mockResolvedValue(resp(200, { message_id: 'm1', pinned: true }));
    global.fetch = f;
    expect(await pinMessageRequest('u1', 'm1')).toBe(true);
    expect(f.mock.calls[0][0]).toMatch(/\/message-pins\/u1\/m1$/);
    expect(f.mock.calls[0][1].method).toBe('POST');
    f.mockResolvedValue(resp(200, { message_id: 'm1', pinned: false }));
    expect(await unpinMessageRequest('u1', 'm1')).toBe(false);
    expect(f.mock.calls[1][1].method).toBe('DELETE');
  });
  test.each([
    [404, {}, 'unavailable'], [429, {}, 'rate'], [403, { detail: { code: 'terms_reaccept_required' } }, 'terms'], [500, {}, 'failed'],
  ])('status %i -> %s', async (status, body, kind) => {
    global.fetch = vi.fn().mockResolvedValue(resp(status, body));
    await expect(pinMessageRequest('u1', 'm1')).rejects.toMatchObject({ kind });
  });
  test('transport error and undecodable/mismatched body throw, never fabricate', async () => {
    global.fetch = vi.fn().mockRejectedValue(new Error('net'));
    await expect(pinMessageRequest('u1', 'm1')).rejects.toBeInstanceOf(PinError);
    global.fetch = vi.fn().mockResolvedValue(resp(200, null, true));
    await expect(pinMessageRequest('u1', 'm1')).rejects.toMatchObject({ message: PIN_FALLBACK });
    global.fetch = vi.fn().mockResolvedValue(resp(200, { message_id: 'm1' }));
    await expect(unpinMessageRequest('u1', 'm1')).rejects.toMatchObject({ kind: 'failed' });
  });
  test('fetchPins builds the DM and group URLs with paging, and fails with warm copy', async () => {
    const f = vi.fn().mockResolvedValue(resp(200, { pins: [raw('m1')], has_more: false, count: 1 }));
    global.fetch = f;
    const dm = await fetchPins('u1', { type: 'friend', id: 'f1' }, { limit: 20, offset: 40 });
    expect(dm.count).toBe(1);
    expect(f.mock.calls[0][0]).toMatch(/\/message-pins\/u1\/dm\/f1\?limit=20&offset=40$/);
    await fetchPins('u1', { type: 'group', id: 'g1', group_id: 'g1' });
    expect(f.mock.calls[1][0]).toMatch(/\/message-pins\/u1\/group\/g1\?limit=20&offset=0$/);
    global.fetch = vi.fn().mockResolvedValue(resp(500, {}));
    await expect(fetchPins('u1', { type: 'friend', id: 'f1' })).rejects.toMatchObject({ kind: 'failed', message: PIN_LIST_ERROR });
    global.fetch = vi.fn().mockResolvedValue(resp(200, { nope: 1 }));
    await expect(fetchPins('u1', { type: 'friend', id: 'f1' })).rejects.toMatchObject({ message: PIN_LIST_ERROR });
    global.fetch = vi.fn().mockResolvedValue(resp(404, {}));
    await expect(fetchPins('u1', { type: 'friend', id: 'f1' })).rejects.toMatchObject({ kind: 'unavailable' });
  });
});
