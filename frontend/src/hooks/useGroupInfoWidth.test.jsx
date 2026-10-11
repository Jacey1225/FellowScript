import React, { useRef } from 'react';
import { describe, test, expect, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { useGroupInfoWidth, maxGroupInfoWidth, GROUP_INFO_MIN, GROUP_INFO_MAX } from './useGroupInfoWidth.js';

function Harness() {
  const ref = useRef(null);
  const { width, handleProps } = useGroupInfoWidth(ref, true);
  return (
    <div ref={ref}>
      <div data-testid="h" {...handleProps} />
      <span data-testid="w">{width}</span>
    </div>
  );
}

describe('useGroupInfoWidth', () => {
  beforeEach(() => { try { window.localStorage.clear(); } catch (e) { /* ignore */ } });

  test('max is above min and capped at 720 for a wide host', () => {
    expect(maxGroupInfoWidth(1280)).toBe(GROUP_INFO_MAX);
    expect(maxGroupInfoWidth(600)).toBe(536);
    expect(maxGroupInfoWidth(300)).toBe(GROUP_INFO_MIN);
  });

  test('aria-valuemax > aria-valuemin; End reaches max, Home reaches min', () => {
    render(<Harness />);
    const h = screen.getByTestId('h');
    const min = Number(h.getAttribute('aria-valuemin'));
    const max = Number(h.getAttribute('aria-valuemax'));
    expect(max).toBeGreaterThan(min);
    fireEvent.keyDown(h, { key: 'End' });
    expect(Number(screen.getByTestId('w').textContent)).toBe(max);
    fireEvent.keyDown(h, { key: 'Home' });
    expect(Number(screen.getByTestId('w').textContent)).toBe(min);
  });
});
