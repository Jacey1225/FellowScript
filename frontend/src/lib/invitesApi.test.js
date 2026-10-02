// Task 20260929-group-invite-links testing: invite API wrappers. Tokens only
// travel in POST bodies (never URL/query), every failure throws (never a
// fabricated value), and pasted-link parsing accepts only fellowscript.com.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  previewInvite, redeemInvite, listGroupInvites, createGroupInvite,
  revokeInvite, resetGroupInvites, revealGroupInvite, parseInviteInput, isWellFormedInviteToken,
  InviteApiError,
} from './invitesApi.js';

const TOKEN = 'A'.repeat(43);
const ok = (body, status = 200) => ({ ok: true, status, json: async () => body });
const fail = (status, body) => ({ ok: false, status, json: async () => body });

let fetchMock;
beforeEach(() => { fetchMock = vi.fn(); vi.stubGlobal('fetch', fetchMock); });
afterEach(() => vi.unstubAllGlobals());

describe('token placement', () => {
  test('preview sends the token only in the POST body', async () => {
    fetchMock.mockResolvedValue(ok({ group_name: 'G' }));
    await previewInvite(TOKEN);
    const [url, opts] = fetchMock.mock.calls[0];
    expect(opts.method).toBe('POST');
    expect(JSON.parse(opts.body)).toEqual({ token: TOKEN });
    expect(url).not.toContain(TOKEN);
    expect(url).not.toContain('?');
  });

  test('redeem sends the token only in the POST body', async () => {
    fetchMock.mockResolvedValue(ok({ joined: true, target_id: 'g1' }));
    await redeemInvite('u1', TOKEN);
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toContain('/invites/u1/redeem');
    expect(opts.method).toBe('POST');
    expect(JSON.parse(opts.body)).toEqual({ token: TOKEN });
    expect(url).not.toContain(TOKEN);
  });

  test('list/create/revoke/reset never put any token in a URL', async () => {
    fetchMock.mockResolvedValue(ok({ invites: [] }));
    await listGroupInvites('u', 'g');
    await createGroupInvite('u', 'g', { expiresInDays: 7, maxUses: 25 });
    await revokeInvite('u', 'inv1');
    await resetGroupInvites('u', 'g');
    for (const [url] of fetchMock.mock.calls) expect(url).not.toMatch(/token=/);
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ expires_in_days: 7, max_uses: 25 });
    expect(fetchMock.mock.calls[2][1].method).toBe('DELETE');
    expect(fetchMock.mock.calls[3][0]).toContain('/groups/g/reset');
  });
});

describe('throw-not-fabricate', () => {
  test('network failure throws InviteApiError status 0', async () => {
    fetchMock.mockRejectedValue(new TypeError('offline'));
    await expect(previewInvite(TOKEN)).rejects.toMatchObject({ name: 'InviteApiError', status: 0 });
  });

  test('non-2xx throws with status and machine code from structured detail', async () => {
    fetchMock.mockResolvedValue(fail(410, { detail: { code: 'revoked', message: 'Gone' } }));
    const err = await redeemInvite('u', TOKEN).catch((e) => e);
    expect(err).toBeInstanceOf(InviteApiError);
    expect(err).toMatchObject({ status: 410, code: 'revoked', message: 'Gone' });
  });

  test('string detail becomes the message with no code', async () => {
    fetchMock.mockResolvedValue(fail(429, { detail: 'slow down' }));
    await expect(previewInvite(TOKEN)).rejects.toMatchObject({ status: 429, code: null, message: 'slow down' });
  });

  test('non-JSON error body falls back to copy but still throws', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 500, json: async () => { throw new Error('x'); } });
    await expect(previewInvite(TOKEN)).rejects.toMatchObject({ status: 500, message: "This invite link isn't valid anymore." });
  });

  test('404 from list (flag off) throws so the UI can hide the section', async () => {
    fetchMock.mockResolvedValue(fail(404, { detail: 'Not found' }));
    await expect(listGroupInvites('u', 'g')).rejects.toMatchObject({ status: 404 });
  });

  test('204 resolves to an empty object, not undefined', async () => {
    fetchMock.mockResolvedValue({ ok: true, status: 204 });
    await expect(revokeInvite('u', 'i')).resolves.toEqual({});
  });
});

describe('token format + pasted input parsing', () => {
  test('well-formed means exactly 43 url-safe chars', () => {
    expect(isWellFormedInviteToken(TOKEN)).toBe(true);
    expect(isWellFormedInviteToken('A'.repeat(42))).toBe(false);
    expect(isWellFormedInviteToken('A'.repeat(44))).toBe(false);
    expect(isWellFormedInviteToken('A'.repeat(42) + '/')).toBe(false);
    expect(isWellFormedInviteToken(null)).toBe(false);
    expect(isWellFormedInviteToken(undefined)).toBe(false);
  });

  test('accepts the canonical URL, www, hash form, bare token, and whitespace', () => {
    expect(parseInviteInput(`https://fellowscript.com/join/${TOKEN}`)).toBe(TOKEN);
    expect(parseInviteInput(`https://fellowscript.com/join/${TOKEN}/`)).toBe(TOKEN);
    expect(parseInviteInput(`https://www.fellowscript.com/join/${TOKEN}`)).toBe(TOKEN);
    expect(parseInviteInput(`https://fellowscript.com/#/join/${TOKEN}`)).toBe(TOKEN);
    expect(parseInviteInput(`  ${TOKEN}  `)).toBe(TOKEN);
  });

  test.each([
    ['foreign host', `https://evil.com/join/${TOKEN}`],
    ['lookalike host', `https://fellowscript.com.evil.com/join/${TOKEN}`],
    ['userinfo trick', `https://fellowscript.com@evil.com/join/${TOKEN}`],
    ['http scheme', `http://fellowscript.com/join/${TOKEN}`],
    ['javascript scheme', `javascript:alert(1)//fellowscript.com/join/${TOKEN}`],
    ['extra path', `https://fellowscript.com/join/${TOKEN}/extra`],
    ['wrong prefix', `https://fellowscript.com/invite/${TOKEN}`],
    ['short token', 'https://fellowscript.com/join/abc'],
    ['bad chars', `https://fellowscript.com/join/${'A'.repeat(42)}!`],
    ['empty', ''],
    ['null', null],
    ['garbage', 'hello world'],
  ])('rejects %s', (_n, input) => {
    expect(parseInviteInput(input)).toBeNull();
  });
});

describe('revealGroupInvite', () => {
  test('GETs the reveal route with no-store and no token anywhere in the request', async () => {
    fetchMock.mockResolvedValue(ok({ url: `https://fellowscript.com/join/${TOKEN}`, invite_id: 'i1' }));
    const res = await revealGroupInvite('u1', 'i1');
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toContain('/invites/u1/i1/reveal');
    expect(opts.cache).toBe('no-store');
    expect(opts.method).toBeUndefined();
    expect(opts.body).toBeUndefined();
    expect(res.url).toContain(TOKEN);
  });

  test('404 throws InviteApiError with status 404 (never fabricates a url)', async () => {
    fetchMock.mockResolvedValue(fail(404, { detail: 'not found' }));
    await expect(revealGroupInvite('u1', 'i1')).rejects.toMatchObject({ name: 'InviteApiError', status: 404 });
  });

  test('network failure throws status 0', async () => {
    fetchMock.mockRejectedValue(new Error('offline'));
    await expect(revealGroupInvite('u1', 'i1')).rejects.toMatchObject({ status: 0 });
  });
});
