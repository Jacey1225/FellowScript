// Task 20261015-adam-hands-scroll-hero: pinned, scroll-scrubbed "Creation of
// Adam" hero. Two marble hand layers approach on an ink stage, touch, and a
// live-drawn light floods the stage to a grainy umber-to-honey field (rev 1).
//
// Rendering model
//  - Fallback (SSR / prerender / no-JS / prefers-reduced-motion): the touch-frame
//    still at 100svh with the live eyebrow, then a static 24svh gradient strip.
//    No pin, no scrub, no animation. This is also the first client render, so
//    the markup the prerender emits and the first client render agree.
//  - Live (client, motion allowed): a 320vh (260vh mobile) runway with a sticky
//    100svh stage. Scroll progress p is smoothed (~0.6 s) and painted by writing
//    styles straight onto the layer elements (no React re-render per frame).
//    All maths lives in src/lib/adamHands/driver.js.
//  - All light, the key filter, wash, cap and type are live; only the cut-out
//    hand layers, edge-light, bounce, fan and spark sprites are image files
//    (public/adam/).
import React, { useEffect, useRef, useState } from 'react';
import {
  CANVAS, RUNWAY_VH, floodDrivers, lightParams, fanWeights, FAN_REF, handsPose,
  bloomIntensity, ignite, beatGlow, typeReveal, warmGlowAlpha, eyebrowColor,
  scrubProgress, smoothStep, coverScale, smooth, lerp,
} from '../lib/adamHands/driver.js';

const INK = '#17120F';

// Rev 2: the end state is a grainy, brown-dominant liquid field. One shared set
// of tokens: every surface (live field layer, data-flat stage, fallback strip,
// fallback block, Home .hm-fam) reads the constants below.
export const FIELD_BASE = '#5C3509'; // deep umber, base of the top ~62% of the field
export const FIELD_END = '#EBC480'; // join colour handed to .hm-fam; also the canvas cap colour
export const FIELD_CAP = FIELD_END; // bloom can never clamp lighter than honey
export const FIELD_INK = '#FBF7F1'; // cream: the text sits on brown
// Static underlayer: umber to the 62% line, then a honey pool that is exactly FIELD_END at 100%.
export const FIELD_UNDER = `linear-gradient(180deg, ${FIELD_BASE} 0%, ${FIELD_BASE} 62%, #8A5217 74%, #B4712C 82%, #E0B066 90%, ${FIELD_END} 97%, ${FIELD_END} 100%)`;
export const FIELD_GRAIN_OPACITY = 0.55;
// Monochrome (colourless) grain tile, opaque grey from the noise red channel,
// drawn with soft-light over the field so it never shifts hue or the mean.
export const FIELD_GRAIN_URL = `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='220' height='220'><filter id='g' x='0' y='0' width='100%' height='100%' color-interpolation-filters='sRGB'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3' stitchTiles='stitch'/><feColorMatrix values='1 0 0 0 0  1 0 0 0 0  1 0 0 0 0  0 0 0 0 1'/></filter><rect width='220' height='220' filter='url(%23g)' opacity='${FIELD_GRAIN_OPACITY}'/></svg>")`;

// Rev 3: no centred halo. The text-contrast guarantee lives in the blob table itself
// (luminance rule below, tested from this table), so blobs may drift behind the text.
// Hand-placed asymmetric set, identical in SSR and client (no PRNG during render).
// x,y = centre in % of the field; w,h = size in % of the field; r = rotation deg;
// a = peak alpha; t = half-cycle drift seconds; dx (cqw), dy (cqh), dr (deg) = drift;
// m = shown on mobile; g = mobile size multiplier; l = optional second lobe
// [px, py, rx, ry] in % of the element box (alpha factor ADAM_LOBE_K) so the silhouette is not a clean ellipse.
export const ADAM_LOBE_K = 0.6;
export const FIELD_BLOBS = [
  { c: '#3A2410', a: 0.9, x: 38, y: 54, w: 90, h: 52, r: -14, t: 53, dx: 12, dy: -6, dr: 22, m: true, g: 1.25, l: [62, 40, 28, 28] },
  { c: '#6B4116', a: 0.3, x: 72, y: 58, w: 60, h: 38, r: 26, t: 37, dx: -14, dy: 5, dr: -25, m: true, g: 1.25, l: [36, 58, 26, 28] },
  { c: '#4A2C0E', a: 0.8, x: 58, y: 30, w: 44, h: 30, r: -40, t: 43, dx: 9, dy: 10, dr: 18, m: false, g: 1, l: [38, 58, 26, 26] },
  { c: '#7B4F20', a: 0.2, x: 14, y: 66, w: 36, h: 22, r: 12, t: 47, dx: 8, dy: -8, dr: 10, m: true, g: 1.25 },
  { c: '#8A5217', a: 0.12, x: 86, y: 44, w: 30, h: 50, r: -8, t: 59, dx: -9, dy: 8, dr: 14, m: false, g: 1 },
  { c: '#B4712C', a: 0.85, x: 93, y: 6, w: 30, h: 18, r: -32, t: 31, dx: -6, dy: 4, dr: 16, m: true, g: 1 },
  { c: '#E09A30', a: 0.8, x: 7, y: 12, w: 16, h: 14, r: 40, t: 29, dx: 5, dy: 6, dr: -18, m: false, g: 1 },
  { c: '#EBC480', a: 0.5, x: 46, y: 3, w: 26, h: 10, r: -6, t: 61, dx: 10, dy: 3, dr: 8, m: true, g: 1 },
  { c: '#B4712C', a: 0.7, x: 3, y: 58, w: 16, h: 30, r: 20, t: 41, dx: 4, dy: -6, dr: 12, m: false, g: 1 },
  { c: '#E09A30', a: 0.55, x: 95, y: 74, w: 14, h: 18, r: -20, t: 51, dx: -4, dy: -4, dr: 10, m: false, g: 1 },
  { c: '#8A5217', a: 0.55, x: 24, y: 8, w: 40, h: 16, r: 6, t: 57, dx: 12, dy: 4, dr: 6, m: true, g: 1 },
];

