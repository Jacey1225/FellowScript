// Task 20261024-verses-depth-liquid: reduced-motion, no-WebGL and parallax-guard behaviour.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, cleanup, act } from '@testing-library/react';
import { renderToStaticMarkup } from 'react-dom/server';
import AdamHands from './AdamHands.jsx';
import { COMMUNITY_VERSES } from '../lib/communityVerses.js';

afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); delete window.__verseParallax; });

function mm({ reduce = false, fine = true } = {}) {
  window.matchMedia = vi.fn().mockImplementation((q) => ({
    matches: (reduce && q.includes('prefers-reduced-motion')) || (fine && q.includes('pointer: fine')),
    media: q, onchange: null, addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  }));
}

describe('reduced motion', () => {
  test('renders the stacked verses, no animated cards, no WebGL canvas, no frames, no pointer listeners', () => {
    mm({ reduce: true });
    const raf = vi.spyOn(window, 'requestAnimationFrame');
    const addDoc = vi.spyOn(window, 'addEventListener');
    const { container } = render(<AdamHands />);
    expect(container.querySelector('[data-testid="verse-stack"]')).not.toBeNull();
    expect(container.querySelector('[data-adam="verses"]')).toBeNull();
    expect(container.querySelector('canvas.adam-gl')).toBeNull();
    expect(container.querySelector('.adam-liquid-frozen')).not.toBeNull();
    expect(raf).not.toHaveBeenCalled();
    expect(addDoc.mock.calls.filter(([t]) => t === 'pointermove' || t === 'mousemove').length).toBe(0);
    COMMUNITY_VERSES.forEach((v) => expect(container.textContent).toContain(v.ref));
  });
});

describe('no WebGL (jsdom): the CSS blob field stays and the shader never claims the handover', () => {
  test('live mode has a canvas but data-gl is never true', () => {
    mm();
    const { container } = render(<AdamHands />);
    const liquid = container.querySelector('.adam-liquid');
    expect(liquid).not.toBeNull();
    expect(liquid.dataset.gl).not.toBe('true');
    expect(liquid.querySelectorAll('[class*="adam-blob"]').length).toBeGreaterThan(0);
  });
  test('server markup has no canvas (prerender parity)', () => {
    expect(renderToStaticMarkup(<AdamHands />)).not.toContain('adam-gl"');
  });
});

describe('parallax guard', () => {
  test('debug hook, when present, never throws when driven or released', () => {
    mm();
    render(<AdamHands />);
    // vitest runs with import.meta.env.DEV, so hooks may exist; they must never throw when driven or released
    if (window.__verseParallax) {
      expect(() => act(() => { window.__verseParallax(1, 1); window.__verseParallax(null, null); })).not.toThrow();
    }
  });
});
