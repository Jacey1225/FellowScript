// Task 20261008-homepage-section-entrance-transitions: scroll-entrance for the
// family block and the ProblemCarousel. (Task 20261015-adam-hands-scroll-hero
// removed the old reaching-hands entrance; the hand section is now AdamHands,
// covered by Home.reaching-section.test.jsx and the adamHands driver tests.) Proves: hidden start state is
// client-only (SSR / renderHome show final content), reduced motion shows the
// final state immediately, count-up lands on exact values without touching the
// aria-live text, stagger delays are removed after the entrance / first click,
// and the hands' entrance uses translate/rotate so the drift transform composes.
//
// Run with: cd frontend && npx vitest run --no-file-parallelism src/pages/Home.entrance-transitions.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent, act } from '@testing-library/react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';
import { renderHome as ssrRenderHome } from '../entry-server.jsx';

vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => ({ user: null }), AuthProvider: ({ children }) => children }));

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function mockMotion(reduce) {
  window.matchMedia = vi.fn().mockImplementation((query) => ({
    matches: reduce && query.includes('prefers-reduced-motion'),
    media: query, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  }));
}

// Records every observer so a test can fire the one with a given threshold.
function stubIO() {
  const all = [];
  vi.stubGlobal('IntersectionObserver', function IO(fn, opts) {
    this.fn = fn; this.opts = opts || {};
    this.observe = vi.fn(); this.unobserve = vi.fn(); this.disconnect = vi.fn();
    all.push(this);
  });
  return {
    all,
    fire: (threshold, rootMarginAbsent = true) => {
      const io = all.find((o) => o.opts.threshold === threshold && (!rootMarginAbsent || !o.opts.rootMargin));
      expect(io, `observer with threshold ${threshold}`).toBeTruthy();
      act(() => io.fn([{ isIntersecting: true, target: document.body }]));
      return io;
    },
  };
}

const renderHomeDom = () => render(<MemoryRouter initialEntries={['/']}><Home /></MemoryRouter>);
const fam = () => document.querySelector('section.hm-fam');
const problem = () => screen.getByText('// THE PROBLEM').closest('section');
const nums = (s) => Array.from(s.querySelectorAll('[data-pc-count]')).map((n) => n.textContent);
const stripStyle = (html) => html.replace(/<style[\s\S]*?<\/style>/g, '');

