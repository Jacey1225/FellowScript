// Tests for AdminActivityMonitoring.jsx (task 20260918-admin-activity-monitoring,
// made interactive by task 20260919-activity-monitoring-interactive-charts):
// each of the five chart cards now fetches structured JSON from the new
// require_admin-gated GET /activity-monitoring/data/* endpoints and renders
// an interactive Recharts <LineChart> with a hover/tooltip exact-value
// affordance and a click-to-expand overlay, replacing the prior task's plain
// <img src=".../plots/*"> markup.
//
// Recharts' <ResponsiveContainer> measures its container via ResizeObserver,
// which jsdom doesn't implement -- without a polyfill that actually invokes
// its callback with a non-zero size, every chart renders as an empty 0x0
// <div> and neither the chart body nor its hover/tooltip interactivity can
// be exercised. `installRechartsSizePolyfill()` below (module-scoped, not a
// shared test/setup.js change, matching Reader.dockview.test.jsx's own
// local-polyfill precedent for the same underlying gap) makes every
// ResizeObserver report a fixed usable size synchronously on `observe()`.
//
// Run with: cd frontend && npm test -- --run src/components/AdminActivityMonitoring.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeAll, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup, act } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import AdminActivityMonitoring from './AdminActivityMonitoring.jsx';
import { API } from '../config.js';

let desktop = true;
vi.mock('../hooks/useIsDesktopViewport.js', () => ({
  useIsDesktopViewport: () => desktop,
}));

// Only the chart's own two Recharts-owned wrapper elements (the outer
// <ResponsiveContainer> div and its inner <div class="recharts-wrapper">,
// which owns the mouse-tracking math for hover/tooltip) get a real,
// non-zero box -- every other element (notably `.recharts-legend-wrapper`,
// which Recharts sizes via `offsetHeight`/`offsetWidth` to reserve its own
// vertical space) keeps jsdom's real 0-by-default layout. A blanket
// override of every element to the same non-zero size was tried first and
// broke the two-series visits chart specifically: Recharts' <Legend> read
// that same fixed height back as "the legend needs the whole container",
// leaving zero height for the plot itself and permanently hiding its
// tooltip.
function isRechartsSizedNode(el) {
  return !!(el.classList && (
    el.classList.contains('recharts-responsive-container') ||
    el.classList.contains('recharts-wrapper')
  ));
}

function installRechartsSizePolyfill() {
  Object.defineProperty(HTMLElement.prototype, 'offsetWidth', {
    configurable: true, get() { return isRechartsSizedNode(this) ? 500 : 0; },
  });
  Object.defineProperty(HTMLElement.prototype, 'offsetHeight', {
    configurable: true, get() { return isRechartsSizedNode(this) ? 300 : 0; },
  });
  Object.defineProperty(HTMLElement.prototype, 'getBoundingClientRect', {
    configurable: true,
    value: function () {
      return isRechartsSizedNode(this)
        ? { width: 500, height: 300, top: 0, left: 0, right: 500, bottom: 300 }
        : { width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0 };
    },
  });
  if (!window.__rechartsPolyfilled) {
    window.ResizeObserver = class {
      constructor(cb) { this.cb = cb; }
      observe(el) { this.cb([{ target: el, contentRect: { width: 500, height: 300 } }]); }
      unobserve() {}
      disconnect() {}
    };
    window.__rechartsPolyfilled = true;
  }
}

beforeAll(() => {
  installRechartsSizePolyfill();
});

const METRIC_SERIES = [
  { day: '2026-09-01', value: 1.5 },
  { day: '2026-09-02', value: 2.75 },
];
const VISITS_SERIES = [
  { day: '2026-09-01', raw: 10, unique: 4 },
  { day: '2026-09-02', raw: 15, unique: 6 },
];

function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  };
}

function metricBody(metricKey, series = METRIC_SERIES) {
  return {
    metric: metricKey,
    title: `Average ${metricKey} per user`,
    ylabel: 'Avg per user',
    series,
  };
}

