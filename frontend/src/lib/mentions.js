// Task 20261017-chat-mentions (web). Pure helpers for @mentions: wire parsing,
// rendering runs, composer trigger detection, member filtering and offset
// bookkeeping. No React, no network (except fetchMentionMembers), so every rule
// is unit-testable on its own.
//
// Offsets are UTF-16 code units, which is what JS string indices already are
// (contract.md section 1.4). Never use code points or grapheme counts here.
//
// A mention in client state is { userId, username, start, length } with the
// composer text containing the literal "@username" at [start, start+length).
// The wire form is { user_id, start, length } (outbound) and the same plus
// `username` (inbound). Anything that fails a range check is treated as "no
// mentions" and the text renders plain (never throws).
import { API } from '../config.js';

export const MENTION_FEATURE = 'chat_mentions';
export const MAX_MENTIONS = 10;

const isHigh = (c) => c >= 0xD800 && c <= 0xDBFF;
const isLow = (c) => c >= 0xDC00 && c <= 0xDFFF;
const WS = /\s/;
const WORD_CHAR = /[\p{L}\p{N}_]/u;

// True when [start, start+length) is a sane, ordered, non-overlapping set of
// ranges that begin with "@" and do not split a surrogate pair.
export function rangesAreValid(text, list) {
  if (typeof text !== 'string' || !Array.isArray(list) || list.length === 0) return false;
  let prevEnd = 0;
  for (const m of list) {
    if (!m || typeof m !== 'object') return false;
    const { start, length } = m;
    if (!Number.isInteger(start) || !Number.isInteger(length)) return false;
    if (start < 0 || length < 2 || start < prevEnd) return false;
    const end = start + length;
    if (end > text.length) return false;
    if (text.charAt(start) !== '@') return false;
    if (isHigh(text.charCodeAt(end - 1))) return false;
    prevEnd = end;
  }
  return true;
}

// Wire array (history row, live frame, ack, thread row) -> validated client
// mentions, or null (absent, null, [], malformed or out-of-bounds: all plain).
export function mentionsFromWire(raw, text) {
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const out = [];
  for (const e of raw) {
    if (!e || typeof e !== 'object' || typeof e.user_id !== 'string' || !e.user_id) return null;
    const m = { userId: e.user_id.toLowerCase(), start: e.start, length: e.length };
    if (typeof e.username === 'string' && e.username) m.username = e.username;
    out.push(m);
  }
  return rangesAreValid(text, out) ? out : null;
}

// `{ mentions }` or `{}` so callers can spread it next to the other fields.
export function mentionFields(src, text) {
  const mentions = mentionsFromWire(src && src.mentions, text);
  return mentions ? { mentions } : {};
}

// Outbound wire shape: exactly the three contract keys.
export function toWireMentions(mentions) {
  return mentions.map((m) => ({ user_id: m.userId, start: m.start, length: m.length }));
}

// Rendering runs: [{ type: 'text'|'mention', text }]. The mention run shows the
// current username when the server sent one (rename safe, contract 1.5), else
// the stored slice. Built sequentially, never by index mutation.
export function mentionSegments(text, mentions) {
  const plain = [{ type: 'text', text: typeof text === 'string' ? text : '' }];
  if (!rangesAreValid(text, mentions)) return plain;
  const out = [];
  let pos = 0;
  for (const m of mentions) {
    if (m.start > pos) out.push({ type: 'text', text: text.slice(pos, m.start) });
    out.push({ type: 'mention', text: m.username ? `@${m.username}` : text.slice(m.start, m.start + m.length) });
    pos = m.start + m.length;
  }
  if (pos < text.length) out.push({ type: 'text', text: text.slice(pos) });
  return out;
}

