import React, { useState, useEffect, useLayoutEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { Spin } from 'antd';
import { ArrowUpOutlined, CloseOutlined, CheckOutlined, WarningOutlined } from '@ant-design/icons';
import {
  askVerse, verseAskErrorCopy, placeVerseAskOverlay, placeVerseAskColumn,
  MAX_QUESTION_CHARS, COUNTER_FROM,
} from '../lib/verseAsk.js';
import '../styles/verseAsk.css';

// Per-verse "Ask AI" (task 20261112-verse-ask-ai). Everything here is a
// portaled, position:fixed layer on document.body: it never sits in the verse
// text flow, never calls scrollIntoView, and focuses with preventScroll, so
// opening, growing with the answer, and closing cannot move text or scroll.
// The AI reply is rendered as a plain text node only (never HTML).

const MENU_MARGIN = 8;

function prefersReducedMotion() {
  return typeof window !== 'undefined' && !!window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

const SparkleIcon = () => (
  <svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor" aria-hidden="true" focusable="false">
    <path d="M12 2l1.9 6.1L20 10l-6.1 1.9L12 18l-1.9-6.1L4 10l6.1-1.9L12 2zm7 12l.9 2.6L22.5 17.5l-2.6.9L19 21l-.9-2.6-2.6-.9 2.6-.9L19 14z" />
  </svg>
);

// Right-click menu with the single "Ask AI" entry, styled as .msg-action-menu.
export function VerseAskMenu({ x, y, onPick, onClose }) {
  const ref = useRef(null);
  const [pos, setPos] = useState(null);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const w = el.offsetWidth || 180;
    const h = el.offsetHeight || 50;
    setPos({
      left: Math.max(MENU_MARGIN, Math.min(x, window.innerWidth - w - MENU_MARGIN)),
      top: Math.max(MENU_MARGIN, Math.min(y, window.innerHeight - h - MENU_MARGIN)),
    });
  }, [x, y]);

  useEffect(() => {
    ref.current?.querySelector('[role="menuitem"]')?.focus({ preventScroll: true });
    const onDown = (e) => { if (!ref.current?.contains(e.target)) onClose(); };
    const dismiss = () => onClose();
    document.addEventListener('pointerdown', onDown, true);
    window.addEventListener('resize', dismiss);
    window.addEventListener('blur', dismiss);
    document.addEventListener('scroll', dismiss, true);
    return () => {
      document.removeEventListener('pointerdown', onDown, true);
      window.removeEventListener('resize', dismiss);
      window.removeEventListener('blur', dismiss);
      document.removeEventListener('scroll', dismiss, true);
    };
  }, [onClose]);

  const onKeyDown = (e) => {
    if (e.key === 'Escape' || e.key === 'Tab') { e.preventDefault(); e.stopPropagation(); onClose(); }
  };

  return createPortal(
    // eslint-disable-next-line jsx-a11y/no-noninteractive-element-interactions
    <div
      ref={ref}
      role="menu"
      aria-label="Verse actions"
      className={`msg-action-menu${prefersReducedMotion() ? ' msg-action-menu-reduced' : ''}`}
      style={{ top: pos ? pos.top : 0, left: pos ? pos.left : 0, visibility: pos ? 'visible' : 'hidden' }}
      onKeyDown={onKeyDown}
    >
      <button type="button" role="menuitem" className="msg-action-item" onClick={onPick}>
        <span className="msg-action-icon va-gold" aria-hidden="true"><SparkleIcon /></span>
        <span>Ask AI</span>
      </button>
    </div>,
    document.body,
  );
}

