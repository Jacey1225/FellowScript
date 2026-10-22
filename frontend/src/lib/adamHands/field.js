// Palette, liquid-field blob table and the text-contrast luminance rule for the
// hero's end state (task 20261022-hands-scroll-grain-gradient, design-spec-r2.md).
// Pure data and maths, no DOM, so the component and tests share one source.
// The settled field is the blue-era liquid implementation (0ba34d1d..26246be9: 135deg
// underlay, swirls, drifting blobs, top highlight washes) recoloured to the warm brown /
// honey palette by luminance rank. The LEAK_* constants belong to the lens bloom.
export const FIELD_BASE = '#5C3509'; // deep umber (L .0486)
export const FIELD_END = '#EBC480'; // honey; join colour handed to .hm-fam
export const FIELD_INK = '#FBF7F1'; // cream text on the field (L .934)
export const FIELD_WHITE = '#FFF4DC'; // warm white hold (continues the hand-touch bloom)
export const FIELD_CAP = FIELD_WHITE; // canvas darken-cap: keeps the bloom white end stop unclamped
export const LEAK_CORE = '#FFF6E4';
export const LEAK_SOFT = '#FFE2AA';
export const LEAK_GOLD = '#E09A30';
export const LEAK_AMBER = '#B4712C';
export const LEAK_HONEY = '#EBC480';
export const LEAK_PEACH = '#F3C48B';
export const FIELD_ZONE_MAX = '#8A5217'; // lightest colour allowed at full alpha under text (L .115)

// Static underlayer (135deg, top-left lit). The first layer pins the bottom edge to
// FIELD_END so the join with .hm-fam is exact (repeated as .adam-liquid::before above the blobs).
export const FIELD_HI = '#A8682A';
export const FIELD_MID = '#96591F';
export const FIELD_LO = '#7C4A1A';
export const FIELD_DARK = '#402508';
export const FIELD_DEEP = '#2C1706';
export const FIELD_BOTTOM_FADE = `linear-gradient(180deg, rgba(235,196,128,0) 80%, ${FIELD_END} 100%)`;
export const FIELD_UNDER = `${FIELD_BOTTOM_FADE}, linear-gradient(135deg, ${FIELD_HI} 0%, ${FIELD_MID} 12%, ${FIELD_LO} 20%, ${FIELD_BASE} 48%, ${FIELD_DARK} 70%, ${FIELD_DEEP} 92%, ${FIELD_END} 100%)`;
export const FIELD_UNDER_MOBILE = FIELD_UNDER.replace('135deg', '160deg');
export const FIELD_GRAIN_OPACITY = 0.55;
// Monochrome (colourless) grain tile, opaque grey from the noise red channel,
// drawn with soft-light over the field so it never shifts hue or the mean.
export const FIELD_GRAIN_URL = `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='220' height='220'><filter id='g' x='0' y='0' width='100%' height='100%' color-interpolation-filters='sRGB'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3' stitchTiles='stitch'/><feColorMatrix values='1 0 0 0 0  1 0 0 0 0  1 0 0 0 0  0 0 0 0 1'/></filter><rect width='220' height='220' filter='url(%23g)' opacity='${FIELD_GRAIN_OPACITY}'/></svg>")`;

// Fallback strip: ink down into the field; last stop is exactly FIELD_BASE (the block's first colour).
export const FALLBACK_GRADIENT = `#17120F 0%, #2B1B0B 22%, #3F2610 50%, ${FIELD_BASE} 100%`;