// Keeps only mentions whose slice still equals "@username", in order, without
// overlaps or repeated users, capped at MAX_MENTIONS. Never returns a range
// that was not verified against the text.
export function verifyMentions(text, mentions) {
  if (typeof text !== 'string' || !Array.isArray(mentions)) return [];
  const sorted = mentions.slice().sort((a, b) => a.start - b.start);
  const out = [];
  const seen = new Set();
  let prevEnd = 0;
  for (const m of sorted) {
    if (out.length >= MAX_MENTIONS) break;
    if (!m || typeof m.username !== 'string' || !m.username || typeof m.userId !== 'string') continue;
    if (!Number.isInteger(m.start) || m.start < prevEnd) continue;
    const token = `@${m.username}`;
    if (m.length !== token.length) continue;
    if (text.slice(m.start, m.start + m.length) !== token) continue;
    if (seen.has(m.userId)) continue;
    seen.add(m.userId);
    out.push(m);
    prevEnd = m.start + m.length;
  }
  return out;
}

// What the composer sends: trim first, shift the offsets by the leading trim,
// then verify. The returned text is the exact string the offsets measure.
export function prepareSend(text, mentions) {
  const trimmed = text.trim();
  const lead = text.length - text.trimStart().length;
  const shifted = (mentions || []).map((m) => ({ ...m, start: m.start - lead })).filter((m) => m.start >= 0);
  return { text: trimmed, mentions: verifyMentions(trimmed, shifted) };
}

// Editing: compare old and new composer text, find the single replaced region
// and keep the mentions that survive. Mentions before the edit stay, mentions
// after it shift by the length delta, mentions touched by it are dropped (the
// text stays as plain text). A word character typed directly against the end of
// a mention also drops it ("@Mat" + "x"). Survivors are re-verified.
export function applyEdit(oldText, newText, mentions) {
  if (!mentions || mentions.length === 0) return [];
  if (oldText === newText) return mentions;
  const oldLen = oldText.length;
  const newLen = newText.length;
  const max = Math.min(oldLen, newLen);
  let p = 0;
  while (p < max && oldText.charCodeAt(p) === newText.charCodeAt(p)) p++;
  if (p > 0 && isHigh(oldText.charCodeAt(p - 1))) p--;
  let s = 0;
  while (s < max - p && oldText.charCodeAt(oldLen - 1 - s) === newText.charCodeAt(newLen - 1 - s)) s++;
  while (s > 0 && isLow(oldText.charCodeAt(oldLen - s))) s--;
  const oldEnd = oldLen - s;
  const newEnd = newLen - s;
  const delta = newEnd - oldEnd;
  const inserted = newText.slice(p, newEnd);
  const kept = [];
  for (const m of mentions) {
    const end = m.start + m.length;
    if (end <= p) {
      if (end === p && inserted && WORD_CHAR.test(String.fromCodePoint(inserted.codePointAt(0)))) continue;
      kept.push(m);
    } else if (m.start >= oldEnd) {
      kept.push({ ...m, start: m.start + delta });
    }
  }
  return verifyMentions(newText, kept);
}

// Backspace / Delete that touches a mention removes the whole mention token in
// one step. Returns { text, mentions, caret } or null when no mention is
// involved (the browser handles the key normally).
export function deleteAcrossMentions(text, mentions, selStart, selEnd, key) {
  if (!mentions || mentions.length === 0) return null;
  let lo = Math.min(selStart, selEnd);
  let hi = Math.max(selStart, selEnd);
  if (lo === hi) {
    const c = lo;
    let hit = null;
    for (const m of mentions) {
      const end = m.start + m.length;
      if (key === 'Backspace') {
        if (c > m.start && c <= end) { hit = { lo: m.start, hi: end }; break; }
        if (c === end + 1 && WS.test(text.charAt(end))) { hit = { lo: m.start, hi: c }; break; }
      } else if (c >= m.start && c < end) {
        hit = { lo: m.start, hi: end };
        break;
      }
    }
    if (!hit) return null;
    ({ lo, hi } = hit);
  } else {
    let touched = false;
    let changed = true;
    while (changed) {
      changed = false;
      for (const m of mentions) {
        const end = m.start + m.length;
        if (m.start < hi && end > lo && (m.start < lo || end > hi)) {
          lo = Math.min(lo, m.start);
          hi = Math.max(hi, end);
          changed = true;
        }
        if (m.start < hi && end > lo) touched = true;
      }
    }
    if (!touched) return null;
  }
  const removed = hi - lo;
  const next = [];
  for (const m of mentions) {
    const end = m.start + m.length;
    if (end <= lo) next.push(m);
    else if (m.start >= hi) next.push({ ...m, start: m.start - removed });
  }
  return { text: text.slice(0, lo) + text.slice(hi), mentions: next, caret: lo };
}

