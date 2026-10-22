// Palette, liquid-field blob table and the text-contrast luminance rule for the
// hero's end state (task 20261022-hands-scroll-grain-gradient, design spec section
// 3). Pure data and maths, no DOM, so the component and tests share one source.
// The palette follows the reference .mov (white flash, pale cyan, teal, deep
// navy). To revert to the old brown/honey end state change only this block.
export const FIELD_WHITE = '#FCFFFC'; // pure white frame, mov 1.5-1.65 s
export const FIELD_PALE = '#CBE5F0'; // wash / orb feather tint
export const FIELD_BASE = '#1B3B64'; // zone base (mov centre at 2.4 s)
export const FIELD_ZONE_MAX = '#2D6485'; // lightest colour allowed under text (L .110)
export const FIELD_TEAL_HI = '#4396AC';
export const FIELD_TEAL_MID = '#397F9B';
export const FIELD_TEAL_LO = '#2F6C8C';
export const FIELD_NAVY = '#14294E';
export const FIELD_NAVY_DEEP = '#030C28';
export const FIELD_END = '#0E2144'; // join colour handed to .hm-fam
export const FIELD_CAP = FIELD_WHITE; // bloom can never clamp lighter than the white flash
export const FIELD_INK = '#F7FBFC'; // text on the field
export const FIELD_ORB_RING_A = '#4C689F'; // violet-blue ring (mov 1.9 s)
export const FIELD_ORB_RING_B = '#4E85A7'; // teal-blue ring

// Static underlayer. The first layer pins the bottom edge to FIELD_END so the join with
// .hm-fam is seamless (it is repeated as .adam-liquid::before above the blobs).
export const FIELD_BOTTOM_FADE = `linear-gradient(180deg, rgba(14,33,68,0) 86%, ${FIELD_END} 100%)`;
export const FIELD_UNDER = `${FIELD_BOTTOM_FADE}, linear-gradient(135deg, #3A809C 0%, ${FIELD_TEAL_LO} 12%, #2A5A7E 30%, ${FIELD_BASE} 48%, ${FIELD_NAVY} 70%, #0A1A3A 92%, ${FIELD_END} 100%)`;
export const FIELD_UNDER_MOBILE = FIELD_UNDER.replace('135deg', '160deg');
export const FIELD_GRAIN_OPACITY = 0.40;
// Monochrome (colourless) grain tile, opaque grey from the noise red channel,
// drawn with soft-light over the field so it never shifts hue or the mean.
export const FIELD_GRAIN_URL = `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='220' height='220'><filter id='g' x='0' y='0' width='100%' height='100%' color-interpolation-filters='sRGB'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3' stitchTiles='stitch'/><feColorMatrix values='1 0 0 0 0  1 0 0 0 0  1 0 0 0 0  0 0 0 0 1'/></filter><rect width='220' height='220' filter='url(%23g)' opacity='${FIELD_GRAIN_OPACITY}'/></svg>")`;

// Fallback strip: ink down into the field; last stop is exactly FIELD_BASE (the block's first colour).
export const FALLBACK_GRADIENT = `#17120F 0%, #10192B 35%, ${FIELD_NAVY} 70%, ${FIELD_BASE} 100%`;

// Blob table, hand-placed and identical in SSR and client (no PRNG during render).
// x,y = centre in % of the field; w,h = size in % of the field; r = rotation deg;
// a = peak alpha; t = half-cycle drift seconds; dx (cqw), dy (cqh), dr (deg) = drift;
// m = shown on mobile; g = mobile size multiplier; s = teal highlight (fades in with the
// settle beat); l = optional second lobe [px, py, rx, ry] in % of the element box.
export const ADAM_LOBE_K = 0.6;
export const FIELD_BLOBS = [
  // static dark, zone-safe (no lighter than FIELD_BASE, or a tiny lift)
  { c: '#071733', a: 0.85, x: 38, y: 54, w: 90, h: 52, r: -14, t: 24, dx: 16, dy: -8, dr: 22, m: true, g: 1.25, l: [62, 40, 28, 28] },
  { c: '#1F4A70', a: 0.30, x: 72, y: 58, w: 60, h: 38, r: 26, t: 17, dx: -18, dy: 6, dr: -25, m: true, g: 1.25, l: [36, 58, 26, 28] },
  { c: '#0B1F42', a: 0.80, x: 58, y: 30, w: 44, h: 30, r: -40, t: 19, dx: 12, dy: 12, dr: 18, m: false, g: 1, l: [38, 58, 26, 26] },
  { c: '#245275', a: 0.20, x: 14, y: 66, w: 36, h: 22, r: 12, t: 21, dx: 10, dy: -10, dr: 10, m: false, g: 1.25 },
  { c: FIELD_NAVY_DEEP, a: 0.95, x: 92, y: 84, w: 80, h: 66, r: -20, t: 26, dx: -9, dy: -7, dr: 14, m: true, g: 1.2 },
  { c: '#2A5A7E', a: 0.45, x: 3, y: 58, w: 16, h: 30, r: 20, t: 14, dx: 5, dy: -8, dr: 12, m: false, g: 1 },
  // teal highlights (s): kept out of the text zone so the lift budget holds
  { c: FIELD_TEAL_HI, a: 0.95, x: 46, y: 1, w: 62, h: 36, r: -6, t: 27, dx: 14, dy: 5, dr: 8, m: true, g: 1, s: true },
  { c: FIELD_TEAL_MID, a: 0.90, x: 6, y: 3, w: 34, h: 20, r: 12, t: 23, dx: 7, dy: 4, dr: -10, m: false, g: 1, s: true },
  { c: FIELD_TEAL_LO, a: 0.80, x: 92, y: 9, w: 34, h: 20, r: -14, t: 25, dx: -9, dy: 4, dr: 12, m: true, g: 1, s: true },
  { c: '#7CC3D4', a: 0.30, x: 60, y: 6, w: 22, h: 7, r: -12, t: 15, dx: -26, dy: 3, dr: 6, m: false, g: 1, s: true }, // sheen, desktop only
];

