import React from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';

const S = {
  page: {
    background: '#1a140f',
    color: '#f3ead9',
    fontFamily: "'Space Grotesk', system-ui, sans-serif",
    lineHeight: 1.5,
    minHeight: '100vh',
  },
  wrap: { maxWidth: 1100, margin: '0 auto' },
  eyebrow: {
    font: "600 11px 'JetBrains Mono', monospace",
    letterSpacing: '0.14em',
    textTransform: 'uppercase',
    color: '#e8a53d',
  },
  btnPrimary: {
    display: 'inline-flex',
    alignItems: 'center',
    gap: 8,
    font: "600 13px 'Space Grotesk', sans-serif",
    letterSpacing: '0.02em',
    padding: '14px 22px',
    background: '#e8a53d',
    color: '#161310',
    borderRadius: 12,
    textDecoration: 'none',
    border: 'none',
    cursor: 'pointer',
  },
  btnOutline: {
    display: 'inline-flex',
    alignItems: 'center',
    gap: 8,
    font: "600 13px 'Space Grotesk', sans-serif",
    letterSpacing: '0.02em',
    padding: '14px 22px',
    border: '1px solid rgba(243,234,217,.3)',
    color: '#f3ead9',
    background: 'transparent',
    borderRadius: 12,
    textDecoration: 'none',
    cursor: 'pointer',
  },
  card: {
    background: '#241c14',
    borderRadius: 16,
    padding: 24,
    border: '1px solid rgba(243,234,217,.06)',
  },
};

// Minimal SVG icon wrapper
function Ico({ d, d2, d3 }) {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none"
      stroke="#e8a53d" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d={d} />
      {d2 && <path d={d2} />}
      {d3 && <path d={d3} />}
    </svg>
  );
}

function IconBox({ children }) {
  return (
    <div style={{ width: 36, height: 36, borderRadius: 10, background: 'rgba(232,165,61,.15)', border: '1px solid rgba(232,165,61,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', marginBottom: 16, flexShrink: 0 }}>
      {children}
    </div>
  );
}

const steps = [
  { n: '1', title: 'Open the Word',          desc: 'Read at your pace, highlight what speaks to you.' },
  { n: '2', title: 'Set a gentle rhythm',    desc: 'Daily check-ins that meet you where you are.' },
  { n: '3', title: 'Share with your people', desc: 'Notes, highlights, live study with your circle.' },
];

const features = [
  {
    icon: <Ico d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" d2="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />,
    title: 'Beautiful Bible Reader',
    desc: 'Every chapter laid out with care. Adjust text size, navigate any book, and read without distraction.',
  },
  {
    icon: <Ico d="M9 11l-6 6v3h3l6-6m13-1-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4" />,
    title: 'Verse Highlights',
    desc: 'Mark what moves you with four distinct colors. Your highlights save automatically and stay with you.',
  },
  {
    icon: <Ico d="M17 3a2.828 2.828 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5L17 3z" />,
    title: 'Scripture Notes',
    desc: 'Write reflections tied to specific verses. Build a personal library of insights you can revisit anytime.',
  },
  {
    icon: <Ico d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z" />,
    title: 'AI Daily Check-ins',
    desc: 'Your AI companion reaches out each day with a question or reflection — gentle, personal, and rooted in Scripture.',
  },
  {
    icon: <Ico d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" d2="M9 7a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm14 0a4 4 0 1 0 0-8 4 4 0 0 0 0 8z" />,
    title: 'Group Bible Study',
    desc: 'Invite up to four people into your plan. Share the same reading space, highlight together, message in real time.',
  },
  {
    icon: <Ico d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z" />,
    title: 'Verse Bookmarks',
    desc: 'Save any verse instantly. Build a treasury of passages that resonate, always one tap away.',
  },
];

