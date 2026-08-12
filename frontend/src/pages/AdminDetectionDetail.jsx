import React, { useEffect, useState, useCallback } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { Layout, Typography, Spin, Alert, Tag, Button, Collapse, message } from 'antd';
import { LeftOutlined, CheckCircleFilled, DownloadOutlined } from '@ant-design/icons';
import dayjs from 'dayjs';
import utc from 'dayjs/plugin/utc';
import relativeTime from 'dayjs/plugin/relativeTime';
import AppNav from '../components/AppNav.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { API } from '../config.js';
import { fsTheme } from '../theme.js';
import { downloadRemediationMarkdown } from '../lib/remediationMarkdown.js';

dayjs.extend(utc);
dayjs.extend(relativeTime);

const { Content } = Layout;
const { Title, Text, Paragraph } = Typography;

const CARD_STYLE = {
  background: 'rgba(6,4,1,0.88)',
  border: '1px solid rgba(200,134,26,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 14,
  marginBottom: '1.5rem',
};

const MONO_BLOCK_STYLE = {
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: '0.78rem',
  color: 'rgba(244,228,193,0.75)',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
  lineHeight: 1.6,
  maxHeight: 360,
  overflowY: 'auto',
  userSelect: 'text',
  background: 'rgba(0,0,0,0.25)',
  border: '1px solid rgba(200,134,26,0.1)',
  borderRadius: 8,
  padding: '0.75rem 0.9rem',
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

const SECTION_LABEL_STYLE = {
  fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em',
  textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)',
};

export default function AdminDetectionDetail() {
  const { id } = useParams();
  const { user } = useAuth();
  const navigate = useNavigate();

  // Gate: this route's own GET /monitoring/detections/{id} fetch is the
  // check -- it must not assume the list page's gate already ran (a direct
  // deep-link skips it entirely). See design-notes.md §1 / AdminGate.jsx.
  const [checked, setChecked] = useState(false);

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

  const fetchDetection = useCallback(async () => {
    if (!user) return;
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
    } finally {
      setChecked(true);
    }
  }, [user, id, navigate]);

  const fetchReport = useCallback(async () => {
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

  useEffect(() => { fetchDetection(); }, [fetchDetection]);
  useEffect(() => { if (detectionState === 'ready') fetchReport(); }, [detectionState, fetchReport]);

  // Cooldown countdown after a 429, purely a client-side nicety on top of
  // the server-side rate limiter (which remains the real enforcement).
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
        navigate('/admin', { replace: true });
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

  // Blank page + spinner until the gate-fetch resolves.
  if (!checked) {
    return (
      <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Spin size="large" />
      </div>
    );
  }

  // Fire-and-forget audit call per architecture's decision: the download
  // itself is assembled entirely client-side from state already in hand, so
  // it must not block on (or fail because of) the audit endpoint. Errors are
  // swallowed with a console log rather than surfaced to the admin, since
  // the file they actually asked for still downloads either way.
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
    <Layout style={{ minHeight: '100vh', background: 'transparent' }}>
      <AppNav />

      <Content style={{ paddingTop: 'calc(var(--nav-h) + 2.5rem)', paddingBottom: '5rem', paddingLeft: '2rem', paddingRight: '2rem', maxWidth: 780, margin: '0 auto', width: '100%' }}>

        <Link to="/admin" style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(200,134,26,0.7)', textDecoration: 'none', marginBottom: '1.25rem' }}>
          <LeftOutlined style={{ fontSize: '0.65rem' }} /> Back to Detections
        </Link>

        {detectionState === 'loading' && (
          <div style={{ textAlign: 'center', padding: '3rem' }}><Spin size="large" /></div>
        )}

        {detectionState === 'notfound' && (
          <Alert
            type="error"
            showIcon
            message="Detection not found."
            action={<Link to="/admin"><Button size="small">Back to Detections</Button></Link>}
            style={{ borderRadius: 8 }}
          />
        )}

        {detectionState === 'error' && (
          <Alert
            type="error"
            showIcon
            message="Could not load this detection."
            action={<Button size="small" onClick={fetchDetection}>Retry</Button>}
            style={{ borderRadius: 8 }}
          />
        )}

        {detectionState === 'ready' && detection && (
          <>
            {/* Header: status + tags */}
            <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', marginBottom: '1.5rem', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
              <StatusDot status={detection.status} />
              <Tag>{detection.log_group_name}</Tag>
              <Tag>{detection.matched_signal}</Tag>
            </div>

            {/* The Error */}
            <div style={{ ...CARD_STYLE, padding: '1.25rem 1.4rem', animationDelay: '0.08s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
              <Text style={{ ...SECTION_LABEL_STYLE, display: 'block', marginBottom: '0.9rem' }}>The Error</Text>

              <div style={MONO_BLOCK_STYLE}>{detection.message}</div>

              <div style={{ display: 'flex', flexWrap: 'wrap', gap: '1.5rem', marginTop: '1rem' }}>
                {detection.log_stream_name && (
                  <div>
                    <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.62rem', letterSpacing: '0.1em', textTransform: 'uppercase', color: 'rgba(244,228,193,0.35)', display: 'block' }}>Log Stream</Text>
                    <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.7)' }}>{detection.log_stream_name}</Text>
                  </div>
                )}
                <div>
                  <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.62rem', letterSpacing: '0.1em', textTransform: 'uppercase', color: 'rgba(244,228,193,0.35)', display: 'block' }}>Event Time</Text>
                  <Text title={dayjs.utc(detection.event_timestamp).toISOString()} style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.7)' }}>
                    {dayjs(detection.event_timestamp).local().format('MMM D, h:mm A')}
                  </Text>
                </div>
                <div>
                  <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.62rem', letterSpacing: '0.1em', textTransform: 'uppercase', color: 'rgba(244,228,193,0.35)', display: 'block' }}>Detected At</Text>
                  <Text title={dayjs.utc(detection.detected_at).toISOString()} style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.7)' }}>
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

            {/* Debugging Agent Report */}
            <div style={{ ...CARD_STYLE, padding: '1.25rem 1.4rem', animationDelay: '0.16s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '1rem' }}>
                <Text style={SECTION_LABEL_STYLE}>Debugging Agent Report</Text>
                <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                  <Button
                    size="small"
                    icon={<DownloadOutlined />}
                    onClick={handleDownloadRemediation}
                  >
                    Download Remediation Instructions
                  </Button>
                  <Button
                    size="small"
                    loading={reportSaving}
                    disabled={rerunDisabled}
                    onClick={handleGenerateReport}
                  >
                    {actionLabel}
                  </Button>
                </div>
              </div>

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
          </>
        )}
      </Content>
    </Layout>
  );
}
