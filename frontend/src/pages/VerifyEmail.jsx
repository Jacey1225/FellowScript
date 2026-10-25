// Task 20261007-email-verification. Landing page for the emailed link
// (/#/verify-email?token=...). The token is consumed by a POST on load (mail
// scanners that only GET the link cannot burn it). Every failure shows the same
// message. The token is stripped from the address bar after the attempt.
import React, { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate, Link } from 'react-router-dom';
import { useWarmCanvas } from '../hooks/useWarmCanvas.js';
import { AuthPage } from '../components/forms/index.js';
import Seo from '../components/Seo.jsx';
import { verifyEmailToken } from '../lib/emailVerificationApi.js';

export default function VerifyEmail() {
  useWarmCanvas(); // same warm gradient canvas as sign-in
  const location = useLocation();
  const navigate = useNavigate();
  const token = new URLSearchParams(location.search).get('token') || '';
  const [phase, setPhase] = useState(token ? 'loading' : 'invalid'); // loading | done | invalid
  const started = useRef(false);

  useEffect(() => {
    if (!token || started.current) return;
    started.current = true; // StrictMode / re-render must not spend the token twice
    verifyEmailToken(token)
      .then(() => setPhase('done'))
      .catch(() => setPhase('invalid'))
      .finally(() => navigate('/verify-email', { replace: true }));
  }, [token, navigate]);

  return (
    <>
      <Seo title="Verify Email — FellowScript" path="/verify-email" noindex />
      <AuthPage title="Verify email">
        {phase === 'loading' && <div className="ff-center" role="status">Verifying…</div>}
        {phase === 'done' && (
          <>
            <div className="ff-info" role="status"><strong>Email verified</strong><div className="ff-helper">Thanks, your email address is confirmed.</div></div>
            <Link to="/account" className="ff-btn ff-btn--primary ff-btn--block" style={{ textAlign: 'center', textDecoration: 'none', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>Continue to your account</Link>
          </>
        )}
        {phase === 'invalid' && (
          <>
            <div className="ff-alert" role="alert">
              <div className="ff-alert__title">This verification link is invalid or has expired.</div>
              <div className="ff-helper">Sign in and request a new verification email from your account page.</div>
            </div>
            <Link to="/account" className="ff-btn ff-btn--primary ff-btn--block" style={{ textAlign: 'center', textDecoration: 'none', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>Go to your account</Link>
          </>
        )}
      </AuthPage>
    </>
  );
}
