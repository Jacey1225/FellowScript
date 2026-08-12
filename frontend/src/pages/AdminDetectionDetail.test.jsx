// Tests for AdminDetectionDetail.jsx (/admin/detections/:id) -- step 9 of
// .claude/pipeline/20260811-error-debug-agent-admin-page/architecture.json:
// "agent-report display" plus this page's own independent route-guard
// behavior (must not assume AdminDetections' gate-fetch already ran, since a
// direct deep-link skips it entirely -- see the component's own docstring).
//
// Run with: cd frontend && npm test -- --run src/pages/AdminDetectionDetail.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import { message } from 'antd';
import AdminDetectionDetail from './AdminDetectionDetail.jsx';
import { downloadRemediationMarkdown } from '../lib/remediationMarkdown.js';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div data-testid="app-nav" /> }));
vi.mock('../lib/remediationMarkdown.js', () => ({
  downloadRemediationMarkdown: vi.fn(),
}));

const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
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

function makeDetection(overrides = {}) {
  return {
    id: 'det-1',
    log_group_name: '/fellowscript/app',
    matched_signal: 'Traceback',
    message: 'ValueError: something broke in the widget handler',
    log_stream_name: 'stream-1',
    event_timestamp: '2026-08-10T12:00:00Z',
    detected_at: '2026-08-10T12:00:05Z',
    status: 'new',
    context: { nearby_lines: ['line 1', 'line 2'] },
    ...overrides,
  };
}

function makeReport(overrides = {}) {
  return {
    id: 'report-1',
    detection_id: 'det-1',
    root_cause: 'A None value was passed where a widget ID was expected.',
    remediation_narrative: 'Validate the widget ID before dispatch and return a 400 on missing input.',
    generated_at: '2026-08-10T12:05:00Z',
    model: 'deepseek-chat',
    ...overrides,
  };
}

function renderPage({ user = ADMIN_USER, initialEntries = ['/admin/detections/det-1'] } = {}) {
  mockUseAuth.mockReturnValue({ user });
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      <Routes>
        <Route path="/admin/detections/:id" element={<AdminDetectionDetail />} />
        <Route path="/admin" element={<div>Admin List Page</div>} />
        <Route path="/signin" element={<div>Sign In Page</div>} />
        <Route path="/" element={<div>Home Page</div>} />
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  global.fetch = vi.fn();
  downloadRemediationMarkdown.mockClear();
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('AdminDetectionDetail — self-guard (independent of AdminGate/AdminDetections)', () => {
  test('401 on the detail fetch redirects to /signin', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(401, { detail: 'Unauthorized' }));
    renderPage();

    expect(await screen.findByText('Sign In Page')).toBeInTheDocument();
  });

  test('403 (authenticated, non-admin) on the detail fetch redirects home', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(403, { detail: 'Forbidden' }));
    renderPage();

    expect(await screen.findByText('Home Page')).toBeInTheDocument();
  });

  test('a direct deep-link (no prior list-page visit) still self-guards correctly', async () => {
    // Simulates navigating straight to the URL bar with no AdminDetections
    // fetch ever having run -- this route must not assume that already
    // happened.
    global.fetch.mockResolvedValueOnce(jsonResponse(401, { detail: 'Unauthorized' }));
    renderPage({ initialEntries: ['/admin/detections/some-other-id'] });

    expect(await screen.findByText('Sign In Page')).toBeInTheDocument();
    expect(global.fetch).toHaveBeenCalledWith(expect.stringContaining('/monitoring/detections/some-other-id'));
  });
});

describe('AdminDetectionDetail — not-found / error states', () => {
  test('404 shows a not-found alert with a link back to the list', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(404, { detail: 'Detection not found' }));
    renderPage();

    expect(await screen.findByText('Detection not found.')).toBeInTheDocument();
  });

  test('a generic failure shows a retry-able error alert', async () => {
    global.fetch.mockRejectedValueOnce(new TypeError('network down'));
    renderPage();

    expect(await screen.findByText('Could not load this detection.')).toBeInTheDocument();

    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    fireEvent.click(screen.getByText('Retry'));

    await screen.findByText(/ValueError: something broke/);
  });
});

