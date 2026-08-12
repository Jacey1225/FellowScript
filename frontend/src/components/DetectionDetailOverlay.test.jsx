// Tests for DetectionDetailOverlay.jsx -- Direction C's mobile-only
// "list-overlay drawer" detail pattern (step 3 of
// .claude/pipeline/20260812-admin-page-triage-console/architecture.json).
//
// This component is rendered unconditionally by AdminDetections.jsx (id/open
// are props, not route params) and reuses the existing .mobile-overlay CSS
// class plus the same fetch/report/rerun/429/502 logic AdminDetectionDetail.jsx
// already had -- duplicated rather than imported so the desktop detail route
// stays byte-for-byte untouched (confirmed zero-diff by the frontend gate).
// Tests below mirror AdminDetectionDetail.test.jsx's pattern for the shared
// fetch/rerun logic, plus new coverage for the overlay-specific surface:
// dialog semantics, the Segmented Error/Report split, focus trap (Tab-cycle +
// Escape-close + return-focus-to-trigger), and props-driven open/close
// (rather than route navigation).
//
// Run with: cd frontend && npm test -- --run src/components/DetectionDetailOverlay.test.jsx
import React, { useState } from 'react';
import { describe, test, expect, vi, beforeAll, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup, within } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import { message } from 'antd';
import DetectionDetailOverlay from './DetectionDetailOverlay.jsx';
import { downloadRemediationMarkdown } from '../lib/remediationMarkdown.js';