// The "@query" token the caret is in: '@' at index 0 or after whitespace, no
// whitespace between it and the caret, not inside an already inserted mention.
// Returns { start, end, query } or null.
export function findTrigger(text, caret, mentions = []) {
  if (typeof text !== 'string' || !Number.isInteger(caret) || caret < 1 || caret > text.length) return null;
  let i = caret - 1;
  while (i >= 0) {
    const ch = text.charAt(i);
    if (ch === '@') break;
    if (WS.test(ch)) return null;
    i--;
  }
  if (i < 0) return null;
  if (i > 0 && !WS.test(text.charAt(i - 1))) return null;
  for (const m of mentions) {
    if (m.start === i || (caret > m.start && caret <= m.start + m.length)) return null;
  }
  return { start: i, end: caret, query: text.slice(i + 1, caret) };
}

// Case-insensitive: prefix matches first, then word-start, then contains; the
// member order is kept within each group. Excluded ids never appear.
export function filterMembers(members, query, excludeIds = []) {
  const q = (query || '').toLowerCase();
  const skip = new Set(excludeIds);
  const groups = [[], [], []];
  for (const mem of members || []) {
    if (!mem || skip.has(mem.user_id)) continue;
    const name = mem.username.toLowerCase();
    if (!q) { groups[0].push(mem); continue; }
    if (name.startsWith(q)) groups[0].push(mem);
    else if (new RegExp(`(?:^|[\\s._-])${q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`).test(name)) groups[1].push(mem);
    else if (name.includes(q)) groups[2].push(mem);
  }
  return [...groups[0], ...groups[1], ...groups[2]];
}

// Replace the "@query" token with "@Name " (no second space when whitespace
// already follows) and record the mention. Returns { text, mentions, caret }.
export function insertMention(text, trigger, member, mentions) {
  const token = `@${member.username}`;
  const after = text.slice(trigger.end);
  const hasSpace = after.length > 0 && WS.test(after.charAt(0));
  const insert = hasSpace ? token : `${token} `;
  const next = text.slice(0, trigger.start) + insert + after;
  const delta = next.length - text.length;
  const shifted = (mentions || []).map((m) => (m.start >= trigger.end ? { ...m, start: m.start + delta } : m));
  const added = { userId: member.user_id, username: member.username, start: trigger.start, length: token.length };
  const all = [...shifted, added].sort((a, b) => a.start - b.start);
  return { text: next, mentions: all, caret: trigger.start + token.length + 1 };
}

// GET /groups/{user_id}/{group_id}/mention-members. Throws on anything but a
// well-formed 200 (throw-not-fabricate): the caller then shows no picker.
export async function fetchMentionMembers(userId, groupId) {
  const res = await fetch(`${API}/groups/${encodeURIComponent(userId)}/${encodeURIComponent(groupId)}/mention-members`, {
    credentials: 'include',
    cache: 'no-store',
  });
  if (res.status !== 200) throw new Error(`mention-members HTTP ${res.status}`);
  const body = await res.json();
  if (!body || !Array.isArray(body.members)) throw new Error('mention-members malformed');
  const seen = new Set();
  const out = [];
  for (const e of body.members) {
    if (!e || typeof e.user_id !== 'string' || !e.user_id || typeof e.username !== 'string' || !e.username) {
      throw new Error('mention-members malformed');
    }
    const id = e.user_id.toLowerCase();
    if (seen.has(id)) continue;
    seen.add(id);
    out.push({ user_id: id, username: e.username });
  }
  return out;
}
