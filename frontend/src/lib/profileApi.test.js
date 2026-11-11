// Task 20261030-user-profiles testing step 8: throw-not-fabricate API wrappers.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  fetchProfile, saveBio, sendFriendRequest, acceptFriendRequest, unfriend,
  blockProfile, reportProfile, ProfileApiError, BIO_MAX_LENGTH,
} from './profileApi.js';

const res = (body, status = 200, ok = status >= 200 && status < 300) => ({ ok, status, json: async () => body });

let fetchMock;
beforeEach(() => { fetchMock = vi.fn(); vi.stubGlobal('fetch', fetchMock); });
afterEach(() => vi.unstubAllGlobals());

describe('profileApi', () => {
  test('BIO_MAX_LENGTH mirrors the server (160)', () => {
    expect(BIO_MAX_LENGTH).toBe(160);
  });

  test('fetchProfile GETs /profiles/{id} and returns the body', async () => {
    fetchMock.mockResolvedValue(res({ user_id: 't', username: 'ann' }));
    await expect(fetchProfile('t')).resolves.toEqual({ user_id: 't', username: 'ann' });
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/profiles\/t$/);
  });

  test('ids are URL-encoded (no path injection)', async () => {
    fetchMock.mockResolvedValue(res({}));
    await fetchProfile('a/b?c');
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/profiles\/a%2Fb%3Fc$/);
  });

  test('404 throws ProfileApiError with status 404 (never returns a fake profile)', async () => {
    fetchMock.mockResolvedValue(res({ detail: 'User not found' }, 404));
    await expect(fetchProfile('t')).rejects.toMatchObject({ name: 'ProfileApiError', status: 404, message: 'User not found' });
  });

  test('500 with a non-JSON body falls back to the generic copy', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 500, json: async () => { throw new Error('bad json'); } });
    await expect(fetchProfile('t')).rejects.toMatchObject({ status: 500, message: "Couldn't load this profile." });
  });

  test('network failure throws status 0', async () => {
    fetchMock.mockRejectedValue(new TypeError('network'));
    const err = await fetchProfile('t').catch((e) => e);
    expect(err).toBeInstanceOf(ProfileApiError);
    expect(err.status).toBe(0);
  });

  test('saveBio PUTs exactly {bio} and returns the stored value', async () => {
    fetchMock.mockResolvedValue(res({ bio: 'Hi there' }));
    await expect(saveBio('me', 'Hi  there')).resolves.toEqual({ bio: 'Hi there' });
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toMatch(/\/profile\/me\/bio$/);
    expect(opts.method).toBe('PUT');
    expect(JSON.parse(opts.body)).toEqual({ bio: 'Hi  there' });
  });

  test('saveBio surfaces the server detail on 422', async () => {
    fetchMock.mockResolvedValue(res({ detail: 'Bios are plain text.' }, 422));
    await expect(saveBio('me', 'x')).rejects.toMatchObject({ status: 422, message: 'Bios are plain text.' });
  });

  test('204 responses resolve to an empty object', async () => {
    fetchMock.mockResolvedValue({ ok: true, status: 204, json: async () => { throw new Error('no body'); } });
    await expect(sendFriendRequest('t')).resolves.toEqual({});
    await expect(acceptFriendRequest('t')).resolves.toEqual({});
    expect(fetchMock.mock.calls[0][1].method).toBe('POST');
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/profiles\/t\/friend-request$/);
    expect(fetchMock.mock.calls[1][0]).toMatch(/\/profiles\/t\/friend-accept$/);
  });

  test('429 is a thrown ProfileApiError with status 429', async () => {
    fetchMock.mockResolvedValue(res({ detail: 'Too many requests. Please try again later.' }, 429));
    await expect(sendFriendRequest('t')).rejects.toMatchObject({ status: 429 });
  });

  test('unfriend and block hit the existing endpoints', async () => {
    fetchMock.mockResolvedValue(res({}));
    await unfriend('me', 'f');
    await blockProfile('me', 'f');
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/friends\/me\/f$/);
    expect(fetchMock.mock.calls[0][1].method).toBe('DELETE');
    expect(fetchMock.mock.calls[1][0]).toMatch(/\/blocks\/me\/f$/);
    expect(fetchMock.mock.calls[1][1].method).toBe('POST');
  });

  test('reportProfile posts a user report', async () => {
    fetchMock.mockResolvedValue(res({}));
    await reportProfile('t', 'spam', 'details');
    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body).toEqual({ content_type: 'user', reported_user_id: 't', reason: 'spam', detail: 'details' });
  });
});
