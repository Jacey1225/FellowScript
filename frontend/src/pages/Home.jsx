import React, { useEffect, useLayoutEffect, useRef } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { useParallaxBlobs } from '../hooks/useParallaxBlobs.js';
import Seo from '../components/Seo.jsx';
import ProblemCarousel from '../components/ProblemCarousel.jsx';
import { useExploreEnabled } from '../hooks/useExploreEnabled.js';
import { SITE_URL } from '../config.js';
// Task 20261008-homepage-reaching-section: the two halftone hands (OpenArt
// source, already generated; recompressed to webp with alpha). Imported through
// Vite so the prerender (SSR) build and the client build both emit the same
// content-hashed /assets/ URL.
import handLeftCream from '../assets/reaching/hand-left-cream.webp';
import handRightAmber from '../assets/reaching/hand-right-amber.webp';
import {
  HOME_SEO_PATH,
  HOME_SEO_TITLE,
  HOME_SEO_DESCRIPTION,
  HOME_SEO_IMAGE,
  homeJsonLd,
} from '../seo/homeSeo.js';

// Task 20260914-restore-homepage-seo-meta-tags: title/description/image/
// JSON-LD now live in src/seo/homeSeo.js so vite.config.js's build-time
// <head> injection (see its Decision comment) uses exactly the same content
// as this client-side render, instead of a second copy that could drift.
const HOME_JSON_LD = homeJsonLd(SITE_URL);

// ── Palette (this page only — a distinct marketing-site look from the app's
// own gold/parchment theme used in Reader/Account/etc.) ──────────────────────
const INK    = '#17120F';
const CREAM  = '#F6EFE6';
// Kept in the family of the in-app --gold-light (#E09A30) so the accent hue
// doesn't visibly shift on a Home→Reader signed-in transition (design-notes.md §6).
const AMBER  = '#E09A30';
const AMBER_LIGHT = '#F3C48B';
const LIGHT_BG = '#FBF7F1';
const LIGHT_INK = '#1A1512';

const HEAD_FONT = "'Schibsted Grotesk', sans-serif";
const BODY_FONT = "'Hanken Grotesk', system-ui, sans-serif";

// ── Small building blocks ─────────────────────────────────────────────────────

// aria-hidden (task 20260909-website-seo semantic review): decorative bullet
// mark -- every Check is immediately followed by the actual perk text.
function Check() {
  return (
    <span style={{ display: 'grid', placeItems: 'center', width: 20, height: 20, borderRadius: '50%', background: 'rgba(232,163,85,0.2)', color: AMBER, flexShrink: 0, marginTop: 2 }} aria-hidden="true">
      <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
        <path d="M4 12.5l5.5 5.5L20 7" />
      </svg>
    </span>
  );
}

function PillButton({ to, primary, children }) {
  const base = {
    display: 'inline-flex', alignItems: 'center', gap: 9,
    padding: '15px 26px', borderRadius: 999,
    fontFamily: BODY_FONT, fontSize: 14, fontWeight: 600, letterSpacing: '0.01em',
  };
  const style = primary
    ? { ...base, background: AMBER, color: '#21160F' }
    : { ...base, border: '1px solid rgba(255,244,230,0.4)', color: '#FFF8EE', background: 'rgba(23,18,15,0.2)' };
  return <Link to={to} className={primary ? 'hm-btn-primary' : 'hm-btn-outline'} style={style}>{children}</Link>;
}

// Radial-gradient blob field + drifting dust, shared by Hero and Community.
function Blobs({ innerRef, overlay }) {
  return (
    <div ref={innerRef} style={{ position: 'absolute', inset: 0, overflow: 'hidden', pointerEvents: 'none' }}>
      <div data-fs-blob="1" data-fs-depth="0.05" style={{ position: 'absolute', width: '76vw', height: '76vw', minWidth: 720, minHeight: 720, left: '4%', top: '8%', borderRadius: '50%', background: 'radial-gradient(circle at 34% 26%, #FFEBCF 0%, #F0B36A 18%, #E8A355 30%, #C4682F 52%, #8A3A2C 70%, #351914 100%)', boxShadow: '0 0 300px 90px rgba(232,163,85,0.22)', willChange: 'transform' }} />
      <div data-fs-blob="2" data-fs-depth="-0.09" style={{ position: 'absolute', width: '40vw', height: '40vw', minWidth: 420, minHeight: 420, right: '-8%', top: '-12%', borderRadius: '50%', background: 'radial-gradient(circle at 60% 70%, rgba(240,179,106,0.85) 0%, rgba(150,62,44,0.6) 45%, rgba(23,18,15,0) 78%)', filter: 'blur(6px)', willChange: 'transform' }} />
      <div data-fs-blob="3" data-fs-depth="0.13" style={{ position: 'absolute', width: '34vw', height: '34vw', minWidth: 340, minHeight: 340, left: '-10%', bottom: '-14%', borderRadius: '50%', background: 'radial-gradient(circle at 40% 40%, rgba(232,163,85,0.5) 0%, rgba(90,40,32,0.4) 50%, rgba(23,18,15,0) 80%)', filter: 'blur(10px)', willChange: 'transform' }} />
      <div data-fs-dust="1" style={{ position: 'absolute', inset: '-6%' }} />
      <div style={{ position: 'absolute', inset: 0, background: overlay }} />
    </div>
  );
}

// Task 20260921-homepage-family-section-redesign: lightweight, one-shot
// "enter viewport" reveal for the "Not just once a week" section below.
// Toggles a data attribute directly on the observed element (not React
// state, to avoid a re-render on scroll — same DOM-first approach as
// useParallaxBlobs.js above) the first time it crosses the threshold, then
// stops observing. Skipped entirely under prefers-reduced-motion, matching
// this file's existing motion-gating convention; the CSS below also forces
// every element this drives back to its resting (fully visible, static)
// state under that same media query as a belt-and-suspenders backstop, so a
// reduced-motion visitor never depends on this effect having run at all.
function useRevealOnScroll(ref) {
  useEffect(() => {
    if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const el = ref.current;
    if (!el || !('IntersectionObserver' in window)) return;
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.setAttribute('data-fs-in-view', 'true');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.2, rootMargin: '0px 0px -8% 0px' });
    io.observe(el);
    return () => io.disconnect();
  }, []);
}

// Task 20261008-homepage-section-entrance-transitions: one-shot collage-style
// entrance for the reaching section's hands + bloom. Progressive enhancement:
// SSR / no-JS / reduced-motion render the final resting state; the hidden
// "pre" state exists only because this layout effect sets data-fs-reach on the
// section client-side before first paint (useLayoutEffect: no flash of
// visible-then-hidden; isomorphic so the prerender does not warn). Own
// observer at threshold 0.33 ("about a third visible"); plays once.
const useIsoLayoutEffect = typeof window !== 'undefined' ? useLayoutEffect : useEffect;

