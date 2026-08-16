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

describe('AppBloom — variant-driven bloom intensity (design-notes.md §1a.4)', () => {
  test('variant="reader" renders the dimmer/cooler reader class, not the account class', () => {
    mockMatchMedia(false);
    const { container } = render(<AppBloom variant="reader" />);
    const root = container.querySelector('.fs-app-bloom');
    expect(root).toBeTruthy();
    expect(root.className).toContain('fs-app-bloom--reader');
    expect(root.className).not.toContain('fs-app-bloom--account');
  });

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

  test('always renders exactly one grain texture layer regardless of variant', () => {
    mockMatchMedia(false);
    const { container } = render(<AppBloom variant="reader" />);
    expect(container.querySelectorAll('.fs-app-bloom-grain').length).toBe(1);
  });

  test('is purely decorative: aria-hidden so it never reaches the accessibility tree', () => {
    mockMatchMedia(false);
    const { container } = render(<AppBloom variant="reader" />);
    expect(container.querySelector('.fs-app-bloom').getAttribute('aria-hidden')).toBe('true');
  });
});

describe('AppBloom — motion delegated to useParallaxBlobs (respects prefers-reduced-motion)', () => {
  test('drives the parallax animation loop when reduced motion is not requested', () => {
    mockMatchMedia(false);
    const rafSpy = vi.spyOn(window, 'requestAnimationFrame');
    render(<AppBloom variant="reader" />);
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
    const { unmount } = render(<AppBloom variant="reader" />);
    expect(() => unmount()).not.toThrow();
  });
});
