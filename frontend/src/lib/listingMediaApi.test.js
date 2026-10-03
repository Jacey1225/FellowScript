import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { precheckImage, uploadListingImage, postToS3, MediaUploadError } from './listingMediaApi.js';

const OPTS = { allowed_mime: ['image/jpeg', 'image/png', 'image/webp'], image_max_upload_bytes: 1000 };
const jsonRes = (body, status = 200) => ({ ok: status < 300, status, json: async () => body, headers: { get: () => null } });
const file = (type = 'image/png', size = 10) => new File([new Uint8Array(size)], 'p.png', { type });

let xhrs;
class FakeXHR {
  constructor() { this.upload = { addEventListener: (_n, cb) => { this.progressCb = cb; } }; xhrs.push(this); }
  open(m, u) { this.method = m; this.url = u; }
  send(body) { this.body = body; this.sent = true; }
}

beforeEach(() => { xhrs = []; vi.stubGlobal('XMLHttpRequest', FakeXHR); });
afterEach(() => { vi.unstubAllGlobals(); });

describe('precheckImage', () => {
  test('rejects type, size and empty; accepts a good file', () => {
    expect(precheckImage(file('image/gif'), OPTS)).toMatch(/JPEG, PNG or WebP/);
    expect(precheckImage(file('image/png', 5000), OPTS)).toMatch(/too large/);
    expect(precheckImage(file('image/png', 0), OPTS)).toMatch(/empty/);
    expect(precheckImage(file('image/png', 10), OPTS)).toBeNull();
    expect(precheckImage(null, OPTS)).toBeTruthy();
  });
});

describe('uploadListingImage', () => {
  test('presign, S3 POST with file last, then confirm', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonRes({ url: 'https://b.s3.amazonaws.com/', fields: { key: 'k', 'Content-Type': 'image/png' }, object_key: 'listings/p/u.png' }))
      .mockResolvedValueOnce(jsonRes({ media_id: 'm1', kind: 'banner', url: 'https://b.s3.amazonaws.com/x', alt_text: 'A' }));
    vi.stubGlobal('fetch', fetchMock);
    const stages = [];
    const p = uploadListingImage({ userId: 'u', groupId: 'g', kind: 'banner', file: file(), altText: 'A', mediaOptions: OPTS, onStage: (s) => stages.push(s) });
    await vi.waitFor(() => expect(xhrs[0]?.sent).toBe(true));
    const keys = [...xhrs[0].body.keys()];
    expect(keys).toEqual(['key', 'Content-Type', 'file']);
    xhrs[0].status = 204; xhrs[0].onload();
    const item = await p;
    expect(item.media_id).toBe('m1');
    expect(stages).toEqual(['uploading', 'processing']);
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ kind: 'banner', content_type: 'image/png' });
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ kind: 'banner', object_key: 'listings/p/u.png', alt_text: 'A' });
  });

  test('S3 failure rejects and never confirms', async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(jsonRes({ url: 'https://b.s3.amazonaws.com/', fields: {}, object_key: 'k' }));
    vi.stubGlobal('fetch', fetchMock);
    const p = uploadListingImage({ userId: 'u', groupId: 'g', kind: 'photo', file: file(), mediaOptions: OPTS });
    await vi.waitFor(() => expect(xhrs[0]?.sent).toBe(true));
    xhrs[0].status = 403; xhrs[0].onload();
    await expect(p).rejects.toBeInstanceOf(MediaUploadError);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test('confirm retry skips the S3 hop via resume.objectKey', async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(jsonRes({ media_id: 'm2', kind: 'photo', url: 'https://b.s3.amazonaws.com/y' }));
    vi.stubGlobal('fetch', fetchMock);
    await uploadListingImage({ userId: 'u', groupId: 'g', kind: 'photo', file: file(), mediaOptions: OPTS, resume: { objectKey: 'listings/p/u.png' } });
    expect(xhrs).toHaveLength(0);
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/listing\/media\/confirm$/);
  });

  test('client precheck failure makes no request', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    await expect(uploadListingImage({ userId: 'u', groupId: 'g', kind: 'photo', file: file('image/gif'), mediaOptions: OPTS })).rejects.toThrow(/JPEG/);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test('network error on S3 surfaces a message', async () => {
    const p = postToS3({ url: 'https://b.s3.amazonaws.com/', fields: {} }, file());
    xhrs[0].onerror();
    await expect(p).rejects.toThrow(/connection/);
  });
});
