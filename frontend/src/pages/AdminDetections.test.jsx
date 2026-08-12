// Tests for AdminDetections.jsx (/admin) -- covers:
//  - step 9 of .claude/pipeline/20260811-error-debug-agent-admin-page/architecture.json
//    ("end-to-end detection-feed rendering" + this page's own independent
//    route-guard behavior, gate-fetch IS the gate)
//  - step 3 of .claude/pipeline/20260812-admin-page-triage-console/architecture.json
//    (Direction C "Triage Console": desktop CSS-grid feed rows, mobile
//    two-line row + chip-filter strip + Time popover, mobile list-overlay
//    drawer detail)
//
// AdminDetections now branches on useIsDesktopViewport() to pick between the
// desktop grid/filter-bar layout and the mobile two-line-row/chip-strip
// layout, so every test below explicitly controls that hook via
// setDesktop(...) rather than relying on jsdom's default matchMedia stub
// (src/test/setup.js always returns matches:false, i.e. "mobile", for any
// query it hasn't been told about -- leaving this implicit silently flipped
// every "desktop" test in this file to mobile once the responsive branching
// was introduced).
//
// Run with: cd frontend && npm test -- --run src/pages/AdminDetections.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import AdminDetections from './AdminDetections.jsx';
import { API } from '../config.js';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div data-testid="app-nav" /> }));

const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));

let desktop = true;
function setDesktop(value) { desktop = value; }
vi.mock('../hooks/useIsDesktopViewport.js', () => ({
  useIsDesktopViewport: () => desktop,
}));

const ADMIN_USER = { user_id: 'admin-1', username: 'jaceysimpson' };

function jsonResponse(status, body, headers = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (k) => headers[k] ?? null },
    json: async () => body,
  };
}

function renderPage({ user = ADMIN_USER } = {}) {
  mockUseAuth.mockReturnValue({ user });
  return render(
    <MemoryRouter initialEntries={['/admin']}>
      <Routes>
        <Route path="/admin" element={<AdminDetections />} />
        <Route path="/signin" element={<div>Sign In Page</div>} />
        <Route path="/" element={<div>Home Page</div>} />
      </Routes>
    </MemoryRouter>
  );
}

function makeItem(overrides = {}) {
  return {
    id: 'det-1',
    log_group_name: '/fellowscript/app',
    matched_signal: 'Traceback',
    message: 'ValueError: something broke in the widget handler',
    event_timestamp: '2026-08-10T12:00:00Z',
    status: 'new',
    ...overrides,
  };
}

beforeEach(() => {
  global.fetch = vi.fn();
  setDesktop(true);
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('AdminDetections — self-guard (independent of AdminGate)', () => {
  test('401 from the detections fetch redirects to /signin, rendering no admin content', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(401, { detail: 'Unauthorized' }));
    renderPage();

    expect(await screen.findByText('Sign In Page')).toBeInTheDocument();
    expect(screen.queryByText('Error Detections')).not.toBeInTheDocument();
  });

  test('403 (authenticated, non-admin) redirects home, rendering no admin content', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(403, { detail: 'Forbidden' }));
    renderPage();

    expect(await screen.findByText('Home Page')).toBeInTheDocument();
    expect(screen.queryByText('Error Detections')).not.toBeInTheDocument();
  });
});

describe('AdminDetections — loading / empty / error states', () => {
  test('shows a spinner before the first fetch resolves, then the page chrome', async () => {
    let resolveFetch;
    global.fetch.mockReturnValueOnce(new Promise((res) => { resolveFetch = res; }));
    const { container } = renderPage();

    // Blank gate spinner while `checked` is still false.
    expect(container.querySelector('.ant-spin')).toBeTruthy();
    expect(screen.queryByText('Error Detections')).not.toBeInTheDocument();

    resolveFetch(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }));
    await screen.findByText('Error Detections');
  });

  test('renders the empty state when there are no matching detections', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }));
    renderPage();

    expect(await screen.findByText('No error detections match these filters.')).toBeInTheDocument();
    // No active filters yet, so no "Clear filters" affordance.
    expect(screen.queryByText('Clear filters')).not.toBeInTheDocument();
  });

  test('renders an error state with a working Retry on fetch failure', async () => {
    global.fetch.mockRejectedValueOnce(new TypeError('Failed to fetch'));
    renderPage();

    expect(await screen.findByText('Could not reach the server.')).toBeInTheDocument();

    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [makeItem()], total: 1, limit: 20, offset: 0 }));
    fireEvent.click(screen.getByText('Retry'));

    await screen.findByText(/ValueError: something broke/);
    expect(global.fetch).toHaveBeenCalledTimes(2);
  });

  test('renders a generic error state on a non-ok, non-401/403 response', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(500, { detail: 'boom' }));
    renderPage();

    expect(await screen.findByText('Could not load detections.')).toBeInTheDocument();
  });
});

