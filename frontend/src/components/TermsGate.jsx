import React, { useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { useCapabilities } from '../hooks/useCapabilities.js';
import { acceptCurrentTerms } from '../lib/capabilities.js';
import { FormRoot } from './forms/index.js';
import { useFocusTrap } from '../hooks/useFocusTrap.js';

// Task 20261002-shared-foundation step 8 (contract 6.12). Presents the same
// "Our Terms of Service have been updated" gate SignIn.jsx and VerifyMfa.jsx
// show, for a user who is already signed in when the Terms version changes.
// Shown only when /app/capabilities answered terms_current === false; a
// missing or failing endpoint reads as "current", so users are never trapped.
export default function TermsGate() {
  const { user, signOut } = useAuth() || {};
  const { termsCurrent, refresh } = useCapabilities();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const open = !!user?.user_id && termsCurrent === false;
  const ref = useRef(null);
  useFocusTrap(open, ref);

  const accept = async () => {
    setLoading(true);
    setError('');
    try {
      await acceptCurrentTerms(user.user_id);
      await refresh();
    } catch (err) {
      setError(err?.message || "Couldn't save your agreement. Please try again.");
    } finally {
      setLoading(false);
    }
  };

  if (!open) return null;
  return (
    <FormRoot style={{ position: 'fixed', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(0,0,0,0.6)', zIndex: 1000, padding: 16 }}>
      <div ref={ref} className="ff-modal ff-modal--confirm" role="alertdialog" aria-modal="true" aria-labelledby="ff-tg-title" aria-describedby="ff-tg-body">
        <div className="ff-body">
          <h2 id="ff-tg-title" className="ff-title">Our Terms of Service have been updated</h2>
          <p id="ff-tg-body" className="ff-helper" style={{ fontSize: 14 }}>
            Please review our{' '}
            <Link to="/terms" target="_blank" style={{ color: 'var(--ff-gold)' }}>updated Terms of Service</Link>{' '}
            before continuing.
          </p>
          {error && <p role="alert" className="ff-error">{error}</p>}
        </div>
        <div className="ff-actions">
          <button type="button" className="ff-btn ff-btn--secondary" onClick={signOut} disabled={loading}>Sign out</button>
          <button type="button" className="ff-btn ff-btn--primary" aria-disabled={loading || undefined} autoFocus
            onClick={() => { if (!loading) accept(); }}>{loading ? 'Saving…' : 'I Agree'}</button>
        </div>
      </div>
    </FormRoot>
  );
}
