// Task 20261015-adam-hands-scroll-hero: the pinned "Creation of Adam" section
// replaced the old `.hm-reach` "Reaching" band. This proves the replacement at
// the page level: old markup gone, one pinned section after the hero, family
// copy preserved verbatim in the light block that follows it, ordering before
// the dark explore strip, fallback (first/SSR) render is non-pinned with the
// still + 24svh gradient, hands/light are decorative-only, and reduced motion
// never registers a scroll listener or goes live.
//
// Run with: cd frontend && npx vitest run src/pages/Home.reaching-section.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, act } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';

vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => ({ user: null }) }));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function mockMotion(reduce, mobile = false) {
  window.matchMedia = vi.fn().mockImplementation((query) => ({
    matches: (reduce && query.includes('prefers-reduced-motion')) || (mobile && query.includes('max-width')),
    media: query, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  }));
  window.requestAnimationFrame = window.requestAnimationFrame || ((fn) => setTimeout(() => fn(performance.now()), 16));
  window.cancelAnimationFrame = window.cancelAnimationFrame || ((id) => clearTimeout(id));
}

function renderHome() {
  return render(<MemoryRouter initialEntries={['/']}><Home /></MemoryRouter>);
}
const pin = (c) => c.querySelector('[data-testid="adam-hands"]');
const fam = (c) => c.querySelector('section.hm-fam');

describe('Home: Adam pinned section replaces .hm-reach', () => {
  test('no .hm-reach markup, class or CSS remains; no halftone hand images', () => {
    mockMotion(true);
    const { container } = renderHome();
    expect(container.querySelector('[class*="hm-reach"]')).toBeNull();
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    expect(css).not.toMatch(/hm-reach/);
    expect(container.innerHTML).not.toMatch(/hand-left-cream|hand-right-amber|halftone/i);
  });

  test('exactly one Adam section, and it sits before the light family block', () => {
    mockMotion(true);
    const { container } = renderHome();
    expect(container.querySelectorAll('[data-testid="adam-hands"]').length).toBe(1);
    expect(pin(container).nextElementSibling).toBe(fam(container));
  });

  test('family copy is preserved verbatim in the light block', () => {
    mockMotion(true);
    const { container } = renderHome();
    const s = fam(container);
    expect(s.querySelector('h2').textContent).toBe('Everyone gathered under Christ is called to live as family.');
    expect(s.textContent).toContain("Brothers and sisters don't show up for each other once a week — they show up every day in between. That daily rhythm, not the Sunday appointment, is the actual point. FellowScript exists to make room for it.");
    expect(s.textContent).toContain('Every day — not just Sunday');
    expect(s.textContent).toContain('// WHAT FELLOWSCRIPT PROVIDES');
    expect(s.textContent).toContain('A platform for leaders and others to:');
    ['Organize their small groups', "Get the resources to stay in each other's lives", 'Keep up with everything going on', 'Nurture the kind of family that empowers its environment around them'].forEach((l) => expect(s.textContent).toContain(l));
  });

  test('no dark section directly follows the flood: the next sibling is the light block', () => {
    mockMotion(false);
    const { container } = renderHome();
    expect(pin(container).nextElementSibling.className).toBe('hm-fam');
  });
});

