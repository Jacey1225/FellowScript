// Route-guard test for MobileBlockGate.jsx.
//
// Like AdminGate.jsx, this is client-side UX only (see deviceGate.js) — it
// can be bypassed by spoofing navigator.userAgent, which is an accepted
// tradeoff here since nothing sensitive sits behind it. This proves the
// two cases: a mobile UA sees the block message instead of the route's
// children, and a desktop UA passes straight through.
//
// Run with: cd frontend && npm test -- --run src/components/MobileBlockGate.test.jsx
import React from 'react';
import { describe, test, expect, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import MobileBlockGate from './MobileBlockGate.jsx';

const IPHONE_SAFARI =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
const DESKTOP_CHROME_MAC =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

let originalUA;

beforeEach(() => {
  originalUA = window.navigator.userAgent;
});

afterEach(() => {
  cleanup();
  Object.defineProperty(window.navigator, 'userAgent', { value: originalUA, configurable: true });
});

function setUserAgent(ua) {
  Object.defineProperty(window.navigator, 'userAgent', { value: ua, configurable: true });
}

function renderGate() {
  return render(
    <MemoryRouter>
      <MobileBlockGate><div>Reader Content</div></MobileBlockGate>
    </MemoryRouter>
  );
}

describe('MobileBlockGate — mobile UA', () => {
  test('shows the block message instead of children', () => {
    setUserAgent(IPHONE_SAFARI);
    renderGate();

    expect(screen.getByText(/reader isn't available on mobile/i)).toBeInTheDocument();
    expect(screen.queryByText('Reader Content')).not.toBeInTheDocument();
  });
});

describe('MobileBlockGate — desktop UA', () => {
  test('renders children through untouched', () => {
    setUserAgent(DESKTOP_CHROME_MAC);
    renderGate();

    expect(screen.getByText('Reader Content')).toBeInTheDocument();
    expect(screen.queryByText(/reader isn't available on mobile/i)).not.toBeInTheDocument();
  });
});