describe('AdminDetectionDetail — error + context + report display', () => {
  test('renders the raw error message, metadata, and toggles the collapsible raw context', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderPage();

    await screen.findByText(/ValueError: something broke/);
    expect(screen.getByText('/fellowscript/app')).toBeInTheDocument();
    expect(screen.getByText('Traceback')).toBeInTheDocument();
    expect(screen.getByText('stream-1')).toBeInTheDocument();

    // Raw context is collapsed by default.
    expect(screen.queryByText(/nearby_lines/)).not.toBeInTheDocument();

    fireEvent.click(screen.getByText('Show raw context'));
    expect(await screen.findByText(/nearby_lines/)).toBeInTheDocument();

    // No report yet.
    expect(await screen.findByText('No report generated yet.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Generate Report/ })).toBeInTheDocument();
  });

  test('renders an existing agent report (root cause + remediation narrative)', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection({ status: 'diagnosed' })))
      .mockResolvedValueOnce(jsonResponse(200, makeReport()));
    renderPage();

    expect(await screen.findByText(/A None value was passed/)).toBeInTheDocument();
    expect(screen.getByText(/Validate the widget ID before dispatch/)).toBeInTheDocument();
    expect(screen.getByLabelText('Diagnosed')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /^Rerun$/ })).toBeInTheDocument();
  });
});

describe('AdminDetectionDetail — Generate/Rerun button state machine', () => {
  test('idle -> loading -> success replaces the report in place and flips the status dot', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderPage();
    await screen.findByText('No report generated yet.');
    expect(screen.getByLabelText('New')).toBeInTheDocument();

    const successSpy = vi.spyOn(message, 'success');

    let resolvePost;
    global.fetch.mockReturnValueOnce(new Promise((res) => { resolvePost = res; }));

    const genBtn = screen.getByRole('button', { name: /Generate Report/ });
    fireEvent.click(genBtn);

    // In-flight: button shows the loading label.
    expect(await screen.findByText('Generating…')).toBeInTheDocument();

    resolvePost(jsonResponse(200, makeReport()));

    await screen.findByText(/A None value was passed/);
    expect(successSpy).toHaveBeenCalledWith('Report generated.');
    expect(screen.getByLabelText('Diagnosed')).toBeInTheDocument();
    // antd's Button loading-icon exit transition can leave a stray "loading"
    // labelled icon in the DOM briefly under jsdom (no real animationend), so
    // match on the visible label text rather than the full accessible name.
    expect(screen.getByRole('button', { name: /Rerun/ })).toBeInTheDocument();

    const postCall = global.fetch.mock.calls.find(([, opts]) => opts && opts.method === 'POST');
    expect(postCall[0]).toContain('/monitoring/detections/det-1/report');
  });

  test('429 shows the cooldown warning (not a silent failure) and disables the button during cooldown', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderPage();
    await screen.findByText('No report generated yet.');

    const warningSpy = vi.spyOn(message, 'warning');
    global.fetch.mockResolvedValueOnce(jsonResponse(429, { detail: 'Too Many Requests' }, { 'Retry-After': '30' }));

    const genBtn = screen.getByRole('button', { name: /Generate Report/ });
    fireEvent.click(genBtn);

    await waitFor(() => expect(warningSpy).toHaveBeenCalledWith(
      "You're regenerating reports too quickly — try again in about a minute."
    ));

    // The button reflects a cooldown countdown rather than failing silently,
    // and is disabled while the cooldown is active.
    const cooldownBtn = await screen.findByRole('button', { name: /Try again in \d+s/ });
    expect(cooldownBtn).toBeDisabled();
    // No inline error alert -- this is a warning/cooldown state, not an error state.
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  test('502 shows a real inline error state (not a silent failure) with a working Try Again', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderPage();
    await screen.findByText('No report generated yet.');

    global.fetch.mockResolvedValueOnce(jsonResponse(502, { detail: 'The debugging agent could not reach OpenRouter.' }));

    fireEvent.click(screen.getByRole('button', { name: /Generate Report/ }));

    expect(await screen.findByText('The debugging agent could not reach OpenRouter.')).toBeInTheDocument();
    expect(screen.getByRole('alert')).toBeInTheDocument();

    // Try Again from the inline alert retries the POST.
    global.fetch.mockResolvedValueOnce(jsonResponse(200, makeReport()));
    fireEvent.click(screen.getByRole('button', { name: 'Try Again' }));

    await screen.findByText(/A None value was passed/);
  });

  test('404 on rerun redirects to /admin with an error toast', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderPage();
    await screen.findByText('No report generated yet.');

    const errorSpy = vi.spyOn(message, 'error');
    global.fetch.mockResolvedValueOnce(jsonResponse(404, { detail: 'Detection not found' }));

    fireEvent.click(screen.getByRole('button', { name: /Generate Report/ }));

    expect(await screen.findByText('Admin List Page')).toBeInTheDocument();
    expect(errorSpy).toHaveBeenCalledWith('This detection no longer exists.');
  });
});