// The overlay: pill input above the verse, response panel below it (or above,
// flipped, near the bottom of the viewport).
export function VerseAskOverlay({ userId, reference, verseText, verseNum, anchor, onClose }) {
  const pillRef = useRef(null);
  const panelRef = useRef(null);
  const inputRef = useRef(null);
  const abortRef = useRef(null);
  const copyTimerRef = useRef(null);
  const [question, setQuestion] = useState('');
  const [status, setStatus] = useState('idle'); // idle | loading | done | error
  const [asked, setAsked] = useState('');
  const [answer, setAnswer] = useState('');
  const [errorCopy, setErrorCopy] = useState('');
  const [copied, setCopied] = useState(false);
  const [geo, setGeo] = useState(null);
  const reduced = prefersReducedMotion();
  const showPanel = status !== 'idle';

  // Place from the captured anchor and the measured sizes. Runs on content
  // changes only; it changes the overlay's own top/height, never page layout.
  const place = useCallback(() => {
    const pill = pillRef.current;
    if (!pill) return;
    const col = placeVerseAskColumn({ columnRect: anchor.column, viewportWidth: window.innerWidth });
    const p = placeVerseAskOverlay({
      verseRect: anchor.verse,
      viewport: { height: window.innerHeight },
      pillH: pill.offsetHeight,
      panelH: panelRef.current ? panelRef.current.scrollHeight + 2 : 0,
    });
    setGeo((prev) => (prev && prev.left === col.left && prev.width === col.width && prev.pillTop === p.pillTop &&
      prev.panelTop === p.panelTop && prev.panelMaxH === p.panelMaxH ? prev : { ...col, ...p }));
  }, [anchor]);

  useLayoutEffect(() => { place(); }, [place, status, answer, errorCopy, question]);

  useEffect(() => {
    window.addEventListener('resize', place);
    return () => window.removeEventListener('resize', place);
  }, [place]);

  // Autofocus without scrolling.
  useEffect(() => { inputRef.current?.focus({ preventScroll: true }); }, []);

  // Autosize the textarea up to 3 lines inside the pill.
  useLayoutEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 72)}px`;
  }, [question]);

  // Dismiss: outside pointer, Escape, reader scroll. Scrolling inside the
  // panel itself is allowed.
  useEffect(() => {
    const inside = (t) => !!(t && (pillRef.current?.contains(t) || panelRef.current?.contains(t)));
    const onDown = (e) => { if (!inside(e.target)) onClose(); };
    const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); onClose(); } };
    const onScroll = (e) => { if (!inside(e.target)) onClose(); };
    document.addEventListener('pointerdown', onDown, true);
    document.addEventListener('keydown', onKey, true);
    document.addEventListener('scroll', onScroll, true);
    return () => {
      document.removeEventListener('pointerdown', onDown, true);
      document.removeEventListener('keydown', onKey, true);
      document.removeEventListener('scroll', onScroll, true);
    };
  }, [onClose]);

  // Cancel any in-flight request when the overlay goes away.
  useEffect(() => () => {
    abortRef.current?.abort();
    clearTimeout(copyTimerRef.current);
  }, []);

  const send = useCallback(async (text) => {
    const q = text.trim();
    if (!q || q.length > MAX_QUESTION_CHARS) return;
    abortRef.current?.abort();
    const ctl = new AbortController();
    abortRef.current = ctl;
    setAsked(q);
    setAnswer('');
    setErrorCopy('');
    setCopied(false);
    setStatus('loading');
    try {
      const reply = await askVerse({
        userId, question: q, verseContext: { reference, text: verseText }, signal: ctl.signal,
      });
      if (ctl.signal.aborted) return;
      setAnswer(reply);
      setStatus('done');
    } catch (err) {
      if (ctl.signal.aborted || err?.name === 'AbortError') return;
      setErrorCopy(verseAskErrorCopy(err));
      setStatus('error');
    }
  }, [userId, reference, verseText]);

  const onInputKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent?.isComposing) {
      e.preventDefault();
      if (status !== 'loading') send(question);
    }
  };

  const copyAnswer = async () => {
    try {
      await navigator.clipboard.writeText(answer);
      setCopied(true);
      clearTimeout(copyTimerRef.current);
      copyTimerRef.current = setTimeout(() => setCopied(false), 1600);
    } catch {
      setErrorCopy("Couldn't copy that. Select the text and copy it instead.");
      setStatus('error');
    }
  };

  const trimmed = question.trim();
  const canSend = trimmed.length > 0 && trimmed.length <= MAX_QUESTION_CHARS && status !== 'loading';
  const motion = reduced ? ' va-reduced' : '';
  const hidden = geo ? undefined : 'hidden';
  const style = (top) => ({ left: geo?.left ?? 0, width: geo?.width ?? 0, top: top ?? 0, visibility: hidden });

  return createPortal(
    <div className="va-layer" data-verse={verseNum}>
      <div
        ref={pillRef}
        role="dialog"
        aria-modal="false"
        aria-label={`Ask AI about ${reference}`}
        className={`va-glass va-pill${motion}`}
        style={style(geo?.pillTop)}
      >
        <span className="va-pill-icon va-gold" aria-hidden="true"><SparkleIcon /></span>
        <textarea
          ref={inputRef}
          className="va-input"
          rows={1}
          value={question}
          maxLength={MAX_QUESTION_CHARS}
          placeholder="Ask about this verse"
          aria-label={`Question about ${reference}`}
          onChange={(e) => setQuestion(e.target.value)}
          onKeyDown={onInputKeyDown}
        />
        {trimmed.length >= COUNTER_FROM && (
          <span className={`va-counter${trimmed.length >= MAX_QUESTION_CHARS ? ' va-counter-limit' : ''}`} aria-live="polite">
            {MAX_QUESTION_CHARS - trimmed.length}
          </span>
        )}
        <button
          type="button"
          className="va-send"
          aria-label="Send question"
          aria-disabled={!canSend}
          onClick={() => { if (canSend) send(question); }}
        >
          <span className="va-send-circle">
            {status === 'loading' ? <Spin size="small" /> : <ArrowUpOutlined aria-hidden="true" />}
          </span>
        </button>
      </div>

      {showPanel && (
        <div
          ref={panelRef}
          className={`va-glass va-panel${motion}`}
          style={{ ...style(geo?.panelTop), maxHeight: geo?.panelMaxH }}
          aria-busy={status === 'loading'}
        >
          <div className="va-panel-head">
            <span className="va-label">Ask AI</span>
            <span className="va-ref">{reference}</span>
            <button type="button" className="va-close" aria-label="Close Ask AI" onClick={onClose}>
              <CloseOutlined aria-hidden="true" />
            </button>
          </div>
          <div className="va-asked">{asked}</div>
          {status === 'loading' && (
            <div className="va-loading" role="status">
              <Spin size="small" /> <span>Thinking</span>
            </div>
          )}
          {status === 'done' && (
            <div className="va-answer-wrap" aria-live="polite">
              <div className={`va-answer${reduced ? ' va-answer-reduced' : ''}`}>{answer}</div>
            </div>
          )}
          {status === 'error' && (
            <div className="va-error" role="alert">
              <WarningOutlined className="va-error-icon" aria-hidden="true" />
              <span>{errorCopy}</span>
              <button type="button" className="va-text-btn" onClick={() => send(asked || question)}>Try again</button>
            </div>
          )}
          {status === 'done' && (
            <div className="va-foot">
              <button type="button" className="va-text-btn" aria-label="Copy answer" onClick={copyAnswer}>
                {copied ? <><CheckOutlined aria-hidden="true" /> Copied</> : 'Copy'}
              </button>
              <span className="va-sr" aria-live="polite">{copied ? 'Answer copied' : ''}</span>
            </div>
          )}
        </div>
      )}
    </div>,
    document.body,
  );
}