// Swirl layers (desktop only): blue-era conic stops and alphas, warm colours.
export const SWIRL_A = 'conic-gradient(from 0deg at 50% 50%, rgba(124,74,26,0) 0deg, rgba(124,74,26,0.33) 70deg, rgba(28,14,4,0) 150deg, rgba(122,72,26,0.25) 235deg, rgba(20,10,3,0) 305deg, rgba(124,74,26,0) 360deg)';
export const SWIRL_B = 'conic-gradient(from 40deg at 50% 50%, rgba(122,72,26,0) 0deg, rgba(122,72,26,0.20) 80deg, rgba(28,14,4,0) 160deg, rgba(28,14,4,0.30) 250deg, rgba(122,72,26,0) 360deg)';
// The light lobes of each swirl (dark lobes have zero lift). Lobes of one swirl sit at
// different angles, so a point sees at most one of them; the two swirls can overlap.
export const SWIRL_LIGHT_LOBES = [
  [{ c: '#7C4A1A', a: 0.33 }, { c: '#7A481A', a: 0.25 }], // A
  [{ c: '#7A481A', a: 0.20 }], // B
];

// Blob table (geometry and timing verbatim from 26246be9), hand-placed and identical in
// SSR and client (no PRNG during render).
// x,y = centre in % of the field; w,h = size in % of the field; r = rotation deg;
// a = peak alpha; t = half-cycle drift seconds; dx (cqw), dy (cqh), dr (deg) = drift;
// m = shown on mobile; g = mobile size multiplier; s = top highlight (fades in with the
// settle beat); l = optional second lobe [px, py, rx, ry] in % of the element box.
export const ADAM_LOBE_K = 0.6;
export const FIELD_BLOBS = [
  // static dark, zone-safe (no lighter than FIELD_BASE, or a tiny lift)
  { c: '#2A1606', a: 0.85, x: 38, y: 54, w: 90, h: 52, r: -14, t: 24, dx: 16, dy: -8, dr: 22, m: true, g: 1.25, l: [62, 40, 28, 28] },
  { c: '#6E4214', a: 0.30, x: 72, y: 58, w: 60, h: 38, r: 26, t: 17, dx: -18, dy: 6, dr: -25, m: true, g: 1.25, l: [36, 58, 26, 28] },
  { c: '#3A220A', a: 0.80, x: 58, y: 30, w: 44, h: 30, r: -40, t: 19, dx: 12, dy: 12, dr: 18, m: false, g: 1, l: [38, 58, 26, 26] },
  { c: '#744618', a: 0.20, x: 14, y: 66, w: 36, h: 22, r: 12, t: 21, dx: 10, dy: -10, dr: 10, m: false, g: 1.25 },
  { c: '#1C0E03', a: 0.95, x: 92, y: 84, w: 80, h: 66, r: -20, t: 26, dx: -9, dy: -7, dr: 14, m: true, g: 1.2 },
  { c: FIELD_LO, a: 0.45, x: 3, y: 58, w: 16, h: 30, r: 20, t: 14, dx: 5, dy: -8, dr: 12, m: false, g: 1 },
  // warm highlights (s): kept out of the text zone so the lift budget holds
  { c: '#D4963A', a: 0.95, x: 46, y: 1, w: 62, h: 36, r: -6, t: 27, dx: 14, dy: 5, dr: 8, m: true, g: 1, s: true },
  { c: '#B87530', a: 0.90, x: 6, y: 3, w: 34, h: 20, r: 12, t: 23, dx: 7, dy: 4, dr: -10, m: false, g: 1, s: true },
  { c: '#9A5C20', a: 0.80, x: 92, y: 9, w: 34, h: 20, r: -14, t: 25, dx: -9, dy: 4, dr: 12, m: true, g: 1, s: true },
  { c: '#F3C48B', a: 0.30, x: 60, y: 6, w: 22, h: 7, r: -12, t: 15, dx: -26, dy: 3, dr: 6, m: false, g: 1, s: true }, // sheen, desktop only
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
// Lift added by the swirl light lobes (worst case: both swirls fully inside the zone).
export function swirlLift() {
  const base = hexRgb(FIELD_BASE);
  const lift = (l) => {
    const c = hexRgb(l.c);
    const mix = base.map((v, i) => v + l.a * (c[i] - v));
    return Math.max(0, relLuminance(mix) - relLuminance(base));
  };
  return SWIRL_LIGHT_LOBES.reduce((s, lobes) => s + Math.max(...lobes.map(lift)), 0);
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
