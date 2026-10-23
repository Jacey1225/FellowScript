import React, { useRef, useState } from 'react';
import { API } from '../../config.js';
import { useFocusTrap } from '../../hooks/useFocusTrap.js';
import { Field } from './Field.jsx';
import { FormRoot, StickyActionBar } from './Layout.jsx';
import { CodeField } from './AuthPage.jsx';

// Tier-3 typed confirm (SX3) then password re-auth (SX2). The server's DELETE
// takes no password, so the password (and emailed code when 2FA is on) is
// verified against the login endpoints first; the delete only runs after that.
export function DeleteAccountDialog({ open, username, userId, onClose, onDeleted, onError }) {
  const ref = useRef(null);
  useFocusTrap(open, ref);
  const [typed, setTyped] = useState('');
  const [step, setStep] = useState('confirm');
  const [password, setPassword] = useState('');
  const [code, setCode] = useState('');
  const [mfaUserId, setMfaUserId] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  if (!open) return null;
  const matches = typed.trim().toLowerCase() === (username || '').toLowerCase() && !!username;

  const close = () => { setTyped(''); setStep('confirm'); setPassword(''); setCode(''); setMfaUserId(null); setError(''); onClose(); };

  const verifyAndDelete = async (e) => {
    e?.preventDefault?.();
    if (!password || busy) return;
    setBusy(true); setError('');
    try {
      const url = mfaUserId ? `${API}/auth/mfa/verify-login` : `${API}/login`;
      const body = mfaUserId ? { user_id: mfaUserId, code: code.trim() } : { username, plain_pass: password };
      const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { setError(mfaUserId ? 'That code did not match.' : 'That password did not match.'); return; }
      if (data.mfa_required) { setMfaUserId(data.user_id); return; }
      const del = await fetch(`${API}/user/${userId}`, { method: 'DELETE' });
      if (del.ok || del.status === 204) { setPassword(''); onDeleted(); return; }
      onError('Delete failed. Please try again.'); close();
    } catch {
      setError('Could not reach the server.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <FormRoot style={{ position: 'fixed', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(0,0,0,0.6)', zIndex: 1000, padding: 16 }}>
      <div ref={ref} className="ff-modal ff-modal--confirm" role="alertdialog" aria-modal="true" aria-labelledby="ff-del-title"
        onKeyDown={(e) => { if (e.key === 'Escape') close(); }}>
        {step === 'confirm' ? (
          <>
            <div className="ff-body">
              <h2 id="ff-del-title" className="ff-title">Delete account</h2>
              <ul className="ff-helper" style={{ fontSize: 14, margin: 0, paddingLeft: 18 }}>
                <li>Your account and profile</li>
                <li>All notes and highlights</li>
                <li>Your group memberships and friend list</li>
              </ul>
              <p className="ff-helper" style={{ margin: 0 }}>This cannot be undone.</p>
              <Field label="Type your username to confirm" value={typed} onChange={setTyped} placeholder={username}
                autoComplete="off" autoCapitalize="none" spellCheck={false} autoFocus />
            </div>
            <div className="ff-actions">
              <button type="button" className="ff-btn ff-btn--secondary" onClick={close}>Cancel</button>
              <button type="button" className="ff-btn ff-btn--danger" aria-disabled={!matches || undefined}
                onClick={() => { if (matches) setStep('reauth'); }}>Delete my account</button>
            </div>
          </>
        ) : (
          <form onSubmit={verifyAndDelete} noValidate>
            <div className="ff-body">
              <h2 id="ff-del-title" className="ff-title">Confirm it's you</h2>
              <p className="ff-helper" style={{ fontSize: 14, margin: 0 }}>Enter your current password to delete your account.</p>
              <Field label="Current password" required secure value={password} onChange={setPassword} error={mfaUserId ? null : (error || null)}
                autoComplete="current-password" autoFocus />
              {mfaUserId && <CodeField label="Verification code" value={code} onChange={setCode} error={error || null} />}
            </div>
            <div className="ff-actions">
              <button type="button" className="ff-btn ff-btn--secondary" onClick={close}>Cancel</button>
              <button type="submit" className="ff-btn ff-btn--danger" aria-disabled={(!password || busy) || undefined}>{busy ? 'Deleting…' : 'Delete my account'}</button>
            </div>
          </form>
        )}
      </div>
    </FormRoot>
  );
}
