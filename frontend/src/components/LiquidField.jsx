// The grainy warm brown/honey liquid field (blue-era implementation, warm colours) behind the hero end state. One component for every
// surface: `live` = the stage layer (shown once the second fill starts, drift runs
// while on screen); otherwise the frozen frame of the same composition (fallback
// block, settle = 1, nothing animated). Pure data lives in lib/adamHands/field.js.
import React, { useEffect, useRef } from 'react';
import {
  FIELD_BLOBS, FIELD_UNDER, FIELD_UNDER_MOBILE, FIELD_BOTTOM_FADE, FIELD_GRAIN_URL, SWIRL_A, SWIRL_B, blobBg,
} from '../lib/adamHands/field.js';
import { createLiquidGl, flowDelta, LIQUID_RES, LIQUID_T0 } from '../lib/adamHands/liquidGl.js';


export const LIQUID_CSS = `
.adam-stage[data-flat="true"] { background: ${FIELD_UNDER}; }
.adam-liquid { position: absolute; inset: 0; overflow: hidden; isolation: isolate; container-type: size; pointer-events: none; background: ${FIELD_UNDER}; }
.adam-field { opacity: 0; visibility: hidden; }
.adam-liquid-blobs { position: absolute; inset: 0; -webkit-mask-image: linear-gradient(180deg, #000 0, #000 60%, transparent 84%); mask-image: linear-gradient(180deg, #000 0, #000 60%, transparent 84%); }
.adam-liquid-hilite { position: absolute; inset: 0; }
/* WebGL ribbon layer (live only). Sits on the underlay, under the washes, bottom fade and grain; the CSS blobs and swirls hand over to it once it is drawing (data-gl). */
.adam-gl { position: absolute; inset: 0; width: 100%; height: 100%; opacity: 0; transition: opacity 0.9s ease; -webkit-mask-image: linear-gradient(180deg, #000 0, #000 60%, transparent 84%); mask-image: linear-gradient(180deg, #000 0, #000 60%, transparent 84%); }
.adam-liquid[data-gl="true"] .adam-gl { opacity: 1; }
.adam-liquid[data-gl="true"] [class*="adam-blob"], .adam-liquid[data-gl="true"] [class*="adam-swirl"] { display: none; }
/* Static top-down warm wash (fades in with the settle). Centre band stays above y 30% and the corner columns keep out of x 18-82, so nothing reaches the text zone. */
.adam-hilite-wash { position: absolute; pointer-events: none; }
.adam-hilite-wash-c { left: 18%; width: 64%; top: 0; height: 30%; background: linear-gradient(180deg, rgba(224,166,72,.95) 0%, rgba(224,166,72,.85) 45%, rgba(224,166,72,.6) 80%, rgba(224,166,72,0) 100%); -webkit-mask-image: linear-gradient(90deg, transparent 0, #000 14%, #000 86%, transparent 100%); mask-image: linear-gradient(90deg, transparent 0, #000 14%, #000 86%, transparent 100%); }
.adam-hilite-wash-l { left: 0; width: 18%; top: 0; height: 62%; background: linear-gradient(180deg, rgba(184,117,48,.7) 0%, rgba(184,117,48,0) 100%); -webkit-mask-image: linear-gradient(90deg, #000 0, #000 70%, transparent 100%); mask-image: linear-gradient(90deg, #000 0, #000 70%, transparent 100%); }
.adam-hilite-wash-r { right: 0; width: 18%; top: 0; height: 62%; background: linear-gradient(180deg, rgba(154,92,32,.7) 0%, rgba(154,92,32,0) 100%); -webkit-mask-image: linear-gradient(270deg, #000 0, #000 70%, transparent 100%); mask-image: linear-gradient(270deg, #000 0, #000 70%, transparent 100%); }
.adam-blob { --k: 1; position: absolute; left: calc(var(--x) * 1%); top: calc(var(--y) * 1%); width: calc(var(--w) * var(--k) * 1%); height: calc(var(--h) * var(--k) * 1%); border-radius: 50%; transform: translate(-50%, -50%) rotate(calc(var(--r) * 1deg)); animation: adam-drift calc(var(--t) * 1s) ease-in-out infinite alternate; animation-play-state: paused; animation-delay: calc(var(--ph, 0) * -1s); }
.adam-swirl { position: absolute; inset: -30%; border-radius: 50%; -webkit-mask-image: radial-gradient(ellipse 70% 70% at 30% 22%, #000 0%, transparent 100%), radial-gradient(closest-side, #000 70%, transparent 100%); mask-image: radial-gradient(ellipse 70% 70% at 30% 22%, #000 0%, transparent 100%), radial-gradient(closest-side, #000 70%, transparent 100%); -webkit-mask-composite: source-in; mask-composite: intersect; animation: adam-spin 90s linear infinite; animation-play-state: paused; }
.adam-swirl-a { background: ${SWIRL_A}; filter: blur(48px); }
.adam-swirl-b { background: ${SWIRL_B}; filter: blur(64px); animation-duration: 140s; animation-direction: reverse; }
.adam-field[data-live="true"][data-onscreen="true"] .adam-blob, .adam-field[data-live="true"][data-onscreen="true"] .adam-swirl { animation-play-state: running; }
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

// Drives the WebGL ribbon layer: client only, live stage only. Draws only while the stage is on
// screen, the tab is visible and the field is shown (data-live); time accumulates from clamped dt
// so resuming never jumps. Flow quickens a little while the page scrolls.
function useLiquidGl(rootRef, canvasRef, live, mobile) {
  useEffect(() => {
    const root = rootRef.current; const canvas = canvasRef.current;
    if (!live || !root || !canvas || typeof window === 'undefined' || typeof window.requestAnimationFrame !== 'function') return undefined;
    const api = createLiquidGl(canvas, { mobile, onLost: () => { delete root.dataset.gl; } });
    if (!api) return undefined;
    const fpsGap = 1000 / (mobile ? LIQUID_RES.mobile.fps : LIQUID_RES.desktop.fps) - 2;
    let t = LIQUID_T0; let raf = 0; let last = 0; let lastDraw = 0; let onscreen = true; let speed = 0; let sy = null; let st = 0;
    const size = () => { const r = root.getBoundingClientRect(); api.resize(r.width || 2, r.height || 2, window.devicePixelRatio || 1); };
    const frame = (now) => {
      raf = 0;
      if (!onscreen || document.visibilityState === 'hidden') { last = 0; return; }
      raf = window.requestAnimationFrame(frame);
      const dt = last ? (now - last) / 1000 : 0; last = now;
      if (now - st > 140) speed = 0;
      if (root.dataset.live !== 'true') return;
      if (now - lastDraw < fpsGap) { t += flowDelta(dt, speed); return; }
      lastDraw = now;
      t += flowDelta(dt, speed);
      api.draw(t);
      if (root.dataset.gl !== 'true') root.dataset.gl = 'true';
    };
    const kick = () => { if (!raf && onscreen && document.visibilityState !== 'hidden') raf = window.requestAnimationFrame(frame); };
    const onScroll = (e) => {
      const el = e.target; const y = el && el.scrollTop !== undefined && el !== document ? el.scrollTop : window.scrollY;
      const now = performance.now();
      if (sy !== null && st && now > st) speed += ((Math.abs(y - sy) / (now - st)) * 1000 - speed) * 0.35;
      sy = y; st = now;
    };
    size();
    let ro = null; let io = null;
    if (typeof ResizeObserver !== 'undefined') { ro = new ResizeObserver(size); ro.observe(root); }
    if (typeof IntersectionObserver !== 'undefined') { io = new IntersectionObserver((es) => { const e = es[es.length - 1]; if (e) { onscreen = e.isIntersecting; if (onscreen) kick(); } }); io.observe(root); }
    document.addEventListener('visibilitychange', kick);
    document.addEventListener('scroll', onScroll, { passive: true, capture: true });
    // Debug / test hook (dev server or ?heroDebug=1): window.__liquid.freeze(t) draws one frame at flow time t and stops; resume() restarts.
    const debug = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.DEV) || /[?&]heroDebug=1/.test(window.location.search || '');
    if (debug) {
      window.__liquid = {
        freeze(tt) { onscreen = false; if (raf) { window.cancelAnimationFrame(raf); raf = 0; } api.draw(tt === undefined ? t : tt); root.dataset.gl = 'true'; },
        resume() { onscreen = true; last = 0; kick(); },
      };
    }
    kick();
    return () => {
      if (raf) window.cancelAnimationFrame(raf);
      if (ro) ro.disconnect();
      if (io) io.disconnect();
      document.removeEventListener('visibilitychange', kick);
      document.removeEventListener('scroll', onScroll, { capture: true });
      delete window.__liquid;
      delete root.dataset.gl;
      api.destroy();
    };
  }, [live, mobile, rootRef, canvasRef]);
}

export default function LiquidField({ live, mobile = false }) {
  const rootRef = useRef(null);
  const canvasRef = useRef(null);
  useLiquidGl(rootRef, canvasRef, !!live, mobile);
  return (
    <div
      ref={rootRef}
      className={live ? 'adam-liquid adam-field' : 'adam-liquid adam-liquid-frozen'}
      data-adam={live ? 'field' : undefined}
      data-live="false"
      aria-hidden="true"
    >
      {live && <canvas ref={canvasRef} className="adam-gl" data-adam="gl" aria-hidden="true" />}
      {live && !mobile && <div className="adam-swirl adam-swirl-a" />}
      {live && !mobile && <div className="adam-swirl adam-swirl-b" />}
      <div className="adam-liquid-blobs">
        {FIELD_BLOBS.map((b, i) => (b.s ? null : <Blob key={i} b={b} i={i} />))}
        <div className="adam-liquid-hilite" data-adam={live ? 'hilite' : undefined} style={{ opacity: live ? 0 : 1 }}>
          {FIELD_BLOBS.map((b, i) => (b.s ? <Blob key={i} b={b} i={i} /> : null))}
          <div className="adam-hilite-wash adam-hilite-wash-c" />
          <div className="adam-hilite-wash adam-hilite-wash-l" />
          <div className="adam-hilite-wash adam-hilite-wash-r" />
        </div>
      </div>
    </div>
  );
}
