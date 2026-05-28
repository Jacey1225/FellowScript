import React, { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Layout, Card, Button, Typography, Tag, Row, Col, Spin } from 'antd';
import { ReadOutlined } from '@ant-design/icons';
import AppNav from '../components/AppNav.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { API } from '../config.js';

const { Content, Footer } = Layout;
const { Title, Text, Paragraph } = Typography;

const DAILY_VERSES = [
  { text: "For God so loved the world, that he gave his only Son, that whoever believes in him should not perish but have eternal life.", ref: "John 3:16" },
  { text: "I can do all things through him who strengthens me.", ref: "Philippians 4:13" },
  { text: "For I know the plans I have for you, declares the Lord, plans for welfare and not for evil, to give you a future and a hope.", ref: "Jeremiah 29:11" },
  { text: "Trust in the Lord with all your heart, and do not lean on your own understanding.", ref: "Proverbs 3:5–6" },
  { text: "And we know that for those who love God all things work together for good.", ref: "Romans 8:28" },
  { text: "Fear not, for I am with you; be not dismayed, for I am your God.", ref: "Isaiah 41:10" },
  { text: "Be strong and courageous. Do not be frightened, and do not be dismayed, for the Lord your God is with you wherever you go.", ref: "Joshua 1:9" },
  { text: "The Lord is my shepherd; I shall not want.", ref: "Psalm 23:1" },
  { text: "Come to me, all who labor and are heavy laden, and I will give you rest.", ref: "Matthew 11:28" },
  { text: "Do not be conformed to this world, but be transformed by the renewal of your mind.", ref: "Romans 12:2" },
  { text: "For God gave us a spirit not of fear but of power and love and self-control.", ref: "2 Timothy 1:7" },
  { text: "But the fruit of the Spirit is love, joy, peace, patience, kindness, goodness, faithfulness.", ref: "Galatians 5:22–23" },
  { text: "For by grace you have been saved through faith. And this is not your own doing; it is the gift of God.", ref: "Ephesians 2:8" },
  { text: "So now faith, hope, and love abide, these three; but the greatest of these is love.", ref: "1 Corinthians 13:13" },
  { text: "But God shows his love for us in that while we were still sinners, Christ died for us.", ref: "Romans 5:8" },
  { text: "This is the day that the Lord has made; let us rejoice and be glad in it.", ref: "Psalm 118:24" },
  { text: "Create in me a clean heart, O God, and renew a right spirit within me.", ref: "Psalm 51:10" },
  { text: "Do not be anxious about anything, but in everything by prayer and supplication with thanksgiving let your requests be made known to God.", ref: "Philippians 4:6" },
  { text: "Delight yourself in the Lord, and he will give you the desires of your heart.", ref: "Psalm 37:4" },
  { text: "Be still, and know that I am God.", ref: "Psalm 46:10" },
  { text: "Your word is a lamp to my feet and a light to my path.", ref: "Psalm 119:105" },
  { text: "As iron sharpens iron, so one person sharpens another.", ref: "Proverbs 27:17" },
  { text: "Draw near to God, and he will draw near to you.", ref: "James 4:8" },
  { text: "I am the vine; you are the branches. Whoever abides in me and I in him, he it is that bears much fruit.", ref: "John 15:5" },
  { text: "The steadfast love of the Lord never ceases; his mercies never come to an end; they are new every morning.", ref: "Lamentations 3:22–23" },
  { text: "The Lord is my light and my salvation; whom shall I fear?", ref: "Psalm 27:1" },
  { text: "But they who wait for the Lord shall renew their strength; they shall mount up with wings like eagles.", ref: "Isaiah 40:31" },
  { text: "For where two or three are gathered in my name, there am I among them.", ref: "Matthew 18:20" },
];

function getDailyVerse() {
  const idx = Math.floor(Date.now() / 86_400_000) % DAILY_VERSES.length;
  return DAILY_VERSES[idx];
}

const WIDGET_DELAY = ['0.15s', '0.25s', '0.32s', '0.40s', '0.48s', '0.56s'];

