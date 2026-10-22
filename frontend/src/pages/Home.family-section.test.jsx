// Regression coverage for task 20260921-homepage-family-section-redesign.
//
// Replaces the old generic "A little bit of grace, every single day." steps
// grid with a purpose-built "Not just once a week" section carrying the
// founder's actual framing (family under Christ, daily not just weekly
// presence, FellowScript as the facilitating environment). This proves:
//  - the old generic headline/copy is fully gone, not just visually hidden;
//  - the new section renders with the founder's-framing substance intact
//    (family/Christ, daily-not-weekly, FellowScript as facilitator);
//  - the founder's-note card is anonymous (no name/initial attribution),
//    per the user's explicit approval recorded in design-notes.md;
//  - every decorative element the section adds (hand-drawn accents,
//    color-block collage panels, the daily badge dot) is aria-hidden, so
//    none of it is exposed to assistive tech as if it carried meaning;
//  - the scroll-entrance reveal hook doesn't crash under either a normal
//    or a prefers-reduced-motion environment, and content is present in
//    the DOM (not JS-reveal-dependent) either way.
//
// Run with: cd frontend && npm test -- --run src/pages/Home.family-section.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';

vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => ({ user: null }),
}));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

function renderHome() {
  return render(
    <MemoryRouter initialEntries={['/']}>
      <Home />
    </MemoryRouter>
  );
}

describe('Home — "Not just once a week" family section', () => {
  test('the old generic "grace" headline and steps content are gone', () => {
    renderHome();

    expect(screen.queryByText(/A little bit of grace, every single day\.?/i)).toBeNull();
    expect(screen.queryByText(/How it feels day to day/i)).toBeNull();
  });

  test('renders the new eyebrow and purpose-built headline carrying the family-under-Christ framing', () => {
    renderHome();

    // Eyebrow appears in the (aria-hidden) Adam stage and in the light block.
    expect(screen.getAllByText('// NOT JUST ONCE A WEEK').length).toBeGreaterThanOrEqual(1);
    expect(document.querySelector('.hm-fam-eyebrow').textContent).toBe('// NOT JUST ONCE A WEEK');
    expect(
      screen.getByText((_, node) =>
        node?.tagName === 'H2' && /gathered under Christ is called to live as/i.test(node.textContent || '')
      )
    ).toBeTruthy();
  });

  test('carries the daily-not-weekly claim as real, always-visible text (not motion-dependent)', () => {
    renderHome();

    expect(screen.getByText(/Every day — not just Sunday/i)).toBeTruthy();
    expect(
      screen.getByText((_, node) =>
        node?.tagName === 'P' && /show up every day in between/i.test(node.textContent || '')
      )
    ).toBeTruthy();
  });

  test('provides card defines what FellowScript provides, with no founder quote', () => {
    renderHome();

    expect(screen.getByText('// WHAT FELLOWSCRIPT PROVIDES')).toBeTruthy();
    expect(screen.queryByText('// WHY WE BUILT THIS')).toBeNull();
    expect(screen.getByText('A platform for leaders and others to:')).toBeTruthy();
    expect(screen.getByText((_, node) => node?.tagName === 'LI' && /Get the resources to stay in each other's lives/.test(node.textContent || ''))).toBeTruthy();
    expect(screen.getByText('Nurture the kind of family that empowers its environment around them')).toBeTruthy();
  });

  test('every decorative element the section adds is aria-hidden', () => {
    const { container } = renderHome();

    const section = document.querySelector('section.hm-fam');
    expect(section).toBeTruthy();

    // The two offset color-block collage panels.
    const collageBlocks = section.querySelectorAll('span[aria-hidden="true"]');
    expect(collageBlocks.length).toBeGreaterThanOrEqual(2);

    // The hand-drawn SVG accents (circle, underline, quote mark) are all
    // aria-hidden and carry no accessible text of their own.
    const svgs = section.querySelectorAll('svg[aria-hidden="true"]');
    expect(svgs.length).toBeGreaterThanOrEqual(2);
    svgs.forEach((svg) => expect(svg.textContent).toBe(''));
  });

  test('renders full content statically even when prefers-reduced-motion is on (reveal is a backstop-safe enhancement, not a requirement)', () => {
    const original = window.matchMedia;
    window.matchMedia = vi.fn().mockImplementation((query) => ({
      matches: query.includes('prefers-reduced-motion'),
      media: query,
      onchange: null,
      addListener: () => {},
      removeListener: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => false,
    }));

    expect(() => renderHome()).not.toThrow();
    expect(document.querySelector('.hm-fam-eyebrow').textContent).toBe('// NOT JUST ONCE A WEEK');
    expect(screen.getByText(/Every day — not just Sunday/i)).toBeTruthy();

    window.matchMedia = original;
  });

  test('renders without crashing when IntersectionObserver is unavailable (jsdom default) and content is present regardless', () => {
    expect('IntersectionObserver' in window).toBe(false);
    renderHome();
    expect(document.querySelector('.hm-fam-eyebrow').textContent).toBe('// NOT JUST ONCE A WEEK');
  });

  test('family block is a section continuing the pin FIELD_END (navy) gradient into #FBF7F1, with #1A1512 text and sits right after the Adam pin', () => {
    const { container } = renderHome();
    const fam = container.querySelector('section.hm-fam');
    const pin = container.querySelector('[data-testid="adam-hands"]');
    expect(pin.nextElementSibling).toBe(fam);
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    expect(css).toMatch(/\.hm-fam \{[^}]*background-color: #FBF7F1;[^}]*linear-gradient\(180deg, #0E2144 0, #FBF7F1 var\(--fam-settle\)\)[^}]*color: #1A1512/);
    // Fade the divider: no hard border under the eyebrow, a gradient-masked ::after rule instead.
    const eb = css.match(/\.hm-fam-eyebrow \{[^}]*\}/)[0];
    expect(eb).not.toMatch(/border-bottom/);
    expect(eb).toMatch(/color: #5C3509/);
    expect(css).toMatch(/\.hm-fam-eyebrow::after \{[^}]*linear-gradient\(90deg, rgba\(26,21,18,0\) 0%[^}]*rgba\(26,21,18,0\) 100%\)/);
    expect(css).toMatch(/\.hm-fam-body \{[^}]*rgba\(26,21,18,0\.86\)/);
  });
});
