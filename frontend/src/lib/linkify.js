// Task 20261124-clickable-message-links. Render-time URL detection for chat
// text. The rules are a cross-platform contract (web, desktop and iOS):
// shared/linkify-fixtures.json is run by both this file's tests and the Swift
// linkifier's tests, so change a rule in all places or in none.
//
// Rules (see intake spec, design decision 3):
//  - Candidate starts with http:// or https:// (case-insensitive scheme) and
//    runs to the first whitespace, one of < > ", or a control character.
//  - Trailing . , ; : ! ? ' are stripped (left as plain text).
//  - A trailing ) ] } is stripped only while unbalanced inside the URL.
//  - The remainder must parse as an http(s) URL with a non-empty host.
//  - Linear time: one regex pass plus an O(n) scan per candidate; input past
//    MAX_SCAN_CHARS is never linked.
// Never used with innerHTML: callers build React elements from the segments.

export const MAX_SCAN_CHARS = 20000;

const SCHEME_RE = /https?:\/\//gi;
const STOP_RE = /[\s<>"\u0000-\u001f\u007f-\u009f]/; // \s already covers U+2028/2029
const TRAIL_PUNCT = ".,;:!?'";
const CLOSER_FOR = { ')': '(', ']': '[', '}': '{' };

// Returns { href, host, suspicious } for a candidate URL string, or null when it
// is not a linkable http(s) URL. `host` is the ASCII (punycode) host; with a
// non-default port it includes the port. `suspicious` = userinfo, raw IP host,
// non-default port, or a non-ASCII (IDN) host.
export function linkInfo(raw) {
  let u;
  try { u = new URL(raw); } catch { return null; }
  if ((u.protocol !== 'http:' && u.protocol !== 'https:') || !u.hostname) return null;
  const hostText = (raw.replace(/^https?:\/\//i, '').split(/[/?#]/, 1)[0]) || '';
  const authority = hostText.slice(hostText.lastIndexOf('@') + 1);
  const bareHost = authority.replace(/:\d*$/, '');
  const hasUserinfo = hostText.includes('@') || !!u.username || !!u.password;
  const isIp = /^\[.*\]$/.test(u.hostname) || /^\d{1,3}(\.\d{1,3}){3}$/.test(u.hostname);
  const nonAscii = /[^\x00-\x7f]/.test(bareHost);
  const hasPort = u.port !== '';
  return {
    href: u.href,
    host: u.host,
    suspicious: hasUserinfo || isIp || hasPort || nonAscii,
  };
}

// Splits `text` into [{ type: 'text'|'link', text }] (concatenation === text).
export function linkifySegments(text) {
  const s = typeof text === 'string' ? text : '';
  if (!s) return [{ type: 'text', text: '' }];
  const limit = Math.min(s.length, MAX_SCAN_CHARS);
  const out = [];
  let pos = 0;
  SCHEME_RE.lastIndex = 0;
  let m;
  while ((m = SCHEME_RE.exec(s)) !== null) {
    const start = m.index;
    if (start < pos) continue;
    if (start >= limit) break;
    let end = start + m[0].length;
    const bodyStart = end;
    let open = { '(': 0, '[': 0, '{': 0 };
    let close = { ')': 0, ']': 0, '}': 0 };
    while (end < limit && !STOP_RE.test(s[end])) {
      const c = s[end];
      if (c in open) open[c] += 1;
      else if (c in close) close[c] += 1;
      end += 1;
    }
    // A URL cut off by the scan cap is never linked.
    const capped = end >= limit && limit < s.length && !STOP_RE.test(s[end] ?? ' ');
    let e = end;
    while (e > bodyStart) {
      const c = s[e - 1];
      if (TRAIL_PUNCT.includes(c)) { e -= 1; continue; }
      if (c in close && close[c] > open[CLOSER_FOR[c]]) { close[c] -= 1; e -= 1; continue; }
      break;
    }
    SCHEME_RE.lastIndex = Math.max(end, start + 1);
    if (capped || e <= bodyStart) continue;
    const url = s.slice(start, e);
    if (!linkInfo(url)) continue;
    if (start > pos) out.push({ type: 'text', text: s.slice(pos, start) });
    out.push({ type: 'link', text: url });
    pos = e;
  }
  if (pos === 0) return [{ type: 'text', text: s }];
  if (pos < s.length) out.push({ type: 'text', text: s.slice(pos) });
  return out;
}

// Only http(s) hrefs may become clickable (AI markdown links use this).
export function isSafeHttpUrl(href) {
  return typeof href === 'string' && !!linkInfo(href.trim());
}
