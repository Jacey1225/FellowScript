import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { Typography, Spin, Alert, Button } from 'antd';
import { CloseOutlined } from '@ant-design/icons';
import dayjs from 'dayjs';
import {
  ResponsiveContainer, LineChart, Line, CartesianGrid, XAxis, YAxis, Tooltip, Legend,
} from 'recharts';
import { API } from '../config.js';
import { useIsDesktopViewport } from '../hooks/useIsDesktopViewport.js';
import { useFocusTrap } from '../hooks/useFocusTrap.js';

const { Title, Text } = Typography;

// Same card treatment as AdminDetections.jsx's own CARD_STYLE (kept as a
// local copy, not a shared import, same precedent as AdminMembershipGrant.jsx
// -- this component stays fully additive and AdminDetections.jsx's own
// styling constants are never touched).
const CARD_STYLE = {
  background: 'rgba(6,4,1,0.88)',
  border: '1px solid rgba(200,134,26,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 14,
  padding: '1.5rem',
};

const EYEBROW_STYLE = {
  fontFamily: "'Lora', serif", fontSize: '0.6rem', letterSpacing: '0.32em',
  textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.2rem',
};

const CARD_LABEL_STYLE = {
  fontFamily: "'Lora', serif", fontSize: '0.68rem', letterSpacing: '0.16em',
  textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.6rem',
};

// backend's `ActivityMonitoringManager.PER_USER_METRICS` keys, in display
// order -- see api/routes/activity_monitoring.py::_METRIC_LABELS for the
// server-side title strings these mirror.
const METRICS = [
  { key: 'notes', label: 'Average notes per user' },
  { key: 'highlights', label: 'Average highlights per user' },
  { key: 'logins', label: 'Average logins per user' },
  { key: 'messages', label: 'Average messages per user' },
];

// Visits chart's two-series colors -- the exact dataviz-skill-validated pair
// from the prior task's activity_plots.py (design-notes.md §3), reused
// verbatim rather than re-derived: color AND shape/line-style both carry the
// distinction ("never color alone").
const VISITS_RAW_COLOR = '#C98A4B';
const VISITS_UNIQUE_COLOR = 'var(--gold)';

// Local copy of ChatThread.jsx's own small pure-function pattern (design-
// notes.md §6) -- this codebase's established convention for this exact
// check, not a shared import.
function prefersReducedMotion() {
  return typeof window !== 'undefined' && !!window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

// Custom dark/gold/parchment tooltip for the single-series average-per-user
// charts -- resolves the "stale = can't interact with the data" complaint
// (clarification-response.md) by surfacing the exact date + value on hover,
// not Recharts' default light-themed popup (design-notes.md §3).
function MetricTooltip({ active, payload, label, ylabel }) {
  if (!active || !payload || !payload.length) return null;
  return (
    <div
      style={{
        background: 'rgba(6,4,1,0.95)', border: '1px solid rgba(200,134,26,0.25)',
        borderRadius: 8, padding: '0.5rem 0.75rem',
      }}
    >
      <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.7rem', color: 'var(--parchment)', display: 'block' }}>
        {dayjs(label).format('MMM D, YYYY')}
      </Text>
      <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'var(--gold)', fontWeight: 600 }}>
        {payload[0].value} {ylabel}
      </Text>
    </div>
  );
}

// Same treatment for the visits chart's two series, with gold-accented color
// swatches per series (design-notes.md §3).
function VisitsTooltip({ active, payload, label }) {
  if (!active || !payload || !payload.length) return null;
  return (
    <div
      style={{
        background: 'rgba(6,4,1,0.95)', border: '1px solid rgba(200,134,26,0.25)',
        borderRadius: 8, padding: '0.5rem 0.75rem',
      }}
    >
      <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.7rem', color: 'var(--parchment)', display: 'block', marginBottom: '0.25rem' }}>
        {dayjs(label).format('MMM D, YYYY')}
      </Text>
      {payload.map(entry => (
        <div key={entry.dataKey} style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
          <span aria-hidden="true" style={{ width: 8, height: 8, borderRadius: '50%', background: entry.color, display: 'inline-block' }} />
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'var(--parchment)' }}>
            {entry.name}: <span style={{ color: 'var(--gold)', fontWeight: 600 }}>{entry.value}</span>
          </Text>
        </div>
      ))}
    </div>
  );
}

