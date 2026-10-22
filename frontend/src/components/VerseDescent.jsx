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
import { verseState, VERSE_LABEL, VERSE_FILL, VERSE_INK, VERSE_REF_INK } from '../lib/verseDescent.js';
import { FIELD_END } from '../lib/adamHands/field.js';

const { rgb: F, a: FA, fallbackA: FFA } = VERSE_FILL;
const fill = (a) => `rgba(${F[0]},${F[1]},${F[2]},${a})`;
const HEAD_FONT = "'Schibsted Grotesk', sans-serif";
const BODY_FONT = "'Hanken Grotesk', system-ui, sans-serif";

export const VERSE_CSS = `
.verse { box-sizing: border-box; margin: 0; padding: 22px 26px 20px; border-radius: 22px; background: ${fill(FA)}; border: 1px solid rgba(255,236,205,0.22); box-shadow: 0 18px 48px rgba(20,10,2,0.38), inset 0 1px 0 rgba(255,244,220,0.16); -webkit-backdrop-filter: blur(22px) saturate(1.15); backdrop-filter: blur(22px) saturate(1.15); color: ${VERSE_INK}; text-align: left; }
@supports not ((backdrop-filter: blur(1px)) or (-webkit-backdrop-filter: blur(1px))) { .verse { background: ${fill(FFA)}; } }
.verse-text { margin: 0; font: 400 clamp(16px, 0.9rem + 0.4vw, 20px)/1.5 ${BODY_FONT}; text-wrap: pretty; }
.verse-ref { margin: 14px 0 0; font: 600 13px/1.4 ${HEAD_FONT}; letter-spacing: 0.16em; text-transform: uppercase; color: ${VERSE_REF_INK}; }
.verse-descent { position: absolute; inset: 0; pointer-events: none; overflow: hidden; }
.verse-descent .verse { position: absolute; left: 0; top: 0; width: min(560px, 44cqw); visibility: hidden; opacity: 0; will-change: transform, opacity; }
.verse-sr { position: absolute; width: 1px; height: 1px; margin: -1px; padding: 0; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0; }
.verse-stack { display: grid; gap: 20px; box-sizing: border-box; max-width: none; padding: clamp(48px, 9vh, 96px) clamp(20px, 5vw, 64px); background: ${FIELD_END}; }
.verse-stack-list { display: grid; gap: 20px; width: 100%; max-width: 640px; margin-inline: auto; padding: 0; list-style: none; }
@media (max-width: 899px), (pointer: coarse) {
  .verse { padding: 18px 20px 16px; border-radius: 18px; -webkit-backdrop-filter: blur(14px) saturate(1.15); backdrop-filter: blur(14px) saturate(1.15); }
  .verse-text { font-size: 16px; }
  .verse-descent .verse { width: min(360px, calc(100cqw - 32px)); }
}
@supports not (width: 1cqw) { .verse-descent .verse { width: min(560px, 44vw); } }
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

// Direct style writes for one frame. els = the .verse nodes in list order.
export function paintVerses(els, p, mobile, W, H) {
  const n = els.length;
  for (let i = 0; i < n; i++) {
    const el = els[i];
    const s = verseState(i, n, p, mobile);
    if (!s.visible) {
      if (el.style.visibility !== 'hidden') { el.style.visibility = 'hidden'; el.style.opacity = '0'; }
      continue;
    }
    el.style.visibility = 'visible';
    el.style.opacity = s.opacity.toFixed(3);
    el.style.transform = `translate3d(${((s.xPct / 100) * W).toFixed(1)}px, ${((s.yVh / 100) * H).toFixed(1)}px, 0) translate(-50%, -50%)`;
  }
}
