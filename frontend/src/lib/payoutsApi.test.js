// Task 20261008-affiliate-payout-details: client hygiene + validation mirror.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  abaValid, validatePayoutFields, payoutErrorMessage, PayoutsApiError,
  getPayoutStatus, savePayoutDetails, verifyPayoutCode, deletePayoutDetails,
} from './payoutsApi.js';

const GOOD = { routing_number: '021000021', account_number: '123456789', account_confirm: '123456789', account_type: 'checking', holder_name: "Mary-Ann O'Neil" };

describe('abaValid', () => {
  test('accepts real checksum numbers', () => {
    expect(abaValid('021000021')).toBe(true);
    expect(abaValid('011401533')).toBe(true);
  });
  test('rejects bad checksum, length, non-digits', () => {
    expect(abaValid('021000022')).toBe(false);
    expect(abaValid('02100002')).toBe(false);
    expect(abaValid('0210000211')).toBe(false);
    expect(abaValid('02100002a')).toBe(false);
    expect(abaValid('')).toBe(false);
  });
});

describe('validatePayoutFields', () => {
  test('valid input has no errors', () => expect(validatePayoutFields(GOOD)).toEqual({}));
  test('each rule is flagged', () => {
    const e = validatePayoutFields({ routing_number: '1', account_number: '12', account_confirm: '13', account_type: 'x', holder_name: 'A1' });
    expect(Object.keys(e).sort()).toEqual(['account_confirm', 'account_number', 'account_type', 'holder_name', 'routing_number']);
  });
  test('account 4 and 17 digits ok, 3 and 18 not', () => {
    expect(validatePayoutFields({ ...GOOD, account_number: '1234', account_confirm: '1234' })).toEqual({});
    const n17 = '1'.repeat(17), n18 = '1'.repeat(18), n3 = '123';
    expect(validatePayoutFields({ ...GOOD, account_number: n17, account_confirm: n17 })).toEqual({});
    expect(validatePayoutFields({ ...GOOD, account_number: n18, account_confirm: n18 }).account_number).toBeTruthy();
    expect(validatePayoutFields({ ...GOOD, account_number: n3, account_confirm: n3 }).account_number).toBeTruthy();
  });
  test('mismatched confirm flagged', () => {
    expect(validatePayoutFields({ ...GOOD, account_confirm: '123456780' }).account_confirm).toBeTruthy();
  });
});

describe('payoutErrorMessage', () => {
  test('maps known codes, generic for unknown, never echoes raw code', () => {
    expect(payoutErrorMessage(new PayoutsApiError('reauth_failed', 403))).toMatch(/not accepted/);
    const m = payoutErrorMessage(new PayoutsApiError('SELECT secret 123456789', 500));
    expect(m).toBe('Something went wrong. Please try again.');
    expect(payoutErrorMessage(null)).toBe('Something went wrong. Please try again.');
  });
});

describe('request hygiene', () => {
  let fetchMock;
  beforeEach(() => { fetchMock = vi.fn(); vi.stubGlobal('fetch', fetchMock); });
  afterEach(() => vi.unstubAllGlobals());
  const ok = (body) => ({ ok: true, status: 200, json: async () => body });

  test('values travel only in PUT body; URL clean; no-store; credentials', async () => {
    fetchMock.mockResolvedValue(ok({ status: 'set' }));
    await savePayoutDetails('proof1', { routing_number: '021000021', account_number: '123456789', account_type: 'checking', holder_name: 'A B' });
    const [url, opts] = fetchMock.mock.calls[0];
    expect(opts.method).toBe('PUT');
    expect(opts.cache).toBe('no-store');
    expect(opts.credentials).toBe('include');
    expect(url).not.toMatch(/123456789|021000021|proof1/);
    expect(JSON.parse(opts.body)).toMatchObject({ proof: 'proof1', account_number: '123456789' });
  });
  test('GET has no body; verify omits password when absent', async () => {
    fetchMock.mockResolvedValue(ok({}));
    await getPayoutStatus();
    expect(fetchMock.mock.calls[0][1].body).toBeUndefined();
    await verifyPayoutCode('123456');
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ code: '123456' });
    await verifyPayoutCode('123456', 'pw');
    expect(JSON.parse(fetchMock.mock.calls[2][1].body)).toEqual({ code: '123456', password: 'pw' });
    await deletePayoutDetails('p');
    expect(fetchMock.mock.calls[3][0]).toMatch(/\/delete$/);
  });
  test('error carries only fixed code and status, not the response body or request values', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 422, json: async () => ({ detail: 'invalid_routing_number', input: '123456789' }) });
    const err = await savePayoutDetails('p', { account_number: '123456789' }).catch((e) => e);
    expect(err).toBeInstanceOf(PayoutsApiError);
    expect(err.code).toBe('invalid_routing_number');
    expect(JSON.stringify(err) + err.message).not.toMatch(/123456789/);
  });
  test('non-string detail (validation array) collapses to generic code', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 422, json: async () => ({ detail: [{ input: '123456789' }] }) });
    const err = await savePayoutDetails('p', {}).catch((e) => e);
    expect(err.code).toBe('error');
  });
  test('network failure and non-JSON body', async () => {
    fetchMock.mockRejectedValueOnce(new Error('boom 123456789'));
    const e1 = await getPayoutStatus().catch((e) => e);
    expect(e1.code).toBe('network'); expect(e1.message).not.toMatch(/123456789/);
    fetchMock.mockResolvedValueOnce({ ok: false, status: 500, json: async () => { throw new Error('x'); } });
    expect((await getPayoutStatus().catch((e) => e)).status).toBe(500);
  });
});
