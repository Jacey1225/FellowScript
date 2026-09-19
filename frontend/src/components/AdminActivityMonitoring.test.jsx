// Tests for AdminActivityMonitoring.jsx (task 20260918-admin-activity-monitoring):
// the admin-only panel embedding backend's matplotlib-rendered plots as
// <img> elements against the require_admin-gated GET
// /activity-monitoring/plots/* endpoints.
//
// Since each chart is a plain <img src=...> (not a fetch() this component
// controls the response of -- see the component's own header comment on why
// that's an acceptable, documented tradeoff), these tests drive jsdom's
// native <img> onload/onerror events directly rather than mocking fetch.
//
// Run with: cd frontend && npm test -- --run src/components/AdminActivityMonitoring.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import AdminActivityMonitoring from './AdminActivityMonitoring.jsx';
import { API } from '../config.js';

let desktop = true;
vi.mock('../hooks/useIsDesktopViewport.js', () => ({
  useIsDesktopViewport: () => desktop,
}));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('AdminActivityMonitoring', () => {
  test('renders five chart cards pointed at the correct require_admin-gated endpoints', () => {
    render(<AdminActivityMonitoring />);

    const expected = ['notes', 'highlights', 'logins', 'messages', 'visits'];
    for (const metric of expected) {
      const img = document.querySelector(
        `img[src="${API}/activity-monitoring/plots/${metric}"]`
      );
      expect(img).not.toBeNull();
    }
  });

  test('every chart has non-empty, load-bearing alt text', () => {
    render(<AdminActivityMonitoring />);
    const imgs = document.querySelectorAll('img');
    expect(imgs.length).toBe(5);
    for (const img of imgs) {
      expect(img.getAttribute('alt')).toBeTruthy();
    }
  });

  test('shows a loading spinner before an image finishes loading', () => {
    render(<AdminActivityMonitoring />);
    // Ant Design's Spin renders with role="img"/aria-label in some versions;
    // more robustly, the loaded image itself should start invisible
    // (opacity 0) since ChartFrame flips it in only on load.
    const img = document.querySelector(`img[src="${API}/activity-monitoring/plots/notes"]`);
    expect(img.style.opacity).toBe('0');
  });

  test('a successful image load fades the chart in (opacity 1)', () => {
    render(<AdminActivityMonitoring />);
    const img = document.querySelector(`img[src="${API}/activity-monitoring/plots/notes"]`);
    fireEvent.load(img);
    expect(img.style.opacity).toBe('1');
  });

  test('a failed image load (e.g. 401/403/500 from the plot endpoint) shows an error '
    + 'state with Retry, without affecting the other four charts', () => {
    render(<AdminActivityMonitoring />);
    const notesImg = document.querySelector(`img[src="${API}/activity-monitoring/plots/notes"]`);
    fireEvent.error(notesImg);

    expect(screen.getByText('Could not load this chart.')).toBeTruthy();
    // The other four charts' <img> elements are untouched -- still present,
    // not replaced by an error state.
    for (const metric of ['highlights', 'logins', 'messages', 'visits']) {
      expect(
        document.querySelector(`img[src="${API}/activity-monitoring/plots/${metric}"]`)
      ).not.toBeNull();
    }
  });

  test('clicking Retry after a failed load re-issues the image request with a cache-busting param', () => {
    render(<AdminActivityMonitoring />);
    const notesImg = document.querySelector(`img[src="${API}/activity-monitoring/plots/notes"]`);
    fireEvent.error(notesImg);

    fireEvent.click(screen.getByRole('button', { name: /retry/i }));

    const retried = document.querySelector(
      `img[src^="${API}/activity-monitoring/plots/notes?_r="]`
    );
    expect(retried).not.toBeNull();
  });

  test('the visits chart card renders an accessible plain-text legend duplicating the '
    + 'in-image raw-vs-unique-device color coding', () => {
    render(<AdminActivityMonitoring />);
    expect(screen.getByText('Raw visits')).toBeTruthy();
    expect(screen.getByText(/Unique devices/)).toBeTruthy();
  });

  test('desktop: metric cards lay out in a 2-column grid', () => {
    desktop = true;
    render(<AdminActivityMonitoring />);
    const grid = screen.getByText('Average notes per user').closest('div').parentElement;
    expect(grid.style.gridTemplateColumns).toBe('1fr 1fr');
  });

  test('mobile: metric cards stack in a single column', () => {
    desktop = false;
    render(<AdminActivityMonitoring />);
    const grid = screen.getByText('Average notes per user').closest('div').parentElement;
    expect(grid.style.gridTemplateColumns).toBe('1fr');
  });

  test('Refresh button remounts every chart, resetting each back to a loading state', () => {
    desktop = true;
    render(<AdminActivityMonitoring />);
    const notesImg = document.querySelector(`img[src="${API}/activity-monitoring/plots/notes"]`);
    fireEvent.load(notesImg);
    expect(
      document.querySelector(`img[src="${API}/activity-monitoring/plots/notes"]`).style.opacity
    ).toBe('1');

    fireEvent.click(screen.getByRole('button', { name: /refresh/i }));

    const remounted = document.querySelector(`img[src="${API}/activity-monitoring/plots/notes"]`);
    expect(remounted.style.opacity).toBe('0');
  });
});
