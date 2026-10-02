// Task 20261002-shared-foundation step 9: capabilities client fail-closed behaviour.
import { describe, test, expect, vi, afterEach } from 'vitest';
import { fetchCapabilities, parseCapabilities, CAPABILITIES_OFF, CAPABILITIES_TIMEOUT_MS } from './capabilities.js';

const okBody = { v: 1, features: { threads: true, explorer_browse: true, join_requests: false }, links: { explore: 'https://x/#/explore' }, terms_current: false };
const resp = (status, body, bad) => ({ status, ok: status >= 200 && status < 300, json: bad ? () => Promise.reject(new SyntaxError('bad')) : () => Promise.resolve(body) });

afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });

describe('fetchCapabilities fail closed', () => {
  test('200 with valid body parses', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(resp(200, okBody)));
    const c = await fetchCapabilities();
    expect(c.features.threads).toBe(true);
    expect(c.features.join_requests).toBe(false);
    expect(c.links.explore).toBe('https://x/#/explore');
    expect(c.termsCurrent).toBe(false);
  });
  test.each([404, 401, 403, 500, 503, 204])('status %s -> all off', async (s) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(resp(s, okBody)));
    expect(await fetchCapabilities()).toBe(CAPABILITIES_OFF);
  });
  test('network error -> all off, never throws', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('net')));
    expect(await fetchCapabilities()).toBe(CAPABILITIES_OFF);
  });
  test.each([
    ['non-JSON', null, true],
    ['null body', null, false],
    ['array body', [], false],
    ['no features', { terms_current: true }, false],
    ['features not object', { features: 'x', terms_current: true }, false],
    ['terms_current missing', { features: {} }, false],
    ['terms_current not boolean', { features: {}, terms_current: 'false' }, false],
  ])('malformed body (%s) -> all off', async (_n, body, bad) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(resp(200, body, bad)));
    expect(await fetchCapabilities()).toBe(CAPABILITIES_OFF);
  });
  test('timeout aborts and fails closed', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('fetch', vi.fn((_u, { signal }) => new Promise((_r, rej) => {
      signal.addEventListener('abort', () => rej(new DOMException('aborted', 'AbortError')));
    })));
    const p = fetchCapabilities();
    await vi.advanceTimersByTimeAsync(CAPABILITIES_TIMEOUT_MS + 1);
    expect(await p).toBe(CAPABILITIES_OFF);
  });
  test('only literal true enables a feature; explore link needs explorer_browse', () => {
    const c = parseCapabilities({ features: { a: 'true', b: 1, c: true }, links: { explore: 'u' }, terms_current: true });
    expect(c.features).toEqual({ a: false, b: false, c: true });
    expect(c.links.explore).toBe(null);
  });
  test('CAPABILITIES_OFF: no features, terms current', () => {
    expect(CAPABILITIES_OFF.features).toEqual({});
    expect(CAPABILITIES_OFF.termsCurrent).toBe(true);
  });
});