// Square dot marker for the visits chart's "Unique devices" series -- pairs
// with its dashed line so the distinction survives without relying on color
// alone (design-notes.md §3/§7).
function SquareDot({ cx, cy, stroke }) {
  const size = 6;
  return (
    <rect x={cx - size / 2} y={cy - size / 2} width={size} height={size} fill={stroke} stroke="none" />
  );
}

// Single-series average-per-user line chart, shared between the inline card
// view and the expanded overlay (design-notes.md §3/§4 -- same data, same
// colors, same time window, just larger).
function MetricLineChart({ series, ylabel, height, animate }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={series} margin={{ top: 8, right: 12, bottom: 4, left: 0 }}>
        <CartesianGrid stroke="rgba(200,134,26,0.15)" strokeDasharray="3 3" vertical={false} />
        <XAxis
          dataKey="day"
          tickFormatter={d => dayjs(d).format('MMM D')}
          stroke="rgba(200,134,26,0.4)"
          tick={{ fill: 'var(--parchment)', fontSize: 11 }}
        />
        <YAxis
          label={{ value: ylabel, angle: -90, position: 'insideLeft', fill: 'rgba(200,134,26,0.55)', fontSize: 11 }}
          stroke="rgba(200,134,26,0.4)"
          tick={{ fill: 'var(--parchment)', fontSize: 11 }}
        />
        <Tooltip content={<MetricTooltip ylabel={ylabel} />} cursor={{ stroke: 'rgba(200,134,26,0.3)' }} />
        <Line
          type="monotone"
          dataKey="value"
          stroke="var(--gold)"
          strokeWidth={2.2}
          dot={{ r: 5, fill: 'var(--gold)' }}
          activeDot={{ r: 6 }}
          isAnimationActive={animate}
          animationDuration={400}
        />
      </LineChart>
    </ResponsiveContainer>
  );
}

// Two-series visits line chart, shared between the inline card and the
// expanded overlay -- same color/shape dual-encoding as
// activity_plots.py's matplotlib version (design-notes.md §3).
function VisitsLineChart({ series, height, animate }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={series} margin={{ top: 8, right: 12, bottom: 4, left: 0 }}>
        <CartesianGrid stroke="rgba(200,134,26,0.15)" strokeDasharray="3 3" vertical={false} />
        <XAxis
          dataKey="day"
          tickFormatter={d => dayjs(d).format('MMM D')}
          stroke="rgba(200,134,26,0.4)"
          tick={{ fill: 'var(--parchment)', fontSize: 11 }}
        />
        <YAxis stroke="rgba(200,134,26,0.4)" tick={{ fill: 'var(--parchment)', fontSize: 11 }} />
        <Tooltip content={<VisitsTooltip />} cursor={{ stroke: 'rgba(200,134,26,0.3)' }} />
        <Legend wrapperStyle={{ fontFamily: "'Inter', sans-serif", fontSize: '0.7rem', color: 'rgba(242,242,242,0.5)' }} />
        <Line
          type="monotone"
          dataKey="raw"
          name="Raw visits"
          stroke={VISITS_RAW_COLOR}
          strokeWidth={2.2}
          dot={{ r: 5, fill: VISITS_RAW_COLOR }}
          activeDot={{ r: 6 }}
          isAnimationActive={animate}
          animationDuration={400}
        />
        <Line
          type="monotone"
          dataKey="unique"
          name="Unique devices (deduplicated by device)"
          stroke={VISITS_UNIQUE_COLOR}
          strokeWidth={2.2}
          strokeDasharray="6 4"
          dot={<SquareDot />}
          activeDot={{ r: 6 }}
          isAnimationActive={animate}
          animationDuration={400}
        />
      </LineChart>
    </ResponsiveContainer>
  );
}

