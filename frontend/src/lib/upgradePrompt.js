// Task 20261002-free-plan-limits-ui: one detector + one tiny store for the
// "not available on the Free plan" upgrade modal. The server is authoritative:
// a blocked action comes back as HTTP 403 with a body of
// {resource, allowed:false, unlimited, used, limit, remaining[, paid_only]},
// either bare or nested under `detail`. Every blocked flow (notes, scheduled
// devotions, session create, session summary, Explorer publish) calls
// `blockedFromBody`/`blockedFromResponse` and, on a hit, `showUpgradePrompt`.
// Any other 403 (permission, note_chars) is not matched and keeps its own handling.

export const BLOCKED_RESOURCES = [
  'notes', 'agent_events', 'sessions', 'session_summaries', 'explorer_publish',
];

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);

// Returns {resource, paidOnly, used, limit} or null when this is not a plan block.
export function blockedFromBody(status, body) {
  if (status !== 403 || !body || typeof body !== 'object') return null;
  const b = body.detail && typeof body.detail === 'object' && !Array.isArray(body.detail) ? body.detail : body;
  if (typeof b.resource !== 'string' || b.allowed !== false) return null;
  if (!BLOCKED_RESOURCES.includes(b.resource)) return null;
  return { resource: b.resource, paidOnly: b.paid_only === true, used: num(b.used), limit: num(b.limit) };
}

// Reads the JSON body of a (non-ok) fetch Response once and runs the detector.
export async function blockedFromResponse(res) {
  if (!res || res.status !== 403) return null;
  let body = null;
  try { body = await res.json(); } catch { return null; }
  return blockedFromBody(res.status, body);
}

export const UPGRADE_TITLE = 'Not available on the Free plan';
export const UPGRADE_CTA = 'Subscribe to unlock it.';

const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

// Copy per resource; numbers come from the blocked body, never literals.
export function upgradeBody(info) {
  const limit = info?.limit;
  switch (info?.resource) {
    case 'notes':
      return limit != null ? `Free plan includes ${plural(limit, 'note')} per week.` : 'The Free plan has a weekly note limit.';
    case 'agent_events':
      return limit != null
        ? `The Free plan includes ${plural(limit, 'scheduled devotion')}. Subscribe for as many as you like.`
        : 'The Free plan has a scheduled devotion limit. Subscribe for as many as you like.';
    case 'sessions':
      return limit != null
        ? `Free plan members can host ${plural(limit, 'session')} at a time. Finish your current one, or subscribe to host more.`
        : 'Free plan members can host one session at a time. Finish your current one, or subscribe to host more.';
    case 'session_summaries':
      return 'Session summaries are for subscribers.';
    case 'explorer_publish':
      return 'Publishing a group to Explorer is for subscribers. Browsing and joining stay free.';
    default:
      return 'This is not available on the Free plan.';
  }
}

// ── Tiny store (single instance; the latest block replaces the content) ─────
let state = null; // {info, trigger}
const listeners = new Set();
const emit = () => listeners.forEach((l) => l());

export function showUpgradePrompt(info) {
  const trigger = typeof document !== 'undefined' ? document.activeElement : null;
  state = { info, trigger };
  emit();
}
export function dismissUpgradePrompt() { state = null; emit(); }
export function getUpgradePrompt() { return state; }
export function subscribeUpgradePrompt(fn) { listeners.add(fn); return () => listeners.delete(fn); }

// Convenience for flows: returns true (and shows the modal) when `res` is a plan block.
export async function handleBlockedResponse(res) {
  const info = await blockedFromResponse(res);
  if (!info) return false;
  showUpgradePrompt(info);
  return true;
}

export const prefersReducedMotion = () =>
  typeof window !== 'undefined' && !!window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches;

// Scroll to (and focus) the Account subscription section, waiting for it to mount.
export function scrollToSubscription(tries = 30) {
  const el = typeof document !== 'undefined' ? document.getElementById('subscription') : null;
  if (el) {
    el.scrollIntoView({ behavior: prefersReducedMotion() ? 'auto' : 'smooth', block: 'start' });
    try { el.focus({ preventScroll: true }); } catch { /* ignore */ }
    return;
  }
  if (tries > 0 && typeof requestAnimationFrame !== 'undefined') {
    requestAnimationFrame(() => scrollToSubscription(tries - 1));
  }
}
