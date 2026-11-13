// Per-verse "Ask AI" (task 20261112-verse-ask-ai). Pure helpers plus the one
// network call. The call goes through the EXISTING Ask AI socket
// (/ask-ai/ws/{user_id}), sending the usual {content} frame with an extra
// verse_context. The server answers with one ephemeral frame (nothing saved),
// so there is no chat id and no history refresh. Mirrors the iOS placement
// function (placeVerseAskOverlay) so both platforms test the same rules.
import { WS_BASE } from '../config.js';

export const MAX_QUESTION_CHARS = 500;
export const COUNTER_FROM = 450;
export const VIEWPORT_MARGIN = 8;
export const OVERLAY_GAP = 6;
export const PILL_MAX_WIDTH = 520;
const PANEL_MIN_H = 120;
const FLIP_BELOW_SPACE = 160;
const PANEL_VIEWPORT_FRACTION = 0.45;
const REPLY_TIMEOUT_MS = 60_000;

// Pure placement. Never reads the DOM. All values are viewport (fixed) px.
// verseRect: {top,bottom}; viewport: {height}; keyboardTop: number|null.
// The pill sits right above the verse and is clamped on screen (it then
// overlays the verse rather than pushing anything). The panel opens below the
// pill, or above it when there is under 160px below.
export function placeVerseAskOverlay({ verseRect, viewport, keyboardTop = null, pillH, panelH }) {
  const topLimit = VIEWPORT_MARGIN;
  const bottomLimit = (keyboardTop == null ? viewport.height : Math.min(keyboardTop, viewport.height)) - VIEWPORT_MARGIN;
  let pillTop = verseRect.top - OVERLAY_GAP - pillH;
  pillTop = Math.min(pillTop, bottomLimit - pillH);
  pillTop = Math.max(pillTop, topLimit);

  const cap = Math.max(PANEL_MIN_H, Math.floor(viewport.height * PANEL_VIEWPORT_FRACTION));
  const belowTop = pillTop + pillH + OVERLAY_GAP;
  const spaceBelow = bottomLimit - belowTop;
  const spaceAbove = pillTop - OVERLAY_GAP - topLimit;

  const flipped = spaceBelow < FLIP_BELOW_SPACE && spaceAbove > spaceBelow && spaceAbove >= PANEL_MIN_H;
  if (flipped) {
    const panelMaxH = Math.min(cap, spaceAbove);
    const h = Math.min(panelH, panelMaxH);
    return { pillTop, panelTop: pillTop - OVERLAY_GAP - h, panelMaxH, flipped: true };
  }
  const panelMaxH = Math.max(PANEL_MIN_H, Math.min(cap, spaceBelow));
  return { pillTop, panelTop: belowTop, panelMaxH, flipped: false };
}

// Horizontal placement: aligned to the verse column, at most 520 wide, kept
// inside the viewport margin.
export function placeVerseAskColumn({ columnRect, viewportWidth }) {
  const width = Math.max(0, Math.min(columnRect.width, PILL_MAX_WIDTH, viewportWidth - VIEWPORT_MARGIN * 2));
  const left = Math.max(VIEWPORT_MARGIN, Math.min(columnRect.left, viewportWidth - width - VIEWPORT_MARGIN));
  return { left, width };
}

// Read reference + plain text from a rendered .verse-span (drops the number).
export function verseContextFromSpan(span, book, chapter) {
  const vNum = parseInt(String(span.id || '').replace(/^vs/, ''), 10);
  const clone = span.cloneNode(true);
  clone.querySelectorAll('sup').forEach((n) => n.remove());
  const text = (clone.textContent || '').replace(/\s+/g, ' ').trim();
  return { verseNum: vNum, reference: `${book} ${chapter}:${vNum}`, text };
}

export class VerseAskError extends Error {
  // kind: 'offline' | 'network' | 'server' | 'timeout'
  constructor(kind, message) {
    super(message || kind);
    this.name = 'VerseAskError';
    this.kind = kind;
  }
}

const COPY_GENERIC = "Couldn't reach Ask AI just now. Try again in a moment.";
const COPY_OFFLINE = "You're offline. Reconnect and try again.";
const COPY_LIMIT = "You've asked a lot today. Try again later.";

// Warm, non-technical copy. Server error text is already user-safe (backend
// step) so it is shown as given, except rate limiting which gets the spec copy.
export function verseAskErrorCopy(err) {
  if (!err) return COPY_GENERIC;
  if (err.kind === 'offline') return COPY_OFFLINE;
  if (err.kind === 'server' && err.message) {
    if (/too many|slow down|rate/i.test(err.message)) return COPY_LIMIT;
    return err.message;
  }
  return COPY_GENERIC;
}

// One-shot ask. Resolves with the reply text; rejects VerseAskError (or an
// AbortError when `signal` aborts). The reply is plain text: render it as a
// text node only, never HTML.
export function askVerse({ userId, question, verseContext, signal }) {
  return new Promise((resolve, reject) => {
    if (typeof navigator !== 'undefined' && navigator.onLine === false) {
      reject(new VerseAskError('offline'));
      return;
    }
    if (signal?.aborted) { reject(new DOMException('Aborted', 'AbortError')); return; }
    let settled = false;
    let ws;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      try { ws?.close(); } catch { /* already closed */ }
      fn(value);
    };
    const onAbort = () => finish(reject, new DOMException('Aborted', 'AbortError'));
    const timer = setTimeout(() => finish(reject, new VerseAskError('timeout')), REPLY_TIMEOUT_MS);
    signal?.addEventListener('abort', onAbort);
    try {
      ws = new WebSocket(`${WS_BASE}/ask-ai/ws/${userId}`);
    } catch {
      finish(reject, new VerseAskError('network'));
      return;
    }
    ws.onopen = () => ws.send(JSON.stringify({ content: question, verse_context: verseContext }));
    ws.onmessage = (e) => {
      let data;
      try { data = JSON.parse(e.data); } catch { finish(reject, new VerseAskError('network')); return; }
      if (data.role === 'error') finish(reject, new VerseAskError('server', data.content));
      else if (typeof data.content === 'string' && data.content.trim()) finish(resolve, data.content);
      else finish(reject, new VerseAskError('network'));
    };
    ws.onerror = () => finish(reject, new VerseAskError('network'));
    ws.onclose = () => finish(reject, new VerseAskError('network'));
  });
}