const FEATURES = [
  {
    label: 'Our Mission',
    heading: <>Fan into flame <em style={{ color: 'var(--gold)', fontStyle: 'italic' }}>the gift of God.</em></>,
    body: 'FellowScript sparks meaningful connections among those who seek to grow in faith — side by side, in the Word, together.',
    footer: '"For this reason I remind you to fan into flame the gift of God." — 2 Tim 1:6',
  },
  {
    label: 'Scripture',
    heading: <>A Living, <em style={{ color: 'var(--gold)', fontStyle: 'italic' }}>Breathing</em> Bible</>,
    body: 'Navigate the full ESV & NIV by book and chapter. Jump to any passage in seconds.',
    chips: ['66 Books', 'ESV & NIV', 'Verse Nav'],
  },
  {
    label: 'Highlights',
    heading: <>Mark What <em style={{ color: 'var(--gold)', fontStyle: 'italic' }}>Moves You.</em></>,
    body: 'Highlight scripture in five colors. See where your group has marked the same verses.',
    swatches: ['#F5C842', '#E8861A', '#4CAF78', '#E0607E', '#5B9BD5'],
  },
  {
    label: 'Community',
    heading: <>Study Together, <em style={{ color: 'var(--gold)', fontStyle: 'italic' }}>In Real Time.</em></>,
    body: 'Message your group, share notes, and watch the Word come alive through shared eyes.',
    chips: ['Group Chat', 'Live Notes', 'Direct Msgs'],
  },
];

