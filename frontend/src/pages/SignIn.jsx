import React, { useState, useEffect } from 'react';
import { useNavigate, useLocation, Link } from 'react-router-dom';
import { AuthPage, Field, Segmented, FormErrorSummary, StickyActionBar, TermsReaccept } from '../components/forms/index.js';
import { useAuth } from '../context/AuthContext.jsx';
import { isDesktopApp } from '../lib/desktopScope.js';
import { API } from '../config.js';
import Seo from '../components/Seo.jsx';
import { useWarmCanvas } from '../hooks/useWarmCanvas.js';
import { postAuthPath } from '../lib/pendingInvite.js';
import { hasMfaRequiredFlag, clearMfaRequiredFlag, MFA_SETUP_PATH, MFA_NOTICE_TEXT } from '../lib/adminMfa.js';

const GOOGLE_CLIENT_ID = '667477247503-plvi16hhr4gpigqudkpsc3epsu6edbgq.apps.googleusercontent.com';

function nonce() {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)))
    .map(b => b.toString(16).padStart(2, '0')).join('');
}

export default function SignIn() {
  useWarmCanvas();
  const { signIn } = useAuth();
  const navigate   = useNavigate();
  const location   = useLocation();
  // /privacy and /terms aren't on the desktop allowlist (task
  // 20260906-desktop-scope-lockdown). Unlike AppNav/Account.jsx's purely
  // navigational Privacy/Terms links, the ones below are woven into
  // required consent disclosure text, so they're forced external
  // (mirroring the target="_blank" Terms links already used elsewhere in
  // this file) rather than hidden, keeping the disclosure intact while
  // routing through the existing https-only on_new_window handoff instead
  // of an in-app SPA navigation.
  const desktopApp = isDesktopApp();
  const [siVals, setSiVals] = useState({ username: '', password: '' });
  const [suVals, setSuVals] = useState({ username: '', email: '', password: '' });
  const [siErrs, setSiErrs] = useState({});
  const [suErrs, setSuErrs] = useState({});
  const [siError,  setSiError]  = useState('');
  const [suError,  setSuError]  = useState('');
  const [siLoading, setSiLoading] = useState(false);
  const [suLoading, setSuLoading] = useState(false);
  const [googleError,   setGoogleError]   = useState('');
  const [googleLoading, setGoogleLoading] = useState(false);
  const [activeTab,     setActiveTab]     = useState(location.state?.tab === 'signup' ? 'signup' : 'signin');
  const [termsAccepted, setTermsAccepted] = useState(false);
  // Holds the auth response while a "Terms have been updated" re-consent gate
  // is shown, so we can finish signing the user in once they accept.
  const [reaccept, setReaccept] = useState(null);
  const [reacceptLoading, setReacceptLoading] = useState(false);

  // Finalizes a successful /login, /signup, or /auth/google response: if the
  // account predates a material Terms change, pause on a blocking re-consent
  // screen instead of immediately signing in.
  const finishAuth = (data) => {
    if (data.terms_reaccept_required) {
      setReaccept(data);
      return;
    }
    signIn(data);
    goAfterAuth();
  };

  // An admin bounced for missing 2FA lands on Account (to turn it on) after
  // signing back in; everyone else follows the normal post-auth path.
  const goAfterAuth = () => {
    if (hasMfaRequiredFlag()) {
      clearMfaRequiredFlag();
      navigate(MFA_SETUP_PATH, { state: { setup2fa: true } });
      return;
    }
    navigate(postAuthPath());
  };

  const handleAcceptUpdatedTerms = async () => {
    setReacceptLoading(true);
    try {
      await fetch(`${API}/user/${reaccept.user_id}/accept-terms`, { method: 'POST' });
    } catch {
      // Session cookie is already set server-side regardless — proceed either way
      // rather than stranding the user on this screen over a network blip.
    } finally {
      setReacceptLoading(false);
      signIn(reaccept);
      setReaccept(null);
      goAfterAuth();
    }
  };

  // Finish Google sign-in. main.jsx stashes the id_token before HashRouter can
  // swallow the redirect fragment, so read that first (falling back to the hash).
  useEffect(() => {
    const stashedToken = sessionStorage.getItem('pending_google_id_token');
    const stashedError = sessionStorage.getItem('pending_google_error');
    // Google's redirect is a full page navigation, so any in-memory React
    // state (the EULA checkbox) is gone by the time we land back here —
    // stash it alongside the id_token and read it back the same way.
    const stashedTerms = sessionStorage.getItem('pending_google_terms_accepted') === 'true';
    sessionStorage.removeItem('pending_google_id_token');
    sessionStorage.removeItem('pending_google_error');
    sessionStorage.removeItem('pending_google_terms_accepted');

    const params  = new URLSearchParams(window.location.hash.slice(1));
    const idToken = stashedToken || params.get('id_token');
    const error   = stashedError || params.get('error');
    if (error) {
      setGoogleError('Google sign-in was cancelled or denied.');
      return;
    }
    if (!idToken) return;
    (async () => {
      setGoogleLoading(true);
      try {
        const res  = await fetch(`${API}/auth/google`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ credential: idToken, terms_accepted: stashedTerms }),
        });
        const data = await res.json();
        if (!res.ok) { setGoogleError(data.detail || 'Google sign-in failed.'); return; }
        finishAuth(data);
      } catch {
        setGoogleError('Could not reach the server.');
      } finally {
        setGoogleLoading(false);
      }
    })();
  }, []);

  const handleGoogleClick = () => {
    // Never gate this on the EULA checkbox — Google sign-in must always be
    // available with the same ease as other options (the same reasoning
    // Guideline 4.8 applies to Sign in with Apple on iOS). If the account is
    // new and terms weren't accepted yet, the server creates it anyway and
    // signals terms_reaccept_required so finishAuth() prompts for consent
    // right after, instead of this click silently failing.
    sessionStorage.setItem('pending_google_terms_accepted', String(termsAccepted));
    const redirectUri = window.location.origin + window.location.pathname;
    const params = new URLSearchParams({
      client_id:     GOOGLE_CLIENT_ID,
      redirect_uri:  redirectUri,
      response_type: 'id_token',
      scope:         'openid email profile',
      nonce:         nonce(),
      prompt:        'select_account',
    });
    window.location.href = `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
  };

  const handleSignin = async (e) => {
    e?.preventDefault?.();
    setSiError('');
    const errs = {};
    if (!siVals.username.trim()) errs.username = 'Username required';
    if (!siVals.password) errs.password = 'Password required';
    setSiErrs(errs);
    if (Object.keys(errs).length) { document.getElementById(`si-${Object.keys(errs)[0]}`)?.focus(); return; }
    setSiLoading(true);
    try {
      const res  = await fetch(`${API}/login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: siVals.username.trim(), plain_pass: siVals.password }),
      });
      const data = await res.json();
      if (!res.ok) { setSiError(data.detail || 'Sign in failed.'); return; }
      if (data.mfa_required) {
        navigate('/verify-2fa', { state: { user_id: data.user_id } });
        return;
      }
      finishAuth(data);
    } catch {
      setSiError('Could not reach the server.');
    } finally {
      setSiLoading(false);
    }
  };

  const handleSignup = async (e) => {
    e?.preventDefault?.();
    setSuError('');
    const errs = {};
    if (!suVals.username.trim()) errs.username = 'Add a username.';
    if (!/^\S+@\S+\.\S+$/.test(suVals.email.trim())) errs.email = 'Enter a valid email.';
    if (suVals.password.length < 6) errs.password = 'Use at least 6 characters.';
    setSuErrs(errs);
    if (Object.keys(errs).length) { document.getElementById(`su-${Object.keys(errs)[0]}`)?.focus(); return; }
    if (!termsAccepted) {
      setSuError('You must agree to the Terms of Service to create an account.');
      return;
    }
    setSuLoading(true);
    try {
      const res  = await fetch(`${API}/signup`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: suVals.username.trim(), email: suVals.email.trim(), plain_pass: suVals.password,
          terms_accepted: termsAccepted,
        }),
      });
      const data = await res.json();
      if (!res.ok) { setSuError(data.detail || 'Sign up failed.'); return; }
      localStorage.setItem('fs_tour', 'reader');
      finishAuth(data);
    } catch {
      setSuError('Could not reach the server.');
    } finally {
      setSuLoading(false);
    }
  };

  const GoogleG = (
    <svg width="18" height="18" viewBox="0 0 18 18" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <g fill="none" fillRule="evenodd">
        <path d="M17.64 9.205c0-.639-.057-1.252-.164-1.841H9v3.481h4.844a4.14 4.14 0 0 1-1.796 2.716v2.259h2.908c1.702-1.567 2.684-3.875 2.684-6.615z" fill="#4285F4"/>
        <path d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 0 0 9 18z" fill="#34A853"/>
        <path d="M3.964 10.71A5.41 5.41 0 0 1 3.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 0 0 0 9c0 1.452.348 2.827.957 4.042l3.007-2.332z" fill="#FBBC05"/>
        <path d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 0 0 .957 4.958L3.964 7.29C4.672 5.163 6.656 3.58 9 3.58z" fill="#EA4335"/>
      </g>
    </svg>
  );

  const isSignin = activeTab === 'signin';
  const formErrors = (errs, prefix, names) => Object.keys(errs).map((k) => ({ id: `${prefix}-${k}`, name: names[k] }));

  return (
    <>
      <Seo
        title="Sign In — FellowScript"
        description="Sign in or create a FellowScript account to start your daily Bible reading rhythm."
        path="/signin"
        noindex
      />
      <AuthPage
        footer={(
          <>
            <p className="ff-legal">
              By creating an account, you agree to our{' '}
              <Link to="/terms" target={desktopApp ? '_blank' : undefined} rel={desktopApp ? 'noopener noreferrer' : undefined}>Terms of Service</Link>
              {' '}and{' '}
              <Link to="/privacy" target={desktopApp ? '_blank' : undefined} rel={desktopApp ? 'noopener noreferrer' : undefined}>Privacy Policy</Link>.
            </p>
          </>
        )}
      >
        <Segmented label="Account" value={activeTab} onChange={setActiveTab}
          options={[{ value: 'signin', label: 'Sign In' }, { value: 'signup', label: 'Create Account' }]} />

        {isSignin ? (
          <form onSubmit={handleSignin} noValidate className="ff-formstack">
            {location.state?.mfaRequired && <div className="ff-info" role="status">{MFA_NOTICE_TEXT}</div>}
            {siError && <div className="ff-alert" role="alert"><div className="ff-alert__title">{siError}</div></div>}
            <FormErrorSummary items={formErrors(siErrs, 'si', { username: 'Username', password: 'Password' })}
              onSelect={(id) => document.getElementById(id)?.focus()} />
            <Field id="si-username" label="Username" required value={siVals.username} error={siErrs.username}
              autoComplete="username" autoCapitalize="none" spellCheck={false}
              onChange={(v) => { setSiVals((p) => ({ ...p, username: v })); if (siErrs.username) setSiErrs((p) => ({ ...p, username: undefined })); }} />
            <Field id="si-password" label="Password" required secure value={siVals.password} error={siErrs.password}
              autoComplete="current-password"
              onChange={(v) => { setSiVals((p) => ({ ...p, password: v })); if (siErrs.password) setSiErrs((p) => ({ ...p, password: undefined })); }} />
            <div className="ff-link-row"><Link to="/forgot-password" className="ff-link">Forgot password?</Link></div>
            <StickyActionBar variant="page" primaryType="submit" primaryLabel="Sign In" saving={siLoading} onPrimary={() => {}} />
          </form>
        ) : (
          <form onSubmit={handleSignup} noValidate className="ff-formstack">
            {suError && <div className="ff-alert" role="alert"><div className="ff-alert__title">{suError}</div></div>}
            <FormErrorSummary items={formErrors(suErrs, 'su', { username: 'Username', email: 'Email', password: 'Password' })}
              onSelect={(id) => document.getElementById(id)?.focus()} />
            <Field id="su-username" label="Username" required value={suVals.username} error={suErrs.username}
              autoComplete="username" autoCapitalize="none" spellCheck={false}
              onChange={(v) => { setSuVals((p) => ({ ...p, username: v })); if (suErrs.username) setSuErrs((p) => ({ ...p, username: undefined })); }} />
            <Field id="su-email" label="Email" required type="email" value={suVals.email} error={suErrs.email}
              autoComplete="email" autoCapitalize="none" spellCheck={false}
              onChange={(v) => { setSuVals((p) => ({ ...p, email: v })); if (suErrs.email) setSuErrs((p) => ({ ...p, email: undefined })); }} />
            <Field id="su-password" label="Password" required secure value={suVals.password} error={suErrs.password}
              helper="At least 6 characters." autoComplete="new-password"
              onChange={(v) => { setSuVals((p) => ({ ...p, password: v })); if (suErrs.password) setSuErrs((p) => ({ ...p, password: undefined })); }} />
            <label className="ff-check">
              <input type="checkbox" checked={termsAccepted} onChange={(e) => setTermsAccepted(e.target.checked)} />
              <span>
                I agree to the{' '}
                <Link to="/terms" target="_blank" className="ff-link" style={{ fontSize: 12 }}>Terms of Service</Link>
                {', including its zero-tolerance policy for objectionable content and abusive behavior.'}
              </span>
            </label>
            <StickyActionBar variant="page" primaryType="submit" primaryLabel="Create Account" saving={suLoading} onPrimary={() => {}} />
          </form>
        )}

        {/* Google Sign-In: below both tabs */}
        <div className="ff-or" aria-hidden="true">or</div>
        {googleError && <div className="ff-alert" role="alert"><div className="ff-alert__title">{googleError}</div></div>}
        <button type="button" className="ff-social" onClick={handleGoogleClick} disabled={googleLoading}>
          {googleLoading ? <span>Signing in…</span> : (<>{GoogleG}Continue with Google</>)}
        </button>
      </AuthPage>

      <TermsReaccept open={!!reaccept} loading={reacceptLoading} onAgree={handleAcceptUpdatedTerms} />
    </>
  );
}
