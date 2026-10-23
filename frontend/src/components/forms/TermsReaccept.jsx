import React from 'react';
import { Link } from 'react-router-dom';
import { FormRoot } from './Layout.jsx';
import { useFocusTrap } from '../../hooks/useFocusTrap.js';

// Blocking "Terms have been updated" re-consent gate (type H, consent). One primary only.
export function TermsReaccept({ open, loading, onAgree }) {
  const ref = React.useRef(null);
  useFocusTrap(open, ref);
  if (!open) return null;
  return (
    <FormRoot style={{ position: 'fixed', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(0,0,0,0.6)', zIndex: 1000, padding: 16 }}>
      <div ref={ref} className="ff-modal ff-modal--confirm" role="alertdialog" aria-modal="true" aria-labelledby="ff-terms-title" aria-describedby="ff-terms-body">
        <div className="ff-body">
          <h2 id="ff-terms-title" className="ff-title">Our Terms of Service have been updated</h2>
          <p id="ff-terms-body" className="ff-helper" style={{ fontSize: 14 }}>
            We've clarified our zero-tolerance policy for objectionable content and abusive behavior, including new
            in-app reporting and blocking tools. Please review our{' '}
            <Link to="/terms" target="_blank" style={{ color: 'var(--ff-gold)' }}>updated Terms of Service</Link>{' '}
            before continuing.
          </p>
        </div>
        <div className="ff-actions">
          <button type="button" className="ff-btn ff-btn--primary ff-btn--block" aria-disabled={loading || undefined} autoFocus
            onClick={() => { if (!loading) onAgree(); }}>
            {loading ? 'Saving…' : 'I Agree'}
          </button>
        </div>
      </div>
    </FormRoot>
  );
}