describe('AdminDetections — desktop (>1024px) feed', () => {
  test('renders grid rows with the fixed Direction C column layout and all fields, navigating to the detail route on click', async () => {
    setDesktop(true);
    global.fetch.mockResolvedValueOnce(
      jsonResponse(200, {
        items: [makeItem(), makeItem({ id: 'det-2', log_group_name: '/fellowscript/nginx/error', matched_signal: '5xx', message: 'Upstream timeout', status: 'diagnosed' })],
        total: 2, limit: 20, offset: 0,
      })
    );

    function Wrapper() {
      mockUseAuth.mockReturnValue({ user: ADMIN_USER });
      return (
        <MemoryRouter initialEntries={['/admin']}>
          <Routes>
            <Route path="/admin" element={<AdminDetections />} />
            <Route path="/admin/detections/:id" element={<div>Detail Page</div>} />
          </Routes>
        </MemoryRouter>
      );
    }
    render(<Wrapper />);

    await screen.findByText('/fellowscript/app');
    expect(screen.getByText('Traceback')).toBeInTheDocument();
    expect(screen.getByText(/ValueError: something broke/)).toBeInTheDocument();
    expect(screen.getByText('/fellowscript/nginx/error')).toBeInTheDocument();
    expect(screen.getByText('Upstream timeout')).toBeInTheDocument();

    // "Diagnosed" row's status dot has an accessible label distinct from "New"
    // -- status is dot+label, never color alone.
    expect(screen.getByLabelText('Diagnosed')).toBeInTheDocument();
    expect(screen.getByLabelText('New')).toBeInTheDocument();

    // Direction C's fixed-column CSS Grid, tightened padding, applied to a
    // real <button style="display:grid">, not a div onClick.
    const row = screen.getByText(/ValueError: something broke/).closest('button');
    expect(row.tagName).toBe('BUTTON');
    expect(row.style.display).toBe('grid');
    expect(row.style.gridTemplateColumns).toBe('28px 160px 140px 130px 1fr 20px');
    expect(row.style.columnGap).toBe('0.75rem');
    expect(row.style.padding).toBe('0.6rem 1.1rem');

    fireEvent.click(row);
    await screen.findByText('Detail Page');
  });

  test('does not render the mobile chip-filter strip', async () => {
    setDesktop(true);
    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [makeItem()], total: 1, limit: 20, offset: 0 }));
    renderPage();
    await screen.findByText('Error Detections');

    expect(screen.queryByRole('group', { name: 'Filter by log group and time range' })).not.toBeInTheDocument();
  });
});

describe('AdminDetections — desktop filters (Select + RangePicker) round-trip', () => {
  test('selecting a log group refetches with log_group_name set and offset reset to 0', async () => {
    setDesktop(true);
    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [makeItem()], total: 1, limit: 20, offset: 0 }));
    const { container } = renderPage();
    await screen.findByText('Error Detections');

    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }));

    const selectors = container.querySelectorAll('.ant-select-selector');
    fireEvent.mouseDown(selectors[0]);
    const option = await screen.findByTitle('/fellowscript/nginx/access');
    fireEvent.click(option);

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(2));
    const secondCallUrl = global.fetch.mock.calls[1][0];
    expect(secondCallUrl).toContain('log_group_name=%2Ffellowscript%2Fnginx%2Faccess');
    expect(secondCallUrl).toContain('offset=0');
  });

  test('selecting a time range refetches with start_time/end_time set', async () => {
    setDesktop(true);
    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [makeItem()], total: 1, limit: 20, offset: 0 }));
    const { container } = renderPage();
    await screen.findByText('Error Detections');

    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }));

    const rangeInputs = container.querySelectorAll('.ant-picker-input input');
    fireEvent.mouseDown(rangeInputs[0]);
    fireEvent.focus(rangeInputs[0]);
    fireEvent.change(rangeInputs[0], { target: { value: '2026-01-01 00:00:00' } });
    fireEvent.keyDown(rangeInputs[0], { key: 'Enter', code: 'Enter' });
    fireEvent.change(rangeInputs[1], { target: { value: '2026-01-02 00:00:00' } });
    fireEvent.keyDown(rangeInputs[1], { key: 'Enter', code: 'Enter' });

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(2));
    const secondCallUrl = global.fetch.mock.calls[1][0];
    expect(secondCallUrl).toContain('start_time=');
    expect(secondCallUrl).toContain('end_time=');
  });
});

