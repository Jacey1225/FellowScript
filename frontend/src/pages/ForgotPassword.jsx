import React, { useState } from 'react';
import { Link } from 'react-router-dom';
import { API } from '../config.js';
import Seo from '../components/Seo.jsx';
import { AuthPage, Field, StickyActionBar } from '../components/forms/index.js';

export default function ForgotPassword() {
  const [email,   setEmail]   = useState('');
  const [error,   setError]   = useState('');
  const [sent,    setSent]    = useState(false);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e?.preventDefault?.();
    setError('');
    setLoading(true);
    try {
      const res = await fetch(`${API}/auth/password-reset/request`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: email.trim() }),
      });
      // The backend always returns the same generic response whether or not
      // the email has an account — never branch UI on that distinction here.
      if (res.ok || res.status === 202) { setSent(true); return; }
      const data = await res.json().catch(() => ({}));
      setError(data.detail || 'Something went wrong. Please try again.');
    } catch {
      setError('Could not reach the server.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <>
      <Seo
        title="Forgot Password — FellowScript"
        description="Reset the password for your FellowScript account."
        path="/forgot-password"
        noindex
      />
      <AuthPage
        title={sent ? 'Check your email' : 'Forgot password'}
        subtitle={sent ? null : "Enter your account email and we'll send a reset link."}
        footer={<div className="ff-link-row"><Link to="/signin" className="ff-link">Back to sign in</Link></div>}
      >
        {sent ? (
          <div className="ff-info" role="status">
            If an account with that email exists, a password reset link has been sent. It expires in 30 minutes.
          </div>
        ) : (
          <form onSubmit={handleSubmit} noValidate className="ff-formstack">
            {error && <div className="ff-alert" role="alert"><div className="ff-alert__title">{error}</div></div>}
            <Field label="Email" required type="email" placeholder="you@example.com" value={email}
              autoComplete="email" autoCapitalize="none" spellCheck={false} autoFocus onChange={setEmail} />
            <StickyActionBar variant="page" primaryType="submit" primaryLabel="Send reset link" saving={loading} onPrimary={() => {}} />
          </form>
        )}
      </AuthPage>
    </>
  );
}
