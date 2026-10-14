// Live-call transcript relay (task 20261013-session-call-live-transcript-summary).
//
// Chime delivers transcript events only to attendee clients. Exactly ONE client
// per call (the "relay", decided by the server, never self-appointed) forwards
// final text to POST /devotions/transcript/ingest so the summarize route can
// use it. Everything here is text-in-memory-only: no persistence, and no
// transcript text is ever logged (only HTTP status codes).

export const TRANSCRIPT_CONSENT_COPY =
  'This call is being transcribed to write the session summary. Only the summary is saved.';

const DEFAULT_POLL_MS = 15000;
const DEFAULT_FLUSH_MS = 3000;
const MAX_SEGMENTS = 40;        // server cap per request (ingest_max_segments)
const MAX_SEGMENT_CHARS = 1000; // server cap per segment (ingest_max_segment_chars)
const MAX_BUFFERED = 400;       // client-side bound; oldest dropped first
const STOP_FLUSH_TIMEOUT_MS = 3000;

const PATHS = {
  status: '/devotions/transcript/relay-status',
  ingest: '/devotions/transcript/ingest',
  leave:  '/devotions/transcript/leave',
};

// Reads the transcription fields every join response carries. Missing or
// malformed fields mean "off" (fail closed: no banner, no relay).
export function transcriptionFromJoin(body) {
  const b = body && typeof body === 'object' ? body : {};
  const pollSeconds = Number(b.transcript_poll_seconds);
  return {
    active: b.transcription_active === true,
    relay: b.transcription_active === true && b.transcript_relay === true,
    pollSeconds: Number.isFinite(pollSeconds) && pollSeconds > 0 ? pollSeconds : 0,
  };
}

// Final (non-partial) results only. Long text is split so every segment fits
// the server's per-segment cap. speaker_id is the Chime attendee externalUserId
// (the FellowScript user id); the server derives the display label itself.
export function segmentsFromEvent(event, maxChars = MAX_SEGMENT_CHARS) {
  const out = [];
  const results = event && Array.isArray(event.results) ? event.results : null;
  if (!results) return out;
  for (const r of results) {
    if (!r || r.isPartial) continue;
    const alt = Array.isArray(r.alternatives) ? r.alternatives[0] : null;
    const text = alt && typeof alt.transcript === 'string' ? alt.transcript.trim() : '';
    if (!text) continue;
    const items = Array.isArray(alt.items) ? alt.items : [];
    const ext = items.map(i => i && i.attendee && i.attendee.externalUserId).find(x => typeof x === 'string' && x);
    const speaker = ext && !ext.endsWith('#content') ? ext : null;
    for (let i = 0; i < text.length; i += maxChars) {
      const seg = { text: text.slice(i, i + maxChars) };
      if (speaker) seg.speaker_id = speaker;
      out.push(seg);
    }
  }
  return out;
}

// Builds the single request function the relay uses. Returns { status, data }.
export function makeTranscriptRequest({ api, fetchFn, sessionId, userId }) {
  const q = `session_id=${encodeURIComponent(sessionId)}&user_id=${encodeURIComponent(userId)}`;
  return async (action, body) => {
    const res = await fetchFn(`${api}${PATHS[action]}?${q}`, {
      method: 'POST',
      ...(body ? { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } : {}),
    });
    let data = null;
    if (action === 'status' && res.ok) {
      try { data = await res.json(); } catch { data = null; }
    }
    return { status: res.status, data };
  };
}

