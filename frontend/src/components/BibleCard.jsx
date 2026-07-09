import React, { useRef, useEffect } from 'react';
import { Card, Button, Space, Typography, Spin } from 'antd';
import { LeftOutlined, RightOutlined } from '@ant-design/icons';

const { Text } = Typography;

export default function BibleCard({
  loading, loadError, curBook, curChapter, chapterHTML,
  chapterCount, preamble, onPrev, onNext, onVerseClick,
  applyHighlights,
}) {
  const bodyRef = useRef(null);

  useEffect(() => {
    if (bodyRef.current && chapterHTML) {
      applyHighlights(bodyRef.current);
    }
  }, [chapterHTML, applyHighlights]);

  const handleClick = (e) => {
    const span = e.target.closest('.verse-span');
    if (span && span.id.startsWith('vs')) {
      const vNum = parseInt(span.id.slice(2));
      onVerseClick(span, vNum, e);
    }
  };

  if (loading) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '1.4rem', padding: '8rem 2rem', color: 'rgba(244,228,193,0.35)' }}>
        <Spin size="large" />
        <Text style={{ fontSize: '0.72rem', letterSpacing: '0.25em', textTransform: 'uppercase', color: 'inherit' }}>
          Loading Scripture…
        </Text>
      </div>
    );
  }

  if (loadError) {
    return (
      <div style={{ textAlign: 'center', padding: '8rem 2rem', color: 'rgba(200,134,26,0.65)', fontSize: '0.8rem', letterSpacing: '0.15em', textTransform: 'uppercase' }}>
        Could not load scripture data.
      </div>
    );
  }

  if (!curBook || !curChapter || !chapterHTML) {
    return (
      <div style={{ textAlign: 'center', padding: '6rem 2rem', maxWidth: 500 }}>
        <Text style={{ fontSize: '0.68rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'var(--gold)', display: 'block', marginBottom: '1.4rem' }}>
          A Digital Scripture Community
        </Text>
        <Text style={{ fontFamily: "'Playfair Display', serif", fontSize: 'clamp(2rem,5vw,3rem)', fontWeight: 700, color: 'var(--parchment)', display: 'block', lineHeight: 1.2 }}>
          Begin <em style={{ color: 'var(--gold)', fontStyle: 'italic' }}>Reading</em>
        </Text>
        <Text style={{ fontSize: '0.88rem', color: 'rgba(244,228,193,0.45)', lineHeight: 1.85, display: 'block', marginTop: '1.1rem' }}>
          Select a book and chapter above to begin your study.
        </Text>
      </div>
    );
  }

  return (
    <Card
      className="chapter-card"
      style={{ width: '100%', margin: 0 }}
      bordered={false}
    >
      {/* Header */}
      <div style={{ marginBottom: '2.2rem', paddingBottom: '1.5rem', borderBottom: '1px solid rgba(180,130,30,0.28)' }}>
        <div className="card-book-label">{curBook.toUpperCase()}</div>
        <div className="card-title">Chapter {curChapter}</div>
        {curChapter === 1 && preamble && (
          <div className="card-section-head">{preamble}</div>
        )}
      </div>

      {/* Body */}
      <div
        ref={bodyRef}
        className="card-body"
        dangerouslySetInnerHTML={{ __html: chapterHTML }}
        onClick={handleClick}
      />

      {/* Navigation */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: '3.2rem', paddingTop: '1.8rem', borderTop: '1px solid rgba(180,130,30,0.28)' }}>
        <Button
          icon={<LeftOutlined />}
          onClick={onPrev}
          disabled={curChapter <= 1}
          style={{ fontFamily: "'Lora', serif", fontSize: '0.76rem', letterSpacing: '0.1em', textTransform: 'uppercase' }}
        >
          Prev
        </Button>
        <Text style={{ fontFamily: "'IM Fell English', serif", fontStyle: 'italic', fontSize: '0.9rem', color: 'rgba(26,16,10,0.45)' }}>
          {curBook} · {curChapter}
        </Text>
        <Button
          icon={<RightOutlined />}
          iconPosition="end"
          onClick={onNext}
          disabled={curChapter >= chapterCount}
          style={{ fontFamily: "'Lora', serif", fontSize: '0.76rem', letterSpacing: '0.1em', textTransform: 'uppercase' }}
        >
          Next
        </Button>
      </div>
    </Card>
  );
}