export default function Dashboard() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const verse    = getDailyVerse();

  const [groupNote,        setGroupNote]        = useState(null);
  const [groupNoteLoading, setGroupNoteLoading] = useState(false);

  useEffect(() => {
    if (!user) return;
    const groups = user.groups || [];
    if (groups.length === 0) return;
    setGroupNoteLoading(true);
    const allNotes = [];
    Promise.all(groups.map(async gid => {
      try {
        const res = await fetch(`${API}/groups/${user.user_id}/${gid}/notes`);
        if (!res.ok) return;
        const data = await res.json();
        for (const [username, noteMap] of Object.entries(data)) {
          for (const [, note] of Object.entries(noteMap)) {
            allNotes.push({ ...note, _username: username });
          }
        }
      } catch {}
    })).then(() => {
      if (allNotes.length) {
        allNotes.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
        setGroupNote(allNotes[0]);
      }
      setGroupNoteLoading(false);
    });
  }, [user]);

  const CARD_STYLE = {
    background: 'rgba(6,4,1,0.88)',
    border: '1px solid rgba(200,134,26,0.16)',
    backdropFilter: 'blur(14px)',
    borderRadius: 12,
  };

  return (
    <Layout style={{ minHeight: '100vh', background: 'transparent' }}>
      <video id="bg-video" autoPlay muted loop playsInline>
        <source src="/data/bg.mp4" type="video/mp4" />
      </video>
      <AppNav />

      <Content style={{ paddingTop: 'calc(var(--nav-h) + 2.2rem)', paddingBottom: '4rem', paddingLeft: '2.5rem', paddingRight: '2.5rem', maxWidth: 1380, margin: '0 auto', width: '100%' }}>

        {/* Header */}
        <div style={{ marginBottom: '1.4rem', animation: 'fadeUp 0.6s ease 0.05s forwards', opacity: 0 }}>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.6rem', letterSpacing: '0.32em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.2rem' }}>
            A Digital Scripture Community
          </Text>
          <Title level={2} style={{ margin: 0, fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>
            Your <em style={{ color: 'var(--gold)', fontStyle: 'italic' }}>Dashboard</em>
          </Title>
        </div>

        {/* Top row */}
        <Row gutter={[20, 20]} style={{ marginBottom: 20 }} align="stretch">
          <Col xs={24} lg={10}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 20, height: '100%' }}>
              {/* Daily verse */}
              <Card style={{ ...CARD_STYLE, borderColor: 'rgba(200,134,26,0.28)', background: 'linear-gradient(148deg,rgba(12,7,2,0.93) 0%,rgba(20,11,3,0.91) 100%)', animationDelay: WIDGET_DELAY[0], animation: 'fadeUp 0.6s ease forwards', opacity: 0 }}>
                <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: '0.6rem' }}>Daily Verse</Text>
                <blockquote style={{ fontFamily: "'IM Fell English', serif", fontStyle: 'italic', fontSize: 'clamp(1rem,1.4vw,1.18rem)', lineHeight: 1.8, color: 'var(--parchment)', borderLeft: '2px solid rgba(200,134,26,0.38)', paddingLeft: '1rem', margin: '0 0 0.75rem' }}>
                  "{verse.text}"
                </blockquote>
                <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.72rem', letterSpacing: '0.1em', color: 'var(--gold)' }}>— {verse.ref}</Text>
              </Card>

              {/* Action buttons */}
              <Row gutter={12}>
                <Col span={12}>
                  <Button type="primary" block size="large" icon={<ReadOutlined />} onClick={() => navigate('/reader')}
                    style={{ fontFamily: "'Lora', serif", letterSpacing: '0.1em', textTransform: 'uppercase', borderRadius: 8 }}>
                    Start Reading
                  </Button>
                </Col>
                <Col span={12}>
                  <Button block size="large" onClick={() => {}}
                    style={{ fontFamily: "'Lora', serif", letterSpacing: '0.1em', textTransform: 'uppercase', borderRadius: 8 }}>
                    Take the Tour
                  </Button>
                </Col>
              </Row>
            </div>
          </Col>

          {/* Latest group note */}
          <Col xs={24} lg={14}>
            <Card style={{ ...CARD_STYLE, borderColor: 'rgba(200,134,26,0.14)', animationDelay: WIDGET_DELAY[1], animation: 'fadeUp 0.6s ease forwards', opacity: 0, height: '100%' }}>
              <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: '0.6rem' }}>Latest from Your Groups</Text>
              {!user
                ? <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.82rem', color: 'rgba(244,228,193,0.28)', lineHeight: 1.75 }}>Sign in to see the latest notes from your study groups.</Text>
                : groupNoteLoading
                  ? <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem' }}><Spin size="small" /><Text style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.28)' }}>Loading…</Text></div>
                  : !groupNote
                    ? <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.82rem', color: 'rgba(244,228,193,0.28)', lineHeight: 1.75 }}>No group notes yet — be the first to share one while reading!</Text>
                    : <>
                        <Title level={5} style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)', marginBottom: '0.4rem' }}>{groupNote.title || 'Untitled Note'}</Title>
                        <Paragraph style={{ fontFamily: "'Lora', serif", fontSize: '0.88rem', color: 'rgba(244,228,193,0.55)', lineHeight: 1.8, WebkitLineClamp: 5, WebkitBoxOrient: 'vertical', overflow: 'hidden', display: '-webkit-box' }}>
                          {groupNote.text}
                        </Paragraph>
                        <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', borderTop: '1px solid rgba(200,134,26,0.1)', paddingTop: '0.6rem', marginTop: 'auto' }}>
                          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.68rem', color: 'var(--gold)' }}>@{groupNote._username}</Text>
                          {groupNote.timestamp && <Text style={{ fontSize: '0.6rem', color: 'rgba(244,228,193,0.22)', marginLeft: 'auto' }}>
                            {new Date(groupNote.timestamp).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })}
                          </Text>}
                        </div>
                      </>
              }
            </Card>
          </Col>
        </Row>

        {/* Feature widgets */}
        <Row gutter={[20, 20]}>
          {FEATURES.map((f, i) => (
            <Col key={i} xs={24} sm={12} xl={6}>
              <Card style={{ ...CARD_STYLE, animationDelay: WIDGET_DELAY[i + 2], animation: 'fadeUp 0.6s ease forwards', opacity: 0, height: '100%' }}>
                <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: '0.6rem' }}>{f.label}</Text>
                <Title level={5} style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)', marginBottom: '0.6rem', lineHeight: 1.2 }}>{f.heading}</Title>
                <Paragraph style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', lineHeight: 1.78, color: 'rgba(244,228,193,0.45)', marginBottom: '0.8rem' }}>{f.body}</Paragraph>
                {f.footer && <Text style={{ fontFamily: "'IM Fell English', serif", fontStyle: 'italic', fontSize: '0.7rem', color: 'rgba(200,134,26,0.45)', borderTop: '1px solid rgba(200,134,26,0.1)', paddingTop: '0.6rem', display: 'block', lineHeight: 1.55 }}>{f.footer}</Text>}
                {f.chips && <div className="feature-chips">{f.chips.map(c => <Tag key={c} style={{ fontSize: '0.6rem', letterSpacing: '0.08em' }}>{c}</Tag>)}</div>}
                {f.swatches && <div style={{ display: 'flex', gap: '0.5rem' }}>{f.swatches.map(s => <span key={s} style={{ width: 20, height: 20, borderRadius: '50%', background: s, border: '2px solid rgba(255,255,255,0.22)', display: 'inline-block' }} />)}</div>}
              </Card>
            </Col>
          ))}
        </Row>
      </Content>

      <footer className="fs-footer">&copy; 2026 FellowScript &nbsp;·&nbsp; A Digital Scripture Community</footer>
    </Layout>
  );
}
