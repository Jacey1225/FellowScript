import React, { useState } from 'react';
import { useNavigate, useLocation, Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { API } from '../config.js';
import Seo from '../components/Seo.jsx';
import { postAuthPath } from '../lib/pendingInvite.js';
import { AuthPage, CodeField, StickyActionBar, TermsReaccept } from '../components/forms/index.js';

export default function VerifyMfa() {
  const { signIn } = useAuth();
  const navigate    = useNavigate();
  const location    = useLocation();
  const userId      = location.state?.user_id;
  const [code,    setCode]    = useState('');
  const [error,   setError]   = useState('');
  const [loading, setLoading] = useState(false);
  const [reaccept, setReaccept] = useState(null);
  const [reacceptLoading, setReacceptLoading] = useState(false);

  const handleAcceptUpdatedTerms = async () => {
    setReacceptLoading(true);
    try {
      await fetch(`${API}/user/${reaccept.user_id}/accept-terms`, { method: 'POST' });
    } finally {
      setReacceptLoading(false);
      signIn(reaccept);
      setReaccept(null);
      navigate(postAuthPath());
    }
  };

  if (!userId) {
    return (
      <>
        <Seo title="Verify Sign-In — FellowScript" path="/verify-2fa" noindex />
        <AuthPage>
          <p className="ff-helper" style={{ fontSize: 14 }}>
            No sign-in in progress. <Link to="/signin" className="ff-link">Return to sign in</Link>.
          </p>
        </AuthPage>
      </>
    );
  }

  const handleVerify = async (e) => {
    e?.preventDefault?.();
    setError('');
    setLoading(true);
    try {
      const res  = await fetch(`${API}/auth/mfa/verify-login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ user_id: userId, code: code.trim() }),
      });
      const data = await res.json();
      if (!res.ok) { setError(data.detail || 'Invalid or expired code.'); return; }
      if (data.terms_reaccept_required) { setReaccept(data); return; }
      signIn(data);
      navigate(postAuthPath());
    } catch {
      setError('Could not reach the server.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <>
      <Seo
        title="Verify Sign-In — FellowScript"
        description="Confirm your identity to finish signing in to FellowScript."
        path="/verify-2fa"
        noindex
      />
      <AuthPage
        title="Verify it's you"
        subtitle="We emailed a 6-digit code to finish signing in."
        footer={<div className="ff-link-row"><Link to="/signin" className="ff-link">Back to sign in</Link></div>}
      >
        <form onSubmit={handleVerify} noValidate className="ff-formstack">
          {error && <div className="ff-alert" role="alert"><div className="ff-alert__title">{error}</div></div>}
          <CodeField label="Verification code" value={code} onChange={setCode} autoFocus />
          <StickyActionBar variant="page" primaryType="submit" primaryLabel="Verify" primaryDisabled={!code} saving={loading} onPrimary={() => {}} />
        </form>
      </AuthPage>
      <TermsReaccept open={!!reaccept} loading={reacceptLoading} onAgree={handleAcceptUpdatedTerms} />
    </>
  );
}
