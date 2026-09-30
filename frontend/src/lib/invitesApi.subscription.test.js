// Task 20260930-subscription-seat-invites testing: subscription sibling routes.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { listSubscriptionInvites, createSubscriptionInvite, resetSubscriptionInvites } from './invitesApi.js';

const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const fail = (status, body) => ({ ok: false, status, json: async () => body });
let fetchMock;
beforeEach(() => { fetchMock = vi.fn(); vi.stubGlobal('fetch', fetchMock); });
afterEach(() => vi.unstubAllGlobals());

describe('subscription invite API', () => {
  test('list/create/reset hit the sibling /subscriptions/ routes, not /groups/', async () => {
    fetchMock.mockResolvedValue(ok({ invites: [] }));
    await listSubscriptionInvites('u1', 's1');
    await createSubscriptionInvite('u1', 's1', { expiresInDays: 7, maxUses: 3 });
    await resetSubscriptionInvites('u1', 's1');
    const urls = fetchMock.mock.calls.map((c) => c[0]);
    expect(urls[0]).toMatch(/\/invites\/u1\/subscriptions\/s1$/);
    expect(urls[1]).toMatch(/\/invites\/u1\/subscriptions\/s1$/);
    expect(urls[2]).toMatch(/\/invites\/u1\/subscriptions\/s1\/reset$/);
    urls.forEach((u) => expect(u).not.toContain('/groups/'));
    expect(fetchMock.mock.calls[1][1].method).toBe('POST');
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ expires_in_days: 7, max_uses: 3 });
    expect(fetchMock.mock.calls[2][1].method).toBe('POST');
  });

  test('403 and 409 not_eligible throw with status/code (never fabricate a link)', async () => {
    fetchMock.mockResolvedValueOnce(fail(403, { detail: 'nope' }));
    await expect(createSubscriptionInvite('u', 's', { expiresInDays: 1, maxUses: 1 })).rejects.toMatchObject({ status: 403 });
    fetchMock.mockResolvedValueOnce(fail(409, { detail: { code: 'not_eligible', message: 'x' } }));
    await expect(listSubscriptionInvites('u', 's')).rejects.toMatchObject({ status: 409, code: 'not_eligible' });
    fetchMock.mockResolvedValueOnce(fail(404, { detail: 'Not found' }));
    await expect(resetSubscriptionInvites('u', 's')).rejects.toMatchObject({ status: 404 });
  });
});
