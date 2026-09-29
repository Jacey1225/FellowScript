// Task 20260929-announcement-banner-crop-list-style testing: pure crop math,
// canvas encode, and remote-source resolution (throw-not-fabricate).
// Run: cd frontend && npx vitest run src/lib/cropBanner.test.js
import { describe, test, expect, vi, afterEach } from 'vitest';
import { ANNOUNCEMENT_LIMITS } from './announcementsApi.js';
import {
  BannerCropError, frameHeight, coverScale, clampOffset, centeredOffset, zoomAround, cropRect,
  outputSize, cropToFile, resolveCropSource,
} from './cropBanner.js';

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('constants', () => {
  test('canonical aspect is 3:1 and output is 1536x512', () => {
    expect(ANNOUNCEMENT_LIMITS.bannerAspect).toBe(3);
    expect(outputSize()).toEqual({ w: 1536, h: 512 });
    expect(frameHeight(300)).toBe(100);
  });
});

describe('cover scale / offsets', () => {
  test('coverScale picks the larger axis ratio', () => {
    expect(coverScale(3000, 3000, 300, 100)).toBeCloseTo(0.1);   // tall/square photo: width-bound
    expect(coverScale(6000, 1000, 300, 100)).toBeCloseTo(0.1);   // very wide: height-bound
    expect(coverScale(600, 200, 300, 100)).toBeCloseTo(0.5);
  });

  test('centeredOffset centres a tall photo vertically and never leaves empty edges', () => {
    const nat = { w: 1000, h: 4000 }; const fw = 300; const fh = 100;
    const off = centeredOffset(nat.w, nat.h, fw, fh, 1);
    const scale = coverScale(nat.w, nat.h, fw, fh);
    expect(off.x).toBeCloseTo(0);
    expect(off.y).toBeCloseTo((fh - nat.h * scale) / 2);
    expect(off.y).toBeLessThanOrEqual(0);
    expect(nat.h * scale + off.y).toBeGreaterThanOrEqual(fh - 1e-6);
  });

  test('clampOffset keeps image covering the frame on every side', () => {
    const nat = { w: 1000, h: 1000 }; const fw = 300; const fh = 100;
    const dw = nat.w * coverScale(nat.w, nat.h, fw, fh); // 300
    const dh = nat.h * coverScale(nat.w, nat.h, fw, fh); // 300
    expect(clampOffset({ x: 50, y: 50 }, nat.w, nat.h, fw, fh, 1)).toEqual({ x: 0, y: 0 });
    const far = clampOffset({ x: -9999, y: -9999 }, nat.w, nat.h, fw, fh, 1);
    expect(far.x).toBeCloseTo(fw - dw);
    expect(far.y).toBeCloseTo(fh - dh);
  });

  test('exact-aspect image at zoom 1 has zero pan range', () => {
    const o = clampOffset({ x: -40, y: 30 }, 600, 200, 300, 100, 1);
    expect(o.x + 0).toBeCloseTo(0); expect(o.y + 0).toBeCloseTo(0);
  });
});

describe('zoomAround', () => {
  const nat = { w: 2000, h: 1000 }; const fw = 300; const fh = 100;

  test('clamps zoom to [1, zoomMax]', () => {
    const s = { zoom: 1, offset: centeredOffset(nat.w, nat.h, fw, fh, 1) };
    expect(zoomAround(s, 99, { x: 150, y: 50 }, nat.w, nat.h, fw, fh).zoom).toBe(ANNOUNCEMENT_LIMITS.cropZoomMax);
    expect(zoomAround(s, 0.2, { x: 150, y: 50 }, nat.w, nat.h, fw, fh).zoom).toBe(1);
  });

  test('keeps the anchor over the same image pixel', () => {
    const s = { zoom: 1, offset: centeredOffset(nat.w, nat.h, fw, fh, 1) };
    const anchor = { x: 220, y: 40 };
    const base = coverScale(nat.w, nat.h, fw, fh);
    const before = { x: (anchor.x - s.offset.x) / base, y: (anchor.y - s.offset.y) / base };
    const next = zoomAround(s, 2, anchor, nat.w, nat.h, fw, fh);
    const after = { x: (anchor.x - next.offset.x) / (base * 2), y: (anchor.y - next.offset.y) / (base * 2) };
    expect(after.x).toBeCloseTo(before.x, 3);
    expect(after.y).toBeCloseTo(before.y, 3);
  });

  test('result offset always still covers the frame', () => {
    const s = { zoom: 1, offset: { x: 0, y: 0 } };
    const r = zoomAround(s, 3, { x: 0, y: 0 }, nat.w, nat.h, fw, fh);
    expect(r.offset).toEqual(clampOffset(r.offset, nat.w, nat.h, fw, fh, r.zoom));
  });
});

