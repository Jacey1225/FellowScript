// Task 20260929-group-announcements testing: announcementsApi throws on every
// failure (throw-not-fabricate), surfaces the free-limit gate, and validates
// banner files before any network call.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  fetchAnnouncements, createAnnouncement, updateAnnouncement, deleteAnnouncement,
  uploadAnnouncementBanner, AnnouncementsError, ANNOUNCEMENT_LIMITS,
} from './announcementsApi.js';

const ok = (body, status = 200) => ({ ok: true, status, json: async () => body });
const fail = (status, body) => ({ ok: false, status, json: async () => body });
let fetchMock;
beforeEach(() => { fetchMock = vi.fn(); vi.stubGlobal('fetch', fetchMock); });
afterEach(() => vi.unstubAllGlobals());

describe('announcementsApi', () => {
  test('network failure throws status 0, no fabricated list', async () => {
    fetchMock.mockRejectedValue(new TypeError('offline'));
    await expect(fetchAnnouncements('u', 'g')).rejects.toMatchObject({ name: 'AnnouncementsError', status: 0 });
  });

  test('non-2xx throws with server string detail and status', async () => {
    fetchMock.mockResolvedValue(fail(422, { detail: 'Title not allowed' }));
    await expect(createAnnouncement('u', 'g', {})).rejects.toMatchObject({ status: 422, message: 'Title not allowed', gate: null });
  });

  test('free-limit 403 exposes the gate object and keeps fallback message', async () => {
    const gate = { resource: 'announcements', allowed: false, used: 1, limit: 1 };
    fetchMock.mockResolvedValue(fail(403, { detail: gate }));
    const err = await createAnnouncement('u', 'g', {}).catch(e => e);
    expect(err).toBeInstanceOf(AnnouncementsError);
    expect(err.status).toBe(403);
    expect(err.gate).toEqual(gate);
    expect(err.message).toBe("That didn't save. Please try again.");
  });

  test('plain 403 (non-member) has no gate', async () => {
    fetchMock.mockResolvedValue(fail(403, { detail: 'Not a member' }));
    await expect(fetchAnnouncements('u', 'g')).rejects.toMatchObject({ status: 403, gate: null });
  });

  test('non-JSON error body falls back to copy', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 500, json: async () => { throw new Error('x'); } });
    await expect(fetchAnnouncements('u', 'g')).rejects.toMatchObject({ status: 500, message: "Couldn't load announcements." });
  });

  test('CRUD verbs, urls and bodies', async () => {
    fetchMock.mockResolvedValue(ok({ id: 'a1' }));
    await fetchAnnouncements('u', 'g');
    expect(fetchMock.mock.calls[0][0]).toContain('/groups/u/g/announcements');
    expect(fetchMock.mock.calls[0][1]).toBeUndefined();
    await createAnnouncement('u', 'g', { title: 't', description: 'd' });
    expect(fetchMock.mock.calls[1][1].method).toBe('POST');
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ title: 't', description: 'd' });
    await updateAnnouncement('u', 'g', 'a1', { banner_key: null });
    expect(fetchMock.mock.calls[2][0]).toContain('/groups/u/g/announcements/a1');
    expect(fetchMock.mock.calls[2][1].method).toBe('PUT');
    expect(JSON.parse(fetchMock.mock.calls[2][1].body)).toEqual({ banner_key: null });
    await deleteAnnouncement('u', 'g', 'a1');
    expect(fetchMock.mock.calls[3][1].method).toBe('DELETE');
  });

  test('204 delete resolves to empty object', async () => {
    fetchMock.mockResolvedValue({ ok: true, status: 204, json: async () => { throw new Error('no body'); } });
    await expect(deleteAnnouncement('u', 'g', 'a1')).resolves.toEqual({});
  });

  test('banner upload rejects oversize and bad type with no network call', async () => {
    const big = new File(['x'], 'a.png', { type: 'image/png' });
    Object.defineProperty(big, 'size', { value: ANNOUNCEMENT_LIMITS.bannerMaxBytes + 1 });
    await expect(uploadAnnouncementBanner('u', 'g', big)).rejects.toMatchObject({ status: 0 });
    await expect(uploadAnnouncementBanner('u', 'g', new File(['x'], 'a.gif', { type: 'image/gif' }))).rejects.toBeInstanceOf(AnnouncementsError);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test('banner upload: presign then POST fields+file to url, returns object key', async () => {
    fetchMock
      .mockResolvedValueOnce(ok({ url: 'https://s3/x', fields: { key: 'k', policy: 'p' }, object_key: 'group-announcements/g/abc' }))
      .mockResolvedValueOnce({ ok: true, status: 204 });
    const key = await uploadAnnouncementBanner('u', 'g', new File(['x'], 'a.png', { type: 'image/png' }));
    expect(key).toBe('group-announcements/g/abc');
    expect(fetchMock.mock.calls[0][0]).toContain('/groups/u/g/announcements/banner/upload-url');
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toMatchObject({ content_type: 'image/png', size_bytes: 1 });
    const [url, opts] = fetchMock.mock.calls[1];
    expect(url).toBe('https://s3/x');
    expect(opts.body.get('key')).toBe('k');
    expect(opts.body.get('file')).toBeInstanceOf(File);
  });

  test('banner upload: failed S3 POST throws, no key returned', async () => {
    fetchMock
      .mockResolvedValueOnce(ok({ url: 'https://s3/x', fields: {}, object_key: 'k' }))
      .mockResolvedValueOnce({ ok: false, status: 403 });
    await expect(uploadAnnouncementBanner('u', 'g', new File(['x'], 'a.png', { type: 'image/png' })))
      .rejects.toMatchObject({ status: 403 });
  });
});
