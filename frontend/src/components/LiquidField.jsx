// The grainy navy liquid field behind the hero end state. One component for every
// surface: `live` = the stage layer (shown once the second fill starts, drift runs
// while on screen); otherwise the frozen frame of the same composition (fallback
// block, settle = 1, nothing animated). Pure data lives in lib/adamHands/field.js.
import React from 'react';
import {
  FIELD_BLOBS, FIELD_UNDER, FIELD_UNDER_MOBILE, FIELD_BOTTOM_FADE, FIELD_GRAIN_URL, blobBg,
} from '../lib/adamHands/field.js';

const SWIRL_A = 'conic-gradient(from 0deg at 50% 50%, rgba(42,90,126,0) 0deg, rgba(42,90,126,0.50) 70deg, rgba(7,23,51,0) 150deg, rgba(47,108,140,0.38) 235deg, rgba(3,12,40,0) 305deg, rgba(42,90,126,0) 360deg)';
const SWIRL_B = 'conic-gradient(from 40deg at 50% 50%, rgba(47,108,140,0) 0deg, rgba(47,108,140,0.30) 80deg, rgba(7,23,51,0) 160deg, rgba(7,23,51,0.45) 250deg, rgba(47,108,140,0) 360deg)';

export const LIQUID_CSS = `
.adam-stage[data-flat="true"] { background: ${FIELD_UNDER}; }
.adam-liquid { position: absolute; inset: 0; overflow: hidden; isolation: isolate; container-type: size; pointer-events: none; background: ${FIELD_UNDER}; }
.adam-field { opacity: 0; visibility: hidden; }
.adam-liquid-blobs { position: absolute; inset: 0; -webkit-mask-image: linear-gradient(180deg, #000 0, #000 60%, transparent 84%); mask-image: linear-gradient(180deg, #000 0, #000 60%, transparent 84%); }
.adam-liquid-teal { position: absolute; inset: 0; }
.adam-blob { --k: 1; position: absolute; left: calc(var(--x) * 1%); top: calc(var(--y) * 1%); width: calc(var(--w) * var(--k) * 1%); height: calc(var(--h) * var(--k) * 1%); border-radius: 50%; transform: translate(-50%, -50%) rotate(calc(var(--r) * 1deg)); animation: adam-drift calc(var(--t) * 1s) ease-in-out infinite alternate; animation-play-state: paused; animation-delay: calc(var(--ph, 0) * -1s); }
.adam-swirl { position: absolute; inset: -30%; border-radius: 50%; animation: adam-spin 90s linear infinite; animation-play-state: paused; }
.adam-swirl-a { background: ${SWIRL_A}; filter: blur(48px); }
.adam-swirl-b { background: ${SWIRL_B}; filter: blur(64px); animation-duration: 140s; animation-direction: reverse; }
.adam-field[data-live="true"][data-onscreen="true"] .adam-blob, .adam-field[data-live="true"][data-onscreen="true"] .adam-swirl { animation-play-state: running; will-change: transform; }
.adam-liquid-frozen .adam-blob { animation: none; }
/* Fallback block only: also fade blobs out at the top edge so it joins the ink strip flat. */
.adam-liquid-frozen .adam-liquid-blobs { -webkit-mask-image: linear-gradient(180deg, transparent 0, #000 16%, #000 60%, transparent 84%); mask-image: linear-gradient(180deg, transparent 0, #000 16%, #000 60%, transparent 84%); }
@keyframes adam-drift { to { transform: translate(calc(-50% + var(--dx) * 1cqw), calc(-50% + var(--dy) * 1cqh)) rotate(calc((var(--r) + var(--dr)) * 1deg)); } }
@keyframes adam-spin { to { transform: rotate(360deg); } }
.adam-liquid::before { content: ''; position: absolute; inset: 0; z-index: 1; background: ${FIELD_BOTTOM_FADE}; }
.adam-liquid::after { content: ''; position: absolute; inset: 0; z-index: 2; background-image: ${FIELD_GRAIN_URL}; background-size: 220px 220px; mix-blend-mode: soft-light; }
@media (prefers-reduced-motion: reduce) { .adam-blob, .adam-swirl { animation: none; } }
@media (max-width: 899px), (pointer: coarse) {
  .adam-liquid, .adam-stage[data-flat="true"] { background: ${FIELD_UNDER_MOBILE}; }
  .adam-liquid::after { opacity: 0.75; }
  .adam-blob-g { --k: 1.25; }
  .adam-blob-d, .adam-swirl { display: none; }
}
`;

function Blob({ b, i }) {
  return (
    <div
      key={i}
      className={`adam-blob${b.m ? '' : ' adam-blob-d'}${b.g > 1 ? ' adam-blob-g' : ''}`}
      style={{ '--x': b.x, '--y': b.y, '--w': b.w, '--h': b.h, '--r': b.r, '--t': b.t, '--dx': b.dx, '--dy': b.dy, '--dr': b.dr, background: blobBg(b) }}
    />
  );
}

export default function LiquidField({ live, mobile = false }) {
  return (
    <div
      className={live ? 'adam-liquid adam-field' : 'adam-liquid adam-liquid-frozen'}
      data-adam={live ? 'field' : undefined}
      data-live="false"
      aria-hidden="true"
    >
      <div className="adam-liquid-blobs">
        {FIELD_BLOBS.map((b, i) => (b.s ? null : <Blob key={i} b={b} i={i} />))}
        <div className="adam-liquid-teal" data-adam={live ? 'teal' : undefined} style={{ opacity: live ? 0 : 1 }}>
          {FIELD_BLOBS.map((b, i) => (b.s ? <Blob key={i} b={b} i={i} /> : null))}
        </div>
      </div>
      {live && !mobile && <div className="adam-swirl adam-swirl-a" />}
      {live && !mobile && <div className="adam-swirl adam-swirl-b" />}
    </div>
  );
}
