// Community verses (World English Bible) as translucent blurred glass widgets.
// Two presentations of the same list:
//  - VerseDescent: pinned mode. Rendered inside the hero stage and painted from the
//    hero's scrub p by direct style writes (paintVerses), never React state per frame.
//    The visual layer is aria-hidden and a visually-hidden list carries the text once.
//  - VerseStack: reduced motion, no-JS/SSR, and short landscape viewports. Normal
//    flow, no pin, no motion, readable.
// Maths: lib/verseDescent.js. Text: lib/communityVerses.js (verified against bible.json).
import React from 'react';
import { COMMUNITY_VERSES } from '../lib/communityVerses.js';
import {
  verseState, springStep, springOmega, parallaxTarget, PARALLAX, VERSE_LABEL, VERSE_FILL, VERSE_INK, VERSE_REF_INK,
} from '../lib/verseDescent.js';
import { FIELD_END } from '../lib/adamHands/field.js';

const { rgb: F, a: FA, fallbackA: FFA } = VERSE_FILL;
const fill = (a) => `rgba(${F[0]},${F[1]},${F[2]},${a})`;
const HEAD_FONT = "'Schibsted Grotesk', sans-serif";
const BODY_FONT = "'Hanken Grotesk', system-ui, sans-serif";

export const VERSE_CSS = `
.verse { box-sizing: border-box; margin: 0; padding: 22px 26px 20px; border-radius: 22px; background: rgba(${F[0]},${F[1]},${F[2]},var(--va, ${FA})); border: 1px solid rgba(255,236,205,0.22); box-shadow: 0 18px 48px rgba(20,10,2,0.38), inset 0 1px 0 rgba(255,244,220,0.16); -webkit-backdrop-filter: blur(22px) saturate(1.15); backdrop-filter: blur(22px) saturate(1.15); color: ${VERSE_INK}; text-align: left; }
@supports not ((backdrop-filter: blur(1px)) or (-webkit-backdrop-filter: blur(1px))) { .verse { background: ${fill(FFA)}; } }
.verse-text { margin: 0; font: 400 clamp(16px, 0.9rem + 0.4vw, 20px)/1.5 ${BODY_FONT}; text-wrap: pretty; }
.verse-ref { margin: 14px 0 0; font: 600 13px/1.4 ${HEAD_FONT}; letter-spacing: 0.16em; text-transform: uppercase; color: ${VERSE_REF_INK}; }
.verse-descent { position: absolute; inset: 0; pointer-events: none; overflow: hidden; }
.verse-descent .verse { position: absolute; left: 0; top: 0; visibility: hidden; opacity: 0; will-change: transform, opacity; width: min(778px, 61cqw); transform-origin: 50% 50%; }
.verse-descent .verse[data-bf="off"] { -webkit-backdrop-filter: none; backdrop-filter: none; }
.verse-sr { position: absolute; width: 1px; height: 1px; margin: -1px; padding: 0; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0; }
.verse-stack { display: grid; gap: 20px; box-sizing: border-box; max-width: none; padding: clamp(48px, 9vh, 96px) clamp(20px, 5vw, 64px); background: ${FIELD_END}; }
.verse-stack-list { display: grid; gap: 20px; width: 100%; max-width: 640px; margin-inline: auto; padding: 0; list-style: none; }
@media (max-width: 899px), (pointer: coarse) {
  .verse { padding: 18px 20px 16px; border-radius: 18px; -webkit-backdrop-filter: blur(14px) saturate(1.15); backdrop-filter: blur(14px) saturate(1.15); }
  .verse-text { font-size: 16px; }
  .verse-descent .verse { width: min(360px, calc(100cqw - 32px)); -webkit-backdrop-filter: none; backdrop-filter: none; }
}
@supports not (width: 1cqw) { .verse-descent .verse { width: min(778px, 61vw); } }
`;

function Verse({ v, dataAdam }) {
  return (
    <figure className="verse" data-adam={dataAdam}>
      <blockquote className="verse-text">{v.text}</blockquote>
      <figcaption className="verse-ref">{v.ref}</figcaption>
    </figure>
  );
}

