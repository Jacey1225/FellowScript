import React, { useMemo, useRef, useState } from 'react';

// Task 20261007-affiliates-page. Marker-free SVG line chart: a single stroked
// polyline, faint gridlines, and a hover/focus/tap readout. The readout is a
// vertical hairline plus text above the chart; no dots are ever drawn.
const W = 600;
const H = 160;
const PAD = 6;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function parts(t) {
  const [y, m, d] = String(t).split('-').map(Number);
  return { y, m: (m || 1) - 1, d: d || 1 };
}
export function formatPointDate(t, unit) {
  const { y, m, d } = parts(t);
  if (unit === 'month') return `${MONTHS[m]} ${y}`;
  if (unit === 'week') return `Week of ${MONTHS[m]} ${d}`;
  return `${MONTHS[m]} ${d}`;
}

const LABEL_STYLE = { fontFamily: "'Inter', sans-serif", fontSize: '0.72rem', color: 'rgba(244,228,193,0.55)' };

export default function AffiliateLineChart({ title, points, field, unit, color, noun }) {
  const wrapRef = useRef(null);
  const [idx, setIdx] = useState(null);
  const n = points.length;
  const values = points.map((p) => Number(p[field]) || 0);
  const max = Math.max(1, ...values);
  const allZero = values.every((v) => v === 0);

  const xs = (i) => PAD + (n <= 1 ? 0 : (i / (n - 1)) * (W - 2 * PAD));
  const ys = (v) => H - PAD - (v / max) * (H - 2 * PAD);
  const path = useMemo(
    () => values.map((v, i) => `${i === 0 ? 'M' : 'L'}${xs(i).toFixed(1)} ${ys(v).toFixed(1)}`).join(' '),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [points, field],
  );

  const setFromClientX = (clientX) => {
    const el = wrapRef.current;
    if (!el || n === 0) return;
    const rect = el.getBoundingClientRect();
    const frac = rect.width > 0 ? Math.min(1, Math.max(0, (clientX - rect.left) / rect.width)) : 0;
    setIdx(Math.round(frac * (n - 1)));
  };
  const onKey = (e) => {
    if (n === 0) return;
    if (e.key === 'ArrowLeft') { e.preventDefault(); setIdx((i) => Math.max(0, (i === null ? n - 1 : i) - 1)); }
    else if (e.key === 'ArrowRight') { e.preventDefault(); setIdx((i) => Math.min(n - 1, (i === null ? n - 1 : i) + 1)); }
    else if (e.key === 'Escape') setIdx(null);
  };

  const shown = idx === null ? null : points[idx];
  const last = points[n - 1];
  const summary = last ? `${title}: ${values[n - 1]} ${noun} on ${formatPointDate(last.t, unit)}.` : `${title}: no data.`;

  return (
    <div style={{ marginBottom: '1rem' }} data-testid={`chart-${field}`}>
      <div style={{ ...LABEL_STYLE, display: 'flex', justifyContent: 'space-between', minHeight: 20 }}>
        <span style={{ color }}>{title}</span>
        <span aria-live="polite" data-testid={`readout-${field}`}>
          {shown ? `${formatPointDate(shown.t, unit)}: ${Number(shown[field]) || 0} ${noun}` : ''}
        </span>
      </div>
      <div
        ref={wrapRef}
        role="img"
        aria-label={summary}
        tabIndex={0}
        data-testid={`chart-area-${field}`}
        onPointerMove={(e) => setFromClientX(e.clientX)}
        onPointerDown={(e) => setFromClientX(e.clientX)}
        onPointerLeave={() => setIdx(null)}
        onKeyDown={onKey}
        onBlur={() => setIdx(null)}
        style={{ position: 'relative', height: H, touchAction: 'pan-y', borderRadius: 8 }}
      >
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" width="100%" height={H} aria-hidden="true" focusable="false">
          {[0.25, 0.5, 0.75].map((g) => (
            <line key={g} x1={PAD} x2={W - PAD} y1={PAD + g * (H - 2 * PAD)} y2={PAD + g * (H - 2 * PAD)}
              stroke="rgba(244,228,193,0.1)" strokeWidth="1" vectorEffect="non-scaling-stroke" />
          ))}
          {n > 0 && (
            <path d={path} fill="none" stroke={color} strokeWidth="2" strokeLinejoin="round" strokeLinecap="round"
              vectorEffect="non-scaling-stroke" />
          )}
        </svg>
        {shown && (
          <div data-testid={`hairline-${field}`} style={{
            position: 'absolute', top: 0, bottom: 0, width: 1, background: 'rgba(244,228,193,0.45)',
            left: `${(xs(idx) / W) * 100}%`, pointerEvents: 'none',
          }} />
        )}
        <span style={{ ...LABEL_STYLE, position: 'absolute', top: 0, right: 4 }}>{max}</span>
        <span style={{ ...LABEL_STYLE, position: 'absolute', bottom: 0, right: 4 }}>0</span>
      </div>
      <div style={{ ...LABEL_STYLE, display: 'flex', justifyContent: 'space-between' }}>
        <span>{n ? formatPointDate(points[0].t, unit) : ''}</span>
        <span>{n > 2 ? formatPointDate(points[Math.floor((n - 1) / 2)].t, unit) : ''}</span>
        <span>{n > 1 ? formatPointDate(points[n - 1].t, unit) : ''}</span>
      </div>
      {allZero && <p style={{ ...LABEL_STYLE, margin: '0.25rem 0 0' }}>No activity yet. Share your code to get started.</p>}
    </div>
  );
}