const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));
vi.mock('../lib/remediationMarkdown.js', () => ({
  downloadRemediationMarkdown: vi.fn(),
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

// Renders the overlay directly with fixed props, updatable via rerender --
// covers everything except the trigger-focus-return behavior, which needs a
// real sibling trigger element (see `renderWithTrigger` below).
function renderOverlay({ user = ADMIN_USER, id = 'det-1', open = true, onClose = vi.fn() } = {}) {
  mockUseAuth.mockReturnValue({ user });
  const utils = render(
    <MemoryRouter initialEntries={['/admin']}>
      <Routes>
        <Route path="/admin" element={<div>Admin List Page</div>} />
        <Route path="/signin" element={<div>Sign In Page</div>} />
        <Route path="/" element={<div>Home Page</div>} />
      </Routes>
      <DetectionDetailOverlay id={id} open={open} onClose={onClose} />
    </MemoryRouter>
  );
  return { onClose, ...utils };
}

// Renders a real trigger <button> (simulating an AdminDetections feed row)
// alongside the overlay, exactly as AdminDetections.jsx wires them together
// (row onClick sets overlayId+overlayOpen; overlay's onClose flips
// overlayOpen back to false) -- needed to test focus-trap return-to-trigger.
function renderWithTrigger({ user = ADMIN_USER, id = 'det-1' } = {}) {
  mockUseAuth.mockReturnValue({ user });

  function Harness() {
    const [open, setOpen] = useState(false);
    return (
      <>
        <button onClick={() => setOpen(true)}>Row: {id}</button>
        <DetectionDetailOverlay id={id} open={open} onClose={() => setOpen(false)} />
      </>
    );
  }

  return render(
    <MemoryRouter initialEntries={['/admin']}>
      <Harness />
    </MemoryRouter>
  );
}

// jsdom never computes real layout, so `offsetParent` always returns null --
// this silently breaks useFocusTrap.js's focusable-element visibility filter
// (`el.offsetParent !== null`) under any jsdom test that exercises the hook,
// not just this file (no production impact -- real browsers do compute
// offsetParent). Polyfilled here so the focus-trap tests below actually
// exercise the hook's auto-focus/Tab-cycle logic instead of it silently
// no-op'ing on an always-empty focusable list.
beforeAll(() => {
  Object.defineProperty(HTMLElement.prototype, 'offsetParent', {
    configurable: true,
    get() { return this.parentElement; },
  });
});

beforeEach(() => {
  global.fetch = vi.fn();
  downloadRemediationMarkdown.mockClear();
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('DetectionDetailOverlay — dialog semantics / open-close (no route navigation)', () => {
  test('renders as a labelled dialog; the "open" class only applies when the open prop is true', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));

    const { rerender } = renderOverlay({ open: false });
    const dialog = screen.getByRole('dialog', { name: 'Detection detail' });
    expect(dialog.className).not.toContain('open');

    rerender(
      <MemoryRouter initialEntries={['/admin']}>
        <Routes>
          <Route path="/admin" element={<div>Admin List Page</div>} />
        </Routes>
        <DetectionDetailOverlay id="det-1" open={true} onClose={vi.fn()} />
      </MemoryRouter>
    );

    await waitFor(() => expect(screen.getByRole('dialog', { name: 'Detection detail' }).className).toContain('open'));
    // No route navigation happens when the overlay opens -- it's a prop, not a
    // URL change, so the underlying list route stays rendered/mounted
    // underneath the whole time (list scroll position preserved).
    expect(screen.getByText('Admin List Page')).toBeInTheDocument();
  });

  test('the close button calls onClose', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    const { onClose } = renderOverlay();

    await screen.findByText(/ValueError: something broke/);
    fireEvent.click(screen.getByRole('button', { name: 'Close detection detail' }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  test('Escape closes the overlay via onClose', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    const { onClose } = renderOverlay();

    await screen.findByText(/ValueError: something broke/);
    fireEvent.keyDown(screen.getByRole('dialog', { name: 'Detection detail' }), { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});

describe('DetectionDetailOverlay — self-guard (independent of AdminDetections gate-fetch)', () => {
  test('401 on the detail fetch redirects to /signin', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(401, { detail: 'Unauthorized' }));
    renderOverlay();
    expect(await screen.findByText('Sign In Page')).toBeInTheDocument();
  });

  test('403 (authenticated, non-admin) redirects home', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(403, { detail: 'Forbidden' }));
    renderOverlay();
    expect(await screen.findByText('Home Page')).toBeInTheDocument();
  });
});

describe('DetectionDetailOverlay — not-found / error states', () => {
  test('404 shows a not-found alert whose "Back to Detections" action calls onClose', async () => {
    global.fetch.mockResolvedValueOnce(jsonResponse(404, { detail: 'Detection not found' }));
    const { onClose } = renderOverlay();

    expect(await screen.findByText('Detection not found.')).toBeInTheDocument();
    fireEvent.click(screen.getByText('Back to Detections'));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  test('a generic failure shows a retry-able error alert', async () => {
    global.fetch.mockRejectedValueOnce(new TypeError('network down'));
    renderOverlay();

    expect(await screen.findByText('Could not load this detection.')).toBeInTheDocument();

    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    fireEvent.click(screen.getByText('Retry'));

    await screen.findByText(/ValueError: something broke/);
  });
});

describe('DetectionDetailOverlay — Error panel content', () => {
  test('renders the raw error message, metadata, and toggles the collapsible raw context', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderOverlay();

    await screen.findByText(/ValueError: something broke/);
    expect(screen.getByText('/fellowscript/app')).toBeInTheDocument();
    expect(screen.getByText('Traceback')).toBeInTheDocument();
    expect(screen.getByText('stream-1')).toBeInTheDocument();
    expect(screen.getByLabelText('New')).toBeInTheDocument();

    // Mono message block wraps rather than horizontal-scrolls, and keeps text selectable.
    const messageBlock = screen.getByText(/ValueError: something broke/);
    expect(messageBlock.style.whiteSpace).toBe('pre-wrap');
    expect(messageBlock.style.userSelect).toBe('text');

    expect(screen.queryByText(/nearby_lines/)).not.toBeInTheDocument();
    fireEvent.click(screen.getByText('Show raw context'));
    expect(await screen.findByText(/nearby_lines/)).toBeInTheDocument();
  });
});

describe('DetectionDetailOverlay — Segmented Error/Report split', () => {
  test('defaults to the Error panel; switching to Report shows the report-exists status dot and content', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection({ status: 'diagnosed' })))
      .mockResolvedValueOnce(jsonResponse(200, makeReport()));
    renderOverlay();

    await screen.findByText(/ValueError: something broke/);
    // Error panel content visible by default; Report panel content not yet.
    expect(screen.queryByText(/A None value was passed/)).not.toBeInTheDocument();

    // Report tab shows a "generated" dot once its own fetch resolves with a report.
    await screen.findByLabelText('Report — generated');

    fireEvent.click(screen.getByText('Report'));
    expect(await screen.findByText(/A None value was passed/)).toBeInTheDocument();
    expect(screen.getByText(/Validate the widget ID before dispatch/)).toBeInTheDocument();
    // Error panel content is hidden while on the Report panel.
    expect(screen.queryByText(/ValueError: something broke/)).not.toBeInTheDocument();

    fireEvent.click(screen.getByText('Error'));
    expect(await screen.findByText(/ValueError: something broke/)).toBeInTheDocument();
  });

  test('shows the "not yet generated" status dot and empty state when no report exists', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderOverlay();

    await screen.findByText(/ValueError: something broke/);
    await screen.findByLabelText('Report — not yet generated');

    fireEvent.click(screen.getByText('Report'));
    expect(await screen.findByText('No report generated yet.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Generate Report/ })).toBeInTheDocument();
  });

  test('switching detections (id change) resets to the Error panel and refetches', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection({ id: 'det-1' })))
      .mockResolvedValueOnce(jsonResponse(200, makeReport()));
    const { rerender } = renderOverlay({ id: 'det-1' });

    await screen.findByText(/ValueError: something broke/);
    fireEvent.click(screen.getByText('Report'));
    await screen.findByText(/A None value was passed/);

    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection({ id: 'det-2', message: 'KeyError: missing header' })))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));

    rerender(
      <MemoryRouter initialEntries={['/admin']}>
        <Routes><Route path="/admin" element={<div>Admin List Page</div>} /></Routes>
        <DetectionDetailOverlay id="det-2" open={true} onClose={vi.fn()} />
      </MemoryRouter>
    );

    // Back on the Error panel for the newly-opened detection, not still on Report.
    expect(await screen.findByText(/KeyError: missing header/)).toBeInTheDocument();
    expect(screen.queryByText(/A None value was passed/)).not.toBeInTheDocument();
  });
});