describe('AdminDetections — pagination (desktop)', () => {
  test('changing page refetches with the correct offset', async () => {
    setDesktop(true);
    global.fetch.mockResolvedValueOnce(
      jsonResponse(200, { items: [makeItem()], total: 45, limit: 20, offset: 0 })
    );
    renderPage();
    await screen.findByText('Error Detections');
    // showTotal renders "1–20 of 45"
    expect(await screen.findByText('1–20 of 45')).toBeInTheDocument();

    global.fetch.mockResolvedValueOnce(
      jsonResponse(200, { items: [makeItem({ id: 'det-page2' })], total: 45, limit: 20, offset: 20 })
    );

    fireEvent.click(screen.getByTitle('2'));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(2));
    const secondCallUrl = global.fetch.mock.calls[1][0];
    expect(secondCallUrl).toContain('offset=20');
  });
});

describe('AdminDetections — mobile (≤1024px) two-line row', () => {
  test('renders line 1 (status dot + log-group tag + relative timestamp) and line 2 (demoted signal chip + message), min 64px row height, no CSS-grid columns', async () => {
    setDesktop(false);
    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [makeItem({ status: 'diagnosed' })], total: 1, limit: 20, offset: 0 }));
    renderPage();

    await screen.findByText('/fellowscript/app');
    expect(screen.getByLabelText('Diagnosed')).toBeInTheDocument();
    expect(screen.getByText('Traceback')).toBeInTheDocument();
    expect(screen.getByText(/ValueError: something broke/)).toBeInTheDocument();

    const row = screen.getByText(/ValueError: something broke/).closest('button');
    expect(row.tagName).toBe('BUTTON');
    expect(row.style.display).toBe('flex'); // two-line stacked row, not the desktop grid
    expect(row.style.minHeight).toBe('64px');
  });

  test('tapping a row opens the DetectionDetailOverlay instead of navigating, and the URL stays /admin (no history.pushState)', async () => {
    setDesktop(false);
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, { items: [makeItem()], total: 1, limit: 20, offset: 0 }))
      // DetectionDetailOverlay's own fetches once opened
      .mockResolvedValueOnce(jsonResponse(200, { id: 'det-1', log_group_name: '/fellowscript/app', matched_signal: 'Traceback', message: 'ValueError: something broke in the widget handler', event_timestamp: '2026-08-10T12:00:00Z', detected_at: '2026-08-10T12:00:05Z', status: 'new', context: {} }))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));

    renderPage();
    await screen.findByText(/ValueError: something broke/);

    fireEvent.click(screen.getByText(/ValueError: something broke/).closest('button'));

    // Overlay opens as a fullscreen dialog on top of the still-mounted list --
    // not a route navigation.
    const dialog = await screen.findByRole('dialog', { name: 'Detection detail' });
    expect(dialog.className).toContain('open');

    // List stays mounted underneath (scroll position preserved -- nothing
    // unmounted/re-fetched for the list itself).
    expect(screen.getByText('Error Detections')).toBeInTheDocument();

    // No route navigation happened: still on /admin.
    expect(screen.queryByText('Detail Page')).not.toBeInTheDocument();
  });

  test('close control dismisses the overlay back to the list and focus returns to the triggering row', async () => {
    setDesktop(false);
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, { items: [makeItem()], total: 1, limit: 20, offset: 0 }))
      .mockResolvedValueOnce(jsonResponse(200, { id: 'det-1', log_group_name: '/fellowscript/app', matched_signal: 'Traceback', message: 'ValueError: something broke in the widget handler', event_timestamp: '2026-08-10T12:00:00Z', detected_at: '2026-08-10T12:00:05Z', status: 'new', context: {} }))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));

    renderPage();
    await screen.findByText(/ValueError: something broke/);
    const row = screen.getByText(/ValueError: something broke/).closest('button');
    row.focus();
    fireEvent.click(row);

    await screen.findByRole('dialog', { name: 'Detection detail' });
    fireEvent.click(screen.getByRole('button', { name: 'Close detection detail' }));

    await waitFor(() => {
      const dialog = screen.getByRole('dialog', { name: 'Detection detail' });
      expect(dialog.className).not.toContain('open');
    });
    expect(document.activeElement).toBe(row);
  });
});

