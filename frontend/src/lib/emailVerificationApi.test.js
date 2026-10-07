// Task 20261007-email-verification: client throws on non-2xx, never sends an address.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { getEmailStatus, resendVerification, verifyEmailToken, EmailVerificationApiError } from './emailVerificationApi.js';

const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const bad = (status) => ({ ok: false, status, json: async () => ({ detail: 'secret server detail' }) });

beforeEach(() => { global.fetch = vi.fn(); });
afterEach(() => { vi.restoreAllMocks(); });

describe('emailVerificationApi', () => {
  test('getEmailStatus GETs status with credentials', async () => {
    fetch.mockResolvedValue(ok({ enabled: true, verified: false }));
    expect(await getEmailStatus()).toEqual({ enabled: true, verified: false });
    const [url, init] = fetch.mock.calls[0];
    expect(url).toMatch(/\/auth\/email\/status$/);
    expect(init.credentials).toBe('include');
  });

  test('resend POSTs with no body (no email/user_id from client)', async () => {
    fetch.mockResolvedValue(ok({ detail: 'ok', resend_cooldown_seconds: 60 }));
    await resendVerification();
    const [url, init] = fetch.mock.calls[0];
    expect(url).toMatch(/\/auth\/email\/resend$/);
    expect(init.method).toBe('POST');
    expect(init.body).toBeUndefined();
  });

  test('verify POSTs the token as JSON', async () => {
    fetch.mockResolvedValue(ok({ verified: true }));
    await verifyEmailToken('tok123');
    const [url, init] = fetch.mock.calls[0];
    expect(url).toMatch(/\/auth\/email\/verify$/);
    expect(JSON.parse(init.body)).toEqual({ token: 'tok123' });
  });

  test.each([400, 404, 429, 500])('non-2xx %i throws with status and a generic message', async (s) => {
    fetch.mockResolvedValue(bad(s));
    for (const fn of [getEmailStatus, resendVerification, () => verifyEmailToken('t')]) {
      const err = await fn().catch((e) => e);
      expect(err).toBeInstanceOf(EmailVerificationApiError);
      expect(err.status).toBe(s);
      expect(err.message).not.toMatch(/secret/);
    }
  });

  test('network failure throws status 0', async () => {
    fetch.mockRejectedValue(new Error('boom'));
    const err = await getEmailStatus().catch((e) => e);
    expect(err).toBeInstanceOf(EmailVerificationApiError);
    expect(err.status).toBe(0);
  });

  test('verify failure message is identical for every failure status', async () => {
    const msgs = new Set();
    for (const s of [400, 404, 410, 500]) {
      fetch.mockResolvedValue(bad(s));
      msgs.add((await verifyEmailToken('t').catch((e) => e)).message);
    }
    expect(msgs.size).toBe(1);
  });
});