describe('DetectionDetailOverlay — Generate/Rerun button state machine', () => {
  async function openOnReportPanel(detectionOverrides = {}) {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection(detectionOverrides)))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderOverlay();
    await screen.findByText(/ValueError: something broke/);
    fireEvent.click(screen.getByText('Report'));
    await screen.findByText('No report generated yet.');
  }

  test('idle -> loading -> success replaces the report in place and flips the status dot', async () => {
    await openOnReportPanel();
    const successSpy = vi.spyOn(message, 'success');

    let resolvePost;
    global.fetch.mockReturnValueOnce(new Promise((res) => { resolvePost = res; }));

    fireEvent.click(screen.getByRole('button', { name: /Generate Report/ }));
    expect(await screen.findByText('Generating…')).toBeInTheDocument();

    resolvePost(jsonResponse(200, makeReport()));

    await screen.findByText(/A None value was passed/);
    expect(successSpy).toHaveBeenCalledWith('Report generated.');
    expect(screen.getByRole('button', { name: /Rerun/ })).toBeInTheDocument();

    fireEvent.click(screen.getByText('Error'));
    // Status dot flips to "diagnosed" once a report exists.
    expect(screen.getByLabelText('Diagnosed')).toBeInTheDocument();

    const postCall = global.fetch.mock.calls.find(([, opts]) => opts && opts.method === 'POST');
    expect(postCall[0]).toContain('/monitoring/detections/det-1/report');
  });

  test('429 shows the cooldown warning and disables the button during cooldown', async () => {
    await openOnReportPanel();
    const warningSpy = vi.spyOn(message, 'warning');
    global.fetch.mockResolvedValueOnce(jsonResponse(429, { detail: 'Too Many Requests' }, { 'Retry-After': '30' }));

    fireEvent.click(screen.getByRole('button', { name: /Generate Report/ }));

    await waitFor(() => expect(warningSpy).toHaveBeenCalledWith(
      "You're regenerating reports too quickly — try again in about a minute."
    ));

    const cooldownBtn = await screen.findByRole('button', { name: /Try again in \d+s/ });
    expect(cooldownBtn).toBeDisabled();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  test('502 shows a real inline error state with a working Try Again', async () => {
    await openOnReportPanel();
    global.fetch.mockResolvedValueOnce(jsonResponse(502, { detail: 'The debugging agent could not reach OpenRouter.' }));

    fireEvent.click(screen.getByRole('button', { name: /Generate Report/ }));

    expect(await screen.findByText('The debugging agent could not reach OpenRouter.')).toBeInTheDocument();
    expect(screen.getByRole('alert')).toBeInTheDocument();

    global.fetch.mockResolvedValueOnce(jsonResponse(200, makeReport()));
    fireEvent.click(screen.getByRole('button', { name: 'Try Again' }));

    await screen.findByText(/A None value was passed/);
  });

  test('404 on rerun calls onClose with an error toast (overlay dismisses back to the list, no route navigation)', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    const { onClose } = renderOverlay();
    await screen.findByText(/ValueError: something broke/);
    fireEvent.click(screen.getByText('Report'));
    await screen.findByText('No report generated yet.');

    const errorSpy = vi.spyOn(message, 'error');
    global.fetch.mockResolvedValueOnce(jsonResponse(404, { detail: 'Detection not found' }));

    fireEvent.click(screen.getByRole('button', { name: /Generate Report/ }));

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(errorSpy).toHaveBeenCalledWith('This detection no longer exists.');
  });
});

