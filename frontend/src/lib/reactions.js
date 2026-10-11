// Task 20261011-desktop-chat-replies-reactions. Message reactions client:
// mirrors FellowScript/Services/NetworkService+Reactions.swift (errors, copy)
// and Shared/ReactionPicker.swift (pure list helpers, accessibility names).
// Throw-not-fabricate: any non-2xx, transport error or undecodable body throws
// a ReactionError; the caller rolls back its optimistic change and shows it.
import { API } from '../config.js';

export const REACTION_FALLBACK = "Couldn't update your reaction. Please try again.";

export class ReactionError extends Error {
  constructor(kind, message) {
    super(message);
    this.name = 'ReactionError';
    this.kind = kind; // unavailable | terms | limit | rate | failed
  }
}

// One summary row from the wire ({emoji, count, viewer_reacted}) or null.
export function parseSummary(raw) {
  if (!raw || typeof raw !== 'object') return null;
  if (typeof raw.emoji !== 'string' || !raw.emoji) return null;
  if (!Number.isInteger(raw.count) || raw.count < 0) return null;
  if (typeof raw.viewer_reacted !== 'boolean') return null;
  return { emoji: raw.emoji, count: raw.count, viewerReacted: raw.viewer_reacted };
}

// A message's `reactions` array -> normalised list, or undefined when the key
// is absent (flag off for the viewer: the payload omits it entirely).
export function parseReactions(raw) {
  if (!Array.isArray(raw)) return undefined;
  return raw.map(parseSummary).filter((r) => r && r.count > 0);
}

const sameEmoji = (a, b) => a.emoji === b;

// The list after the viewer toggles `emoji` (entry dropped at 0).
export function toggled(list, emoji) {
  const i = list.findIndex((r) => sameEmoji(r, emoji));
  if (i === -1) return [...list, { emoji, count: 1, viewerReacted: true }];
  const cur = list[i];
  if (cur.viewerReacted) {
    if (cur.count - 1 <= 0) return list.filter((_, k) => k !== i);
    return list.map((r, k) => (k === i ? { ...r, count: r.count - 1, viewerReacted: false } : r));
  }
  return list.map((r, k) => (k === i ? { ...r, count: r.count + 1, viewerReacted: true } : r));
}

// Replace / insert / remove (value null or count <= 0) one emoji's entry only.
// Used to apply the server result and to roll back one emoji after a failure.
export function setting(list, emoji, value) {
  const i = list.findIndex((r) => sameEmoji(r, emoji));
  if (value && value.count > 0) {
    if (i === -1) return [...list, value];
    return list.map((r, k) => (k === i ? value : r));
  }
  return i === -1 ? list : list.filter((_, k) => k !== i);
}

// Someone else's change (live frame): new count, viewer's own state kept.
export function updatingCount(list, emoji, count) {
  if (!(count > 0)) return setting(list, emoji, null);
  const existing = list.find((r) => sameEmoji(r, emoji));
  return setting(list, emoji, { emoji, count, viewerReacted: existing ? existing.viewerReacted : false });
}

const KNOWN = {
  '\u{1F44D}': 'Thumbs up', '\u{1F44E}': 'Thumbs down', '❤️': 'Heart', '\u{1F64F}': 'Praying hands',
  '\u{1F602}': 'Laughing', '\u{1F62E}': 'Surprised', '\u{1F622}': 'Crying', '\u{1F389}': 'Celebration',
  '\u{1F525}': 'Fire', '\u{1F44F}': 'Clapping', '\u{1F64C}': 'Raised hands', '\u{1F60A}': 'Smiling',
  '\u{1F914}': 'Thinking', '\u{1F4AF}': 'One hundred', '✝️': 'Cross', '\u{1F60D}': 'Heart eyes',
};

// Friendly name for screen readers; falls back to the emoji itself (never empty).
export function emojiName(emoji) {
  return KNOWN[emoji] || emoji;
}

// e.g. "Thumbs up, 3 reactions, you reacted"
export function chipLabel(r) {
  const noun = r.count === 1 ? '1 reaction' : `${r.count} reactions`;
  return r.viewerReacted ? `${emojiName(r.emoji)}, ${noun}, you reacted` : `${emojiName(r.emoji)}, ${noun}`;
}

async function send(userId, messageId, method, emoji) {
  let path = `${API}/message-reactions/${encodeURIComponent(userId)}/${encodeURIComponent(messageId)}`;
  const init = { method, credentials: 'include' };
  if (method === 'DELETE') path += `?emoji=${encodeURIComponent(emoji)}`;
  else {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify({ emoji });
  }
  let res;
  try {
    res = await fetch(path, init);
  } catch {
    throw new ReactionError('failed', 'Could not reach the server.');
  }
  if (!res.ok) {
    let code = null;
    try {
      const d = await res.json();
      if (d && d.detail && typeof d.detail === 'object') code = d.detail.code || null;
    } catch { /* keep null */ }
    if (res.status === 404) throw new ReactionError('unavailable', "That message can't be reacted to anymore.");
    if (res.status === 429) throw new ReactionError('rate', "You're reacting too quickly. Please wait a moment.");
    if (res.status === 403 && code === 'terms_reaccept_required') {
      throw new ReactionError('terms', 'Please review and accept the updated Terms to continue.');
    }
    if (res.status === 409) throw new ReactionError('limit', 'This message has reached its reaction limit.');
    throw new ReactionError('failed', REACTION_FALLBACK);
  }
  let body = null;
  try { body = await res.json(); } catch { /* handled below */ }
  const summary = parseSummary(body);
  if (!summary) throw new ReactionError('failed', REACTION_FALLBACK);
  return summary;
}

export const addReaction = (userId, messageId, emoji) => send(userId, messageId, 'POST', emoji);
export const removeReaction = (userId, messageId, emoji) => send(userId, messageId, 'DELETE', emoji);