describe('AdminDetections — mobile chip-filter strip', () => {
  test('renders "All" first/active by default plus a pill per LOG_GROUPS entry, all real <button>s', async () => {
    setDesktop(false);
    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }));
    renderPage();
    await screen.findByText('Error Detections');

    const strip = screen.getByRole('group', { name: 'Filter by log group and time range' });
    const buttons = strip.querySelectorAll('button');
    // All + 5 LOG_GROUPS + Time pill = 7 real buttons.
    expect(buttons.length).toBe(7);
    expect(buttons[0]).toHaveTextContent('All');
    expect(buttons[0].getAttribute('aria-pressed')).toBe('true');
    expect(screen.getByTitle('/fellowscript/nginx/access')).toBeInTheDocument();
    expect(screen.getByTitle('/fellowscript/nginx/error')).toBeInTheDocument();
    expect(screen.getByTitle('/fellowscript/syslog')).toBeInTheDocument();
    expect(screen.getByTitle('/fellowscript/auth')).toBeInTheDocument();
    expect(screen.getByTitle('/fellowscript/app')).toBeInTheDocument();
  });

  test('clicking a log-group chip filters and round-trips log_group_name to the same endpoint/params the desktop Select would send', async () => {
    setDesktop(false);
    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }));
    renderPage();
    await screen.findByText('Error Detections');

    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }));
    fireEvent.click(screen.getByTitle('/fellowscript/nginx/access'));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(2));
    const secondCallUrl = global.fetch.mock.calls[1][0];
    expect(secondCallUrl).toContain(`${API}/monitoring/detections?`);
    expect(secondCallUrl).toContain('log_group_name=%2Ffellowscript%2Fnginx%2Faccess');
    expect(secondCallUrl).toContain('offset=0');
    expect(screen.getByTitle('/fellowscript/nginx/access').getAttribute('aria-pressed')).toBe('true');
  });

  test('the Time pill opens an anchored Popover whose From/To pickers round-trip start_time/end_time, and closing it returns focus to the pill', async () => {
    setDesktop(false);
    global.fetch.mockResolvedValueOnce(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }));
    renderPage();
    await screen.findByText('Error Detections');

    const timePill = screen.getByRole('button', { name: /^Time:/ });
    timePill.focus();
    fireEvent.click(timePill);

    // Popover opens with From/To DatePicker fields (existing pattern, reused).
    await screen.findByText('From');
    expect(screen.getByText('To')).toBeInTheDocument();

    // The Popover's content renders into a portal appended to document.body
    // (antd default), not inside the render container, so query from the
    // document rather than the local `container`.
    // Unlike the desktop RangePicker (a single control that only ever emits
    // a complete [from, to] pair), the mobile Popover uses two independent
    // DatePicker fields, each firing its own onChange as soon as it's set.
    // Setting "From" alone therefore triggers an intermediate fetch of its
    // own -- and since fetchDetections only attaches start_time/end_time
    // once *both* dateRange[0] and dateRange[1] are present, that
    // intermediate fetch actually drops back to no time filter at all until
    // "To" is also set. Documented here as a real (non-blocking) UX quirk
    // of this Direction C mobile pattern, not assumed away: three fetches
    // fire in total (initial + "From" alone + "From"+"To" complete), and
    // only the final one carries both time params.
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }))
      .mockResolvedValueOnce(jsonResponse(200, { items: [], total: 0, limit: 20, offset: 0 }));
    const dateInputs = document.body.querySelectorAll('.ant-picker-input input');
    fireEvent.mouseDown(dateInputs[0]);
    fireEvent.focus(dateInputs[0]);
    fireEvent.change(dateInputs[0], { target: { value: '2026-01-01 00:00:00' } });
    fireEvent.keyDown(dateInputs[0], { key: 'Enter', code: 'Enter' });

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(2));
    // Intermediate fetch (From set, To not yet set) has no time params --
    // the quirk described above.
    expect(global.fetch.mock.calls[1][0]).not.toContain('start_time=');

    fireEvent.change(dateInputs[1], { target: { value: '2026-01-02 00:00:00' } });
    fireEvent.keyDown(dateInputs[1], { key: 'Enter', code: 'Enter' });

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(3));
    const finalCallUrl = global.fetch.mock.calls[2][0];
    expect(finalCallUrl).toContain('start_time=');
    expect(finalCallUrl).toContain('end_time=');

    // Escape closes the popover via its focus trap and returns focus to the
    // trigger pill (design-notes.md §4: overlays/Popovers return focus to
    // the trigger on close).
    fireEvent.keyDown(screen.getByText('From').closest('div'), { key: 'Escape' });
    // antd's Popover keeps its content mounted through a CSS leave-transition
    // (rc-motion) rather than unmounting synchronously, and jsdom never fires
    // transitionend, so the "From" text itself never actually leaves the DOM
    // in this environment -- same class of quirk as the .mobile-overlay
    // `open`-class check elsewhere in this file. Assert on the closed state
    // via the popover's own leave classes/pointer-events instead of DOM
    // removal.
    await waitFor(() => {
      const popover = screen.getByText('From').closest('.ant-popover');
      expect(popover.className).toContain('leave');
      expect(popover.style.pointerEvents).toBe('none');
    });
    expect(document.activeElement).toBe(timePill);
  });
});