// Pinned layer (client only, mounted inside the live stage).
export function VerseDescent() {
  return (
    <>
      <div className="verse-descent" data-adam="verses" aria-hidden="true">
        {COMMUNITY_VERSES.map((v) => <Verse key={v.ref} v={v} dataAdam="verse" />)}
      </div>
      <ul className="verse-sr" aria-label={VERSE_LABEL}>
        {COMMUNITY_VERSES.map((v) => <li key={v.ref}>{v.text} {v.ref}</li>)}
      </ul>
    </>
  );
}

// Normal-flow list: reduced motion, no-JS/SSR and landscape-phone fallback.
export function VerseStack() {
  return (
    <section className="verse-stack" aria-label={VERSE_LABEL} data-testid="verse-stack">
      <ul className="verse-stack-list">
        {COMMUNITY_VERSES.map((v) => <li key={v.ref}><Verse v={v} /></li>)}
      </ul>
    </section>
  );
}

// Cursor-parallax rig: JS-held spring state per card (no React state). Created once per
// live effect. pointer(nx, ny) sets the target (null releases to neutral); step(dt) integrates
// and returns true while any card is still moving (false = asleep, stop the loop).
export function createVerseRig(mobile = false) {
  const rig = {
    mobile, nx: 0, ny: 0, released: true,
    x: [], y: [], vx: [], vy: [], z: [], last: [],
    pointer(nx, ny) {
      rig.released = nx === null;
      rig.nx = nx === null ? 0 : nx; rig.ny = ny === null ? 0 : ny;
    },
    step(dt) {
      let active = false;
      const rate = rig.released ? PARALLAX.returnScale : 1;
      for (let i = 0; i < rig.z.length; i++) {
        const z = rig.z[i] || 1;
        const [tx, ty] = parallaxTarget(rig.nx, rig.ny, z);
        const w = springOmega(z, rig.mobile) * rate;
        const sx = springStep(rig.x[i] || 0, rig.vx[i] || 0, tx, w, dt);
        const sy = springStep(rig.y[i] || 0, rig.vy[i] || 0, ty, w, dt);
        rig.x[i] = sx[0]; rig.vx[i] = sx[1]; rig.y[i] = sy[0]; rig.vy[i] = sy[1];
        if (Math.abs(sx[0] - tx) > 0.05 || Math.abs(sy[0] - ty) > 0.05 || Math.abs(sx[1]) > 0.05 || Math.abs(sy[1]) > 0.05) active = true;
        else { rig.x[i] = tx; rig.y[i] = ty; rig.vx[i] = 0; rig.vy[i] = 0; }
      }
      return active;
    },
  };
  return rig;
}

const setStyle = (rig, i, key, el, prop, val) => {
  const L = rig.last[i] || (rig.last[i] = {});
  if (L[key] === val) return;
  L[key] = val;
  el.style[prop] = val;
};

// Safe margin (px) between a card and the stage edge.
export const VERSE_EDGE_MARGIN = 20;
// Covered fraction at which a card starts / finishes dimming, and the opacity it keeps when
// covered (0: a covered card is gone, never ghosting through or over the card in front).
export const VERSE_OCC = { from: 0.004, to: 0.06, keep: 0 };
// A card already softening behind a nearer card dims over this wider covered range, so it
// fades out with the nearer card's arrival instead of snapping off (still 0 when mostly covered).
export const VERSE_OCC_SOFT = { from: 0.004, to: 0.22, keep: 0 };
const smoothstep = (t) => { const c = Math.min(1, Math.max(0, t)); return c * c * (3 - 2 * c); };

// Pure: keep a card of scaled size (w x h) centred at c inside [0, W] with margin m.
export const clampCentre = (c, size, W, m = VERSE_EDGE_MARGIN) => {
  const half = size / 2;
  if (W - 2 * m <= size) return W / 2;
  return Math.min(W - m - half, Math.max(m + half, c));
};

// Overlap of rect with each other rect, weighted by that rect's opacity (x0,y0,x1,y1,opacity).
function coverage(rect, others) {
  const area = (rect[2] - rect[0]) * (rect[3] - rect[1]);
  if (area <= 0) return 0;
  let covered = 0;
  for (const r of others) {
    const w = Math.min(rect[2], r[2]) - Math.max(rect[0], r[0]);
    const h = Math.min(rect[3], r[3]) - Math.max(rect[1], r[1]);
    if (w > 0 && h > 0) covered += ((w * h) / area) * r[4];
  }
  return Math.min(1, covered);
}

