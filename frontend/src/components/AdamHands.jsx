// Task 20261015-adam-hands-scroll-hero: pinned, scroll-scrubbed "Creation of
// Adam" hero. Two marble hand layers approach on an ink stage, touch, and a
// live-drawn light floods the stage white; a lens-gleam bloom of irregular warm lobes grows
// from the screen centre, holds, and falls back to its centre, revealing a grainy warm brown/honey liquid gradient (task 20261022-hands-scroll-grain-gradient) and
// community verses descend through it in glass widgets (VerseDescent).
//
// Rendering model
//  - Fallback (SSR / prerender / no-JS / prefers-reduced-motion): the touch-frame
//    still at 100svh with the live eyebrow, then a static 24svh gradient strip.
//    No pin, no scrub, no animation. This is also the first client render, so
//    the markup the prerender emits and the first client render agree.
//  - Live (client, motion allowed): a 980vh (900vh mobile) runway with a sticky
//    100svh stage; p runs 0 .. P_END (4.0 / 5.0). Scroll progress p is smoothed (~0.6 s) and painted by writing
//    styles straight onto the layer elements (no React re-render per frame).
//    All maths lives in src/lib/adamHands/driver.js.
//  - All light, the key filter, lens bloom, cap and type are live; only the cut-out
//    hand layers, edge-light, bounce, fan and spark sprites are image files
//    (public/adam/).
import React, { useEffect, useRef, useState } from 'react';
import {
  CANVAS, RUNWAY_VH, RUNWAY_VH_STACK, BASE_SPAN_VH, P_END, P_END_STACK, floodDrivers, lightParams, fanWeights, FAN_REF,
  handsPose, handsOpacity, bloomIntensity, ignite, beatGlow, warmGlowAlpha, eyebrowColor, fill2Drivers, familyOpacity,
  scrubProgress, smoothStep, coverScale, smooth, lerp, clamp,
} from '../lib/adamHands/driver.js';
import {
  FIELD_CAP, FIELD_INK, FIELD_UNDER, FIELD_GRAIN_URL, FIELD_BLOBS, FALLBACK_GRADIENT, adamPhase,
} from '../lib/adamHands/field.js';
import LiquidField, { LIQUID_CSS } from './LiquidField.jsx';
import { LensBloom, LENS_CSS, collectLens, paintLens } from './LensBloom.jsx';
import { VerseDescent, VerseStack, VERSE_CSS, paintVerses, createVerseRig } from './VerseDescent.jsx';
import { VERSE_STACK_QUERY } from '../lib/verseDescent.js';

// Palette, blob table and the text-contrast luminance rule live in lib/adamHands/field.js
// (re-exported here: Home.jsx and the tests import them from this module).
export {
  FIELD_BASE, FIELD_END, FIELD_CAP, FIELD_INK, FIELD_UNDER, FIELD_GRAIN_URL, FIELD_BLOBS, FALLBACK_GRADIENT, adamPhase,
  FIELD_WHITE, FIELD_ZONE_MAX, ADAM_ZONE, ADAM_ZONE_L_MAX, ADAM_STAGES, ADAM_LOBE_K, relLuminance, blobAlpha, blobLift, blobExtent,
  blobInZone, zoneLift, swirlLift, FIELD_GRAIN_OPACITY, SWIRL_LIGHT_LOBES,
} from '../lib/adamHands/field.js';

