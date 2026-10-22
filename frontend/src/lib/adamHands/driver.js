// Pure scroll-driver maths for the pinned "Creation of Adam" hero section
// (task 20261015-adam-hands-scroll-hero). No DOM, no React: everything here maps
// a scrub progress p in [0, 1] to numbers, so it is unit-testable and the
// component only has to paint them.
//
// Source of truth: rev2 assets README section 5 (drivers), section 6 (hand
// transform per beat, easing B) and data/transform-table.json. Do not tune the
// constants here without re-checking them against those files.
import { DESKTOP_ROWS, MOBILE_ROWS } from './table.js';

export const TOUCH_P = 0.80;
export const FLOOD_END_P = 0.97;
export const TABLE_STEP = 0.02;

export const CANVAS = {
  desktop: { w: 1600, h: 900, tx: 800, ty: 432 },
  mobile: { w: 900, h: 1600, tx: 450, ty: 736 },
};

// Scrub domain (design spec, task 20261022-hands-scroll-grain-gradient). p now runs
// 0 .. P_END; every constant above 1.0 is new, everything at or below 1.0 is the
// original hands/flood timeline and is unchanged (its drivers clamp, so they hold
// their old end state for p > 1).
export const BASE_SPAN_VH = { desktop: 220, mobile: 160 };
export const BAND_START_P = 0.84; // the light band's soft leading edge enters from below
export const WHITE_HOLD_P = 0.05;
export const FILL2_START_P = FLOOD_END_P + WHITE_HOLD_P; // 1.02: the band lifts off, revealing the field
export const FILL2_DELAY_P = FILL2_START_P - TOUCH_P; // touch -> second fill (about 2 s of the mov)
export const FILL2_SPAN_P = 0.09;
export const FILL2_END_P = FILL2_START_P + FILL2_SPAN_P; // 1.11: band clear of the stage
export const LEAKS_START_P = 0.78; // first free streak (s0) starts before the touch
export const LEAKS_END_P = 1.16; // every leak is fully off here, before the Family reveal
export const SETTLE_SPAN_P = 0.12;
export const SETTLE_END_P = FILL2_END_P + SETTLE_SPAN_P; // 1.23
export const FAMILY_REVEAL_P = [1.19, 1.26];
export const FAMILY_HIDE_P = [1.38, 1.46];
export const VERSE_START_P = 1.40;
export const VERSE_SPAN_P = { desktop: 1.20, mobile: 1.50 };
const r6 = (x) => Math.round(x * 1e6) / 1e6;
export const P_END = { desktop: r6(VERSE_START_P + VERSE_SPAN_P.desktop), mobile: r6(VERSE_START_P + VERSE_SPAN_P.mobile) };
// Landscape-phone / stacked-verse mode: the pinned stage stops where the verses would start.
export const P_END_STACK = VERSE_START_P;
// Runway = one stage plus P_END base spans. Single place for the formula.
export const runwayVh = (pEnd, baseSpanVh) => Math.round(100 + pEnd * baseSpanVh);
export const RUNWAY_VH = {
  desktop: runwayVh(P_END.desktop, BASE_SPAN_VH.desktop),
  mobile: runwayVh(P_END.mobile, BASE_SPAN_VH.mobile),
};
export const RUNWAY_VH_STACK = {
  desktop: runwayVh(P_END_STACK, BASE_SPAN_VH.desktop),
  mobile: runwayVh(P_END_STACK, BASE_SPAN_VH.mobile),
};
// Scrub smoothing: time constant of the exponential chase. 0.2 s reaches 95% of
// a jump in about 0.6 s ("scrub ~0.6").
export const SMOOTH_TAU_S = 0.2;

export const clamp = (x, lo = 0, hi = 1) => (x < lo ? lo : x > hi ? hi : x);
export const lerp = (a, b, t) => a + (b - a) * t;
export const smooth = (x) => { const t = clamp(x); return t * t * (3 - 2 * t); };