// Shared click-to-expand overlay (design-notes.md §4/§5): blends
// DetectionDetailOverlay's role="dialog"/useFocusTrap/Escape-to-close
// semantics with the .attachment-lightbox-overlay CSS family's backdrop-
// blur/fade+scale motion at desktop widths, and the exact `.mobile-overlay`
// fullscreen slide-up treatment (same class, same breakpoint) this same page
// already uses at small viewports (Q13's purpose-built small-viewport
// requirement).
function ChartExpandOverlay({ open, onClose, isDesktop, title, ariaLabel, children }) {
  const containerRef = useRef(null);
  const [closing, setClosing] = useState(false);
  const reducedMotion = prefersReducedMotion();

  useFocusTrap(open && !closing, containerRef);

  const requestClose = useCallback(() => {
    if (!isDesktop || reducedMotion) {
      onClose();
      return;
    }
    setClosing(true);
  }, [isDesktop, reducedMotion, onClose]);

  useEffect(() => {
    if (!closing) return undefined;
    // Exit faster than enter (0.2s), matching .attachment-lightbox-overlay's
    // own timing (design-notes.md §4).
    const timer = window.setTimeout(onClose, 200);
    return () => window.clearTimeout(timer);
  }, [closing, onClose]);

  useEffect(() => { if (open) setClosing(false); }, [open]);

  if (isDesktop) {
    if (!open) return null;
    return (
      <div
        className={`chart-expand-overlay${closing ? ' chart-expand-closing' : ''}`}
        onClick={e => { if (e.target === e.currentTarget) requestClose(); }}
      >
        <div
          className={`chart-expand-panel${closing ? ' chart-expand-closing' : ''}`}
          ref={containerRef}
          role="dialog"
          aria-modal="true"
          aria-label={ariaLabel}
          onKeyDown={e => { if (e.key === 'Escape') requestClose(); }}
        >
          <button
            type="button"
            className="chart-expand-close"
            onClick={requestClose}
            aria-label="Close expanded chart"
          >
            <CloseOutlined />
          </button>
          <Text style={{ fontFamily: "'Playfair Display', serif", fontSize: '1.1rem', color: 'var(--parchment)', display: 'block', marginBottom: '0.75rem' }}>
            {title}
          </Text>
          <div style={{ flex: 1, minHeight: 0 }}>{children}</div>
        </div>
      </div>
    );
  }

  // Mobile/small-viewport: always mounted, visibility toggled via the
  // `.open` class -- same mechanism as DetectionDetailOverlay, required for
  // its slide-up CSS transition (not a keyframe animation) to actually play.
  return (
    <div
      className={`mobile-overlay${open ? ' open' : ''}`}
      ref={containerRef}
      role="dialog"
      aria-modal="true"
      aria-label={ariaLabel}
      onKeyDown={e => { if (e.key === 'Escape' && open) onClose(); }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.9rem 1rem', borderBottom: '1px solid rgba(200,134,26,0.15)', background: 'rgba(6,4,1,0.98)', flexShrink: 0 }}>
        <button
          type="button"
          onClick={onClose}
          aria-label="Close expanded chart"
          style={{
            background: 'none', border: 'none', color: 'rgba(200,134,26,0.65)', cursor: 'pointer',
            fontSize: '1.1rem', width: 44, height: 44, display: 'flex', alignItems: 'center',
            justifyContent: 'center', flexShrink: 0,
          }}
        >
          <CloseOutlined />
        </button>
        <Text style={{ fontFamily: "'Playfair Display', serif", fontSize: '1rem', color: 'var(--parchment)' }}>
          {title}
        </Text>
      </div>
      <div style={{ flex: 1, minHeight: 0, padding: '1rem', display: 'flex', flexDirection: 'column' }}>
        {open && children}
      </div>
    </div>
  );
}

// Shared reserved-space chart box: renders as a real, keyboard-operable
// <button> (not a `div` with `onClick`) once a chart is actually ready to
// expand, or a plain (non-interactive-wrapping) `div` for the loading/error/
// empty states -- kept as two separate branches rather than one disabled
// `<button>` around everything, since the error state's own Retry `<button>`
// must never end up nested inside another `<button>` (invalid HTML, and
// screen readers/click handling both misbehave with interactive-in-
// interactive content).
function ChartBox({ state, onRetry, ariaLabel, onExpand, chart }) {
  const boxStyle = {
    position: 'relative', width: '100%', aspectRatio: '2.5 / 1',
    borderRadius: 10, overflow: 'hidden', background: 'rgba(200,134,26,0.04)',
  };

  if (state === 'ready') {
    return (
      <button
        type="button"
        onClick={onExpand}
        aria-label={ariaLabel}
        style={{
          display: 'block', width: '100%', padding: 0, margin: 0, border: 'none',
          background: 'transparent', cursor: 'pointer', textAlign: 'left',
        }}
      >
        <div style={boxStyle}>{chart}</div>
      </button>
    );
  }

  return (
    <div style={boxStyle}>
      {state === 'loading' && (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Spin size="small" />
        </div>
      )}
      {state === 'error' && (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '0.75rem' }}>
          <Alert
            type="error"
            showIcon
            message="Could not load this chart."
            action={<Button size="small" onClick={onRetry}>Retry</Button>}
            style={{ borderRadius: 8, width: '100%' }}
          />
        </div>
      )}
      {state === 'empty' && (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.35)' }}>
            No data yet for this window.
          </Text>
        </div>
      )}
    </div>
  );
}

