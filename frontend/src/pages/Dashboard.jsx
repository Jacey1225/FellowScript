import React, { useEffect, useRef } from 'react';
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

export default function Dashboard() {
  const navigate      = useNavigate();
  const containerRef  = useRef(null);
  const circleRef     = useRef(null);
  const squareRef     = useRef(null);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const onScroll = () => {
      const sy = el.scrollTop;
      if (circleRef.current) {
        circleRef.current.style.transform = `scale(${1 + sy * 0.0018})`;
      }
      if (squareRef.current) {
        squareRef.current.style.transform = `translate(-50%, -50%) scale(${1 + sy * 0.0014})`;
      }
    };
    el.addEventListener('scroll', onScroll, { passive: true });
    return () => el.removeEventListener('scroll', onScroll);
  }, []);

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

        {/* Golden circle — top-left, grows on scroll */}
        <div
          ref={circleRef}
          style={{
            position: 'absolute',
            top: '-22%',
            left: '-15%',
            width: 900,
            height: 900,
            borderRadius: '50%',
            background: GOLD,
            transformOrigin: '20% 20%',
            willChange: 'transform',
            zIndex: 0,
            pointerEvents: 'none',
          }}
        />

        <div style={{
          position: 'relative',
          zIndex: 1,
          maxWidth: 1240,
          margin: '0 auto',
          width: '100%',
          padding: 'clamp(4rem, 8vw, 7rem) clamp(1.5rem, 5vw, 4rem)',
          display: 'grid',
          gridTemplateColumns: '1fr 1fr',
          gap: 'clamp(2.5rem, 5vw, 6rem)',
          alignItems: 'center',
        }}>

          {/* Left — headline */}
          <div>
            <p style={{
              fontFamily: "'Lora', serif",
              fontSize: '0.58rem',
              letterSpacing: '0.35em',
              textTransform: 'uppercase',
              color: 'rgba(200,134,26,0.75)',
              margin: '0 0 1.2rem',
            }}>
              A Digital Scripture Community
            </p>
            <h1 style={{
              fontFamily: "'Playfair Display', serif",
              fontSize: 'clamp(2.2rem, 4.5vw, 3.8rem)',
              fontWeight: 800,
              lineHeight: 1.12,
              color: BLACK,
              margin: '0 0 2.4rem',
              letterSpacing: '-0.01em',
            }}>
              The forefront of spiritual growth through powerful connection.
            </h1>
            <div style={{ display: 'flex', gap: '0.9rem', flexWrap: 'wrap' }}>
              <button
                onClick={() => navigate('/reader')}
                style={{
                  background: BLACK,
                  color: WHITE,
                  border: 'none',
                  padding: '0.9rem 2.2rem',
                  fontSize: '0.72rem',
                  letterSpacing: '0.18em',
                  textTransform: 'uppercase',
                  fontFamily: "'Lora', serif",
                  cursor: 'pointer',
                  borderRadius: 2,
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
                  background: 'transparent',
                  color: BLACK,
                  border: `1.5px solid ${BLACK}`,
                  padding: '0.9rem 2.2rem',
                  fontSize: '0.72rem',
                  letterSpacing: '0.18em',
                  textTransform: 'uppercase',
                  fontFamily: "'Lora', serif",
                  cursor: 'pointer',
                  borderRadius: 2,
                  transition: 'border-color 0.2s, color 0.2s',
                }}
                onMouseEnter={e => { e.currentTarget.style.color = GOLD; e.currentTarget.style.borderColor = GOLD; }}
                onMouseLeave={e => { e.currentTarget.style.color = BLACK; e.currentTarget.style.borderColor = BLACK; }}
              >
                Join Free
              </button>
            </div>
          </div>

          {/* Right — paragraph */}
          <div>
            <p style={{
              fontFamily: "'Lora', serif",
              fontSize: 'clamp(0.92rem, 1.3vw, 1.06rem)',
              lineHeight: 2.05,
              color: '#3D3D3D',
              margin: 0,
            }}>
              Faith does not flourish in silence. It is forged in the fire of fellowship — tested by honest
              questions, strengthened by shared conviction, and carried forward by the voices of those who
              refuse to walk alone. Every morning you open the Word, you face the same quiet battles: doubt
              that whispers you are too far gone, grief that says nothing is promised, distraction that steals
              the sacred before it even begins.
            </p>
            <p style={{
              fontFamily: "'Lora', serif",
              fontSize: 'clamp(0.92rem, 1.3vw, 1.06rem)',
              lineHeight: 2.05,
              color: '#3D3D3D',
              margin: '1.4rem 0 0',
            }}>
              FellowScript was built for those who believe that true spiritual transformation is not a solo
              act. It is born in the spaces between two people who open the same passage, feel the same weight,
              and choose — together — to press deeper into the presence of God.
            </p>
          </div>
        </div>
      </section>

      {/* ─── MISSION ────────────────────────────────────────────────────────── */}
      <section style={{
        position: 'relative',
        overflow: 'hidden',
        background: WHITE,
        padding: 'clamp(5rem, 10vw, 9rem) 2rem',
        display: 'flex',
        justifyContent: 'center',
        alignItems: 'center',
        minHeight: 520,
      }}>

        {/* Black square — grows on scroll */}
        <div
          ref={squareRef}
          style={{
            position: 'absolute',
            top: '50%',
            left: '50%',
            width: 'min(760px, 92vw)',
            height: 380,
            background: BLACK,
            transform: 'translate(-50%, -50%) scale(1)',
            transformOrigin: 'center center',
            willChange: 'transform',
            zIndex: 0,
            pointerEvents: 'none',
            borderRadius: 3,
          }}
        />

        {/* Content */}
        <div style={{
          position: 'relative',
          zIndex: 1,
          textAlign: 'center',
          maxWidth: 560,
          padding: '3rem 2rem',
        }}>
          <p style={{
            fontFamily: "'Lora', serif",
            fontSize: '0.55rem',
            letterSpacing: '0.38em',
            textTransform: 'uppercase',
            color: 'rgba(200,134,26,0.8)',
            margin: '0 0 1.1rem',
          }}>
            What We Stand For
          </p>
          <h2 style={{
            fontFamily: "'Playfair Display', serif",
            fontSize: 'clamp(2rem, 4vw, 3rem)',
            fontWeight: 700,
            color: WHITE,
            margin: '0 0 1.2rem',
            lineHeight: 1.15,
          }}>
            Mission
          </h2>
          <p style={{
            fontFamily: "'IM Fell English', serif",
            fontStyle: 'italic',
            fontSize: 'clamp(0.9rem, 1.4vw, 1.05rem)',
            color: 'rgba(244,228,193,0.65)',
            lineHeight: 1.85,
            margin: '0 0 2.2rem',
          }}>
            To build a generation of believers who never study alone.
          </p>
          <button
            style={{
              background: 'transparent',
              color: GOLD,
              border: `1px solid rgba(200,134,26,0.55)`,
              padding: '0.8rem 2.2rem',
              fontSize: '0.68rem',
              letterSpacing: '0.22em',
              textTransform: 'uppercase',
              fontFamily: "'Lora', serif",
              cursor: 'pointer',
              borderRadius: 2,
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
      <section style={{
        background: WHITE,
        padding: 'clamp(4rem, 8vw, 7rem) clamp(1.5rem, 5vw, 4rem) clamp(5rem, 10vw, 9rem)',
      }}>
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
            fontSize: 'clamp(1.7rem, 2.8vw, 2.4rem)',
            fontWeight: 700,
            color: BLACK,
            margin: '0 0 clamp(2.5rem, 5vw, 4rem)',
            lineHeight: 1.2,
          }}>
            Everything you need to grow.
          </h2>

          <div style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))',
            gap: 'clamp(2rem, 4vw, 3.5rem)',
          }}>
            {FEATURES.map((f, i) => (
              <div
                key={i}
                style={{
                  paddingTop: '2rem',
                  borderTop: `3px solid ${f.accent}`,
                }}
              >
                <p style={{
                  fontFamily: "'Lora', serif",
                  fontSize: '0.52rem',
                  letterSpacing: '0.32em',
                  textTransform: 'uppercase',
                  color: f.accent,
                  margin: '0 0 0.9rem',
                }}>
                  {f.label}
                </p>
                <h3 style={{
                  fontFamily: "'Playfair Display', serif",
                  fontSize: 'clamp(1.1rem, 1.6vw, 1.35rem)',
                  fontWeight: 700,
                  color: BLACK,
                  margin: '0 0 0.9rem',
                  lineHeight: 1.25,
                }}>
                  {f.heading}
                </h3>
                <p style={{
                  fontFamily: "'Lora', serif",
                  fontSize: '0.86rem',
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
        padding: '2.2rem 2rem',
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
