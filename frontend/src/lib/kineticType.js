// Pure maths for the scroll-driven kinetic typography of the .hm-fam head (task 20261111-kinetic-type-marble,
// design-spec.md section 2). No DOM, no React: scene progress q in [0, 1] maps to a per-unit style, so it is
// unit-testable and Home.jsx only has to write the numbers.
//
// Units: u0 = the eyebrow, u1..u10 = the ten words of the h2. Every unit runs the same eased arrival (never linear),
// staggered along q. The scene is a pinned head over the pinned marble stage; q = 0 when the head pins, 1 when it unpins.
import { clamp, smooth, cubicBezier } from './adamHands/driver.js';

export const KINETIC_UNITS = 11; // eyebrow + ten words
export const Q_START = 0.04; // first unit starts
export const Q_END = 0.74; // last unit lands; 0.74 .. 1 is the hold before the unpin
export const DUR = 0.30; // each unit's own travel in q
// Stagger between consecutive units: (Q_END - Q_START - DUR) / (N - 1) = 0.04.
export const STAGGER = (Q_END - Q_START - DUR) / (KINETIC_UNITS - 1);
export const settleEase = cubicBezier(0.16, 1, 0.3, 1);
const circleEase = cubicBezier(0.65, 0, 0.35, 1);
export const CIRCLE_Q = [0.68, 0.88];

export const unitStart = (i) => Q_START + i * STAGGER;
export const unitEnd = (i) => unitStart(i) + DUR;
// Unit-local linear progress t_i and its eased value e_i.
export const unitT = (i, q) => clamp((q - unitStart(i)) / DUR);
export const unitE = (i, q) => settleEase(unitT(i, q));

// Circle around "family": draws after the word is ~80% opaque, ends with a hold.
export const circleP = (q) => circleEase(clamp((q - CIRCLE_Q[0]) / (CIRCLE_Q[1] - CIRCLE_Q[0])));

// Scene progress from the scene's bounding rect: -top / (height - viewport), clamped. Identical to
// (p - TYPE_START_P) / (P_END - TYPE_START_P) in the pinned region (driver.js).
export const sceneProgress = (rectTop, rectHeight, vh) => {
  const span = rectHeight - vh;
  return span > 0 ? clamp(-rectTop / span) : 0;
};

// Style numbers for one unit. Full power: opacity, translate (em), scale, blur (px), light glow g in [0, 1].
// Low power (phones): opacity + translateY only, the same stagger and easing; no blur, glow, x drift or scale.
export function unitStyle(i, q, lowPower = false) {
  const t = unitT(i, q);
  const e = settleEase(t);
  const eyebrow = i === 0;
  const opacity = smooth(t / 0.45);
  const rest = 1 - e;
  if (lowPower) return { opacity, x: 0, y: rest * 0.55, scale: 1, blur: 0, glow: 0 };
  return {
    opacity,
    x: eyebrow ? 0 : rest * 0.18 * (i % 2 === 1 ? -1 : 1),
    y: rest * 0.55,
    scale: eyebrow ? 1 : 0.96 + 0.04 * e,
    blur: eyebrow ? 0 : rest * 14,
    glow: eyebrow ? 0 : 1 - smooth(t / 0.9),
  };
}

// The same numbers as CSS strings. Filter and text-shadow are only emitted while the unit is travelling
// (0 < t < 1 / glow > 0); a resting unit gets 'none', so a finished word carries no filter cost.
export function unitCss(i, q, lowPower = false) {
  const s = unitStyle(i, q, lowPower);
  const t = unitT(i, q);
  const moving = t > 0 && t < 1;
  const tf = lowPower ? `translateY(${s.y.toFixed(4)}em)` : `translate(${s.x.toFixed(4)}em, ${s.y.toFixed(4)}em) scale(${s.scale.toFixed(4)})`;
  return {
    opacity: s.opacity < 0.003 ? '0' : s.opacity.toFixed(3),
    transform: moving ? tf : 'none',
    filter: !lowPower && moving && s.blur > 0.05 ? `blur(${s.blur.toFixed(2)}px)` : 'none',
    textShadow: !lowPower && moving && s.glow > 0.003
      ? `0 0 ${(s.glow * 28).toFixed(1)}px rgba(255,226,170,${(s.glow * 0.7).toFixed(3)})`
      : 'none',
  };
}

// Scrim backstop opacity: the head sits in the viewport (over the white hold) for a stretch before q = 0 while the
// hand-off is still running, so its dark scrim must not show then (over the white hold it reads as grey mud). It
// stays off until the light has withdrawn from the text zone (q 0 .. SCRIM_START_Q) and fades in over SCRIM_Q after that.
export const SCRIM_START_Q = 0.07;
export const SCRIM_Q = 0.08;
export const scrimOpacity = (q) => smooth((q - SCRIM_START_Q) / SCRIM_Q);
