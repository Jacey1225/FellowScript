import React, { useEffect, useState, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { Typography, Spin, Alert, Tag, Button, Collapse, Segmented, message } from 'antd';
import { CloseOutlined, CheckCircleFilled, DownloadOutlined } from '@ant-design/icons';
import dayjs from 'dayjs';
import utc from 'dayjs/plugin/utc';
import relativeTime from 'dayjs/plugin/relativeTime';
import { useAuth } from '../context/AuthContext.jsx';
import { API } from '../config.js';
import { fsTheme } from '../theme.js';
import { useFocusTrap } from '../hooks/useFocusTrap.js';
import { downloadRemediationMarkdown } from '../lib/remediationMarkdown.js';

dayjs.extend(utc);
dayjs.extend(relativeTime);

const { Text, Paragraph } = Typography;

// Direction C's "list-overlay drawer" mobile detail (design-notes.md §3).
// Field-level treatment inside each panel is ported from Direction A's
// mobile detail spec / AdminDetectionDetail.jsx's existing fetch + rerun/
// generate logic, not re-derived -- this duplicates that logic (rather than
// importing it from AdminDetectionDetail.jsx) so the desktop detail route
// stays pixel-for-pixel untouched, per this task's explicit "do not modify"
// requirement for that file.

const MONO_BLOCK_STYLE = {
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: '0.78rem',
  color: 'rgba(244,228,193,0.75)',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
  lineHeight: 1.6,
  // 280px (not desktop's 360px) per design-notes.md's Direction A mobile
  // detail spec, to leave more of the viewport scrollable.
  maxHeight: 280,
  overflowY: 'auto',
  userSelect: 'text',
  background: 'rgba(0,0,0,0.25)',
  border: '1px solid rgba(200,134,26,0.1)',
  borderRadius: 8,
  padding: '0.75rem 0.9rem',
};

const METADATA_LABEL_STYLE = {
  fontFamily: "'Lora', serif", fontSize: '0.62rem', letterSpacing: '0.1em',
  textTransform: 'uppercase', color: 'rgba(244,228,193,0.35)', display: 'block',
};

const METADATA_VALUE_STYLE = {
  fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.7)',
};

const SECTION_LABEL_STYLE = {
  fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em',
  textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)',
};

const DEFAULT_COOLDOWN_MS = 15000;

function StatusDot({ status }) {
  if (status === 'diagnosed') {
    return (
      <CheckCircleFilled
        aria-label="Diagnosed"
        title="Diagnosed"
        style={{ color: fsTheme.token.colorSuccess, fontSize: '0.9rem' }}
      />
    );
  }
  return (
    <span
      aria-label="New"
      title="New"
      style={{ display: 'inline-block', width: 9, height: 9, borderRadius: '50%', background: 'var(--gold)' }}
    />
  );
}

