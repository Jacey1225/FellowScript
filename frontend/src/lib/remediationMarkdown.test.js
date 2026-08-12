// Tests for the pure, non-UI Markdown-formatting utility backing the
// "Download Remediation Instructions" feature -- step 4 of
// .claude/pipeline/20260812-download-remediation-md/architecture.json.
//
// Covers buildRemediationMarkdown (with-report + no-report/error-only
// fallback + full raw-context inclusion), buildRemediationFilename (sane,
// filesystem-safe, collision-resistant), and downloadRemediationMarkdown's
// Blob/anchor-click wiring (mocked DOM/URL primitives -- jsdom doesn't
// implement URL.createObjectURL).
//
// Run with: cd frontend && npm test -- --run src/lib/remediationMarkdown.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  buildRemediationMarkdown,
  buildRemediationFilename,
  downloadRemediationMarkdown,
} from './remediationMarkdown.js';

function makeDetection(overrides = {}) {
  return {
    id: 'det-1',
    log_group_name: '/fellowscript/app',
    log_stream_name: 'stream-1',
    matched_signal: 'Traceback',
    message: 'ValueError: something broke in the widget handler',
    event_timestamp: '2026-08-10T12:00:00Z',
    detected_at: '2026-08-10T12:00:05Z',
    status: 'diagnosed',
    context: { nearby_lines: ['line 1', 'line 2'], analyzer_notes: 'looked at recent deploys' },
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

describe('buildRemediationMarkdown — with a report', () => {
  test('includes the error message, log group/stream, matched signal, and both timestamps', () => {
    const md = buildRemediationMarkdown(makeDetection(), makeReport());

    expect(md).toContain('ValueError: something broke in the widget handler');
    expect(md).toContain('/fellowscript/app');
    expect(md).toContain('stream-1');
    expect(md).toContain('Traceback');
    expect(md).toContain('2026-08-10T12:00:00Z'); // event_timestamp
    expect(md).toContain('2026-08-10T12:00:05Z'); // detected_at
  });

  test('includes the full raw context, not truncated, in a fenced json code block', () => {
    const bigContext = {
      nearby_lines: Array.from({ length: 40 }, (_, i) => `log line number ${i}`),
      note: 'x'.repeat(500),
    };
    const md = buildRemediationMarkdown(makeDetection({ context: bigContext }), makeReport());

    expect(md).toContain('## Raw Context');
    expect(md).toContain('```json');
    // Every line and the full-length note must be present -- no truncation.
    expect(md).toContain('log line number 0');
    expect(md).toContain('log line number 39');
    expect(md).toContain('x'.repeat(500));
  });

  test('includes the root cause + remediation narrative + model/generated-at footer', () => {
    const md = buildRemediationMarkdown(makeDetection(), makeReport());

    expect(md).toContain('A None value was passed where a widget ID was expected.');
    expect(md).toContain('Validate the widget ID before dispatch and return a 400 on missing input.');
    expect(md).toContain('deepseek-chat');
    expect(md).toContain('2026-08-10T12:05:00Z');
  });

  test('does not contain the literal strings "undefined" or "null" anywhere in the output', () => {
    const md = buildRemediationMarkdown(makeDetection(), makeReport());
    expect(md).not.toMatch(/\bundefined\b/);
    expect(md).not.toMatch(/\bnull\b/);
  });
});

describe('buildRemediationMarkdown — no report yet (report is null)', () => {
  test('produces an error-only file with a clear "no report generated yet" note, no crash', () => {
    expect(() => buildRemediationMarkdown(makeDetection({ status: 'new' }), null)).not.toThrow();

    const md = buildRemediationMarkdown(makeDetection({ status: 'new' }), null);
    expect(md).toContain('No diagnostic report has been generated yet for this detection.');
    // Still contains the error record itself.
    expect(md).toContain('ValueError: something broke in the widget handler');
    // Does not fabricate report-only headers with no content behind them.
    expect(md).not.toContain('### Root Cause');
    expect(md).not.toContain('### Recommended Remediation');
  });

  test('handles report === undefined the same as null', () => {
    const md = buildRemediationMarkdown(makeDetection(), undefined);
    expect(md).toContain('No diagnostic report has been generated yet for this detection.');
  });

  test('no "undefined"/"null" leaks into the output text in the no-report case', () => {
    const md = buildRemediationMarkdown(makeDetection({ status: 'new' }), null);
    expect(md).not.toMatch(/\bundefined\b/);
    expect(md).not.toMatch(/\bnull\b/);
  });

  test('does not crash and produces sane placeholders for a bare-minimum/missing-field detection', () => {
    expect(() => buildRemediationMarkdown({}, null)).not.toThrow();
    expect(() => buildRemediationMarkdown(null, null)).not.toThrow();

    const md = buildRemediationMarkdown({}, null);
    expect(md).not.toMatch(/\bundefined\b/);
  });
});

describe('buildRemediationFilename', () => {
  test('produces "remediation-<detection_id>.md" for a normal id', () => {
    expect(buildRemediationFilename(makeDetection({ id: 'det-1' }))).toBe('remediation-det-1.md');
  });

  test('contains no illegal filesystem characters for a hostile/unexpected id', () => {
    const hostileId = '../../etc/passwd?name=<script>&*|"';
    const filename = buildRemediationFilename(makeDetection({ id: hostileId }));

    // No path separators, no reserved/illegal characters on common filesystems.
    expect(filename).not.toMatch(/[\\/:*?"<>|]/);
    expect(filename.endsWith('.md')).toBe(true);
  });

  test('is collision-resistant across two different detections', () => {
    const a = buildRemediationFilename(makeDetection({ id: 'det-aaa' }));
    const b = buildRemediationFilename(makeDetection({ id: 'det-bbb' }));
    expect(a).not.toBe(b);
  });

  test('falls back to a sane filename when detection/id is missing', () => {
    expect(buildRemediationFilename(null)).toBe('remediation-unknown.md');
    expect(buildRemediationFilename({})).toBe('remediation-unknown.md');
  });
});

describe('downloadRemediationMarkdown — Blob + anchor-click trigger', () => {
  let createObjectURLSpy;
  let revokeObjectURLSpy;
  let clickSpy;

  beforeEach(() => {
    createObjectURLSpy = vi.fn(() => 'blob:mock-url');
    revokeObjectURLSpy = vi.fn();
    global.URL.createObjectURL = createObjectURLSpy;
    global.URL.revokeObjectURL = revokeObjectURLSpy;
    clickSpy = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  test('constructs a Blob, triggers a click on a download anchor, and revokes the object URL', () => {
    downloadRemediationMarkdown(makeDetection(), makeReport());

    expect(createObjectURLSpy).toHaveBeenCalledTimes(1);
    const blobArg = createObjectURLSpy.mock.calls[0][0];
    expect(blobArg).toBeInstanceOf(Blob);
    expect(blobArg.type).toContain('text/markdown');

    expect(clickSpy).toHaveBeenCalledTimes(1);
    expect(revokeObjectURLSpy).toHaveBeenCalledWith('blob:mock-url');
  });

  test('does not throw when called with report === null (error-only download)', () => {
    expect(() => downloadRemediationMarkdown(makeDetection({ status: 'new' }), null)).not.toThrow();
    expect(createObjectURLSpy).toHaveBeenCalledTimes(1);
  });
});
