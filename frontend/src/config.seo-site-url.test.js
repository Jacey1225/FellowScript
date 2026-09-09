// Confirms config.js's SITE_URL (task 20260909-website-seo) resolves the way
// Configuration Q2/Q4/Q7 require: a real VITE_SITE_URL value (as
// frontend/.env.production sets at build time) is used verbatim for every
// canonical/OG/JSON-LD tag, and the 'http://localhost:5173' literal is only
// ever a dev-time fallback -- never a production placeholder. The
// build-time fail-fast itself (refusing `npm run build` without
// VITE_SITE_URL) lives in vite.config.js and isn't unit-testable here; this
// covers the value-resolution half of that same acceptance criterion.
//
// Run with: cd frontend && npm test -- --run src/config.seo-site-url.test.js
import { describe, test, expect, vi, afterEach } from 'vitest';

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe('config.js — SITE_URL', () => {
  test('falls back to localhost when VITE_SITE_URL is unset (the dev-only case, never shipped to production)', async () => {
    vi.stubEnv('VITE_SITE_URL', undefined);
    vi.resetModules();

    const { SITE_URL } = await import('./config.js');
    expect(SITE_URL).toBe('http://localhost:5173');
  });

  test('uses the real production domain verbatim once VITE_SITE_URL is set (mirrors frontend/.env.production at build time)', async () => {
    vi.stubEnv('VITE_SITE_URL', 'https://fellowscript.com');
    vi.resetModules();

    const { SITE_URL } = await import('./config.js');
    expect(SITE_URL).toBe('https://fellowscript.com');
  });
});
