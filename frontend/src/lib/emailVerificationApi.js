// Task 20261007-email-verification. Thin client for api/routes/email_verification.py.
// Every function throws EmailVerificationApiError (with `.status`) on a non-2xx
// or network failure (throw-not-fabricate). The server derives the address from
// the session; nothing here ever sends an email address. 404 = feature off.
import { API } from '../config.js';

export class EmailVerificationApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'EmailVerificationApiError';
    this.status = status;
  }
}

async function call(path, init, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, { credentials: 'include', ...init });
  } catch {
    throw new EmailVerificationApiError('Could not reach the server.', 0);
  }
  if (!res || !res.ok) throw new EmailVerificationApiError(fallback, res ? res.status : 0);
  return res.json();
}

// -> { enabled, verified, resend_cooldown_seconds? }
export function getEmailStatus() {
  return call('/auth/email/status', {}, "Couldn't check your email status.");
}

// -> { detail, resend_cooldown_seconds }. Uniform 202 whether or not a mail went out.
export function resendVerification() {
  return call('/auth/email/resend', { method: 'POST' }, "Couldn't send the email. Try again shortly.");
}

// -> { verified: true }. Any failure (unknown, expired, reused) is one error.
export function verifyEmailToken(token) {
  return call('/auth/email/verify', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token }),
  }, 'This verification link is invalid or has expired.');
}