const INK = '#17120F';

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
.adam-pin[data-live="true"][data-stack="true"] { height: ${RUNWAY_VH_STACK.desktop}vh; }
.adam-stage { position: relative; height: 100vh; height: 100svh; overflow: hidden; background: ${INK}; container-type: size; }
.adam-pin[data-live="true"] .adam-stage { position: sticky; top: 0; }
${LIQUID_CSS}
${LENS_CSS}
${VERSE_CSS}
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
.adam-stage[data-flat="true"] .adam-canvas { display: none; }
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
  .adam-pin[data-live="true"][data-stack="true"] { height: ${RUNWAY_VH_STACK.mobile}vh; }
  .adam-fb-img { object-position: 50% 46%; }
  .adam-eyebrow { left: 9.33cqw; top: calc(5.6cqh + env(safe-area-inset-top, 0px)); font-size: max(2.89cqw, 12px); }
  .adam-pin[data-live="true"] .adam-eyebrow { left: 9.33cqw; top: calc(5.6cqh + env(safe-area-inset-top, 0px)); transform: translateY(-50%); }
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
function paintFrame(refs, p, mobile, stack) {
  const cv = mobile ? CANVAS.mobile : CANVAS.desktop;
  const { stage, canvas } = refs;
  const pose = handsPose(p, mobile);
  const d = floodDrivers(p);
  const L = lightParams(d.f, d.g);
  const ig = ignite(p);
  const f2 = fill2Drivers(p);
  const flat = f2.handsHidden; // hands, bloom and fans sit under the opaque field: stop compositing them
  stage.dataset.p = p.toFixed(3);
  stage.dataset.flat = flat ? 'true' : 'false';

  // Hands: translate then scale about the touch point.
  const place = (el, h) => {
    if (el) el.style.transform = `translate(${h.tx.toFixed(2)}px, ${h.ty.toFixed(2)}px) scale(${pose.scale.toFixed(5)})`;
  };
  place(refs.adamGroup, pose.adam);
  place(refs.godGroup, pose.god);
  const ho = handsOpacity(p).toFixed(3);
  if (refs.adamGroup) refs.adamGroup.style.opacity = ho;
  if (refs.godGroup) refs.godGroup.style.opacity = ho;

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
  // Past f .35 the lens lobes own the wide light; fade the canvas radial so it never reads as a clean circle.
  const igBloom = ig * (1 - 0.7 * smooth((d.f - 0.35) / 0.40));
  const bloomKey = `${L.r0.toFixed(1)}|${L.k.toFixed(3)}|${igBloom.toFixed(3)}|${ig.toFixed(3)}`;
  if (refs.lastBloom !== bloomKey) {
    refs.lastBloom = bloomKey;
    refs.bloom.style.background = bloomGradient(L, igBloom, cv.tx, cv.ty);
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

  // Lens bloom (style writes only), then the field underneath.
  paintLens(refs, p, mobile);
  setOpacity(refs.field, f2.fieldOn ? 1 : 0);
  if (refs.field) {
    const on = f2.fieldOn ? 'true' : 'false';
    if (refs.field.dataset.live !== on) refs.field.dataset.live = on;
  }
  if (refs.hilite) refs.hilite.style.opacity = f2.settle.toFixed(3);
  if (refs.verses.length) paintVerses(refs.verses, p, mobile, refs.w, refs.h, refs.rig);

  // Type.
  const ec = eyebrowColor(d.c);
  refs.eyebrow.style.color = `rgb(${ec[0]},${ec[1]},${ec[2]})`;
  setOpacity(refs.eyebrow, d.e);
  const tr = familyOpacity(p, stack);
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
    field: q('field'), hilite: q('hilite'), ...collectLens(q),
    verses: qa('verse'), eyebrow: q('eyebrow'), final: q('final'),
    w: 1, h: 1,
    lastKey: null, lastBloom: null,
  };
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

function LiveStage({ mobile, stack }) {
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
      <LiquidField live mobile={mobile} />
      <LensBloom mobile={mobile} />

      <p className="adam-eyebrow" data-adam="eyebrow" aria-hidden="true">{ADAM_EYEBROW}</p>
      <div className="adam-final" data-adam="final">
        <span className="adam-final-h">{ADAM_FINAL_HEADLINE}</span>
        <span className="adam-final-b">{ADAM_FINAL_SUBTITLE}</span>
      </div>
      {!stack && <VerseDescent />}
    </>
  );
}