const plans = [
  {
    name: 'Free',
    price: '$0',
    sub: 'No card needed',
    perks: ['Beautiful Bible reader', '10 notes per week', '1 AI check-in event', '3 scheduled notifications', 'Verse highlights & bookmarks'],
    cta: 'Start reading',
    href: '/signin',
    primary: false,
  },
  {
    name: 'Individual',
    price: '$10',
    sub: 'per month — 1 month free trial',
    perks: ['Everything in Free', 'Unlimited notes', 'Unlimited AI check-ins', 'Unlimited notifications', 'Priority support'],
    cta: 'Start free trial',
    href: '/signin',
    primary: true,
  },
  {
    name: 'Group',
    price: '$40',
    sub: 'per month — up to 5 members',
    perks: ['Everything in Individual', 'Shared reading space', 'Group messaging & chat', 'Live study sessions', 'Invite up to 4 others'],
    cta: 'Start group trial',
    href: '/signin',
    primary: false,
  },
];

export default function Home() {
  const { user } = useAuth();
  const cta = user ? '/reader' : '/signin';

  return (
    <div style={S.page}>
      <style>{`
        .hp-nav-links a { color: rgba(243,234,217,.6); text-decoration: none; }
        .hp-nav-links a:hover { color: #e8a53d; }
        .hp-hero-grid  { display: grid; grid-template-columns: 1fr 300px; gap: 32px; align-items: center; }
        .hp-hero-cards { position: relative; height: 280px; }
        .hp-steps-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; }
        .hp-feat-grid  { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }
        .hp-plans-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }
        .hp-community-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 32px; align-items: center; }
        @media (max-width: 820px) {
          .hp-hero-grid        { grid-template-columns: 1fr !important; }
          .hp-hero-cards       { display: none !important; }
          .hp-steps-grid       { grid-template-columns: 1fr !important; }
          .hp-feat-grid        { grid-template-columns: 1fr !important; }
          .hp-plans-grid       { grid-template-columns: 1fr !important; }
          .hp-community-grid   { grid-template-columns: 1fr !important; }
          .hp-nav-links        { display: none !important; }
          .hp-quote-row        { flex-direction: column !important; }
          .hp-community-visual { display: none !important; }
        }
        @media (max-width: 1024px) and (min-width: 821px) {
          .hp-feat-grid  { grid-template-columns: repeat(2, 1fr) !important; }
          .hp-plans-grid { grid-template-columns: repeat(2, 1fr) !important; }
        }
      `}</style>

      {/* ── Nav ── */}
      <nav style={{ ...S.wrap, display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '24px 24px' }}>
        <Link to="/" style={{ font: "700 18px 'Space Grotesk', sans-serif", letterSpacing: '-0.02em', color: '#f3ead9', textDecoration: 'none' }}>
          FellowScript
        </Link>
        <div className="hp-nav-links" style={{ display: 'flex', alignItems: 'center', gap: 28, font: "500 13px 'Space Grotesk', sans-serif" }}>
          <Link to="/">Home</Link>
          <Link to="/reader">Read</Link>
          {user && <Link to="/account">{user.username || 'Account'}</Link>}
          <Link to={cta} style={{ ...S.btnPrimary, borderRadius: 10, padding: '9px 16px', fontSize: 12 }}>
            {user ? 'Open app' : 'Get started'}
          </Link>
        </div>
      </nav>

      {/* ── Hero ── */}
      <header style={{ position: 'relative', overflow: 'hidden' }}>
        <div style={{
          position: 'absolute', inset: 0,
          backgroundImage: 'radial-gradient(rgba(243,234,217,.09) 1px, transparent 1px)',
          backgroundSize: '22px 22px',
          WebkitMaskImage: 'linear-gradient(to bottom, black, transparent 85%)',
          maskImage: 'linear-gradient(to bottom, black, transparent 85%)',
          zIndex: 0,
        }} />
        <div className="hp-hero-grid" style={{ ...S.wrap, position: 'relative', zIndex: 1, padding: '44px 24px 64px' }}>
          <div>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, background: 'rgba(232,165,61,.14)', borderRadius: 20, padding: '7px 14px', marginBottom: 20 }}>
              <div style={{ width: 6, height: 6, borderRadius: '50%', background: '#e8a53d' }} />
              <span style={{ font: "600 11.5px 'Space Grotesk', sans-serif", color: '#e8a53d' }}>Now with daily AI check-ins</span>
            </div>
            <h1 style={{ font: "700 44px/1.12 'Space Grotesk', sans-serif", letterSpacing: '-0.02em', margin: '0 0 18px', maxWidth: 480 }}>
              You don't have to walk with God alone.
            </h1>
            <p style={{ maxWidth: 420, color: 'rgba(243,234,217,.68)', fontSize: 15, margin: '0 0 26px' }}>
              A friendly AI companion, a daily rhythm, and people who show up with you — every single day.
            </p>
            <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
              <Link to={cta} style={S.btnPrimary}>Begin your journey →</Link>
              <Link to="/reader" style={S.btnOutline}>Read scripture</Link>
            </div>
          </div>

          <div className="hp-hero-cards">
            <div style={{ position: 'absolute', top: 0, right: 20, width: 200, background: '#241c14', borderRadius: 18, padding: 18, boxShadow: '0 20px 40px rgba(0,0,0,.45)', transform: 'rotate(3deg)' }}>
              <div style={{ font: "600 11px 'Space Grotesk', sans-serif", color: '#e8a53d', marginBottom: 8 }}>Today's verse</div>
              <div style={{ font: "500 13px/1.4 'Space Grotesk', sans-serif", color: '#f3ead9' }}>
                "Be still, and know that I am God." — Psalm 46:10
              </div>
            </div>
            <div style={{ position: 'absolute', top: 130, left: 0, width: 210, background: '#241c14', borderRadius: 18, padding: 16, boxShadow: '0 20px 40px rgba(0,0,0,.45)', transform: 'rotate(-4deg)', display: 'flex', alignItems: 'center', gap: 10 }}>
              <div style={{ width: 34, height: 34, borderRadius: 10, background: 'rgba(232,165,61,.18)', flexShrink: 0 }} />
              <div>
                <div style={{ font: '600 12px', color: '#f3ead9' }}>Jacey checked in</div>
                <div style={{ font: '500 11px', color: 'rgba(243,234,217,.5)' }}>2 min ago</div>
              </div>
            </div>
          </div>
        </div>
      </header>

      {/* ── How it feels ── */}
      <section style={{ borderTop: '1px solid rgba(243,234,217,.1)' }}>
        <div style={{ ...S.wrap, padding: '52px 24px' }}>
          <div style={{ ...S.eyebrow, marginBottom: 14 }}>How it feels day to day</div>
          <h2 style={{ font: "700 28px/1.2 'Space Grotesk', sans-serif", letterSpacing: '-0.01em', margin: '0 0 32px', maxWidth: 500 }}>
            A little bit of grace, every single day.
          </h2>
          <div className="hp-steps-grid">
            {steps.map(({ n, title, desc }) => (
              <div key={n} style={S.card}>
                <div style={{ width: 34, height: 34, borderRadius: 10, background: 'rgba(232,165,61,.18)', color: '#e8a53d', display: 'flex', alignItems: 'center', justifyContent: 'center', font: "700 14px 'Space Grotesk', sans-serif", marginBottom: 14 }}>
                  {n}
                </div>
                <div style={{ font: '600 14.5px', marginBottom: 6 }}>{title}</div>
                <div style={{ fontSize: 12.5, color: 'rgba(243,234,217,.6)' }}>{desc}</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── Features grid ── */}
      <section style={{ borderTop: '1px solid rgba(243,234,217,.1)' }}>
        <div style={{ ...S.wrap, padding: '52px 24px' }}>
          <div style={{ ...S.eyebrow, marginBottom: 14 }}>Everything you need</div>
          <h2 style={{ font: "700 28px/1.2 'Space Grotesk', sans-serif", letterSpacing: '-0.01em', margin: '0 0 32px', maxWidth: 500 }}>
            Every tool for the journey, in one place.
          </h2>
          <div className="hp-feat-grid">
            {features.map(({ icon, title, desc }) => (
              <div key={title} style={S.card}>
                <IconBox>{icon}</IconBox>
                <div style={{ font: "600 14.5px 'Space Grotesk', sans-serif", marginBottom: 8 }}>{title}</div>
                <div style={{ fontSize: 13, lineHeight: 1.6, color: 'rgba(243,234,217,.6)' }}>{desc}</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── Community spotlight ── */}
      <section style={{ borderTop: '1px solid rgba(243,234,217,.1)' }}>
        <div style={{ ...S.wrap, padding: '52px 24px' }}>
          <div className="hp-community-grid">
            <div>
              <div style={{ ...S.eyebrow, marginBottom: 14 }}>Built for community</div>
              <h2 style={{ font: "700 28px/1.2 'Space Grotesk', sans-serif", letterSpacing: '-0.01em', margin: '0 0 16px', maxWidth: 420 }}>
                Study together, wherever you are.
              </h2>
              <p style={{ fontSize: 14, color: 'rgba(243,234,217,.6)', lineHeight: 1.7, maxWidth: 380, margin: '0 0 28px' }}>
                The group plan gives up to five people a shared space to read, highlight, and grow — with real-time messaging and a live study feed of what everyone's been marking.
              </p>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                {[
                  'Shared reading & highlights across all members',
                  'Real-time group messaging and discussion',
                  'Each member gets their own AI companion',
                  "Host controls — manage who's in the group",
                ].map(perk => (
                  <div key={perk} style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
                    <div style={{ width: 18, height: 18, borderRadius: '50%', background: 'rgba(232,165,61,.18)', border: '1px solid rgba(232,165,61,.3)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, marginTop: 2 }}>
                      <svg width="9" height="9" viewBox="0 0 24 24" fill="none" stroke="#e8a53d" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
                        <polyline points="20 6 9 17 4 12" />
                      </svg>
                    </div>
                    <span style={{ fontSize: 13.5, color: 'rgba(243,234,217,.75)', lineHeight: 1.5 }}>{perk}</span>
                  </div>
                ))}
              </div>
              <div style={{ marginTop: 32 }}>
                <Link to={cta} style={S.btnPrimary}>Start a group →</Link>
              </div>
            </div>

            {/* Mock chat visual */}
            <div className="hp-community-visual" style={{ ...S.card, padding: 20, background: '#1e1610', border: '1px solid rgba(232,165,61,.12)' }}>
              <div style={{ font: "600 11px 'JetBrains Mono', monospace", letterSpacing: '0.12em', textTransform: 'uppercase', color: 'rgba(232,165,61,.5)', marginBottom: 16 }}>Morning Study — Romans 8</div>
              {[
                { name: 'Jacey', msg: 'v.28 hit different today — "all things work together for good." Highlighted it in yellow.', time: '7:04 am', mine: false },
                { name: 'You', msg: 'Same! I keep coming back to v.38-39. Nothing can separate us.', time: '7:11 am', mine: true },
                { name: 'Marcus', msg: 'v.26 is my anchor — the Spirit intercedes when we don\'t have words. 🙏', time: '7:18 am', mine: false },
              ].map(({ name, msg, time, mine }) => (
                <div key={name} style={{ display: 'flex', flexDirection: 'column', alignItems: mine ? 'flex-end' : 'flex-start', marginBottom: 14 }}>
                  {!mine && <div style={{ font: "600 10px 'Space Grotesk', sans-serif", color: '#e8a53d', marginBottom: 4, paddingLeft: 2 }}>{name}</div>}
                  <div style={{ maxWidth: '85%', padding: '9px 13px', borderRadius: 12, background: mine ? 'rgba(232,165,61,.15)' : 'rgba(255,255,255,.05)', border: mine ? '1px solid rgba(232,165,61,.25)' : '1px solid rgba(255,255,255,.08)', font: "400 12.5px/1.5 'Space Grotesk', sans-serif", color: 'rgba(243,234,217,.85)' }}>
                    {msg}
                  </div>
                  <div style={{ font: "400 10px", color: 'rgba(243,234,217,.25)', marginTop: 4, paddingLeft: 2, paddingRight: 2 }}>{time}</div>
                </div>
              ))}
              <div style={{ marginTop: 8, background: 'rgba(255,255,255,.04)', border: '1px solid rgba(255,255,255,.07)', borderRadius: 10, padding: '9px 12px', font: "400 12px 'Space Grotesk', sans-serif", color: 'rgba(243,234,217,.25)' }}>
                Share a thought…
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ── Plans ── */}
      <section style={{ borderTop: '1px solid rgba(243,234,217,.1)' }}>
        <div style={{ ...S.wrap, padding: '52px 24px' }}>
          <div style={{ ...S.eyebrow, marginBottom: 14 }}>Simple pricing</div>
          <h2 style={{ font: "700 28px/1.2 'Space Grotesk', sans-serif", letterSpacing: '-0.01em', margin: '0 0 8px', maxWidth: 500 }}>
            Start free. Grow at your own pace.
          </h2>
          <p style={{ fontSize: 13.5, color: 'rgba(243,234,217,.5)', margin: '0 0 32px' }}>Every paid plan starts with a free month — no card required to begin.</p>
          <div className="hp-plans-grid">
            {plans.map(({ name, price, sub, perks, cta: planCta, href, primary }) => (
              <div key={name} style={{ ...S.card, border: primary ? '1px solid rgba(232,165,61,.35)' : '1px solid rgba(243,234,217,.06)', position: 'relative', display: 'flex', flexDirection: 'column' }}>
                {primary && (
                  <div style={{ position: 'absolute', top: -1, left: 24, background: '#e8a53d', color: '#161310', font: "700 10px 'JetBrains Mono', monospace", letterSpacing: '0.1em', textTransform: 'uppercase', padding: '3px 10px', borderRadius: '0 0 8px 8px' }}>
                    Most popular
                  </div>
                )}
                <div style={{ marginBottom: 6 }}>
                  <div style={{ font: "600 13px 'Space Grotesk', sans-serif", color: 'rgba(243,234,217,.6)', marginBottom: 8 }}>{name}</div>
                  <div style={{ display: 'flex', alignItems: 'baseline', gap: 4 }}>
                    <span style={{ font: "700 32px/1 'Space Grotesk', sans-serif" }}>{price}</span>
                    {price !== '$0' && <span style={{ font: "400 13px 'Space Grotesk', sans-serif", color: 'rgba(243,234,217,.4)' }}>/mo</span>}
                  </div>
                  <div style={{ font: "400 12px 'Space Grotesk', sans-serif", color: 'rgba(243,234,217,.4)', marginTop: 4 }}>{sub}</div>
                </div>
                <div style={{ width: '100%', height: 1, background: 'rgba(243,234,217,.07)', margin: '20px 0' }} />
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10, flex: 1, marginBottom: 24 }}>
                  {perks.map(perk => (
                    <div key={perk} style={{ display: 'flex', alignItems: 'flex-start', gap: 9 }}>
                      <div style={{ width: 16, height: 16, borderRadius: '50%', background: 'rgba(232,165,61,.15)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, marginTop: 1 }}>
                        <svg width="8" height="8" viewBox="0 0 24 24" fill="none" stroke="#e8a53d" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
                          <polyline points="20 6 9 17 4 12" />
                        </svg>
                      </div>
                      <span style={{ fontSize: 13, color: 'rgba(243,234,217,.7)', lineHeight: 1.4 }}>{perk}</span>
                    </div>
                  ))}
                </div>
                <Link to={user ? '/account' : href} style={primary ? S.btnPrimary : { ...S.btnOutline, justifyContent: 'center' }}>
                  {planCta}
                </Link>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── Quote CTA ── */}
      <section style={{ borderTop: '1px solid rgba(243,234,217,.1)' }}>
        <div className="hp-quote-row" style={{ ...S.wrap, padding: '48px 24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 24, flexWrap: 'wrap' }}>
          <div>
            <p style={{ font: "600 22px/1.5 'Space Grotesk', sans-serif", letterSpacing: '-0.005em', margin: '0 0 8px', maxWidth: 560 }}>
              "As iron sharpens iron, so one person sharpens another."
            </p>
            <div style={S.eyebrow}>Proverbs 27:17</div>
          </div>
          <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
            <Link to={cta} style={S.btnPrimary}>Join free →</Link>
            <Link to="/reader" style={S.btnOutline}>Read the Bible</Link>
          </div>
        </div>
      </section>
    </div>
  );
}