describe('DetectionDetailOverlay — accessibility: real buttons, focus trap, return-focus-to-trigger', () => {
  test('every tappable element in the overlay is a real <button>, never a div onClick', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderOverlay();

    await screen.findByText(/ValueError: something broke/);
    const closeBtn = screen.getByRole('button', { name: 'Close detection detail' });
    expect(closeBtn.tagName).toBe('BUTTON');

    fireEvent.click(screen.getByText('Report'));
    const genBtn = await screen.findByRole('button', { name: /Generate Report/ });
    expect(genBtn.tagName).toBe('BUTTON');
  });

  test('opening the overlay moves focus inside it (to the close button) and closing it returns focus to the triggering row', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));

    renderWithTrigger();
    const trigger = screen.getByRole('button', { name: 'Row: det-1' });
    trigger.focus();
    expect(document.activeElement).toBe(trigger);

    fireEvent.click(trigger);

    // Focus trap moves focus into the overlay as soon as it activates.
    const closeBtn = await screen.findByRole('button', { name: 'Close detection detail' });
    await waitFor(() => expect(document.activeElement).toBe(closeBtn));

    fireEvent.click(closeBtn);

    // Focus trap deactivates and restores focus to whatever had it before
    // the trap activated -- the row button that opened the overlay.
    await waitFor(() => expect(document.activeElement).toBe(trigger));
  });

  test('Tab cycles focus within the overlay rather than escaping to the page behind it', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection({ status: 'diagnosed' })))
      .mockResolvedValueOnce(jsonResponse(200, makeReport()));

    renderWithTrigger();
    fireEvent.click(screen.getByRole('button', { name: 'Row: det-1' }));
    await screen.findByText(/ValueError: something broke/);

    const dialog = screen.getByRole('dialog', { name: 'Detection detail' });
    const focusable = within(dialog).getAllByRole('button');
    const first = focusable[0];
    const last = focusable[focusable.length - 1];

    last.focus();
    fireEvent.keyDown(dialog, { key: 'Tab' });
    expect(document.activeElement).toBe(first);

    first.focus();
    fireEvent.keyDown(dialog, { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(last);
  });
});

describe('DetectionDetailOverlay — Download Remediation Instructions button', () => {
  test('clicking it (from the Report panel) fires the audit POST and calls the download utility with this overlay\'s own current detection/report state', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection({ status: 'diagnosed' })))
      .mockResolvedValueOnce(jsonResponse(200, makeReport()));
    renderOverlay();

    await screen.findByText(/ValueError: something broke/);
    fireEvent.click(screen.getByText('Report'));
    await screen.findByText(/A None value was passed/);

    global.fetch.mockResolvedValueOnce(jsonResponse(200, { logged: true }));
    fireEvent.click(screen.getByRole('button', { name: 'Download Remediation Instructions' }));

    await waitFor(() => {
      const auditCall = global.fetch.mock.calls.find(
        ([url]) => typeof url === 'string' && url.includes('/report/download-audit')
      );
      expect(auditCall).toBeTruthy();
      expect(auditCall[1]).toMatchObject({ method: 'POST' });
    });

    expect(downloadRemediationMarkdown).toHaveBeenCalledTimes(1);
    const [detectionArg, reportArg] = downloadRemediationMarkdown.mock.calls[0];
    expect(detectionArg).toMatchObject({ id: 'det-1', status: 'diagnosed' });
    expect(reportArg).toMatchObject({ id: 'report-1', root_cause: expect.stringContaining('None value') });
  });

  test('button stays enabled and downloads an error-only file when no report exists yet', async () => {
    global.fetch
      .mockResolvedValueOnce(jsonResponse(200, makeDetection()))
      .mockResolvedValueOnce(jsonResponse(404, { detail: 'No report generated yet for this detection' }));
    renderOverlay();

    await screen.findByText(/ValueError: something broke/);
    fireEvent.click(screen.getByText('Report'));
    await screen.findByText('No report generated yet.');

    const downloadBtn = screen.getByRole('button', { name: 'Download Remediation Instructions' });
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
    renderOverlay();
    await screen.findByText(/ValueError: something broke/);
    fireEvent.click(screen.getByText('Report'));
    await screen.findByText(/A None value was passed/);

    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    global.fetch.mockRejectedValueOnce(new TypeError('network down'));

    expect(() => {
      fireEvent.click(screen.getByRole('button', { name: 'Download Remediation Instructions' }));
    }).not.toThrow();

    expect(downloadRemediationMarkdown).toHaveBeenCalledTimes(1);

    await waitFor(() => expect(consoleErrorSpy).toHaveBeenCalledWith(
      'Failed to log remediation download audit:', expect.any(Error)
    ));
  });
});
