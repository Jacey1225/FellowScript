// Tests for AppBloom.jsx — the new decorative background layer added by
// the parchment-and-gold restyle implementation
// (.claude/pipeline/20260816-web-frontend-restyle-implementation).
//
// Covers the two pieces of real logic this component adds (per
// design-notes.md §1a): context-aware bloom intensity via the `variant`
// prop, and delegating motion entirely to useParallaxBlobs — including
// that hook's prefers-reduced-motion guard, which must still be honored
// now that the hook is reused here instead of only on Home.
//
// variant="reader" behavior was reverted back to a rendered (not null)
// bloom by the Warm Vellum Glass reconciliation's bounce revision
// (20260824-reader-full-functionality, design-notes.md §8.1): the prior
// black/gold restyle pass had made AppBloom return null for variant="reader"
// entirely, which — combined with the corner-pinned static #root::before
// layer's limited reach — produced a flat black canvas gap against the
// reference mockup. Reader now renders the same blob/grain layer as every
// other variant, dampened via the existing `.fs-app-bloom--reader` opacity/
// saturate/brightness modifier (defined in global.css) rather than opting
// out of the layer altogether. No other variant/page's <AppBloom> usage
// changes.
//
// Run with: cd frontend && npm test -- --run src/components/AppBloom.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, cleanup } from '@testing-library/react';
import AppBloom from './AppBloom.jsx';

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

function mockMatchMedia(reduceMotion) {
  window.matchMedia = vi.fn((query) => ({
    matches: query.includes('prefers-reduced-motion') ? reduceMotion : false,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  }));
}

describe('AppBloom — variant="reader" renders the dampened bloom layer (design-notes.md §8.1, bounce revision)', () => {
  test('renders the bloom root with both blobs and the grain layer, same as any other variant', () => {
    mockMatchMedia(false);
    const { container } = render(<AppBloom variant="reader" />);
    expect(container.querySelector('.fs-app-bloom')).toBeTruthy();
    expect(container.querySelectorAll('.fs-app-bloom-blob').length).toBe(2);
    expect(container.querySelectorAll('.fs-app-bloom-grain').length).toBe(1);
  });

  test('applies the dimmer/cooler .fs-app-bloom--reader intensity class, not the full-strength account class', () => {
    mockMatchMedia(false);
    const { container } = render(<AppBloom variant="reader" />);
    const root = container.querySelector('.fs-app-bloom');
    expect(root.className).toContain('fs-app-bloom--reader');
    expect(root.className).not.toContain('fs-app-bloom--account');
  });

  test('drives the parallax animation loop for variant="reader" same as other variants (rules of hooks, ref now attached)', () => {
    mockMatchMedia(false);
    const rafSpy = vi.spyOn(window, 'requestAnimationFrame');
    render(<AppBloom variant="reader" />);
    expect(rafSpy).toHaveBeenCalled();
  });

  test('unmounting a variant="reader" instance does not throw', () => {
    mockMatchMedia(false);
    const { unmount } = render(<AppBloom variant="reader" />);
    expect(() => unmount()).not.toThrow();
  });
});

describe('AppBloom — variant-driven bloom intensity (design-notes.md §1a.4), non-reader variants unaffected', () => {
  test('variant="account" renders the full-intensity account class', () => {
    mockMatchMedia(false);
    const { container } = render(<AppBloom variant="account" />);
    const root = container.querySelector('.fs-app-bloom');
    expect(root.className).toContain('fs-app-bloom--account');
    expect(root.className).not.toContain('fs-app-bloom--reader');
  });

  test('defaults to the account variant when no variant prop is passed', () => {
    mockMatchMedia(false);
    const { container } = render(<AppBloom />);
    const root = container.querySelector('.fs-app-bloom');
    expect(root.className).toContain('fs-app-bloom--account');
  });

  test('always renders exactly one grain texture layer for a rendered (non-reader) variant', () => {
    mockMatchMedia(false);
    const { container } = render(<AppBloom variant="account" />);
    expect(container.querySelectorAll('.fs-app-bloom-grain').length).toBe(1);
  });

  test('is purely decorative: aria-hidden so it never reaches the accessibility tree', () => {
    mockMatchMedia(false);
    const { container } = render(<AppBloom variant="account" />);
    expect(container.querySelector('.fs-app-bloom').getAttribute('aria-hidden')).toBe('true');
  });
});

describe('AppBloom — motion delegated to useParallaxBlobs (respects prefers-reduced-motion), non-reader variants', () => {
  test('drives the parallax animation loop when reduced motion is not requested', () => {
    mockMatchMedia(false);
    const rafSpy = vi.spyOn(window, 'requestAnimationFrame');
    render(<AppBloom variant="account" />);
    expect(rafSpy).toHaveBeenCalled();
  });

  test('starts no animation loop under prefers-reduced-motion, but still renders the bloom markup', () => {
    mockMatchMedia(true);
    const rafSpy = vi.spyOn(window, 'requestAnimationFrame');
    const { container } = render(<AppBloom variant="account" />);
    expect(rafSpy).not.toHaveBeenCalled();
    // Static layer still present -- reduced motion means no drift, not no bloom.
    expect(container.querySelector('.fs-app-bloom')).toBeTruthy();
    expect(container.querySelectorAll('.fs-app-bloom-blob').length).toBe(2);
  });

  test('unmount cleans up the animation loop without throwing', () => {
    mockMatchMedia(false);
    const { unmount } = render(<AppBloom variant="account" />);
    expect(() => unmount()).not.toThrow();
  });
});
