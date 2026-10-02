import React, { useState, useEffect, useLayoutEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { MoreOutlined } from '@ant-design/icons';

// Task 20261001-message-threads step 8 (design Alternative A, provisional).
// Anchored message action menu for chat bubbles. Opens from:
//   - right-click / the ContextMenu key (native contextmenu event),
//   - a 500 ms touch hold (cancelled by movement past 10 px, scroll, or lift),
//   - the focusable "More actions" button on the bubble (the keyboard and
//     screen-reader alternative to press-and-hold).
// It never opens over an active text selection or on a link, so selecting and
// following links keep working. Items are plain data: { key, label, icon,
// destructive, onSelect }. A bubble with no actions renders no trigger.
//
// Accessibility: the trigger has aria-haspopup="menu" and aria-expanded; the
// menu is role="menu" with role="menuitem" buttons, arrow/Home/End roving
// focus, Escape closes and returns focus to the trigger, Tab closes. Touch
// targets are at least 44 px. Reduced motion: the reveal is a plain fade.

const HOLD_MS = 500;
const MOVE_CANCEL_PX = 10;
const MENU_GAP = 6;
const VIEWPORT_MARGIN = 8;

function prefersReducedMotion() {
  return typeof window !== 'undefined' && !!window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

function hasActiveSelection() {
  const sel = typeof window !== 'undefined' && window.getSelection ? window.getSelection() : null;
  return !!sel && !sel.isCollapsed && String(sel).trim().length > 0;
}

function MenuPopover({ anchor, align, actions, onClose, onPick }) {
  const menuRef = useRef(null);
  const [pos, setPos] = useState(null);

  useLayoutEffect(() => {
    const el = menuRef.current;
    if (!el || !anchor) return;
    const w = el.offsetWidth || 180;
    const h = el.offsetHeight || 120;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    let left = align === 'right' ? anchor.right - w : anchor.left;
    left = Math.max(VIEWPORT_MARGIN, Math.min(left, vw - w - VIEWPORT_MARGIN));
    let top = anchor.bottom + MENU_GAP;
    if (top + h > vh - VIEWPORT_MARGIN) top = Math.max(VIEWPORT_MARGIN, anchor.top - h - MENU_GAP);
    setPos({ top, left });
  }, [anchor, align, actions.length]);

  useEffect(() => {
    const first = menuRef.current?.querySelector('[role="menuitem"]');
    first?.focus({ preventScroll: true });
  }, []);

  useEffect(() => {
    const onDown = (e) => { if (!menuRef.current?.contains(e.target)) onClose(false); };
    const onDismiss = () => onClose(false);
    document.addEventListener('pointerdown', onDown, true);
    window.addEventListener('resize', onDismiss);
    window.addEventListener('blur', onDismiss);
    document.addEventListener('scroll', onDismiss, true);
    return () => {
      document.removeEventListener('pointerdown', onDown, true);
      window.removeEventListener('resize', onDismiss);
      window.removeEventListener('blur', onDismiss);
      document.removeEventListener('scroll', onDismiss, true);
    };
  }, [onClose]);

  const onKeyDown = (e) => {
    const items = Array.from(menuRef.current?.querySelectorAll('[role="menuitem"]') || []);
    const idx = items.indexOf(document.activeElement);
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); onClose(true); return; }
    if (e.key === 'Tab') { onClose(true); return; }
    if (!items.length) return;
    let next = null;
    if (e.key === 'ArrowDown') next = items[(idx + 1 + items.length) % items.length];
    else if (e.key === 'ArrowUp') next = items[(idx - 1 + items.length) % items.length];
    else if (e.key === 'Home') next = items[0];
    else if (e.key === 'End') next = items[items.length - 1];
    if (next) { e.preventDefault(); next.focus({ preventScroll: true }); }
  };

  return createPortal(
    // eslint-disable-next-line jsx-a11y/no-noninteractive-element-interactions
    <div
      ref={menuRef}
      role="menu"
      aria-label="Message actions"
      className={`msg-action-menu${prefersReducedMotion() ? ' msg-action-menu-reduced' : ''}`}
      style={{ top: pos ? pos.top : 0, left: pos ? pos.left : 0, visibility: pos ? 'visible' : 'hidden', transformOrigin: align === 'right' ? 'top right' : 'top left' }}
      onKeyDown={onKeyDown}
    >
      {actions.map((a) => (
        <button
          key={a.key}
          type="button"
          role="menuitem"
          tabIndex={-1}
          className={`msg-action-item${a.destructive ? ' msg-action-item-destructive' : ''}`}
          onClick={() => onPick(a)}
        >
          {a.icon ? <span className="msg-action-icon" aria-hidden="true">{a.icon}</span> : null}
          <span>{a.label}</span>
        </button>
      ))}
    </div>,
    document.body,
  );
}