// CSS-style cubic-bezier(x1, y1, x2, y2) solved with Newton + bisection.
export function cubicBezier(x1, y1, x2, y2) {
  const cx = 3 * x1; const bx = 3 * (x2 - x1) - cx; const ax = 1 - cx - bx;
  const cy = 3 * y1; const by = 3 * (y2 - y1) - cy; const ay = 1 - cy - by;
  const sx = (t) => ((ax * t + bx) * t + cx) * t;
  const sy = (t) => ((ay * t + by) * t + cy) * t;
  const dx = (t) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const err = sx(t) - x;
      if (Math.abs(err) < 1e-7) return sy(t);
      const d = dx(t);
      if (Math.abs(d) < 1e-6) break;
      t -= err / d;
    }
    let lo = 0; let hi = 1; t = x;
    for (let i = 0; i < 40; i++) {
      const v = sx(t);
      if (Math.abs(v - x) < 1e-7) break;
      if (v < x) lo = t; else hi = t;
      t = (lo + hi) / 2;
    }
    return sy(t);
  };
}

export const floodCurve = cubicBezier(0.65, 0, 0.35, 1);

// Easing B (chosen): p_eff = 0.8 * (1 - (1 - p / 0.8)^2) on [0, 0.8], held at
// 0.8 after. The shipped option-B table rows are ALREADY evaluated at this warp
// (beat 2 is the p = 0.20 row, beat 3 the p = 0.517 row), so lookupRow() takes
// the raw scrub p. easingB is exported to document and test that equivalence.
export function easingB(p) {
  if (p <= 0) return 0;
  if (p >= TOUCH_P) return TOUCH_P;
  const u = 1 - p / TOUCH_P;
  return TOUCH_P * (1 - u * u);
}

export function getRows(mobile) { return mobile ? MOBILE_ROWS : DESKTOP_ROWS; }

// Linear interpolation between the 0.02-spaced rows. p is clamped to [0, 0.8].
// Returns the row as an array in TABLE_COLUMNS order (p replaced by the query p).
export function lookupRow(rows, p) {
  const q = clamp(p, 0, TOUCH_P);
  const i = Math.min(rows.length - 2, Math.floor(q / TABLE_STEP + 1e-9));
  const a = rows[i]; const b = rows[i + 1];
  const t = clamp((q - a[0]) / (b[0] - a[0]));
  const out = new Array(a.length);
  for (let k = 0; k < a.length; k++) out[k] = lerp(a[k], b[k], t);
  out[0] = q;
  return out;
}

export function handsPose(p, mobile) {
  const r = lookupRow(getRows(mobile), p);
  return {
    adam: { tx: r[1], ty: r[2] },
    god: { tx: r[3], ty: r[4] },
    scale: r[5],
    slope: [r[6], r[7], r[8]],
    intercept: r[9],
    rim: r[10],
    bounce: r[11],
  };
}

// README section 5 drivers.
export function floodDrivers(p) {
  const t = clamp((p - 0.80) / 0.17);
  const f = floodCurve(t);
  const g = smooth((p - 0.80) / 0.06);
  const w = smooth((p - 0.91) / 0.06);
  const A = (0.6 + 0.4 * g) * (1 - smooth((f - 0.15) / 0.45));
  const e = 1 - smooth((p - 0.89) / 0.04);
  const c = smooth((p - 0.85) / 0.04);
  const fanG = smooth(f / 0.30);
  const tipS = 0.35 * (1 - smooth(f / 0.35));
  return { t, f, g, w, A, e, c, fanG, tipS };
}

// Sizes derived from f and g (README section 5, "Sizes").
export function lightParams(f, g) {
  return {
    sigma: 4 + 60 * f,
    r0: 18 + 917 * f,
    k: 0.30 + 0.80 * f,
    fanLength: 60 + 1040 * f,
    fanBlur: 2 + 12 * clamp((f - 0.10) / 0.90),
    fanRotateDeg: 3 * f,
    hairScale: (1 + 0.6 * g) / 1.6,
    streakScaleX: (300 + 200 * g) / 500,
    rimReach: 120 + 780 * f,
    bounceLive: 0.10 + 0.25 * f,
  };
}

// Pre-rendered fan sprites: a (L 270), b (L 670), c (L 1100). Cross-fade by f.
export const FAN_REF = { a: 270, b: 670, c: 1100 };
export function fanWeights(f) {
  const wa = 1 - smooth(f / 0.4);
  const wc = smooth((f - 0.5) / 0.5);
  const wb = clamp(1 - wa - wc);
  return { a: wa, b: wb, c: wc };
}

// Radial intensity of the live bloom at distance r (px): Wn(r) * k / (1 + (r/r0)^2).
export function bloomIntensity(r, r0, k) {
  const wn = 1 - smooth((r - r0) / (0.9 * r0));
  return wn * k / (1 + (r / r0) * (r / r0));
}

