import React, { useEffect, useLayoutEffect, useRef, useState } from 'react';

// Isomorphic: layout effect on the client (sets the hidden entrance state
// before first paint, so no visible-then-hidden flash), plain effect during
// the prerender (never runs there anyway; avoids the SSR warning).
const useIsoLayoutEffect = typeof window !== 'undefined' ? useLayoutEffect : useEffect;

// Entrance timing (ms). Slots land back-to-front, ENTER_STAGGER apart.
const ENTER_STAGGER = 150;
const ENTER_COUNT_MS = 700;
const ENTER_DONE_MS = ENTER_STAGGER * 2 + 700 + 150;

// Task 20261008-homepage-problem-carousel: fanned-deck carousel. Data-driven
// (slides are props, 1..N), SSR-safe (window/document only touched inside
// effects/handlers), no dependencies. Spec: ~/.claude/design/
// 20261008-fellowscript-home-problem-carousel/design-spec.md.
//
// Model: `active` is the index of the front slide. Slides stay in fixed DOM
// order (stable keys, so CSS transitions animate) and each gets
// data-slot = (index - active) mod n; slot 0 is the front card, 1 and 2 peek
// behind it, anything further is hidden. Server HTML therefore contains every
// slide's text for crawlers.

const INK = '#17120F';
const AMBER = '#E09A30';
const EASE = 'cubic-bezier(0.2,0.8,0.2,1)';
const HEAD = "'Schibsted Grotesk', sans-serif";

const RING_R = 104;
const RING_C = 2 * Math.PI * RING_R;

function pad2(n) {
  return String(n).padStart(2, '0');
}

// ── Stat visuals ─────────────────────────────────────────────────────────────

function Ring({ percent }) {
  const frac = Math.min(100, Math.max(0, percent)) / 100;
  const angle = frac * 2 * Math.PI - Math.PI / 2;
  const tx = 120 + (RING_R + 18) * Math.cos(angle);
  const ty = 120 + (RING_R + 18) * Math.sin(angle);
  return (
    <svg className="pc-visual" viewBox="-20 -20 280 280" role="img" aria-label={`${percent} percent`}>
      <circle className="pc-track" cx="120" cy="120" r={RING_R} fill="none" strokeWidth="1.5" />
      <circle
        className="pc-mark" cx="120" cy="120" r={RING_R} fill="none" strokeWidth="6" strokeLinecap="round"
        strokeDasharray={`${(frac * RING_C).toFixed(2)} ${RING_C.toFixed(2)}`}
        transform="rotate(-90 120 120)"
      />
      <text className="pc-tick pc-mark-fill" x={tx.toFixed(1)} y={ty.toFixed(1)} textAnchor="middle" dominantBaseline="middle" fontSize="12" fontFamily={HEAD} aria-hidden="true">{percent}%</text>
    </svg>
  );
}

function Waffle({ percent }) {
  const filled = Math.round((percent / 100) * 25);
  const cells = [];
  for (let k = 0; k < 25; k += 1) {
    const row = 4 - Math.floor(k / 5);
    const col = k % 5;
    cells.push(
      <rect
        key={k} x={col * 44} y={row * 44} width="36" height="36" rx="6"
        className={k < filled ? 'pc-cell-on' : 'pc-cell-off'}
        strokeWidth={k < filled ? 0 : 1.5}
      />,
    );
  }
  return (
    <div className="pc-visual-wrap">
      <svg className="pc-visual" viewBox="0 0 244 244" role="img" aria-label={`${percent} percent`}>{cells}</svg>
      <div className="pc-caption">{percent} of 100</div>
    </div>
  );
}

const NODES = [[60, 70], [190, 62], [205, 140], [160, 205], [84, 196], [38, 140], [128, 36]];
const LOOPS = [[0, 5], [1, 2], [3, 4]];

