// Task 20261008-homepage-problem-carousel: "THE PROBLEM" fanned-deck carousel
// replacing the old features section. Proves: verified statistics and source
// lines verbatim (34% Hartford, 56% Barna, 32% LifeWay; never the unsourced
// 61%/66%/69%), ARIA carousel semantics, click/keyboard/dot rotation, reduced
// motion, SSR render without window, old features section gone.
//
// Run with: cd frontend && npx vitest run src/pages/Home.problem-section.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';
import ProblemCarousel from '../components/ProblemCarousel.jsx';

vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => ({ user: null }) }));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function renderHome() {
  return render(<MemoryRouter initialEntries={['/']}><Home /></MemoryRouter>);
}
const section = () => screen.getByText('// THE PROBLEM').closest('section');
const slides = (s) => Array.from(s.querySelectorAll('[aria-roledescription="slide"]'));
const slotOf = (el) => el.getAttribute('data-slot');
const frontIndex = (s) => slides(s).findIndex((el) => slotOf(el) === '0');

function mockMotion(reduce) {
  window.matchMedia = vi.fn().mockImplementation((query) => ({
    matches: reduce && query.includes('prefers-reduced-motion'),
    media: query, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  }));
}

describe('Home problem section: content and truthfulness', () => {
  test('old features section is gone', () => {
    renderHome();
    expect(screen.queryByText('// EVERYTHING YOU NEED')).toBeNull();
    expect(document.body.textContent).not.toContain('EVERYTHING YOU NEED');
  });

  test('three slides carry the verified stats and exact source lines', () => {
    renderHome();
    const s = section();
    const sl = slides(s);
    expect(sl.length).toBe(3);

    expect(sl[0].textContent).toContain('56% of U.S. Christians say their spiritual life is entirely private.');
    expect(sl[0].textContent).toContain('Barna Group & The Navigators, 2022');
    expect(sl[1].textContent).toContain('Only 34% of U.S. congregations grew by 5% or more between 2015 and 2020.');
    expect(sl[1].textContent).toContain('Hartford Institute, Faith Communities Today, 2020');
    expect(sl[2].textContent).toContain('Only 32% of Protestant churchgoers read the Bible every day.');
    expect(sl[2].textContent).toContain('LifeWay Research, 2019');
  });

  test('unsourced figures 61%, 66% and 69% are never printed in the section', () => {
    renderHome();
    const t = section().textContent;
    expect(t).not.toMatch(/\b61\s?%/);
    expect(t).not.toMatch(/\b66\s?%/);
    expect(t).not.toMatch(/\b69\s?%/);
    expect(t).not.toMatch(/confess/i);
  });

  test('every source line is a safe external link with a real https href', () => {
    renderHome();
    const links = Array.from(section().querySelectorAll('.pc-source a'));
    expect(links.length).toBe(3);
    links.forEach((a) => {
      expect(a.getAttribute('href')).toMatch(/^https:\/\//);
      expect(a.getAttribute('target')).toBe('_blank');
      expect(a.getAttribute('rel')).toContain('noopener');
      expect(a.getAttribute('rel')).toContain('noreferrer');
    });
    expect(links[0].getAttribute('href')).toContain('barna.com');
  });

  test('each slide carries a Solution block', () => {
    renderHome();
    slides(section()).forEach((el) => {
      expect(el.querySelector('.pc-pill').textContent).toBe('Solution');
      expect(el.querySelector('.pc-solution').textContent.length).toBeGreaterThan(40);
    });
  });
});

describe('Home problem section: ARIA semantics', () => {
  test('carousel region, slide groups, labelled nav controls', () => {
    renderHome();
    const root = section().querySelector('[aria-roledescription="carousel"]');
    expect(root).toBeTruthy();
    expect(root.getAttribute('role')).toBe('region');
    expect(root.getAttribute('aria-label')).toBeTruthy();
    const sl = slides(section());
    sl.forEach((el, i) => {
      expect(el.getAttribute('role')).toBe('group');
      expect(el.getAttribute('aria-label')).toBe(`Slide ${i + 1} of 3`);
    });
    expect(screen.getByRole('button', { name: 'Previous slide' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Next slide' })).toBeTruthy();
    expect(screen.getAllByRole('button', { name: /^Go to slide \d$/ }).length).toBe(3);
  });

  test('back slides are hidden from assistive tech, front is exposed; only front is focus target', () => {
    renderHome();
    const sl = slides(section());
    expect(sl[0].querySelector('.pc-inner').hasAttribute('aria-hidden')).toBe(false);
    expect(sl[1].querySelector('.pc-inner').getAttribute('aria-hidden')).toBe('true');
    expect(sl[2].querySelector('.pc-inner').getAttribute('aria-hidden')).toBe('true');
    expect(sl[0].getAttribute('tabindex')).toBe('-1');
    expect(sl[1].hasAttribute('tabindex')).toBe(false);
    // back-slide source links are removed from the tab order
    expect(sl[1].querySelector('.pc-source a').getAttribute('tabindex')).toBe('-1');
    expect(sl[0].querySelector('.pc-source a').hasAttribute('tabindex')).toBe(false);
  });

  test('aria-current marks the active dot and a polite live region announces the slide', () => {
    renderHome();
    const dots = screen.getAllByRole('button', { name: /^Go to slide \d$/ });
    expect(dots[0].getAttribute('aria-current')).toBe('true');
    expect(dots[1].hasAttribute('aria-current')).toBe(false);
    const live = section().querySelector('[aria-live="polite"]');
    expect(live.textContent).toBe('Slide 1 of 3: KEPT PRIVATE');
    fireEvent.click(dots[2]);
    expect(live.textContent).toBe('Slide 3 of 3: IN THE WORD');
    expect(screen.getAllByRole('button', { name: /^Go to slide \d$/ })[2].getAttribute('aria-current')).toBe('true');
  });

  test('no autoplay: slide does not change on its own', () => {
    const two = [
      { id: 'a', label: 'A', sentence: 'Alpha', solution: 'Sol A', visual: 'network' },
      { id: 'b', label: 'B', sentence: 'Beta', solution: 'Sol B', visual: 'network' },
    ];
    const { container } = render(<ProblemCarousel slides={two} />);
    vi.useFakeTimers();
    try {
      vi.advanceTimersByTime(60000);
    } finally {
      vi.useRealTimers();
    }
    expect(container.querySelector('[data-slot="0"]').getAttribute('aria-label')).toBe('Slide 1 of 2');
  });
});

describe('Home problem section: rotation', () => {
  test('clicking a back slide brings it to the front and moves focus to it', () => {
    renderHome();
    const s = section();
    fireEvent.click(screen.getByRole('button', { name: /Show slide 2: TIME AND RESOURCES/ }));
    expect(frontIndex(s)).toBe(1);
    expect(slotOf(slides(s)[2])).toBe('1');
    expect(slotOf(slides(s)[0])).toBe('2');
    expect(document.activeElement).toBe(slides(s)[1]);
    // formerly front slide is now a back card with a show button
    expect(screen.getByRole('button', { name: /Show slide 1: KEPT PRIVATE/ })).toBeTruthy();
  });

  test('next/prev buttons wrap around', () => {
    renderHome();
    const s = section();
    const next = screen.getByRole('button', { name: 'Next slide' });
    const prev = screen.getByRole('button', { name: 'Previous slide' });
    fireEvent.click(next); expect(frontIndex(s)).toBe(1);
    fireEvent.click(next); expect(frontIndex(s)).toBe(2);
    fireEvent.click(next); expect(frontIndex(s)).toBe(0);
    fireEvent.click(prev); expect(frontIndex(s)).toBe(2);
  });

  test('keyboard: ArrowRight/ArrowLeft/End/Home', () => {
    renderHome();
    const s = section();
    const root = s.querySelector('[aria-roledescription="carousel"]');
    fireEvent.keyDown(root, { key: 'ArrowRight' }); expect(frontIndex(s)).toBe(1);
    fireEvent.keyDown(root, { key: 'ArrowRight' }); expect(frontIndex(s)).toBe(2);
    fireEvent.keyDown(root, { key: 'ArrowRight' }); expect(frontIndex(s)).toBe(0);
    fireEvent.keyDown(root, { key: 'ArrowLeft' }); expect(frontIndex(s)).toBe(2);
    fireEvent.keyDown(root, { key: 'Home' }); expect(frontIndex(s)).toBe(0);
    fireEvent.keyDown(root, { key: 'End' }); expect(frontIndex(s)).toBe(2);
    fireEvent.keyDown(root, { key: 'a' }); expect(frontIndex(s)).toBe(2);
  });

  test('dots jump directly to a slide', () => {
    renderHome();
    const s = section();
    fireEvent.click(screen.getAllByRole('button', { name: /^Go to slide \d$/ })[2]);
    expect(frontIndex(s)).toBe(2);
    fireEvent.click(screen.getAllByRole('button', { name: /^Go to slide \d$/ })[1]);
    expect(frontIndex(s)).toBe(1);
  });

  test('touch swipe left advances, swipe right goes back; mouse drag is ignored', () => {
    renderHome();
    const s = section();
    const stage = s.querySelector('.pc-stage');
    const swipe = (x0, x1, pointerType = 'touch') => {
      fireEvent.pointerDown(stage, { pointerType, clientX: x0, clientY: 100 });
      fireEvent.pointerUp(stage, { pointerType, clientX: x1, clientY: 100 });
    };
    swipe(300, 40); expect(frontIndex(s)).toBe(1);
    swipe(40, 300); expect(frontIndex(s)).toBe(0);
    swipe(300, 40, 'mouse'); expect(frontIndex(s)).toBe(0);
  });
});

describe('Home problem section: reduced motion and SSR', () => {
  test('reduced motion: no reveal phase is applied, rotation still works, CSS disables transitions', () => {
    mockMotion(true);
    const io = vi.fn();
    vi.stubGlobal('IntersectionObserver', io);
    renderHome();
    const s = section();
    const root = s.querySelector('.pc-root');
    expect(root.hasAttribute('data-pc-phase')).toBe(false);
    expect(io).not.toHaveBeenCalled();
    expect(s.querySelector('style').textContent).toMatch(/prefers-reduced-motion: reduce[\s\S]*transition: none !important/);
    fireEvent.click(screen.getByRole('button', { name: 'Next slide' }));
    expect(frontIndex(s)).toBe(1);
  });

  test('normal motion with IntersectionObserver: starts in "pre" and flips to "in" on intersect', () => {
    mockMotion(false);
    let cb;
    const disconnect = vi.fn();
    vi.stubGlobal('IntersectionObserver', function IO(fn, opts) {
      // Home has its own observers; capture only the carousel's (threshold 0.2).
      const mine = opts && opts.threshold === 0.2 && !opts.rootMargin;
      if (mine) cb = fn;
      this.observe = vi.fn();
      this.disconnect = mine ? disconnect : vi.fn();
      this.unobserve = vi.fn();
    });
    renderHome();
    const root = section().querySelector('.pc-root');
    expect(root.getAttribute('data-pc-phase')).toBe('pre');
    cb([{ isIntersecting: true }]);
    expect(root.getAttribute('data-pc-phase')).toBe('in');
    expect(disconnect).toHaveBeenCalled();
  });

  test('SSR: renders to static markup with all slide text and no window access', () => {
    const html = renderToStaticMarkup(
      <MemoryRouter><Home /></MemoryRouter>
    );
    expect(html).toContain('// THE PROBLEM');
    expect(html).toContain('56% of U.S. Christians say their spiritual life is entirely private.');
    expect(html).toContain('Only 34% of U.S. congregations grew by 5% or more between 2015 and 2020.');
    expect(html).toContain('Only 32% of Protestant churchgoers read the Bible every day.');
    expect(html).toContain('Barna Group &amp; The Navigators, 2022');
    expect(html).toContain('Hartford Institute, Faith Communities Today, 2020');
    expect(html).toContain('LifeWay Research, 2019');
    expect(html).not.toMatch(/\b(61|66|69)\s?%/);
  });

  test('ProblemCarousel is data-driven for a different slide count', () => {
    const two = [
      { id: 'a', label: 'A', sentence: 'Alpha', solution: 'Sol A', visual: 'network' },
      { id: 'b', label: 'B', sentence: 'Beta', solution: 'Sol B', visual: 'network' },
    ];
    const { container } = render(<ProblemCarousel slides={two} />);
    expect(container.querySelectorAll('[aria-roledescription="slide"]').length).toBe(2);
    fireEvent.click(screen.getByRole('button', { name: 'Next slide' }));
    fireEvent.click(screen.getByRole('button', { name: 'Next slide' }));
    expect(container.querySelector('[data-slot="0"]').getAttribute('aria-label')).toBe('Slide 1 of 2');
  });
});
