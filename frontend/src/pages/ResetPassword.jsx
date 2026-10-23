import React, { useState } from 'react';
import { useLocation, Link } from 'react-router-dom';
import { API } from '../config.js';
import Seo from '../components/Seo.jsx';
import { AuthPage, Field, StickyActionBar } from '../components/forms/index.js';

export default function ResetPassword() {
  const location = useLocation();
  const token     = new URLSearchParams(location.search).get('token') || '';
  const [password, setPassword] = useState('');
  const [error,    setError]    = useState('');
  const [done,     setDone]     = useState(false);
  const [loading,  setLoading]  = useState(false);

  if (!token) {
    return (
      <>
        <Seo title="Reset Password — FellowScript" path="/reset-password" noindex />
        <AuthPage>
          <p className="ff-helper" style={{ fontSize: 14 }}>
            This reset link is missing its token. <Link to="/forgot-password" className="ff-link">Request a new one</Link>.
          </p>
        </AuthPage>
      </>
    );
  }

  const handleSubmit = async (e) => {
    e?.preventDefault?.();
    setError('');
    setLoading(true);
    try {
      const res  = await fetch(`${API}/auth/password-reset/confirm`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token, new_password: password }),
      });
      const data = await res.json();
      if (!res.ok) { setError(data.detail || 'This reset link is invalid or has expired.'); return; }
      setDone(true);
    } catch {
      setError('Could not reach the server.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <>
      <Seo
        title="Reset Password — FellowScript"
        description="Choose a new password for your FellowScript account."
        path="/reset-password"
        noindex
      />
      <AuthPage title="Reset password">
        {done ? (
          <>
            <div className="ff-info" role="status">
              <strong>Password updated.</strong> You've been signed out everywhere for security. Sign in with your new password.
            </div>
            <Link to="/signin" className="ff-btn ff-btn--primary ff-btn--block" style={{ textAlign: 'center', textDecoration: 'none', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>Go to sign in</Link>
          </>
        ) : (
          <form onSubmit={handleSubmit} noValidate className="ff-formstack">
            {error && <div className="ff-alert" role="alert"><div className="ff-alert__title">{error}</div></div>}
            <Field label="New password" required secure value={password} autoComplete="new-password" autoFocus onChange={setPassword} />
            <StickyActionBar variant="page" primaryType="submit" primaryLabel="Reset password" saving={loading} onPrimary={() => {}} />
          </form>
        )}
      </AuthPage>
    </>
  );
}