// One metric card: fetches its own JSON series, renders the inline chart,
// and owns its own click-to-expand overlay. Independent per-card
// loading/error/empty state (design-notes.md §2) -- one card's failure must
// never block the other four.
function MetricChartCard({ metricKey, label, refreshKey, isDesktop }) {
  const navigate = useNavigate();
  const [state, setState] = useState('loading'); // loading | ready | empty | error
  const [series, setSeries] = useState([]);
  const [ylabel, setYlabel] = useState('Avg per user');
  const [expanded, setExpanded] = useState(false);

  const fetchData = useCallback(async () => {
    setState('loading');
    try {
      const res = await fetch(`${API}/activity-monitoring/data/${metricKey}`);

      if (res.status === 401) { navigate('/signin', { replace: true }); return; }
      if (res.status === 403) { navigate('/', { replace: true }); return; }

      if (!res.ok) { setState('error'); return; }

      const data = await res.json();
      setYlabel(data.ylabel || 'Avg per user');
      setSeries(data.series || []);
      setState((data.series || []).length ? 'ready' : 'empty');
    } catch {
      setState('error');
    }
  }, [metricKey, navigate]);

  useEffect(() => { fetchData(); }, [fetchData, refreshKey]);

  const reducedMotion = prefersReducedMotion();
  const title = label;
  const expandAriaLabel = `${label}, expanded`;

  return (
    <div style={CARD_STYLE}>
      <Text style={CARD_LABEL_STYLE}>{label}</Text>
      <ChartBox
        state={state}
        onRetry={fetchData}
        ariaLabel={`Line chart: ${label}, trailing 30 days. Press to expand.`}
        onExpand={() => setExpanded(true)}
        chart={<MetricLineChart series={series} ylabel={ylabel} height="100%" animate={!reducedMotion} />}
      />

      <ChartExpandOverlay
        open={expanded}
        onClose={() => setExpanded(false)}
        isDesktop={isDesktop}
        title={title}
        ariaLabel={expandAriaLabel}
      >
        <MetricLineChart series={series} ylabel={ylabel} height={isDesktop ? 480 : '100%'} animate={false} />
      </ChartExpandOverlay>
    </div>
  );
}