describe('Adam section: fallback (first render, reduced motion, no-JS equivalent)', () => {
  test('reduced motion: stays non-live, no pin runway, still + gradient, no live stack', () => {
    mockMotion(true);
    const { container } = renderHome();
    const p = pin(container);
    expect(p.getAttribute('data-live')).toBe('false');
    expect(p.querySelector('.adam-canvas')).toBeNull();
    expect(p.querySelector('[data-adam="wash"]')).toBeNull();
    expect(p.querySelector('[data-adam="leaks"]')).toBeNull();
    expect(p.querySelector('[data-adam="field"]')).toBeNull();
    expect(p.querySelector('[data-adam="verses"]')).toBeNull(); // no pinned descent
    const still = p.querySelector('img.adam-fb-img');
    expect(still).toBeTruthy();
    expect(still.getAttribute('src')).toBe('/adam/fallback-touch-desktop-1600x900.webp');
    expect(p.querySelector('picture source').getAttribute('srcset')).toBe('/adam/fallback-touch-mobile-900x1600.webp');
    expect(p.querySelector('.adam-grad')).toBeTruthy();
    const css = p.querySelector('style').textContent;
    // The runway height is only ever applied under data-live="true".
    expect(css).toMatch(/\.adam-pin\[data-live="true"\] \{ height: 672vh; \}/);
    expect(css).toMatch(/\.adam-grad \{ position: relative; height: 24svh;/);
    expect(css).toMatch(/#17120F 0%, #2B1B0B 22%, #3F2610 50%, #5C3509 100%/);
    expect(css).toMatch(/#EBC480 97%, #EBC480 100%/);
    // verses are readable in normal flow inside the section (reduced motion / no-JS)
    expect(p.querySelector('[data-testid="verse-stack"]').querySelectorAll('blockquote').length).toBeGreaterThanOrEqual(3);
    expect(p.querySelector('[data-testid="adam-fallback-field"]').textContent).toBe('FamilyWelcoming scripture into a deeper comunity.');
  });

  test('reduced motion: no scroll listener is registered by the Adam section', () => {
    mockMotion(true);
    const add = vi.spyOn(document, 'addEventListener');
    renderHome();
    expect(add.mock.calls.filter(([t, , o]) => t === 'scroll' && o && o.capture).length).toBe(0);
  });

  test('motion allowed: goes live after mount, with a scroll listener (capture) and a 672vh runway attr', () => {
    mockMotion(false);
    const add = vi.spyOn(document, 'addEventListener');
    const { container } = renderHome();
    expect(pin(container).getAttribute('data-live')).toBe('true');
    expect(pin(container).querySelector('.adam-canvas')).toBeTruthy();
    expect(add.mock.calls.filter(([t, , o]) => t === 'scroll' && o && o.capture).length).toBe(1);
  });

  test('unmount removes the scroll listener', () => {
    mockMotion(false);
    const remove = vi.spyOn(document, 'removeEventListener');
    const { unmount } = renderHome();
    unmount();
    expect(remove.mock.calls.some(([t, , o]) => t === 'scroll' && o && o.capture)).toBe(true);
  });
});

describe('Adam section: live stack is decorative and a11y-safe', () => {
  test('every image and layer is alt-empty / aria-hidden, nothing focusable, canvas is aria-hidden', () => {
    mockMotion(false);
    const { container } = renderHome();
    const p = pin(container);
    const imgs = p.querySelectorAll('img');
    expect(imgs.length).toBeGreaterThan(8);
    imgs.forEach((img) => {
      expect(img.getAttribute('alt')).toBe('');
      expect(img.closest('[aria-hidden="true"]')).toBeTruthy();
      expect(img.hasAttribute('tabindex')).toBe(false);
    });
    expect(p.querySelector('.adam-canvas').getAttribute('aria-hidden')).toBe('true');
    expect(p.querySelectorAll('a, button, input, [tabindex]').length).toBe(0);
  });

  test('every key filter carries color-interpolation-filters=sRGB and the warm frame-1 curve', () => {
    mockMotion(false);
    const { container } = renderHome();
    const filters = pin(container).querySelectorAll('filter');
    expect(filters.length).toBeGreaterThanOrEqual(1);
    filters.forEach((f) => expect(f.getAttribute('color-interpolation-filters')).toBe('sRGB'));
    const f = filters[0];
    const n = (sel, a) => parseFloat(f.querySelector(sel).getAttribute(a));
    expect(n('feFuncR', 'slope')).toBeCloseTo(0.682, 4);
    expect(n('feFuncG', 'slope')).toBeCloseTo(0.670, 4);
    expect(n('feFuncB', 'slope')).toBeCloseTo(0.646, 4);
    expect(n('feFuncR', 'intercept')).toBeCloseTo(-0.1, 4);
  });

  test('final-frame type: Schibsted headline "Family" + Schibsted subtitle, grainy field layer, light-band layers and #FFF4DC darken cap', () => {
    mockMotion(false);
    const { container } = renderHome();
    const p = pin(container);
    expect(p.querySelector('.adam-final-h').textContent).toBe('Family');
    expect(p.querySelector('[data-adam="leaks"]').getAttribute('aria-hidden')).toBe('true');
    expect(p.querySelector('[data-adam="wash"]')).toBeNull();
    expect(p.querySelector('[data-adam="cover"]')).toBeNull();
    expect(p.querySelector('[data-adam="field"]').getAttribute('aria-hidden')).toBe('true');
    // pinned verse layer is aria-hidden; the same verses are exposed once via the sr-only list
    expect(p.querySelector('[data-adam="verses"]').getAttribute('aria-hidden')).toBe('true');
    expect(p.querySelectorAll('.verse-sr li').length).toBe(5);
    expect(p.querySelector('[data-testid="verse-stack"]')).toBeNull();
    expect(p.querySelector('.adam-final-b').textContent).toBe('Welcoming scripture into a deeper comunity.');
    const cap = p.querySelector('[data-adam="cap"]');
    expect(cap.style.background).toMatch(/rgb\(255, 244, 220\)|#FFF4DC/i);
    expect(cap.style.mixBlendMode).toBe('darken');
    const css = p.querySelector('style').textContent;
    expect(css).toMatch(/\.adam-final-h \{[^}]*Schibsted Grotesk[^}]*font-weight: 600/);
    expect(css).toMatch(/\.adam-final-b \{[^}]*Schibsted Grotesk/);
    expect(css).not.toMatch(/Playfair|Inter\b/);
  });

  test('mobile: 9:16 canvas, 1800px layers on 2x srcset, 564vh runway rule', () => {
    mockMotion(false, true);
    const { container } = renderHome();
    const p = pin(container);
    expect(p.getAttribute('data-live')).toBe('true');
    const cv = p.querySelector('.adam-canvas');
    expect(cv.style.width).toBe('900px');
    expect(cv.style.height).toBe('1600px');
    const hand = p.querySelector('[data-adam="hand-img"]');
    expect(hand.getAttribute('srcset')).toMatch(/-900x1600\.webp 1x, .*-1800x3200\.webp 2x/);
    expect(p.querySelector('style').textContent).toMatch(/height: 564vh/);
  });

  test('image fallback: eyebrow text stays in the DOM even if the still fails', () => {
    mockMotion(true);
    const { container } = renderHome();
    const still = pin(container).querySelector('img.adam-fb-img');
    act(() => { still.dispatchEvent(new Event('error')); });
    expect(pin(container).querySelector('.adam-eyebrow').textContent).toBe('// NOT JUST ONCE A WEEK');
  });
});
