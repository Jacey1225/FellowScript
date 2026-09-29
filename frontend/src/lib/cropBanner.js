// Task 20260929-announcement-banner-crop-list-style. Pure crop math plus the
// canvas encode step for the announcement banner cropper. Everything here
// throws on failure (throw-not-fabricate): callers must never upload an
// uncropped or wrongly cropped file as a fallback.
import { ANNOUNCEMENT_LIMITS } from './announcementsApi.js';

export class BannerCropError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'BannerCropError';
    this.code = code; // 'decode' | 'cors' | 'encode'
  }
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

export const frameHeight = (frameW, aspect = ANNOUNCEMENT_LIMITS.bannerAspect) => frameW / aspect;

// Scale at which the image exactly covers the frame (zoom 1).
export function coverScale(natW, natH, frameW, frameH) {
  return Math.max(frameW / natW, frameH / natH);
}

// Offset = top-left of the displayed image relative to the frame's top-left.
// Clamped so the image always covers the frame (no empty edges).
export function clampOffset(offset, natW, natH, frameW, frameH, zoom) {
  const scale = coverScale(natW, natH, frameW, frameH) * zoom;
  const dw = natW * scale;
  const dh = natH * scale;
  return {
    x: clamp(offset.x, Math.min(0, frameW - dw), 0),
    y: clamp(offset.y, Math.min(0, frameH - dh), 0),
  };
}

export function centeredOffset(natW, natH, frameW, frameH, zoom = 1) {
  const scale = coverScale(natW, natH, frameW, frameH) * zoom;
  return clampOffset({ x: (frameW - natW * scale) / 2, y: (frameH - natH * scale) / 2 }, natW, natH, frameW, frameH, zoom);
}

// Change zoom while keeping the frame-space `anchor` point fixed over the same
// image pixel. Returns clamped { zoom, offset }.
export function zoomAround(state, nextZoom, anchor, natW, natH, frameW, frameH, zoomMax = ANNOUNCEMENT_LIMITS.cropZoomMax) {
  const zoom = clamp(nextZoom, 1, zoomMax);
  const base = coverScale(natW, natH, frameW, frameH);
  const oldScale = base * state.zoom;
  const newScale = base * zoom;
  const imgX = (anchor.x - state.offset.x) / oldScale;
  const imgY = (anchor.y - state.offset.y) / oldScale;
  const offset = clampOffset({ x: anchor.x - imgX * newScale, y: anchor.y - imgY * newScale }, natW, natH, frameW, frameH, zoom);
  return { zoom, offset };
}

// Source rectangle in natural image pixels that the frame currently shows.
export function cropRect(state, natW, natH, frameW, frameH) {
  const scale = coverScale(natW, natH, frameW, frameH) * state.zoom;
  const sw = Math.min(natW, frameW / scale);
  const sh = Math.min(natH, frameH / scale);
  return {
    sx: clamp(-state.offset.x / scale, 0, natW - sw),
    sy: clamp(-state.offset.y / scale, 0, natH - sh),
    sw,
    sh,
  };
}

export function outputSize() {
  const w = ANNOUNCEMENT_LIMITS.bannerOutputWidth;
  return { w, h: Math.round(w / ANNOUNCEMENT_LIMITS.bannerAspect) };
}

// Draw the cropped region of a decoded image/bitmap into a canvas at the
// canonical size and encode a JPEG File. Re-encoding strips EXIF/location and
// flattens transparency onto a dark ground.
export async function cropToFile(source, rect, name = 'banner.jpg') {
  const { w, h } = outputSize();
  const canvas = document.createElement('canvas');
  canvas.width = w; canvas.height = h;
  const ctx = canvas.getContext?.('2d');
  if (!ctx) throw new BannerCropError("Couldn't process this photo. Try a different one.", 'encode');
  ctx.fillStyle = '#141414';
  ctx.fillRect(0, 0, w, h);
  try {
    ctx.drawImage(source, rect.sx, rect.sy, rect.sw, rect.sh, 0, 0, w, h);
  } catch (err) {
    throw new BannerCropError("Couldn't process this photo. Try a different one.", 'encode');
  }
  const blob = await new Promise((resolve) => {
    try { canvas.toBlob(resolve, 'image/jpeg', ANNOUNCEMENT_LIMITS.bannerJpegQuality); } catch (err) { resolve(null); }
  });
  if (!blob) throw new BannerCropError("Couldn't save the crop. Try again.", 'encode');
  return new File([blob], name.replace(/\.[^.]+$/, '') + '.jpg', { type: 'image/jpeg' });
}

// Resolve a crop source ({ file } or { url }) to a same-origin object URL that
// is safe to draw on a canvas. A remote banner is fetched as a blob; if the
// CDN blocks that (CORS) we throw so the caller can offer "Replace photo".
export async function resolveCropSource({ file, url }) {
  if (file) return { objectUrl: URL.createObjectURL(file), name: file.name || 'banner.jpg' };
  if (!url) throw new BannerCropError("Couldn't open this photo.", 'decode');
  if (url.startsWith('blob:') || url.startsWith('data:')) return { objectUrl: url, name: 'banner.jpg', owned: false };
  let res;
  try {
    res = await fetch(url, { mode: 'cors', credentials: 'omit' });
  } catch (err) {
    throw new BannerCropError("Can't re-crop this banner. Choose Replace photo instead.", 'cors');
  }
  if (!res.ok) throw new BannerCropError("Can't re-crop this banner. Choose Replace photo instead.", 'cors');
  const blob = await res.blob();
  return { objectUrl: URL.createObjectURL(blob), name: 'banner.jpg' };
}
