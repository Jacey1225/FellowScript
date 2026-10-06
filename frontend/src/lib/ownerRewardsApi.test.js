// Task 20261001-promo-owner-rewards testing: API wrappers throw, never fabricate.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  createCreatorCode, listCodesOverview, deactivateCode, updateCodeEmail, fetchRewardSummary, OwnerRewardsApiError,
} from './ownerRewardsApi.js';

const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const bad = (status, body) => ({ ok: false, status, json: async () => body });

beforeEach(() => { global.fetch = vi.fn(); });
afterEach(() => { vi.restoreAllMocks(); });

describe('createCreatorCode', () => {
  test('POSTs snake_case body, omits unset optional fields', async () => {
    fetch.mockResolvedValue(ok({ code: { code: 'ABC' } }));
    await createCreatorCode({ name: 'N', ownerEmail: 'a@b.co' });
    const [url, opts] = fetch.mock.calls[0];
    expect(url).toMatch(/\/admin\/promo\/creator-codes$/);
    expect(opts.method).toBe('POST');
    expect(JSON.parse(opts.body)).toEqual({ name: 'N', notes: '', owner_email: 'a@b.co' });
  });
  test('includes code, max_redemptions, expires_at when given', async () => {
    fetch.mockResolvedValue(ok({}));
    await createCreatorCode({ name: 'N', ownerEmail: 'a@b.co', code: 'X', maxRedemptions: 5, expiresAt: '2027-01-01' });
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({ code: 'X', max_redemptions: 5, expires_at: '2027-01-01' });
  });
  test('403 throws with status and server detail', async () => {
    fetch.mockResolvedValue(bad(403, { detail: 'nope' }));
    await expect(createCreatorCode({ name: 'N', ownerEmail: 'a@b.co' })).rejects.toMatchObject({
      name: 'OwnerRewardsApiError', status: 403, message: 'nope',
    });
  });
  test('non-JSON error body falls back to default message', async () => {
    fetch.mockResolvedValue({ ok: false, status: 500, json: async () => { throw new Error('x'); } });
    await expect(createCreatorCode({ name: 'N', ownerEmail: 'a@b.co' })).rejects.toMatchObject({
      status: 500, message: "Couldn't create the code.",
    });
  });
  test('network failure throws status 0', async () => {
    fetch.mockRejectedValue(new TypeError('offline'));
    const err = await createCreatorCode({ name: 'N', ownerEmail: 'a@b.co' }).catch((e) => e);
    expect(err).toBeInstanceOf(OwnerRewardsApiError);
    expect(err.status).toBe(0);
  });
});

describe('list / deactivate / summary', () => {
  test('list builds query and returns rows', async () => {
    fetch.mockResolvedValue(ok([{ id: 1 }]));
    expect(await listCodesOverview({ kind: 'creator', limit: 10, offset: 5 })).toEqual([{ id: 1 }]);
    const url = fetch.mock.calls[0][0];
    expect(url).toContain('kind=creator');
    expect(url).toContain('limit=10');
    expect(url).toContain('offset=5');
  });
  test('list omits kind when unset', async () => {
    fetch.mockResolvedValue(ok([]));
    await listCodesOverview();
    expect(fetch.mock.calls[0][0]).not.toContain('kind=');
  });
  test('deactivate encodes id and POSTs', async () => {
    fetch.mockResolvedValue(ok({}));
    await deactivateCode('a/b');
    const [url, opts] = fetch.mock.calls[0];
    expect(url).toMatch(/\/admin\/promo\/codes\/a%2Fb\/deactivate$/);
    expect(opts.method).toBe('POST');
  });
  test('summary 404 (flag off) surfaces status 404', async () => {
    fetch.mockResolvedValue(bad(404, { detail: 'Not found' }));
    await expect(fetchRewardSummary('u1')).rejects.toMatchObject({ status: 404 });
  });
  test('summary returns data', async () => {
    fetch.mockResolvedValue(ok({ earned: 2 }));
    expect(await fetchRewardSummary('u 1')).toEqual({ earned: 2 });
    expect(fetch.mock.calls[0][0]).toMatch(/\/rewards\/u%201$/);
  });
});

// Task 20261005-creator-promo-awaiting-email
describe('optional owner email', () => {
  test('createCreatorCode omits owner_email when blank', async () => {
    fetch.mockResolvedValue(ok({}));
    await createCreatorCode({ name: 'N', ownerEmail: '' });
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ name: 'N', notes: '' });
  });
  test('updateCodeEmail PATCHes owner_email only (never active)', async () => {
    fetch.mockResolvedValue(ok({ id: 'c1' }));
    await updateCodeEmail('c 1', 'a@b.co');
    const [url, opts] = fetch.mock.calls[0];
    expect(url).toMatch(/\/admin\/promo\/codes\/c%201$/);
    expect(opts.method).toBe('PATCH');
    expect(JSON.parse(opts.body)).toEqual({ owner_email: 'a@b.co' });
  });
  test('updateCodeEmail blank sends null (remove)', async () => {
    fetch.mockResolvedValue(ok({}));
    await updateCodeEmail('c1', '');
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ owner_email: null });
  });
  test('updateCodeEmail 422 throws with server detail', async () => {
    fetch.mockResolvedValue(bad(422, { detail: 'owner_email is not a valid email address' }));
    await expect(updateCodeEmail('c1', 'x')).rejects.toMatchObject({ status: 422, message: 'owner_email is not a valid email address' });
  });
});