export default function DetectionDetailOverlay({ id, open, onClose }) {
  const { user } = useAuth();
  const navigate = useNavigate();

  const containerRef = useRef(null);
  useFocusTrap(open, containerRef);

  const [detection,      setDetection]      = useState(null);
  const [detectionState, setDetectionState] = useState('loading'); // loading | ready | notfound | error

  const [report,        setReport]        = useState(null);
  const [reportLoading, setReportLoading] = useState(false);
  const [reportMissing, setReportMissing] = useState(false);

  const [reportSaving,      setReportSaving]      = useState(false);
  const [reportActionError, setReportActionError] = useState(null);
  const [cooldownUntil,     setCooldownUntil]     = useState(0);
  const [cooldownRemaining, setCooldownRemaining] = useState(0);

  const [contextOpen, setContextOpen] = useState(false);
  const [panel, setPanel] = useState('Error');

  const fetchDetection = useCallback(async () => {
    if (!user || !id) return;
    setDetectionState('loading');
    try {
      const res = await fetch(`${API}/monitoring/detections/${id}`);

      if (res.status === 401) { navigate('/signin', { replace: true }); return; }
      if (res.status === 403) { navigate('/', { replace: true }); return; }

      if (res.status === 404) { setDetectionState('notfound'); return; }
      if (!res.ok) { setDetectionState('error'); return; }

      const data = await res.json();
      setDetection(data);
      setDetectionState('ready');
    } catch {
      setDetectionState('error');
    }
  }, [user, id, navigate]);

  const fetchReport = useCallback(async () => {
    if (!id) return;
    setReportLoading(true);
    setReportMissing(false);
    try {
      const res = await fetch(`${API}/monitoring/detections/${id}/report`);
      if (res.status === 404) { setReport(null); setReportMissing(true); return; }
      if (!res.ok) { setReport(null); setReportMissing(true); return; }
      setReport(await res.json());
    } catch {
      setReport(null);
      setReportMissing(true);
    } finally {
      setReportLoading(false);
    }
  }, [id]);

  // Reset to the Error panel and re-fetch whenever a different row's detail
  // is opened (id changes) -- switching back and forth between an already-
  // open detection's own panels re-fetches nothing, matching Direction B's
  // "already fetched, no re-fetch" panel-switch behavior.
  useEffect(() => {
    if (!id) return;
    setPanel('Error');
    setContextOpen(false);
    setReportActionError(null);
    fetchDetection();
  }, [id, fetchDetection]);

  useEffect(() => { if (detectionState === 'ready') fetchReport(); }, [detectionState, fetchReport]);

  useEffect(() => {
    if (!cooldownUntil) { setCooldownRemaining(0); return; }
    const tick = () => {
      const remaining = Math.max(0, cooldownUntil - Date.now());
      setCooldownRemaining(remaining);
      if (remaining <= 0) setCooldownUntil(0);
    };
    tick();
    const interval = setInterval(tick, 500);
    return () => clearInterval(interval);
  }, [cooldownUntil]);

  const handleGenerateReport = async () => {
    setReportActionError(null);
    setReportSaving(true);
    try {
      const res = await fetch(`${API}/monitoring/detections/${id}/report`, { method: 'POST' });

      if (res.status === 429) {
        const retryAfterHeader = res.headers.get('Retry-After');
        const retryAfterMs = retryAfterHeader ? Number(retryAfterHeader) * 1000 : NaN;
        setCooldownUntil(Date.now() + (Number.isFinite(retryAfterMs) && retryAfterMs > 0 ? retryAfterMs : DEFAULT_COOLDOWN_MS));
        message.warning("You're regenerating reports too quickly — try again in about a minute.");
        return;
      }
      if (res.status === 404) {
        message.error('This detection no longer exists.');
        onClose();
        return;
      }
      if (res.status === 502) {
        const body = await res.json().catch(() => ({}));
        setReportActionError(body.detail || 'The debugging agent could not reach OpenRouter.');
        return;
      }
      if (!res.ok) {
        setReportActionError('Something went wrong generating the report.');
        return;
      }

      const data = await res.json();
      setReport(data);
      setReportMissing(false);
      setDetection(prev => (prev ? { ...prev, status: 'diagnosed' } : prev));
      message.success('Report generated.');
    } catch {
      setReportActionError('Could not reach the server.');
    } finally {
      setReportSaving(false);
    }
  };

  // Fire-and-forget audit call per architecture's decision: the download
  // itself is assembled entirely client-side from state already in hand, so
  // it must not block on (or fail because of) the audit endpoint. Errors are
  // swallowed with a console log rather than surfaced to the admin, since
  // the file they actually asked for still downloads either way. Duplicated
  // from AdminDetectionDetail.jsx's own handler rather than shared, per this
  // component's existing "do not import from the desktop route" convention.
  const handleDownloadRemediation = () => {
    fetch(`${API}/monitoring/detections/${id}/report/download-audit`, { method: 'POST' }).catch(err => {
      console.error('Failed to log remediation download audit:', err);
    });
    downloadRemediationMarkdown(detection, report);
  };

  const rerunDisabled = reportSaving || cooldownRemaining > 0;
  const actionLabel = reportSaving
    ? (report ? 'Rerunning…' : 'Generating…')
    : cooldownRemaining > 0
      ? `Try again in ${Math.ceil(cooldownRemaining / 1000)}s`
      : (report ? 'Rerun' : 'Generate Report');

  return (
    <div
      className={`mobile-overlay${open ? ' open' : ''}`}
      ref={containerRef}
      role="dialog"
      aria-modal="true"
      aria-label="Detection detail"
      onKeyDown={e => { if (e.key === 'Escape' && open) onClose(); }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.9rem 1rem', borderBottom: '1px solid rgba(200,134,26,0.15)', background: 'rgba(6,4,1,0.98)', flexShrink: 0 }}>
        <button
          onClick={onClose}
          aria-label="Close detection detail"
          style={{
            background: 'none', border: 'none', color: 'rgba(200,134,26,0.65)', cursor: 'pointer',
            fontSize: '1.1rem', width: 44, height: 44, display: 'flex', alignItems: 'center',
            justifyContent: 'center', flexShrink: 0,
          }}
        >
          <CloseOutlined />
        </button>
        <Text style={{ fontFamily: "'Playfair Display', serif", fontSize: '1rem', color: 'var(--parchment)' }}>
          Detection
        </Text>
      </div>

      <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '1rem' }}>
        {!id ? null : detectionState === 'loading' ? (
          <div style={{ textAlign: 'center', padding: '3rem' }}><Spin size="large" /></div>
        ) : detectionState === 'notfound' ? (
          <Alert
            type="error"
            showIcon
            message="Detection not found."
            action={<Button size="small" onClick={onClose}>Back to Detections</Button>}
            style={{ borderRadius: 8 }}
          />
        ) : detectionState === 'error' ? (
          <Alert
            type="error"
            showIcon
            message="Could not load this detection."
            action={<Button size="small" onClick={fetchDetection}>Retry</Button>}
            style={{ borderRadius: 8 }}
          />
        ) : detectionState === 'ready' && detection && (
          <>
            <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', marginBottom: '1rem', flexWrap: 'wrap' }}>
              <StatusDot status={detection.status} />
              <Tag>{detection.log_group_name}</Tag>
              <Tag>{detection.matched_signal}</Tag>
            </div>

            <Segmented
              block
              size="large"
              className="detection-overlay-segmented"
              value={panel}
              onChange={setPanel}
              options={[
                { label: 'Error', value: 'Error' },
                {
                  value: 'Report',
                  label: (
                    <span
                      style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}
                      aria-label={report ? 'Report — generated' : 'Report — not yet generated'}
                    >
                      Report
                      <span
                        aria-hidden="true"
                        style={{
                          width: 6, height: 6, borderRadius: '50%',
                          background: report ? fsTheme.token.colorSuccess : 'var(--gold)',
                          display: 'inline-block',
                        }}
                      />
                    </span>
                  ),
                },
              ]}
              style={{ marginBottom: '1.25rem' }}
            />

            {panel === 'Error' && (
              <div>
                <div style={MONO_BLOCK_STYLE}>{detection.message}</div>

                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0.75rem 1rem', marginTop: '1rem' }}>
                  {detection.log_stream_name && (
                    <div>
                      <Text style={METADATA_LABEL_STYLE}>Log Stream</Text>
                      <Text style={METADATA_VALUE_STYLE}>{detection.log_stream_name}</Text>
                    </div>
                  )}
                  <div>
                    <Text style={METADATA_LABEL_STYLE}>Event Time</Text>
                    <Text title={dayjs.utc(detection.event_timestamp).toISOString()} style={METADATA_VALUE_STYLE}>
                      {dayjs(detection.event_timestamp).local().format('MMM D, h:mm A')}
                    </Text>
                  </div>
                  <div>
                    <Text style={METADATA_LABEL_STYLE}>Detected At</Text>
                    <Text title={dayjs.utc(detection.detected_at).toISOString()} style={METADATA_VALUE_STYLE}>
                      {dayjs(detection.detected_at).local().format('MMM D, h:mm A')}
                    </Text>
                  </div>
                </div>

                <Collapse
                  ghost
                  activeKey={contextOpen ? ['context'] : []}
                  onChange={keys => setContextOpen(keys.includes('context'))}
                  style={{ marginTop: '1rem' }}
                  items={[{
                    key: 'context',
                    label: <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.72rem', color: 'rgba(200,134,26,0.6)' }}>Show raw context</Text>,
                    children: (
                      <div style={MONO_BLOCK_STYLE}>
                        {JSON.stringify(detection.context, null, 2)}
                      </div>
                    ),
                  }]}
                />
              </div>
            )}

            {panel === 'Report' && (
              <div>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <Text style={SECTION_LABEL_STYLE}>Debugging Agent Report</Text>
                  <Button
                    size="small"
                    icon={<DownloadOutlined />}
                    onClick={handleDownloadRemediation}
                    aria-label="Download Remediation Instructions"
                    title="Download Remediation Instructions"
                  />
                </div>
                <Button
                  size="large"
                  loading={reportSaving}
                  disabled={rerunDisabled}
                  onClick={handleGenerateReport}
                  style={{ width: '100%', marginTop: '0.6rem', marginBottom: '1.25rem' }}
                >
                  {actionLabel}
                </Button>

                {reportActionError && (
                  <Alert
                    type="error"
                    showIcon
                    message={reportActionError}
                    action={<Button size="small" onClick={handleGenerateReport} loading={reportSaving}>Try Again</Button>}
                    style={{ borderRadius: 8, marginBottom: '1rem' }}
                  />
                )}

                {reportLoading ? (
                  <div style={{ textAlign: 'center', padding: '1.5rem' }}><Spin size="small" /></div>
                ) : report ? (
                  <>
                    <div style={{ marginBottom: '1.25rem' }}>
                      <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.62rem', letterSpacing: '0.14em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.4rem' }}>
                        Root Cause
                      </Text>
                      <Paragraph style={{ fontFamily: "'Lora', serif", fontSize: '0.85rem', color: 'rgba(244,228,193,0.8)', lineHeight: 1.75, margin: 0, whiteSpace: 'pre-wrap' }}>
                        {report.root_cause}
                      </Paragraph>
                    </div>
                    <div>
                      <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.62rem', letterSpacing: '0.14em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.4rem' }}>
                        Recommended Remediation
                      </Text>
                      <Paragraph style={{ fontFamily: "'Lora', serif", fontSize: '0.85rem', color: 'rgba(244,228,193,0.8)', lineHeight: 1.75, margin: 0, whiteSpace: 'pre-wrap' }}>
                        {report.remediation_narrative}
                      </Paragraph>
                    </div>
                    <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.68rem', color: 'rgba(244,228,193,0.35)', display: 'block', marginTop: '1.25rem' }}>
                      Generated {dayjs(report.generated_at).fromNow()} via {report.model}
                    </Text>
                  </>
                ) : (
                  reportMissing && (
                    <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.35)' }}>
                      No report generated yet.
                    </Text>
                  )
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
