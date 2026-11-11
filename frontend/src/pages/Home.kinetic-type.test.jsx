// Task 20261111-kinetic-type-marble, testing gate: the .hm-fam head (eyebrow + h2) with scroll-driven kinetic typography
// over the pinned marble. Proves: the static HTML (SSR / prerender / no JS) carries the full text with no hidden start state;
// reduced motion attaches nothing; the pinned mode writes the kinetic maths per scroll frame and is reversible; phones get
// opacity + translateY only; landscape phones get the stacked one-shot fade-up; no honey strip; no verse symbols remain.
//
// Run with: cd frontend && npx vitest run src/pages/Home.kinetic-type.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, cleanup, act } from '@testing-library/react';
import { renderToStaticMarkup, renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';
import { KINETIC_UNITS, STAGGER, unitCss, circleP } from '../lib/kineticType.js';
import { KINETIC_SPAN_VH } from '../lib/adamHands/driver.js';
import { LIGHT_BG, FIELD_UNDER } from '../lib/adamHands/field.js';
import { LIQUID_CSS } from '../components/LiquidField.jsx';
import { ADAM_CSS } from '../components/AdamHands.jsx';

vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => ({ user: null }) }));

afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

const EYEBROW = '// NOT JUST ONCE A WEEK';
const SENTENCE = 'Everyone gathered under Christ is called to live as family.';

function mm({ reduce = false, mobile = false, stack = false } = {}) {
  window.matchMedia = vi.fn().mockImplementation((q) => ({
    matches: (reduce && q.includes('prefers-reduced-motion')) || (mobile && q.includes('max-width')) || (stack && q.includes('max-height: 520px')),
    media: q, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  }));
}
const home = () => <MemoryRouter initialEntries={['/']}><Home /></MemoryRouter>;
const flushMO = () => act(async () => { await Promise.resolve(); });

// Controllable scroll for the kinetic scene: one queue for every requestAnimationFrame (hero scrub, marble, kinetic).
function setup(opts) {
  mm(opts);
  const rafQ = [];
  vi.stubGlobal('requestAnimationFrame', (cb) => { rafQ.push(cb); return rafQ.length; });
  vi.stubGlobal('cancelAnimationFrame', () => {});
  const r = render(home());
  const section = r.container.querySelector('section.hm-fam');
  const scene = section.querySelector('.hm-fam-scene');
  const head = scene.querySelector('.hm-fam-head');
  const VH = 900; const sceneH = (100 + KINETIC_SPAN_VH) / 100 * VH; // 2700
  Object.defineProperty(scene, 'offsetHeight', { configurable: true, value: sceneH });
  Object.defineProperty(head, 'offsetHeight', { configurable: true, value: VH });
  let top = 0;
  scene.getBoundingClientRect = () => ({ top, height: sceneH, bottom: top + sceneH, left: 0, right: 0, width: 0, x: 0, y: top });
  const toQ = (q) => { top = -q * (sceneH - VH); act(() => { document.dispatchEvent(new Event('scroll')); for (let i = 0; i < 90; i++) rafQ.splice(0).forEach((cb) => cb(i * 100 + 100)); }); };
  return { ...r, section, scene, head, toQ };
}
const num = (v) => parseFloat(v); // jsdom serialises '1.000' as '1'
const units = (section) => Array.from(section.querySelectorAll('[data-k]'));