// Text-zone luminance rule (stage %). Any blob whose full drift envelope can reach the
// zone is dark (no lighter than FIELD_BASE) or a low-alpha lift, the summed lift stays
// under ADAM_ZONE_L_MAX - L(FIELD_BASE), and nothing lighter than FIELD_ZONE_MAX reaches it.
export const ADAM_ZONE = { desktop: { x: [18, 82], y: [30, 72] }, mobile: { x: [0, 100], y: [34, 66] } };
export const ADAM_ZONE_L_MAX = 0.13;
// Stage pixel basis used for the extent maths (desktop, mobile portrait, landscape phone).
export const ADAM_STAGES = { desktop: [1600, 900], mobile: [390, 844], landscape: [844, 390] };

export const hexRgb = (hex) => { const n = parseInt(hex.slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; };
const lin = (v) => { const c = v / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
export const relLuminance = (rgb) => 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2]);
// Peak effective alpha of a blob (main gradient plus its second lobe, stacked).
export const blobAlpha = (b) => (b.l ? 1 - (1 - b.a) * (1 - ADAM_LOBE_K * b.a) : b.a);
// Luminance added at the blob peak over FIELD_BASE (0 for blobs that only darken).
export function blobLift(b) {
  const base = hexRgb(FIELD_BASE); const c = hexRgb(b.c); const a = blobAlpha(b);
  const mix = base.map((v, i) => v + a * (c[i] - v));
  return Math.max(0, relLuminance(mix) - relLuminance(base));
}
// Bounding box (stage %) of a blob over its whole drift envelope, rotation range and 100% radius.
export function blobExtent(b, mobile, W = 1600, H = 900) {
  const k = mobile ? b.g : 1;
  const hw = (b.w * k / 100) * W / 2; const hh = (b.h * k / 100) * H / 2;
  let ex = 0; let ey = 0;
  for (let i = 0; i <= 12; i += 1) {
    const th = ((b.r + (b.dr * i) / 12) * Math.PI) / 180;
    ex = Math.max(ex, Math.hypot(hw * Math.cos(th), hh * Math.sin(th)));
    ey = Math.max(ey, Math.hypot(hw * Math.sin(th), hh * Math.cos(th)));
  }
  const cx0 = Math.min(b.x, b.x + b.dx); const cx1 = Math.max(b.x, b.x + b.dx);
  const cy0 = Math.min(b.y, b.y + b.dy); const cy1 = Math.max(b.y, b.y + b.dy);
  return { x0: cx0 - (ex / W) * 100, x1: cx1 + (ex / W) * 100, y0: cy0 - (ey / H) * 100, y1: cy1 + (ey / H) * 100 };
}
export function blobInZone(b, mobile, W, H) {
  const z = mobile ? ADAM_ZONE.mobile : ADAM_ZONE.desktop;
  const e = blobExtent(b, mobile, W, H);
  return e.x1 > z.x[0] && e.x0 < z.x[1] && e.y1 > z.y[0] && e.y0 < z.y[1];
}
// Summed lift of every blob that can reach the zone (tests assert <= ADAM_ZONE_L_MAX - L(FIELD_BASE)).
export function zoneLift(mobile, W, H, table = FIELD_BLOBS) {
  return table.filter((b) => (!mobile || b.m) && blobInZone(b, mobile, W, H)).reduce((s, b) => s + blobLift(b), 0);
}
// Client-only random drift start phase (seconds into the 2t cycle), applied in the live effect.
export const adamPhase = (t, rnd) => +(rnd * 2 * t).toFixed(2);

const hexRgba = (hex, a) => { const [r, g, b] = hexRgb(hex); return `rgba(${r},${g},${b},${a})`; };
export const blobBg = (b) => {
  const main = `radial-gradient(closest-side, ${hexRgba(b.c, b.a)} 0%, ${hexRgba(b.c, +(b.a * 0.6).toFixed(3))} 55%, ${hexRgba(b.c, 0)} 100%)`;
  if (!b.l) return main;
  const [px, py, rx, ry] = b.l; const a = +(b.a * ADAM_LOBE_K).toFixed(3);
  const lobe = `radial-gradient(ellipse ${rx}% ${ry}% at ${px}% ${py}%, ${hexRgba(b.c, a)} 0%, ${hexRgba(b.c, +(a * 0.6).toFixed(3))} 55%, ${hexRgba(b.c, 0)} 100%)`;
  return `${lobe}, ${main}`;
};
