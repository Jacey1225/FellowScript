import React, { useRef } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { useParallaxBlobs } from '../hooks/useParallaxBlobs.js';

// ── Palette (this page only — a distinct marketing-site look from the app's
// own gold/parchment theme used in Reader/Account/etc.) ──────────────────────
const INK    = '#17120F';
const CREAM  = '#F6EFE6';
// Kept in the family of the in-app --gold-light (#E09A30) so the accent hue
// doesn't visibly shift on a Home→Reader signed-in transition (design-notes.md §6).
const AMBER  = '#E09A30';
const AMBER_LIGHT = '#F3C48B';
const LIGHT_BG = '#FBF7F1';
const LIGHT_INK = '#1A1512';

const HEAD_FONT = "'Schibsted Grotesk', sans-serif";
const BODY_FONT = "'Hanken Grotesk', system-ui, sans-serif";

// ── Small building blocks ─────────────────────────────────────────────────────

function Ico({ children, size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      {children}
    </svg>
  );
}

function Check() {
  return (
    <span style={{ display: 'grid', placeItems: 'center', width: 20, height: 20, borderRadius: '50%', background: 'rgba(232,163,85,0.2)', color: AMBER, flexShrink: 0, marginTop: 2 }}>
      <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
        <path d="M4 12.5l5.5 5.5L20 7" />
      </svg>
    </span>
  );
}

// Filled brand glyphs for the desktop-download platform badges (design-spec.md
// §7) — deliberately filled, not redrawn as 1.6px-stroke `Ico` outlines;
// outlined brand marks read as counterfeit. Both paths are the official
// simple-icons (MIT-licensed) brand marks — matches Apple/Microsoft's own
// marks exactly, not a hand-authored approximation.
function AppleMark({ size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701" />
    </svg>
  );
}

function WinMark({ size = 18 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M0,0H11.377V11.372H0ZM12.623,0H24V11.372H12.623ZM0,12.623H11.377V24H0Zm12.623,0H24V24H12.623" />
    </svg>
  );
}

function PillButton({ to, primary, children }) {
  const base = {
    display: 'inline-flex', alignItems: 'center', gap: 9,
    padding: '15px 26px', borderRadius: 999,
    fontFamily: BODY_FONT, fontSize: 14, fontWeight: 600, letterSpacing: '0.01em',
  };
  const style = primary
    ? { ...base, background: AMBER, color: '#21160F' }
    : { ...base, border: '1px solid rgba(255,244,230,0.4)', color: '#FFF8EE', background: 'rgba(23,18,15,0.2)' };
  return <Link to={to} className={primary ? 'hm-btn-primary' : 'hm-btn-outline'} style={style}>{children}</Link>;
}

// Radial-gradient blob field + drifting dust, shared by Hero and Community.
function Blobs({ innerRef, overlay }) {
  return (
    <div ref={innerRef} style={{ position: 'absolute', inset: 0, overflow: 'hidden', pointerEvents: 'none' }}>
      <div data-fs-blob="1" data-fs-depth="0.05" style={{ position: 'absolute', width: '76vw', height: '76vw', minWidth: 720, minHeight: 720, left: '4%', top: '8%', borderRadius: '50%', background: 'radial-gradient(circle at 34% 26%, #FFEBCF 0%, #F0B36A 18%, #E8A355 30%, #C4682F 52%, #8A3A2C 70%, #351914 100%)', boxShadow: '0 0 300px 90px rgba(232,163,85,0.22)', willChange: 'transform' }} />
      <div data-fs-blob="2" data-fs-depth="-0.09" style={{ position: 'absolute', width: '40vw', height: '40vw', minWidth: 420, minHeight: 420, right: '-8%', top: '-12%', borderRadius: '50%', background: 'radial-gradient(circle at 60% 70%, rgba(240,179,106,0.85) 0%, rgba(150,62,44,0.6) 45%, rgba(23,18,15,0) 78%)', filter: 'blur(6px)', willChange: 'transform' }} />
      <div data-fs-blob="3" data-fs-depth="0.13" style={{ position: 'absolute', width: '34vw', height: '34vw', minWidth: 340, minHeight: 340, left: '-10%', bottom: '-14%', borderRadius: '50%', background: 'radial-gradient(circle at 40% 40%, rgba(232,163,85,0.5) 0%, rgba(90,40,32,0.4) 50%, rgba(23,18,15,0) 80%)', filter: 'blur(10px)', willChange: 'transform' }} />
      <div data-fs-dust="1" style={{ position: 'absolute', inset: '-6%' }} />
      <div style={{ position: 'absolute', inset: 0, background: overlay }} />
    </div>
  );
}

// ── Desktop download (On your desktop section) ────────────────────────────────
// Live GitHub Release asset (desktop-v0.1.0) — resolved per the user's
// Discord answer (task 20260902-download-section-implementation follow-up).
// Per that same answer, no OS-floor claim is displayed at all (see the
// macOS card's metadata line below) — this is a user-facing marketing
// value, a reasonable future candidate to promote to a small config/env
// value rather than staying hardcoded here, but not required for now.
const MACOS_DOWNLOAD_URL = 'https://github.com/Jacey1225/FellowScript/releases/download/desktop-v0.1.0/FellowScript.dmg';