function useReachEntrance(ref) {
  useIsoLayoutEffect(() => {
    if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return undefined;
    const el = ref.current;
    if (!el || !('IntersectionObserver' in window)) return undefined;
    el.setAttribute('data-fs-reach', 'pre');
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          el.setAttribute('data-fs-reach', 'in');
          io.disconnect();
        }
      });
    }, { threshold: 0.33 });
    io.observe(el);
    return () => io.disconnect();
  }, []);
}

// Task 20261008-homepage-reaching-section: the halftone hands drift a few px
// toward each other as the section scrolls through the viewport. Tunables are
// named constants (not scattered magic numbers). Scroll is rAF-throttled and
// writes one CSS variable (--fs-drift, 0..1, eased) straight onto the section
// -- DOM-first like useRevealOnScroll, no React re-render per scroll event.
// Skipped entirely under prefers-reduced-motion (the CSS in the <style> block
// also pins the hands static there as a backstop).
const HAND_DRIFT_PX = 6;         // desktop travel per hand at full progress
const HAND_DRIFT_PX_MOBILE = 3;  // 390px band: smaller travel

function useHandDrift(ref) {
  useEffect(() => {
    if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const el = ref.current;
    if (!el) return;
    let raf = 0;
    const update = () => {
      raf = 0;
      const r = el.getBoundingClientRect();
      const vh = window.innerHeight || 1;
      // 0 as the section's top edge enters the bottom of the viewport, 1 as its
      // bottom edge leaves the top.
      const p = Math.min(1, Math.max(0, (vh - r.top) / (vh + r.height)));
      const eased = p * p * (3 - 2 * p); // smoothstep: never linear
      el.style.setProperty('--fs-drift', eased.toFixed(3));
    };
    const onScroll = () => { if (!raf) raf = window.requestAnimationFrame(update); };
    update();
    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onScroll);
    return () => {
      window.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onScroll);
      if (raf) window.cancelAnimationFrame(raf);
    };
  }, []);
}

// Purely decorative hand-drawn marker strokes (task
// 20260921-homepage-family-section-redesign) — mined from the "French
// Notez" hand-lettering reference for technique only, not the reference's
// own script font or its cream/orange palette (design-notes.md §Conflicts
// #1-2): drawn in AMBER as loose, slightly imperfect SVG paths rather than
// a decorative font import, so the one "off-system" gesture stays inside
// this page's existing color system. Each one is aria-hidden — it always
// sits directly against real, already-readable text (a headline word, a
// quote), never carries meaning on its own. `pathLength="1"` lets the CSS
// draw-on animation below use simple 0–1 dasharray/dashoffset math
// regardless of each path's actual geometry.
function HandDrawnCircle({ style, className }) {
  return (
    <svg aria-hidden="true" className={className} viewBox="0 0 176 64" style={{ position: 'absolute', pointerEvents: 'none', ...style }}>
      <path
        className="hm-draw-path"
        pathLength="1"
        d="M20 42 C8 26 24 8 58 5 C98 2 142 8 158 24 C170 36 162 52 126 58 C90 64 42 60 22 48 C15 44 16 41 21 42"
        fill="none" stroke={AMBER} strokeWidth="4.8" strokeLinecap="round" strokeLinejoin="round"
      />
    </svg>
  );
}

function HandDrawnUnderline({ style }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 220 20" preserveAspectRatio="none" style={{ position: 'absolute', pointerEvents: 'none', ...style }}>
      <path
        className="hm-draw-path"
        pathLength="1"
        d="M3 12 C42 3 72 19 112 8 C152 -3 182 17 217 6"
        fill="none" stroke={AMBER} strokeWidth="4" strokeLinecap="round"
      />
    </svg>
  );
}

