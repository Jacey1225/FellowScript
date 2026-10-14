// Task 20261013-session-call-live-transcript-summary testing: web transcript relay.
// Run: cd frontend && npx vitest run src/lib/transcriptRelay.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  transcriptionFromJoin, segmentsFromEvent, makeTranscriptRequest, createTranscriptRelay, TRANSCRIPT_CONSENT_COPY,
} from './transcriptRelay.js';

const ev = (results) => ({ results });
const fin = (text, ext) => ({
  isPartial: false,
  alternatives: [{ transcript: text, items: ext ? [{ attendee: { externalUserId: ext } }] : [] }],
});

describe('transcriptionFromJoin', () => {
  test('fails closed on missing/malformed fields', () => {
    for (const b of [null, undefined, 'x', {}, { transcription_active: 'true' }]) {
      expect(transcriptionFromJoin(b)).toEqual({ active: false, relay: false, pollSeconds: 0 });
    }
  });
  test('relay never true unless transcription is active', () => {
    expect(transcriptionFromJoin({ transcription_active: false, transcript_relay: true, transcript_poll_seconds: 15 }).relay).toBe(false);
    expect(transcriptionFromJoin({ transcription_active: true, transcript_relay: true, transcript_poll_seconds: 15 }))
      .toEqual({ active: true, relay: true, pollSeconds: 15 });
  });
  test('bad poll seconds -> 0', () => {
    expect(transcriptionFromJoin({ transcription_active: true, transcript_poll_seconds: -3 }).pollSeconds).toBe(0);
    expect(transcriptionFromJoin({ transcription_active: true, transcript_poll_seconds: 'abc' }).pollSeconds).toBe(0);
  });
  test('consent copy states transcription and that only the summary is saved', () => {
    expect(TRANSCRIPT_CONSENT_COPY).toMatch(/transcribed/i);
    expect(TRANSCRIPT_CONSENT_COPY).toMatch(/only the summary is saved/i);
  });
});

describe('segmentsFromEvent', () => {
  test('keeps final results only, with externalUserId as speaker_id', () => {
    const out = segmentsFromEvent(ev([
      { isPartial: true, alternatives: [{ transcript: 'partial words', items: [] }] },
      fin('hello there', 'u1'),
    ]));
    expect(out).toEqual([{ text: 'hello there', speaker_id: 'u1' }]);
  });
  test('ignores blanks, non-transcript events, content-share attendees', () => {
    expect(segmentsFromEvent(null)).toEqual([]);
    expect(segmentsFromEvent({ status: { type: 'started' } })).toEqual([]);
    expect(segmentsFromEvent(ev([fin('   ', 'u1')]))).toEqual([]);
    expect(segmentsFromEvent(ev([fin('shared screen audio', 'u1#content')]))).toEqual([{ text: 'shared screen audio' }]);
  });
  test('splits long text to the per-segment cap', () => {
    const out = segmentsFromEvent(ev([fin('a'.repeat(2500), 'u1')]));
    expect(out.map(s => s.text.length)).toEqual([1000, 1000, 500]);
    expect(out.every(s => s.speaker_id === 'u1')).toBe(true);
  });
});

describe('makeTranscriptRequest', () => {
  test('encodes ids, posts JSON body, never returns body text for ingest', async () => {
    const fetchFn = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({ accepted: 1 }) });
    const req = makeTranscriptRequest({ api: 'http://x', fetchFn, sessionId: 's 1', userId: 'u&1' });
    const r = await req('ingest', { segments: [{ text: 'hi' }] });
    expect(r).toEqual({ status: 200, data: null });
    const [url, init] = fetchFn.mock.calls[0];
    expect(url).toBe('http://x/devotions/transcript/ingest?session_id=s%201&user_id=u%261');
    expect(JSON.parse(init.body)).toEqual({ segments: [{ text: 'hi' }] });
  });
  test('status returns parsed data; leave has no body', async () => {
    const fetchFn = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({ transcript_relay: true }) });
    const req = makeTranscriptRequest({ api: '', fetchFn, sessionId: 's', userId: 'u' });
    expect((await req('status')).data).toEqual({ transcript_relay: true });
    await req('leave');
    expect(fetchFn.mock.calls[1][1].body).toBeUndefined();
  });
});