// ── Content (kept in sync with the real backend — dynamic 1-8 member group pricing) ──

const steps = [
  { n: '01', title: 'Open the Word',          desc: 'Read at your pace, highlight what speaks to you.' },
  { n: '02', title: 'Set a gentle rhythm',    desc: 'Daily check-ins that meet you where you are.' },
  { n: '03', title: 'Share with your people', desc: 'Notes, highlights, live study with your circle.' },
];

const features = [
  {
    icon: <><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H19v15H6.5A2.5 2.5 0 0 0 4 20.5z" /><path d="M4 5.5v15" /></>,
    title: 'Beautiful Bible Reader',
    desc: 'Adjustable text size, navigate any book, and read distraction-free.',
  },
  {
    icon: <><path d="M9 14l-3 3v3h4l9-9-4-4-6 6z" /><path d="M4 21h16" /></>,
    title: 'Verse Highlights',
    desc: 'Four distinct highlight colors, saved the moment you mark them.',
  },
  {
    icon: <><path d="M15 4l5 5L9 20H4v-5z" /><path d="M13.5 5.5l5 5" /></>,
    title: 'Scripture Notes',
    desc: 'Tie reflections to specific verses and build a personal library.',
  },
  {
    icon: <path d="M12 3l2.4 5.6L20 11l-5.6 2.4L12 19l-2.4-5.6L4 11l5.6-2.4z" />,
    title: 'AI Daily Check-ins',
    desc: 'A gentle, personal question each day, rooted in Scripture.',
  },
  {
    icon: <><circle cx="9" cy="8" r="3.2" /><path d="M3 20c0-3.3 2.7-5.5 6-5.5s6 2.2 6 5.5" /><path d="M16 5.5a3 3 0 0 1 0 5.6" /><path d="M18 20c0-2.6-1-4.4-2.6-5.3" /></>,
    title: 'Group Bible Study',
    desc: 'Up to eight people in a shared reading space with real-time messaging.',
  },
  {
    icon: <path d="M6 3h12v18l-6-4.5L6 21z" />,
    title: 'Verse Bookmarks',
    desc: 'Save any passage instantly and return to your own treasury.',
  },
];

const communityPerks = [
  'Shared reading & highlights across all members',
  'Real-time group messaging and discussion',
  'Each member gets their own AI companion',
  "Host controls — manage who's in the group",
];

const chatMock = [
  { name: 'Jacey',  msg: 'v.28 hit different today. Highlighted the whole verse.', time: '7:14 AM', avatar: 'J', reaction: '🙌 3' },
  { name: 'Samel',  msg: 'Same. Been sitting with "groanings too deep for words" all week.', time: '7:21 AM', avatar: 'S' },
  { name: 'Marcus', msg: 'Adding a note before work. See you all at the 6pm study.', time: '7:36 AM', avatar: 'M', reaction: '❤️ 2' },
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
    name: 'Group',
    price: 'From $10',
    sub: 'Pick 1 to 8 members · 1 month free trial',
    perks: ['Unlimited notes', 'Unlimited AI check-ins', 'Unlimited notifications', 'Shared reading space & group chat', 'Live study sessions', 'Priority support'],
    cta: 'Start free trial',
    href: '/signin',
    primary: true,
  },
];

// ── Page ──────────────────────────────────────────────────────────────────────

