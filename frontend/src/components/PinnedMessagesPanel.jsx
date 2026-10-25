import React, { useEffect, useLayoutEffect, useRef, useState, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { PushpinOutlined, PushpinFilled } from '@ant-design/icons';
import { Avatar, Spin } from 'antd';
import { pinPreview, pinnedByLabel, PIN_LIST_ERROR } from '../lib/pins.js';

// Task 20261012-message-pins. The Pinned list, opened from the pin icon in the
// chat header. Desktop: popover anchored under the button. <= 640px: bottom
// sheet over a scrim (CSS). role="dialog", focus moves in on open and returns
// to the button on close, Tab is trapped, Esc / scrim / outside press closes.
// Rows jump to the message; the trailing button unpins (optimistic, no confirm).

function whenLabel(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return '';
  const sameDay = d.toDateString() === new Date().toDateString();
  return sameDay
    ? d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    : d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

export function PinnedMessagesButton({ count, open, onClick, buttonRef }) {
  const label = count > 0 ? `Pinned messages, ${count}` : 'Pinned messages';
  return (
    <button
      ref={buttonRef}
      type="button"
      className="pins-header-btn"
      aria-label={label}
      aria-haspopup="dialog"
      aria-expanded={open}
      onClick={onClick}
    >
      <PushpinOutlined aria-hidden="true" />
      {count > 0 && <span className="pins-badge" aria-hidden="true">{count > 99 ? '99+' : count}</span>}
    </button>
  );
}

// The list body (loading / error / empty / rows / Show more), shared by the
// anchored DM popover below and the group submenu (GroupInfoRow). `spinner`
// swaps the skeleton rows for a plain spinner (design-spec section 5).
export function PinnedListBody({ list, viewerId, onJump, onUnpin, onLoadMore, onRetry, spinner = false }) {
  const { pins, status, hasMore, moreLoading } = list;
  const loading = status === 'loading' && pins.length === 0;
  const errored = status === 'error' && pins.length === 0;
  const empty = status === 'ready' && pins.length === 0;
  return (
    <>
      {loading && (spinner ? (
        <div className="pins-state" role="status" aria-label="Loading pinned messages"><Spin /></div>
      ) : (
        <div className="pins-skeletons" aria-hidden="true">
          <div className="pins-skeleton" /><div className="pins-skeleton" /><div className="pins-skeleton" />
        </div>
      ))}
      {errored && (
        <div className="pins-state">
          <p>{list.error || PIN_LIST_ERROR}</p>
          <button type="button" className="pins-text-btn" onClick={onRetry}>Try again</button>
        </div>
      )}
      {empty && (
        <div className="pins-state">
          <PushpinOutlined aria-hidden="true" className="pins-empty-glyph" />
          <p>No pinned messages yet.</p>
          <p className="pins-hint">Use a message&apos;s menu to pin it.</p>
        </div>
      )}
      {pins.length > 0 && (
        <ul className="pins-rows">
          {pins.map((p) => {
            const who = p.message.from || 'Someone';
            return (
              <li key={p.messageId} className="pins-row">
                <button type="button" className="pins-row-main" onClick={() => onJump(p)}>
                  <Avatar size={24} style={{ background: 'rgba(255,198,26,0.12)', color: 'var(--gold)', flexShrink: 0 }}>
                    {who[0].toUpperCase()}
                  </Avatar>
                  <span className="pins-row-text">
                    <span className="pins-row-top">
                      <span className="pins-row-name">{who}</span>
                      <span className="pins-row-time">{whenLabel(p.message.timestamp)}</span>
                    </span>
                    <span className="pins-row-preview">{pinPreview(p)}</span>
                    <span className="pins-row-by">{pinnedByLabel(p, viewerId)}</span>
                  </span>
                </button>
                <button
                  type="button"
                  className="pins-unpin-btn"
                  aria-label={`Unpin message from ${who}`}
                  onClick={() => onUnpin(p)}
                >
                  <PushpinFilled aria-hidden="true" />
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {pins.length > 0 && hasMore && (
        <button type="button" className="pins-text-btn pins-more" disabled={moreLoading} onClick={onLoadMore}>
          {moreLoading ? 'Loading…' : 'Show more'}
        </button>
      )}
    </>
  );
}

export default function PinnedMessagesPanel({
  anchorRef, list, viewerId, onClose, onJump, onUnpin, onLoadMore, onRetry,
}) {
  const panelRef = useRef(null);
  const [pos, setPos] = useState(null);

  const reposition = useCallback(() => {
    const r = anchorRef.current?.getBoundingClientRect();
    if (!r) return;
    setPos({ top: r.bottom + 6, right: Math.max(8, window.innerWidth - r.right) });
  }, [anchorRef]);

  useLayoutEffect(() => {
    reposition();
    window.addEventListener('resize', reposition);
    return () => window.removeEventListener('resize', reposition);
  }, [reposition]);

  useEffect(() => {
    const el = panelRef.current;
    el?.querySelector('button, [tabindex]')?.focus?.({ preventScroll: true });
    if (!el?.contains(document.activeElement)) el?.focus?.({ preventScroll: true });
  }, []);

  useEffect(() => {
    const onDown = (e) => {
      if (panelRef.current?.contains(e.target) || anchorRef.current?.contains(e.target)) return;
      onClose();
    };
    document.addEventListener('pointerdown', onDown, true);
    return () => document.removeEventListener('pointerdown', onDown, true);
  }, [onClose, anchorRef]);

  const onKeyDown = (e) => {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); onClose(); return; }
    if (e.key !== 'Tab') return;
    const items = Array.from(panelRef.current?.querySelectorAll('button:not([disabled])') || []);
    if (!items.length) { e.preventDefault(); return; }
    const first = items[0];
    const last = items[items.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  };

  return createPortal(
    <>
      <div className="pins-scrim" aria-hidden="true" onClick={onClose} />
      {/* eslint-disable-next-line jsx-a11y/no-noninteractive-element-interactions */}
      <div
        ref={panelRef}
        role="dialog"
        aria-label="Pinned messages"
        tabIndex={-1}
        className="pins-panel"
        style={pos ? { top: pos.top, right: pos.right } : undefined}
        onKeyDown={onKeyDown}
      >
        <div className="pins-panel-head">
          <h2 className="pins-panel-title">Pinned</h2>
          <button type="button" className="pins-close-btn" onClick={onClose}>Done</button>
        </div>
        <div className="pins-panel-body">
          <PinnedListBody list={list} viewerId={viewerId} onJump={onJump} onUnpin={onUnpin} onLoadMore={onLoadMore} onRetry={onRetry} />
        </div>
      </div>
    </>,
    document.body,
  );
}