describe('createTranscriptRelay', () => {
  let request;
  beforeEach(() => { vi.useFakeTimers(); request = vi.fn(); vi.spyOn(console, 'warn').mockImplementation(() => {}); });
  afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });
  const mk = (initial, extra = {}) => {
    const onStatus = vi.fn();
    const r = createTranscriptRelay({ request, onStatus, initial, pollMs: 15000, flushMs: 3000, ...extra });
    return { r, onStatus };
  };

  test('non-relay client buffers nothing and never ingests, but still polls', async () => {
    request.mockResolvedValue({ status: 200, data: { transcription_active: true, transcript_relay: false, poll_seconds: 15 } });
    const { r } = mk({ active: true, relay: false, pollSeconds: 15 });
    r.start();
    r.handleEvent(ev([fin('secret words', 'u1')]));
    expect(r.getState().buffered).toBe(0);
    await vi.advanceTimersByTimeAsync(16000);
    expect(request).toHaveBeenCalledWith('status');
    expect(request.mock.calls.some(c => c[0] === 'ingest')).toBe(false);
    r.stop();
  });

  test('relay batches final segments and sends them after the flush delay', async () => {
    request.mockResolvedValue({ status: 200, data: null });
    const { r } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    r.handleEvent(ev([fin('one', 'u1')]));
    r.handleEvent(ev([fin('two', 'u2')]));
    expect(request).not.toHaveBeenCalledWith('ingest', expect.anything());
    await vi.advanceTimersByTimeAsync(3100);
    const ing = request.mock.calls.filter(c => c[0] === 'ingest');
    expect(ing).toHaveLength(1);
    expect(ing[0][1].segments).toEqual([{ text: 'one', speaker_id: 'u1' }, { text: 'two', speaker_id: 'u2' }]);
    r.stop();
  });

  test('at most 40 segments per request', async () => {
    request.mockResolvedValue({ status: 200, data: null });
    const { r } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    for (let i = 0; i < 100; i++) r.handleEvent(ev([fin(`s${i}`, 'u1')]));
    await vi.advanceTimersByTimeAsync(3100);
    const ing = request.mock.calls.filter(c => c[0] === 'ingest');
    expect(ing[0][1].segments).toHaveLength(40);
    r.stop();
  });

  test('429/5xx requeues with backoff; nothing lost', async () => {
    request.mockResolvedValueOnce({ status: 503, data: null }).mockResolvedValue({ status: 200, data: null });
    const { r } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    r.handleEvent(ev([fin('keep me', 'u1')]));
    await vi.advanceTimersByTimeAsync(3100);
    expect(r.getState().buffered).toBe(1);
    await vi.advanceTimersByTimeAsync(6100);
    const ing = request.mock.calls.filter(c => c[0] === 'ingest');
    expect(ing).toHaveLength(2);
    expect(ing[1][1].segments[0].text).toBe('keep me');
    expect(r.getState().buffered).toBe(0);
    r.stop();
  });

  test('403 drops buffer, loses relay role and re-checks status immediately', async () => {
    request.mockImplementation(async (a) => {
      if (a === 'ingest') return { status: 403, data: null };
      return { status: 200, data: { transcription_active: true, transcript_relay: false, poll_seconds: 15 } };
    });
    const { r, onStatus } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    r.handleEvent(ev([fin('x', 'u1')]));
    await vi.advanceTimersByTimeAsync(3100);
    expect(r.getState()).toMatchObject({ relay: false, buffered: 0 });
    expect(onStatus).toHaveBeenLastCalledWith({ active: true, relay: false });
    await vi.advanceTimersByTimeAsync(10);
    expect(request).toHaveBeenCalledWith('status');
    r.handleEvent(ev([fin('after', 'u1')]));
    expect(r.getState().buffered).toBe(0);
    r.stop();
  });

  test('413/422 drops the batch without retry', async () => {
    request.mockResolvedValue({ status: 422, data: null });
    const { r } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    r.handleEvent(ev([fin('x', 'u1')]));
    await vi.advanceTimersByTimeAsync(20000);
    expect(request.mock.calls.filter(c => c[0] === 'ingest')).toHaveLength(1);
    r.stop();
  });

  test('role handed over by the poll: becomes relay when the server says so', async () => {
    request.mockResolvedValue({ status: 200, data: { transcription_active: true, transcript_relay: true, poll_seconds: 15 } });
    const { r, onStatus } = mk({ active: true, relay: false, pollSeconds: 15 });
    r.start();
    await vi.advanceTimersByTimeAsync(15100);
    expect(onStatus).toHaveBeenLastCalledWith({ active: true, relay: true });
    r.handleEvent(ev([fin('now mine', 'u1')]));
    expect(r.getState().buffered).toBe(1);
    r.stop();
  });

  test('transcription starting after join flips active (consent banner) via poll', async () => {
    request.mockResolvedValue({ status: 200, data: { transcription_active: true, transcript_relay: false, poll_seconds: 15 } });
    const { r, onStatus } = mk({ active: false, relay: false, pollSeconds: 15 });
    r.start();
    await vi.advanceTimersByTimeAsync(15100);
    expect(onStatus).toHaveBeenLastCalledWith({ active: true, relay: false });
    r.stop();
  });

  test('404 (feature off) clears state and stops polling', async () => {
    request.mockResolvedValue({ status: 404, data: null });
    const { r } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    await vi.advanceTimersByTimeAsync(15100);
    expect(r.getState()).toMatchObject({ active: false, relay: false });
    const n = request.mock.calls.length;
    await vi.advanceTimersByTimeAsync(60000);
    expect(request.mock.calls.length).toBe(n);
    r.stop();
  });

  test('stop({flushRemaining}) sends the tail BEFORE leave, then stops everything', async () => {
    const order = [];
    request.mockImplementation(async (a, b) => { order.push(a); return { status: 200, data: null }; });
    const { r } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    r.handleEvent(ev([fin('tail words', 'u1')]));
    await r.stop({ flushRemaining: true });
    expect(order).toEqual(['ingest', 'leave']);
    r.handleEvent(ev([fin('late', 'u1')]));
    expect(r.getState().buffered).toBe(0);
    request.mockClear();
    await vi.advanceTimersByTimeAsync(60000);
    expect(request).not.toHaveBeenCalled();
  });

  test('stop() on a never-active client does not send leave', async () => {
    request.mockResolvedValue({ status: 200, data: null });
    const { r } = mk({ active: false, relay: false, pollSeconds: 0 });
    r.start();
    await r.stop();
    expect(request).not.toHaveBeenCalledWith('leave');
  });

  test('flush on stop is bounded even if the server hangs', async () => {
    request.mockImplementation((a) => (a === 'ingest' ? new Promise(() => {}) : Promise.resolve({ status: 200, data: null })));
    const { r } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    r.handleEvent(ev([fin('x', 'u1')]));
    const p = r.stop({ flushRemaining: true });
    await vi.advanceTimersByTimeAsync(3500);
    await p;
    expect(request).toHaveBeenCalledWith('leave');
  });

  test('client buffer is bounded (oldest dropped)', async () => {
    request.mockResolvedValue({ status: 500, data: null });
    const { r } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    for (let i = 0; i < 600; i++) r.handleEvent(ev([fin(`s${i}`, 'u1')]));
    expect(r.getState().buffered).toBeLessThanOrEqual(400);
    r.stop();
  });

  test('never logs transcript text', async () => {
    request.mockResolvedValue({ status: 403, data: null });
    const spy = console.warn;
    const { r } = mk({ active: true, relay: true, pollSeconds: 15 });
    r.start();
    r.handleEvent(ev([fin('TOP SECRET SPOKEN WORDS', 'u1')]));
    await vi.advanceTimersByTimeAsync(3100);
    expect(JSON.stringify(spy.mock.calls)).not.toContain('SECRET');
    r.stop();
  });
});