// A chat bubble that can open the action menu. Renders the same element the
// plain bubble was (a div carrying `className`), so layout is unchanged.
export default function ActionableBubble({ actions, mine, className, children, ...rest }) {
  const bubbleRef = useRef(null);
  const triggerRef = useRef(null);
  const holdRef = useRef({ timer: null, x: 0, y: 0 });
  const suppressClickRef = useRef(false);
  const [anchor, setAnchor] = useState(null);
  const hasActions = Array.isArray(actions) && actions.length > 0;
  const open = !!anchor;

  const openMenu = useCallback(() => {
    const el = bubbleRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    setAnchor({ top: r.top, bottom: r.bottom, left: r.left, right: r.right });
  }, []);

  const close = useCallback((restoreFocus) => {
    setAnchor(null);
    if (restoreFocus) triggerRef.current?.focus({ preventScroll: true });
  }, []);

  const cancelHold = useCallback(() => {
    clearTimeout(holdRef.current.timer);
    holdRef.current.timer = null;
  }, []);
  useEffect(() => cancelHold, [cancelHold]);

  if (!hasActions) {
    return <div ref={bubbleRef} className={className} {...rest}>{children}</div>;
  }

  const onPointerDown = (e) => {
    if (e.pointerType === 'mouse' || e.target.closest?.('a[href], .msg-more-btn')) return;
    holdRef.current.x = e.clientX;
    holdRef.current.y = e.clientY;
    cancelHold();
    holdRef.current.timer = setTimeout(() => {
      holdRef.current.timer = null;
      if (hasActiveSelection()) return;
      suppressClickRef.current = true;
      openMenu();
    }, HOLD_MS);
  };
  const onPointerMove = (e) => {
    if (!holdRef.current.timer) return;
    if (Math.hypot(e.clientX - holdRef.current.x, e.clientY - holdRef.current.y) > MOVE_CANCEL_PX) cancelHold();
  };
  const onContextMenu = (e) => {
    if (e.target.closest?.('a[href]') || hasActiveSelection()) return;
    e.preventDefault();
    cancelHold();
    openMenu();
  };
  const onClickCapture = (e) => {
    if (suppressClickRef.current) {
      suppressClickRef.current = false;
      e.preventDefault();
      e.stopPropagation();
    }
  };
  const onTriggerKeyDown = (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); openMenu(); }
  };

  return (
    <div
      ref={bubbleRef}
      className={`${className} msg-bubble-actionable${open ? ' msg-bubble-menu-open' : ''}`}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={cancelHold}
      onPointerCancel={cancelHold}
      onPointerLeave={cancelHold}
      onContextMenu={onContextMenu}
      onClickCapture={onClickCapture}
      {...rest}
    >
      {children}
      <button
        ref={triggerRef}
        type="button"
        className="msg-more-btn"
        aria-label="More actions"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => (open ? close(true) : openMenu())}
        onKeyDown={onTriggerKeyDown}
      >
        <MoreOutlined aria-hidden="true" />
      </button>
      {open && (
        <MenuPopover
          anchor={anchor}
          align={mine ? 'right' : 'left'}
          actions={actions}
          onClose={close}
          onPick={(a) => { close(true); a.onSelect(); }}
        />
      )}
    </div>
  );
}
