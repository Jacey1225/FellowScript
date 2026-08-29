// User-Agent based mobile detection for gating routes that don't have a
// mobile-optimized layout (currently just /reader — see MobileBlockGate.jsx).
//
// This is a UX-level check, not a security boundary: a mobile browser can
// always spoof its UA string to get past it, same as any client-side gate
// in this codebase (see AdminGate.jsx's own comment on this). It's fine
// here because nothing sensitive is being protected — the only cost of a
// false negative (a phone getting through) is a cramped layout, and the
// cost of a false positive (a legitimate desktop/tablet user blocked) is
// worse, which is why the regex below stays conservative: it matches the
// common phone UA tokens and deliberately does NOT try to catch iPadOS
// Safari, which reports itself as a Mac since iPadOS 13 and is a fine fit
// for the desktop dockview layout anyway.
const MOBILE_UA_RE = /Android|iPhone|iPod|IEMobile|BlackBerry|Opera Mini|Windows Phone/i;

export function isMobileUserAgent(ua = (typeof navigator !== 'undefined' ? navigator.userAgent : '')) {
  return MOBILE_UA_RE.test(ua || '');
}