describe('static HTML (SSR / prerender / no JS): full text, no hidden start state', () => {
  const html = renderToStaticMarkup(home());
  const body = html.replace(/<style>[\s\S]*?<\/style>/g, '');
  const dom = document.createElement('div'); dom.innerHTML = body;
  const section = dom.querySelector('section.hm-fam');

  test('the eyebrow and the h2 sentence are real, readable text in the markup', () => {
    expect(section.querySelector('.hm-fam-eyebrow').textContent).toBe(EYEBROW);
    expect(section.querySelector('h2').textContent).toBe(SENTENCE);
    expect(renderToString(home())).toContain('NOT JUST ONCE A WEEK');
  });
  test('eleven kinetic units (eyebrow + ten word spans), real spaces between the words, no per-letter split, nothing aria-hidden', () => {
    const k = [...section.querySelectorAll('[data-k]')];
    expect(k.length).toBe(KINETIC_UNITS);
    expect(k.map((el) => el.getAttribute('data-k'))).toEqual(['eyebrow', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10']);
    const words = [...section.querySelectorAll('h2 .kw')];
    expect(words.length).toBe(10);
    expect(words.map((w) => w.textContent.replace('.', ''))).toEqual(['Everyone', 'gathered', 'under', 'Christ', 'is', 'called', 'to', 'live', 'as', 'family']);
    words.slice(0, -1).forEach((w) => expect(w.nextSibling && w.nextSibling.textContent).toBe(' '));
    expect(section.querySelector('h2').innerHTML).not.toMatch(/<span[^>]*>[A-Za-z]<\/span>/); // no single-letter spans
    k.forEach((el) => { expect(el.getAttribute('aria-hidden')).toBeNull(); expect(el.closest('[aria-hidden="true"]')).toBeNull(); });
  });
  test('no start-state styles in the static markup: no inline opacity/transform/filter on any unit, no data-kinetic', () => {
    expect(section.hasAttribute('data-kinetic')).toBe(false);
    section.querySelectorAll('[data-k]').forEach((el) => expect(el.getAttribute('style')).toBeNull());
    expect(body).not.toMatch(/data-kinetic/);
  });
  test('the rest of the copy (body, pill, card) is still in the static markup, in the cream rest block', () => {
    const rest = section.querySelector(':scope > .hm-fam-rest');
    expect(rest.textContent).toContain('Every day — not just Sunday');
    expect(rest.textContent).toContain('// WHAT FELLOWSCRIPT PROVIDES');
  });
});

describe('reduced motion', () => {
  test('nothing is attached: no data-kinetic, no inline styles on the units, no kinetic scroll work', async () => {
    mm({ reduce: true });
    const add = vi.spyOn(document, 'addEventListener');
    const { container } = render(home());
    await flushMO();
    const section = container.querySelector('section.hm-fam');
    expect(section.hasAttribute('data-kinetic')).toBe(false);
    units(section).forEach((el) => expect(el.getAttribute('style')).toBeNull());
    expect(add.mock.calls.filter(([t, , o]) => t === 'scroll' && o && o.capture).length).toBe(0);
    expect(section.querySelector('h2').textContent).toBe(SENTENCE);
  });
  test('CSS backstop forces the final static type and a drawn circle whatever JS did', () => {
    mm({ reduce: true });
    const { container } = render(home());
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    expect(css).toMatch(/@media \(prefers-reduced-motion: reduce\) \{[\s\S]*\.hm-fam \.kw, \.hm-fam-eyebrow \{ opacity: 1 !important; transform: none !important; filter: none !important; text-shadow: none !important; transition: none !important; \}/);
    expect(css).toMatch(/\.hm-fam-head \.hm-draw-path \{ stroke-dashoffset: 0 !important; \}/);
    expect(css).toMatch(/\.hm-fam-eyebrow::after \{ clip-path: none !important; \}/);
    // the animated start states (stack fade-up) only exist outside reduced motion
    const stack = css.match(/@media not \(prefers-reduced-motion: reduce\) \{[^@]*\.hm-fam\[data-kinetic="stack"\][\s\S]*?\n        \}/);
    expect(stack).toBeTruthy();
    expect(css.replace(stack[0], '')).not.toMatch(/\.hm-fam\[data-kinetic="stack"\] \.kw[^{]*\{[^}]*opacity: 0/);
  });
});

describe('pinned (desktop) kinetic mode: scroll-driven, reversible', () => {
  test('goes data-kinetic="on" once the stage is live, and paints the q = 0 start state before any scroll (no flash of the final type)', async () => {
    const { section } = setup();
    await flushMO();
    expect(section.getAttribute('data-kinetic')).toBe('on');
    units(section).forEach((el) => { expect(el.style.opacity).toBe('0'); });
    expect(num(section.querySelector('.hm-fam-head').style.getPropertyValue('--k-scrim'))).toBe(0);
  });
  test('scrolling the scene to q = 1 lands every unit on the final pose and draws the circle; scrolling back restores the start state', async () => {
    const { section, head, toQ } = setup();
    await flushMO();
    toQ(1);
    units(section).forEach((el) => {
      expect(num(el.style.opacity)).toBe(1); expect(el.style.transform).toBe('none'); expect(el.style.filter).toBe('none'); expect(el.style.textShadow).toBe('none');
    });
    expect(num(section.querySelector('[data-k="10"]').style.getPropertyValue('--k-circle'))).toBe(1);
    expect(num(section.querySelector('[data-k="eyebrow"]').style.getPropertyValue('--fs-thread'))).toBe(1);
    expect(num(head.style.getPropertyValue('--k-scrim'))).toBe(1);
    toQ(0);
    units(section).forEach((el) => expect(el.style.opacity).toBe('0'));
    expect(num(section.querySelector('[data-k="10"]').style.getPropertyValue('--k-circle'))).toBe(0);
  }, 30000);
  test('mid scroll: each unit carries exactly the values of the pure maths (unitCss) and words arrive in reading order', async () => {
    const { section, toQ } = setup();
    await flushMO();
    const q = 0.3;
    toQ(q);
    const els = units(section);
    els.forEach((el, i) => {
      const c = unitCss(i, q, false);
      expect(num(el.style.opacity)).toBe(num(c.opacity));
      expect(el.style.transform).toBe(c.transform);
      expect(el.style.filter).toBe(c.filter);
    });
    const ops = els.map((el) => parseFloat(el.style.opacity));
    for (let i = 1; i < ops.length; i++) expect(ops[i - 1]).toBeGreaterThanOrEqual(ops[i]);
    expect(ops[0]).toBe(1); expect(ops[ops.length - 1]).toBe(0); // eyebrow done, last word not started (starts at 0.44)
    expect(parseFloat(section.querySelector('[data-k="10"]').style.getPropertyValue('--k-circle'))).toBeCloseTo(circleP(q), 4);
  }, 30000);
  test('layout CSS: head is sticky 100svh over the pinned stage and the scene overlaps the pin runway by (100 + KINETIC_SPAN_VH) vh', () => {
    mm();
    const { container } = render(home());
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    expect(KINETIC_SPAN_VH).toBe(200);
    expect(css).toMatch(/\.hm-fam \{ --k-span: 200;/);
    expect(css).toMatch(/\.adam-pin\[data-live="true"\]:not\(\[data-stack="true"\]\) \+ \.hm-fam \{ margin-top: calc\(-1 \* \(100 \+ var\(--k-span\)\) \* 1vh\); \}/);
    expect(css).toMatch(/\+ \.hm-fam \.hm-fam-scene \{ min-height: 0; height: calc\(\(100 \+ var\(--k-span\)\) \* 1vh\); \}/);
    expect(css).toMatch(/\+ \.hm-fam \.hm-fam-head \{ position: sticky; top: 0; height: 100vh; height: 100svh;/);
    expect(css).toMatch(/\+ \.hm-fam \.hm-fam-backdrop \{ display: none; \}/); // the live marble is the pinned stage; the frozen backdrop is only for static modes
  });
  test('unmount cleans up: no data-kinetic and no leftover inline styles are required, and the scroll listeners are removed', async () => {
    const { section, unmount } = setup();
    await flushMO();
    const rm = vi.spyOn(document, 'removeEventListener');
    unmount();
    expect(rm.mock.calls.filter(([t, , o]) => t === 'scroll' && o && o.capture).length).toBeGreaterThanOrEqual(2);
    expect(section.hasAttribute('data-kinetic')).toBe(false);
  });
});

describe('mobile / low-power: opacity + translateY only', () => {
  test('at every sampled scroll position no unit has a blur filter, text-shadow, scale or x translate', async () => {
    const { section, toQ } = setup({ mobile: true });
    await flushMO();
    expect(section.getAttribute('data-kinetic')).toBe('on');
    for (const q of [0, 0.1, 0.2, 0.3, 0.45, 0.6, 0.8, 1]) {
      toQ(q);
      units(section).forEach((el, i) => {
        const c = unitCss(i, q, true);
        expect(el.style.filter).toBe('none');
        expect(el.style.textShadow).toBe('none');
        expect(el.style.transform === 'none' || /^translateY\(-?[\d.]+em\)$/.test(el.style.transform)).toBe(true);
        expect(num(el.style.opacity)).toBe(num(c.opacity));
        expect(el.style.transform).toBe(c.transform);
      });
    }
  }, 30000);
});

describe('landscape phone (stacked)', () => {
  test('flow layout with the one-shot staggered fade-up: data-kinetic="stack", per-unit transition delays i * STAGGER ms, "stack-in" on entry', async () => {
    const IOS = [];
    vi.stubGlobal('IntersectionObserver', function IO(fn, opts) { this.fn = fn; this.opts = opts || {}; this.observe = vi.fn(); this.unobserve = vi.fn(); this.disconnect = vi.fn(); IOS.push(this); });
    const { section, scene } = setup({ stack: true });
    await flushMO();
    expect(section.getAttribute('data-kinetic')).toBe('stack');
    units(section).forEach((el, i) => expect(el.style.transitionDelay).toBe(`${Math.round(i * STAGGER * 1000)}ms`));
    expect(units(section)[10].style.transitionDelay).toBe('400ms');
    // no scroll-scrubbed inline start state in stack mode: the hidden state comes from CSS and clears on entry
    units(section).forEach((el) => expect(el.style.opacity).toBe(''));
    const io = IOS.find((o) => o.observe.mock.calls.some(([el]) => el === scene)); // the observer watching the scene (the reveal hook watches the rest block)
    expect(io).toBeTruthy();
    expect(section.getAttribute('data-kinetic')).toBe('stack'); // not before it is on screen
    act(() => io.fn([{ isIntersecting: false, target: document.body }]));
    expect(section.getAttribute('data-kinetic')).toBe('stack');
    act(() => io.fn([{ isIntersecting: true, target: document.body }]));
    expect(section.getAttribute('data-kinetic')).toBe('stack-in');
    expect(io.disconnect).toHaveBeenCalled(); // one-shot
  });
  test('without IntersectionObserver the stack goes straight to stack-in (final type, never stuck hidden)', async () => {
    const { section } = setup({ stack: true });
    await flushMO();
    expect(section.getAttribute('data-kinetic')).toBe('stack-in');
  });
  test('the hidden start state is CSS-only and lives inside @media not (prefers-reduced-motion: reduce): opacity 0 + translateY(26px), 640ms ease', () => {
    mm({ stack: true });
    const { container } = render(home());
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    expect(css).toMatch(/\.hm-fam\[data-kinetic="stack"\] \.kw, \.hm-fam\[data-kinetic="stack"\] \.hm-fam-eyebrow \{[^}]*opacity: 0; transform: translateY\(26px\); transition: opacity 640ms/);
    expect(css).toMatch(/\.hm-fam\[data-kinetic="stack"\] \.hm-fam-head \.hm-draw-path \{ stroke-dashoffset: 1; transition: stroke-dashoffset 850ms/);
    // no sticky / pinned rule applies in stack mode (the pinned rules are scoped to :not([data-stack="true"]))
    expect(css.match(/\.adam-pin\[data-live="true"\][^{]*\+ \.hm-fam[^{]*\{/g).every((r) => r.includes(':not([data-stack="true"])'))).toBe(true);
  });
});

describe('no honey strip and no verse symbols', () => {
  const css = () => {
    mm();
    const { container } = render(home());
    return [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
  };
  test('.hm-fam has no background of its own and the stage bottom is the cream LIGHT_BG token that .hm-fam-rest starts with', () => {
    const c = css();
    expect(c.match(/\.hm-fam \{[^}]*\}/)[0]).not.toMatch(/background/);
    expect(c).not.toMatch(/\.hm-fam::before/);
    expect(c).toMatch(/\.hm-fam-rest \{[^}]*background: #FBF7F1/);
    expect(LIGHT_BG).toBe('#FBF7F1');
    // CSS marble (no GL / frozen) resolves to the same token at 100%
    expect(LIQUID_CSS).toMatch(/\.adam-resolve \{[^}]*linear-gradient\(180deg,[^}]*#FBF7F1 100%\)/);
    expect(LIQUID_CSS).toMatch(/\.adam-liquid\[data-gl="true"\] \.adam-resolve \{ display: none; \}/);
    // the dark underlay never contains a honey colour
    expect(FIELD_UNDER).not.toMatch(/EBC480/i);
    expect(c).not.toMatch(/EBC480/i);
  });
  test('no verse symbols: no VerseDescent / VerseStack / communityVerses / verseDescent module and no verse markup or CSS on the page', async () => {
    mm();
    const { container } = render(home());
    expect(container.innerHTML).not.toMatch(/verse-|VerseDescent|VerseStack|data-adam="verse/);
    expect(container.querySelector('.verse-sr, [data-testid="verse-stack"], [data-adam="verses"]')).toBeNull();
    for (const f of ['../components/VerseDescent.jsx', '../lib/verseDescent.js', '../lib/communityVerses.js']) {
      await expect(import(/* @vite-ignore */ f)).rejects.toThrow();
    }
  });
});

// Polish pass (Jacey: "polish first"): the stage's own eyebrow and the head's eyebrow carry the same words. They used to sit about
// 150-300 px apart, so the text seemed to jump at the hand-off. Pinned, the head's eyebrow now sits exactly where the stage's does.
describe('one continuous eyebrow: the head eyebrow sits where the stage eyebrow sits', () => {
  mm();
  const { container } = render(home());
  const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
  cleanup();
  const PIN = '.adam-pin[data-live="true"]:not([data-stack="true"]) + .hm-fam';
  const rule = (src, sel) => { const i = src.indexOf(`${sel} {`); return i < 0 ? '' : src.slice(i, src.indexOf('}', i)); };
  test('desktop: left 11.5% and vertical centre 11.9% of the head, the same numbers as .adam-eyebrow in the live stage; text line centred via 0.8em (line-height 1.6)', () => {
    const stage = rule(ADAM_CSS, '.adam-pin[data-live="true"] .adam-eyebrow');
    expect(stage).toMatch(/left: 11\.5cqw; top: 11\.9cqh/);
    const head = rule(css, `${PIN} .hm-fam-eyebrow`);
    expect(head).toMatch(/position: absolute; left: 11\.5%;/);
    expect(head).toMatch(/top: calc\(11\.9% - 0\.8em\)/);
    expect(head).toMatch(/margin: 0;/);
    expect(head).toMatch(/font-size: clamp\(11\.5px, 0\.8vw, 14px\)/); // the stage uses clamp(11.5px, 0.8cqw, 14px)
    expect(rule(ADAM_CSS, '.adam-eyebrow')).toMatch(/font-size: clamp\(11\.5px, 0\.8cqw, 14px\)/);
    expect(rule(ADAM_CSS, '.adam-eyebrow')).toMatch(/line-height: 1\.6/);
    expect(css).toMatch(/\.hm-fam-eyebrow \{[^}]*line-height: 1\.6/);
  });
  test('the h2 is left-aligned to the same edge (inner is static so the eyebrow resolves against the sticky head, and its left padding lands on 11.5vw)', () => {
    const inner = rule(css, `${PIN} .hm-fam-inner`);
    expect(inner).toMatch(/position: static;/);
    expect(inner).toMatch(/padding-left: calc\(11\.5vw - clamp\(20px, 5vw, 64px\)\)/);
  });
  test('phones: the same continuity with the phone numbers (9.33% / 5.6% + safe area / max(2.89vw, 12px)) from the stage', () => {
    expect(ADAM_CSS).toMatch(/\.adam-pin\[data-live="true"\] \.adam-eyebrow \{ left: 9\.33cqw; top: calc\(5\.6cqh \+ env\(safe-area-inset-top, 0px\)\)/);
    const at = css.indexOf('@media (max-width: 899px), (pointer: coarse) {', css.indexOf(`${PIN} .hm-fam-eyebrow`));
    const block = css.slice(at, css.indexOf('\n        }', at));
    expect(block).toMatch(/left: 9\.33%; top: calc\(5\.6% \+ env\(safe-area-inset-top, 0px\) - 0\.8em\); font-size: max\(2\.89vw, 12px\)/);
    expect(block).toMatch(/padding-left: calc\(9\.33vw - clamp\(20px, 5vw, 64px\)\)/);
  });
  test('static modes (no JS, reduced motion, stacked landscape) keep the eyebrow in normal flow: the absolute rule only exists under the pinned live selector', () => {
    const all = css.split('.hm-fam-eyebrow {').slice(1);
    for (const chunk of css.matchAll(/([^{}]*\.hm-fam-eyebrow)\s*\{[^}]*position: absolute/g)) expect(chunk[1]).toContain(PIN);
    expect(all.length).toBeGreaterThan(0);
    const html = renderToStaticMarkup(home());
    expect(html).toContain('class="hm-fam-eyebrow" data-k="eyebrow"');
    expect(html).not.toMatch(/hm-fam-eyebrow[^>]*style=/); // no inline positioning in the markup
  });
});
