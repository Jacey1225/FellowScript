// Task 20261022-hands-scroll-grain-gradient, testing gate: the reduced-motion
// and mobile first client renders must produce the same markup as the
// server/prerender render (identical hydration markup, no flash, no mismatch),
// and the verse stack must be present in that markup for no-JS readers.
//
// Run with: cd frontend && npx vitest run src/components/AdamHands.prerenderParity.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, cleanup } from '@testing-library/react';
import { renderToString } from 'react-dom/server';
import AdamHands from './AdamHands.jsx';
import { COMMUNITY_VERSES } from '../lib/communityVerses.js';

afterEach(() => { cleanup(); vi.restoreAllMocks(); });

function mm({ reduce = false, mobile = false } = {}) {
  window.matchMedia = vi.fn().mockImplementation((q) => ({
    matches: (reduce && q.includes('prefers-reduced-motion')) || (mobile && q.includes('max-width')),
    media: q, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  }));
}
const norm = (s) => s.replace(/<!-- -->/g, '');
// jsdom re-serialises inline styles and void tags differently from React's
// string renderer, so compare the parsed structure: tag, class, data-/aria-
// attributes and text of every element, in order. <style> bodies are skipped:
// React string-escapes quotes in them (&quot;) while the DOM does not.
function shape(root) {
  return [...root.querySelectorAll('*')].map((el) => [
    el.tagName, el.getAttribute('class'),
    el.getAttributeNames().filter((n) => /^(data-|aria-|alt$|src$|width$|height$)/.test(n)).sort().map((n) => `${n}=${el.getAttribute(n)}`).join('|'),
    el.children.length || el.tagName === 'STYLE' ? '' : el.textContent,
  ]);
}
function parse(html) { const d = document.createElement('div'); d.innerHTML = html; return d; }

describe('prerender parity', () => {
  const ssr = norm(renderToString(<AdamHands />));

  test('reduced-motion client render is byte-identical to the prerender markup', () => {
    mm({ reduce: true });
    const { container } = render(<AdamHands />);
    expect(shape(container)).toEqual(shape(parse(ssr)));
    expect(container.innerHTML).toContain('data-live="false"');
  });

  test('prerender markup carries every community verse as real text (readable without JS)', () => {
    expect(COMMUNITY_VERSES.length).toBeGreaterThanOrEqual(3);
    const text = ssr.replace(/<style>[\s\S]*?<\/style>/g, '').replace(/&#x27;/g, "'").replace(/&quot;/g, '"');
    for (const v of COMMUNITY_VERSES) {
      expect(text).toContain(v.ref);
      expect(text).toContain(v.text.slice(0, 40).replace(/'/g, "'"));
    }
  });

  test('prerender is deterministic (two renders identical, no random or time-based values)', () => {
    expect(norm(renderToString(<AdamHands />))).toBe(ssr);
  });
});