// Pure: opacity multiplier for a card given the rects (x0,y0,x1,y1,opacity) of nearer cards.
// Any real overlap with a visible nearer card dims it to VERSE_OCC.keep (0 = hidden).
export function occlusionFactor(rect, nearer) {
  if (!nearer.length) return 1;
  const occ = smoothstep((coverage(rect, nearer) - VERSE_OCC_SOFT.from) / (VERSE_OCC_SOFT.to - VERSE_OCC_SOFT.from));
  return 1 - (1 - VERSE_OCC_SOFT.keep) * occ;
}

// Pure: a nearer card that is still fading in must not ghost over a more solid farther card.
// While it overlaps a farther card it stays hidden until it is nearly opaque (then it takes
// over and the farther card, occluded by it, goes), or until it clears the farther card.
export function entryFactor(rect, own, farther) {
  if (!farther.length || own >= 1) return 1;
  const occ = smoothstep((coverage(rect, farther) - VERSE_OCC.from) / (VERSE_OCC.to - VERSE_OCC.from));
  return 1 - occ * (1 - smoothstep((own - 0.7) / 0.3));
}

// Direct style writes for one frame (transform, opacity, filter, visibility only).
// els = the .verse nodes in list order (later = nearer). rig is optional (spring offsets).
// Cards are kept inside the stage; a card covered by nearer ones fades out instead of
// ghosting through them or leaving slivers.
export function paintVerses(els, p, mobile, W, H, rig) {
  const n = els.length;
  const r = rig || createVerseRig(mobile);
  // Pass 1: state and rect of every card.
  const info = [];
  for (let i = 0; i < n; i++) {
    const el = els[i];
    const s = verseState(i, n, p, mobile);
    r.z[i] = s.z;
    if (!s.visible) {
      if (el.style.visibility !== 'hidden') { el.style.visibility = 'hidden'; el.style.opacity = '0'; if (r.last[i]) r.last[i].op = '0'; }
      continue;
    }
    if (el.style.visibility !== 'visible') el.style.visibility = 'visible';
    const w0 = el.offsetWidth || (mobile ? Math.min(360, W - 32) : Math.min(778, 0.61 * W));
    const h0 = el.offsetHeight || 0;
    const sw = w0 * s.scale;
    const sh = h0 * s.scale;
    const ax = r.x[i] || 0; const ay = r.y[i] || 0;
    const px = clampCentre((s.xPct / 100) * W, sw, W) + ax;
    const py = h0 ? clampCentre((s.yPct / 100) * H, sh, H) + ay : (s.yPct / 100) * H + ay;
    info[i] = { s, px, py, rect: h0 ? [px - sw / 2, py - sh / 2, px + sw / 2, py + sh / 2] : null };
  }
  // Pass 2: nearest first, so a nearer card's final opacity is known when dimming the cards behind it.
  const nearer = [];
  for (let i = n - 1; i >= 0; i--) {
    const f = info[i];
    if (!f) continue;
    const { s, px, py, rect } = f;
    const el = els[i];
    let op = s.opacity;
    if (rect) {
      const farther = [];
      for (let j = 0; j < i; j++) if (info[j] && info[j].rect) farther.push([...info[j].rect, info[j].s.opacity]);
      op *= entryFactor(rect, s.opacity, farther);
      op *= occlusionFactor(rect, nearer);
      nearer.push([...rect, op]);
    }
    setStyle(r, i, 'z', el, 'zIndex', String(i + 1)); // nearer (later) cards strictly above
    setStyle(r, i, 'op', el, 'opacity', op.toFixed(3));
    setStyle(r, i, 'tf', el, 'transform', `translate3d(${px.toFixed(1)}px, ${py.toFixed(1)}px, 0) translate(-50%, -50%) scale(${s.scale.toFixed(4)})`);
    setStyle(r, i, 'fl', el, 'filter', s.blur > 0 ? `blur(${s.blur}px)` : 'none');
    const bf = s.backdrop ? 'on' : 'off';
    if (el.dataset.bf !== bf) el.dataset.bf = bf;
    const va = s.alpha.toFixed(3);
    if (r.last[i].va2 !== va) { r.last[i].va2 = va; el.style.setProperty('--va', va); }
  }
}
