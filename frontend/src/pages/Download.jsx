import React from 'react';
import { Link } from 'react-router-dom';
import Seo from '../components/Seo.jsx';
import { isMobileUserAgent } from '../lib/deviceGate.js';

// Task 20260922-reader-nav-download-page: the single "go get the app"
// destination every previously-leaking `/reader` nav occurrence now points
// at instead (AppNav.jsx's hamburger "Read" item on the web, Home.jsx's
// nav links + "Read scripture"/"Read the Bible" CTAs) — see design-notes.md
// for the full per-occurrence rationale. This page owns the device
// branching itself via the same `isMobileUserAgent()` mechanism
// MobileBlockGate.jsx already uses, so every nav site that points here can
// collapse back to a single plain link/route regardless of device.

// ── Palette (matches Home.jsx's marketing palette, duplicated rather than
// extracted into a shared tokens module per design-notes.md §2 — this is
// the same handful of constants Home.jsx already keeps local to itself). ──
const INK   = '#17120F';
const CREAM = '#F6EFE6';
const AMBER = '#E09A30';
const AMBER_LIGHT = '#F3C48B';

const HEAD_FONT = "'Schibsted Grotesk', sans-serif";
const BODY_FONT = "'Hanken Grotesk', system-ui, sans-serif";

const APP_STORE_URL = 'https://apps.apple.com/us/app/fellowscript-study-connect/id6791701454';

// Live GitHub Release asset (desktop-v0.1.0) — relocated from Home.jsx's
// former "On your desktop" section verbatim (design-notes.md §3/§4).
const MACOS_DOWNLOAD_URL = 'https://github.com/Jacey1225/FellowScript/releases/download/desktop-v0.1.0/FellowScript.dmg';

// Filled brand glyphs — relocated from Home.jsx alongside the section that
// used them (they had no other caller there). Both paths are the official
// simple-icons (MIT-licensed) brand marks.
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

// ── Mobile branch: a single tailored layout, not a squeezed-down version of
// the desktop grid (design-notes.md §3, Q13). One primary CTA out to the
// real App Store listing — never lands the visitor in /reader. ──────────
function MobileDownload() {
  return (
    <section style={{
      minHeight: 'calc(100vh - 64px)',
      display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
      textAlign: 'center', padding: '48px 24px 64px', gap: 22,
    }}>
      <div style={{ fontFamily: HEAD_FONT, fontSize: 11.5, letterSpacing: '0.26em', textTransform: 'uppercase', color: AMBER }}>
        // GET THE APP
      </div>
      <h1 style={{ fontFamily: HEAD_FONT, fontSize: 'clamp(30px, 8vw, 44px)', lineHeight: 1.08, fontWeight: 400, letterSpacing: '-0.03em', color: '#FFF9F0', margin: 0, maxWidth: '16em' }}>
        Get the FellowScript app
      </h1>
      <p style={{ fontSize: 16, lineHeight: 1.65, color: 'rgba(255,243,228,0.72)', margin: 0, maxWidth: '26em' }}>
        FellowScript's reader lives in the app, built for your phone from the ground up — highlights, notes, and daily check-ins all in one calm place.
      </p>
      <a
        href={APP_STORE_URL}
        target="_blank"
        rel="noopener noreferrer"
        className="dl-btn-primary"
        style={{
          display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 10,
          minHeight: 44, minWidth: 44,
          marginTop: 12, padding: '16px 30px', borderRadius: 999,
          background: AMBER, color: '#21160F',
          fontFamily: BODY_FONT, fontSize: 15.5, fontWeight: 600, letterSpacing: '0.01em',
          textDecoration: 'none',
        }}
      >
        Get it on the App Store <span aria-hidden="true">→</span>
      </a>
    </section>
  );
}