export default function AdamHands() {
  // First render is always the fallback (SSR-equal); the effect below upgrades
  // to the live stack on the client when motion is allowed.
  const [mode, setMode] = useState({ live: false, mobile: false, stack: false });
  const sectionRef = useRef(null);
  const stageRef = useRef(null);

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return undefined;
    const rm = window.matchMedia('(prefers-reduced-motion: reduce)');
    const mo = window.matchMedia(ADAM_MOBILE_QUERY);
    const sq = window.matchMedia(VERSE_STACK_QUERY);
    const update = () => setMode((m) => {
      const next = { live: !rm.matches && typeof window.requestAnimationFrame === 'function', mobile: !!mo.matches, stack: !!sq.matches };
      return m.live === next.live && m.mobile === next.mobile && m.stack === next.stack ? m : next;
    });
    update();
    const bind = (mq) => { if (mq.addEventListener) mq.addEventListener('change', update); else if (mq.addListener) mq.addListener(update); };
    const unbind = (mq) => { if (mq.removeEventListener) mq.removeEventListener('change', update); else if (mq.removeListener) mq.removeListener(update); };
    bind(rm); bind(mo); bind(sq);
    return () => { unbind(rm); unbind(mo); unbind(sq); };
  }, []);

  useEffect(() => {
    if (!mode.live) return undefined;
    const section = sectionRef.current;
    const stage = stageRef.current;
    if (!section || !stage) return undefined;
    const refs = collect(stage);
    if (!refs.canvas) return undefined;
    refs.rig = createVerseRig(mode.mobile);

    const fit = () => {
      const s = coverScale(stage.clientWidth || 1, stage.clientHeight || 1, mode.mobile);
      refs.canvas.style.transform = `translate(-50%, -50%) scale(${s.toFixed(5)})`;
      refs.w = stage.clientWidth || 1; refs.h = stage.clientHeight || 1;
    };
    const baseSpan = mode.mobile ? BASE_SPAN_VH.mobile : BASE_SPAN_VH.desktop;
    const pEnd = mode.stack ? P_END_STACK : (mode.mobile ? P_END.mobile : P_END.desktop);
    const readTarget = () => {
      const rect = section.getBoundingClientRect();
      return scrubProgress(rect.top, rect.height, stage.clientHeight || window.innerHeight, baseSpan, pEnd);
    };

    // Per-visit variety: random drift start phase per blob. Client only, after mount (never in render).
    // DOM order is the non-highlight blobs, then the highlights (see LiquidField).
    const blobEls = stage.querySelectorAll('.adam-field .adam-blob');
    const domOrder = [...FIELD_BLOBS.filter((b) => !b.s), ...FIELD_BLOBS.filter((b) => b.s)];
    blobEls.forEach((el, i) => { if (domOrder[i]) el.style.setProperty('--ph', adamPhase(domOrder[i].t, Math.random())); });

    // Pause the drift when the stage is off screen (CSS keys animation-play-state on data-onscreen).
    const fieldEl = refs.field;
    if (fieldEl) fieldEl.dataset.onscreen = 'true';
    let io = null;
    if (fieldEl && typeof IntersectionObserver !== 'undefined') {
      io = new IntersectionObserver((entries) => {
        const e = entries[entries.length - 1];
        if (e) {
          fieldEl.dataset.onscreen = e.isIntersecting ? 'true' : 'false';
          visible = e.isIntersecting;
          if (!visible) { refs.rig.pointer(null, null); } else pkick();
        }
      });
      io.observe(stage);
    }

    let target = readTarget();
    let cur = target;
    let raf = 0;
    let last = 0;
    fit();
    paintFrame(refs, cur, mode.mobile, mode.stack);

    const tick = (now) => {
      raf = 0;
      const dt = last ? Math.min(0.1, (now - last) / 1000) : 1 / 60;
      last = now;
      cur = smoothStep(cur, target, dt);
      paintFrame(refs, cur, mode.mobile, mode.stack);
      if (cur !== target) raf = window.requestAnimationFrame(tick);
      else last = 0;
    };
    const kick = () => { if (!raf) raf = window.requestAnimationFrame(tick); };
    const onScroll = () => { target = readTarget(); kick(); };

    // Cursor spring parallax (fine pointer, pinned verses only). Own rAF loop that sleeps once
    // every card has settled; the scroll tick above also paints with the same spring offsets.
    let praf = 0;
    let plast = 0;
    let visible = true;
    const ptick = (now) => {
      praf = 0;
      const dt = plast ? Math.min(0.1, (now - plast) / 1000) : 1 / 60;
      plast = now;
      const active = refs.rig.step(dt);
      if (refs.verses.length) paintVerses(refs.verses, cur, mode.mobile, refs.w, refs.h, refs.rig);
      if (active && visible && document.visibilityState !== 'hidden') praf = window.requestAnimationFrame(ptick);
      else plast = 0;
    };
    const pkick = () => { if (!praf) praf = window.requestAnimationFrame(ptick); };
    const fine = !mode.mobile && !mode.stack && window.matchMedia && window.matchMedia('(pointer: fine)').matches;
    const onPointerMove = (e) => {
      const r = stage.getBoundingClientRect();
      if (!r.width || !r.height) return;
      const nx = clamp(((e.clientX - r.left) / r.width) * 2 - 1, -1, 1);
      const ny = clamp(((e.clientY - r.top) / r.height) * 2 - 1, -1, 1);
      refs.rig.pointer(nx, ny);
      pkick();
    };
    const onPointerOut = (e) => { if (!e.relatedTarget) { refs.rig.pointer(null, null); pkick(); } };
    const onBlur = () => { refs.rig.pointer(null, null); pkick(); };
    if (fine) {
      window.addEventListener('pointermove', onPointerMove, { passive: true });
      document.addEventListener('pointerout', onPointerOut);
      window.addEventListener('blur', onBlur);
    }
    // Debug / test hooks (dev server, or any build opened with ?heroDebug=1):
    //  window.__verseParallax(nx, ny)  drives the spring without a real pointer (null releases).
    //  window.__adamScrollToP(p)       scrolls the page so the hero scrub target is p (0 .. P_END).
    const debug = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.DEV) || /[?&]heroDebug=1/.test(window.location.search || '');
    if (debug) {
      if (fine) window.__verseParallax = (nx, ny) => { refs.rig.pointer(nx, ny); pkick(); };
      window.__adamScrollToP = (pp) => {
        let sc = section.parentElement;
        while (sc && !(sc.scrollHeight > sc.clientHeight + 1 && /(auto|scroll)/.test(getComputedStyle(sc).overflowY))) sc = sc.parentElement;
        sc = sc || document.scrollingElement || document.documentElement;
        const span = (baseSpan / 100) * (stage.clientHeight || window.innerHeight);
        sc.scrollTop += section.getBoundingClientRect().top + pp * span;
        onScroll();
      };
    }
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
      if (io) io.disconnect();
      window.removeEventListener('pointermove', onPointerMove);
      document.removeEventListener('pointerout', onPointerOut);
      window.removeEventListener('blur', onBlur);
      delete window.__verseParallax; delete window.__adamScrollToP;
      if (praf) window.cancelAnimationFrame(praf);
      if (raf) window.cancelAnimationFrame(raf);
    };
  }, [mode.live, mode.mobile, mode.stack]);

  return (
    <>
      <section ref={sectionRef} className="adam-pin" data-live={mode.live ? 'true' : 'false'} data-stack={mode.live && mode.stack ? 'true' : undefined} data-testid="adam-hands">
        <style>{ADAM_CSS}</style>
        <div ref={stageRef} className="adam-stage" data-flat="false">
          {mode.live ? <LiveStage key={`${mode.mobile ? 'm' : 'd'}${mode.stack ? 's' : ''}`} mobile={mode.mobile} stack={mode.stack} /> : <FallbackStage />}
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
        {!mode.live && <VerseStack />}
      </section>
      {mode.live && mode.stack && <VerseStack />}
    </>
  );
}
