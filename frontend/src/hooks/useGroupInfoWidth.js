import { useState, useEffect, useRef, useCallback } from 'react';

// Shared, user-resizable width for the Group Info side panel and every
// subpage inside it (task 20261010-group-info-round2). One numeric width,
// persisted in localStorage (every access in try/catch; nothing else stored).

export const GROUP_INFO_WIDTH_KEY = 'fs.groupInfoWidth';
export const GROUP_INFO_MIN = 320;
export const GROUP_INFO_MAX = 720;
export const GROUP_INFO_GUTTER = 64;   // always leave this much of the host visible
export const GROUP_INFO_STEP = 16;
export const GROUP_INFO_STEP_LARGE = 64;

export function maxGroupInfoWidth(hostWidth) {
  const hostMax = Number.isFinite(hostWidth) && hostWidth > 0 ? hostWidth - GROUP_INFO_GUTTER : GROUP_INFO_MAX;
  return Math.max(GROUP_INFO_MIN, Math.min(GROUP_INFO_MAX, hostMax));
}

export function clampGroupInfoWidth(w, hostWidth) {
  const max = maxGroupInfoWidth(hostWidth);
  const n = Number.isFinite(w) ? w : GROUP_INFO_MIN;
  return Math.round(Math.min(max, Math.max(GROUP_INFO_MIN, n)));
}

function readStored() {
  try {
    const raw = window.localStorage.getItem(GROUP_INFO_WIDTH_KEY);
    const n = raw == null ? NaN : Number(raw);
    return Number.isFinite(n) ? n : GROUP_INFO_MIN;
  } catch (e) { return GROUP_INFO_MIN; }
}
function writeStored(n) {
  try { window.localStorage.setItem(GROUP_INFO_WIDTH_KEY, String(n)); } catch (e) { /* storage unavailable: width just won't persist */ }
}

// panelRef: the panel root; its offsetParent / parentElement is the host whose width bounds the panel.
export function useGroupInfoWidth(panelRef, enabled = true) {
  const [raw, setRaw] = useState(readStored);
  const [hostWidth, setHostWidth] = useState(() => (typeof window !== 'undefined' ? window.innerWidth : 0));
  const [dragging, setDragging] = useState(false);
  const drag = useRef(null);

  const measureHost = useCallback(() => {
    const host = panelRef.current?.parentElement;
    const w = host?.clientWidth || window.innerWidth;
    setHostWidth(w);
  }, [panelRef]);

  useEffect(() => {
    if (!enabled) return undefined;
    measureHost();
    window.addEventListener('resize', measureHost);
    return () => window.removeEventListener('resize', measureHost);
  }, [enabled, measureHost]);

  const width = clampGroupInfoWidth(raw, hostWidth);
  const maxWidth = maxGroupInfoWidth(hostWidth);

  const commit = useCallback((next, persist = true) => {
    const clamped = clampGroupInfoWidth(next, hostWidth);
    setRaw(clamped);
    if (persist) writeStored(clamped);
  }, [hostWidth]);

  const onPointerDown = (e) => {
    if (e.button != null && e.button !== 0) return;
    e.preventDefault();
    try { e.currentTarget.setPointerCapture?.(e.pointerId); } catch (err) { /* synthetic pointer */ }
    measureHost();
    drag.current = { startX: e.clientX, startW: width, last: width };
    setDragging(true);
  };
  const onPointerMove = (e) => {
    if (!drag.current) return;
    // The panel is anchored right; dragging left widens it.
    const next = clampGroupInfoWidth(drag.current.startW + (drag.current.startX - e.clientX), hostWidth);
    drag.current.last = next;
    setRaw(next);
  };
  const endDrag = (e) => {
    if (!drag.current) return;
    try { e.currentTarget.releasePointerCapture?.(e.pointerId); } catch (err) { /* ignore */ }
    writeStored(drag.current.last);
    drag.current = null;
    setDragging(false);
  };
  const onKeyDown = (e) => {
    const step = e.shiftKey ? GROUP_INFO_STEP_LARGE : GROUP_INFO_STEP;
    let next = null;
    if (e.key === 'ArrowLeft') next = width + step;      // handle sits on the left edge: left = wider
    else if (e.key === 'ArrowRight') next = width - step;
    else if (e.key === 'Home') next = GROUP_INFO_MIN;
    else if (e.key === 'End') next = maxWidth;
    if (next == null) return;
    e.preventDefault();
    commit(next);
  };

  const handleProps = {
    role: 'separator',
    'aria-orientation': 'vertical',
    'aria-label': 'Resize group info',
    tabIndex: 0,
    'aria-valuenow': width,
    'aria-valuemin': GROUP_INFO_MIN,
    'aria-valuemax': maxWidth,
    onPointerDown, onPointerMove, onPointerUp: endDrag, onPointerCancel: endDrag, onKeyDown,
  };
  return { width, dragging, handleProps };
}