// ── Desktop branch: Home.jsx's former "On your desktop" section, relocated
// wholesale (design-notes.md §3/§4) — same markup/styling, just moved. ──
function DesktopDownload() {
  return (
    <section style={{ position: 'relative', overflow: 'hidden', padding: 'clamp(60px, 10vh, 120px) clamp(20px, 5vw, 64px) clamp(90px, 13vh, 160px)' }}>
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
        <h1 style={{ fontFamily: HEAD_FONT, fontWeight: 400, fontSize: 'clamp(32px, 4.2vw, 62px)', lineHeight: 1.03, letterSpacing: '-0.03em', color: '#FFF9F0', margin: '0 0 24px' }}>
          Out of the browser, <span style={{ color: 'rgba(255,249,240,0.42)' }}>into a window of its own.</span>
        </h1>
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
          }} className="dl-card dl-card-mac">
            <span style={{
              display: 'grid', placeItems: 'center', width: 42, height: 42, borderRadius: 12,
              background: 'rgba(232,163,85,0.16)', border: '1px solid rgba(232,163,85,0.30)', color: AMBER,
            }}>
              <AppleMark size={20} />
            </span>
            <span style={{ fontFamily: HEAD_FONT, fontSize: 12, letterSpacing: '0.2em', textTransform: 'uppercase', color: '#F0C08A' }}>MACOS</span>
            <h2 style={{ fontFamily: HEAD_FONT, fontSize: 21, fontWeight: 500, letterSpacing: '-0.02em', margin: 0, color: '#FFF9F0' }}>Signed, notarized, ready</h2>
            <p style={{ fontSize: 15, lineHeight: 1.6, color: 'rgba(255,243,228,0.7)', margin: 0 }}>One download, no gatekeeper warnings — just open it.</p>
            <div style={{ flex: 1 }} />
            {/* Live GitHub Release asset — plain <a>, not <Link>: this points
                at a hosted file, not an internal route. */}
            <a
              href={MACOS_DOWNLOAD_URL}
              download
              className="dl-btn-primary"
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
            {/* No OS-floor claim — two verified facts only: file size from
                the built .dmg, architecture support from the Tauri build
                target. */}
            <div style={{ fontFamily: BODY_FONT, fontSize: 12.5, letterSpacing: '0.04em', color: 'rgba(255,243,228,0.58)', textAlign: 'center' }}>
              Apple silicon &amp; Intel · 3 MB
            </div>
          </div>

          {/* Windows card — recessed, present-but-not-live. No <button>/<a>/
              tabIndex/role="button"/hover/cursor-pointer anywhere in this
              card. */}
          <div style={{
            position: 'relative', display: 'flex', flexDirection: 'column', gap: 18,
            padding: '38px 34px 40px', borderRadius: 20,
            background: 'rgba(255,244,230,0.028)',
            border: '1px solid rgba(255,244,230,0.13)',
            cursor: 'default',
          }} className="dl-card">
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
            <h2 style={{ fontFamily: HEAD_FONT, fontSize: 21, fontWeight: 500, letterSpacing: '-0.02em', margin: 0, color: '#FFF9F0' }}>Still in the workshop</h2>
            <p style={{ fontSize: 15, lineHeight: 1.6, color: 'rgba(255,243,228,0.7)', margin: 0 }}>We started on macOS. The Windows build is on the way.</p>
            <div style={{ flex: 1 }} />
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
  );
}

// ── Page ──────────────────────────────────────────────────────────────────
export default function Download() {
  // Task 20260922-reader-nav-download-page: same UA-check approach as
  // MobileBlockGate.jsx / Home.jsx's former readNavProps (a UX gate, not a
  // security boundary — see deviceGate.js's own comment on that). This is
  // the one place that decision needs to live now that every nav site
  // pointing here is a single, unbranched link/route.
  const mobile = isMobileUserAgent();

  return (
    <div style={{ minHeight: '100vh', fontFamily: BODY_FONT, color: CREAM, background: INK }}>
      <Seo
        title="Download FellowScript"
        description="Get the FellowScript app — on the App Store for iPhone, or as a native desktop app for macOS and Windows."
        path="/download"
      />
      {/* No motion/parallax on this page — a two-branch utility page, not a
          scroll-narrative marketing section (design-notes.md §3). The only
          hover transition below is guarded under prefers-reduced-motion. */}
      <style>{`
        .dl-btn-primary:hover { background: ${AMBER_LIGHT} !important; }
        .dl-card-mac { transition: transform 220ms cubic-bezier(0.22,0.61,0.36,1), border-color 220ms cubic-bezier(0.22,0.61,0.36,1), box-shadow 220ms cubic-bezier(0.22,0.61,0.36,1); }
        .dl-card-mac:hover { transform: translateY(-4px); border-color: rgba(255,244,230,0.30); box-shadow: 0 48px 100px -50px rgba(232,163,85,0.35), 0 40px 90px -50px rgba(0,0,0,0.9); }
        @media (prefers-reduced-motion: reduce) {
          .dl-card-mac { transition: none !important; }
          .dl-card-mac:hover { transform: none !important; }
        }
      `}</style>

      {/* Lightweight sticky header — Privacy.jsx/Terms.jsx's pattern (logo +
          a single "Back to Home" link) rather than AppNav (app-chrome pages
          only) or Home's full hero header (design-notes.md §2). */}
      <header style={{
        position: 'sticky', top: 0, zIndex: 10,
        display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 24,
        padding: '18px clamp(20px, 5vw, 64px)', height: 64, boxSizing: 'border-box',
        background: 'rgba(23,18,15,0.92)', borderBottom: '1px solid rgba(255,244,230,0.14)',
        backdropFilter: 'blur(10px)',
      }}>
        <Link to="/" style={{ fontFamily: HEAD_FONT, fontSize: 19, fontWeight: 600, letterSpacing: '-0.01em', color: '#FFF8EE', textDecoration: 'none' }}>
          <span>Fellow</span><span style={{ color: AMBER }}>Script</span>
        </Link>
        <Link to="/" style={{ fontSize: 13, color: 'rgba(255,244,230,0.55)', textDecoration: 'none' }}>&larr; Back to Home</Link>
      </header>

      <main>
        {mobile ? <MobileDownload /> : <DesktopDownload />}
      </main>
    </div>
  );
}
