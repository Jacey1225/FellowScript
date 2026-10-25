// Pure verse depth maths (design spec 20261024-verses-depth-liquid, sections 1 to 3).
// Cards start NEAR the camera (large, in frame) and are pulled backwards toward a
// vanishing region as the hero scrubs; they go soft, then dim, then vanish with distance.
// The widgets are painted by direct style writes from the hero's paint loop; nothing
// here touches the DOM.
import { clamp, lerp, smooth, VERSE_START_P, VERSE_SPAN_P } from './adamHands/driver.js';

// Per-widget travel window in verse progress v (0..1). Mobile stacks cards at one spot (one card
// reads at a time), so it uses a shorter window = longer gap before the next arrives, which
// gives the front card time to blur and fade before it hands over.
export const VERSE_D = { desktop: 0.45, mobile: 0.30 };
// Depth Z in focal units: 1 is the reading plane. [near, far] per layout.
export const VERSE_Z = { desktop: [0.72, 4.2], mobile: [1.0, 4.0] };
export const VERSE_VP = { x: 50, y: 44 }; // vanishing point, % of stage
// World offsets from the vanishing point, fractions of W (ox) and H (oy) at Z = 1.
export const VERSE_OFFSETS = {
  desktop: { ox: [-0.22, 0.20, -0.12, 0.22, 0.00], oy: [-0.06, 0.08, -0.14, 0.10, -0.02] },
  mobile: { ox: [0, 0.04, -0.04, 0.04, 0], oy: [-0.06, 0.08, -0.12, 0.10, -0.02] },
};
export const VERSE_NEAR_IN = 0.12; // u span of the opacity ramp-in
// Ramps are smoothstep over log depth (constant rate per unit of scroll) and are the SAME for every card:
// blur builds from just behind the reading plane to Z 3.4, opacity from Z 1.2 to gone at Z 3.9.
export const VERSE_FADE_Z = { op: [1.2, 3.9], blur: [0.8, 3.4] };
export const VERSE_BLUR_MAX = { desktop: 9, mobile: 6 };
export const VERSE_BF_Z = 1.9; // backdrop-filter only while Z <= this
export const VERSE_ALPHA = { near: 0.72, far: 0.86, z: [1.7, 2.1], mobile: 0.93 };
// Cursor follow is a critically damped spring (no overshoot, no wobble), integrated in closed form so
// it is frame-rate independent. w is the natural rate (1/s); the 63% settle time of the step
// response is SPRING_T63 / w: near cards ~0.45 s, far cards ~0.65 s. Easing back to neutral when the
// cursor leaves runs at returnScale * w (about 1.7x slower), so cards drift home instead of snapping.
export const SPRING_T63 = 2.146;
export const PARALLAX = { amp: 48, wNear: 4.77, wFar: 3.30, returnScale: 0.58 };
export const VERSE_STACK_QUERY = '(prefers-reduced-motion: reduce), (max-height: 520px) and (orientation: landscape)';
export const VERSE_LABEL = 'Scripture on community';

export const verseStep = (n, d = VERSE_D.desktop) => (n > 1 ? (1 - d) / (n - 1) : 0);

// Verse-phase progress v in [0, 1] from the hero scrub p.
export const verseProgress = (p, mobile) => clamp((p - VERSE_START_P) / VERSE_SPAN_P[mobile ? 'mobile' : 'desktop']);

const ramp = (z, [a, b]) => smooth((Math.log(z) - Math.log(a)) / (Math.log(b) - Math.log(a)));
const q = (x, step) => Math.round(x / step) * step;

// Depth of a card at own progress u (geometric, so apparent shrink speed is constant per scroll).
export const depthZ = (u, mobile) => { const [zn, zf] = VERSE_Z[mobile ? 'mobile' : 'desktop']; return zn * (zf / zn) ** u; };

// Per-widget state: u (own travel 0..1), z (depth), scale (of the near-size layout),
// xPct / yPct (card centre, % of stage W / H, before parallax), opacity, blur (px),
// backdrop (glass blur allowed), alpha (glass fill), visible.
export function verseState(i, n, p, mobile) {
  const v = verseProgress(p, mobile);
  const k = mobile ? 'mobile' : 'desktop';
  const d = VERSE_D[k];
  const u = clamp((v - i * verseStep(n, d)) / d);
  const [zn] = VERSE_Z[k];
  const z = depthZ(u, mobile);
  const o = VERSE_OFFSETS[k];
  const opacity = smooth(u / VERSE_NEAR_IN) * (1 - ramp(z, VERSE_FADE_Z.op));
  const blur = q(VERSE_BLUR_MAX[k] * ramp(z, VERSE_FADE_Z.blur) ** 1.2, 0.5);
  const alpha = mobile ? VERSE_ALPHA.mobile : lerp(VERSE_ALPHA.near, VERSE_ALPHA.far, ramp(z, VERSE_ALPHA.z));
  return {
    u,
    z,
    scale: zn / z,
    xPct: VERSE_VP.x + (o.ox[i % o.ox.length] * 100) / z,
    yPct: VERSE_VP.y + (o.oy[i % o.oy.length] * 100) / z,
    opacity,
    blur,
    backdrop: !mobile && z <= VERSE_BF_Z,
    alpha,
    visible: u > 0 && opacity > 0.01,
  };
}

// Critically damped spring, exact solution over dt (any dt, any frame rate, never overshoots
// when starting at rest). Pure: returns the next [x, v].
export function springStep(x, v, target, w, dt) {
  const c1 = x - target;
  const c2 = v + w * c1;
  const e = Math.exp(-w * dt);
  return [target + (c1 + c2 * dt) * e, (c2 - w * (c1 + c2 * dt)) * e];
}
// Per-card spring rate: near cards slightly quicker, far cards trail (all relaxed).
export const springOmega = (z, mobile) => {
  const [zn, zf] = VERSE_Z[mobile ? 'mobile' : 'desktop'];
  return lerp(PARALLAX.wNear, PARALLAX.wFar, clamp((z - zn) / (zf - zn)));
};
// Pointer-to-offset target for a card at depth z (nearer cards move more).
export const parallaxTarget = (nx, ny, z) => [nx * PARALLAX.amp / z, ny * PARALLAX.amp / z];

// Widget colours (design spec section 7). Fill is composited over whatever is behind it;
// tests bound the contrast over warm white (FIELD_WHITE) and the lightest field colour (honey).
export const VERSE_FILL = { rgb: [34, 19, 6], a: 0.72, farA: 0.86, fallbackA: 0.93 };
export const VERSE_INK = '#FBF7F1';
export const VERSE_REF_INK = '#F4E3C3';
