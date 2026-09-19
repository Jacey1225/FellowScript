// Tests for VisitTracker.jsx (task 20260918-admin-activity-monitoring): the
// client-side beacon that fires POST /activity-monitoring/visits on every
// route change, backing the admin panel's "website visits" chart.
//
// Mocks deviceId.js and desktopScope.js directly rather than exercising the
// real localStorage-backed getOrCreateDeviceId (this repo's jsdom/vitest
// environment has a pre-existing, unrelated undefined-localStorage bug --
// see deviceId.test.js's own header comment -- and this file is about
// VisitTracker's own wiring, not deviceId's fallback behavior, which already
// has its own dedicated test file).
//
// Run with: cd frontend && npm test -- --run src/components/VisitTracker.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, cleanup, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import VisitTracker from './VisitTracker.jsx';
import { API } from '../config.js';

const FAKE_DEVICE_ID = '11111111-1111-4111-8111-111111111111';
vi.mock('../lib/deviceId.js', () => ({
  getOrCreateDeviceId: () => FAKE_DEVICE_ID,
}));

let desktopApp = false;
vi.mock('../lib/desktopScope.js', () => ({
  isDesktopApp: () => desktopApp,
}));

function renderAt(path) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <VisitTracker />
      <Routes>
        <Route path="*" element={<div>page</div>} />
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  desktopApp = false;
  global.fetch = vi.fn().mockResolvedValue({ ok: true });
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('VisitTracker', () => {
  test('fires a beacon on mount with the device_id and current path', async () => {
    renderAt('/reader');

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(1));
    const [url, opts] = global.fetch.mock.calls[0];
    expect(url).toBe(`${API}/activity-monitoring/visits`);
    expect(opts.method).toBe('POST');
    expect(opts.keepalive).toBe(true);
    expect(JSON.parse(opts.body)).toEqual({ device_id: FAKE_DEVICE_ID, path: '/reader' });
  });

  test('sends only pathname, never a query string, even if the route has one', async () => {
    renderAt('/reader?foo=bar');

    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(1));
    const body = JSON.parse(global.fetch.mock.calls[0][1].body);
    expect(body.path).toBe('/reader');
    expect(body.path).not.toContain('?');
  });

  test('renders nothing (side-effect-only component)', () => {
    const { container } = renderAt('/reader');
    // VisitTracker itself renders null; only the routed page content shows.
    expect(container.textContent).toBe('page');
  });

  test('inside the Tauri desktop shell: never fires the beacon', async () => {
    desktopApp = true;
    renderAt('/reader');

    // Give any stray async effect a tick to (not) fire.
    await new Promise((r) => setTimeout(r, 0));
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test('a failed beacon request is swallowed silently -- never throws or surfaces to the page', async () => {
    global.fetch = vi.fn().mockRejectedValue(new Error('network down'));
    expect(() => renderAt('/reader')).not.toThrow();
    await waitFor(() => expect(global.fetch).toHaveBeenCalledTimes(1));
  });
});
