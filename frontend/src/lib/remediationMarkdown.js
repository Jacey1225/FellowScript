// Shared, non-UI utility for the "Download Remediation Instructions" action
// on the admin detection detail view (AdminDetectionDetail.jsx desktop route
// and DetectionDetailOverlay.jsx mobile overlay). Both components fetch the
// same ErrorDetection + DetectionReport shapes into local state (per
// api/schemas/watchdog.py) -- this module turns that already-fetched data
// into a single Markdown document and triggers a client-side download of it,
// so the formatting logic isn't duplicated between the two components.
//
// Per .claude/pipeline/20260812-download-remediation-md/architecture.json:
//   - Assembly is entirely client-side; no server endpoint returns Markdown
//     or report content. (The step-1 audit endpoint just logs that a
//     download happened -- calling it is wired in alongside the button in
//     step 3, not here.)
//   - When no report exists yet, the file is still produced (button always
//     stays enabled) with an honest "no report yet" note instead of a
//     silent on-demand report-generation trigger.
//   - `context` is included in full (not truncated) in its own fenced code
//     block -- the same require_admin-gated admin already has UI access to
//     it via each component's "Show raw context" section.

/**
 * Pure formatting function: turns an ErrorDetection (+ optional
 * DetectionReport) into a single Markdown document structured for hand-off
 * into an external coding-agent chat (e.g. Claude Code).
 *
 * @param {object} detection - ErrorDetection: id, log_group_name,
 *   log_stream_name (nullable), event_timestamp, message, matched_signal,
 *   context, detected_at, status.
 * @param {object|null} report - DetectionReport (id, detection_id,
 *   root_cause, remediation_narrative, model, generated_at) or null/undefined
 *   when no report has been generated yet for this detection.
 * @returns {string} Markdown document.
 */
export function buildRemediationMarkdown(detection, report) {
  const d = detection || {};

  const contextBlock = (() => {
    try {
      return JSON.stringify(d.context ?? null, null, 2);
    } catch {
      return '"<context could not be serialized>"';
    }
  })();

  const lines = [
    `# Remediation Handoff — ${d.matched_signal || 'Detected Error'}`,
    '',
    '## Task',
    'You are being handed a production error captured by an automated log monitor, along with (if available) a diagnostic report from an internal debugging agent. Use the error record, raw context, and any diagnostic findings below to identify the root cause and implement a fix in the relevant codebase.',
    '',
    '## Error Record',
    `- **Detection ID:** ${d.id ?? 'unknown'}`,
    `- **Log Group:** ${d.log_group_name ?? 'unknown'}`,
    `- **Log Stream:** ${d.log_stream_name ?? 'n/a'}`,
    `- **Matched Signal:** ${d.matched_signal ?? 'unknown'}`,
    `- **Event Timestamp:** ${d.event_timestamp ?? 'unknown'}`,
    `- **Detected At:** ${d.detected_at ?? 'unknown'}`,
    `- **Status:** ${d.status ?? 'unknown'}`,
    '',
    '**Message:**',
    '```',
    d.message ?? '',
    '```',
    '',
    '## Raw Context',
    '```json',
    contextBlock,
    '```',
    '',
    '## Diagnostic Report',
  ];

  if (report) {
    lines.push(
      '',
      '### Root Cause',
      report.root_cause ?? '',
      '',
      '### Recommended Remediation',
      report.remediation_narrative ?? '',
      '',
      `_Generated ${report.generated_at ?? 'unknown'} via ${report.model ?? 'unknown model'}._`,
    );
  } else {
    lines.push(
      '',
      '_No diagnostic report has been generated yet for this detection. This handoff includes the raw error record only — use the "Generate Report" action in the admin console first if a root-cause/remediation writeup from the internal debugging agent is needed._',
    );
  }

  return lines.join('\n') + '\n';
}

/**
 * Builds a sane, collision-resistant filename for a detection's remediation
 * download. Sanitizes the detection id defensively (expected to be a plain
 * UUID/opaque id, but this keeps the resulting file path safe regardless).
 *
 * @param {object} detection - ErrorDetection (only `id` is required here).
 * @returns {string} e.g. "remediation-<detection_id>.md"
 */
export function buildRemediationFilename(detection) {
  const rawId = detection?.id ?? 'unknown';
  const safeId = String(rawId).replace(/[^a-zA-Z0-9._-]/g, '_');
  return `remediation-${safeId}.md`;
}

/**
 * Formats the detection + report into Markdown and triggers a client-side
 * file download via a temporary <a download> element. Does not call any
 * backend endpoint -- the step-1 audit call is wired in by the calling
 * component (AdminDetectionDetail.jsx / DetectionDetailOverlay.jsx) alongside
 * the button that invokes this.
 *
 * @param {object} detection - ErrorDetection.
 * @param {object|null} report - DetectionReport or null when none exists yet.
 */
export function downloadRemediationMarkdown(detection, report) {
  const markdown = buildRemediationMarkdown(detection, report);
  const filename = buildRemediationFilename(detection);

  const blob = new Blob([markdown], { type: 'text/markdown;charset=utf-8' });
  const url = URL.createObjectURL(blob);

  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);

  URL.revokeObjectURL(url);
}