// Text-zone luminance rule (stage %). Any blob whose full drift envelope can reach the
// zone is either dark (no lighter than FIELD_BASE) or a low-alpha lift, and the summed
// lift stays under ADAM_ZONE_L_MAX - L(FIELD_BASE). Cream ink needs raw L <= 0.0725 for ~8:1.
export const ADAM_ZONE = { desktop: { x: [18, 82], y: [30, 72] }, mobile: { x: [0, 100], y: [34, 66] } };
export const ADAM_ZONE_L_MAX = 0.0725;
// Stage pixel basis used for the extent maths (desktop, mobile portrait, landscape phone).
export const ADAM_STAGES = { desktop: [1600, 900], mobile: [390, 844], landscape: [844, 390] };

const hexRgb = (hex) => { const n = parseInt(hex.slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; };
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
const blobBg = (b) => {
  const main = `radial-gradient(closest-side, ${hexRgba(b.c, b.a)} 0%, ${hexRgba(b.c, +(b.a * 0.6).toFixed(3))} 55%, ${hexRgba(b.c, 0)} 100%)`;
  if (!b.l) return main;
  const [px, py, rx, ry] = b.l; const a = +(b.a * ADAM_LOBE_K).toFixed(3);
  const lobe = `radial-gradient(ellipse ${rx}% ${ry}% at ${px}% ${py}%, ${hexRgba(b.c, a)} 0%, ${hexRgba(b.c, +(a * 0.6).toFixed(3))} 55%, ${hexRgba(b.c, 0)} 100%)`;
  return `${lobe}, ${main}`;
};

// Headline face: Schibsted Grotesk, the same face as the nav wordmark (.fs-wordmark).
// Change the face in this one place (live .adam-final-h and the fallback block both use it).
export const ADAM_FINAL_FONT = "'Schibsted Grotesk', sans-serif";
const HEAD_FONT = ADAM_FINAL_FONT;
const BODY_FONT = "'Hanken Grotesk', system-ui, sans-serif";

export const ADAM_MOBILE_QUERY = '(max-width: 899px), (pointer: coarse)';
export const ADAM_KEY_FILTER_ID = 'fs-adam-key';
export const ADAM_EYEBROW = '// NOT JUST ONCE A WEEK';
export const ADAM_FINAL_HEADLINE = 'Family';
// Exact string from Jacey, typo ("comunity") kept verbatim.
export const ADAM_FINAL_SUBTITLE = 'Welcoming scripture into a deeper comunity.';

// Fallback strip: ink down into the field; last stop is exactly FIELD_BASE (the block's first colour).
export const FALLBACK_GRADIENT = `#17120F 0%, #2B1B0B 22%, #3F2610 50%, ${FIELD_BASE} 100%`;

const A = '/adam/';
const FILES = {
  desktop: {
    adam: `${A}adam-desktop-1600x900.webp`,
    god: `${A}god-desktop-1600x900.webp`,
    edgeAdam: `${A}edgelight-adam-desktop-1600x900.webp`,
    edgeGod: `${A}edgelight-god-desktop-1600x900.webp`,
    bounceAdam: `${A}bounce-adam-desktop-1600x900.webp`,
    bounceGod: `${A}bounce-god-desktop-1600x900.webp`,
  },
  mobile: {
    adam: `${A}adam-mobile-900x1600.webp`,
    adam2x: `${A}adam-mobile-1800x3200.webp`,
    god: `${A}god-mobile-900x1600.webp`,
    god2x: `${A}god-mobile-1800x3200.webp`,
    edgeAdam: `${A}edgelight-adam-mobile-900x1600.webp`,
    edgeGod: `${A}edgelight-god-mobile-900x1600.webp`,
    bounceAdam: `${A}bounce-adam-mobile-900x1600.webp`,
    bounceGod: `${A}bounce-god-mobile-900x1600.webp`,
  },
  fanA: `${A}fan-a-L270-sigma3-640px@1x.webp`,
  fanB: `${A}fan-b-L670-sigma8-700px@2x.webp`,
  fanC: `${A}fan-c-L1100-sigma14-1150px@2x.webp`,
  hair: `${A}spark-hairlines-760px.webp`,
  streak: `${A}streak-520x17.png`,
  fallbackDesktop: `${A}fallback-touch-desktop-1600x900.webp`,
  fallbackMobile: `${A}fallback-touch-mobile-900x1600.webp`,
};
// Fan sprite display sizes in canvas px (b and c are half-resolution, shown at 2x).
const FAN_SIZE = { a: 640, b: 1400, c: 2300 };

// Grid lines (hairline) and plus-mark intersections, canvas px.
const GRID = {
  desktop: { x: [160, 1440], y: [108, 792] },
  mobile: { x: [60, 840], y: [90, 1510] },
};

const GRAIN_URL = "url(\"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><filter id='n'><feTurbulence baseFrequency='.9' numOctaves='2'/></filter><rect width='200' height='200' filter='url(%23n)'/></svg>\")";

const EDGE_MASK = 'radial-gradient(circle calc(var(--adam-d0) * 8) at var(--adam-tx) var(--adam-ty), #000 0, rgba(0,0,0,0.8) 6.25%, rgba(0,0,0,0.5) 12.5%, rgba(0,0,0,0.31) 18.75%, rgba(0,0,0,0.2) 25%, rgba(0,0,0,0.1) 37.5%, rgba(0,0,0,0.06) 50%, rgba(0,0,0,0.03) 75%, transparent 100%)';

export const ADAM_CSS = `
.adam-pin { position: relative; background: ${INK}; }
.adam-pin[data-live="true"] { height: ${RUNWAY_VH.desktop}vh; }
.adam-stage { position: relative; height: 100vh; height: 100svh; overflow: hidden; background: ${INK}; container-type: size; }
.adam-pin[data-live="true"] .adam-stage { position: sticky; top: 0; }
.adam-stage[data-flat="true"] { background: ${FIELD_UNDER}; }
.adam-liquid { position: absolute; inset: 0; overflow: hidden; isolation: isolate; container-type: size; pointer-events: none; background: ${FIELD_UNDER}; }
.adam-field { opacity: 0; }
.adam-liquid-blobs { position: absolute; inset: 0; -webkit-mask-image: linear-gradient(180deg, #000 0, #000 60%, transparent 84%); mask-image: linear-gradient(180deg, #000 0, #000 60%, transparent 84%); }
.adam-blob { --k: 1; position: absolute; left: calc(var(--x) * 1%); top: calc(var(--y) * 1%); width: calc(var(--w) * var(--k) * 1%); height: calc(var(--h) * var(--k) * 1%); border-radius: 50%; transform: translate(-50%, -50%) rotate(calc(var(--r) * 1deg)); animation: adam-drift calc(var(--t) * 1s) ease-in-out infinite alternate; animation-play-state: paused; animation-delay: calc(var(--ph, 0) * -1s); }
.adam-field[data-live="true"] .adam-blob { animation-play-state: running; will-change: transform; }
.adam-liquid-frozen .adam-blob { animation: none; }
/* Fallback block only: also fade blobs out at the top edge so it joins the ink-to-umber strip flat. */
.adam-liquid-frozen .adam-liquid-blobs { -webkit-mask-image: linear-gradient(180deg, transparent 0, #000 16%, #000 60%, transparent 84%); mask-image: linear-gradient(180deg, transparent 0, #000 16%, #000 60%, transparent 84%); }
@keyframes adam-drift { to { transform: translate(calc(-50% + var(--dx) * 1cqw), calc(-50% + var(--dy) * 1cqh)) rotate(calc((var(--r) + var(--dr)) * 1deg)); } }
.adam-liquid::after { content: ''; position: absolute; inset: 0; background-image: ${FIELD_GRAIN_URL}; background-size: 220px 220px; mix-blend-mode: soft-light; }
@media (prefers-reduced-motion: reduce) { .adam-blob { animation: none; } }
.adam-fb-img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; object-position: 50% 48%; display: block; }
.adam-eyebrow { position: absolute; margin: 0; left: 5.25cqw; top: 7cqh; font-family: ${HEAD_FONT}; font-size: clamp(11.5px, 0.8cqw, 14px); letter-spacing: 0.26em; text-transform: uppercase; line-height: 1.6; white-space: nowrap; color: #F0C08A; pointer-events: none; }
.adam-pin[data-live="true"] .adam-eyebrow { left: 11.5cqw; top: 11.9cqh; transform: translateY(-50%); }
.adam-grad { position: relative; height: 24svh; min-height: 120px; background: linear-gradient(180deg, ${FALLBACK_GRADIENT}); }
.adam-grad::after { content: ''; position: absolute; inset: 0; background-image: ${FIELD_GRAIN_URL}; background-size: 220px 220px; mix-blend-mode: soft-light; }
.adam-fbfield { position: relative; isolation: isolate; display: grid; place-items: center; text-align: center; min-height: clamp(520px, 80svh, 760px); padding: clamp(48px, 9vh, 96px) clamp(20px, 5vw, 64px); background: ${FIELD_UNDER}; color: ${FIELD_INK}; }
.adam-fbfield-in { position: relative; z-index: 1; max-width: 1240px; margin: 0 auto; text-align: center; }
.adam-fbfield .adam-final-h { font-size: clamp(48px, 7vw, 88px); }
.adam-fbfield .adam-final-b { max-width: 34em; margin-inline: auto; }
.adam-canvas { position: absolute; left: 50%; top: 50%; transform-origin: 50% 50%; isolation: isolate; overflow: hidden; background: ${INK}; pointer-events: none; }
.adam-stage[data-flat="true"] .adam-canvas { visibility: hidden; }
.adam-layer { position: absolute; left: 0; top: 0; pointer-events: none; }
.adam-img { position: absolute; left: 0; top: 0; display: block; max-width: none; pointer-events: none; user-select: none; }
.adam-edge { -webkit-mask-image: ${EDGE_MASK}; mask-image: ${EDGE_MASK}; }
.adam-plus { position: absolute; width: 10px; height: 10px; margin: -5px 0 0 -5px; }
.adam-plus::before, .adam-plus::after { content: ''; position: absolute; background: rgba(255,244,230,0.4); }
.adam-plus::before { left: 4.5px; top: 0; width: 1px; height: 10px; }
.adam-plus::after { top: 4.5px; left: 0; height: 1px; width: 10px; }
.adam-final { position: absolute; inset: 0; margin: 0; padding: 0 6.67cqw; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; opacity: 0; pointer-events: none; color: ${FIELD_INK}; }
.adam-final-h { display: block; margin: 0; font-family: ${HEAD_FONT}; font-weight: 600; font-size: clamp(48px, 4.5cqw, 88px); letter-spacing: -0.02em; line-height: 1; white-space: nowrap; color: ${FIELD_INK}; }
.adam-final-b { display: block; margin: clamp(20px, 4cqh, 40px) 0 0; max-width: 34cqw; font-family: ${HEAD_FONT}; font-weight: 400; font-size: clamp(18px, 1.4cqw, 24px); line-height: 1.4; color: ${FIELD_INK}; text-wrap: balance; }
@supports not (width: 1cqw) {
  .adam-eyebrow { left: 5.25vw; top: 7vh; font-size: 12px; }
  .adam-pin[data-live="true"] .adam-eyebrow { left: 11.5vw; top: 11.9vh; }
  .adam-final { padding: 0 6.67vw; }
  .adam-final-h { font-size: clamp(48px, 4.5vw, 88px); }
  .adam-final-b { max-width: 34vw; font-size: clamp(18px, 1.4vw, 24px); }
}
@media (max-width: 899px), (pointer: coarse) {
  .adam-pin[data-live="true"] { height: ${RUNWAY_VH.mobile}vh; }
  .adam-fb-img { object-position: 50% 46%; }
  .adam-eyebrow { left: 9.33cqw; top: calc(5.6cqh + env(safe-area-inset-top, 0px)); font-size: max(2.89cqw, 12px); }
  .adam-pin[data-live="true"] .adam-eyebrow { left: 9.33cqw; top: calc(5.6cqh + env(safe-area-inset-top, 0px)); transform: translateY(-50%); }
  .adam-blob-g { --k: 1.25; }
  .adam-blob-d { display: none; }
  .adam-final-h { font-size: clamp(52px, min(17.5vw, 15svh), 96px); white-space: nowrap; letter-spacing: -0.025em; line-height: 0.98; }
  .adam-final-b { margin-top: 20px; max-width: none; font-size: 19px; line-height: 1.4; }
  .adam-fbfield .adam-final-h { font-size: clamp(52px, 17.5vw, 96px); }
  @supports not (width: 1cqw) {
    .adam-eyebrow, .adam-pin[data-live="true"] .adam-eyebrow { left: 9.33vw; font-size: 12px; }
  }
}
@media (max-height: 500px) {
  .adam-final-h { font-size: clamp(48px, min(17.5vw, 15svh), 56px); }
  .adam-final-b { font-size: 16px; }
}
`;

function rgba(rgb, a) { return `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a.toFixed(3)})`; }

function bloomGradient(L, ig, tx, ty) {
  const { r0, k } = L;
  const R = 1.9 * r0;
  const gold = [224, 154, 48]; const white = [255, 241, 214];
  const stops = [];
  for (let i = 0; i < 20; i++) {
    const r = i * 0.1 * r0;
    const I = bloomIntensity(r, r0, k);
    const t = smooth((I - 0.2) / 0.8);
    const col = [0, 1, 2].map((c) => Math.round(lerp(gold[c], white[c], t)));
    stops.push(`${rgba(col, Math.min(1, I) * ig)} ${r.toFixed(1)}px`);
  }
  return `radial-gradient(circle ${R.toFixed(1)}px at ${tx}px ${ty}px, ${stops.join(',')}, rgba(255,241,214,0) ${R.toFixed(1)}px)`;
}

function coreGradient(sigma, ig, tx, ty) {
  const s = sigma;
  const pts = [[0, 1], [0.5, 0.88], [1, 0.61], [1.5, 0.32], [2, 0.135], [3, 0.011], [4, 0]];
  const stops = pts.map(([x, a]) => `rgba(255,246,228,${(a * ig).toFixed(3)}) ${(x * s).toFixed(1)}px`);
  return `radial-gradient(circle ${(4 * s).toFixed(1)}px at ${tx}px ${ty}px, ${stops.join(',')})`;
}

function haloGradient(g, tx, ty) {
  const pts = [[0, 1], [0.25, 0.5625], [0.5, 0.25], [0.75, 0.0625], [1, 0]];
  const stops = pts.map(([x, a]) => `${rgba(g.color, a * g.alpha)} ${(x * g.r).toFixed(1)}px`);
  return `radial-gradient(circle ${g.r.toFixed(1)}px at ${tx}px ${ty}px, ${stops.join(',')})`;
}

function setOpacity(el, v) {
  if (!el) return;
  const o = v < 0.003 ? 0 : v > 1 ? 1 : v;
  el.style.opacity = o.toFixed(3);
  el.style.visibility = o === 0 ? 'hidden' : 'visible';
}

// Paints one frame by writing styles onto the cached layer elements.
function paintFrame(refs, p, mobile) {
  const cv = mobile ? CANVAS.mobile : CANVAS.desktop;
  const { stage, canvas } = refs;
  const pose = handsPose(p, mobile);
  const d = floodDrivers(p);
  const L = lightParams(d.f, d.g);
  const ig = ignite(p);
  const flat = d.w >= 0.9999;
  stage.dataset.p = p.toFixed(3);
  stage.dataset.flat = flat ? 'true' : 'false';

  // Hands: translate then scale about the touch point.
  const place = (el, h) => {
    if (el) el.style.transform = `translate(${h.tx.toFixed(2)}px, ${h.ty.toFixed(2)}px) scale(${pose.scale.toFixed(5)})`;
  };
  place(refs.adamGroup, pose.adam);
  place(refs.godGroup, pose.god);

  // Key filter (sRGB; slope/intercept from key_fixed). Dropped once identity.
  const keyId = `${pose.slope.map((s) => s.toFixed(4)).join(',')}|${pose.intercept.toFixed(4)}`;
  if (refs.lastKey !== keyId) {
    refs.lastKey = keyId;
    const ch = [refs.kr, refs.kg, refs.kb];
    ch.forEach((n, i) => {
      if (!n) return;
      n.setAttribute('slope', pose.slope[i].toFixed(4));
      n.setAttribute('intercept', pose.intercept.toFixed(4));
    });
    const identity = pose.slope.every((s) => s > 0.9995) && Math.abs(pose.intercept) < 0.0005;
    const f = identity ? 'none' : `url(#${ADAM_KEY_FILTER_ID})`;
    refs.handImgs.forEach((im) => { im.style.filter = f; });
  }

  // Table rim/bounce fade to 0 by beat 2; from the touch on, rim is full weight
  // and bounce follows 0.10 + 0.25 f (README section 4), ramped in by ignite().
  refs.edges.forEach((el) => setOpacity(el, Math.max(pose.rim, ig)));
  refs.bounces.forEach((el) => setOpacity(el, Math.max(pose.bounce, ig * L.bounceLive)));
  canvas.style.setProperty('--adam-d0', `${L.rimReach.toFixed(1)}px`);

  setOpacity(refs.grid, d.e);
  setOpacity(refs.grain, d.e * 0.04);
  setOpacity(refs.warm, warmGlowAlpha(p, d.e));

  // Beat 1-3 glow.
  const gl = beatGlow(p, pose, mobile);
  if (gl.alpha > 0.002) {
    refs.glow.style.background = haloGradient(gl, gl.x, gl.y);
    refs.glow.style.visibility = 'visible';
  } else {
    refs.glow.style.visibility = 'hidden';
  }

  // Touch light.
  const bloomKey = `${L.r0.toFixed(1)}|${L.k.toFixed(3)}|${ig.toFixed(3)}`;
  if (refs.lastBloom !== bloomKey) {
    refs.lastBloom = bloomKey;
    refs.bloom.style.background = bloomGradient(L, ig, cv.tx, cv.ty);
    refs.core.style.background = coreGradient(L.sigma, ig, cv.tx, cv.ty);
  }
  refs.bloom.style.visibility = ig > 0.002 ? 'visible' : 'hidden';
  refs.core.style.visibility = ig > 0.002 ? 'visible' : 'hidden';

  const fw = fanWeights(d.f);
  const fanScale = (key) => ((L.fanLength / FAN_REF[key])).toFixed(4);
  ['a', 'b', 'c'].forEach((k) => {
    const el = refs.fan[k];
    if (!el) return;
    el.style.transform = `scale(${fanScale(k)})`;
    setOpacity(el, fw[k] * d.fanG * ig);
  });
  refs.fanWrap.style.transform = `rotate(${L.fanRotateDeg.toFixed(3)}deg)`;

  const hairK = mobile ? 0.55 : 1;
  refs.hair.style.transform = `${mobile ? 'rotate(-20deg) ' : ''}scale(${(L.hairScale * hairK).toFixed(4)})`;
  setOpacity(refs.hair, d.A * ig);
  refs.streak.style.transform = `scaleX(${(L.streakScaleX * (mobile ? 0.733 : 1)).toFixed(4)})`;
  setOpacity(refs.streak, d.A * ig);

  setOpacity(refs.tip, d.tipS * ig);

  setOpacity(refs.field, d.w);
  if (refs.field) {
    const on = d.w > 0.001 ? 'true' : 'false';
    if (refs.field.dataset.live !== on) refs.field.dataset.live = on;
  }

  // Type.
  const ec = eyebrowColor(d.c);
  refs.eyebrow.style.color = `rgb(${ec[0]},${ec[1]},${ec[2]})`;
  setOpacity(refs.eyebrow, d.e);
  const tr = typeReveal(p);
  refs.final.style.opacity = tr.toFixed(3);
  refs.final.style.transform = `translateY(${(12 * (1 - tr)).toFixed(2)}px)`;
}

function collect(stage) {
  const q = (k) => stage.querySelector(`[data-adam="${k}"]`);
  const qa = (k) => Array.from(stage.querySelectorAll(`[data-adam="${k}"]`));
  return {
    stage,
    canvas: q('canvas'),
    adamGroup: q('adam-group'),
    godGroup: q('god-group'),
    handImgs: qa('hand-img'),
    edges: qa('edge'),
    bounces: qa('bounce'),
    kr: q('kr'), kg: q('kg'), kb: q('kb'),
    grid: q('grid'), grain: q('grain'), warm: q('warm'), glow: q('glow'),
    bloom: q('bloom'), core: q('core'),
    fanWrap: q('fan-wrap'), fan: { a: q('fan-a'), b: q('fan-b'), c: q('fan-c') },
    hair: q('hair'), streak: q('streak'), tip: q('tip'),
    field: q('field'), eyebrow: q('eyebrow'), final: q('final'),
    lastKey: null, lastBloom: null,
  };
}

// One liquid field for every surface. `live` = the stage layer (opacity driven by w, drift
// runs while visible); otherwise the frozen frame of the same composition (fallback block).
function LiquidField({ live }) {
  return (
    <div
      className={live ? 'adam-liquid adam-field' : 'adam-liquid adam-liquid-frozen'}
      data-adam={live ? 'field' : undefined}
      data-live="false"
      aria-hidden="true"
    >
      <div className="adam-liquid-blobs">
        {FIELD_BLOBS.map((b, i) => (
          <div
            key={i}
            className={`adam-blob${b.m ? '' : ' adam-blob-d'}${b.g > 1 ? ' adam-blob-g' : ''}`}
            style={{ '--x': b.x, '--y': b.y, '--w': b.w, '--h': b.h, '--r': b.r, '--t': b.t, '--dx': b.dx, '--dy': b.dy, '--dr': b.dr, background: blobBg(b) }}
          />
        ))}
      </div>
    </div>
  );
}

function FallbackStage() {
  return (
    <>
      <picture>
        <source media={ADAM_MOBILE_QUERY} srcSet={FILES.fallbackMobile} />
        <img
          className="adam-fb-img"
          src={FILES.fallbackDesktop}
          width="1600"
          height="900"
          alt=""
          aria-hidden="true"
          loading="lazy"
          decoding="async"
          fetchpriority="low"
        />
      </picture>
      <p className="adam-eyebrow" data-adam="eyebrow" aria-hidden="true">{ADAM_EYEBROW}</p>
    </>
  );
}

function LiveStage({ mobile }) {
  const cv = mobile ? CANVAS.mobile : CANVAS.desktop;
  const files = mobile ? FILES.mobile : FILES.desktop;
  const grid = mobile ? GRID.mobile : GRID.desktop;
  const sz = { width: cv.w, height: cv.h };
  const origin = `${cv.tx}px ${cv.ty}px`;
  const handSrc = (who) => (mobile
    ? { src: files[who], srcSet: `${files[who]} 1x, ${files[`${who}2x`]} 2x` }
    : { src: files[who] });
  const img = (src, extra) => (
    <img className="adam-img" src={src} width={cv.w} height={cv.h} alt="" aria-hidden="true" decoding="async" draggable="false" style={sz} {...extra} />
  );
  const group = (who, name) => (
    <div key={who} className="adam-layer" data-adam={`${who}-group`} style={{ ...sz, transformOrigin: origin, willChange: 'transform' }}>
      {img(null, { ...handSrc(who), 'data-adam': 'hand-img', style: { ...sz, filter: `url(#${ADAM_KEY_FILTER_ID})` } })}
      <img className="adam-img adam-edge" data-adam="edge" src={files[`edge${name}`]} width={cv.w} height={cv.h} alt="" aria-hidden="true" decoding="async" draggable="false" style={{ ...sz, mixBlendMode: 'screen', opacity: 0 }} />
      <img className="adam-img" data-adam="bounce" src={files[`bounce${name}`]} width={cv.w} height={cv.h} alt="" aria-hidden="true" decoding="async" draggable="false" style={{ ...sz, mixBlendMode: 'screen', opacity: 0 }} />
    </div>
  );
  const centred = (w, h) => ({ position: 'absolute', left: cv.tx - w / 2, top: cv.ty - h / 2, width: w, height: h, transformOrigin: '50% 50%', mixBlendMode: 'screen', opacity: 0 });
  const full = { ...sz };

  return (
    <>
      <svg width="0" height="0" aria-hidden="true" focusable="false" style={{ position: 'absolute' }}>
        <defs>
          <filter id={ADAM_KEY_FILTER_ID} colorInterpolationFilters="sRGB" x="0" y="0" width="100%" height="100%">
            <feComponentTransfer>
              <feFuncR data-adam="kr" type="linear" slope="0.682" intercept="-0.1" />
              <feFuncG data-adam="kg" type="linear" slope="0.670" intercept="-0.1" />
              <feFuncB data-adam="kb" type="linear" slope="0.646" intercept="-0.1" />
            </feComponentTransfer>
          </filter>
        </defs>
      </svg>

      <div
        className="adam-canvas"
        data-adam="canvas"
        aria-hidden="true"
        style={{ ...sz, '--adam-tx': `${cv.tx}px`, '--adam-ty': `${cv.ty}px`, '--adam-d0': '120px' }}
      >
        <div className="adam-layer" data-adam="grid" style={full}>
          {grid.x.map((x) => <span key={`x${x}`} style={{ position: 'absolute', left: x, top: 0, width: 1, height: cv.h, background: 'rgba(255,244,230,0.08)' }} />)}
          {grid.y.map((y) => <span key={`y${y}`} style={{ position: 'absolute', top: y, left: 0, height: 1, width: cv.w, background: 'rgba(255,244,230,0.08)' }} />)}
          {grid.x.flatMap((x) => grid.y.map((y) => <span key={`p${x}-${y}`} className="adam-plus" style={{ left: x, top: y }} />))}
        </div>
        <div className="adam-layer" data-adam="warm" style={{ ...full, background: `radial-gradient(circle ${mobile ? 500 : 900}px at ${cv.w}px 0px, rgba(224,154,48,0.06), rgba(224,154,48,0) 100%)` }} />

        {group('adam', 'Adam')}
        {group('god', 'God')}

        <div className="adam-layer" data-adam="glow" style={full} />
        <div className="adam-layer" data-adam="bloom" style={{ ...full, mixBlendMode: 'screen', visibility: 'hidden' }} />
        <div className="adam-layer" data-adam="fan-wrap" style={{ ...full, transformOrigin: origin, mixBlendMode: 'screen' }}>
          <img className="adam-img" data-adam="fan-a" src={FILES.fanA} alt="" aria-hidden="true" decoding="async" draggable="false" style={{ ...centred(FAN_SIZE.a, FAN_SIZE.a), mixBlendMode: 'normal' }} />
          <img className="adam-img" data-adam="fan-b" src={FILES.fanB} alt="" aria-hidden="true" decoding="async" draggable="false" style={{ ...centred(FAN_SIZE.b, FAN_SIZE.b), mixBlendMode: 'normal' }} />
          <img className="adam-img" data-adam="fan-c" src={FILES.fanC} alt="" aria-hidden="true" decoding="async" draggable="false" style={{ ...centred(FAN_SIZE.c, FAN_SIZE.c), mixBlendMode: 'normal' }} />
        </div>
        <img className="adam-img" data-adam="hair" src={FILES.hair} alt="" aria-hidden="true" decoding="async" draggable="false" style={centred(760, 760)} />
        <img className="adam-img" data-adam="streak" src={FILES.streak} alt="" aria-hidden="true" decoding="async" draggable="false" style={centred(520, 17)} />
        <div className="adam-layer" data-adam="core" style={{ ...full, mixBlendMode: 'screen', visibility: 'hidden' }} />

        {/* Tip re-overlay: both hand layers again inside a 24 px disc at T. */}
        <div
          className="adam-layer"
          data-adam="tip"
          style={{
            ...full,
            opacity: 0,
            WebkitMaskImage: `radial-gradient(circle 24px at ${cv.tx}px ${cv.ty}px, #000 16px, transparent 24px)`,
            maskImage: `radial-gradient(circle 24px at ${cv.tx}px ${cv.ty}px, #000 16px, transparent 24px)`,
          }}
        >
          {img(null, handSrc('adam'))}
          {img(null, handSrc('god'))}
        </div>

        <div className="adam-layer" data-adam="grain" style={{ ...full, backgroundImage: GRAIN_URL, mixBlendMode: 'screen', opacity: 0.03 }} />
        {/* Brightness cap: no channel can exceed the field end colour (amber, never cream). */}
        <div className="adam-layer" data-adam="cap" style={{ ...full, background: FIELD_CAP, mixBlendMode: 'darken' }} />
      </div>

      {/* Stage-level liquid field (opacity = w). Drift lives on this element only, so the
          data-flat stage background (FIELD_UNDER) never has to match a drift state. */}
      <LiquidField live />

      <p className="adam-eyebrow" data-adam="eyebrow" aria-hidden="true">{ADAM_EYEBROW}</p>
      <div className="adam-final" data-adam="final">
        <span className="adam-final-h">{ADAM_FINAL_HEADLINE}</span>
        <span className="adam-final-b">{ADAM_FINAL_SUBTITLE}</span>
      </div>
    </>
  );
}

export default function AdamHands() {
  // First render is always the fallback (SSR-equal); the effect below upgrades
  // to the live stack on the client when motion is allowed.
  const [mode, setMode] = useState({ live: false, mobile: false });
  const sectionRef = useRef(null);
  const stageRef = useRef(null);

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return undefined;
    const rm = window.matchMedia('(prefers-reduced-motion: reduce)');
    const mo = window.matchMedia(ADAM_MOBILE_QUERY);
    const update = () => setMode((m) => {
      const next = { live: !rm.matches && typeof window.requestAnimationFrame === 'function', mobile: !!mo.matches };
      return m.live === next.live && m.mobile === next.mobile ? m : next;
    });
    update();
    const bind = (mq) => { if (mq.addEventListener) mq.addEventListener('change', update); else if (mq.addListener) mq.addListener(update); };
    const unbind = (mq) => { if (mq.removeEventListener) mq.removeEventListener('change', update); else if (mq.removeListener) mq.removeListener(update); };
    bind(rm); bind(mo);
    return () => { unbind(rm); unbind(mo); };
  }, []);

  useEffect(() => {
    if (!mode.live) return undefined;
    const section = sectionRef.current;
    const stage = stageRef.current;
    if (!section || !stage) return undefined;
    const refs = collect(stage);
    if (!refs.canvas) return undefined;

    const fit = () => {
      const s = coverScale(stage.clientWidth || 1, stage.clientHeight || 1, mode.mobile);
      refs.canvas.style.transform = `translate(-50%, -50%) scale(${s.toFixed(5)})`;
    };
    const readTarget = () => {
      const rect = section.getBoundingClientRect();
      return scrubProgress(rect.top, rect.height, stage.clientHeight || window.innerHeight);
    };

    // Per-visit variety: random drift start phase per blob. Client only, after mount (never in render).
    const blobEls = stage.querySelectorAll('.adam-field .adam-blob');
    blobEls.forEach((el, i) => { if (FIELD_BLOBS[i]) el.style.setProperty('--ph', adamPhase(FIELD_BLOBS[i].t, Math.random())); });

    let target = readTarget();
    let cur = target;
    let raf = 0;
    let last = 0;
    fit();
    paintFrame(refs, cur, mode.mobile);

    const tick = (now) => {
      raf = 0;
      const dt = last ? Math.min(0.1, (now - last) / 1000) : 1 / 60;
      last = now;
      cur = smoothStep(cur, target, dt);
      paintFrame(refs, cur, mode.mobile);
      if (cur !== target) raf = window.requestAnimationFrame(tick);
      else last = 0;
    };
    const kick = () => { if (!raf) raf = window.requestAnimationFrame(tick); };
    const onScroll = () => { target = readTarget(); kick(); };
    const onResize = () => { fit(); onScroll(); };

    // Capture phase on document: the app scrolls inside #root (html/body/#root
    // are height 100% with overflow-x hidden), so window never gets the event.
    document.addEventListener('scroll', onScroll, { passive: true, capture: true });
    window.addEventListener('resize', onResize);
    let ro = null;
    if (typeof ResizeObserver !== 'undefined') { ro = new ResizeObserver(onResize); ro.observe(stage); }
    return () => {
      document.removeEventListener('scroll', onScroll, { capture: true });
      window.removeEventListener('resize', onResize);
      if (ro) ro.disconnect();
      if (raf) window.cancelAnimationFrame(raf);
    };
  }, [mode.live, mode.mobile]);

  return (
    <section ref={sectionRef} className="adam-pin" data-live={mode.live ? 'true' : 'false'} data-testid="adam-hands">
      <style>{ADAM_CSS}</style>
      <div ref={stageRef} className="adam-stage" data-flat="false">
        {mode.live ? <LiveStage key={mode.mobile ? 'm' : 'd'} mobile={mode.mobile} /> : <FallbackStage />}
      </div>
      {!mode.live && <div className="adam-grad" aria-hidden="true" />}
      {!mode.live && (
        <div className="adam-fbfield" data-testid="adam-fallback-field">
          <LiquidField />
          <div className="adam-fbfield-in">
            <span className="adam-final-h">{ADAM_FINAL_HEADLINE}</span>
            <span className="adam-final-b">{ADAM_FINAL_SUBTITLE}</span>
          </div>
        </div>
      )}
    </section>
  );
}
