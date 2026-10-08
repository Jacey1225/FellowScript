import React, { useEffect, useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { Spin, Alert, Button, Tag, Segmented } from 'antd';
import {
  PictureOutlined, ReadOutlined, NotificationOutlined, QrcodeOutlined, FileTextOutlined,
} from '@ant-design/icons';
import AppBloom from '../components/AppBloom.jsx';
import AppNav from '../components/AppNav.jsx';
import Seo from '../components/Seo.jsx';
import EmailVerifyNotice from '../components/EmailVerifyNotice.jsx';
import AffiliateLineChart from '../components/AffiliateLineChart.jsx';
import AffiliatePayouts from '../components/AffiliatePayouts.jsx';
import AffiliateResources, { RESOURCE_SECTIONS } from '../components/AffiliateResources.jsx';
import { useWarmCanvas } from '../hooks/useWarmCanvas.js';
import { useAuth } from '../context/AuthContext.jsx';
import { getAffiliateOverview } from '../lib/affiliatesApi.js';

const CARD_STYLE = {
  background: 'rgba(32,24,16,0.62)',
  border: '1px solid rgba(200,134,26,0.22)',
  backdropFilter: 'blur(14px)',
  borderRadius: 22,
  marginBottom: '1.25rem',
  padding: '1.25rem 1.4rem',
};
const LABEL = {
  fontFamily: "'Inter', sans-serif", fontWeight: 600, fontSize: '0.62rem', letterSpacing: '0.22em',
  textTransform: 'uppercase', color: 'rgba(224,170,60,0.78)', display: 'block', marginBottom: 4, margin: '0 0 4px',
};
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.5)' };
const BODY = { fontFamily: "'Inter', sans-serif", fontSize: '0.9rem', color: 'rgba(244,228,193,0.85)', lineHeight: 1.6 };
const ICONS = {
  logos: <PictureOutlined />, guides: <ReadOutlined />, ads: <NotificationOutlined />,
  links: <QrcodeOutlined />, script: <FileTextOutlined />,
};
const money = (cents) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format((cents || 0) / 100);
const pct = (rate) => `${Math.round((Number(rate) || 0) * 10000) / 100}%`;

function StatCard({ label, value, sub, testId }) {
  return (
    <div style={{ ...CARD_STYLE, flex: '1 1 220px', marginBottom: 0, textAlign: 'center' }}>
      <h2 style={LABEL}>{label}</h2>
      <div className="fs-heading" data-testid={testId} style={{ fontSize: '2.2rem', color: 'var(--parchment)', margin: '0.2rem 0' }}>{value}</div>
      <div style={MUTED}>{sub}</div>
    </div>
  );
}