export default function Home() {
  const { user } = useAuth();
  const cta = user ? '/reader' : '/signin';

  const heroBgRef = useRef(null);
  const communityBgRef = useRef(null);
  useParallaxBlobs([heroBgRef, communityBgRef]);

  return (
    <div style={{ fontFamily: BODY_FONT, color: CREAM, background: INK, overflowX: 'hidden' }}>
      <style>{`
        @keyframes hm-orbit { to { transform: rotate(360deg); } }
        @keyframes hm-float { 0%,100% { transform: translateY(0); } 50% { transform: translateY(-14px); } }
        @media (prefers-reduced-motion: reduce) {
          .hm-float, .hm-orbit-spin { animation: none !important; }
          .hm-dl-mac { transition: none !important; }
          .hm-dl-mac:hover { transform: none !important; }
        }

        .hm-nav-link { color: rgba(255,248,238,0.82); }
        .hm-nav-link:hover { color: #FFF8EE; }
        .hm-btn-primary:hover { background: ${AMBER_LIGHT} !important; }
        .hm-btn-outline:hover { border-color: #FFF8EE !important; background: rgba(255,244,230,0.12) !important; }
        .hm-footer-link { color: ${LIGHT_INK}; }
        .hm-footer-link:hover { color: #B4712C; }

        .hm-dl-mac { transition: transform 220ms cubic-bezier(0.22,0.61,0.36,1), border-color 220ms cubic-bezier(0.22,0.61,0.36,1), box-shadow 220ms cubic-bezier(0.22,0.61,0.36,1); }
        .hm-dl-mac:hover { transform: translateY(-4px); border-color: rgba(255,244,230,0.30); box-shadow: 0 48px 100px -50px rgba(232,163,85,0.35), 0 40px 90px -50px rgba(0,0,0,0.9); }

        .hm-hero-grid { display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(0, 0.85fr); gap: clamp(24px, 5vw, 72px); align-items: center; }
        .hm-hero-cards { display: flex; flex-direction: column; align-items: flex-end; gap: 22px; }
        @media (max-width: 860px) {
          .hm-hero-grid  { grid-template-columns: 1fr; }
          .hm-hero-cards { display: none; }
        }
      `}</style>

      {/* ══ Hero ══ */}
      <section style={{ position: 'relative', minHeight: '100vh', overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
        <Blobs innerRef={heroBgRef} overlay="linear-gradient(180deg, rgba(23,18,15,0.55) 0%, rgba(23,18,15,0.15) 35%, rgba(23,18,15,0.45) 78%, #17120F 100%)" />

        <header style={{ position: 'relative', zIndex: 3, display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 24, padding: '26px clamp(20px, 5vw, 64px)' }}>
          <Link to="/" style={{ fontFamily: HEAD_FONT, fontSize: 19, fontWeight: 600, letterSpacing: '-0.01em', color: '#FFF8EE', textDecoration: 'none' }}>
            FellowScript
          </Link>
          <nav style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 4, padding: 5, borderRadius: 999, background: 'rgba(23,18,15,0.28)', border: '1px solid rgba(255,244,230,0.16)', backdropFilter: 'blur(10px)' }}>
              <Link to="/" style={{ display: 'block', padding: '8px 16px', borderRadius: 999, fontSize: 12.5, letterSpacing: '0.08em', textTransform: 'uppercase', color: '#FFF8EE', background: 'rgba(255,244,230,0.14)', textDecoration: 'none' }}>Home</Link>
              <Link to="/reader" className="hm-nav-link" style={{ display: 'block', padding: '8px 16px', borderRadius: 999, fontSize: 12.5, letterSpacing: '0.08em', textTransform: 'uppercase', textDecoration: 'none' }}>Read</Link>
              {user && (
                <Link to="/account" className="hm-nav-link" style={{ display: 'block', padding: '8px 16px', borderRadius: 999, fontSize: 12.5, letterSpacing: '0.08em', textTransform: 'uppercase', textDecoration: 'none' }}>Account</Link>
              )}
            </div>
            <PillButton to={cta} primary>{user ? 'Open app' : 'Get started'}</PillButton>
          </nav>
        </header>

        <div className="hm-hero-grid" style={{ position: 'relative', zIndex: 2, flex: 1, maxWidth: 1400, margin: '0 auto', width: '100%', padding: 'clamp(40px, 6vh, 90px) clamp(20px, 5vw, 64px) clamp(28px, 5vh, 64px)' }}>
          <div style={{ maxWidth: 760 }}>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 9, padding: '7px 15px 7px 12px', borderRadius: 999, background: 'rgba(23,18,15,0.4)', border: '1px solid rgba(255,244,230,0.2)', backdropFilter: 'blur(8px)', marginBottom: 34 }}>
              <span style={{ width: 7, height: 7, borderRadius: '50%', background: AMBER, boxShadow: '0 0 10px 2px rgba(232,163,85,0.7)' }} />
              <span style={{ fontSize: 12, letterSpacing: '0.04em', color: '#FFF3E2' }}>Now with daily AI check-ins</span>
            </div>
            <div style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.28em', textTransform: 'uppercase', color: '#F0C08A', marginBottom: 22 }}>// FELLOWSCRIPT</div>
            <h1 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(44px, 6.4vw, 104px)', lineHeight: 0.96, fontWeight: 400, letterSpacing: '-0.035em', color: '#FFF9F0', margin: '0 0 28px', textWrap: 'balance' }}>
              You don't have to walk with God <span style={{ color: 'rgba(255,249,240,0.62)' }}>alone.</span>
            </h1>
            <p style={{ fontSize: 'clamp(15px, 1.25vw, 19px)', lineHeight: 1.6, color: 'rgba(255,243,228,0.86)', maxWidth: '30em', margin: '0 0 40px' }}>
              A friendly AI companion, a daily rhythm, and people who show up with you — every single day.
            </p>
            <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 14 }}>
              <PillButton to={cta} primary>Begin your journey <span>→</span></PillButton>
              <PillButton to="/reader">Read scripture</PillButton>
            </div>
          </div>

          <div className="hm-hero-cards">
            <div className="hm-float" style={{ width: 'min(400px, 100%)', padding: '26px 28px 28px', borderRadius: 20, background: 'rgba(28,21,17,0.66)', border: '1px solid rgba(255,244,230,0.18)', backdropFilter: 'blur(18px)', boxShadow: '0 30px 70px -30px rgba(20,10,5,0.8)', animation: 'hm-float 9s ease-in-out infinite' }}>
              <div style={{ fontFamily: HEAD_FONT, fontSize: 11, letterSpacing: '0.22em', textTransform: 'uppercase', color: '#F0C08A', marginBottom: 18 }}>// TODAY'S VERSE</div>
              <p style={{ fontFamily: HEAD_FONT, fontSize: 21, lineHeight: 1.42, fontWeight: 400, letterSpacing: '-0.015em', color: '#FFF9F0', margin: '0 0 16px' }}>
                "Be still, and know that I am God."
              </p>
              <div style={{ fontSize: 12.5, letterSpacing: '0.06em', color: 'rgba(255,243,228,0.6)' }}>PSALM 46:10</div>
            </div>
            <div style={{ width: 'min(330px, 100%)', display: 'flex', alignItems: 'center', gap: 13, padding: '15px 18px', borderRadius: 16, background: 'rgba(28,21,17,0.7)', border: '1px solid rgba(255,244,230,0.16)', backdropFilter: 'blur(18px)', boxShadow: '0 24px 56px -28px rgba(20,10,5,0.8)', animation: 'hm-float 11s ease-in-out 1.2s infinite' }}>
              <span style={{ display: 'grid', placeItems: 'center', width: 36, height: 36, borderRadius: '50%', background: AMBER, color: '#21160F', fontSize: 14, fontWeight: 600, flexShrink: 0 }}>J</span>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 3, minWidth: 0 }}>
                <span style={{ fontSize: 14, color: '#FFF9F0' }}>Jacey checked in</span>
                <span style={{ fontSize: 12, color: 'rgba(255,243,228,0.55)' }}>2 min ago</span>
              </div>
            </div>
          </div>
        </div>

        <div style={{ position: 'relative', zIndex: 2, display: 'flex', alignItems: 'center', gap: 18, padding: '0 clamp(20px, 5vw, 64px) clamp(32px, 5vh, 56px)' }}>
          <div style={{ position: 'relative', width: 62, height: 62, borderRadius: '50%', border: '1px solid rgba(255,244,230,0.45)', flexShrink: 0 }}>
            <div className="hm-orbit-spin" style={{ position: 'absolute', inset: 0, animation: 'hm-orbit 5.5s linear infinite' }}>
              <span style={{ position: 'absolute', top: 5, left: '50%', width: 5, height: 5, marginLeft: -2.5, borderRadius: '50%', background: '#FFF8EE' }} />
              <span style={{ position: 'absolute', bottom: 12, left: '30%', width: 3, height: 3, borderRadius: '50%', background: 'rgba(255,248,238,0.7)' }} />
            </div>
          </div>
          <span style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.24em', textTransform: 'uppercase', color: 'rgba(255,248,238,0.8)' }}>Learn more</span>
        </div>
      </section>

      {/* ══ How it feels ══ */}
      <section style={{ padding: 'clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)', background: INK }}>
        <div style={{ maxWidth: 1240, margin: '0 auto' }}>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: AMBER, paddingBottom: 22, borderBottom: '1px solid rgba(255,244,230,0.14)', marginBottom: 56 }}>// HOW IT FEELS DAY TO DAY</div>
          <h2 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(34px, 5vw, 74px)', lineHeight: 1.02, fontWeight: 400, letterSpacing: '-0.03em', margin: '0 0 clamp(56px, 8vh, 110px)', maxWidth: '20em', color: '#FFF9F0' }}>
            A little bit of <span style={{ color: 'rgba(255,249,240,0.42)' }}>grace,</span> every single day.
          </h2>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 'clamp(20px, 3vw, 44px)' }}>
            {steps.map(({ n, title, desc }) => (
              <div key={n} style={{ display: 'flex', flexDirection: 'column', gap: 18, paddingTop: 28, borderTop: '1px solid rgba(255,244,230,0.16)' }}>
                <span style={{ display: 'grid', placeItems: 'center', width: 38, height: 38, borderRadius: 11, background: 'rgba(232,163,85,0.16)', border: '1px solid rgba(232,163,85,0.35)', color: AMBER, fontFamily: HEAD_FONT, fontSize: 14, fontWeight: 600 }}>{n}</span>
                <h3 style={{ fontFamily: HEAD_FONT, fontSize: 23, fontWeight: 500, letterSpacing: '-0.02em', margin: 0, color: '#FFF9F0' }}>{title}</h3>
                <p style={{ fontSize: 15.5, lineHeight: 1.65, color: 'rgba(255,243,228,0.62)', margin: 0, maxWidth: '26em' }}>{desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ══ Everything you need ══ */}
      <section style={{ padding: 'clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)', background: LIGHT_BG, color: LIGHT_INK }}>
        <div style={{ maxWidth: 1240, margin: '0 auto' }}>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: '#B4712C', paddingBottom: 22, borderBottom: '1px solid rgba(26,21,18,0.14)', marginBottom: 56 }}>// EVERYTHING YOU NEED</div>
          <h2 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(34px, 5vw, 74px)', lineHeight: 1.02, fontWeight: 400, letterSpacing: '-0.03em', margin: '0 0 clamp(56px, 8vh, 104px)', maxWidth: '22em', color: LIGHT_INK }}>
            Every tool for <span style={{ color: 'rgba(26,21,18,0.38)' }}>the journey,</span> in one place.
          </h2>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: 'clamp(18px, 2.2vw, 28px)' }}>
            {features.map(({ icon, title, desc }) => (
              <div key={title} style={{ display: 'flex', flexDirection: 'column', gap: 16, padding: '32px 30px 36px', border: '1px solid rgba(26,21,18,0.13)', borderRadius: 18, background: '#FFFDFA' }}>
                <span style={{ display: 'grid', placeItems: 'center', width: 42, height: 42, borderRadius: 12, background: 'rgba(232,163,85,0.2)', color: '#A9631F' }}>
                  <Ico>{icon}</Ico>
                </span>
                <h3 style={{ fontFamily: HEAD_FONT, fontSize: 21, fontWeight: 500, letterSpacing: '-0.02em', margin: '4px 0 0', color: LIGHT_INK }}>{title}</h3>
                <p style={{ fontSize: 15, lineHeight: 1.66, color: 'rgba(26,21,18,0.62)', margin: 0 }}>{desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ══ Built for community ══ */}
      <section style={{ position: 'relative', overflow: 'hidden', padding: 'clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)', background: INK }}>
        <Blobs innerRef={communityBgRef} overlay="linear-gradient(180deg, #17120F 0%, rgba(23,18,15,0.42) 22%, rgba(23,18,15,0.5) 72%, #17120F 100%)" />
        <div style={{ position: 'relative', zIndex: 1, maxWidth: 1240, margin: '0 auto' }}>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: AMBER, paddingBottom: 22, borderBottom: '1px solid rgba(255,244,230,0.14)', marginBottom: 56 }}>// BUILT FOR COMMUNITY</div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))', gap: 'clamp(40px, 6vw, 90px)', alignItems: 'start' }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 34 }}>
              <h2 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(32px, 4.2vw, 62px)', lineHeight: 1.03, fontWeight: 400, letterSpacing: '-0.03em', margin: 0, color: '#FFF9F0' }}>
                Study together, <span style={{ color: 'rgba(255,249,240,0.42)' }}>wherever you are.</span>
              </h2>
              <p style={{ fontSize: 16.5, lineHeight: 1.7, color: 'rgba(255,243,228,0.66)', margin: 0, maxWidth: '34em' }}>
                The group plan gives up to eight people a shared space to read, highlight, and grow — with real-time messaging and a live study feed of what everyone's been marking.
              </p>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 15 }}>
                {communityPerks.map(perk => (
                  <div key={perk} style={{ display: 'flex', alignItems: 'flex-start', gap: 13 }}>
                    <Check />
                    <span style={{ fontSize: 15.5, lineHeight: 1.55, color: 'rgba(255,243,228,0.86)' }}>{perk}</span>
                  </div>
                ))}
              </div>
              <PillButton to={cta} primary>Start a group <span>→</span></PillButton>
            </div>

            <div style={{ border: '1px solid rgba(255,244,230,0.16)', borderRadius: 22, background: '#1F1815', overflow: 'hidden', boxShadow: '0 40px 90px -50px rgba(0,0,0,0.9)' }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 16, padding: '20px 24px', borderBottom: '1px solid rgba(255,244,230,0.12)' }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <span style={{ fontFamily: HEAD_FONT, fontSize: 16, fontWeight: 500, color: '#FFF9F0' }}>Morning Study — Romans 8</span>
                  <span style={{ fontSize: 12, color: 'rgba(255,243,228,0.5)' }}>3 of 8 members reading now</span>
                </div>
                <span style={{ width: 8, height: 8, borderRadius: '50%', background: '#7FC08A', boxShadow: '0 0 10px 2px rgba(127,192,138,0.5)', flexShrink: 0 }} />
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: 24 }}>
                {chatMock.map(({ name, msg, time, avatar, reaction }) => (
                  <div key={name} style={{ display: 'flex', gap: 12 }}>
                    <span style={{ display: 'grid', placeItems: 'center', width: 32, height: 32, borderRadius: '50%', background: avatar === 'J' ? AMBER : 'rgba(255,244,230,0.16)', color: avatar === 'J' ? '#21160F' : '#FFF9F0', fontSize: 13, fontWeight: 600, flexShrink: 0 }}>{avatar}</span>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 7, minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'baseline', gap: 9 }}>
                        <span style={{ fontSize: 13.5, fontWeight: 600, color: '#FFF9F0' }}>{name}</span>
                        <span style={{ fontSize: 11.5, color: 'rgba(255,243,228,0.45)' }}>{time}</span>
                      </div>
                      <div style={{ padding: '13px 16px', borderRadius: '4px 14px 14px 14px', background: 'rgba(255,244,230,0.07)', border: '1px solid rgba(255,244,230,0.1)', fontSize: 14.5, lineHeight: 1.6, color: 'rgba(255,243,228,0.88)' }}>{msg}</div>
                      {reaction && (
                        <div style={{ display: 'flex', gap: 6 }}>
                          <span style={{ padding: '3px 9px', borderRadius: 999, background: 'rgba(232,163,85,0.14)', border: '1px solid rgba(232,163,85,0.28)', fontSize: 11.5, color: 'rgba(255,243,228,0.8)' }}>{reaction}</span>
                        </div>
                      )}
                    </div>
                  </div>
                ))}
              </div>
              <div style={{ padding: '14px 24px 20px', borderTop: '1px solid rgba(255,244,230,0.1)', fontSize: 12.5, letterSpacing: '0.04em', color: 'rgba(255,243,228,0.45)' }}>Jacey highlighted Romans 8:28 · just now</div>
            </div>
          </div>
        </div>
      </section>

      {/* ══ Pricing ══ */}
      <section style={{ padding: 'clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)', background: LIGHT_BG, color: LIGHT_INK }}>
        <div style={{ maxWidth: 1240, margin: '0 auto' }}>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: '#B4712C', paddingBottom: 22, borderBottom: '1px solid rgba(26,21,18,0.14)', marginBottom: 56 }}>// SIMPLE PRICING</div>
          <h2 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(34px, 5vw, 74px)', lineHeight: 1.02, fontWeight: 400, letterSpacing: '-0.03em', margin: '0 0 24px', maxWidth: '20em', color: LIGHT_INK }}>
            Start free. <span style={{ color: 'rgba(26,21,18,0.38)' }}>Grow at your own pace.</span>
          </h2>
          <p style={{ fontSize: 16.5, lineHeight: 1.65, color: 'rgba(26,21,18,0.6)', margin: '0 0 clamp(48px, 7vh, 88px)', maxWidth: '32em' }}>Every paid plan starts with a free month — no card required to begin.</p>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 'clamp(20px, 2.4vw, 32px)', alignItems: 'stretch' }}>
            {plans.map(({ name, price, sub, perks, cta: planCta, href, primary }) => (
              <div key={name} style={primary
                ? { position: 'relative', display: 'flex', flexDirection: 'column', gap: 26, padding: '38px 34px 40px', border: '1px solid rgba(26,21,18,0.9)', borderRadius: 20, background: LIGHT_INK, color: '#FFF9F0' }
                : { display: 'flex', flexDirection: 'column', gap: 26, padding: '38px 34px 40px', border: '1px solid rgba(26,21,18,0.14)', borderRadius: 20, background: '#FFFDFA' }
              }>
                {primary && (
                  <span style={{ position: 'absolute', top: 22, right: 26, padding: '6px 12px', borderRadius: 999, background: AMBER, color: '#21160F', fontSize: 10.5, fontWeight: 600, letterSpacing: '0.14em', textTransform: 'uppercase' }}>Most popular</span>
                )}
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  <span style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.2em', textTransform: 'uppercase', color: primary ? '#F0C08A' : 'rgba(26,21,18,0.55)' }}>{name}</span>
                  <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ fontFamily: HEAD_FONT, fontSize: 52, fontWeight: 400, letterSpacing: '-0.04em', color: primary ? '#FFF9F0' : LIGHT_INK }}>{price}</span>
                    {price !== '$0' && <span style={{ fontSize: 15, color: primary ? 'rgba(255,243,228,0.6)' : 'rgba(26,21,18,0.5)' }}>/mo</span>}
                  </div>
                  <span style={{ fontSize: 14, color: primary ? 'rgba(255,243,228,0.6)' : 'rgba(26,21,18,0.5)' }}>{sub}</span>
                </div>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12, fontSize: 15, lineHeight: 1.5, color: primary ? 'rgba(255,243,228,0.82)' : 'rgba(26,21,18,0.72)', flex: 1 }}>
                  {perks.map(perk => <span key={perk}>{perk}</span>)}
                </div>
                <Link
                  to={user ? '/account' : href}
                  style={primary
                    ? { display: 'inline-flex', alignItems: 'center', justifyContent: 'center', marginTop: 'auto', padding: '16px 24px', borderRadius: 999, background: AMBER, color: '#21160F', fontSize: 14.5, fontWeight: 600 }
                    : { display: 'inline-flex', alignItems: 'center', justifyContent: 'center', marginTop: 'auto', padding: '16px 24px', borderRadius: 999, border: '1px solid rgba(26,21,18,0.28)', color: LIGHT_INK, fontSize: 14.5, fontWeight: 600 }
                  }
                >
                  {planCta}
                </Link>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ══ On your desktop ══ */}
      <section style={{ position: 'relative', overflow: 'hidden', padding: 'clamp(90px, 13vh, 180px) clamp(20px, 5vw, 64px)', background: INK }}>
        <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', pointerEvents: 'none' }}>
          <div style={{
            position: 'absolute',
            top: 'clamp(-140px, -9vh, -70px)',
            right: 'clamp(-60px, -6vw, -20px)',
            width: 'clamp(260px, 28vw, 420px)',
            height: 'clamp(260px, 28vw, 420px)',
            borderRadius: '50%',
            background: 'radial-gradient(circle at 45% 40%, rgba(240,179,106,0.24) 0%, rgba(164,74,45,0.16) 42%, rgba(23,18,15,0) 74%)',
            filter: 'blur(12px)',
          }} />
        </div>
        <div style={{ position: 'relative', zIndex: 1, maxWidth: 1240, margin: '0 auto' }}>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: AMBER, paddingBottom: 22, borderBottom: '1px solid rgba(255,244,230,0.14)', marginBottom: 56 }}>// ON YOUR DESKTOP</div>
          <h2 style={{ fontFamily: HEAD_FONT, fontWeight: 400, fontSize: 'clamp(32px, 4.2vw, 62px)', lineHeight: 1.03, letterSpacing: '-0.03em', color: '#FFF9F0', margin: '0 0 24px' }}>
            Out of the browser, <span style={{ color: 'rgba(255,249,240,0.42)' }}>into a window of its own.</span>
          </h2>
          <p style={{ fontFamily: BODY_FONT, fontSize: 16.5, lineHeight: 1.7, color: 'rgba(255,243,228,0.66)', maxWidth: '34em', margin: '0 0 clamp(48px, 7vh, 88px)' }}>
            The desktop app opens straight into your reading — one calm window, no tabs, no browser chrome, sitting right where you left it.
          </p>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 'clamp(20px, 2.4vw, 32px)', alignItems: 'stretch' }}>
            {/* macOS card — primary, live */}
            <div style={{
              position: 'relative', display: 'flex', flexDirection: 'column', gap: 18,
              padding: '38px 34px 40px', borderRadius: 20,
              background: 'rgba(255,244,230,0.055)',
              border: '1px solid rgba(255,244,230,0.18)',
              boxShadow: '0 40px 90px -50px rgba(0,0,0,0.9)',
            }} className="hm-dl-card hm-dl-mac">
              <span style={{
                display: 'grid', placeItems: 'center', width: 42, height: 42, borderRadius: 12,
                background: 'rgba(232,163,85,0.16)', border: '1px solid rgba(232,163,85,0.30)', color: AMBER,
              }}>
                <AppleMark size={20} />
              </span>
              <span style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.2em', textTransform: 'uppercase', color: '#F0C08A' }}>MACOS</span>
              <h3 style={{ fontFamily: HEAD_FONT, fontSize: 21, fontWeight: 500, letterSpacing: '-0.02em', margin: 0, color: '#FFF9F0' }}>Signed, notarized, ready</h3>
              <p style={{ fontSize: 15, lineHeight: 1.6, color: 'rgba(255,243,228,0.7)', margin: 0 }}>One download, no gatekeeper warnings — just open it.</p>
              <div style={{ flex: 1 }} />
              {/* Live GitHub Release asset — plain <a>, not <Link>: this points
                  at a hosted file, not an internal route. */}
              <a
                href={MACOS_DOWNLOAD_URL}
                download
                className="hm-btn-primary"
                style={{
                  display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 9,
                  padding: '16px 24px', borderRadius: 999,
                  background: AMBER, color: '#21160F',
                  fontFamily: BODY_FONT, fontSize: 14.5, fontWeight: 600, letterSpacing: '0.01em',
                  textDecoration: 'none',
                }}
              >
                Download for Mac <span aria-hidden="true">↓</span>
              </a>
              {/* No OS-floor claim per the user's answer (critique.md §4 item 4's
                  own suggested fallback) — two verified facts only: file size
                  from the built .dmg, architecture support from the Tauri
                  build target. */}
              <div style={{ fontFamily: BODY_FONT, fontSize: 12.5, letterSpacing: '0.04em', color: 'rgba(255,243,228,0.58)', textAlign: 'center' }}>
                Apple silicon &amp; Intel · 3 MB
              </div>
            </div>

            {/* Windows card — recessed, present-but-not-live. No <button>/<a>/
                tabIndex/role="button"/hover/cursor-pointer anywhere in this card. */}
            <div style={{
              position: 'relative', display: 'flex', flexDirection: 'column', gap: 18,
              padding: '38px 34px 40px', borderRadius: 20,
              background: 'rgba(255,244,230,0.028)',
              border: '1px solid rgba(255,244,230,0.13)',
              cursor: 'default',
            }} className="hm-dl-card">
              <span style={{
                position: 'absolute', top: 22, right: 26, padding: '6px 12px', borderRadius: 999,
                background: 'rgba(232,163,85,0.14)', border: '1px solid rgba(232,163,85,0.28)',
                color: 'rgba(255,243,228,0.8)', fontSize: 10.5, fontWeight: 600, letterSpacing: '0.14em', textTransform: 'uppercase',
              }}>
                Coming soon
              </span>
              <span style={{
                display: 'grid', placeItems: 'center', width: 42, height: 42, borderRadius: 12,
                background: 'rgba(232,163,85,0.16)', border: '1px solid rgba(232,163,85,0.30)', color: AMBER,
              }}>
                <WinMark size={18} />
              </span>
              <span style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.2em', textTransform: 'uppercase', color: '#F0C08A' }}>WINDOWS</span>
              <h3 style={{ fontFamily: HEAD_FONT, fontSize: 21, fontWeight: 500, letterSpacing: '-0.02em', margin: 0, color: '#FFF9F0' }}>Still in the workshop</h3>
              <p style={{ fontSize: 15, lineHeight: 1.6, color: 'rgba(255,243,228,0.7)', margin: 0 }}>We started on macOS. The Windows build is on the way.</p>
              <div style={{ flex: 1 }} />
              {/* padding: '16px 0' (not '16px 24px') and textAlign: 'left' below
                  (not 'center') — critique.md §5 fixes for the 24px orphan
                  indent / mismatched centering axis. */}
              <div style={{
                display: 'flex', alignItems: 'center', justifyContent: 'flex-start',
                padding: '16px 0',
                fontFamily: BODY_FONT, fontSize: 15, fontWeight: 400, letterSpacing: '0.01em',
                color: 'rgba(255,243,228,0.66)',
              }}>
                Windows 10 &amp; 11
              </div>
              <div style={{ fontFamily: BODY_FONT, fontSize: 12.5, letterSpacing: '0.04em', color: 'rgba(255,243,228,0.58)', textAlign: 'left' }}>
                We'll post it here first — no signup needed.
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ══ Closing CTA ══ */}
      <section style={{ position: 'relative', overflow: 'hidden', padding: 'clamp(90px, 15vh, 190px) clamp(20px, 5vw, 64px)', background: INK }}>
        <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
          <div style={{ position: 'absolute', width: '60vw', height: '60vw', minWidth: 480, minHeight: 480, left: '50%', top: '20%', transform: 'translateX(-50%)', borderRadius: '50%', background: 'radial-gradient(circle at 45% 40%, rgba(240,179,106,0.4) 0%, rgba(164,74,45,0.28) 42%, rgba(23,18,15,0) 74%)', filter: 'blur(10px)' }} />
        </div>
        <div style={{ position: 'relative', maxWidth: 1000, margin: '0 auto', textAlign: 'center', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 40 }}>
          <blockquote style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(30px, 4.2vw, 62px)', lineHeight: 1.08, fontWeight: 400, letterSpacing: '-0.03em', color: '#FFF9F0', margin: 0, textWrap: 'balance' }}>
            "As iron sharpens iron, <span style={{ color: 'rgba(255,249,240,0.45)' }}>so one person sharpens another."</span>
          </blockquote>
          <div style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.24em', textTransform: 'uppercase', color: '#F0C08A' }}>Proverbs 27:17</div>
          <div style={{ display: 'flex', flexWrap: 'wrap', justifyContent: 'center', gap: 14 }}>
            <PillButton to={cta} primary>Join free <span>→</span></PillButton>
            <PillButton to="/reader">Read the Bible</PillButton>
          </div>
        </div>
      </section>

      {/* ══ Footer ══ */}
      <footer style={{ padding: 'clamp(60px, 9vh, 110px) clamp(20px, 5vw, 64px) 44px', background: LIGHT_BG, color: LIGHT_INK }}>
        <div style={{ maxWidth: 1240, margin: '0 auto', display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 'clamp(36px, 5vw, 72px)' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: '#B4712C' }}>// FELLOWSCRIPT</div>
            <div style={{ fontFamily: HEAD_FONT, fontSize: 26, fontWeight: 500, letterSpacing: '-0.025em', color: LIGHT_INK }}>Walk with God, together.</div>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
            <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: '#B4712C' }}>// NAVIGATION</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 11 }}>
              <Link to="/" className="hm-footer-link" style={{ fontSize: 15.5, textDecoration: 'none' }}>Home</Link>
              <Link to="/reader" className="hm-footer-link" style={{ fontSize: 15.5, textDecoration: 'none' }}>Read</Link>
              {user && <Link to="/account" className="hm-footer-link" style={{ fontSize: 15.5, textDecoration: 'none' }}>Account</Link>}
            </div>
          </div>
        </div>
        <div style={{ maxWidth: 1240, margin: 'clamp(48px, 7vh, 90px) auto 0', paddingTop: 22, borderTop: '1px solid rgba(26,21,18,0.14)', display: 'flex', flexWrap: 'wrap', gap: 12, justifyContent: 'space-between', fontSize: 12.5, color: 'rgba(26,21,18,0.5)' }}>
          <span>© 2026 FellowScript</span>
          <span>Made for daily rhythm.</span>
        </div>
      </footer>
    </div>
  );
}