describe('AdminDetectionDetail — Download Remediation Instructions button', () => {
  test('clicking it fires the audit POST and calls the download utility with this component\'s current detection/report state', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection({ status: 'diagnosed' })))
      .mockResolvedValueOnce(jsonResponse(200, makeReport()));
    renderPage();

    await screen.findByText(/A None value was passed/);

    global.fetch.mockResolvedValueOnce(jsonResponse(200, { logged: true }));
    fireEvent.click(screen.getByRole('button', { name: /Download Remediation Instructions/ }));

    // Audit call fired at the correct URL with a POST.
    await waitFor(() => {
      const auditCall = global.fetch.mock.calls.find(
        ([url]) => typeof url === 'string' && url.includes('/report/download-audit')
      );
      expect(auditCall).toBeTruthy();
      expect(auditCall[1]).toMatchObject({ method: 'POST' });
    });

    // Download utility called synchronously with this component's own
    // in-state detection + report (not stale/placeholder data).
    expect(downloadRemediationMarkdown).toHaveBeenCalledTimes(1);
    const [detectionArg, reportArg] = downloadRemediationMarkdown.mock.calls[0];
    expect(detectionArg).toMatchObject({ id: 'det-1', status: 'diagnosed' });
    expect(reportArg).toMatchObject({ id: 'report-1', root_cause: expect.stringContaining('None value') });
  });

  test('button stays enabled and downloads an error-only file when no report exists yet', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderPage();

    await screen.findByText('No report generated yet.');

    const downloadBtn = screen.getByRole('button', { name: /Download Remediation Instructions/ });
    expect(downloadBtn).not.toBeDisabled();

    global.fetch.mockResolvedValueOnce(jsonResponse(200, { logged: true }));
    fireEvent.click(downloadBtn);

    expect(downloadRemediationMarkdown).toHaveBeenCalledTimes(1);
    const [detectionArg, reportArg] = downloadRemediationMarkdown.mock.calls[0];
    expect(detectionArg).toMatchObject({ id: 'det-1' });
    expect(reportArg).toBeNull();
  });

  test('a failed/rejected audit call does not prevent the download or throw an unhandled error', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection({ status: 'diagnosed' })))
      .mockResolvedValueOnce(jsonResponse(200, makeReport()));
    renderPage();
    await screen.findByText(/A None value was passed/);

    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    global.fetch.mockRejectedValueOnce(new TypeError('network down'));

    expect(() => {
      fireEvent.click(screen.getByRole('button', { name: /Download Remediation Instructions/ }));
    }).not.toThrow();

    // The download itself is not blocked on (or gated by) the audit call --
    // it's called synchronously in the same click handler regardless.
    expect(downloadRemediationMarkdown).toHaveBeenCalledTimes(1);

    // The rejected audit fetch is swallowed (caught + logged), not left as
    // an unhandled promise rejection.
    await waitFor(() => expect(consoleErrorSpy).toHaveBeenCalledWith(
      'Failed to log remediation download audit:', expect.any(Error)
    ));
  });
});
