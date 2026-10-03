// Task 20261003-web-reader-ios-parity step 2. Run: npm test -- --run src/lib/ringApi.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { ringMembers, rowStateFromResult, RingError } from './ringApi.js';

beforeEach(() => { global.fetch = vi.fn(); });

describe('ringMembers', () => {
  test('posts the contract body and returns the results map', async () => {
    global.fetch.mockResolvedValue({ ok: true, status: 200, json: async () => ({ results: { a: { sent: true, reason: null } } }) });
    const r = await ringMembers('me', 's1', ['a']);
    expect(r).toEqual({ a: { sent: true, reason: null } });
    const [url, init] = global.fetch.mock.calls[0];
    expect(url).toMatch(/\/devotions\/ring$/);
    expect(JSON.parse(init.body)).toEqual({ devotion_id: 's1', user_id: 'me', target_ids: ['a'] });
  });
  test('404 (ring disabled) throws a distinct message', async () => {
    global.fetch.mockResolvedValue({ ok: false, status: 404, json: async () => ({}) });
    await expect(ringMembers('me', 's1', ['a'])).rejects.toMatchObject({ status: 404, message: 'Ringing is not available right now.' });
  });
  test('network failure and malformed bodies throw RingError', async () => {
    global.fetch.mockRejectedValue(new Error('x'));
    await expect(ringMembers('me', 's1', ['a'])).rejects.toBeInstanceOf(RingError);
    global.fetch.mockResolvedValue({ ok: true, status: 200, json: async () => ({ nope: 1 }) });
    await expect(ringMembers('me', 's1', ['a'])).rejects.toBeInstanceOf(RingError);
  });
});

describe('rowStateFromResult', () => {
  test.each([
    [{ sent: true, reason: null }, { kind: 'sent' }],
    [{ sent: false, reason: 'rate_limited' }, { kind: 'rateLimited' }],
    [{ sent: false, reason: 'unreachable' }, { kind: 'error', caption: 'Not reachable' }],
    [{ sent: false, reason: 'no_voip_token' }, { kind: 'error', caption: "Can't ring this device" }],
    [{ sent: false, reason: 'send_failed' }, { kind: 'error', caption: "Couldn't send" }],
    [{ sent: false, reason: 'not_a_member' }, { kind: 'error', caption: 'Unavailable' }],
    [undefined, { kind: 'error', caption: "Couldn't send" }],
  ])('%j', (input, expected) => {
    expect(rowStateFromResult(input)).toEqual(expected);
  });
});
