// Task 20261008-affiliate-payout-details. Client for /affiliates/payouts.
// Hygiene: values only ever travel in the JSON body of PUT; never in URLs, storage,
// logs, or error text. Errors carry only a fixed server code + HTTP status.
import { API } from '../config.js';

export class PayoutsApiError extends Error {
  constructor(code, status) {
    super(code || 'error');
    this.name = 'PayoutsApiError';
    this.code = code || 'error';
    this.status = status;
  }
}

async function call(method, path, body) {
  let res;
  try {
    res = await fetch(`${API}/affiliates/payouts${path}`, {
      method,
      credentials: 'include',
      cache: 'no-store',
      headers: body === undefined ? undefined : { 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new PayoutsApiError('network', 0);
  }
  let json = null;
  try { json = await res.json(); } catch { /* empty or non-JSON body */ }
  if (!res.ok) {
    const code = json && typeof json.detail === 'string' ? json.detail : 'error';
    throw new PayoutsApiError(code, res.status);
  }
  return json || {};
}

export const getPayoutStatus = () => call('GET', '');
export const requestPayoutCode = () => call('POST', '/reauth');
export const verifyPayoutCode = (code, password) =>
  call('POST', '/reauth/verify', password ? { code, password } : { code });
export const savePayoutDetails = (proof, fields) => call('PUT', '', { proof, ...fields });
export const deletePayoutDetails = (proof) => call('POST', '/delete', { proof });

// Client mirror of the server rules, for UX only (server is authoritative).
export function abaValid(r) {
  if (!/^[0-9]{9}$/.test(r)) return false;
  const d = [...r].map(Number);
  return (3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])) % 10 === 0;
}
export function validatePayoutFields(f) {
  const errs = {};
  if (!abaValid(f.routing_number)) errs.routing_number = 'Enter a valid 9-digit routing number.';
  if (!/^[0-9]{4,17}$/.test(f.account_number)) errs.account_number = 'Account number must be 4 to 17 digits.';
  if (f.account_number !== f.account_confirm) errs.account_confirm = 'Account numbers do not match.';
  if (!['checking', 'savings'].includes(f.account_type)) errs.account_type = 'Choose checking or savings.';
  const h = f.holder_name.trim();
  if (h.length < 2 || h.length > 100 || !/^[\p{L}\p{M} '.-]+$/u.test(h)) errs.holder_name = 'Enter the account holder name (letters only, 2 to 100 characters).';
  return errs;
}

const MESSAGES = {
  invalid_routing_number: 'That routing number is not valid.',
  invalid_account_number: 'That account number is not valid.',
  invalid_account_type: 'Choose checking or savings.',
  invalid_holder_name: 'That account holder name is not valid.',
  reauth_failed: 'That code or password was not accepted.',
  reauth_required: 'Your verification expired. Please verify again.',
  locked: 'Too many attempts. Try again later.',
  rate_limited: 'Too many requests. Try again later.',
  email_failed: "We couldn't send the code. Try again.",
};
export const payoutErrorMessage = (err) =>
  (err && MESSAGES[err.code]) || 'Something went wrong. Please try again.';
