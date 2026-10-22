// The light transition layers for the hero (design-spec-r2.md R2-3): one tall, rotated,
// noise-masked band of warm light climbs the stage (soft leading edge = first fill, solid
// body = white hold, soft trailing edge = second fill), with anamorphic streaks and
// off-axis edge leaks. Everything is an ellipse or a linear gradient: no circles, no
// orbs. Markup is static; per frame only transform / opacity / visibility are written
// (paintLeaks), so nothing repaints a gradient. Maths: lib/adamHands/driver.js (leakDrivers).
import React from 'react';
import { leakDrivers, STREAKS, EDGES } from '../lib/adamHands/driver.js';
import { FIELD_WHITE } from '../lib/adamHands/field.js';

const LK_NOISE = `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='1024' height='1024'><filter id='n' x='0' y='0' width='100%' height='100%' color-interpolation-filters='sRGB'><feTurbulence type='fractalNoise' baseFrequency='.0035 .012' numOctaves='3' seed='7' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  1.9 0 0 0 -.35'/></filter><rect width='1024' height='1024' filter='url(%23n)'/></svg>")`;
export const LK_BAND_ROTATE = { desktop: -5, mobile: -4 };
const BAND_MASK = 'linear-gradient(180deg, transparent 0, #000 20%, #000 77.8%, transparent 100%)';
const ellipseAt = (at, stops) => `radial-gradient(ellipse 100% 100% at ${at}, ${stops})`;

export const LEAKS_CSS = `
.adam-leaks { position: absolute; inset: 0; overflow: hidden; isolation: isolate; pointer-events: none; visibility: hidden; }
.lk-band { position: absolute; left: -15%; width: 130%; top: 0; height: 225cqh; transform-origin: 50% 0; transform: translate3d(0, 112cqh, 0) rotate(${LK_BAND_ROTATE.desktop}deg);
  background: linear-gradient(180deg, rgba(224,154,48,0) 0%, rgba(224,154,48,.28) 2.4%, rgba(240,178,84,.62) 7.2%, rgba(255,226,170,.86) 12.4%, ${FIELD_WHITE} 20%, ${FIELD_WHITE} 77.8%, rgba(255,226,170,.90) 81.8%, rgba(235,196,128,.72) 87.8%, rgba(224,154,48,.28) 93.8%, rgba(180,113,44,0) 100%);
  -webkit-mask-image: ${BAND_MASK}, ${LK_NOISE}; mask-image: ${BAND_MASK}, ${LK_NOISE};
  -webkit-mask-size: 100% 100%, 1024px 1024px; mask-size: 100% 100%, 1024px 1024px;
  -webkit-mask-repeat: no-repeat, repeat; mask-repeat: no-repeat, repeat; }
.lk-s { position: absolute; left: -20%; width: 140%; pointer-events: none; mix-blend-mode: screen; transform-origin: 50% 50%; opacity: 0; visibility: hidden; }
.lk-band .lk-s { left: 0; width: 100%; opacity: 1; visibility: visible; }
.lk-s-white { background: radial-gradient(ellipse 50% 50% at 50% 50%, rgba(255,246,228,.95) 0, rgba(255,226,170,.55) 30%, rgba(224,154,48,.20) 62%, rgba(224,154,48,0) 100%); }
.lk-s-gold { background: radial-gradient(ellipse 50% 50% at 50% 50%, rgba(255,215,154,.90) 0, rgba(224,154,48,.55) 30%, rgba(180,113,44,.20) 62%, rgba(180,113,44,0) 100%); }
.lk-s-amber { background: radial-gradient(ellipse 50% 50% at 50% 50%, rgba(240,190,130,.90) 0, rgba(180,113,44,.55) 30%, rgba(180,113,44,.20) 62%, rgba(180,113,44,0) 100%); }
.lk-bs1 { top: 6.4%; height: .55%; } .lk-bs2 { top: 12.8%; height: .35%; } .lk-bs3 { top: 80.6%; height: .50%; } .lk-bs4 { top: 88.4%; height: .40%; }
${STREAKS.map((s, i) => `.lk-s${i} { top: ${s.y}%; height: ${s.h}cqh; }`).join(' ')}
.lk-edge { position: absolute; mix-blend-mode: screen; opacity: 0; visibility: hidden; transform-origin: 50% 50%;
  -webkit-mask-image: ${LK_NOISE}; mask-image: ${LK_NOISE}; -webkit-mask-size: 1024px 1024px; mask-size: 1024px 1024px; }
.lk-e1 { left: -18%; top: 56%; width: 95%; height: 30%; background: ${ellipseAt('0% 50%', 'rgba(255,215,154,.90) 0, rgba(224,154,48,.50) 34%, rgba(224,154,48,.16) 65%, rgba(224,154,48,0) 100%')}; }
.lk-e2 { left: 30%; top: 22%; width: 88%; height: 26%; background: ${ellipseAt('100% 50%', 'rgba(243,196,139,.85) 0, rgba(180,113,44,.50) 36%, rgba(180,113,44,.16) 68%, rgba(180,113,44,0) 100%')}; }
.lk-e3 { left: -6%; top: 70%; width: 110%; height: 40%; background: ${ellipseAt('50% 100%', 'rgba(255,241,214,.95) 0, rgba(235,196,128,.55) 38%, rgba(224,154,48,.16) 70%, rgba(224,154,48,0) 100%')}; }
.lk-e4 { left: 40%; top: -6%; width: 70%; height: 22%; background: ${ellipseAt('100% 0%', 'rgba(224,154,48,.80) 0, rgba(180,113,44,.40) 40%, rgba(180,113,44,0) 100%')}; }
@media (max-width: 899px), (pointer: coarse) {
  .lk-band { left: -40%; width: 180%; transform: translate3d(0, 112cqh, 0) rotate(${LK_BAND_ROTATE.mobile}deg); -webkit-mask-size: 100% 100%, 768px 768px; mask-size: 100% 100%, 768px 768px; }
  .lk-bs2, .lk-bs4, .lk-s1, .lk-s3, .lk-s4, .lk-e2, .lk-e4 { display: none; }
  .lk-s, .lk-edge { mix-blend-mode: normal; }
  .lk-s0 { height: ${STREAKS[0].mh}cqh; } .lk-s2 { height: ${STREAKS[2].mh}cqh; }
}
@media (prefers-reduced-motion: reduce) { .adam-leaks { display: none; } }
`;

