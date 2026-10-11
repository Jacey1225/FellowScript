// Task 20261011-web-session-screenshare-rooms (step 1). Pure, SDK-free logic
// for desktop screen share, ported from iOS ScreenShareState.swift /
// CallSessionUIState.swift. Everything here is a plain function so the rules
// (flag gating, one share at a time, honest copy) are unit testable without
// the Chime SDK or a browser.

// Server feature flag (GET /app/capabilities -> features.screen_share_enabled).
// It gates SENDING only; receiving a content share is always on.
export const SCREEN_SHARE_FLAG = 'screen_share_enabled';

// Chime names the content attendee "<externalUserId>#content".
const CONTENT_SUFFIX = '#content';

// Returns the real user id behind a Chime external user id (content or not),
// or '' when there is none. Never fabricates a name.
export function contentOwnerId(externalUserId) {
  if (typeof externalUserId !== 'string' || !externalUserId) return '';
  return externalUserId.endsWith(CONTENT_SUFFIX)
    ? externalUserId.slice(0, -CONTENT_SUFFIX.length)
    : externalUserId;
}

// True when this runtime can capture the display at all. Missing in some
// webviews (e.g. an embedded WKWebView without media-capture support).
export function isDisplayCaptureSupported() {
  return typeof navigator !== 'undefined'
    && !!navigator.mediaDevices
    && typeof navigator.mediaDevices.getDisplayMedia === 'function';
}

// The Share screen row is offered only when the server flag is explicitly on
// AND the runtime can capture. Fail closed: anything else hides it.
export function canOfferScreenShare({ flagEnabled, supported }) {
  return flagEnabled === true && supported === true;
}

// Why a start is not allowed right now (null = allowed).
export function screenShareStartBlock({ flagEnabled, supported, connected, someoneElseSharing, phase }) {
  if (flagEnabled !== true) return 'flagOff';
  if (!supported) return 'unsupported';
  if (!connected) return 'notConnected';
  if (phase !== 'idle') return 'alreadyActive';
  if (someoneElseSharing) return 'someoneElseSharing';
  return null;
}

// Maps a getDisplayMedia / startContentShare failure to a coarse kind.
// NotAllowedError covers both "user dismissed the picker" and "OS or webview
// denied capture"; the browser does not let us tell them apart.
export function classifyCaptureError(err) {
  const name = err && err.name;
  if (name === 'NotAllowedError' || name === 'AbortError' || name === 'SecurityError') return 'cancelled';
  return 'failed';
}

// Pure layout rule (iOS CallLayoutState): one top row of bubbles iff Prompts
// are open or a share exists (someone else's tile, or my own "You are
// sharing" panel, both of which need the content area).
export function callLayoutMode({ promptsOpen, hasShare }) {
  return promptsOpen || hasShare ? 'row' : 'field';
}

// What the content area shows. A share wins the area over Prompts; Prompts
// return once the share stops. My own share shows the "You are sharing" panel
// (never my own frames).
export function contentAreaKind({ promptsOpen, hasRemoteShare, sharingSelf }) {
  if (hasRemoteShare) return 'remoteShare';
  if (sharingSelf) return 'selfShare';
  if (promptsOpen) return 'prompts';
  return 'none';
}

// Warm, fail-soft copy (iOS ScreenShareMessages). Never raw error text.
export const SCREEN_SHARE_COPY = {
  couldNotStart: "We couldn't start screen sharing. Please try again.",
  notStarted: "Screen sharing wasn't started. If you didn't cancel, check your system's screen recording permission.",
  ended: 'Screen sharing ended.',
  failedMidShare: 'Screen sharing stopped unexpectedly.',
  someoneElse: 'Someone else is already sharing.',
  changedRooms: 'Screen sharing stopped because you changed rooms.',
};
