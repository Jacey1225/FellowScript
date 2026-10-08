// Task 20261008-homepage-reaching-section: "Reaching" composition of the
// "NOT JUST ONCE A WEEK" section. Proves: copy verbatim, decorative hands are
// alt-empty + aria-hidden + non-focusable, image failure leaves text intact,
// the gold circle around "family" is the enlarged one, and the scroll drift is
// skipped under prefers-reduced-motion (and runs otherwise).
//
// Run with: cd frontend && npx vitest run src/pages/Home.reaching-section.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';

vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => ({ user: null }) }));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function renderHome() {
  return render(<MemoryRouter initialEntries={['/']}><Home /></MemoryRouter>);
}
const section = () => screen.getByText('// NOT JUST ONCE A WEEK').closest('section');

function mockMotion(reduce) {
  window.matchMedia = vi.fn().mockImplementation((query) => ({
    matches: reduce && query.includes('prefers-reduced-motion'),
    media: query, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  }));
}

describe('Home reaching section', () => {
  test('all copy is present verbatim', () => {
    renderHome();
    const s = section();
    const h2 = s.querySelector('h2');
    expect(h2.textContent).toBe('Everyone gathered under Christ is called to live as family.');
    expect(s.textContent).toContain("Brothers and sisters don't show up for each other once a week — they show up every day in between. That daily rhythm, not the Sunday appointment, is the actual point. FellowScript exists to make room for it.");
    expect(s.textContent).toContain('Every day — not just Sunday');
    expect(s.textContent).toContain('// WHY WE BUILT THIS');
    expect(s.querySelector('blockquote').textContent).toBe(
      "\"I didn't build this to replace church. I built it because family doesn't clock out — I wanted somewhere for us to keep showing up for each other, every day of the week.\""
    );
  });

  test('both hands are alt-empty, aria-hidden, and unfocusable; section has no interactive content', () => {
    renderHome();
    const imgs = section().querySelectorAll('img');
    expect(imgs.length).toBe(2);
    imgs.forEach((img) => {
      expect(img.getAttribute('alt')).toBe('');
      expect(img.getAttribute('aria-hidden')).toBe('true');
      expect(img.hasAttribute('tabindex')).toBe(false);
      expect(img.closest('[aria-hidden="true"]')).toBeTruthy();
    });
    expect(section().querySelectorAll('a, button, input, [tabindex]').length).toBe(0);
  });

  test('image load failure hides the hand and leaves text intact', () => {
    renderHome();
    const imgs = section().querySelectorAll('img');
    imgs.forEach((img) => fireEvent.error(img));
    imgs.forEach((img) => expect(img.style.display).toBe('none'));
    expect(screen.getByText('// NOT JUST ONCE A WEEK')).toBeTruthy();
    expect(section().querySelector('h2').textContent).toMatch(/live as family\./);
  });

  test('gold circle around "family" is a fixed 400px wide, centered on the word', () => {
    renderHome();
    const circle = section().querySelector('svg.hm-reach-circle');
    expect(circle).toBeTruthy();
    expect(circle.getAttribute('aria-hidden')).toBe('true');
    expect(circle.style.width).toBe('400px');
    expect(circle.style.left).toBe('50%');
    expect(circle.style.top).toBe('50%');
    expect(circle.closest('span').textContent).toBe('family');
  });

  test('drift: reduced motion never touches --fs-drift or registers a scroll listener', () => {
    mockMotion(true);
    const add = vi.spyOn(window, 'addEventListener');
    renderHome();
    const reducedScrollCount = add.mock.calls.filter(([t, , o]) => t === 'scroll' && o && o.passive).length;
    cleanup();
    add.mockClear();
    mockMotion(false);
    renderHome();
    const normalScrollCount = add.mock.calls.filter(([t, , o]) => t === 'scroll' && o && o.passive).length;
    expect(normalScrollCount).toBeGreaterThan(reducedScrollCount);
    mockMotion(true);
    cleanup();
    renderHome();
    expect(section().style.getPropertyValue('--fs-drift')).toBe('');
  });

  test('drift: without reduced motion, --fs-drift is written (eased, within 0..1)', () => {
    mockMotion(false);
    renderHome();
    const v = parseFloat(section().style.getPropertyValue('--fs-drift'));
    expect(v).toBeGreaterThanOrEqual(0);
    expect(v).toBeLessThanOrEqual(1);
  });

  test('CSS: static backstop pins hands under prefers-reduced-motion', () => {
    const { container } = renderHome();
    const css = [...container.querySelectorAll('style')].map((s) => s.textContent).join('\n');
    expect(css).toMatch(/prefers-reduced-motion: reduce\)[^{]*\{[^}]*[\s\S]*?\.hm-reach-hand[^}]*transform:\s*none\s*!important/);
  });
});