describe('cropRect', () => {
  test('zoom 1 on an exact 3:1 image is the whole image', () => {
    const r = cropRect({ zoom: 1, offset: { x: 0, y: 0 } }, 900, 300, 300, 100);
    expect(r).toEqual({ sx: 0, sy: 0, sw: 900, sh: 300 });
  });

  test('crop rect always has 3:1 aspect and stays inside the image', () => {
    const nat = { w: 1000, h: 4000 }; const fw = 300; const fh = 100;
    for (const zoom of [1, 1.7, 4]) {
      let off = clampOffset({ x: -9999, y: -9999 }, nat.w, nat.h, fw, fh, zoom);
      const r = cropRect({ zoom, offset: off }, nat.w, nat.h, fw, fh);
      expect(r.sw / r.sh).toBeCloseTo(3, 5);
      expect(r.sx).toBeGreaterThanOrEqual(0);
      expect(r.sy).toBeGreaterThanOrEqual(0);
      expect(r.sx + r.sw).toBeLessThanOrEqual(nat.w + 1e-6);
      expect(r.sy + r.sh).toBeLessThanOrEqual(nat.h + 1e-6);
    }
  });

  test('panned to the top-left shows the top-left region; zoom 2 halves the source size', () => {
    const r = cropRect({ zoom: 2, offset: { x: 0, y: 0 } }, 1000, 1000, 300, 100);
    expect(r.sx).toBe(0); expect(r.sy).toBe(0);
    expect(r.sw).toBeCloseTo(500); expect(r.sh).toBeCloseTo(500 / 3);
  });
});

describe('cropToFile', () => {
  function stubCanvas({ blob = new Blob(['jpg'], { type: 'image/jpeg' }), drawThrows = false, noCtx = false } = {}) {
    const ctx = { fillRect: vi.fn(), drawImage: vi.fn(() => { if (drawThrows) throw new Error('bad'); }), fillStyle: '' };
    const canvas = { width: 0, height: 0, getContext: vi.fn(() => (noCtx ? null : ctx)), toBlob: vi.fn((cb) => cb(blob)) };
    const real = document.createElement.bind(document);
    vi.spyOn(document, 'createElement').mockImplementation((t) => (t === 'canvas' ? canvas : real(t)));
    return { ctx, canvas };
  }

  test('draws the rect into a 1536x512 canvas and returns a JPEG File', async () => {
    const { ctx, canvas } = stubCanvas();
    const file = await cropToFile({}, { sx: 10, sy: 20, sw: 300, sh: 100 }, 'holiday.HEIC');
    expect(canvas.width).toBe(1536); expect(canvas.height).toBe(512);
    expect(ctx.fillRect).toHaveBeenCalledWith(0, 0, 1536, 512); // flatten transparency
    expect(ctx.drawImage).toHaveBeenCalledWith(expect.anything(), 10, 20, 300, 100, 0, 0, 1536, 512);
    expect(canvas.toBlob).toHaveBeenCalledWith(expect.any(Function), 'image/jpeg', 0.85);
    expect(file).toBeInstanceOf(File);
    expect(file.type).toBe('image/jpeg');
    expect(file.name).toBe('holiday.jpg');
  });

  test('throws BannerCropError (never fabricates) when no 2d context, draw fails, or encode yields null', async () => {
    stubCanvas({ noCtx: true });
    await expect(cropToFile({}, { sx: 0, sy: 0, sw: 3, sh: 1 })).rejects.toMatchObject({ name: 'BannerCropError', code: 'encode' });
    vi.restoreAllMocks();
    stubCanvas({ drawThrows: true });
    await expect(cropToFile({}, { sx: 0, sy: 0, sw: 3, sh: 1 })).rejects.toBeInstanceOf(BannerCropError);
    vi.restoreAllMocks();
    stubCanvas({ blob: null });
    await expect(cropToFile({}, { sx: 0, sy: 0, sw: 3, sh: 1 })).rejects.toMatchObject({ code: 'encode' });
  });
});

describe('resolveCropSource', () => {
  test('a picked file becomes an object URL and keeps its name', async () => {
    vi.stubGlobal('URL', Object.assign(function () {}, { createObjectURL: vi.fn(() => 'blob:abc'), revokeObjectURL: vi.fn() }));
    const f = new File(['x'], 'a.png', { type: 'image/png' });
    expect(await resolveCropSource({ file: f })).toEqual({ objectUrl: 'blob:abc', name: 'a.png' });
  });

  test('blob: and data: urls pass through unowned', async () => {
    expect(await resolveCropSource({ url: 'blob:zzz' })).toMatchObject({ objectUrl: 'blob:zzz', owned: false });
  });

  test('no source throws decode error', async () => {
    await expect(resolveCropSource({})).rejects.toMatchObject({ code: 'decode' });
  });

  test('remote fetch blocked (CORS/network) throws the Replace photo error', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')));
    await expect(resolveCropSource({ url: 'https://cdn.example/b.jpg' }))
      .rejects.toMatchObject({ code: 'cors', message: "Can't re-crop this banner. Choose Replace photo instead." });
  });

  test('remote non-ok response throws the same error', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false }));
    await expect(resolveCropSource({ url: 'https://cdn.example/b.jpg' })).rejects.toMatchObject({ code: 'cors' });
  });

  test('remote ok response is fetched with cors/omit and turned into an object URL', async () => {
    const blob = new Blob(['x']);
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, blob: async () => blob });
    vi.stubGlobal('fetch', fetchMock);
    vi.stubGlobal('URL', Object.assign(function () {}, { createObjectURL: vi.fn(() => 'blob:remote'), revokeObjectURL: vi.fn() }));
    const r = await resolveCropSource({ url: 'https://cdn.example/b.jpg' });
    expect(fetchMock).toHaveBeenCalledWith('https://cdn.example/b.jpg', { mode: 'cors', credentials: 'omit' });
    expect(r.objectUrl).toBe('blob:remote');
  });
});