export function createTranscriptRelay({
  request, onStatus, initial, pollMs = DEFAULT_POLL_MS, flushMs = DEFAULT_FLUSH_MS, timers = globalThis,
}) {
  let active = false;
  let relay = false;
  let stopped = false;
  let buffer = [];
  let inflight = false;
  let pollTimer = null;
  let flushTimer = null;
  let interval = pollMs;

  const setStatus = (nextActive, nextRelay) => {
    const changed = nextActive !== active || nextRelay !== relay;
    active = nextActive;
    relay = nextActive && nextRelay;
    if (!relay) buffer = [];
    if (changed && onStatus) onStatus({ active, relay });
  };

  const schedulePoll = () => {
    if (stopped) return;
    timers.clearTimeout(pollTimer);
    pollTimer = timers.setTimeout(poll, interval);
  };

  async function poll() {
    if (stopped) return;
    try {
      const { status, data } = await request('status');
      if (stopped) return;
      if (status === 404) { setStatus(false, false); return; }  // feature off: stop polling for this call
      if (status >= 200 && status < 300 && data) {
        const secs = Number(data.poll_seconds);
        if (Number.isFinite(secs) && secs > 0) interval = secs * 1000;
        setStatus(data.transcription_active === true, data.transcript_relay === true);
      }
    } catch {
      // Network blip: keep the last known state and try again next tick.
    }
    schedulePoll();
  }

  const scheduleFlush = (delay = flushMs) => {
    if (stopped || flushTimer || !relay || buffer.length === 0) return;
    flushTimer = timers.setTimeout(() => { flushTimer = null; flush(); }, delay);
  };

  async function flush() {
    if (stopped || inflight || !relay || buffer.length === 0) return;
    inflight = true;
    const batch = buffer.splice(0, MAX_SEGMENTS);
    let retryDelay = flushMs;
    try {
      const { status } = await request('ingest', { segments: batch });
      if (status === 403 || status === 404 || status === 409) {
        // Not (or no longer) the relay, or transcription ended: re-check now.
        console.warn('Transcript relay rejected:', status);
        setStatus(active, false);
        if (!stopped) { timers.clearTimeout(pollTimer); pollTimer = timers.setTimeout(poll, 0); }
      } else if (status === 429 || status >= 500) {
        buffer = batch.concat(buffer).slice(-MAX_BUFFERED);
        retryDelay = flushMs * 2;
      } else if (status === 413 || status === 422) {
        console.warn('Transcript batch dropped:', status);  // malformed for the server; retrying cannot help
      }
    } catch {
      buffer = batch.concat(buffer).slice(-MAX_BUFFERED);
      retryDelay = flushMs * 2;
    } finally {
      inflight = false;
    }
    scheduleFlush(retryDelay);
  }

  return {
    start() {
      stopped = false;
      const init = initial || { active: false, relay: false, pollSeconds: 0 };
      if (init.pollSeconds > 0) interval = init.pollSeconds * 1000;
      setStatus(init.active, init.relay);
      schedulePoll();
    },
    handleEvent(event) {
      if (stopped || !relay) return;
      const segs = segmentsFromEvent(event);
      if (!segs.length) return;
      buffer = buffer.concat(segs).slice(-MAX_BUFFERED);
      scheduleFlush();
    },
    // Optionally sends what is still buffered (bounded wait) so the summary
    // sees the end of the call, then says goodbye so the role can move on.
    async stop({ flushRemaining = false } = {}) {
      if (stopped) return;
      if (flushRemaining && relay && buffer.length) {
        const drain = (async () => {
          for (let pass = 0; pass < 5 && relay && buffer.length; pass++) {
            while (inflight) await new Promise(r => timers.setTimeout(r, 20));
            await flush();
          }
        })();
        await Promise.race([drain, new Promise(r => timers.setTimeout(r, STOP_FLUSH_TIMEOUT_MS))]);
      }
      const wasActive = active;
      stopped = true;
      timers.clearTimeout(pollTimer);
      timers.clearTimeout(flushTimer);
      pollTimer = null; flushTimer = null;
      buffer = [];
      if (wasActive || relay) {
        try { await request('leave'); } catch { /* best effort */ }
      }
      active = false; relay = false;
    },
    getState: () => ({ active, relay, buffered: buffer.length }),
  };
}