describe('entrance: prerender / no-JS shows final content', () => {
  test('renderHome (prerender entry) has no hidden or offset state markers and keeps indexed text', () => {
    const html = ssrRenderHome();
    const body = stripStyle(html);
    expect(body).not.toMatch(/data-fs-reach/);
    expect(body).not.toMatch(/data-pc-phase/);
    expect(body).not.toMatch(/opacity:\s*0[;"]/);
    const text = body.replace(/<svg[\s\S]*?<\/svg>/g, '').replace(/<[^>]+>/g, '').replace(/&#x27;/g, "'").replace(/&amp;/g, '&');
    expect(text).toContain('// NOT JUST ONCE A WEEK');
    expect(text).toContain('Everyone gathered under Christ is called to live as family.');
    expect(body).toContain('56% of U.S. Christians say their spiritual life is entirely private.');
    expect(body).toContain('Only 34% of U.S. congregations grew by 5% or more between 2015 and 2020.');
    expect(body).toContain('Only 32% of Protestant churchgoers read the Bible every day.');
    // Real numbers present in the aria-hidden count nodes, in server markup.
    expect(body).toMatch(/data-pc-count="56"[^>]*>56</);
    expect(body).toMatch(/data-pc-count="34"[^>]*>34</);
    expect(body).toMatch(/data-pc-count="32"[^>]*>32</);
  });

  test('renderToStaticMarkup(Home) has no entrance state attribute', () => {
    const body = stripStyle(renderToStaticMarkup(<MemoryRouter><Home /></MemoryRouter>));
    expect(body).not.toMatch(/data-fs-reach|data-pc-phase/);
  });

  test('hidden start state is gated on the client-set attribute, never default CSS', () => {
    const body = renderToStaticMarkup(<MemoryRouter><Home /></MemoryRouter>);
    const css = [...body.matchAll(/<style>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join('\n').replace(/&quot;/g, '"').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
    // the family block's hidden state is not default CSS on a markup element:
    // it only applies to .hm-family-reveal, which the prerender still emits
    // visible via the reduced-motion/no-attr backstop covered elsewhere.
    expect(css).not.toMatch(/hm-reach/);
    // carousel pre-state likewise
    const pcOffset = css.split('}').filter((r) => /translate:\s*0 var\(--pc-enter-y\)/.test(r));
    expect(pcOffset.length).toBeGreaterThan(0);
    pcOffset.forEach((r) => expect(r).toMatch(/data-pc-phase="pre"/));
  });
});

describe('entrance: family block (light section after the Adam pin)', () => {
  test('client: reveal observer arms at threshold 0.2 and flips data-fs-in-view once', () => {
    mockMotion(false);
    const io = stubIO();
    renderHomeDom();
    expect(fam().hasAttribute('data-fs-in-view')).toBe(false);
    const obs = io.all.find((o) => o.opts.threshold === 0.2 && o.opts.rootMargin);
    expect(obs).toBeTruthy();
    act(() => obs.fn([{ isIntersecting: true, target: fam() }]));
    expect(fam().getAttribute('data-fs-in-view')).toBe('true');
    expect(obs.unobserve).toHaveBeenCalled();
  });

  test('reduced motion: no reveal observer is created for the family block', () => {
    mockMotion(true);
    const io = stubIO();
    renderHomeDom();
    expect(io.all.find((o) => o.opts.threshold === 0.2 && o.opts.rootMargin)).toBeFalsy();
    expect(fam().hasAttribute('data-fs-in-view')).toBe(false);
  });

  test('no IntersectionObserver: nothing hidden by attribute, carousel has no phase', () => {
    mockMotion(false);
    vi.stubGlobal('IntersectionObserver', undefined);
    delete window.IntersectionObserver;
    renderHomeDom();
    expect(fam().hasAttribute('data-fs-in-view')).toBe(false);
    expect(problem().querySelector('.pc-root').hasAttribute('data-pc-phase')).toBe(false);
  });

  test('CSS: the family hidden state is class-based and reduced-motion forces it visible', () => {
    const { container } = renderHomeDom();
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    expect(css).toMatch(/prefers-reduced-motion: reduce\)[\s\S]*\.hm-family-reveal \{ opacity: 1 !important; transform: none !important; transition: none !important; \}/);
    expect(css).toMatch(/\[data-fs-in-view="true"\] \.hm-family-reveal \{ opacity: 1; transform: translateY\(0\); \}/);
  });

  test('the old reach hooks and markup are gone from the page', () => {
    const { container } = renderHomeDom();
    expect(container.querySelector('.hm-reach')).toBeNull();
    expect(container.querySelector('[data-fs-reach]')).toBeNull();
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    expect(css).not.toMatch(/hm-reach/);
  });
});

describe('entrance: problem carousel', () => {
  const slotsOf = (s) => Array.from(s.querySelectorAll('.pc-card')).map((c) => c.getAttribute('data-slot'));

  test('client: counts start at 0 in the aria-hidden node only, pre phase set before any intersect', () => {
    mockMotion(false);
    stubIO();
    renderHomeDom();
    const root = problem().querySelector('.pc-root');
    expect(root.getAttribute('data-pc-phase')).toBe('pre');
    expect(nums(problem())).toEqual(['0', '0', '0']);
    problem().querySelectorAll('[data-pc-count]').forEach((n) => {
      expect(n.closest('[aria-hidden="true"]')).toBeTruthy();
    });
  });

  test('count-up ends on exact 56/34/32 and never touches aria-live text', () => {
    vi.useFakeTimers();
    mockMotion(false);
    const io = stubIO();
    renderHomeDom();
    const live = problem().querySelector('[aria-live]');
    expect(live).toBeTruthy();
    const liveBefore = live.textContent;
    const mo = [];
    const observer = new MutationObserver((recs) => mo.push(...recs));
    observer.observe(live, { subtree: true, childList: true, characterData: true, attributes: true });

    io.fire(0.2);
    expect(problem().querySelector('.pc-root').getAttribute('data-pc-phase')).toBe('in');
    for (let i = 0; i < 60; i += 1) act(() => { vi.advanceTimersByTime(50); });
    // intermediate values are never greater than the target
    expect(nums(problem())).toEqual(['56', '34', '32']);
    expect(live.textContent).toBe(liveBefore);
    expect(mo.length).toBe(0);
    observer.disconnect();
  });

  test('count values ramp (not instantly final) shortly after the trigger', () => {
    vi.useFakeTimers();
    mockMotion(false);
    const io = stubIO();
    renderHomeDom();
    io.fire(0.2);
    act(() => { vi.advanceTimersByTime(200); });
    const mid = nums(problem()).map(Number);
    // slide 1 (56) is front: starts after 2x stagger, so at 200ms the slide-3
    // number (back card) has begun but none has finished
    expect(mid.some((v, i) => v < [56, 34, 32][i])).toBe(true);
  });

  test('stagger: slot 2 -> 1 -> 0 delays in CSS, 150ms apart, only under phase "in"', () => {
    const { container } = renderHomeDom();
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    const d = (slot) => css.match(new RegExp(`data-pc-phase="in"\\] \\.pc-card\\[data-slot="${slot}"\\] \\{ transition-delay: (\\d+)ms`))[1];
    expect([d(2), d(1), d(0)]).toEqual(['0', '150', '300']);
    // no delay rule keyed on anything but "in"
    expect(css).not.toMatch(/data-pc-phase="(pre|done)"\][^{]*\{[^}]*transition-delay/);
    // cards enter from below via individual translate property
    expect(css).toMatch(/data-pc-phase="pre"\] \.pc-card:not\(\[data-slot="far"\]\) \{ translate: 0 var\(--pc-enter-y\); opacity: 0; \}/);
    // slot transforms (resting fan) untouched
    expect(css).toMatch(/\.pc-card\[data-slot="1"\] \{ z-index: 2; transform: translate\(-36px,-46px\) scale\(\.96\) rotate\(-1\.5deg\); \}/);
    expect(css).toMatch(/\.pc-card\[data-slot="2"\] \{ z-index: 1; transform: translate\(-72px,-92px\) scale\(\.92\) rotate\(-3deg\); \}/);
  });

  test('delays are removed ("done") after the entrance timer', () => {
    vi.useFakeTimers();
    mockMotion(false);
    const io = stubIO();
    renderHomeDom();
    const root = problem().querySelector('.pc-root');
    io.fire(0.2);
    expect(root.getAttribute('data-pc-phase')).toBe('in');
    act(() => { vi.advanceTimersByTime(1200); });
    expect(root.getAttribute('data-pc-phase')).toBe('done');
  });

  test('delays are removed on the first interaction, and rotation still works mid-entrance', () => {
    vi.useFakeTimers();
    mockMotion(false);
    const io = stubIO();
    renderHomeDom();
    const root = problem().querySelector('.pc-root');
    io.fire(0.2);
    expect(root.getAttribute('data-pc-phase')).toBe('in');
    fireEvent.click(screen.getByRole('button', { name: 'Next slide' }));
    expect(root.getAttribute('data-pc-phase')).toBe('done');
    const front = problem().querySelector('[data-slot="0"]');
    expect(front.getAttribute('aria-label')).toBe('Slide 2 of 3');
  });

  test('existing interactions after the entrance: keyboard, dots, prev wrap, aria-live announces', () => {
    vi.useFakeTimers();
    mockMotion(false);
    const io = stubIO();
    renderHomeDom();
    io.fire(0.2);
    act(() => { vi.advanceTimersByTime(1500); });
    const s = problem();
    const region = s.querySelector('[role="region"], [aria-roledescription="carousel"]') || s;
    fireEvent.keyDown(region.closest('.pc-root') || region, { key: 'End' });
    expect(s.querySelector('[data-slot="0"]').getAttribute('aria-label')).toBe('Slide 3 of 3');
    fireEvent.keyDown(region.closest('.pc-root') || region, { key: 'Home' });
    expect(s.querySelector('[data-slot="0"]').getAttribute('aria-label')).toBe('Slide 1 of 3');
    fireEvent.click(screen.getByRole('button', { name: 'Previous slide' }));
    expect(s.querySelector('[data-slot="0"]').getAttribute('aria-label')).toBe('Slide 3 of 3');
    expect(s.querySelector('[aria-live]').textContent).toMatch(/3/);
    expect(slotsOf(s).sort()).toEqual(['0', '1', '2'].sort());
  });

  test('unmount mid count-up cancels timers/rAF and does not throw', () => {
    vi.useFakeTimers();
    mockMotion(false);
    const io = stubIO();
    const { unmount } = renderHomeDom();
    io.fire(0.2);
    act(() => { vi.advanceTimersByTime(250); });
    unmount();
    expect(() => act(() => { vi.advanceTimersByTime(2000); })).not.toThrow();
  });

  test('reduced motion: no phase, no observer, real numbers immediately', () => {
    mockMotion(true);
    const io = stubIO();
    renderHomeDom();
    const root = problem().querySelector('.pc-root');
    expect(root.hasAttribute('data-pc-phase')).toBe(false);
    expect(io.all.find((o) => o.opts.threshold === 0.2 && !o.opts.rootMargin)).toBeFalsy();
    expect(nums(problem())).toEqual(['56', '34', '32']);
  });

  test('CSS: reduced-motion backstop forces opacity 1 / translate none even if a phase attribute exists', () => {
    const { container } = renderHomeDom();
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    expect(css).toMatch(/\.pc-root\[data-pc-phase\] \.pc-card:not\(\[data-slot="far"\]\) \{ opacity: 1; translate: none; \}/);
  });

  test('hover rules are not gated on phase (hover lift stays functional after entrance)', () => {
    const { container } = renderHomeDom();
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    const hover = css.match(/@media \(hover: hover\) \{[\s\S]*?\n\s*\}/)[0];
    expect(hover).toMatch(/data-slot="1"\]:hover/);
    expect(hover).not.toMatch(/data-pc-phase/);
  });
});