function Network() {
  return (
    <svg className="pc-visual" viewBox="0 0 240 240" aria-hidden="true">
      {NODES.map(([x, y], i) => <line key={`s${i}`} className="pc-link" x1="120" y1="120" x2={x} y2={y} strokeWidth="1" />)}
      {LOOPS.map(([a, b]) => <line key={`l${a}${b}`} className="pc-link" x1={NODES[a][0]} y1={NODES[a][1]} x2={NODES[b][0]} y2={NODES[b][1]} strokeWidth="1" />)}
      {NODES.map(([x, y], i) => <circle key={`n${i}`} className="pc-node" cx={x} cy={y} r={i % 3 === 0 ? 6 : 4.5} fill="none" strokeWidth="1" />)}
      <circle className="pc-centre" cx="120" cy="120" r="7" />
    </svg>
  );
}

function Visual({ slide }) {
  switch (slide.visual) {
    case 'ring': return <Ring percent={slide.percent} />;
    case 'waffle': return <Waffle percent={slide.percent} />;
    default: return <Network />;
  }
}

// ── Component ────────────────────────────────────────────────────────────────

/**
 * slides: [{ id, label, percent?, sentence, problem?, source?: {text, href},
 *            solution, visual: 'ring' | 'waffle' | 'network' }]
 */
