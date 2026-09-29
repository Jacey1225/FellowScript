// Task 20260929-group-info-panel testing: groupInfoApi throws on every failure
// (throw-not-fabricate) and validates photo files before any network call.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  fetchGroupInfo, renameGroup, setGroupMuted, removeGroupPhoto,
  uploadGroupPhoto, fetchGroupGallery, GroupInfoError, GROUP_PHOTO_LIMITS,
} from './groupInfoApi.js';

const ok = (body, status = 200) => ({ ok: true, status, json: async () => body });
const fail = (status, body) => ({ ok: false, status, json: async () => body });

let fetchMock;
beforeEach(() => { fetchMock = vi.fn(); vi.stubGlobal('fetch', fetchMock); });
afterEach(() => vi.unstubAllGlobals());

describe('groupInfoApi', () => {
  test('network failure throws GroupInfoError status 0, no fabricated value', async () => {
    fetchMock.mockRejectedValue(new TypeError('offline'));
    await expect(fetchGroupInfo('u', 'g')).rejects.toMatchObject({ name: 'GroupInfoError', status: 0 });
  });

  test('non-2xx throws with server detail and status', async () => {
    fetchMock.mockResolvedValue(fail(422, { detail: 'Title too long' }));
    await expect(renameGroup('u', 'g', 'x')).rejects.toMatchObject({ status: 422, message: 'Title too long' });
  });

  test('non-JSON error body falls back to copy', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 500, json: async () => { throw new Error('x'); } });
    await expect(fetchGroupInfo('u', 'g')).rejects.toMatchObject({ status: 500, message: "Couldn't refresh just now." });
  });

  test('403 surfaces status 403', async () => {
    fetchMock.mockResolvedValue(fail(403, { detail: 'no' }));
    await expect(fetchGroupInfo('u', 'g')).rejects.toBeInstanceOf(GroupInfoError);
  });

  test('mute uses PUT, unmute uses DELETE', async () => {
    fetchMock.mockResolvedValue(ok({ muted: true }));
    await setGroupMuted('u', 'g', true);
    expect(fetchMock.mock.calls[0][1].method).toBe('PUT');
    expect(fetchMock.mock.calls[0][0]).toContain('/groups/u/g/mute');
    await setGroupMuted('u', 'g', false);
    expect(fetchMock.mock.calls[1][1].method).toBe('DELETE');
  });

  test('rename sends title JSON via PUT /title', async () => {
    fetchMock.mockResolvedValue(ok({ title: 'New' }));
    await renameGroup('u', 'g', 'New');
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toContain('/groups/u/g/title');
    expect(opts.method).toBe('PUT');
    expect(JSON.parse(opts.body)).toEqual({ title: 'New' });
  });

  test('remove photo returns restore_key', async () => {
    fetchMock.mockResolvedValue(ok({ restore_key: 'group-photos/g/a' }));
    expect((await removeGroupPhoto('u', 'g')).restore_key).toBe('group-photos/g/a');
  });

  test('upload rejects oversize and bad type without any network call', async () => {
    const big = { size: GROUP_PHOTO_LIMITS.maxBytes + 1, type: 'image/png' };
    await expect(uploadGroupPhoto('u', 'g', big)).rejects.toThrow(/15MB/);
    await expect(uploadGroupPhoto('u', 'g', { size: 10, type: 'application/pdf' })).rejects.toThrow(/JPG, PNG/);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test('upload: policy -> S3 POST (no bytes to API) -> confirm with object_key', async () => {
    const file = new File(['abc'], 'a.png', { type: 'image/png' });
    fetchMock
      .mockResolvedValueOnce(ok({ url: 'https://s3.example/b', fields: { key: 'k' }, object_key: 'group-photos/g/x' }))
      .mockResolvedValueOnce({ ok: true, status: 204 })
      .mockResolvedValueOnce(ok({ photo_url: 'https://cdn/p' }));
    const res = await uploadGroupPhoto('u', 'g', file);
    expect(res.photo_url).toBe('https://cdn/p');
    expect(fetchMock.mock.calls[1][0]).toBe('https://s3.example/b');
    expect(fetchMock.mock.calls[1][1].body).toBeInstanceOf(FormData);
    expect(JSON.parse(fetchMock.mock.calls[2][1].body)).toEqual({ object_key: 'group-photos/g/x' });
  });

  test('S3 upload failure throws and never confirms', async () => {
    const file = new File(['abc'], 'a.png', { type: 'image/png' });
    fetchMock
      .mockResolvedValueOnce(ok({ url: 'https://s3.example/b', fields: {}, object_key: 'k' }))
      .mockResolvedValueOnce({ ok: false, status: 403 });
    await expect(uploadGroupPhoto('u', 'g', file)).rejects.toMatchObject({ status: 403 });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test('gallery builds kind and cursor query', async () => {
    fetchMock.mockResolvedValue(ok({ items: [] }));
    await fetchGroupGallery('u', 'g', { kind: 'image', cursor: { timestamp: 't1', id: 5 } });
    const url = fetchMock.mock.calls[0][0];
    expect(url).toContain('kind=image');
    expect(url).toContain('cursor_timestamp=t1');
    expect(url).toContain('cursor_id=5');
    await fetchGroupGallery('u', 'g');
    expect(fetchMock.mock.calls[1][0]).toMatch(/\/gallery$/);
  });
});