function Milestones({ milestones, count }) {
  const firstOpen = milestones.findIndex((m) => !m.earned);
  return (
    <div style={CARD_STYLE}>
      <h2 style={LABEL}>Milestones</h2>
      {milestones.map((m, i) => (
        <div key={m.subscribers} data-testid={`milestone-${m.subscribers}`}
          style={{ padding: '0.6rem 0', borderTop: i ? '1px solid rgba(244,228,193,0.08)' : 'none' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', flexWrap: 'wrap' }}>
            <span style={{ ...BODY, flex: 1, minWidth: 140 }}>{m.subscribers} subscribers</span>
            <span style={BODY}>{money(m.bonus_cents)} bonus</span>
            {m.earned
              ? <Tag color="gold">Earned{m.earned_at ? ` ${m.earned_at}` : ''}</Tag>
              : <Tag>Not yet earned</Tag>}
          </div>
          {!m.earned && (
            <div style={{ marginTop: 6 }}>
              {i === firstOpen && (
                <div role="progressbar" aria-label={`Progress to ${m.subscribers} subscribers`}
                  aria-valuemin={0} aria-valuemax={m.subscribers} aria-valuenow={Math.min(count, m.subscribers)}
                  style={{ height: 6, borderRadius: 3, background: 'rgba(244,228,193,0.12)', overflow: 'hidden' }}>
                  <div style={{ height: '100%', width: `${Math.min(100, (count / m.subscribers) * 100)}%`, background: '#e0aa3c' }} />
                </div>
              )}
              <span style={MUTED}>{Math.max(0, m.subscribers - count)} to go</span>
            </div>
          )}
        </div>
      ))}
      <p style={{ ...MUTED, margin: '0.6rem 0 0' }}>
        Each bonus is paid once and is paid manually by FellowScript. Milestones count active paying subscribers.
      </p>
    </div>
  );
}

// Task 20261007-affiliates-page: /#/affiliates, the creator program page. Server
// side session + creator-email check is the real enforcement; this page only
// reads the answer. 404 = program off (neutral notice), 403 = not a creator.
export default function Affiliates() {
  useWarmCanvas();
  const { user } = useAuth();
  const navigate = useNavigate();
  const [phase, setPhase] = useState('idle'); // idle | loading | ok | unavailable | forbidden | signedout | error
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [unit, setUnit] = useState('day');
  const [section, setSection] = useState(null);

  const load = useCallback(async () => {
    setPhase('loading'); setError(null);
    try {
      setData(await getAffiliateOverview());
      setPhase('ok');
    } catch (err) {
      if (err.status === 404) setPhase('unavailable');
      else if (err.status === 403) setPhase('forbidden');
      else if (err.status === 401) setPhase('signedout');
      else { setError(err.message || "Couldn't load the page."); setPhase('error'); }
    }
  }, []);

  useEffect(() => { if (user) load(); }, [user, load]);

  const signedOut = !user || phase === 'signedout';
  const goSignIn = (tab) => navigate('/signin', tab ? { state: { tab } } : undefined);

  let content;
  if (signedOut) {
    content = (
      <div style={CARD_STYLE}>
        <h2 style={LABEL}>Creator program</h2>
        <p style={BODY}>
          The FellowScript affiliate program is for content creators. Create a FellowScript account, or sign in,
          using the email your creator code is registered to.
        </p>
        <div style={{ display: 'flex', gap: '0.6rem', flexWrap: 'wrap' }}>
          <Button type="primary" shape="round" style={{ minHeight: 44 }} onClick={() => goSignIn('signup')}>Create account</Button>
          <Button shape="round" style={{ minHeight: 44 }} onClick={() => goSignIn()}>Sign in</Button>
        </div>
      </div>
    );
  } else if (phase === 'idle' || phase === 'loading') {
    content = <div style={{ textAlign: 'center', minHeight: '40vh' }}><Spin /></div>;
  } else if (phase === 'unavailable') {
    content = <Alert type="info" showIcon message="Affiliates isn't available right now." />;
  } else if (phase === 'forbidden') {
    content = (
      <div style={CARD_STYLE}>
        <h2 style={LABEL}>Creator program</h2>
        {/* The server answers the same 403 for non-creators and unverified
            emails, so show the verify prompt whenever status says unverified. */}
        <EmailVerifyNotice context="affiliates" />
        <p style={BODY}>This account isn't set up as a creator.</p>
        <p style={MUTED}>Sign in with the email your creator code is registered to, or contact FellowScript to join the program.</p>
        <div style={{ display: 'flex', gap: '0.6rem', flexWrap: 'wrap' }}>
          <Button shape="round" style={{ minHeight: 44 }} onClick={() => goSignIn()}>Switch account</Button>
          <Button shape="round" style={{ minHeight: 44 }} onClick={() => navigate('/')}>Back home</Button>
        </div>
      </div>
    );
  } else if (phase === 'error') {
    content = (
      <div role="alert">
        <Alert type="error" showIcon message={error}
          action={<Button size="small" onClick={load}>Try again</Button>} />
      </div>
    );
  } else if (phase === 'ok' && data) {
    const m = data.metrics || {};
    const series = (data.series && data.series[unit]) || [];
    const codes = Array.isArray(data.codes) ? data.codes : [];
    const rate = pct(m.commission_rate);
    content = (
      <div className="fs-aff__cols">
        <nav aria-label="Promotion resources" className="fs-aff__side">
          <span className="fs-eyebrow" style={{ padding: '0 0.5rem 0.5rem', display: 'block' }}>Resources</span>
          <ul>
            {RESOURCE_SECTIONS.map((s) => (
              <li key={s.key}>
                <button type="button" className="fs-aff__btn" aria-pressed={section === s.key}
                  onClick={() => setSection(section === s.key ? null : s.key)}>
                  {ICONS[s.key]}<span>{s.label}</span>
                </button>
              </li>
            ))}
          </ul>
        </nav>
        <div className="fs-aff__main">
          <div style={{ display: 'flex', gap: '1rem', flexWrap: 'wrap', maxWidth: 720, margin: '0 auto 1.25rem' }}>
            <StatCard label="Active paying subscribers" testId="metric-subscribers"
              value={new Intl.NumberFormat('en-US').format(m.active_paying_subscribers || 0)} sub="who joined with your code" />
            <StatCard label="Earnings per month" testId="metric-earnings"
              value={money(m.monthly_earnings_cents)} sub={`${rate} of their plan prices`} />
          </div>

          <div style={CARD_STYLE}>
            <h2 style={LABEL}>Your program</h2>
            <p style={BODY}>
              You earn {rate} of the monthly plan price of every active paying subscriber who joined with your code, for as long as
              they stay subscribed (lifetime), plus one-time bonuses at subscriber milestones. Payouts are sent manually by FellowScript; add your bank details under Payout details below.
            </p>
            {codes.map((c) => (
              <div key={c.code} style={{ display: 'flex', gap: '0.6rem', alignItems: 'center', marginBottom: 6 }}>
                <code style={{ color: 'var(--parchment)' }}>{c.code}</code>
                {c.active ? <Tag color="gold">Active</Tag> : <Tag>Inactive</Tag>}
              </div>
            ))}
            <p style={{ ...MUTED, margin: '0.5rem 0 0' }}>
              Disclose your partnership clearly when you promote FellowScript (for example, "affiliate link" or "#ad").
            </p>
          </div>

          <div style={CARD_STYLE}>
            <h2 style={LABEL}>Subscription activity</h2>
            <Segmented aria-label="Chart range" value={unit} onChange={setUnit}
              options={[{ label: 'Day', value: 'day' }, { label: 'Week', value: 'week' }, { label: 'Month', value: 'month' }]}
              style={{ marginBottom: '1rem' }} />
            <AffiliateLineChart title="New subscribers" points={series} field="new" unit={unit} color="#e0aa3c" noun="new" />
            <AffiliateLineChart title="Total subscribers" points={series} field="total" unit={unit} color="rgba(244,228,193,0.85)" noun="total" />
          </div>

          <AffiliatePayouts />

          <Milestones milestones={Array.isArray(data.milestones) ? data.milestones : []} count={m.active_paying_subscribers || 0} />

          {section && (
            <div style={CARD_STYLE}>
              <AffiliateResources section={section} codes={codes} onClose={() => setSection(null)} />
            </div>
          )}
        </div>
      </div>
    );
  }

  return (
    <>
      <Seo title="Affiliates - FellowScript" description="FellowScript creator affiliate program" path="/affiliates" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <div className="fs-aff">
        <div className="fs-admin__head">
          <span className="fs-eyebrow">Creators</span>
          <h1 className="fs-heading">Affiliates</h1>
        </div>
        {content}
      </div>
    </>
  );
}
