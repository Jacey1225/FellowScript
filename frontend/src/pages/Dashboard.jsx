import React, { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import AppNav from '../components/AppNav.jsx';

const GOLD  = '#C8861A';
const BLACK = '#0D0D0D';
const WHITE = '#FFFFFF';

const FEATURES = [
  {
    label: 'SCRIPTURE',
    heading: 'A Living, Breathing Bible',
    body: 'Navigate the full ESV & NIV by book and chapter. Every passage a breath away — Genesis to Revelation, always at your fingertips.',
    accent: GOLD,
  },
  {
    label: 'HIGHLIGHTS',
    heading: 'Mark What Moves You',
    body: 'Five colors, infinite meaning. See where your brothers and sisters have marked the same verses and discover what God is saying to your circle.',
    accent: BLACK,
  },
  {
    label: 'COMMUNITY',
    heading: 'Study Together, In Real Time',
    body: 'Message your group, share notes, and join live voice sessions built around Scripture. The Word comes alive when witnessed through shared eyes.',
    accent: GOLD,
  },
  {
    label: 'SESSIONS',
    heading: 'Capture Every Revelation',
    body: 'Schedule devotion sessions with your group, attach verses, and arrive prepared. No revelation lost, no moment of clarity left unshared.',
    accent: BLACK,
  },
];

function useWindowWidth() {
  const [w, setW] = useState(() => window.innerWidth);
  useEffect(() => {
    const handler = () => setW(window.innerWidth);
    window.addEventListener('resize', handler, { passive: true });
    return () => window.removeEventListener('resize', handler);
  }, []);
  return w;
}

export default function Dashboard() {
  const navigate      = useNavigate();
  const containerRef  = useRef(null);
  const circleRef     = useRef(null);
  const squareRef     = useRef(null);
  const mRef          = useRef({ circle: 0.0018, square: 0.0014 });

  const w      = useWindowWidth();
  const isMob  = w < 640;
  const isTab  = w >= 640 && w < 1100;
  const isDesk = w >= 1100 && w < 1440;
  const isWide = w >= 1440;

  // Keep scroll multipliers in sync with breakpoint
  useEffect(() => {
    if (isMob)        mRef.current = { circle: 0.0008, square: 0.0006 };
    else if (isTab)   mRef.current = { circle: 0.0012, square: 0.0009 };
    else if (isWide)  mRef.current = { circle: 0.0022, square: 0.0016 };
    else              mRef.current = { circle: 0.0018, square: 0.0014 };
  }, [isMob, isTab, isWide]);

  // Scroll handler — writes directly to DOM, no re-renders
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const onScroll = () => {
      const sy = el.scrollTop;
      if (circleRef.current)
        circleRef.current.style.transform = `scale(${1 + sy * mRef.current.circle})`;
      if (squareRef.current)
        squareRef.current.style.transform = `translate(-50%, -50%) scale(${1 + sy * mRef.current.square})`;
    };
    el.addEventListener('scroll', onScroll, { passive: true });
    return () => el.removeEventListener('scroll', onScroll);
  }, []);

  // Responsive values
  const circleSize = isMob ? 320 : isTab ? 560 : isWide ? 1100 : 900;
  const circleTop  = isMob ? '-18%' : isTab ? '-22%' : isWide ? '-32%' : '-28%';
  const circleLeft = `calc(50% - ${circleSize / 2}px)`;

  const squareW = isMob ? '92vw' : isTab ? '88vw' : 'min(760px, 92vw)';
  const squareH = isMob ? 280    : isTab ? 320    : isWide ? 440 : 380;

  const heroGrid  = (isDesk || isWide) ? '1fr 1fr' : '1fr';
  const heroGap   = isMob ? '1.8rem' : isTab ? '2.2rem' : 'clamp(2.5rem, 5vw, 6rem)';
  const heroPad   = isMob ? '2.8rem 1.25rem 3.2rem' : isTab ? '3.5rem 2rem' : isWide ? 'clamp(5rem, 8vw, 8rem) clamp(2rem, 6vw, 5rem)' : 'clamp(4rem, 8vw, 7rem) clamp(1.5rem, 5vw, 4rem)';

  const h1Size    = isMob ? 'clamp(1.65rem, 6.5vw, 2.2rem)' : isTab ? 'clamp(1.9rem, 3.5vw, 2.6rem)' : isWide ? 'clamp(2.8rem, 3.5vw, 4.2rem)' : 'clamp(2.2rem, 4.5vw, 3.8rem)';
  const bodySize  = isMob ? '0.85rem' : isTab ? '0.92rem' : 'clamp(0.92rem, 1.3vw, 1.06rem)';
  const btnPad    = isMob ? '0.7rem 1.4rem' : isWide ? '1rem 2.6rem' : '0.9rem 2.2rem';
  const missionH2 = isMob ? '1.8rem' : isTab ? '2.2rem' : isWide ? 'clamp(2.4rem, 4vw, 3.6rem)' : 'clamp(2rem, 4vw, 3rem)';
  const missionP  = isMob ? '1.8rem 1.25rem' : isWide ? '3.5rem 2.5rem' : '3rem 2rem';
  const missionMin= isMob ? 340 : isWide ? 600 : 520;
  const featGrid  = isMob ? '1fr' : isTab ? '1fr 1fr' : 'repeat(4, 1fr)';
  const featGap   = isMob ? '1.8rem' : isTab ? '2rem' : isWide ? 'clamp(2.5rem, 5vw, 4.5rem)' : 'clamp(2rem, 4vw, 3.5rem)';
  const secPad    = isMob ? '3rem 1.25rem 5rem' : isWide ? 'clamp(5rem, 10vw, 9rem) clamp(2rem, 6vw, 5rem) clamp(6rem, 12vw, 10rem)' : 'clamp(4rem, 8vw, 7rem) clamp(1.5rem, 5vw, 4rem) clamp(5rem, 10vw, 9rem)';

  return (
    <div ref={containerRef} style={{ background: WHITE, height: '100vh', overflowY: 'auto', overflowX: 'hidden' }}>
      <AppNav />

      {/* ─── HERO ──────────────────────────────────────────────────────────── */}
      <section style={{
        position: 'relative',
        overflow: 'hidden',
        minHeight: '100vh',
        background: WHITE,
        display: 'flex',
        alignItems: 'center',
        paddingTop: 'var(--nav-h, 64px)',
      }}>

        <svg
          ref={circleRef}
          viewBox="0 0 900 900"
          xmlns="http://www.w3.org/2000/svg"
          style={{
            position: 'absolute',
            top: circleTop,
            left: circleLeft,
            width: circleSize,
            height: circleSize,
            transformOrigin: '50% 10%',
            zIndex: 0,
            pointerEvents: 'none',
            overflow: 'visible',
          }}
        >
          <circle cx="450" cy="450" r="450" fill={GOLD} />
        </svg>

        <div style={{
          position: 'relative',
          zIndex: 1,
          maxWidth: 1240,
          margin: '0 auto',
          width: '100%',
          padding: heroPad,
          display: 'grid',
          gridTemplateColumns: heroGrid,
          gap: heroGap,
          alignItems: 'center',
        }}>

          {/* Headline + CTAs */}
          <div>
            <p style={{
              fontFamily: "'Lora', serif",
              fontSize: isMob ? '0.5rem' : '0.58rem',
              letterSpacing: '0.35em',
              textTransform: 'uppercase',
              color: BLACK,
              margin: '0 0 0.9rem',
            }}>
              A Digital Scripture Community
            </p>
            <h1 style={{
              fontFamily: "'Playfair Display', serif",
              fontSize: h1Size,
              fontWeight: 800,
              lineHeight: 1.13,
              color: BLACK,
              margin: '0 0 1.8rem',
              letterSpacing: '-0.01em',
            }}>
              The forefront of spiritual growth through powerful connection.
            </h1>
            <div style={{ display: 'flex', gap: '0.65rem', flexWrap: 'wrap' }}>
              <button
                onClick={() => navigate('/reader')}
                style={{
                  background: BLACK, color: WHITE, border: 'none',
                  padding: btnPad, fontSize: isMob ? '0.65rem' : '0.72rem',
                  letterSpacing: '0.15em', textTransform: 'uppercase',
                  fontFamily: "'Lora', serif", cursor: 'pointer', borderRadius: 2,
                  transition: 'background 0.2s',
                }}
                onMouseEnter={e => { e.currentTarget.style.background = '#2A2A2A'; }}
                onMouseLeave={e => { e.currentTarget.style.background = BLACK; }}
              >
                Start Reading →
              </button>
              <button
                onClick={() => navigate('/signin')}
                style={{
                  background: 'transparent', color: BLACK, border: `1.5px solid ${BLACK}`,
                  padding: btnPad, fontSize: isMob ? '0.65rem' : '0.72rem',
                  letterSpacing: '0.15em', textTransform: 'uppercase',
                  fontFamily: "'Lora', serif", cursor: 'pointer', borderRadius: 2,
                  transition: 'border-color 0.2s, color 0.2s',
                }}
                onMouseEnter={e => { e.currentTarget.style.color = GOLD; e.currentTarget.style.borderColor = GOLD; }}
                onMouseLeave={e => { e.currentTarget.style.color = BLACK; e.currentTarget.style.borderColor = BLACK; }}
              >
                Join Free
              </button>
            </div>
          </div>

          {/* Paragraph */}
          <div>
            <p style={{
              fontFamily: "'Playfair Display', serif",
              fontSize: isMob ? '1.15rem' : isTab ? '1.25rem' : 'clamp(1.25rem, 1.8vw, 1.55rem)',
              fontWeight: 400,
              lineHeight: 1.85,
              color: '#1A1A1A',
              margin: 0,
              fontStyle: 'normal',
            }}>
              Faith was never meant to be carried alone. Every breakthrough, every answered prayer, every
              moment of clarity — forged in the fire of community. FellowScript puts the people who sharpen
              you right beside the Word that transforms you.
            </p>
          </div>
        </div>
      </section>

      {/* ─── MISSION ────────────────────────────────────────────────────────── */}
      <section style={{
        position: 'relative',
        overflow: 'hidden',
        background: WHITE,
        padding: isMob ? '4.5rem 1.25rem' : 'clamp(5rem, 10vw, 9rem) 2rem',
        display: 'flex',
        justifyContent: 'center',
        alignItems: 'center',
        minHeight: missionMin,
      }}>

        <div
          ref={squareRef}
          style={{
            position: 'absolute',
            top: '50%',
            left: '50%',
            width: squareW,
            height: squareH,
            background: BLACK,
            transform: 'translate(-50%, -50%) scale(1)',
            transformOrigin: 'center center',
            zIndex: 0,
            pointerEvents: 'none',
            borderRadius: 3,
          }}
        />

        <div style={{
          position: 'relative',
          zIndex: 1,
          textAlign: 'center',
          maxWidth: 480,
          padding: missionP,
        }}>
          <p style={{
            fontFamily: "'Lora', serif",
            fontSize: '0.55rem',
            letterSpacing: '0.38em',
            textTransform: 'uppercase',
            color: 'rgba(200,134,26,0.8)',
            margin: '0 0 0.9rem',
          }}>
            What We Stand For
          </p>
          <h2 style={{
            fontFamily: "'Playfair Display', serif",
            fontSize: missionH2,
            fontWeight: 700,
            color: WHITE,
            margin: '0 0 1rem',
            lineHeight: 1.15,
          }}>
            Mission
          </h2>
          <p style={{
            fontFamily: "'IM Fell English', serif",
            fontStyle: 'italic',
            fontSize: isMob ? '0.88rem' : 'clamp(0.9rem, 1.4vw, 1.05rem)',
            color: 'rgba(244,228,193,0.65)',
            lineHeight: 1.85,
            margin: '0 0 1.8rem',
          }}>
            To build a generation of believers who never study alone.
          </p>
          <button
            style={{
              background: 'transparent', color: GOLD,
              border: `1px solid rgba(200,134,26,0.55)`,
              padding: isMob ? '0.7rem 1.6rem' : '0.8rem 2.2rem',
              fontSize: '0.68rem', letterSpacing: '0.22em', textTransform: 'uppercase',
              fontFamily: "'Lora', serif", cursor: 'pointer', borderRadius: 2,
              transition: 'border-color 0.2s, color 0.2s',
            }}
            onMouseEnter={e => { e.currentTarget.style.borderColor = GOLD; e.currentTarget.style.color = WHITE; }}
            onMouseLeave={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.55)'; e.currentTarget.style.color = GOLD; }}
          >
            Learn More →
          </button>
        </div>
      </section>

      {/* ─── FEATURES ────────────────────────────────────────────────────────── */}
      <section style={{ background: WHITE, padding: secPad }}>
        <div style={{ maxWidth: 1240, margin: '0 auto' }}>

          <p style={{
            fontFamily: "'Lora', serif",
            fontSize: '0.56rem',
            letterSpacing: '0.35em',
            textTransform: 'uppercase',
            color: 'rgba(200,134,26,0.65)',
            margin: '0 0 0.5rem',
          }}>
            Built for the Journey
          </p>
          <h2 style={{
            fontFamily: "'Playfair Display', serif",
            fontSize: isMob ? '1.45rem' : isTab ? '1.8rem' : 'clamp(1.7rem, 2.8vw, 2.4rem)',
            fontWeight: 700,
            color: BLACK,
            margin: `0 0 ${isMob ? '2rem' : 'clamp(2.5rem, 5vw, 4rem)'}`,
            lineHeight: 1.2,
          }}>
            Everything you need to grow.
          </h2>

          <div style={{
            display: 'grid',
            gridTemplateColumns: featGrid,
            gap: featGap,
          }}>
            {FEATURES.map((f, i) => (
              <div key={i} style={{ paddingTop: '1.6rem', borderTop: `3px solid ${f.accent}` }}>
                <p style={{
                  fontFamily: "'Lora', serif",
                  fontSize: '0.52rem',
                  letterSpacing: '0.32em',
                  textTransform: 'uppercase',
                  color: f.accent,
                  margin: '0 0 0.75rem',
                }}>
                  {f.label}
                </p>
                <h3 style={{
                  fontFamily: "'Playfair Display', serif",
                  fontSize: isMob ? '1.05rem' : 'clamp(1.1rem, 1.6vw, 1.35rem)',
                  fontWeight: 700,
                  color: BLACK,
                  margin: '0 0 0.7rem',
                  lineHeight: 1.25,
                }}>
                  {f.heading}
                </h3>
                <p style={{
                  fontFamily: "'Lora', serif",
                  fontSize: isMob ? '0.82rem' : '0.86rem',
                  color: '#555555',
                  lineHeight: 1.9,
                  margin: 0,
                }}>
                  {f.body}
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ─── FOOTER ──────────────────────────────────────────────────────────── */}
      <footer style={{
        background: BLACK,
        padding: '2rem',
        textAlign: 'center',
        fontFamily: "'Lora', serif",
        fontSize: '0.65rem',
        letterSpacing: '0.14em',
        color: 'rgba(244,228,193,0.28)',
      }}>
        © 2026 FellowScript &nbsp;·&nbsp; A Digital Scripture Community
      </footer>
    </div>
  );
}