// Touch light only ignites as the fingertips close; before that the beat 1-3
// glows own the gap. Beats 1 to 3 and the touch frame are exact at p <= 0.66
// and p >= 0.80, the ramp only joins them without a pop.
export function ignite(p) { return smooth((p - 0.66) / 0.14); }

// Beat 1-3 glow (live radial, centred midway between the two fingertips).
// Beat 1: #E09A30 r128 a0.12; beat 2: #E09A30 r128 a0.30; beat 3: #F3C48B r40 a0.60.
const GLOW_BEATS = [
  { p: 0, color: [224, 154, 48], r: 128, a: 0.12 },
  { p: 0.2, color: [224, 154, 48], r: 128, a: 0.30 },
  { p: 0.5172, color: [243, 196, 139], r: 40, a: 0.60 },
];
export function beatGlow(p, pose, mobile) {
  const q = clamp(p, 0, TOUCH_P);
  let i = 0;
  while (i < GLOW_BEATS.length - 2 && q > GLOW_BEATS[i + 1].p) i++;
  const a = GLOW_BEATS[i]; const b = GLOW_BEATS[i + 1];
  const t = clamp((q - a.p) / (b.p - a.p));
  const s = mobile ? 0.658 : 1;
  const cv = mobile ? CANVAS.mobile : CANVAS.desktop;
  return {
    x: cv.tx + (pose.adam.tx + pose.god.tx) / 2,
    y: cv.ty + (pose.adam.ty + pose.god.ty) / 2,
    r: lerp(a.r, b.r, t) * s,
    alpha: lerp(a.a, b.a, t) * (1 - ignite(p)),
    color: [0, 1, 2].map((k) => Math.round(lerp(a.color[k], b.color[k], t))),
  };
}

// Final-frame type reveal (design spec): opacity = smooth((p - 0.955) / 0.035).
export function typeReveal(p) { return smooth((p - 0.955) / 0.035); }

// Warm upper-right glow, beats 1-3 only (README section 2, "Not shipped").
export function warmGlowAlpha(p, e) { return e * (1 - smooth((p - 0.66) / 0.14)); }

// Eyebrow colour: #F0C08A -> #1A1512 by c.
export function eyebrowColor(c) {
  const a = [0xF0, 0xC0, 0x8A]; const b = [0x1A, 0x15, 0x12];
  return a.map((v, i) => Math.round(lerp(v, b[i], c)));
}

// Light transition (design-spec-r2.md R2-3): ONE tall, noise-masked, slightly rotated
// band of warm light travels up through the stage. Its soft leading edge is the first
// fill, its solid body is the white hold, its soft trailing edge is the second fill
// (the field shows behind it). Plus free anamorphic streaks and edge leaks. No circles.
// Geometry in units of stage height H; y = top edge of the band element (0 = stage top).
export const BAND = { yStart: 1.12, yCover: -0.57, yHoldEnd: -0.63, yClear: -2.37, F1: 0.45, Bd: 1.30, F2: 0.50 };
export const BAND_HEIGHT = BAND.F1 + BAND.Bd + BAND.F2; // 2.25 H
const bandEaseA = cubicBezier(0.30, 0, 0.40, 1);
const bandEaseB = cubicBezier(0.35, 0.05, 0.35, 1);
export function bandY(p) {
  if (p <= BAND_START_P) return BAND.yStart;
  if (p < FLOOD_END_P) return lerp(BAND.yStart, BAND.yCover, bandEaseA((p - BAND_START_P) / (FLOOD_END_P - BAND_START_P)));
  if (p < FILL2_START_P) return lerp(BAND.yCover, BAND.yHoldEnd, (p - FLOOD_END_P) / (FILL2_START_P - FLOOD_END_P));
  if (p < FILL2_END_P) return lerp(BAND.yHoldEnd, BAND.yClear, bandEaseB((p - FILL2_START_P) / (FILL2_END_P - FILL2_START_P)));
  return BAND.yClear;
}

