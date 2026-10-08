// Admin 2FA enforcement helpers (task 20261008-admin-require-2fa).
import { describe, test, expect, beforeEach } from 'vitest';
import {
  isMfaRequiredDetail, isMfaRequiredResponse, isMfaRequiredError,
  setMfaRequiredFlag, hasMfaRequiredFlag, clearMfaRequiredFlag,
} from './adminMfa.js';

const resp = (status, body) => new Response(JSON.stringify(body), { status });

describe('adminMfa', () => {
  beforeEach(() => sessionStorage.clear());

  test('detail matcher accepts only the structured mfa_required object', () => {
    expect(isMfaRequiredDetail({ code: 'mfa_required', message: 'x' })).toBe(true);
    expect(isMfaRequiredDetail('Admin access required')).toBe(false);
    expect(isMfaRequiredDetail({ code: 'other' })).toBe(false);
    expect(isMfaRequiredDetail(null)).toBe(false);
    expect(isMfaRequiredDetail(undefined)).toBe(false);
  });

  test('response matcher: mfa_required 403 true; plain 403, other statuses, bad body false', async () => {
    expect(await isMfaRequiredResponse(resp(403, { detail: { code: 'mfa_required', message: 'm' } }))).toBe(true);
    expect(await isMfaRequiredResponse(resp(403, { detail: 'Admin access required' }))).toBe(false);
    expect(await isMfaRequiredResponse(resp(401, { detail: { code: 'mfa_required' } }))).toBe(false);
    expect(await isMfaRequiredResponse(new Response('not json', { status: 403 }))).toBe(false);
    expect(await isMfaRequiredResponse(null)).toBe(false);
  });

  test('response matcher leaves the original body readable', async () => {
    const r = resp(403, { detail: { code: 'mfa_required', message: 'm' } });
    await isMfaRequiredResponse(r);
    expect((await r.json()).detail.code).toBe('mfa_required');
  });

  test('error matcher needs status 403 and the code', () => {
    expect(isMfaRequiredError({ status: 403, code: 'mfa_required' })).toBe(true);
    expect(isMfaRequiredError({ status: 403 })).toBe(false);
    expect(isMfaRequiredError({ status: 401, code: 'mfa_required' })).toBe(false);
    expect(isMfaRequiredError(null)).toBe(false);
  });

  test('return-to-enable flag set / read / clear', () => {
    expect(hasMfaRequiredFlag()).toBe(false);
    setMfaRequiredFlag();
    expect(hasMfaRequiredFlag()).toBe(true);
    clearMfaRequiredFlag();
    expect(hasMfaRequiredFlag()).toBe(false);
  });
});