// Visits card: two-series fetch/render, same shape as MetricChartCard but
// for GET /activity-monitoring/data/visits.
function VisitsChartCard({ refreshKey, isDesktop }) {
  const navigate = useNavigate();
  const [state, setState] = useState('loading'); // loading | ready | empty | error
  const [series, setSeries] = useState([]);
  const [expanded, setExpanded] = useState(false);

  const fetchData = useCallback(async () => {
    setState('loading');
    try {
      const res = await fetch(`${API}/activity-monitoring/data/visits`);

      if (res.status === 401) { navigate('/signin', { replace: true }); return; }
      if (res.status === 403) { navigate('/', { replace: true }); return; }

      if (!res.ok) { setState('error'); return; }

      const data = await res.json();
      setSeries(data.series || []);
      setState((data.series || []).length ? 'ready' : 'empty');
    } catch {
      setState('error');
    }
  }, [navigate]);

  useEffect(() => { fetchData(); }, [fetchData, refreshKey]);

  const reducedMotion = prefersReducedMotion();
  const title = 'Website visits';
  const expandAriaLabel = 'Website visits, raw vs. unique devices, expanded';

  return (
    <div style={{ ...CARD_STYLE, gridColumn: isDesktop ? '1 / -1' : 'auto' }}>
      <Text style={CARD_LABEL_STYLE}>{title}</Text>
      <ChartBox
        state={state}
        onRetry={fetchData}
        ariaLabel="Line chart: website visits over the trailing 30 days, showing raw pageviews and unique-device visitors as two separate lines. Press to expand."
        onExpand={() => setExpanded(true)}
        chart={<VisitsLineChart series={series} height="100%" animate={!reducedMotion} />}
      />

      <ChartExpandOverlay
        open={expanded}
        onClose={() => setExpanded(false)}
        isDesktop={isDesktop}
        title={title}
        ariaLabel={expandAriaLabel}
      >
        <VisitsLineChart series={series} height={isDesktop ? 480 : '100%'} animate={false} />
      </ChartExpandOverlay>
    </div>
  );
}

// Admin-only Activity Monitoring panel (task 20260918-admin-activity-monitoring,
// made interactive by task 20260919-activity-monitoring-interactive-charts).
// Lives on the same gated /admin surface as AdminDetections/
// AdminMembershipGrant, below both, without touching that page's own
// filter/fetch/pagination behavior -- fully self-contained, own state, own
// requests, per the AdminMembershipGrant precedent this component follows
// (design-notes.md §1).
//
// Each of the five chart cards now fetches structured JSON from the new
// `GET /activity-monitoring/data/*` endpoints (api/routes/activity_monitoring.py)
// -- require_admin-gated, admin_audit-logged, Cache-Control: no-store, same
// as the PNG endpoints they replace -- and renders a live Recharts
// <LineChart> with hover tooltips and a click-to-expand overlay, per
// design-notes.md. A lapsed/demoted admin session now surfaces via this
// component's own 401/403 redirect handling (matching AdminDetections.jsx's
// fetchDetections convention) rather than a generic per-card error, since
// this is a real fetch() this component controls the response of.
export default function AdminActivityMonitoring() {
  const isDesktop = useIsDesktopViewport();
  // Bumping this re-fetches every card's JSON -- this is a point-in-time
  // snapshot view, not a polling dashboard, so a manual Refresh is the only
  // way any of these five charts ever update (design-notes.md §2; "stale"
  // was resolved via hover interactivity, not auto-refresh, per
  // clarification-response.md).
  const [refreshKey, setRefreshKey] = useState(0);

  return (
    <div style={{ marginBottom: '1.5rem' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '1rem', gap: '1rem' }}>
        <div>
          <Text style={EYEBROW_STYLE}>Interactive · hover for exact values · trailing 30 days</Text>
          <Title level={3} style={{ margin: 0, fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>
            Activity Monitoring
          </Title>
        </div>
        <Button type="text" onClick={() => setRefreshKey(k => k + 1)} style={{ color: 'var(--gold)', flexShrink: 0 }}>
          Refresh
        </Button>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: isDesktop ? '1fr 1fr' : '1fr', gap: '1.5rem' }}>
        {METRICS.map(m => (
          <MetricChartCard
            key={m.key}
            metricKey={m.key}
            label={m.label}
            refreshKey={refreshKey}
            isDesktop={isDesktop}
          />
        ))}

        <VisitsChartCard refreshKey={refreshKey} isDesktop={isDesktop} />
      </div>
    </div>
  );
}