function visitsBody(series = VISITS_SERIES) {
  return { title: 'Website visits (raw vs. unique devices)', series };
}

// Default happy-path fetch mock: every card's `/data/<metric-or-visits>`
// endpoint resolves with a small two-point series, unless a case-specific
// `overrides` entry (keyed by the endpoint's final path segment) says
// otherwise.
function mockFetch(overrides = {}) {
  global.fetch = vi.fn(async (url) => {
    const key = url.split('/').pop();
    if (Object.prototype.hasOwnProperty.call(overrides, key)) {
      const entry = overrides[key];
      return typeof entry === 'function' ? entry() : entry;
    }
    if (key === 'visits') return jsonResponse(200, visitsBody());
    return jsonResponse(200, metricBody(key));
  });
  return global.fetch;
}

function renderPanel() {
  return render(
    <MemoryRouter initialEntries={['/admin']}>
      <Routes>
        <Route path="/admin" element={<AdminActivityMonitoring />} />
        <Route path="/signin" element={<div>Sign In Page</div>} />
        <Route path="/" element={<div>Home Page</div>} />
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  desktop = true;
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('AdminActivityMonitoring', () => {
  test('each of the five cards fetches its own require_admin-gated JSON endpoint on mount', async () => {
    mockFetch();
    renderPanel();

    await waitFor(() => {
      for (const metric of ['notes', 'highlights', 'logins', 'messages', 'visits']) {
        expect(global.fetch).toHaveBeenCalledWith(`${API}/activity-monitoring/data/${metric}`);
      }
    });
    expect(global.fetch).toHaveBeenCalledTimes(5);
  });

  test('shows a loading spinner before a card\'s fetch resolves', async () => {
    let resolveFetch;
    global.fetch = vi.fn((url) => {
      if (url.endsWith('/notes')) {
        return new Promise((resolve) => { resolveFetch = resolve; });
      }
      return Promise.resolve(jsonResponse(200, metricBody(url.split('/').pop())));
    });

    renderPanel();
    expect(document.querySelector('.ant-spin')).not.toBeNull();

    await act(async () => {
      resolveFetch(jsonResponse(200, metricBody('notes')));
      await Promise.resolve();
    });
  });

  test('a loaded chart with data renders as a real, labeled expand button', async () => {
    mockFetch();
    renderPanel();

    const button = await screen.findByRole('button', {
      name: 'Line chart: Average notes per user, trailing 30 days. Press to expand.',
    });
    expect(button).toBeInTheDocument();
    expect(button.querySelector('svg.recharts-surface')).not.toBeNull();
  });

  test('an empty series ("no data yet") renders the empty state, not a broken chart', async () => {
    mockFetch({ notes: jsonResponse(200, metricBody('notes', [])) });
    renderPanel();

    expect(await screen.findByText('No data yet for this window.')).toBeInTheDocument();
    // Not rendered as a button -- nothing to expand.
    expect(screen.queryByRole('button', { name: /Average notes per user/ })).not.toBeInTheDocument();
  });

  test('a failed card fetch (e.g. 500) shows an error state with Retry, without affecting the other four charts', async () => {
    mockFetch({ notes: jsonResponse(500, {}) });
    renderPanel();

    expect(await screen.findByText('Could not load this chart.')).toBeInTheDocument();

    // The other four cards are untouched -- still rendered ready, with their
    // own expand button, not swept into the same error state.
    for (const label of ['highlights', 'logins', 'messages']) {
      await screen.findByRole('button', {
        name: `Line chart: Average ${label} per user, trailing 30 days. Press to expand.`,
      });
    }
    await screen.findByRole('button', { name: /website visits/i });

    // Only one error card, four ready ones.
    const readyButtons = await screen.findAllByRole('button', { name: /Press to expand\.?$/ });
    expect(readyButtons.length).toBe(4);
  });

  test('clicking Retry after a failed load re-fetches only that card\'s endpoint', async () => {
    let notesCallCount = 0;
    global.fetch = vi.fn((url) => {
      if (url.endsWith('/notes')) {
        notesCallCount += 1;
        if (notesCallCount === 1) return Promise.resolve(jsonResponse(500, {}));
        return Promise.resolve(jsonResponse(200, metricBody('notes')));
      }
      return Promise.resolve(jsonResponse(200, metricBody(url.split('/').pop())));
    });

    renderPanel();
    await screen.findByText('Could not load this chart.');

    fireEvent.click(screen.getByRole('button', { name: /retry/i }));

    await waitFor(() => expect(notesCallCount).toBe(2));
    expect(
      await screen.findByRole('button', {
        name: 'Line chart: Average notes per user, trailing 30 days. Press to expand.',
      })
    ).toBeInTheDocument();
  });

  test('a 401 from any card\'s fetch redirects to /signin', async () => {
    mockFetch({ notes: jsonResponse(401, { detail: 'Unauthorized' }) });
    renderPanel();

    expect(await screen.findByText('Sign In Page')).toBeInTheDocument();
  });

  test('a 403 (authenticated, non-admin) from any card\'s fetch redirects home', async () => {
    mockFetch({ notes: jsonResponse(403, { detail: 'Forbidden' }) });
    renderPanel();

    expect(await screen.findByText('Home Page')).toBeInTheDocument();
  });

  test('hovering the chart shows an exact date + value tooltip (resolves the "stale = can\'t '
    + 'interact with the data" complaint)', async () => {
    mockFetch();
    renderPanel();

    const button = await screen.findByRole('button', {
      name: 'Line chart: Average notes per user, trailing 30 days. Press to expand.',
    });
    const surface = button.querySelector('svg.recharts-surface');
    expect(surface).not.toBeNull();

    fireEvent.mouseOver(surface, { clientX: 100, clientY: 100 });
    fireEvent.mouseMove(surface, { clientX: 100, clientY: 100 });

    // Scoped to this card's own button -- every chart mounts its own
    // `.recharts-tooltip-wrapper`, and an unscoped `document.querySelector`
    // would silently grab the *first* one in the page (a different,
    // still-hidden card's) rather than the one this test just hovered.
    await waitFor(() => {
      expect(button.querySelector('.recharts-tooltip-wrapper')).not.toBeNull();
    });
    const tooltipText = button.querySelector('.recharts-tooltip-wrapper').textContent;
    expect(tooltipText).toMatch(/Sep \d, 2026/);
    expect(tooltipText).toMatch(/(1\.5|2\.75) Avg per user/);
  });

  test('the visits chart renders both series with an accessible plain-text legend '
    + '(native Recharts <Legend>, per design-notes.md)', async () => {
    mockFetch();
    renderPanel();

    await screen.findByRole('button', { name: /website visits/i });
    expect(screen.getByText('Raw visits')).toBeInTheDocument();
    expect(screen.getByText(/Unique devices/)).toBeInTheDocument();
  });

  test('the visits chart tooltip shows both raw and unique values on hover', async () => {
    mockFetch();
    renderPanel();

    const button = await screen.findByRole('button', { name: /website visits/i });
    const surface = button.querySelector('svg.recharts-surface');

    fireEvent.mouseOver(surface, { clientX: 100, clientY: 100 });
    fireEvent.mouseMove(surface, { clientX: 100, clientY: 100 });

    await waitFor(() => {
      expect(button.querySelector('.recharts-tooltip-wrapper')).not.toBeNull();
    });
    const tooltipText = button.querySelector('.recharts-tooltip-wrapper').textContent;
    expect(tooltipText).toMatch(/Raw visits:/);
    expect(tooltipText).toMatch(/Unique devices/);
  });

  test('clicking a chart card opens a click-to-expand dialog with the same data, desktop path', async () => {
    desktop = true;
    mockFetch();
    renderPanel();

    const button = await screen.findByRole('button', {
      name: 'Line chart: Average notes per user, trailing 30 days. Press to expand.',
    });
    fireEvent.click(button);

    const dialog = await screen.findByRole('dialog', { name: 'Average notes per user, expanded' });
    expect(dialog).toBeInTheDocument();
    expect(dialog.className).toContain('chart-expand-panel');
    expect(dialog.querySelectorAll('svg.recharts-surface').length).toBeGreaterThan(0);
  });

  test('Escape closes the desktop expand dialog', async () => {
    desktop = true;
    mockFetch();
    renderPanel();

    const button = await screen.findByRole('button', {
      name: 'Line chart: Average notes per user, trailing 30 days. Press to expand.',
    });
    fireEvent.click(button);
    const dialog = await screen.findByRole('dialog', { name: 'Average notes per user, expanded' });

    fireEvent.keyDown(dialog, { key: 'Escape' });

    await waitFor(() => {
      expect(screen.queryByRole('dialog', { name: 'Average notes per user, expanded' })).not.toBeInTheDocument();
    });
  });

  test('the close button also dismisses the expanded chart', async () => {
    desktop = true;
    mockFetch();
    renderPanel();

    const button = await screen.findByRole('button', {
      name: 'Line chart: Average notes per user, trailing 30 days. Press to expand.',
    });
    fireEvent.click(button);
    await screen.findByRole('dialog', { name: 'Average notes per user, expanded' });

    fireEvent.click(screen.getByRole('button', { name: 'Close expanded chart' }));

    await waitFor(() => {
      expect(screen.queryByRole('dialog', { name: 'Average notes per user, expanded' })).not.toBeInTheDocument();
    });
  });

  test('on small viewports, expanding a chart uses the fullscreen mobile-overlay treatment '
    + 'instead of the centered desktop dialog (Q13 purpose-built small-viewport requirement)', async () => {
    desktop = false;
    mockFetch();
    renderPanel();

    const button = await screen.findByRole('button', {
      name: 'Line chart: Average notes per user, trailing 30 days. Press to expand.',
    });
    fireEvent.click(button);

    const dialog = await screen.findByRole('dialog', { name: 'Average notes per user, expanded' });
    expect(dialog.className).toContain('mobile-overlay');
    expect(dialog.className).toContain('open');
    expect(dialog.className).not.toContain('chart-expand-panel');
  });

  test('desktop: metric cards lay out in a 2-column grid, visits card spans both columns', async () => {
    desktop = true;
    mockFetch();
    renderPanel();

    await screen.findByRole('button', { name: /Average notes per user/ });
    // The mobile-overlay branch of ChartExpandOverlay stays permanently
    // mounted (even while closed, hidden via CSS) so its slide-up CSS
    // transition can play -- but that branch is only used when `isDesktop`
    // is false, so on desktop `getAllByText` returns exactly the one
    // visible card-label match; `[0]` is defensive/consistent with the
    // mobile variant of this same query below.
    const grid = screen.getAllByText('Average notes per user')[0].closest('div').parentElement;
    expect(grid.style.gridTemplateColumns).toBe('1fr 1fr');

    const visitsCard = screen.getAllByText('Website visits')[0].closest('div');
    expect(visitsCard.style.gridColumn).toBe('1 / -1');
  });

  test('mobile: metric cards stack in a single column', async () => {
    desktop = false;
    mockFetch();
    renderPanel();

    await screen.findByRole('button', { name: /Average notes per user/ });
    // Two matches at mobile widths: the visible card label, and the
    // permanently-mounted (but CSS-hidden while closed) mobile-overlay
    // header title for this same card -- see the comment in the desktop
    // version of this test above. The card label is first in DOM order
    // (ChartBox renders before ChartExpandOverlay in MetricChartCard's JSX).
    const grid = screen.getAllByText('Average notes per user')[0].closest('div').parentElement;
    expect(grid.style.gridTemplateColumns).toBe('1fr');
  });

  test('Refresh button re-fetches every card\'s JSON endpoint', async () => {
    mockFetch();
    renderPanel();

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(5));

    fireEvent.click(screen.getByRole('button', { name: /refresh/i }));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(10));
  });
});