export function LightLeaks() {
  return (
    <div className="adam-leaks" data-adam="leaks" aria-hidden="true">
      {EDGES.map((e) => <div key={e.id} className={`lk-edge lk-${e.id}`} data-adam={`lk-${e.id}`} />)}
      <div className="lk-band" data-adam="lk-band">
        <i className="lk-s lk-s-gold lk-bs1" />
        <i className="lk-s lk-s-white lk-bs2" />
        <i className="lk-s lk-s-white lk-bs3" />
        <i className="lk-s lk-s-gold lk-bs4" />
      </div>
      <div className="lk-streaks">
        {STREAKS.map((s, i) => <i key={i} className={`lk-s lk-s-${s.tone} lk-s${i}`} data-adam={`lk-s${i}`} />)}
      </div>
    </div>
  );
}

const EDGE_ROT = [-9, 11, 0, 28];
export const collectLeaks = (q) => ({
  leaks: q('leaks'),
  band: q('lk-band'),
  edges: EDGES.map((e) => q(`lk-${e.id}`)),
  streaks: STREAKS.map((_, i) => q(`lk-s${i}`)),
});

function put(el, on, o) {
  if (!el) return;
  if (on) { el.style.opacity = o.toFixed(3); el.style.visibility = 'visible'; } else if (el.style.visibility !== 'hidden') { el.style.opacity = '0'; el.style.visibility = 'hidden'; }
}

// One frame of the transition layers: style writes only.
export function paintLeaks(refs, p, mobile) {
  const { leaks, band } = refs;
  if (!leaks) return;
  const d = leakDrivers(p, mobile);
  const k = mobile ? 0.85 : 1;
  leaks.style.visibility = d.leavesOn ? 'visible' : 'hidden';
  if (!d.leavesOn) {
    if (band) { band.style.willChange = 'auto'; band.style.visibility = 'hidden'; }
    d.streaks.forEach((s, i) => put(refs.streaks[i], false, 0));
    d.edges.forEach((e, i) => put(refs.edges[i], false, 0));
    return;
  }
  if (band) {
    band.style.visibility = d.bandOn ? 'visible' : 'hidden';
    band.style.willChange = d.bandOn ? 'transform' : 'auto';
    band.style.transform = `translate3d(0, ${(d.bandY * 100).toFixed(3)}cqh, 0) rotate(${mobile ? LK_BAND_ROTATE.mobile : LK_BAND_ROTATE.desktop}deg)`;
  }
  d.streaks.forEach((s, i) => {
    const el = refs.streaks[i];
    if (el && s.on) el.style.transform = `translate3d(0, calc(-50% + ${s.ty.toFixed(3)}cqh), 0) scaleX(${s.sx.toFixed(4)})`;
    put(el, s.on && s.o > 0.002, s.o * k);
  });
  d.edges.forEach((e, i) => {
    const el = refs.edges[i];
    if (el && e.on) el.style.transform = `rotate(${EDGE_ROT[i]}deg) translateX(${e.tx.toFixed(3)}cqw)`;
    put(el, e.on, e.o * k);
  });
}
