// Regression/behavioral test for useHostRect (added
// .claude/pipeline/20260826-notes-filter-panel-blur-increase, step 3
// verification): both .notes-filter-panel (NotesPanel.jsx) and .chat-overlay
// (MessagingPanel.jsx) now depend on this hook for their portaled
// position/size tracking, so a regression here would silently break both
// overlays' "stay glued to the host panel" contract without necessarily
// showing up in either component's own tests. This exercises the hook in
// isolation: initial measurement, tracking through a resize, tracking
// through a "dock move" (translate without resize -- the case a
// ResizeObserver alone would miss, per the hook's own comment), and
// stopping/resetting when `active` goes false (the overlay-close case).
//
// Run with: cd frontend && npm test -- --run src/hooks/useHostRect.test.js
import React, { useRef } from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, act, cleanup } from '@testing-library/react';
import { useHostRect } from './useHostRect.js';

function TestHarness({ active }) {
  const hostRef = useRef(null);
  const rect = useHostRect(active, hostRef);
  return (
    <div>
      <div ref={hostRef} data-testid="host" />
      <div data-testid="rect">{rect ? JSON.stringify(rect) : 'null'}</div>
    </div>
  );
}

describe('useHostRect', () => {
  let rafCallbacks;
  let nextRafId;

  beforeEach(() => {
    rafCallbacks = new Map();
    nextRafId = 1;
    // Deterministic, manually-steppable rAF stand-in so the hook's polling
    // loop can be driven one frame at a time instead of depending on real
    // frame timing.
    vi.spyOn(window, 'requestAnimationFrame').mockImplementation((cb) => {
      const id = nextRafId++;
      rafCallbacks.set(id, cb);
      return id;
    });
    vi.spyOn(window, 'cancelAnimationFrame').mockImplementation((id) => {
      rafCallbacks.delete(id);
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  function stepFrame() {
    const due = Array.from(rafCallbacks.entries());
    rafCallbacks.clear();
    due.forEach(([, cb]) => act(() => cb()));
  }

  test('returns null while inactive (overlay closed) -- no rect, no polling scheduled', () => {
    const { getByTestId } = render(<TestHarness active={false} />);
    expect(getByTestId('rect').textContent).toBe('null');
    expect(rafCallbacks.size).toBe(0);
  });

  test('measures the host synchronously on open (overlay open) -- correct on first paint, no flash-of-wrong-position', () => {
    let call = 0;
    const rects = [{ top: 10, left: 20, width: 300, height: 400 }];
    Element.prototype.getBoundingClientRect = vi.fn(() => rects[Math.min(call, rects.length - 1)]);

    const { getByTestId } = render(<TestHarness active={true} />);
    const rect = JSON.parse(getByTestId('rect').textContent);
    expect(rect).toEqual({ top: 10, left: 20, width: 300, height: 400 });
  });

  test('tracks the host through a resize (e.g. splitting/resizing a dock group)', () => {
    let current = { top: 10, left: 20, width: 300, height: 400 };
    Element.prototype.getBoundingClientRect = vi.fn(() => current);

    const { getByTestId } = render(<TestHarness active={true} />);
    expect(JSON.parse(getByTestId('rect').textContent).width).toBe(300);

    // Simulate the host panel being resized (e.g. a dock split/resize).
    current = { top: 10, left: 20, width: 150, height: 250 };
    stepFrame();
    const resized = JSON.parse(getByTestId('rect').textContent);
    expect(resized.width).toBe(150);
    expect(resized.height).toBe(250);
  });

  test('tracks the host through a "dock move" -- a translate with no size change, which a ResizeObserver alone would miss', () => {
    let current = { top: 10, left: 20, width: 300, height: 400 };
    Element.prototype.getBoundingClientRect = vi.fn(() => current);

    const { getByTestId } = render(<TestHarness active={true} />);
    expect(JSON.parse(getByTestId('rect').textContent)).toEqual({ top: 10, left: 20, width: 300, height: 400 });

    // Same size, moved position -- the exact case the hook's own comment
    // calls out (a sibling group's resize shifting this one within a split
    // layout).
    current = { top: 220, left: 340, width: 300, height: 400 };
    stepFrame();
    expect(JSON.parse(getByTestId('rect').textContent)).toEqual({ top: 220, left: 340, width: 300, height: 400 });
  });

  test('does not re-render on an unchanged measurement (stable rect across frames with no movement)', () => {
    const current = { top: 10, left: 20, width: 300, height: 400 };
    Element.prototype.getBoundingClientRect = vi.fn(() => current);

    const renderSpy = vi.fn();
    function Probe({ active }) {
      const hostRef = useRef(null);
      const rect = useHostRect(active, hostRef);
      renderSpy(rect);
      return <div ref={hostRef} />;
    }
    render(<Probe active={true} />);
    const rendersAfterMount = renderSpy.mock.calls.length;

    stepFrame();
    stepFrame();
    stepFrame();

    // The measure loop keeps scheduling frames (needed to catch real
    // movement), but an unchanged rect must not trigger extra React renders.
    expect(renderSpy.mock.calls.length).toBe(rendersAfterMount);
  });

  test('resets to null and stops polling when active goes false (overlay close)', () => {
    const current = { top: 10, left: 20, width: 300, height: 400 };
    Element.prototype.getBoundingClientRect = vi.fn(() => current);

    const { getByTestId, rerender } = render(<TestHarness active={true} />);
    expect(JSON.parse(getByTestId('rect').textContent)).not.toBeNull();
    expect(rafCallbacks.size).toBeGreaterThan(0);

    rerender(<TestHarness active={false} />);
    expect(getByTestId('rect').textContent).toBe('null');
    expect(rafCallbacks.size).toBe(0);
  });

  test('re-measures fresh on re-open after a close (open -> close -> open cycle)', () => {
    let current = { top: 10, left: 20, width: 300, height: 400 };
    Element.prototype.getBoundingClientRect = vi.fn(() => current);

    const { getByTestId, rerender } = render(<TestHarness active={true} />);
    expect(JSON.parse(getByTestId('rect').textContent).top).toBe(10);

    rerender(<TestHarness active={false} />);
    expect(getByTestId('rect').textContent).toBe('null');

    // Host moved while the overlay was closed (e.g. user resized the dock
    // layout with Filter & Sort closed) -- reopening must reflect the new
    // position, not a stale cached one.
    current = { top: 99, left: 88, width: 77, height: 66 };
    rerender(<TestHarness active={true} />);
    expect(JSON.parse(getByTestId('rect').textContent)).toEqual({ top: 99, left: 88, width: 77, height: 66 });
  });
});
