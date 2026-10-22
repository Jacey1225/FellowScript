// The light transition for the hero (design-spec.md section 2): a lens-gleam bloom that
// opens at the screen centre and swells outward as six overlapping soft lobes of different
// size, tilt and delay, plus an anamorphic streak, ghost glints and uneven rays. It holds a
// full-screen overexposed beat, then falls back toward its own centre over the live field.
// Markup is static; per frame only transform / opacity / visibility are written
// (paintLens), so no gradient is ever repainted. Maths: lib/adamHands/driver.js (lensDrivers).
import React from 'react';
import { lensDrivers, LENS_LOBES, LENS_MOBILE_LOBES, LENS_GHOSTS } from '../lib/adamHands/driver.js';
import { FIELD_WHITE, LEAK_PEACH, LEAK_GOLD, LEAK_HONEY } from '../lib/adamHands/field.js';

// Isotropic fractal-noise alpha mask: soft irregular holes that never go fully clear.
const LENS_NOISE = `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='1024' height='1024'><filter id='n' x='0' y='0' width='100%' height='100%' color-interpolation-filters='sRGB'><feTurbulence type='fractalNoise' baseFrequency='.006' numOctaves='3' seed='11' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  1.7 0 0 0 -.05'/></filter><rect width='1024' height='1024' filter='url(%23n)'/></svg>")`;
// Flare-style falloff with an amber shoulder (the fringe that reads as light bending).
export const LOBE_GRAD = 'radial-gradient(ellipse 50% 50% at 50% 50%, #FFF6E4 0, #FFF4DC 32%, rgba(255,244,220,.96) 46%, rgba(255,226,170,.58) 62%, rgba(224,154,48,.26) 76%, rgba(180,113,44,.07) 89%, rgba(180,113,44,0) 100%)';
const CORE_GRAD = 'radial-gradient(ellipse 50% 50% at 50% 50%, #FFFAF0 0, rgba(255,246,228,.92) 30%, rgba(255,226,170,.50) 60%, rgba(255,226,170,0) 100%)';
const STREAK_GRAD = 'radial-gradient(ellipse 50% 50% at 50% 50%, rgba(255,246,228,.95) 0, rgba(255,226,170,.55) 30%, rgba(224,154,48,.20) 62%, rgba(224,154,48,0) 100%)';
const ghostGrad = (c) => `radial-gradient(ellipse 50% 50% at 50% 50%, ${c} 0, ${c} 35%, rgba(255,226,170,0) 100%)`;
const GHOST_COLOR = [LEAK_PEACH, LEAK_GOLD, LEAK_HONEY];
const GHOST_ROT = -18; // all three sit on one oblique axis through the origin
// Spokes [angle deg, width deg, alpha]: uneven on purpose, so the reach differs at every angle.
const SPOKES = [[6, 3.5, 0.9], [31, 1.6, 0.55], [52, 4.2, 0.8], [79, 2.0, 0.4], [104, 5.0, 1], [131, 1.8, 0.6], [158, 3.0, 0.7],
  [183, 4.6, 0.85], [207, 1.4, 0.35], [231, 3.8, 0.9], [262, 2.2, 0.5], [289, 5.4, 1], [318, 1.9, 0.6], [344, 3.2, 0.75]];
const RAYS_MASK = `conic-gradient(from 0deg at 50% 50%, ${SPOKES.map(([a, w, o]) => `rgba(0,0,0,0) ${(a - w / 2).toFixed(1)}deg, rgba(0,0,0,${o}) ${a}deg, rgba(0,0,0,0) ${(a + w / 2).toFixed(1)}deg`).join(', ')}, rgba(0,0,0,0) 360deg)`;

export const LENS_CSS = `
.adam-lens { --u: max(1cqw, 1cqh); position: absolute; inset: 0; overflow: hidden; isolation: isolate; pointer-events: none; visibility: hidden; }
.lens-flat { position: absolute; inset: 0; background: ${FIELD_WHITE}; opacity: 0; }
.lens-o { position: absolute; left: 50%; top: 50%; width: 0; height: 0; }
.lens-wash { position: absolute; inset: 0; -webkit-mask-image: ${LENS_NOISE}; mask-image: ${LENS_NOISE}; -webkit-mask-size: 1024px 1024px; mask-size: 1024px 1024px; -webkit-mask-repeat: repeat; mask-repeat: repeat; }
.lens-lobe, .lens-core-lobe, .lens-streak, .lens-ghost, .lens-rays { position: absolute; left: 0; top: 0; opacity: 0; transform-origin: 50% 50%; transform: translate(-50%, -50%) scale(0); }
.lens-lobe { background: ${LOBE_GRAD}; }
.lens-core-lobe { background: ${CORE_GRAD}; mix-blend-mode: screen; }
.lens-streak { width: calc(150 * var(--u)); height: 1.3cqh; background: ${STREAK_GRAD}; mix-blend-mode: screen; }
.lens-ghost { mix-blend-mode: screen; }
.lens-rays { width: calc(200 * var(--u)); height: calc(200 * var(--u)); background: radial-gradient(circle closest-side, rgba(255,246,228,.80) 0, rgba(255,226,170,.35) 40%, rgba(255,226,170,0) 100%); mix-blend-mode: screen;
  -webkit-mask-image: ${RAYS_MASK}, ${LENS_NOISE}; mask-image: ${RAYS_MASK}, ${LENS_NOISE}; -webkit-mask-size: 100% 100%, 1024px 1024px; mask-size: 100% 100%, 1024px 1024px; -webkit-mask-composite: source-in; mask-composite: intersect; }
.adam-lens[data-on="true"] .lens-lobe, .adam-lens[data-on="true"] .lens-core-lobe, .adam-lens[data-on="true"] .lens-streak, .adam-lens[data-on="true"] .lens-ghost, .adam-lens[data-on="true"] .lens-rays { will-change: transform, opacity; }
@media (max-width: 899px), (pointer: coarse) {
  .lens-wash { -webkit-mask-size: 768px 768px; mask-size: 768px 768px; }
  .lens-streak { mix-blend-mode: normal; }
}
@media (prefers-reduced-motion: reduce) { .adam-lens { display: none; } }
`;

