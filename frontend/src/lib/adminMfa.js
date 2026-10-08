// Admin 2FA enforcement (task 20261008-admin-require-2fa).
//
// The server's `require_admin` answers 403 with a structured detail
// `{ code: 'mfa_required', message }` when an admin account has two-factor
// authentication off. That is distinct from the plain-string 403 a non-admin
// gets. The client reacts by ending the session, showing a notice on sign-in,
// and after the next sign-in sending the admin to Account to turn 2FA on.
export const MFA_REQUIRED_CODE = 'mfa_required';
const FLAG_KEY = 'fs_admin_mfa_required';

export function isMfaRequiredDetail(detail) {
  return !!detail && typeof detail === 'object' && detail.code === MFA_REQUIRED_CODE;
}

// True when a non-ok fetch Response is the admin mfa_required 403. Reads a
// clone so the caller can still consume the original body.
export async function isMfaRequiredResponse(res) {
  if (!res || res.status !== 403) return false;
  try {
    const d = await res.clone().json();
    return isMfaRequiredDetail(d?.detail);
  } catch {
    return false;
  }
}

// True when an admin API error (status + code) is the mfa_required 403.
export function isMfaRequiredError(err) {
  return !!err && err.status === 403 && err.code === MFA_REQUIRED_CODE;
}

export function setMfaRequiredFlag() {
  try { sessionStorage.setItem(FLAG_KEY, '1'); } catch { /* storage unavailable */ }
}
export function hasMfaRequiredFlag() {
  try { return sessionStorage.getItem(FLAG_KEY) === '1'; } catch { return false; }
}
export function clearMfaRequiredFlag() {
  try { sessionStorage.removeItem(FLAG_KEY); } catch { /* storage unavailable */ }
}

// Where to land after sign-in when the admin was bounced for missing 2FA.
export const MFA_SETUP_PATH = '/account';
export const MFA_NOTICE_TEXT =
  'Two-factor authentication is required for admin accounts. Sign in, then turn it on in your account settings to regain admin access.';
