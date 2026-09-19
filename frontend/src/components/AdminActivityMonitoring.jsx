import React, { useState } from 'react';
import { Typography, Spin, Alert, Button } from 'antd';
import { API } from '../config.js';
import { useIsDesktopViewport } from '../hooks/useIsDesktopViewport.js';

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
  { key: 'notes', label: 'Average notes per user', alt: 'Line chart: average notes per user, trailing 30 days' },
  { key: 'highlights', label: 'Average highlights per user', alt: 'Line chart: average highlights per user, trailing 30 days' },
  { key: 'logins', label: 'Average logins per user', alt: 'Line chart: average logins per user, trailing 30 days' },
  { key: 'messages', label: 'Average messages per user', alt: 'Line chart: average messages per user, trailing 30 days' },
];

// A single chart's reserved-space image box, with its own independent
// loading/crossfade/error+retry state (design-notes.md §5) -- one card's
// failure must never block the other four.
function ChartFrame({ src, alt }) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [retryKey, setRetryKey] = useState(0);

  // Cache-Control: no-store already means the server never caches this
  // response -- the `_r` param here isn't fighting a cache, it's just
  // forcing React/the browser to treat `src` as a new URL and re-issue the
  // <img> request on Retry (design-notes.md §5).
  const finalSrc = retryKey ? `${src}?_r=${retryKey}` : src;

  const retry = () => {
    setError(false);
    setLoading(true);
    setRetryKey(k => k + 1);
  };

  return (
    <div
      style={{
        position: 'relative', width: '100%', aspectRatio: '2.5 / 1',
        borderRadius: 10, overflow: 'hidden', background: 'rgba(200,134,26,0.04)',
      }}
    >
      {loading && !error && (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Spin size="small" />
        </div>
      )}
      {error ? (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '0.75rem' }}>
          <Alert
            type="error"
            showIcon
            message="Could not load this chart."
            action={<Button size="small" onClick={retry}>Retry</Button>}
            style={{ borderRadius: 8, width: '100%' }}
          />
        </div>
      ) : (
        <img
          key={finalSrc}
          src={finalSrc}
          alt={alt}
          onLoad={() => setLoading(false)}
          onError={() => { setLoading(false); setError(true); }}
          style={{
            width: '100%', height: '100%', objectFit: 'contain', borderRadius: 10,
            opacity: loading ? 0 : 1, transition: 'opacity 280ms ease-out',
          }}
        />
      )}
    </div>
  );
}

// Admin-only Activity Monitoring panel (task 20260918-admin-activity-monitoring).
// Lives on the same gated /admin surface as AdminDetections/
// AdminMembershipGrant, below both, without touching that page's own
// filter/fetch/pagination behavior -- fully self-contained, own state, own
// requests, per the AdminMembershipGrant precedent this component follows
// (design-notes.md §1). No new route, no new AdminGate wrapper needed: it
// only ever mounts once AdminDetections's own gate-fetch has already
// resolved the admin auth boundary.
//
// Server-side `require_admin` on every GET /activity-monitoring/plots/*
// call is the real enforcement (api/routes/activity_monitoring.py); a
// 401/403 there is handled the same way AdminMembershipGrant.jsx's own
// fetch handles those statuses -- but since these are plain <img> requests
// (not a fetch() this component controls the response of), a lapsed/demoted
// admin session simply surfaces as this component's own per-card error
// state, not a redirect -- acceptable here since the page around it already
// gates entry, and a mid-session demotion is a rare edge case for what is
// explicitly a read-only, no-user-consequence panel.
export default function AdminActivityMonitoring() {
  const isDesktop = useIsDesktopViewport();
  // Bumping this remounts every ChartFrame (via the key below), which resets
  // each one's own loading/error state and re-issues its <img> request --
  // this is a point-in-time snapshot view, not a polling dashboard, so a
  // manual Refresh is the only way any of these five charts ever update
  // (design-notes.md §2).
  const [refreshKey, setRefreshKey] = useState(0);

  return (
    <div style={{ marginBottom: '1.5rem' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '1rem', gap: '1rem' }}>
        <div>
          <Text style={EYEBROW_STYLE}>Server-rendered snapshot · trailing 30 days</Text>
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
          <div key={m.key} style={CARD_STYLE}>
            <Text style={CARD_LABEL_STYLE}>{m.label}</Text>
            <ChartFrame key={refreshKey} src={`${API}/activity-monitoring/plots/${m.key}`} alt={m.alt} />
          </div>
        ))}

        <div style={{ ...CARD_STYLE, gridColumn: isDesktop ? '1 / -1' : 'auto' }}>
          <Text style={CARD_LABEL_STYLE}>Website visits</Text>
          <ChartFrame
            key={refreshKey}
            src={`${API}/activity-monitoring/plots/visits`}
            alt="Line chart: website visits over the trailing 30 days, showing raw pageviews and unique-device visitors as two separate lines"
          />
          {/* Accessibility redundancy (design-notes.md §6): duplicates the
              in-image legend as accessible DOM text, since the two-series
              color distinction otherwise lives only inside a flat PNG. */}
          <div style={{ display: 'flex', alignItems: 'center', gap: '1rem', marginTop: '0.6rem' }}>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.35rem', fontFamily: "'Inter', sans-serif", fontSize: '0.7rem', color: 'rgba(242,242,242,0.5)' }}>
              <span aria-hidden="true" style={{ width: 8, height: 8, borderRadius: '50%', background: '#C98A4B', display: 'inline-block' }} />
              Raw visits
            </span>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.35rem', fontFamily: "'Inter', sans-serif", fontSize: '0.7rem', color: 'rgba(242,242,242,0.5)' }}>
              <span aria-hidden="true" style={{ width: 8, height: 8, borderRadius: '50%', background: 'var(--gold)', display: 'inline-block' }} />
              Unique devices (deduplicated by device)
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}
