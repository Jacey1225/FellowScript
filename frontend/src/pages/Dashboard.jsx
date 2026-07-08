import React, { useEffect, useRef, useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import AppNav from '../components/AppNav.jsx';

const GOLD  = '#C8861A';
const BLACK = '#0D0D0D';
const WHITE = '#FFFFFF';
const CREAM = '#F4E4C1';

const FEATURES = [
  {
    label: 'SCRIPTURE',
    heading: 'A Living Bible',
    body: 'The full ESV & NIV at your fingertips — with highlights, bookmarks, and verse-linked notes. Genesis to Revelation, always a breath away.',
  },
  {
    label: 'HIGHLIGHTS',
    heading: 'Shared Revelation',
    body: 'Five colors, infinite meaning. See where your brothers and sisters marked the same verse — discover what God is saying to your whole circle.',
  },
  {
    label: 'COMMUNITY',
    heading: 'Scripture in Common',
    body: 'Message your group, share notes with verse references, and study together in real time. The Word comes alive through shared eyes.',
  },
  {
    label: 'SESSIONS',
    heading: 'Live Study Calls',
    body: 'Join voice and video sessions built around Scripture. Schedule devotions, attach verses, arrive prepared. No revelation left unshared.',
  },
];

function useWindowWidth() {
  const [w, setW] = useState(() => window.innerWidth);
  useEffect(() => {
    const h = () => setW(window.innerWidth);
    window.addEventListener('resize', h, { passive: true });
    return () => window.removeEventListener('resize', h);
  }, []);
  return w;
}

function useFadeIn() {
  const ref = useRef(null);
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const observer = new IntersectionObserver(
      ([entry]) => { if (entry.isIntersecting) { setVisible(true); observer.disconnect(); } },
      { threshold: 0.12 }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, []);
  return [ref, visible];
}

function CheckIcon() {
  return (
    <svg width="10" height="10" viewBox="0 0 12 12" fill="none">
      <path d="M2 6L5 9L10 3" stroke={GOLD} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export default function Dashboard() {
  const navigate = useNavigate();
  const w        = useWindowWidth();
  const isMob    = w < 640;
  const isTab    = w >= 640 && w < 1100;

  const [heroRef,   heroVisible]   = useFadeIn();
  const [rhythmRef, rhythmVisible] = useFadeIn();
  const [heartRef,  heartVisible]  = useFadeIn();
  const [agentRef,  agentVisible]  = useFadeIn();
  const [featRef,   featVisible]   = useFadeIn();
  const [ctaRef,    ctaVisible]    = useFadeIn();

  const hPad = isMob ? '0 1.4rem' : isTab ? '0 2.2rem' : '0 clamp(2rem, 8vw, 7rem)';
  const vPad = isMob ? '5rem 0' : 'clamp(5.5rem, 10vw, 9rem) 0';

  const fc = (visible, d) =>
    `fs-fade${visible ? ' fs-visible' : ''}${d ? ` fs-d${d}` : ''}`;

  return (
    <div style={{ background: BLACK, minHeight: '100vh', overflowX: 'hidden' }}>
      <style>{`
        @keyframes fsUp {
          from { opacity: 0; transform: translateY(26px); }
          to   { opacity: 1; transform: translateY(0); }
        }
        @keyframes fsGlow {
          0%, 100% { opacity: 0.14; }
          50%       { opacity: 0.28; }
        }
        @keyframes fsPulse {
          0%, 100% { transform: scale(1);    opacity: 0.65; }
          50%       { transform: scale(1.06); opacity: 1;    }
        }
        .fs-fade { opacity: 0; }
        .fs-fade.fs-visible       { animation: fsUp 0.72s ease forwards; }
        .fs-fade.fs-visible.fs-d1 { animation-delay: 0.08s; }
        .fs-fade.fs-visible.fs-d2 { animation-delay: 0.20s; }
        .fs-fade.fs-visible.fs-d3 { animation-delay: 0.32s; }
        .fs-fade.fs-visible.fs-d4 { animation-delay: 0.44s; }
        .fs-fade.fs-visible.fs-d5 { animation-delay: 0.56s; }
      `}</style>

      <AppNav />

      {/* ── HERO ──────────────────────────────────────────────────────────── */}
      <section style={{
        position: 'relative', minHeight: '100vh',
        display: 'flex', flexDirection: 'column', justifyContent: 'center',
        overflow: 'hidden', paddingTop: 'var(--nav-h, 64px)', background: BLACK,
      }}>
        <div style={{
          position: 'absolute', top: '-18%', right: '-8%',
          width: isMob ? 320 : 700, height: isMob ? 320 : 700,
          borderRadius: '50%',
          background: 'radial-gradient(circle, rgba(200,134,26,0.18) 0%, transparent 70%)',
          pointerEvents: 'none', animation: 'fsGlow 6s ease-in-out infinite',
        }} />
        <div style={{
          position: 'absolute', bottom: '8%', left: '-6%',
          width: isMob ? 180 : 380, height: isMob ? 180 : 380,
          borderRadius: '50%',
          background: 'radial-gradient(circle, rgba(200,134,26,0.09) 0%, transparent 70%)',
          pointerEvents: 'none',
        }} />

        <div ref={heroRef} style={{
          maxWidth: 1200, margin: '0 auto', width: '100%', position: 'relative', zIndex: 1,
          padding: isMob ? '3.5rem 1.4rem 4.5rem' : isTab ? '4.5rem 2.2rem 5.5rem' : 'clamp(4rem, 8vw, 8rem) clamp(2rem, 8vw, 7rem)',
        }}>
          <p className={fc(heroVisible, 1)} style={{
            fontFamily: "'Lora', serif", fontSize: isMob ? '0.52rem' : '0.60rem',
            letterSpacing: '0.40em', textTransform: 'uppercase',
            color: GOLD, margin: '0 0 1.5rem',
          }}>
            A Digital Scripture Community
          </p>

          <h1 className={fc(heroVisible, 2)} style={{
            fontFamily: "'Playfair Display', serif",
            fontSize: isMob ? 'clamp(2.3rem, 9vw, 3rem)' : isTab ? 'clamp(3rem, 6vw, 4rem)' : 'clamp(3.8rem, 6vw, 5.8rem)',
            fontWeight: 800, lineHeight: 1.15, color: WHITE,
            margin: '0 0 0.15rem', letterSpacing: '-0.02em',
            paddingBottom: '0.05em',
          }}>
            Prayer &amp; devotion,
          </h1>
          <h1 className={fc(heroVisible, 2)} style={{
            fontFamily: "'Playfair Display', serif",
            fontSize: isMob ? 'clamp(2.3rem, 9vw, 3rem)' : isTab ? 'clamp(3rem, 6vw, 4rem)' : 'clamp(3.8rem, 6vw, 5.8rem)',
            fontWeight: 800, lineHeight: 1.15,
            color: 'transparent',
            backgroundImage: `linear-gradient(90deg, ${GOLD} 0%, #E8A830 55%, rgba(200,134,26,0.55) 100%)`,
            WebkitBackgroundClip: 'text', backgroundClip: 'text',
            margin: '0 0 2.2rem', letterSpacing: '-0.02em',
            paddingBottom: '0.12em',
          }}>
            every single day.
          </h1>

          <p className={fc(heroVisible, 3)} style={{
            fontFamily: "'Lora', serif",
            fontSize: isMob ? '0.90rem' : isTab ? '0.98rem' : 'clamp(0.96rem, 1.35vw, 1.12rem)',
            color: 'rgba(244,228,193,0.65)', lineHeight: 1.95,
            margin: '0 0 2.8rem', maxWidth: 560,
          }}>
            FellowScript is built around one conviction: the Word of God transforms when it
            becomes a daily rhythm — not just a Sunday event. AI spiritual agents, automated
            devotional events, live study sessions, and a Bible you can read together with the
            people who matter most.
          </p>

          <div className={fc(heroVisible, 4)} style={{ display: 'flex', gap: '0.9rem', flexWrap: 'wrap' }}>
            <button
              onClick={() => navigate('/signin')}
              style={{
                background: GOLD, color: BLACK, border: 'none',
                padding: isMob ? '0.88rem 1.9rem' : '1rem 2.8rem',
                fontSize: isMob ? '0.68rem' : '0.75rem',
                letterSpacing: '0.18em', textTransform: 'uppercase',
                fontFamily: "'Lora', serif", cursor: 'pointer',
                borderRadius: 3, fontWeight: 700,
                transition: 'background 0.2s, transform 0.15s',
              }}
              onMouseEnter={e => { e.currentTarget.style.background = '#E8A830'; e.currentTarget.style.transform = 'translateY(-1px)'; }}
              onMouseLeave={e => { e.currentTarget.style.background = GOLD;      e.currentTarget.style.transform = 'translateY(0)';    }}
            >
              Begin Your Journey →
            </button>
            <button
              onClick={() => navigate('/reader')}
              style={{
                background: 'transparent', color: CREAM,
                border: '1.5px solid rgba(244,228,193,0.28)',
                padding: isMob ? '0.88rem 1.9rem' : '1rem 2.5rem',
                fontSize: isMob ? '0.68rem' : '0.75rem',
                letterSpacing: '0.18em', textTransform: 'uppercase',
                fontFamily: "'Lora', serif", cursor: 'pointer',
                borderRadius: 3, transition: 'all 0.2s',
              }}
              onMouseEnter={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.6)'; e.currentTarget.style.color = GOLD; e.currentTarget.style.transform = 'translateY(-1px)'; }}
              onMouseLeave={e => { e.currentTarget.style.borderColor = 'rgba(244,228,193,0.28)'; e.currentTarget.style.color = CREAM; e.currentTarget.style.transform = 'translateY(0)'; }}
            >
              Read Scripture
            </button>
          </div>

          <div className={fc(heroVisible, 5)} style={{
            display: 'flex', gap: isMob ? '1.5rem' : '2.8rem', flexWrap: 'wrap',
            marginTop: isMob ? '3.5rem' : '5rem',
            paddingTop: isMob ? '2rem' : '2.5rem',
            borderTop: '1px solid rgba(200,134,26,0.16)',
          }}>
            {[
              { num: 'ESV & NIV', label: 'Full Bible' },
              { num: 'AI',        label: 'Spiritual Agents' },
              { num: 'Live',      label: 'Video Study' },
              { num: '∞',         label: 'Devotional Events' },
            ].map((s, i) => (
              <div key={i}>
                <p style={{
                  fontFamily: "'Playfair Display', serif",
                  fontSize: isMob ? '1.05rem' : '1.35rem',
                  fontWeight: 700, color: GOLD, margin: '0 0 0.15rem',
                }}>
                  {s.num}
                </p>
                <p style={{
                  fontFamily: "'Lora', serif", fontSize: '0.56rem',
                  letterSpacing: '0.2em', textTransform: 'uppercase',
                  color: 'rgba(244,228,193,0.35)', margin: 0,
                }}>
                  {s.label}
                </p>
              </div>
            ))}
          </div>
        </div>

        <div style={{
          position: 'absolute', bottom: 0, left: 0, right: 0, height: 1,
          background: 'linear-gradient(90deg, transparent 0%, rgba(200,134,26,0.30) 50%, transparent 100%)',
        }} />
      </section>

      {/* ── HOW IT WORKS ─────────────────────────────────────────────────── */}
      <section style={{ background: WHITE, padding: vPad }}>
        <div ref={rhythmRef} style={{ maxWidth: 1200, margin: '0 auto', padding: hPad }}>
          <div style={{ textAlign: isMob ? 'left' : 'center', marginBottom: isMob ? '3rem' : '4.5rem' }}>
            <p className={fc(rhythmVisible, 1)} style={{
              fontFamily: "'Lora', serif", fontSize: '0.56rem',
              letterSpacing: '0.38em', textTransform: 'uppercase',
              color: 'rgba(200,134,26,0.65)', margin: '0 0 0.8rem',
            }}>
              How It Works
            </p>
            <h2 className={fc(rhythmVisible, 2)} style={{
              fontFamily: "'Playfair Display', serif",
              fontSize: isMob ? '1.85rem' : isTab ? '2.4rem' : 'clamp(2.3rem, 3.8vw, 3.1rem)',
              fontWeight: 700, color: BLACK, margin: '0 0 1rem', lineHeight: 1.12,
            }}>
              A rhythm built for<br />the devoted life.
            </h2>
            <p className={fc(rhythmVisible, 3)} style={{
              fontFamily: "'Lora', serif",
              fontSize: isMob ? '0.88rem' : 'clamp(0.88rem, 1.25vw, 1rem)',
              color: '#585858', lineHeight: 1.9,
              maxWidth: 480, margin: isMob ? 0 : '0 auto',
            }}>
              Three pillars, working together every single day.
            </p>
          </div>

          <div style={{
            display: 'grid',
            gridTemplateColumns: isMob || isTab ? '1fr' : 'repeat(3, 1fr)',
            gap: isMob ? '2.8rem' : isTab ? '2.5rem' : '3.5rem',
            position: 'relative',
          }}>
            {!isMob && !isTab && (
              <div style={{
                position: 'absolute', top: 26, left: '16.6%', right: '16.6%', height: 1, zIndex: 0,
                background: `linear-gradient(90deg, ${GOLD} 0%, rgba(200,134,26,0.18) 100%)`,
              }} />
            )}

            {[
              {
                num: '01', title: 'Open the Word',
                body: 'Navigate the full Bible — ESV or NIV. Highlight what speaks to you, bookmark passages, and write verse-linked notes that grow with your faith.',
              },
              {
                num: '02', title: 'Set Your Heartbeat',
                body: 'Choose a time and write a prompt. Your AI spiritual agent will meet you there — composing a personal devotional and saving it straight to your journal.',
              },
              {
                num: '03', title: 'Study with Your Circle',
                body: "Message your group, see where friends highlighted the same verse, and join live voice or video sessions built entirely around Scripture.",
              },
            ].map((step, i) => (
              <div key={i} className={fc(rhythmVisible, i + 2)} style={{ position: 'relative', zIndex: 1 }}>
                <div style={{
                  width: 52, height: 52, borderRadius: '50%', marginBottom: '1.5rem',
                  background: i === 0 ? GOLD : WHITE,
                  border: `2px solid ${i === 0 ? GOLD : 'rgba(200,134,26,0.35)'}`,
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                }}>
                  <span style={{
                    fontFamily: "'Playfair Display', serif",
                    fontSize: '0.78rem', fontWeight: 700, letterSpacing: '0.05em',
                    color: i === 0 ? BLACK : GOLD,
                  }}>
                    {step.num}
                  </span>
                </div>
                <h3 style={{
                  fontFamily: "'Playfair Display', serif",
                  fontSize: isMob ? '1.15rem' : 'clamp(1.1rem, 1.6vw, 1.35rem)',
                  fontWeight: 700, color: BLACK, margin: '0 0 0.8rem', lineHeight: 1.2,
                }}>
                  {step.title}
                </h3>
                <p style={{
                  fontFamily: "'Lora', serif",
                  fontSize: isMob ? '0.84rem' : '0.88rem',
                  color: '#585858', lineHeight: 1.9, margin: 0,
                }}>
                  {step.body}
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── HEARTBEAT EVENTS ─────────────────────────────────────────────── */}
      <section style={{ background: BLACK, padding: vPad, position: 'relative', overflow: 'hidden' }}>
        <div style={{
          position: 'absolute', top: '50%', right: '-6%', transform: 'translateY(-50%)',
          width: isMob ? 240 : 500, height: isMob ? 240 : 500,
          borderRadius: '50%',
          background: 'radial-gradient(circle, rgba(200,134,26,0.12) 0%, transparent 70%)',
          pointerEvents: 'none',
        }} />

        <div ref={heartRef} style={{ maxWidth: 1200, margin: '0 auto', padding: hPad }}>
          <div style={{
            display: 'grid',
            gridTemplateColumns: isMob || isTab ? '1fr' : '1fr 1fr',
            gap: isMob ? '3rem' : isTab ? '3.5rem' : '5.5rem',
            alignItems: 'center',
          }}>
            <div>
              <p className={fc(heartVisible, 1)} style={{
                fontFamily: "'Lora', serif", fontSize: '0.56rem',
                letterSpacing: '0.38em', textTransform: 'uppercase',
                color: GOLD, margin: '0 0 1.2rem',
              }}>
                Heartbeat Events
              </p>
              <h2 className={fc(heartVisible, 2)} style={{
                fontFamily: "'Playfair Display', serif",
                fontSize: isMob ? '2.1rem' : isTab ? '2.6rem' : 'clamp(2.4rem, 4vw, 3.5rem)',
                fontWeight: 800, color: WHITE, margin: '0 0 1.4rem', lineHeight: 1.08,
              }}>
                Your devotion,<br />
                <span style={{ color: GOLD }}>on schedule.</span>
              </h2>
              <p className={fc(heartVisible, 3)} style={{
                fontFamily: "'Lora', serif",
                fontSize: isMob ? '0.9rem' : 'clamp(0.9rem, 1.3vw, 1.02rem)',
                color: 'rgba(244,228,193,0.62)', lineHeight: 1.95, margin: '0 0 1.5rem',
              }}>
                Set a time. Write a prompt. Let your AI spiritual agent do the rest. Every day
                at the moment you choose, your agent opens the Scripture, writes a personal
                devotional response, and saves it as a note in your journal — automatically.
              </p>
              <p className={fc(heartVisible, 3)} style={{
                fontFamily: "'IM Fell English', serif", fontStyle: 'italic',
                fontSize: isMob ? '0.95rem' : 'clamp(0.95rem, 1.3vw, 1.06rem)',
                color: 'rgba(200,134,26,0.72)', lineHeight: 1.85, margin: '0 0 2.2rem',
                paddingLeft: '1rem', borderLeft: '2px solid rgba(200,134,26,0.25)',
              }}>
                "Every morning at 6am, reflect on a Psalm and how God's faithfulness applies to my day."
              </p>
              <div className={fc(heartVisible, 4)} style={{ display: 'flex', gap: '0.75rem', flexWrap: 'wrap' }}>
                {['Daily', 'Weekly', 'Monthly'].map(tag => (
                  <span key={tag} style={{
                    fontFamily: "'Lora', serif", fontSize: '0.60rem',
                    letterSpacing: '0.16em', textTransform: 'uppercase',
                    color: GOLD, border: '1px solid rgba(200,134,26,0.32)',
                    padding: '0.4rem 0.95rem', borderRadius: 2,
                  }}>
                    {tag}
                  </span>
                ))}
              </div>
            </div>

            {/* Mock UI card */}
            <div className={fc(heartVisible, 3)}>
              <div style={{
                background: '#141414', border: '1px solid rgba(200,134,26,0.16)',
                borderRadius: 12, padding: isMob ? '1.5rem' : '1.8rem',
              }}>
                <div style={{
                  display: 'flex', alignItems: 'center', gap: '0.85rem',
                  marginBottom: '1.4rem', paddingBottom: '1.1rem',
                  borderBottom: '1px solid rgba(200,134,26,0.10)',
                }}>
                  <div style={{
                    width: 38, height: 38, borderRadius: '50%',
                    background: 'rgba(200,134,26,0.14)',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    animation: 'fsPulse 2.6s ease-in-out infinite',
                  }}>
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                      <path d="M12 21.593c-5.63-5.539-11-10.297-11-14.402 0-3.791 3.068-5.191 5.281-5.191 1.312 0 4.151.501 5.719 4.457 1.59-3.968 4.464-4.447 5.726-4.447 2.54 0 5.274 1.621 5.274 5.181 0 4.069-5.136 8.625-11 14.402z" fill={GOLD} opacity="0.85" />
                    </svg>
                  </div>
                  <div>
                    <p style={{ fontFamily: "'Lora', serif", fontSize: '0.74rem', color: CREAM, margin: 0, fontWeight: 600 }}>
                      Daily Devotional Agent
                    </p>
                    <p style={{ fontFamily: "'Lora', serif", fontSize: '0.58rem', color: 'rgba(200,134,26,0.5)', margin: '3px 0 0', letterSpacing: '0.1em' }}>
                      FIRES DAILY · 6:00 AM
                    </p>
                  </div>
                </div>

                <p style={{
                  fontFamily: "'Lora', serif", fontSize: '0.60rem',
                  color: 'rgba(244,228,193,0.40)', margin: '0 0 0.5rem',
                  letterSpacing: '0.14em', textTransform: 'uppercase',
                }}>
                  Prompt
                </p>
                <p style={{
                  fontFamily: "'IM Fell English', serif", fontStyle: 'italic',
                  fontSize: '0.90rem', color: 'rgba(244,228,193,0.70)',
                  lineHeight: 1.7, margin: '0 0 1.4rem',
                }}>
                  "Reflect on a Psalm and how God's faithfulness applies to my day."
                </p>

                <div style={{
                  background: 'rgba(200,134,26,0.07)', borderRadius: 8,
                  padding: '1rem 1.1rem', borderLeft: `2px solid ${GOLD}`,
                }}>
                  <p style={{
                    fontFamily: "'Lora', serif", fontSize: '0.58rem',
                    color: GOLD, margin: '0 0 0.5rem',
                    letterSpacing: '0.15em', textTransform: 'uppercase',
                  }}>
                    Today's Note — Psalm 23:1
                  </p>
                  <p style={{
                    fontFamily: "'Lora', serif",
                    fontSize: isMob ? '0.78rem' : '0.82rem',
                    color: 'rgba(244,228,193,0.60)', lineHeight: 1.8, margin: 0,
                  }}>
                    "The Lord is my shepherd; I lack nothing." Today, rest in sufficiency.
                    Whatever gap you feel — provision, peace, purpose — your Shepherd already
                    knows it. Walk forward in that confidence...
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ── AI SPIRITUAL AGENTS ──────────────────────────────────────────── */}
      <section style={{ background: WHITE, padding: vPad, overflow: 'hidden' }}>
        <div ref={agentRef} style={{ maxWidth: 1200, margin: '0 auto', padding: hPad }}>
          <div style={{
            display: 'grid',
            gridTemplateColumns: isMob || isTab ? '1fr' : '1fr 1fr',
            gap: isMob ? '3rem' : isTab ? '3.5rem' : '5.5rem',
            alignItems: 'center',
          }}>
            {/* Chat preview — desktop only */}
            {!isMob && !isTab && (
              <div className={fc(agentVisible, 2)}>
                <div style={{ background: BLACK, borderRadius: 12, padding: '1.8rem', border: '1px solid rgba(200,134,26,0.10)' }}>
                  {[
                    { role: 'New Testament Scholar', mine: false, msg: 'In John 1, the Logos draws on both Jewish Wisdom tradition and Greek philosophy. John declares this eternal Word became flesh — entering the creation he authored.' },
                    { role: 'You',                   mine: true,  msg: 'Why does John start with "In the beginning"?' },
                    { role: 'New Testament Scholar', mine: false, msg: 'It mirrors Genesis 1:1 deliberately. John positions Jesus as existing before creation itself — the Word through whom all things were made (v.3).' },
                  ].map((m, i) => (
                    <div key={i} style={{
                      display: 'flex', flexDirection: m.mine ? 'row-reverse' : 'row',
                      gap: '0.65rem', alignItems: 'flex-start',
                      marginBottom: i < 2 ? '1rem' : 0,
                    }}>
                      <div style={{
                        width: 28, height: 28, borderRadius: '50%', flexShrink: 0,
                        background: m.mine ? 'rgba(200,134,26,0.18)' : 'rgba(200,134,26,0.10)',
                        display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11,
                      }}>
                        {m.mine ? '👤' : '✦'}
                      </div>
                      <div style={{
                        background: m.mine ? 'rgba(200,134,26,0.09)' : '#1A1A1A',
                        borderRadius: 8, padding: '0.65rem 0.9rem', maxWidth: '82%',
                      }}>
                        {!m.mine && (
                          <p style={{
                            fontFamily: "'Lora', serif", fontSize: '0.54rem', color: GOLD,
                            margin: '0 0 0.3rem', letterSpacing: '0.15em', textTransform: 'uppercase',
                          }}>
                            {m.role}
                          </p>
                        )}
                        <p style={{
                          fontFamily: "'Lora', serif", fontSize: '0.80rem',
                          color: 'rgba(244,228,193,0.72)', lineHeight: 1.78, margin: 0,
                        }}>
                          {m.msg}
                        </p>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            <div>
              <p className={fc(agentVisible, 1)} style={{
                fontFamily: "'Lora', serif", fontSize: '0.56rem',
                letterSpacing: '0.38em', textTransform: 'uppercase',
                color: 'rgba(200,134,26,0.65)', margin: '0 0 1.2rem',
              }}>
                AI Spiritual Agents
              </p>
              <h2 className={fc(agentVisible, 2)} style={{
                fontFamily: "'Playfair Display', serif",
                fontSize: isMob ? '2.1rem' : isTab ? '2.6rem' : 'clamp(2.4rem, 4vw, 3.5rem)',
                fontWeight: 800, color: BLACK, margin: '0 0 1.4rem', lineHeight: 1.08,
              }}>
                Your personal<br />theologian.
              </h2>
              <p className={fc(agentVisible, 3)} style={{
                fontFamily: "'Lora', serif",
                fontSize: isMob ? '0.9rem' : 'clamp(0.9rem, 1.3vw, 1.02rem)',
                color: '#585858', lineHeight: 1.95, margin: '0 0 2rem',
              }}>
                Build an AI agent shaped around your theology — whether you're a Reformed
                expositor, a Pentecostal worshipper, or somewhere in between. Your agent
                knows your study context, engages your questions, and goes deeper into the
                Word alongside you.
              </p>
              <div className={fc(agentVisible, 4)} style={{ display: 'flex', flexDirection: 'column', gap: '0.88rem' }}>
                {[
                  'Custom theological role & personality',
                  'Summarizes your group study sessions',
                  'Writes heartbeat devotional notes on schedule',
                  'Verse-linked notes saved to your journal',
                ].map((feat, i) => (
                  <div key={i} style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
                    <div style={{
                      width: 20, height: 20, borderRadius: '50%', flexShrink: 0,
                      background: 'rgba(200,134,26,0.10)',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                    }}>
                      <CheckIcon />
                    </div>
                    <p style={{ fontFamily: "'Lora', serif", fontSize: '0.87rem', color: '#333', margin: 0 }}>
                      {feat}
                    </p>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ── FEATURES GRID ────────────────────────────────────────────────── */}
      <section style={{ background: '#0A0A0A', padding: vPad }}>
        <div ref={featRef} style={{ maxWidth: 1200, margin: '0 auto', padding: hPad }}>
          <div style={{ textAlign: isMob ? 'left' : 'center', marginBottom: isMob ? '3rem' : '4.5rem' }}>
            <p className={fc(featVisible, 1)} style={{
              fontFamily: "'Lora', serif", fontSize: '0.56rem',
              letterSpacing: '0.38em', textTransform: 'uppercase',
              color: GOLD, margin: '0 0 0.8rem',
            }}>
              The Full Platform
            </p>
            <h2 className={fc(featVisible, 2)} style={{
              fontFamily: "'Playfair Display', serif",
              fontSize: isMob ? '1.85rem' : isTab ? '2.4rem' : 'clamp(2.2rem, 3.6vw, 3rem)',
              fontWeight: 700, color: WHITE, margin: 0, lineHeight: 1.12,
            }}>
              Everything you need to grow.
            </h2>
          </div>

          <div style={{
            display: 'grid',
            gridTemplateColumns: isMob ? '1fr' : isTab ? '1fr 1fr' : 'repeat(4, 1fr)',
            gap: isMob ? '1.4rem' : '1.6rem',
          }}>
            {FEATURES.map((f, i) => (
              <div
                key={i}
                className={fc(featVisible, i + 1)}
                style={{
                  background: '#141414', borderRadius: 10,
                  padding: isMob ? '1.6rem' : '1.9rem',
                  border: '1px solid rgba(200,134,26,0.09)',
                  transition: 'border-color 0.25s, transform 0.25s',
                }}
                onMouseEnter={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.38)'; e.currentTarget.style.transform = 'translateY(-3px)'; }}
                onMouseLeave={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.09)';  e.currentTarget.style.transform = 'translateY(0)';   }}
              >
                <p style={{
                  fontFamily: "'Lora', serif", fontSize: '0.52rem',
                  letterSpacing: '0.32em', textTransform: 'uppercase',
                  color: GOLD, margin: '0 0 0.9rem',
                }}>
                  {f.label}
                </p>
                <h3 style={{
                  fontFamily: "'Playfair Display', serif",
                  fontSize: isMob ? '1.1rem' : 'clamp(1.05rem, 1.6vw, 1.3rem)',
                  fontWeight: 700, color: WHITE, margin: '0 0 0.8rem', lineHeight: 1.22,
                }}>
                  {f.heading}
                </h3>
                <p style={{
                  fontFamily: "'Lora', serif",
                  fontSize: isMob ? '0.82rem' : '0.84rem',
                  color: 'rgba(244,228,193,0.42)', lineHeight: 1.9, margin: 0,
                }}>
                  {f.body}
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── SCRIPTURE QUOTE ──────────────────────────────────────────────── */}
      <section style={{
        background: 'linear-gradient(135deg, #1A1000 0%, #0D0D0D 42%, #090800 100%)',
        padding: isMob ? '5rem 1.5rem' : 'clamp(6rem, 12vw, 10rem) 2rem',
        textAlign: 'center', position: 'relative', overflow: 'hidden',
      }}>
        <div style={{
          position: 'absolute', inset: 0,
          background: 'radial-gradient(ellipse at center, rgba(200,134,26,0.07) 0%, transparent 65%)',
          pointerEvents: 'none',
        }} />
        <div style={{ position: 'relative', zIndex: 1, maxWidth: 680, margin: '0 auto' }}>
          <div style={{
            width: 36, height: 1, margin: '0 auto 2.2rem',
            background: `linear-gradient(90deg, transparent, ${GOLD}, transparent)`,
          }} />
          <blockquote style={{
            fontFamily: "'IM Fell English', serif", fontStyle: 'italic',
            fontSize: isMob ? '1.35rem' : isTab ? '1.6rem' : 'clamp(1.5rem, 2.6vw, 2.1rem)',
            color: CREAM, lineHeight: 1.65, margin: '0 0 1.5rem', fontWeight: 400,
          }}>
            "As iron sharpens iron, so one person sharpens another."
          </blockquote>
          <p style={{
            fontFamily: "'Lora', serif", fontSize: '0.60rem',
            letterSpacing: '0.30em', textTransform: 'uppercase',
            color: 'rgba(200,134,26,0.52)', margin: 0,
          }}>
            Proverbs 27:17
          </p>
          <div style={{
            width: 36, height: 1, margin: '2.2rem auto 0',
            background: `linear-gradient(90deg, transparent, ${GOLD}, transparent)`,
          }} />
        </div>
      </section>

      {/* ── FINAL CTA ────────────────────────────────────────────────────── */}
      <section style={{ background: WHITE, padding: isMob ? '5.5rem 1.4rem' : 'clamp(6.5rem, 12vw, 10.5rem) 2rem' }}>
        <div ref={ctaRef} style={{ maxWidth: 660, margin: '0 auto', textAlign: 'center' }}>
          <p className={fc(ctaVisible, 1)} style={{
            fontFamily: "'Lora', serif", fontSize: '0.56rem',
            letterSpacing: '0.38em', textTransform: 'uppercase',
            color: 'rgba(200,134,26,0.65)', margin: '0 0 1.2rem',
          }}>
            Begin Today
          </p>
          <h2 className={fc(ctaVisible, 2)} style={{
            fontFamily: "'Playfair Display', serif",
            fontSize: isMob ? '2.1rem' : isTab ? '2.6rem' : 'clamp(2.6rem, 4.5vw, 3.9rem)',
            fontWeight: 800, color: BLACK, margin: '0 0 1.4rem',
            lineHeight: 1.08, letterSpacing: '-0.02em',
          }}>
            Faith was never meant<br />to be carried alone.
          </h2>
          <p className={fc(ctaVisible, 3)} style={{
            fontFamily: "'Lora', serif",
            fontSize: isMob ? '0.9rem' : 'clamp(0.9rem, 1.3vw, 1.02rem)',
            color: '#585858', lineHeight: 1.95, margin: '0 0 2.6rem',
          }}>
            Join a community of believers who read the Word together, study with AI spiritual
            companions, and show up to their devotion every single day.
          </p>
          <div className={fc(ctaVisible, 4)} style={{
            display: 'flex', gap: '0.9rem', justifyContent: 'center', flexWrap: 'wrap',
          }}>
            <button
              onClick={() => navigate('/signin')}
              style={{
                background: BLACK, color: WHITE, border: 'none',
                padding: isMob ? '0.92rem 2.1rem' : '1.1rem 3.2rem',
                fontSize: isMob ? '0.68rem' : '0.75rem',
                letterSpacing: '0.18em', textTransform: 'uppercase',
                fontFamily: "'Lora', serif", cursor: 'pointer', borderRadius: 3,
                transition: 'background 0.2s, transform 0.15s',
              }}
              onMouseEnter={e => { e.currentTarget.style.background = '#1C1C1C'; e.currentTarget.style.transform = 'translateY(-1px)'; }}
              onMouseLeave={e => { e.currentTarget.style.background = BLACK;     e.currentTarget.style.transform = 'translateY(0)';    }}
            >
              Join Free →
            </button>
            <button
              onClick={() => navigate('/reader')}
              style={{
                background: 'transparent', color: BLACK,
                border: `1.5px solid ${BLACK}`,
                padding: isMob ? '0.92rem 2.1rem' : '1.1rem 2.9rem',
                fontSize: isMob ? '0.68rem' : '0.75rem',
                letterSpacing: '0.18em', textTransform: 'uppercase',
                fontFamily: "'Lora', serif", cursor: 'pointer', borderRadius: 3,
                transition: 'all 0.2s',
              }}
              onMouseEnter={e => { e.currentTarget.style.color = GOLD; e.currentTarget.style.borderColor = GOLD; e.currentTarget.style.transform = 'translateY(-1px)'; }}
              onMouseLeave={e => { e.currentTarget.style.color = BLACK; e.currentTarget.style.borderColor = BLACK; e.currentTarget.style.transform = 'translateY(0)'; }}
            >
              Read the Bible
            </button>
          </div>
        </div>
      </section>

      {/* ── FOOTER ───────────────────────────────────────────────────────── */}
      <footer style={{
        background: BLACK, padding: '2.2rem', textAlign: 'center',
        fontFamily: "'Lora', serif", color: 'rgba(244,228,193,0.28)',
        borderTop: '1px solid rgba(200,134,26,0.10)',
      }}>
        <p style={{ fontSize: '0.65rem', letterSpacing: '0.14em', margin: '0 0 0.75rem' }}>
          © 2026 FellowScript &nbsp;·&nbsp; A Digital Scripture Community
        </p>
        <div style={{ display: 'flex', justifyContent: 'center', gap: '1.5rem', fontSize: '0.60rem', letterSpacing: '0.12em' }}>
          <Link to="/privacy" style={{ color: 'rgba(200,134,26,0.55)', textDecoration: 'none' }}
            onMouseEnter={e => e.currentTarget.style.color = GOLD}
            onMouseLeave={e => e.currentTarget.style.color = 'rgba(200,134,26,0.55)'}>
            PRIVACY POLICY
          </Link>
          <span style={{ opacity: 0.25 }}>·</span>
          <Link to="/terms" style={{ color: 'rgba(200,134,26,0.55)', textDecoration: 'none' }}
            onMouseEnter={e => e.currentTarget.style.color = GOLD}
            onMouseLeave={e => e.currentTarget.style.color = 'rgba(200,134,26,0.55)'}>
            TERMS OF SERVICE
          </Link>
        </div>
      </footer>
    </div>
  );
}