function HandDrawnQuoteMark({ size = 46 }) {
  return (
    <svg aria-hidden="true" width={size} height={size * 0.78} viewBox="0 0 60 46">
      <path className="hm-draw-path" pathLength="1" d="M15 6 C4 11 1 23 7 33 C11 39 20 41 25 35" fill="none" stroke={AMBER} strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" />
      <path className="hm-draw-path" pathLength="1" d="M43 6 C32 11 29 23 35 33 C39 39 48 41 53 35" fill="none" stroke={AMBER} strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

// ── Content (kept in sync with the real backend — dynamic 1-8 member group pricing) ──

// Task 20261008-homepage-problem-carousel: every figure below is a survey
// statistic with a visible source line; see
// .claude/pipeline/20261008-homepage-problem-carousel/stats-verification.md.
const problemSlides = [
  {
    id: 'private',
    label: 'KEPT PRIVATE',
    visual: 'ring',
    percent: 56,
    sentence: '56% of U.S. Christians say their spiritual life is entirely private.',
    source: { text: 'Barna Group & The Navigators, 2022', href: 'https://www.barna.com/trends/stat-download-spiritual-lives/' },
    solution: "FellowScript encourages a community that invites doubt, questions, struggles, shame and the emotions that can be a barrier to experiencing God's peace.",
  },
  {
    id: 'growth',
    label: 'TIME AND RESOURCES',
    visual: 'network',
    percent: 34,
    sentence: 'Only 34% of U.S. congregations grew by 5% or more between 2015 and 2020.',
    problem: "Many churches struggle to grow their community, often because there isn't enough time and resources to organize.",
    source: { text: 'Hartford Institute, Faith Communities Today, 2020', href: 'https://goodfaithmedia.org/most-u-s-faith-communities-are-small-with-declining-attendance/' },
    solution: 'FellowScript gives churches a digital platform that organizes it all effortlessly by connecting people through an advanced, intelligent grouping system.',
  },
  {
    id: 'word',
    label: 'IN THE WORD',
    visual: 'waffle',
    percent: 32,
    sentence: 'Only 32% of Protestant churchgoers read the Bible every day.',
    source: { text: 'LifeWay Research, 2019', href: 'https://thealabamabaptist.org/?p=102486' },
    solution: 'FellowScript uses the people around you to keep each other connected in the word, with continuous accountability check-ins and effortless devotions to pick up on together.',
  },
];

const communityPerks = [
  'Shared reading & highlights across all members',
  'Real-time group messaging and discussion',
  'Each member gets their own AI companion',
  "Host controls — manage who's in the group",
];

const chatMock = [
  { name: 'Jacey',  msg: 'v.28 hit different today. Highlighted the whole verse.', time: '7:14 AM', avatar: 'J', reaction: '🙌 3' },
  { name: 'Samel',  msg: 'Same. Been sitting with "groanings too deep for words" all week.', time: '7:21 AM', avatar: 'S' },
  { name: 'Marcus', msg: 'Adding a note before work. See you all at the 6pm study.', time: '7:36 AM', avatar: 'M', reaction: '❤️ 2' },
];

const plans = [
  {
    name: 'Free',
    price: '$0',
    sub: 'No card needed',
    perks: ['Beautiful Bible reader', '5 notes per week', '1 scheduled devotion', '3 scheduled notifications', 'Verse highlights & bookmarks'],
    cta: 'Start reading',
    href: '/signin',
    primary: false,
  },
  {
    name: 'Group',
    price: 'From $4.99',
    sub: 'Pick 1 to 8 members · Billed monthly',
    perks: ['Unlimited notes', 'Unlimited scheduled devotions', 'Unlimited notifications', 'Shared reading space & group chat', 'Live study sessions', 'Priority support'],
    cta: 'Subscribe',
    href: '/signin',
    primary: true,
  },
];

// ── Page ──────────────────────────────────────────────────────────────────────

export default function Home() {
  const { user } = useAuth();
  const cta = user ? '/reader' : '/signin';
  // Task 20261001-explorer-listings step 9: runtime probe only (false during
  // prerender, so the static Home bytes are unchanged).
  const exploreOn = useExploreEnabled();

  const heroBgRef = useRef(null);
  const communityBgRef = useRef(null);
  useParallaxBlobs([heroBgRef, communityBgRef]);

  // Task 20260921-homepage-family-section-redesign: scroll-entrance reveal
  // for the "Not just once a week" section — see useRevealOnScroll above.
  const familyRef = useRef(null);
  useRevealOnScroll(familyRef);
  useHandDrift(familyRef);
  useReachEntrance(familyRef);

  return (
    <div style={{ fontFamily: BODY_FONT, color: CREAM, background: INK, overflowX: 'hidden' }}>
      <Seo
        title={HOME_SEO_TITLE}
        description={HOME_SEO_DESCRIPTION}
        path={HOME_SEO_PATH}
        image={HOME_SEO_IMAGE}
        jsonLd={HOME_JSON_LD}
      />
      <style>{`
        @keyframes hm-orbit { to { transform: rotate(360deg); } }
        @keyframes hm-float { 0%,100% { transform: translateY(0); } 50% { transform: translateY(-14px); } }
        @media (prefers-reduced-motion: reduce) {
          .hm-float, .hm-orbit-spin { animation: none !important; }
          /* Task 20260921-homepage-family-section-redesign: belt-and-suspenders
             backstop for the "Not just once a week" section's scroll reveal —
             useRevealOnScroll already skips observing under this same media
             query, so [data-fs-in-view] never gets set; this rule guarantees
             every element it would have revealed still renders fully visible
             and static even if that JS gate is ever bypassed or races. */
          .hm-family-reveal { opacity: 1 !important; transform: none !important; transition: none !important; }
          .hm-reach-hand { transform: none !important; transition: none !important; }
          /* Entrance backstop: final state even if the JS gate is bypassed. */
          .hm-reach-hand, .hm-reach-bloom { translate: none !important; rotate: none !important; }
          .hm-reach[data-fs-reach] .hm-reach-bloom { opacity: 1 !important; transition: none !important; }
        }

        /* Task 20260921-homepage-family-section-redesign — "Not just once a
           week" section: lightweight viewport-entrance fade (opacity + small
           y-offset), staggered per element via inline transitionDelay, eased
           with the same settle curve used for hm-btn above. */
        .hm-family-reveal {
          opacity: 0;
          transform: translateY(26px);
          transition: opacity 640ms cubic-bezier(0.16,1,0.3,1), transform 640ms cubic-bezier(0.16,1,0.3,1);
        }
        [data-fs-in-view="true"] .hm-family-reveal { opacity: 1; transform: translateY(0); }

        /* Hand-drawn marker "draw-on" — stroke-dashoffset scrubbed from 1 to 0
           via CSS transition once the section is in view; wrapped in its own
           not(prefers-reduced-motion) query (on top of the JS-level skip in
           useRevealOnScroll) so a reduced-motion visitor's default state
           (dashoffset: 0, fully drawn, no transition at all) is never
           overridden into a hidden starting state in the first place. */
        .hm-draw-path { stroke-dasharray: 1; stroke-dashoffset: 0; }
        @media not (prefers-reduced-motion: reduce) {
          .hm-draw-path { stroke-dashoffset: 1; transition: stroke-dashoffset 850ms cubic-bezier(0.65,0,0.35,1) 480ms; }
          [data-fs-in-view="true"] .hm-draw-path { stroke-dashoffset: 0; }
        }

        /* Task 20261008-homepage-reaching-section — "Reaching" composition.
           Everything in the headline stage is sized in em off .hm-reach-stage's
           font-size (the headline size), so the hands, scrim and bloom keep their
           position relative to the headline at every width. Desktop fingertips
           stop at the headline edge, about 755px apart at 1440 (not the ~100px
           gap in the early spec text: hand art over white text fails contrast). */
        .hm-reach { position: relative; overflow: hidden; background: ${INK}; border-top: 1px solid rgba(255,244,230,0.14); border-bottom: 1px solid rgba(255,244,230,0.14); padding: 56px clamp(20px, 5vw, 64px); --fs-drift-px: ${HAND_DRIFT_PX}px; }
        .hm-reach-xgrid { position: absolute; inset: 0; opacity: 0.10; pointer-events: none; background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='140' height='140'><text x='70' y='72' font-size='9.6' text-anchor='middle' fill='%23FFF4E6' font-family='sans-serif'>x</text></svg>"); -webkit-mask-image: radial-gradient(ellipse 55% 50% at 50% 42%, transparent 70%, #000 100%); mask-image: radial-gradient(ellipse 55% 50% at 50% 42%, transparent 70%, #000 100%); }
        .hm-reach-bandgrid { display: none; }
        .hm-reach-grain { position: absolute; inset: 0; opacity: 0.04; mix-blend-mode: screen; pointer-events: none; background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><filter id='n'><feTurbulence baseFrequency='.9' numOctaves='2'/></filter><rect width='200' height='200' filter='url(%23n)'/></svg>"); }
        .hm-reach-plus { position: absolute; width: 10px; height: 10px; pointer-events: none; }
        .hm-reach-plus::before, .hm-reach-plus::after { content: ''; position: absolute; background: rgba(255,244,230,0.4); }
        .hm-reach-plus::before { left: 4.5px; top: 0; width: 1px; height: 10px; }
        .hm-reach-plus::after { top: 4.5px; left: 0; height: 1px; width: 10px; }
        .hm-reach-inner { position: relative; max-width: 1240px; margin: 0 auto; text-align: center; }
        .hm-reach-eyebrow { font-family: ${HEAD_FONT}; font-size: 11.5px; letter-spacing: 0.26em; text-transform: uppercase; color: ${AMBER}; padding-bottom: 22px; border-bottom: 1px solid rgba(255,244,230,0.14); line-height: 1.6; }
        .hm-reach-stage { position: relative; margin-top: 80px; font-size: clamp(40px, 7vw, 100px); }
        .hm-reach-hands { position: absolute; inset: 0; pointer-events: none; display: block; }
        .hm-reach-bloom { position: absolute; display: block; left: 50%; top: 2.47em; width: 8.4em; height: 8.4em; transform: translate(-50%, -50%); background: radial-gradient(circle, rgba(224,154,48,0.34), transparent 50%); }
        .hm-reach-hand { position: absolute; display: block; height: auto; top: 2.74em; transition: transform 600ms cubic-bezier(0.22,1,0.36,1); will-change: transform; translate: 0 0; rotate: 0deg; transition: transform 600ms cubic-bezier(0.22,1,0.36,1), translate 1000ms cubic-bezier(0.16,1,0.3,1), rotate 1000ms cubic-bezier(0.16,1,0.3,1); }
        .hm-reach-hand-l { right: calc(50% + 3.9em); width: 7em; opacity: 0.8; transform: translate3d(calc(var(--fs-drift, 0) * var(--fs-drift-px)), 0, 0); }
        .hm-reach-hand-r { left: calc(50% + 3.9em); width: 6em; opacity: 0.85; transform: translate3d(calc(var(--fs-drift, 0) * var(--fs-drift-px) * -1), 0, 0); }
        /* Entrance (client-only; data-fs-reach is set after mount, never in SSR).
           Individual translate/rotate compose with the drift transform above. */
        .hm-reach { --hm-reach-travel: 50vw; }
        .hm-reach-bloom { transition: opacity 450ms cubic-bezier(0.16,1,0.3,1) 650ms; }
        .hm-reach[data-fs-reach="pre"] .hm-reach-bloom { opacity: 0; }
        .hm-reach[data-fs-reach="pre"] .hm-reach-hand-l { translate: calc(var(--hm-reach-travel) * -1) 0; rotate: -9deg; }
        .hm-reach[data-fs-reach="pre"] .hm-reach-hand-r { translate: var(--hm-reach-travel) 0; rotate: 9deg; }
        .hm-reach-scrim { position: absolute; display: block; left: 50%; top: 50%; width: 7.6em; height: 4.2em; transform: translate(-50%, -50%); background: radial-gradient(ellipse at center, rgba(23,18,15,0.7) 0, rgba(23,18,15,0.6) 50%, transparent 74%); }
        .hm-reach-bandfade { display: none; }
        .hm-reach-h2 { position: relative; z-index: 1; font-family: ${HEAD_FONT}; font-size: 1em; line-height: 0.98; font-weight: 400; letter-spacing: -0.035em; margin: 0 auto; max-width: 9em; color: #FFF9F0; text-wrap: balance; }
        .hm-reach-body { position: relative; z-index: 1; font-size: 16.5px; line-height: 1.7; color: rgba(255,243,228,0.7); margin: 60px auto 0; max-width: 36em; text-wrap: pretty; }
        .hm-reach-pillrow { position: relative; z-index: 1; margin-top: 24px; }
        .hm-reach-card { position: relative; z-index: 1; margin: 44px auto 0; width: min(640px, 100%); box-sizing: border-box; padding: 26px 30px 28px; border-radius: 20px; background: rgba(28,21,17,0.66); border: 1px solid rgba(255,244,230,0.18); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); box-shadow: 0 30px 70px -30px rgba(20,10,5,0.8); text-align: left; }
        .hm-reach-quote { margin: 0 0 4px; font-family: ${HEAD_FONT}; font-size: 19px; line-height: 1.42; font-weight: 400; letter-spacing: -0.015em; color: #FFF9F0; }

        /* 390px re-composition (not a shrink): hands become a 220px band under
           the eyebrow, headline left-aligned below it (text never over art, so
           no scrim), x-grid only inside the band, two corner marks. */
        @media (max-width: 760px) {
          .hm-reach { padding: 40px 24px 48px; --fs-drift-px: ${HAND_DRIFT_PX_MOBILE}px; }
          .hm-reach-inner { text-align: left; }
          .hm-reach-xgrid { display: none; }
          .hm-reach-plus-tr, .hm-reach-plus-bl { display: none; }
          .hm-reach-plus-tl { left: 12px !important; top: 12px !important; }
          .hm-reach-plus-br { right: 12px !important; bottom: 12px !important; }
          .hm-reach-stage { margin-top: 0; font-size: 40px; }
          .hm-reach-hands { position: relative; inset: auto; height: 220px; margin: 0 -24px 26px; overflow: hidden; }
          .hm-reach-bandgrid { display: block; position: absolute; inset: 0; opacity: 0.14; background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='96' height='96'><text x='48' y='49.7' font-size='8' text-anchor='middle' fill='%23FFF4E6' font-family='sans-serif'>x</text></svg>"); }
          .hm-reach-bloom { top: 50%; width: 360px; height: 360px; background: radial-gradient(circle, rgba(224,154,48,0.34), transparent 60%); }
          .hm-reach-hand { opacity: 0.7; }
          .hm-reach { --hm-reach-travel: 200px; }
          .hm-reach-hand-l { top: 50px; right: calc(50% + 14px); width: 360px; }
          .hm-reach-hand-r { top: 56px; left: calc(50% + 9px); width: 330px; }
          .hm-reach-scrim { display: none; }
          .hm-reach-bandfade { display: block; position: absolute; left: 0; right: 0; bottom: 0; height: 24px; background: linear-gradient(to bottom, transparent, ${INK}); }
          .hm-reach-h2 { margin: 0; max-width: none; }
          .hm-reach-body { font-size: 16px; margin: 34px 0 0; max-width: none; }
          .hm-reach-pillrow { margin-top: 22px; }
          .hm-reach-card { margin: 34px 0 0; width: auto; padding: 26px 22px 28px; }
          .hm-reach-quote { font-size: 18px; line-height: 1.45; }
        }

        .hm-nav-link { color: rgba(255,248,238,0.82); }
        .hm-nav-link:hover { color: #FFF8EE; }
        .hm-btn-primary:hover { background: ${AMBER_LIGHT} !important; }
        .hm-btn-outline:hover { border-color: #FFF8EE !important; background: rgba(255,244,230,0.12) !important; }
        .hm-footer-link { color: ${LIGHT_INK}; }
        .hm-footer-link:hover { color: #B4712C; }

        .hm-hero-grid { display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(0, 0.85fr); gap: clamp(24px, 5vw, 72px); align-items: center; }
        .hm-hero-cards { display: flex; flex-direction: column; align-items: flex-end; gap: 22px; }
        @media (max-width: 860px) {
          .hm-hero-grid  { grid-template-columns: 1fr; }
          .hm-hero-cards { display: none; }
        }
      `}</style>

      {/* ══ Hero ══ */}
      <section style={{ position: 'relative', minHeight: '100vh', overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
        <Blobs innerRef={heroBgRef} overlay="linear-gradient(180deg, rgba(23,18,15,0.55) 0%, rgba(23,18,15,0.15) 35%, rgba(23,18,15,0.45) 78%, #17120F 100%)" />

        <header style={{ position: 'relative', zIndex: 3, display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 24, padding: '26px clamp(20px, 5vw, 64px)' }}>
          <Link to="/" style={{ fontFamily: HEAD_FONT, fontSize: 19, fontWeight: 600, letterSpacing: '-0.01em', color: '#FFF8EE', textDecoration: 'none' }}>
            FellowScript
          </Link>
          <nav style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 4, padding: 5, borderRadius: 999, background: 'rgba(23,18,15,0.28)', border: '1px solid rgba(255,244,230,0.16)', backdropFilter: 'blur(10px)' }}>
              <Link to="/" style={{ display: 'block', padding: '8px 16px', borderRadius: 999, fontSize: 12.5, letterSpacing: '0.08em', textTransform: 'uppercase', color: '#FFF8EE', background: 'rgba(255,244,230,0.14)', textDecoration: 'none' }}>Home</Link>
              {/* Task 20260922-reader-nav-download-page: routes to the new
                  /download page, which now owns the device branching itself
                  — matches the adjacent Home/Account links' <Link> usage
                  instead of being the odd one out as a plain <a>. */}
              <Link to="/download" className="hm-nav-link" style={{ display: 'block', padding: '8px 16px', borderRadius: 999, fontSize: 12.5, letterSpacing: '0.08em', textTransform: 'uppercase', textDecoration: 'none' }}>Read</Link>
              {exploreOn && (
                <Link to="/explore" className="hm-nav-link" style={{ display: 'block', padding: '8px 16px', borderRadius: 999, fontSize: 12.5, letterSpacing: '0.08em', textTransform: 'uppercase', textDecoration: 'none' }}>Explore</Link>
              )}
              {user && (
                <Link to="/account" className="hm-nav-link" style={{ display: 'block', padding: '8px 16px', borderRadius: 999, fontSize: 12.5, letterSpacing: '0.08em', textTransform: 'uppercase', textDecoration: 'none' }}>Account</Link>
              )}
            </div>
          </nav>
        </header>

        <div className="hm-hero-grid" style={{ position: 'relative', zIndex: 2, flex: 1, maxWidth: 1400, margin: '0 auto', width: '100%', padding: 'clamp(40px, 6vh, 90px) clamp(20px, 5vw, 64px) clamp(28px, 5vh, 64px)' }}>
          <div style={{ maxWidth: 760 }}>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 9, padding: '7px 15px 7px 12px', borderRadius: 999, background: 'rgba(23,18,15,0.4)', border: '1px solid rgba(255,244,230,0.2)', backdropFilter: 'blur(8px)', marginBottom: 34 }}>
              <span style={{ width: 7, height: 7, borderRadius: '50%', background: AMBER, boxShadow: '0 0 10px 2px rgba(232,163,85,0.7)' }} />
              <span style={{ fontSize: 12, letterSpacing: '0.04em', color: '#FFF3E2' }}>Now with scheduled devotions</span>
            </div>
            <div style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.28em', textTransform: 'uppercase', color: '#F0C08A', marginBottom: 22 }}>// FELLOWSCRIPT</div>
            <h1 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(44px, 6.4vw, 104px)', lineHeight: 0.96, fontWeight: 400, letterSpacing: '-0.035em', color: '#FFF9F0', margin: '0 0 28px', textWrap: 'balance' }}>
              Lead with confidence, <span style={{ color: 'rgba(255,249,240,0.62)' }}>gather in power.</span>
            </h1>
            <p style={{ fontSize: 'clamp(15px, 1.25vw, 19px)', lineHeight: 1.6, color: 'rgba(255,243,228,0.86)', maxWidth: '30em', margin: '0 0 40px' }}>
              A friendly AI companion, a daily rhythm, and people who show up with you — every single day.
            </p>
            <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 14 }}>
              <PillButton to={cta} primary>Begin your journey <span aria-hidden="true">→</span></PillButton>
              {/* Task 20260922-reader-nav-download-page: was an unconditional
                  /reader link with no device branching — a leaking-nav
                  occurrence under this task's "every occurrence" framing,
                  not a legitimate carve-out (design-notes.md §4). */}
              <PillButton to="/download">Read scripture</PillButton>
            </div>
          </div>

          <div className="hm-hero-cards">
            <div className="hm-float" style={{ width: 'min(400px, 100%)', padding: '26px 28px 28px', borderRadius: 20, background: 'rgba(28,21,17,0.66)', border: '1px solid rgba(255,244,230,0.18)', backdropFilter: 'blur(18px)', boxShadow: '0 30px 70px -30px rgba(20,10,5,0.8)', animation: 'hm-float 9s ease-in-out infinite' }}>
              <div style={{ fontFamily: HEAD_FONT, fontSize: 11, letterSpacing: '0.22em', textTransform: 'uppercase', color: '#F0C08A', marginBottom: 18 }}>// TODAY'S VERSE</div>
              <p style={{ fontFamily: HEAD_FONT, fontSize: 21, lineHeight: 1.42, fontWeight: 400, letterSpacing: '-0.015em', color: '#FFF9F0', margin: '0 0 16px' }}>
                "Be still, and know that I am God."
              </p>
              <div style={{ fontSize: 12.5, letterSpacing: '0.06em', color: 'rgba(255,243,228,0.6)' }}>PSALM 46:10</div>
            </div>
            <div style={{ width: 'min(330px, 100%)', display: 'flex', alignItems: 'center', gap: 13, padding: '15px 18px', borderRadius: 16, background: 'rgba(28,21,17,0.7)', border: '1px solid rgba(255,244,230,0.16)', backdropFilter: 'blur(18px)', boxShadow: '0 24px 56px -28px rgba(20,10,5,0.8)', animation: 'hm-float 11s ease-in-out 1.2s infinite' }}>
              <span style={{ display: 'grid', placeItems: 'center', width: 36, height: 36, borderRadius: '50%', background: AMBER, color: '#21160F', fontSize: 14, fontWeight: 600, flexShrink: 0 }}>J</span>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 3, minWidth: 0 }}>
                <span style={{ fontSize: 14, color: '#FFF9F0' }}>Jacey checked in</span>
                <span style={{ fontSize: 12, color: 'rgba(255,243,228,0.55)' }}>2 min ago</span>
              </div>
            </div>
          </div>
        </div>

        <div style={{ position: 'relative', zIndex: 2, display: 'flex', alignItems: 'center', gap: 18, padding: '0 clamp(20px, 5vw, 64px) clamp(32px, 5vh, 56px)' }}>
          <div style={{ position: 'relative', width: 62, height: 62, borderRadius: '50%', border: '1px solid rgba(255,244,230,0.45)', flexShrink: 0 }}>
            <div className="hm-orbit-spin" style={{ position: 'absolute', inset: 0, animation: 'hm-orbit 5.5s linear infinite' }}>
              <span style={{ position: 'absolute', top: 5, left: '50%', width: 5, height: 5, marginLeft: -2.5, borderRadius: '50%', background: '#FFF8EE' }} />
              <span style={{ position: 'absolute', bottom: 12, left: '30%', width: 3, height: 3, borderRadius: '50%', background: 'rgba(255,248,238,0.7)' }} />
            </div>
          </div>
          <span style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.24em', textTransform: 'uppercase', color: 'rgba(255,248,238,0.8)' }}>Learn more</span>
        </div>
      </section>

      {/* ══ Not just once a week (task 20260921-homepage-family-section-redesign) ══
          Replaces the old generic "A little bit of grace, every single day."
          steps grid with the founder's actual framing: family under Christ
          shows up daily, not just on Sunday, and FellowScript exists to make
          room for that. Purpose-built layout (not a text swap) — see
          design-notes.md for the full synthesis of the three visual
          references and the conflicts/resolutions between them. */}
      <section ref={familyRef} className="hm-reach">
        {/* Decorative layers (all aria-hidden, no focusable content). If the
            hand images fail to load they hide themselves and the x-grid, bloom
            and all text stay intact. */}
        <span aria-hidden="true" className="hm-reach-xgrid" />
        <span aria-hidden="true" className="hm-reach-grain" />
        <span aria-hidden="true" className="hm-reach-plus hm-reach-plus-tl" style={{ left: 24, top: 24 }} />
        <span aria-hidden="true" className="hm-reach-plus hm-reach-plus-tr" style={{ right: 24, top: 24 }} />
        <span aria-hidden="true" className="hm-reach-plus hm-reach-plus-bl" style={{ left: 24, bottom: 24 }} />
        <span aria-hidden="true" className="hm-reach-plus hm-reach-plus-br" style={{ right: 24, bottom: 24 }} />

        <div className="hm-reach-inner">
          <div className="hm-family-reveal hm-reach-eyebrow">// NOT JUST ONCE A WEEK</div>

          <div className="hm-family-reveal hm-reach-stage">
            {/* Task 20261008-homepage-reaching-section: halftone hands reaching
                toward the circled word (Variant 1 "Reaching"). Cream hand left,
                amber hand right; purely decorative, so alt="" + aria-hidden. */}
            <span aria-hidden="true" className="hm-reach-hands">
              <span className="hm-reach-bandgrid" />
              <span className="hm-reach-bloom" />
              <img className="hm-reach-hand hm-reach-hand-l" src={handLeftCream} width="900" height="387" alt="" aria-hidden="true" decoding="async" onError={(e) => { e.currentTarget.style.display = 'none'; }} />
              <img className="hm-reach-hand hm-reach-hand-r" src={handRightAmber} width="760" height="345" alt="" aria-hidden="true" decoding="async" onError={(e) => { e.currentTarget.style.display = 'none'; }} />
              <span className="hm-reach-scrim" />
              <span className="hm-reach-bandfade" />
            </span>
            <h2 className="hm-reach-h2">
              Everyone gathered under Christ is called to live as{' '}
              <span style={{ position: 'relative', display: 'inline-block' }}>
                family
                <HandDrawnCircle className="hm-reach-circle" style={{ left: '50%', top: '50%', transform: 'translate(-50%, -50%)', width: 400, maxWidth: 'calc(100vw - 48px)', height: 'auto' }} />
              </span>.
            </h2>
          </div>

          <p className="hm-family-reveal hm-reach-body" style={{ transitionDelay: '90ms' }}>
            Brothers and sisters don't show up for each other once a week — they show up every day in between. That daily rhythm, not the Sunday appointment, is the actual point. FellowScript exists to make room for it.
          </p>

          <div className="hm-reach-pillrow">
            <div className="hm-family-reveal" style={{ transitionDelay: '160ms', display: 'inline-flex', alignItems: 'center', gap: 9, padding: '7px 15px 7px 12px', borderRadius: 999, background: 'rgba(232,163,85,0.12)', border: '1px solid rgba(232,163,85,0.32)' }}>
              <span aria-hidden="true" style={{ width: 7, height: 7, borderRadius: '50%', background: AMBER }} />
              <span style={{ fontSize: 12, letterSpacing: '0.04em', color: '#FFF3E2' }}>Every day — not just Sunday</span>
            </div>
          </div>

          {/* Founder's-note card — same glass treatment as the hero verse card.
              Anonymous (no name/initial attribution), per the earlier approval. */}
          <div className="hm-family-reveal hm-reach-card" style={{ transitionDelay: '220ms' }}>
            <div style={{ fontFamily: HEAD_FONT, fontSize: 11, letterSpacing: '0.22em', textTransform: 'uppercase', color: '#F0C08A', marginBottom: 16 }}>// WHY WE BUILT THIS</div>
            <div style={{ marginBottom: 6 }}>
              <HandDrawnQuoteMark size={42} />
            </div>
            <blockquote className="hm-reach-quote">
              "I didn't build this to replace church. I built it because family doesn't clock out — I wanted somewhere for us to keep{' '}
              <span style={{ position: 'relative', display: 'inline-block' }}>
                showing up for each other
                <HandDrawnUnderline style={{ left: '-2%', bottom: '-14%', width: '104%', height: '30%' }} />
              </span>, every day of the week."
            </blockquote>
          </div>
        </div>
      </section>

      {/* Task 20261001-explorer-listings step 9: shown only after the runtime
          probe succeeds, so the prerendered Home is unchanged. */}
      {exploreOn && (
        <section style={{ padding: 'clamp(48px, 7vh, 90px) clamp(20px, 5vw, 64px)', background: INK }}>
          <div style={{ maxWidth: 1240, margin: '0 auto', display: 'flex', flexWrap: 'wrap', alignItems: 'center', justifyContent: 'space-between', gap: 24, paddingTop: 36, borderTop: '1px solid rgba(255,244,230,0.14)' }}>
            <h2 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(26px, 3.2vw, 44px)', lineHeight: 1.08, fontWeight: 400, letterSpacing: '-0.03em', margin: 0, color: '#FFF9F0', maxWidth: '22em' }}>
              Find a group near your faith and season of life.
            </h2>
            <PillButton to="/explore" primary>Browse groups</PillButton>
          </div>
        </section>
      )}

      {/* ══ The problem (task 20261008-homepage-problem-carousel) ══ */}
      <section style={{ padding: 'clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)', background: LIGHT_BG, color: LIGHT_INK }}>
        <div style={{ maxWidth: 1240, margin: '0 auto' }}>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: '#B4712C', paddingBottom: 22, borderBottom: '1px solid rgba(26,21,18,0.14)', marginBottom: 56 }}>// THE PROBLEM</div>
          <h2 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(34px, 5vw, 74px)', lineHeight: 1.02, fontWeight: 400, letterSpacing: '-0.03em', margin: '0 0 clamp(24px, 4vh, 64px)', maxWidth: '22em', color: LIGHT_INK }}>
            What gets in the way <span style={{ color: 'rgba(26,21,18,0.38)' }}>of growing together.</span>
          </h2>
          <ProblemCarousel slides={problemSlides} />
        </div>
      </section>

      {/* ══ Built for community ══ */}
      <section style={{ position: 'relative', overflow: 'hidden', padding: 'clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)', background: INK }}>
        <Blobs innerRef={communityBgRef} overlay="linear-gradient(180deg, #17120F 0%, rgba(23,18,15,0.42) 22%, rgba(23,18,15,0.5) 72%, #17120F 100%)" />
        <div style={{ position: 'relative', zIndex: 1, maxWidth: 1240, margin: '0 auto' }}>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: AMBER, paddingBottom: 22, borderBottom: '1px solid rgba(255,244,230,0.14)', marginBottom: 56 }}>// BUILT FOR COMMUNITY</div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))', gap: 'clamp(40px, 6vw, 90px)', alignItems: 'start' }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 34 }}>
              <h2 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(32px, 4.2vw, 62px)', lineHeight: 1.03, fontWeight: 400, letterSpacing: '-0.03em', margin: 0, color: '#FFF9F0' }}>
                Study together, <span style={{ color: 'rgba(255,249,240,0.42)' }}>wherever you are.</span>
              </h2>
              <p style={{ fontSize: 16.5, lineHeight: 1.7, color: 'rgba(255,243,228,0.66)', margin: 0, maxWidth: '34em' }}>
                The group plan gives up to eight people a shared space to read, highlight, and grow — with real-time messaging and a live study feed of what everyone's been marking.
              </p>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 15 }}>
                {communityPerks.map(perk => (
                  <div key={perk} style={{ display: 'flex', alignItems: 'flex-start', gap: 13 }}>
                    <Check />
                    <span style={{ fontSize: 15.5, lineHeight: 1.55, color: 'rgba(255,243,228,0.86)' }}>{perk}</span>
                  </div>
                ))}
              </div>
              <PillButton to={cta} primary>Start a group <span aria-hidden="true">→</span></PillButton>
            </div>

            <div style={{ border: '1px solid rgba(255,244,230,0.16)', borderRadius: 22, background: '#1F1815', overflow: 'hidden', boxShadow: '0 40px 90px -50px rgba(0,0,0,0.9)' }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 16, padding: '20px 24px', borderBottom: '1px solid rgba(255,244,230,0.12)' }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <span style={{ fontFamily: HEAD_FONT, fontSize: 16, fontWeight: 500, color: '#FFF9F0' }}>Morning Study — Romans 8</span>
                  <span style={{ fontSize: 12, color: 'rgba(255,243,228,0.5)' }}>3 of 8 members reading now</span>
                </div>
                <span style={{ width: 8, height: 8, borderRadius: '50%', background: '#7FC08A', boxShadow: '0 0 10px 2px rgba(127,192,138,0.5)', flexShrink: 0 }} />
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: 24 }}>
                {chatMock.map(({ name, msg, time, avatar, reaction }) => (
                  <div key={name} style={{ display: 'flex', gap: 12 }}>
                    <span style={{ display: 'grid', placeItems: 'center', width: 32, height: 32, borderRadius: '50%', background: avatar === 'J' ? AMBER : 'rgba(255,244,230,0.16)', color: avatar === 'J' ? '#21160F' : '#FFF9F0', fontSize: 13, fontWeight: 600, flexShrink: 0 }}>{avatar}</span>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 7, minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'baseline', gap: 9 }}>
                        <span style={{ fontSize: 13.5, fontWeight: 600, color: '#FFF9F0' }}>{name}</span>
                        <span style={{ fontSize: 11.5, color: 'rgba(255,243,228,0.45)' }}>{time}</span>
                      </div>
                      <div style={{ padding: '13px 16px', borderRadius: '4px 14px 14px 14px', background: 'rgba(255,244,230,0.07)', border: '1px solid rgba(255,244,230,0.1)', fontSize: 14.5, lineHeight: 1.6, color: 'rgba(255,243,228,0.88)' }}>{msg}</div>
                      {reaction && (
                        <div style={{ display: 'flex', gap: 6 }}>
                          <span style={{ padding: '3px 9px', borderRadius: 999, background: 'rgba(232,163,85,0.14)', border: '1px solid rgba(232,163,85,0.28)', fontSize: 11.5, color: 'rgba(255,243,228,0.8)' }}>{reaction}</span>
                        </div>
                      )}
                    </div>
                  </div>
                ))}
              </div>
              <div style={{ padding: '14px 24px 20px', borderTop: '1px solid rgba(255,244,230,0.1)', fontSize: 12.5, letterSpacing: '0.04em', color: 'rgba(255,243,228,0.45)' }}>Jacey highlighted Romans 8:28 · just now</div>
            </div>
          </div>
        </div>
      </section>

      {/* ══ Pricing ══ */}
      <section style={{ padding: 'clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)', background: LIGHT_BG, color: LIGHT_INK }}>
        <div style={{ maxWidth: 1240, margin: '0 auto' }}>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: '#B4712C', paddingBottom: 22, borderBottom: '1px solid rgba(26,21,18,0.14)', marginBottom: 56 }}>// SIMPLE PRICING</div>
          <h2 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(34px, 5vw, 74px)', lineHeight: 1.02, fontWeight: 400, letterSpacing: '-0.03em', margin: '0 0 24px', maxWidth: '20em', color: LIGHT_INK }}>
            Start free. <span style={{ color: 'rgba(26,21,18,0.38)' }}>Grow at your own pace.</span>
          </h2>
          <p style={{ fontSize: 16.5, lineHeight: 1.65, color: 'rgba(26,21,18,0.6)', margin: '0 0 clamp(48px, 7vh, 88px)', maxWidth: '32em' }}>The free plan needs no card. Paid plans are billed monthly and you can cancel any time.</p>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 'clamp(20px, 2.4vw, 32px)', alignItems: 'stretch' }}>
            {plans.map(({ name, price, sub, perks, cta: planCta, href, primary }) => (
              <div key={name} style={primary
                ? { position: 'relative', display: 'flex', flexDirection: 'column', gap: 26, padding: '38px 34px 40px', border: '1px solid rgba(26,21,18,0.9)', borderRadius: 20, background: LIGHT_INK, color: '#FFF9F0' }
                : { display: 'flex', flexDirection: 'column', gap: 26, padding: '38px 34px 40px', border: '1px solid rgba(26,21,18,0.14)', borderRadius: 20, background: '#FFFDFA' }
              }>
                {primary && (
                  <span style={{ position: 'absolute', top: 22, right: 26, padding: '6px 12px', borderRadius: 999, background: AMBER, color: '#21160F', fontSize: 10.5, fontWeight: 600, letterSpacing: '0.14em', textTransform: 'uppercase' }}>Most popular</span>
                )}
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  <span style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.2em', textTransform: 'uppercase', color: primary ? '#F0C08A' : 'rgba(26,21,18,0.55)' }}>{name}</span>
                  <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ fontFamily: HEAD_FONT, fontSize: 52, fontWeight: 400, letterSpacing: '-0.04em', color: primary ? '#FFF9F0' : LIGHT_INK }}>{price}</span>
                    {price !== '$0' && <span style={{ fontSize: 15, color: primary ? 'rgba(255,243,228,0.6)' : 'rgba(26,21,18,0.5)' }}>/mo</span>}
                  </div>
                  <span style={{ fontSize: 14, color: primary ? 'rgba(255,243,228,0.6)' : 'rgba(26,21,18,0.5)' }}>{sub}</span>
                </div>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12, fontSize: 15, lineHeight: 1.5, color: primary ? 'rgba(255,243,228,0.82)' : 'rgba(26,21,18,0.72)', flex: 1 }}>
                  {perks.map(perk => <span key={perk}>{perk}</span>)}
                </div>
                <Link
                  to={user ? '/account' : href}
                  style={primary
                    ? { display: 'inline-flex', alignItems: 'center', justifyContent: 'center', marginTop: 'auto', padding: '16px 24px', borderRadius: 999, background: AMBER, color: '#21160F', fontSize: 14.5, fontWeight: 600 }
                    : { display: 'inline-flex', alignItems: 'center', justifyContent: 'center', marginTop: 'auto', padding: '16px 24px', borderRadius: 999, border: '1px solid rgba(26,21,18,0.28)', color: LIGHT_INK, fontSize: 14.5, fontWeight: 600 }
                  }
                >
                  {planCta}
                </Link>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ══ Closing CTA ══ */}
      <section style={{ position: 'relative', overflow: 'hidden', padding: 'clamp(90px, 15vh, 190px) clamp(20px, 5vw, 64px)', background: INK }}>
        <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
          <div style={{ position: 'absolute', width: '60vw', height: '60vw', minWidth: 480, minHeight: 480, left: '50%', top: '20%', transform: 'translateX(-50%)', borderRadius: '50%', background: 'radial-gradient(circle at 45% 40%, rgba(240,179,106,0.4) 0%, rgba(164,74,45,0.28) 42%, rgba(23,18,15,0) 74%)', filter: 'blur(10px)' }} />
        </div>
        <div style={{ position: 'relative', maxWidth: 1000, margin: '0 auto', textAlign: 'center', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 40 }}>
          <blockquote style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(30px, 4.2vw, 62px)', lineHeight: 1.08, fontWeight: 400, letterSpacing: '-0.03em', color: '#FFF9F0', margin: 0, textWrap: 'balance' }}>
            "As iron sharpens iron, <span style={{ color: 'rgba(255,249,240,0.45)' }}>so one person sharpens another."</span>
          </blockquote>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.24em', textTransform: 'uppercase', color: '#F0C08A' }}>Proverbs 27:17</div>
          <div style={{ display: 'flex', flexWrap: 'wrap', justifyContent: 'center', gap: 14 }}>
            <PillButton to={cta} primary>Join free <span aria-hidden="true">→</span></PillButton>
            {/* Task 20260922-reader-nav-download-page: same rationale as the
                hero's "Read scripture" button above — was an unconditional
                /reader link with no device branching (design-notes.md §4). */}
            <PillButton to="/download">Read the Bible</PillButton>
          </div>
        </div>
      </section>

      {/* ══ Footer ══ */}
      <footer style={{ padding: 'clamp(60px, 9vh, 110px) clamp(20px, 5vw, 64px) 44px', background: LIGHT_BG, color: LIGHT_INK }}>
        <div style={{ maxWidth: 1240, margin: '0 auto', display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 'clamp(36px, 5vw, 72px)' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: '#B4712C' }}>// FELLOWSCRIPT</div>
            <div style={{ fontFamily: HEAD_FONT, fontSize: 26, fontWeight: 500, letterSpacing: '-0.025em', color: LIGHT_INK }}>Walk with God, together.</div>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
            <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: '#B4712C' }}>// NAVIGATION</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 11 }}>
              <Link to="/" className="hm-footer-link" style={{ fontSize: 15.5, textDecoration: 'none' }}>Home</Link>
              <Link to="/download" className="hm-footer-link" style={{ fontSize: 15.5, textDecoration: 'none' }}>Read</Link>
              {/* Task 20260930-downloads-page-indexable: plain <a> to the real,
                  prerendered, crawlable downloads URL (a HashRouter <Link>
                  only yields "#/download", which crawlers cannot follow). */}
              <a href="/download/" className="hm-footer-link" style={{ fontSize: 15.5, textDecoration: 'none' }}>Download</a>
              {exploreOn && <Link to="/explore" className="hm-footer-link" style={{ fontSize: 15.5, textDecoration: 'none' }}>Explore</Link>}
              {user && <Link to="/account" className="hm-footer-link" style={{ fontSize: 15.5, textDecoration: 'none' }}>Account</Link>}
            </div>
          </div>
        </div>
        <div style={{ maxWidth: 1240, margin: 'clamp(48px, 7vh, 90px) auto 0', paddingTop: 22, borderTop: '1px solid rgba(26,21,18,0.14)', display: 'flex', flexWrap: 'wrap', gap: 12, justifyContent: 'space-between', fontSize: 12.5, color: 'rgba(26,21,18,0.5)' }}>
          <span>© 2026 FellowScript</span>
          <span>Made for daily rhythm.</span>
        </div>
      </footer>
    </div>
  );
}