export default function ProblemCarousel({ slides, ariaLabel = 'The problem' }) {
  const n = slides.length;
  const [active, setActive] = useState(0);
  const rootRef = useRef(null);
  const frontRefs = useRef([]);
  const focusFront = useRef(false);
  const touch = useRef(null);

  // Entrance (skipped under reduced motion): cards fly up from below in
  // back-to-front sequence, stats count up. SSR / no-JS renders the resting
  // fan with real numbers: "pre" is only ever set from this client-only layout
  // effect (before first paint). "in" runs the staggered transitions, "done"
  // (after they finish, or on the first interaction) removes the stagger
  // delays so click-rotate and hover keep their normal timing.
  const entering = useRef(false);
  const finishEntrance = () => {
    if (!entering.current) return;
    entering.current = false;
    const el = rootRef.current;
    if (el && el.getAttribute('data-pc-phase') === 'in') el.setAttribute('data-pc-phase', 'done');
  };
  useIsoLayoutEffect(() => {
    if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return undefined;
    const el = rootRef.current;
    if (!el || !('IntersectionObserver' in window)) return undefined;
    // Count-up targets: only the aria-hidden number text node; React's markup
    // and the aria-live region are never touched.
    const nums = Array.from(el.querySelectorAll('[data-pc-count]'));
    const setNum = (node, v) => { if (node.firstChild) node.firstChild.nodeValue = String(v); };
    nums.forEach((node) => setNum(node, 0));
    el.setAttribute('data-pc-phase', 'pre');
    const timers = [];
    const rafs = new Set();
    const countUp = (node, delay) => {
      const target = Number(node.getAttribute('data-pc-count'));
      timers.push(setTimeout(() => {
        const t0 = performance.now();
        const step = (now) => {
          const p = Math.min(1, (now - t0) / ENTER_COUNT_MS);
          const eased = 1 - Math.pow(1 - p, 3);
          setNum(node, p >= 1 ? target : Math.round(target * eased));
          if (p < 1) rafs.add(requestAnimationFrame(step));
        };
        rafs.add(requestAnimationFrame(step));
      }, delay));
    };
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        io.disconnect();
        entering.current = true;
        el.setAttribute('data-pc-phase', 'in');
        nums.forEach((node) => {
          const card = node.closest('.pc-card');
          const slot = card ? Number(card.getAttribute('data-slot')) : 0;
          countUp(node, Number.isNaN(slot) ? 0 : (2 - Math.min(2, slot)) * ENTER_STAGGER);
        });
        timers.push(setTimeout(finishEntrance, ENTER_DONE_MS));
      });
    }, { threshold: 0.2 });
    io.observe(el);
    return () => {
      io.disconnect();
      timers.forEach(clearTimeout);
      rafs.forEach((id) => cancelAnimationFrame(id));
      nums.forEach((node) => setNum(node, node.getAttribute('data-pc-count')));
    };
  }, []);

  // After a back-card click, the clicked button unmounts (it becomes the front
  // card), so move focus to the new front card's container.
  useEffect(() => {
    if (focusFront.current) {
      focusFront.current = false;
      const el = frontRefs.current[active];
      if (el) el.focus({ preventScroll: true });
    }
  }, [active]);

  const go = (i) => { finishEntrance(); setActive(((i % n) + n) % n); };
  const next = () => go(active + 1);
  const prev = () => go(active - 1);

  const onKeyDown = (e) => {
    if (e.key === 'ArrowRight') { e.preventDefault(); next(); }
    else if (e.key === 'ArrowLeft') { e.preventDefault(); prev(); }
    else if (e.key === 'Home') { e.preventDefault(); go(0); }
    else if (e.key === 'End') { e.preventDefault(); go(n - 1); }
  };

  const onPointerDown = (e) => {
    if (e.pointerType === 'mouse') return;
    touch.current = { x: e.clientX, y: e.clientY, t: e.timeStamp };
  };
  const onPointerUp = (e) => {
    const s = touch.current;
    touch.current = null;
    if (!s) return;
    const dx = e.clientX - s.x;
    const dy = e.clientY - s.y;
    const dt = Math.max(1, e.timeStamp - s.t);
    const width = e.currentTarget.getBoundingClientRect().width || 1;
    if (Math.abs(dx) < 24 || Math.abs(dx) < Math.abs(dy)) return;
    if (Math.abs(dx) > width * 0.3 || Math.abs(dx) / dt > 0.4) {
      if (dx < 0) next(); else prev();
    }
  };

  const cur = slides[active];

  return (
    <div
      ref={rootRef}
      className="pc-root"
      role="region"
      aria-roledescription="carousel"
      aria-label={ariaLabel}
      onKeyDown={onKeyDown}
    >
      <style>{`
        .pc-root { --pc-ease: ${EASE}; }
        .pc-stage { display: grid; padding: 96px 0 24px 72px; }
        .pc-card { grid-area: 1 / 1; position: relative; box-sizing: border-box; width: 100%; max-width: 880px; min-height: 560px; padding: 48px; border-radius: 22px; background: #1F1815; border: 1px solid rgba(255,244,230,0.16); box-shadow: 0 40px 90px -50px rgba(0,0,0,0.9); color: #FFF9F0; transform-origin: 20% 80%; touch-action: pan-y; transition: transform 420ms var(--pc-ease), opacity 420ms var(--pc-ease), translate 420ms var(--pc-ease), background-color 220ms var(--pc-ease), border-color 220ms var(--pc-ease); outline: none; }
        .pc-card[data-slot="0"] { z-index: 3; background: ${INK}; }
        .pc-card[data-slot="1"] { z-index: 2; transform: translate(-36px,-46px) scale(.96) rotate(-1.5deg); }
        .pc-card[data-slot="2"] { z-index: 1; transform: translate(-72px,-92px) scale(.92) rotate(-3deg); }
        .pc-card[data-slot="far"] { z-index: 0; opacity: 0; pointer-events: none; transform: translate(-72px,-92px) scale(.92) rotate(-3deg); }
        .pc-card:focus-visible { box-shadow: 0 0 0 3px #FBF7F1, 0 0 0 6px ${AMBER}; }
        /* Entrance: the individual translate property composes with the slot transforms and hover transforms, so the resting fan is untouched. */
        .pc-root { --pc-enter-y: 120px; }
        .pc-root[data-pc-phase="pre"] .pc-card:not([data-slot="far"]) { translate: 0 var(--pc-enter-y); opacity: 0; }
        .pc-root[data-pc-phase="in"] .pc-card:not([data-slot="far"]) { transition-property: transform, translate, opacity, background-color, border-color; transition-duration: 420ms, 700ms, 500ms, 220ms, 220ms; transition-timing-function: var(--pc-ease), cubic-bezier(0.16,1,0.3,1), var(--pc-ease), var(--pc-ease), var(--pc-ease); }
        .pc-root[data-pc-phase="in"] .pc-card[data-slot="2"] { transition-delay: 0ms; }
        .pc-root[data-pc-phase="in"] .pc-card[data-slot="1"] { transition-delay: ${ENTER_STAGGER}ms; }
        .pc-root[data-pc-phase="in"] .pc-card[data-slot="0"] { transition-delay: ${ENTER_STAGGER * 2}ms; }
        @media (hover: hover) {
          .pc-card[data-slot="1"]:hover { transform: translate(-26px,-38px) scale(.98) rotate(-1.5deg); background: #241C18; }
          .pc-card[data-slot="2"]:hover { transform: translate(-62px,-84px) scale(.94) rotate(-3deg); background: #241C18; }
          .pc-card[data-slot="1"]:hover .pc-index, .pc-card[data-slot="2"]:hover .pc-index { color: rgba(255,243,228,0.8); }
        }
        .pc-inner { display: grid; grid-template-columns: minmax(0, 58fr) minmax(0, 42fr); gap: 40px; align-items: center; height: 100%; }
        .pc-index { font-family: ${HEAD}; font-size: 11px; letter-spacing: 0.22em; text-transform: uppercase; color: rgba(255,243,228,0.5); margin-bottom: 28px; transition: color 420ms var(--pc-ease); }
        .pc-card[data-slot="0"] .pc-index { color: ${AMBER}; }
        .pc-back .pc-index { position: absolute; top: 8px; left: 50px; margin: 0; }
        .pc-lead { min-height: 214px; }
        .pc-num { font-family: ${HEAD}; font-weight: 500; font-size: clamp(72px, 7vw, 112px); line-height: 1; letter-spacing: -0.04em; color: rgba(255,243,228,0.5); margin-bottom: 14px; transition: color 420ms var(--pc-ease); }
        .pc-card[data-slot="0"] .pc-num { color: ${AMBER}; }
        .pc-pct { font-size: 0.45em; vertical-align: 0.9em; margin-left: 0.04em; }
        .pc-sentence { font-family: ${HEAD}; font-weight: 500; font-size: 24px; line-height: 1.2; color: #FFF9F0; max-width: 20em; margin: 0; }
        .pc-problem { font-size: 15px; line-height: 1.6; color: rgba(255,243,228,0.66); max-width: 30em; margin: 12px 0 0; }
        .pc-sentence-words { font-size: 32px; line-height: 1.15; max-width: 17em; }
        .pc-source { display: flex; align-items: center; gap: 10px; margin: 16px 0 0; font-size: 12.5px; letter-spacing: 0.04em; color: rgba(255,243,228,0.5); }
        .pc-source::before { content: ''; width: 1px; height: 18px; background: rgba(255,243,228,0.4); flex-shrink: 0; }
        .pc-card[data-slot="0"] .pc-source::before { background: ${AMBER}; }
        .pc-source a { color: inherit; text-decoration: underline; text-underline-offset: 3px; }
        .pc-source a:hover { color: #F3C48B; }
        .pc-source a:focus-visible, .pc-nav:focus-visible, .pc-dot:focus-visible, .pc-hit:focus-visible { outline: 3px solid ${AMBER}; outline-offset: 3px; }
        .pc-pill { display: inline-block; margin-top: 28px; padding: 5px 12px; border-radius: 999px; background: rgba(232,163,85,0.14); border: 1px solid rgba(232,163,85,0.28); font-family: ${HEAD}; font-size: 10.5px; letter-spacing: 0.2em; text-transform: uppercase; color: #F3C48B; }
        .pc-solution { font-size: 16px; line-height: 1.68; color: rgba(255,243,228,0.66); max-width: 34em; margin: 14px 0 0; }
        .pc-visual-wrap { width: 100%; max-width: 300px; margin: 0 auto; }
        .pc-visual { display: block; width: 100%; max-width: 300px; height: auto; margin: 0 auto; }
        .pc-track { stroke: rgba(255,244,230,0.14); }
        .pc-mark, .pc-link, .pc-node { stroke: rgba(255,243,228,0.5); transition: stroke 420ms var(--pc-ease); }
        .pc-link { stroke: rgba(255,243,228,0.28); }
        .pc-mark-fill, .pc-centre { fill: rgba(255,243,228,0.5); transition: fill 420ms var(--pc-ease); }
        .pc-cell-on { fill: rgba(255,243,228,0.18); transition: fill 420ms var(--pc-ease); }
        .pc-cell-off { fill: none; stroke: rgba(255,244,230,0.14); }
        .pc-card[data-slot="0"] .pc-mark, .pc-card[data-slot="0"] .pc-node { stroke: ${AMBER}; }
        .pc-card[data-slot="0"] .pc-mark-fill, .pc-card[data-slot="0"] .pc-centre, .pc-card[data-slot="0"] .pc-cell-on { fill: ${AMBER}; }
        .pc-caption { margin-top: 14px; text-align: center; font-family: ${HEAD}; font-size: 12px; letter-spacing: 0.12em; text-transform: uppercase; color: rgba(255,243,228,0.55); }
        .pc-hit { position: absolute; inset: 0; z-index: 2; margin: 0; padding: 0; border: 0; border-radius: 22px; background: transparent; cursor: pointer; }
        .pc-sr { position: absolute; width: 1px; height: 1px; margin: -1px; padding: 0; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }
        .pc-controls { display: flex; align-items: center; gap: 12px; margin-top: 40px; }
        .pc-nav { display: grid; place-items: center; width: 44px; height: 44px; padding: 0; border-radius: 50%; border: 1px solid rgba(26,21,18,0.2); background: transparent; color: #1A1512; cursor: pointer; transition: border-color 200ms var(--pc-ease), background-color 200ms var(--pc-ease), transform 120ms var(--pc-ease); }
        .pc-nav:hover { border-color: ${AMBER}; background: rgba(224,154,48,0.08); }
        .pc-nav:active { transform: scale(.96); }
        .pc-dots { display: flex; align-items: center; margin-left: 16px; }
        .pc-dot { display: grid; place-items: center; width: 24px; height: 24px; padding: 0; border: 0; background: transparent; cursor: pointer; }
        .pc-dot span { display: block; width: 8px; height: 8px; border-radius: 999px; background: rgba(26,21,18,0.45); transition: width 300ms var(--pc-ease), background-color 300ms var(--pc-ease); }
        .pc-dot:hover span { background: rgba(26,21,18,0.65); }
        .pc-dot[aria-current="true"] span { width: 22px; background: ${AMBER}; }
        .pc-count { margin-left: auto; font-family: ${HEAD}; font-size: 12px; letter-spacing: 0.22em; color: rgba(26,21,18,0.55); }

        /* Tablet and phone: single card, slivers of the next cards behind it. */
        @media (max-width: 999px) {
          .pc-stage { padding: 0 16px 0 0; overflow-x: clip; }
          .pc-card { max-width: none; min-height: 0; padding: 28px; }
          .pc-card[data-slot="1"] { transform: translateX(8px) scale(.96); }
          .pc-card[data-slot="2"] { transform: translateX(16px) scale(.92); }
          .pc-card[data-slot="far"] { transform: translateX(16px) scale(.92); }
          .pc-root { --pc-enter-y: 60px; }
          @media (hover: hover) {
            .pc-card[data-slot="1"]:hover { transform: translateX(12px) scale(.96); }
            .pc-card[data-slot="2"]:hover { transform: translateX(20px) scale(.92); }
          }
          .pc-card:not([data-slot="0"]) .pc-inner { visibility: hidden; }
          .pc-back .pc-index { display: none; }
          .pc-inner { grid-template-columns: 1fr; gap: 24px; }
          .pc-visual-wrap, .pc-visual { max-width: 140px; }
          .pc-tick, .pc-caption { display: none; }
          .pc-index { margin-bottom: 20px; }
          .pc-lead { min-height: 0; }
          .pc-num { font-size: 72px; }
          .pc-sentence { font-size: 20px; line-height: 1.22; }
          .pc-sentence-words { font-size: 26px; line-height: 1.18; }
          .pc-problem { font-size: 14.5px; }
          .pc-solution { font-size: 15.5px; line-height: 1.66; }
          .pc-controls { margin-top: 16px; }
          .pc-dot { width: 44px; height: 44px; }
          .pc-dots { margin-left: 4px; }
          .pc-count { display: none; }
        }
        @media (prefers-reduced-motion: reduce) {
          .pc-card, .pc-card * { transition: none !important; }
          .pc-root[data-pc-phase] .pc-card:not([data-slot="far"]) { opacity: 1; translate: none; }
          .pc-card[data-slot="0"] { animation: pc-fade 120ms ease-out; }
          @media (hover: hover) {
            .pc-card[data-slot="1"]:hover, .pc-card[data-slot="2"]:hover { border-color: rgba(232,163,85,0.28); background: #1F1815; }
            .pc-card[data-slot="1"]:hover { transform: translate(-36px,-46px) scale(.96) rotate(-1.5deg); }
            .pc-card[data-slot="2"]:hover { transform: translate(-72px,-92px) scale(.92) rotate(-3deg); }
          }
        }
        @keyframes pc-fade { from { opacity: 0; } to { opacity: 1; } }
      `}</style>

      <div
        className="pc-stage"
        role="group"
        aria-label="Slides"
        onPointerDown={onPointerDown}
        onPointerUp={onPointerUp}
        onPointerCancel={() => { touch.current = null; }}
      >
        {slides.map((slide, i) => {
          const rel = ((i - active) % n + n) % n;
          const slot = rel <= 2 ? String(rel) : 'far';
          const isFront = rel === 0;
          return (
            <div
              key={slide.id}
              className={isFront ? 'pc-card' : 'pc-card pc-back'}
              data-slot={slot}
              role="group"
              aria-roledescription="slide"
              aria-label={`Slide ${i + 1} of ${n}`}
              tabIndex={isFront ? -1 : undefined}
              ref={(el) => { frontRefs.current[i] = el; }}
            >
              {!isFront && rel <= 2 && (
                <button
                  type="button"
                  className="pc-hit"
                  onClick={() => { focusFront.current = true; go(i); }}
                >
                  <span className="pc-sr">{`Show slide ${i + 1}: ${slide.label}`}</span>
                </button>
              )}
              <div className="pc-inner" aria-hidden={isFront ? undefined : 'true'}>
                <div>
                  <div className="pc-index">{`${pad2(i + 1)} / ${slide.label}`}</div>
                  <div className="pc-lead">
                    {slide.percent != null && (
                      <div className="pc-num" aria-hidden="true"><span data-pc-count={slide.percent}>{slide.percent}</span><span className="pc-pct">%</span></div>
                    )}
                    <p className={slide.percent != null ? 'pc-sentence' : 'pc-sentence pc-sentence-words'}>{slide.sentence}</p>
                    {slide.problem && <p className="pc-problem">{slide.problem}</p>}
                    {slide.source && (
                      <p className="pc-source">
                        <a href={slide.source.href} target="_blank" rel="noopener noreferrer" tabIndex={isFront ? undefined : -1}>{slide.source.text}</a>
                      </p>
                    )}
                  </div>
                  <span className="pc-pill">Solution</span>
                  <p className="pc-solution">{slide.solution}</p>
                </div>
                <div className="pc-visual-col"><Visual slide={slide} /></div>
              </div>
            </div>
          );
        })}
      </div>

      <div className="pc-controls">
        <button type="button" className="pc-nav" aria-label="Previous slide" onClick={prev}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M15 5l-7 7 7 7" /></svg>
        </button>
        <button type="button" className="pc-nav" aria-label="Next slide" onClick={next}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M9 5l7 7-7 7" /></svg>
        </button>
        <div className="pc-dots" role="group" aria-label="Choose slide">
          {slides.map((s, i) => (
            <button
              key={s.id} type="button" className="pc-dot"
              aria-label={`Go to slide ${i + 1}`}
              aria-current={i === active ? 'true' : undefined}
              onClick={() => go(i)}
            >
              <span />
            </button>
          ))}
        </div>
        <div className="pc-count" aria-hidden="true">{`${pad2(active + 1)} / ${pad2(n)}`}</div>
      </div>

      <div className="pc-sr" aria-live="polite" aria-atomic="true">{`Slide ${active + 1} of ${n}: ${cur.label}`}</div>
    </div>
  );
}