// Free streaks s0..s4: a = start p, y = % of stage, h = cqh, d = rise (cqh), tone, mobile = kept on mobile.
export const STREAKS = [
  { a: 0.78, y: 48, h: 1.9, d: 6, tone: 'white', mobile: true, mh: 1.2 },
  { a: 0.81, y: 41, h: 1.3, d: 11, tone: 'gold', mobile: false },
  { a: 0.83, y: 57, h: 1.6, d: 9, tone: 'white', mobile: true, mh: 1.0 },
  { a: 0.85, y: 30, h: 1.0, d: 13, tone: 'amber', mobile: false },
  { a: 0.86, y: 65.9, h: 1.2, d: 8, tone: 'gold', mobile: false },
];
export const STREAK_END_P = 1.03;
const streakEaseOut = cubicBezier(0.2, 0.7, 0.2, 1);
// Edge leaks e1..e4: in = [start, full], out = [start, gone] windows (scroll p), o = peak opacity.
export const EDGES = [
  { id: 'e1', inW: [0.80, 0.92], outW: [1.00, 1.12], o: 0.90, mobile: true },
  { id: 'e2', inW: [0.83, 0.95], outW: [1.02, 1.13], o: 0.85, mobile: false },
  { id: 'e3', inW: [0.81, 0.91], outW: [1.03, 1.11], o: 0.95, mobile: true },
  { id: 'e4', inW: [0.90, 0.97], outW: [1.08, 1.16], o: 0.70, mobile: false },
];

export function leakDrivers(p, mobile = false) {
  const streaks = STREAKS.map((s) => {
    const on = p >= s.a && p <= STREAK_END_P && (!mobile || s.mobile);
    if (!on) return { on: false, sx: 0.25, ty: 0, o: 0 };
    return {
      on,
      sx: lerp(0.25, 1, streakEaseOut((p - s.a) / 0.12)),
      ty: -s.d * smooth((p - s.a) / 0.20),
      o: smooth((p - s.a) / 0.06) * (1 - smooth((p - 0.96) / 0.07)),
    };
  });
  const edges = EDGES.map((e) => {
    const o = e.o * smooth((p - e.inW[0]) / (e.inW[1] - e.inW[0])) * (1 - smooth((p - e.outW[0]) / (e.outW[1] - e.outW[0])));
    const on = (!mobile || e.mobile) && o > 0.002;
    return { on, o: on ? o : 0, tx: lerp(-4, 4, smooth((p - e.inW[0]) / (e.outW[1] - e.inW[0]))) };
  });
  return {
    bandY: bandY(p),
    bandOn: p > BAND_START_P && p < FILL2_END_P,
    streaks,
    edges,
    leavesOn: p >= LEAKS_START_P && p < LEAKS_END_P,
  };
}

// Field timing: the opaque field sits above the canvas once the band is solid.
export function fill2Drivers(p) {
  return {
    u: clamp((p - FILL2_START_P) / FILL2_SPAN_P),
    settle: smooth((p - FILL2_END_P) / SETTLE_SPAN_P),
    fieldOn: p >= FILL2_START_P - 0.005,
    handsHidden: p >= FILL2_START_P,
  };
}

// "Family" headline: reveal then hide before the first verse reaches mid-stage.
// keep = true (stacked mode, no verses on the stage) never hides it.
export function familyOpacity(p, keep = false) {
  const [r0, r1] = FAMILY_REVEAL_P; const [h0, h1] = FAMILY_HIDE_P;
  const reveal = smooth((p - r0) / (r1 - r0));
  return keep ? reveal : reveal * (1 - smooth((p - h0) / (h1 - h0)));
}

// Scrub progress for a pinned section: distance scrolled into the runway over
// the base span (baseSpanVh of the stage height; equal to sectionHeight -
// stageHeight for a runway of 100 + baseSpanVh), clamped to [0, pEnd]. Without
// baseSpanVh it falls back to the original sectionHeight - stageHeight span.
export function scrubProgress(rectTop, sectionHeight, stageHeight, baseSpanVh, pEnd = 1) {
  const span = baseSpanVh ? (baseSpanVh / 100) * stageHeight : sectionHeight - stageHeight;
  if (span <= 0) return 0;
  return clamp(-rectTop / span, 0, pEnd);
}

// Frame-rate independent exponential chase toward the target p.
export function smoothStep(current, target, dtSeconds, tau = SMOOTH_TAU_S) {
  if (dtSeconds <= 0) return current;
  const k = 1 - Math.exp(-dtSeconds / tau);
  const next = current + (target - current) * k;
  return Math.abs(target - next) < 0.0004 ? target : next;
}

// Scale that makes a W x H canvas cover a stage (object-fit: cover).
export function coverScale(stageW, stageH, mobile) {
  const cv = mobile ? CANVAS.mobile : CANVAS.desktop;
  return Math.max(stageW / cv.w, stageH / cv.h);
}
