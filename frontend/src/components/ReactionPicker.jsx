import React, { useState, useEffect, useLayoutEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import { emojiName } from '../lib/reactions.js';

// Task 20261011-desktop-chat-replies-reactions. Anchored emoji picker for a
// chat message: the server's quick row plus a "More" toggle that reveals the
// rest of the server allowlist (the client never hardcodes emoji; mirrors
// Shared/ReactionPicker.swift's quick row + full sheet).
//
// Accessibility: role="dialog" (non-modal) holding plain buttons with
// aria-pressed for the viewer's current reactions; one roving list
// (quick..., More, more...) driven by arrows (left/right step, up/down move a
// row in the grid, Home/End); Escape closes and returns focus to the element
// that opened it; Tab closes; targets are at least 44 px; reduced motion is a
// plain fade (CSS).

const GAP = 6;
const MARGIN = 8;
const COLS = 6;

function prefersReducedMotion() {
  return typeof window !== 'undefined' && !!window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

export default function ReactionPicker({ anchor, align, quick, more, selected, onPick, onClose }) {
  const ref = useRef(null);
  const [pos, setPos] = useState(null);
  const [showMore, setShowMore] = useState(false);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || !anchor) return;
    const w = el.offsetWidth || 260;
    const h = el.offsetHeight || 56;
    let left = align === 'right' ? anchor.right - w : anchor.left;
    left = Math.max(MARGIN, Math.min(left, window.innerWidth - w - MARGIN));
    let top = anchor.top - h - GAP;
    if (top < MARGIN) top = Math.min(anchor.bottom + GAP, window.innerHeight - h - MARGIN);
    setPos({ top: Math.max(MARGIN, top), left });
  }, [anchor, align, showMore, quick.length, more.length]);

  useEffect(() => {
    ref.current?.querySelector('button')?.focus({ preventScroll: true });
  }, []);

  useEffect(() => {
    const onDown = (e) => { if (!ref.current?.contains(e.target)) onClose(false); };
    const onDismiss = () => onClose(false);
    const onScroll = (e) => { if (!ref.current?.contains(e.target)) onClose(false); };
    document.addEventListener('pointerdown', onDown, true);
    window.addEventListener('resize', onDismiss);
    window.addEventListener('blur', onDismiss);
    document.addEventListener('scroll', onScroll, true);
    return () => {
      document.removeEventListener('pointerdown', onDown, true);
      window.removeEventListener('resize', onDismiss);
      window.removeEventListener('blur', onDismiss);
      document.removeEventListener('scroll', onScroll, true);
    };
  }, [onClose]);

  const onKeyDown = (e) => {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); onClose(true); return; }
    if (e.key === 'Tab') { onClose(true); return; }
    const items = Array.from(ref.current?.querySelectorAll('button') || []);
    if (!items.length) return;
    const idx = items.indexOf(document.activeElement);
    const at = (i) => items[Math.min(items.length - 1, i)];
    let next = null;
    if (e.key === 'ArrowRight') next = items[(idx + 1) % items.length];
    else if (e.key === 'ArrowLeft') next = items[(idx - 1 + items.length) % items.length];
    else if (showMore && e.key === 'ArrowDown') {
      const gridStart = quick.length + 1;
      next = idx < gridStart ? items[gridStart] : at(idx + COLS);
    } else if (showMore && e.key === 'ArrowUp') {
      const gridStart = quick.length + 1;
      if (idx >= gridStart) next = idx - COLS >= gridStart ? items[idx - COLS] : items[quick.length];
    } else if (e.key === 'Home') next = items[0];
    else if (e.key === 'End') next = items[items.length - 1];
    if (next) { e.preventDefault(); next.focus({ preventScroll: true }); }
  };

  const emojiBtn = (e) => {
    const on = selected.has(e);
    return (
      <button
        key={e}
        type="button"
        className={`msg-reaction-pick${on ? ' msg-reaction-pick-on' : ''}`}
        aria-label={emojiName(e)}
        aria-pressed={on}
        onClick={() => onPick(e)}
      >
        <span aria-hidden="true">{e}</span>
      </button>
    );
  };

  return createPortal(
    // eslint-disable-next-line jsx-a11y/no-noninteractive-element-interactions
    <div
      ref={ref}
      role="dialog"
      aria-label="Add reaction"
      className={`msg-reaction-picker${prefersReducedMotion() ? ' msg-reaction-picker-reduced' : ''}`}
      style={{ top: pos ? pos.top : 0, left: pos ? pos.left : 0, visibility: pos ? 'visible' : 'hidden', transformOrigin: align === 'right' ? 'bottom right' : 'bottom left' }}
      onKeyDown={onKeyDown}
    >
      <div className="msg-reaction-quick">
        {quick.map(emojiBtn)}
        {more.length > 0 && (
          <button
            type="button"
            className="msg-reaction-pick msg-reaction-more"
            aria-label="More reactions"
            aria-expanded={showMore}
            onClick={() => setShowMore((v) => !v)}
          >
            <span aria-hidden="true">{showMore ? '−' : '+'}</span>
          </button>
        )}
      </div>
      {showMore && <div className="msg-reaction-grid">{more.map(emojiBtn)}</div>}
    </div>,
    document.body,
  );
}

// Small helper so callers don't repeat the anchor rect math.
export function rectOf(el) {
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
}