export function LensBloom({ mobile = false }) {
  const lobes = LENS_LOBES.slice(0, mobile ? LENS_MOBILE_LOBES : LENS_LOBES.length);
  return (
    <div className="adam-lens" data-adam="lens" aria-hidden="true">
      <div className="lens-flat" data-adam="lens-flat" />
      <div className="lens-o">
        <div className="lens-wash">
          {lobes.map((l, i) => (
            <i key={l.id} className="lens-lobe" data-adam={`lens-lobe-${i}`} style={{ width: `calc(${2 * l.rx} * var(--u))`, height: `calc(${2 * l.ry} * var(--u))` }} />
          ))}
        </div>
        {[0, 1].map((i) => (
          <i key={`c${i}`} className="lens-core-lobe" data-adam={`lens-core-${i}`} style={{ width: `calc(${2 * LENS_LOBES[i].rx} * var(--u))`, height: `calc(${2 * LENS_LOBES[i].ry} * var(--u))` }} />
        ))}
        <i className="lens-streak" data-adam="lens-streak" />
        {!mobile && LENS_GHOSTS.map((g, i) => (
          <i key={g.id} className="lens-ghost" data-adam={`lens-ghost-${i}`} style={{ width: `calc(${g.w} * var(--u))`, height: `calc(${g.h} * var(--u))`, background: ghostGrad(GHOST_COLOR[i]) }} />
        ))}
        {!mobile && <i className="lens-rays" data-adam="lens-rays" />}
      </div>
    </div>
  );
}

export const collectLens = (q) => ({
  lens: q('lens'),
  lensFlat: q('lens-flat'),
  lensLobes: [0, 1, 2, 3, 4, 5].map((i) => q(`lens-lobe-${i}`)).filter(Boolean),
  lensCore: [q('lens-core-0'), q('lens-core-1')],
  lensStreak: q('lens-streak'),
  lensGhosts: LENS_GHOSTS.map((_, i) => q(`lens-ghost-${i}`)),
  lensRays: q('lens-rays'),
});

const op = (el, o) => { if (el) el.style.opacity = o < 0.003 ? '0' : Math.min(1, o).toFixed(3); };
const place = (el, tx, rot, scale) => { if (el) el.style.transform = `translate(-50%, -50%) ${tx} rotate(${rot.toFixed(2)}deg) scale(${scale.toFixed(4)})`; };
const off = (dx, dy) => `translate(calc(${dx} * var(--u)), calc(${dy} * var(--u)))`;

// One frame of the lens: style writes only.
export function paintLens(refs, p, mobile) {
  const { lens } = refs;
  if (!lens) return;
  const d = lensDrivers(p, mobile);
  lens.style.visibility = d.on ? 'visible' : 'hidden';
  lens.dataset.on = d.on ? 'true' : 'false';
  if (!d.on) return;
  op(refs.lensFlat, d.flat);
  d.lobes.forEach((s, i) => {
    const l = LENS_LOBES[i];
    place(refs.lensLobes[i], off(l.dx, l.dy), l.rot + s.rot, s.g);
    op(refs.lensLobes[i], s.o);
  });
  [0, 1].forEach((i) => {
    const l = LENS_LOBES[i];
    place(refs.lensCore[i], off(l.dx * 0.45, l.dy * 0.45), l.rot + (d.lobes[i] ? d.lobes[i].rot : 0), d.core.g * 0.45);
    op(refs.lensCore[i], d.core.o);
  });
  if (refs.lensStreak) {
    refs.lensStreak.style.transform = `translate(-50%, -50%) rotate(-3deg) scaleX(${d.flare.sx.toFixed(4)})`;
    op(refs.lensStreak, d.flare.o * (mobile ? 0.85 : 1));
  }
  d.ghosts.forEach((s, i) => {
    const g = LENS_GHOSTS[i];
    place(refs.lensGhosts[i], off(g.dx * s.g, g.dy * s.g), GHOST_ROT, Math.max(s.g, 0.001));
    op(refs.lensGhosts[i], s.o * g.o);
  });
  if (refs.lensRays) {
    place(refs.lensRays, '', d.rays.rot, lerpScale(p));
    op(refs.lensRays, d.rays.o);
  }
}
const lerpScale = (p) => 0.35 + 0.65 * Math.min(1, Math.max(0, (p - 0.86) / 0.11));
