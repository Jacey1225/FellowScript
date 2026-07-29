import React, { useState, useEffect } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { Card, Form, Input, Button, Typography, Tabs, Alert, Checkbox, Modal } from 'antd';
import { UserOutlined, LockOutlined, MailOutlined } from '@ant-design/icons';
import { useAuth } from '../context/AuthContext.jsx';
import { API } from '../config.js';

const { Title, Text } = Typography;

const GOOGLE_CLIENT_ID = '667477247503-plvi16hhr4gpigqudkpsc3epsu6edbgq.apps.googleusercontent.com';

function nonce() {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)))
    .map(b => b.toString(16).padStart(2, '0')).join('');
}

export default function SignIn() {
  const { signIn } = useAuth();
  const navigate   = useNavigate();
  const [siForm]   = Form.useForm();
  const [suForm]   = Form.useForm();
  const [siError,  setSiError]  = useState('');
  const [suError,  setSuError]  = useState('');
  const [siLoading, setSiLoading] = useState(false);
  const [suLoading, setSuLoading] = useState(false);
  const [googleError,   setGoogleError]   = useState('');
  const [googleLoading, setGoogleLoading] = useState(false);
  const [activeTab,     setActiveTab]     = useState('signin');
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
    navigate('/reader');
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
      navigate('/reader');
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

  const handleSignin = async (vals) => {
    setSiError('');
    setSiLoading(true);
    try {
      const res  = await fetch(`${API}/login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: vals.username.trim(), plain_pass: vals.password }),
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

  const handleSignup = async (vals) => {
    setSuError('');
    if (!termsAccepted) {
      setSuError('You must agree to the Terms of Service to create an account.');
      return;
    }
    setSuLoading(true);
    try {
      const res  = await fetch(`${API}/signup`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: vals.username.trim(), email: vals.email.trim(), plain_pass: vals.password,
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

  const tabs = [
    {
      key: 'signin',
      label: 'Sign In',
      children: (
        <Form form={siForm} layout="vertical" onFinish={handleSignin} style={{ marginTop: 8 }}>
          {siError && <Alert message={siError} type="error" showIcon style={{ marginBottom: 16 }} />}
          <Form.Item name="username" rules={[{ required: true, message: 'Username required' }]}>
            <Input prefix={<UserOutlined />} placeholder="Username" />
          </Form.Item>
          <Form.Item name="password" rules={[{ required: true, message: 'Password required' }]}>
            <Input.Password prefix={<LockOutlined />} placeholder="Password" />
          </Form.Item>
          <div style={{ textAlign: 'right', marginTop: -8, marginBottom: 16 }}>
            <Link to="/forgot-password" style={{ fontSize: 12, color: 'rgba(200,134,26,0.65)' }}>
              Forgot password?
            </Link>
          </div>
          <Button type="primary" htmlType="submit" loading={siLoading} block>Sign In</Button>
        </Form>
      ),
    },
    {
      key: 'signup',
      label: 'Create Account',
      children: (
        <Form form={suForm} layout="vertical" onFinish={handleSignup} style={{ marginTop: 8 }}>
          {suError && <Alert message={suError} type="error" showIcon style={{ marginBottom: 16 }} />}
          <Form.Item name="username" rules={[{ required: true }]}>
            <Input prefix={<UserOutlined />} placeholder="Username" />
          </Form.Item>
          <Form.Item name="email" rules={[{ required: true, type: 'email' }]}>
            <Input prefix={<MailOutlined />} placeholder="Email" />
          </Form.Item>
          <Form.Item name="password" rules={[{ required: true, min: 6 }]}>
            <Input.Password prefix={<LockOutlined />} placeholder="Password" />
          </Form.Item>
          <Button type="primary" htmlType="submit" loading={suLoading} block>Create Account</Button>
        </Form>
      ),
    },
  ];

  return (
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '2rem' }}>
      <Card style={{ width: '100%', maxWidth: 420, background: 'rgba(10,6,2,0.88)', border: '1px solid rgba(200,134,26,0.2)', backdropFilter: 'blur(12px)' }}>
        <div style={{ textAlign: 'center', marginBottom: '1.5rem' }}>
          <Title level={3} style={{ margin: 0, fontFamily: "'Playfair Display', serif" }}>
            <span style={{ color: 'var(--parchment)' }}>Fellow</span>
            <em style={{ color: 'var(--gold)' }}>Script</em>
          </Title>
          <div style={{ width: 40, height: 1, background: 'rgba(200,134,26,0.3)', margin: '1rem auto 0' }} />
        </div>

        <Tabs items={tabs} centered activeKey={activeTab} onChange={setActiveTab} />

        {activeTab === 'signup' && (
          <div style={{ marginTop: -8, marginBottom: 12 }}>
            <Checkbox checked={termsAccepted} onChange={e => setTermsAccepted(e.target.checked)}>
              <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.6)' }}>
                I agree to the{' '}
                <Link to="/terms" target="_blank" style={{ color: 'rgba(200,134,26,0.8)' }}>Terms of Service</Link>
                {', including its zero-tolerance policy for objectionable content and abusive behavior.'}
              </Text>
            </Checkbox>
          </div>
        )}

        {/* Google Sign-In — below both tabs */}
        <div style={{ marginTop: 8 }}>
          <div style={{ display: 'flex', alignItems: 'center', margin: '16px 0' }}>
            <div style={{ flex: 1, height: 1, background: 'rgba(200,134,26,0.18)' }} />
            <Text style={{ margin: '0 12px', color: 'rgba(244,228,193,0.35)', fontSize: 12 }}>or</Text>
            <div style={{ flex: 1, height: 1, background: 'rgba(200,134,26,0.18)' }} />
          </div>
          {googleError && <Alert message={googleError} type="error" showIcon style={{ marginBottom: 12 }} />}
          <button
            onClick={handleGoogleClick}
            disabled={googleLoading}
            style={{
              width: '100%',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              gap: 10,
              padding: '10px 16px',
              background: '#fff',
              border: '1px solid rgba(200,134,26,0.25)',
              borderRadius: 6,
              cursor: googleLoading ? 'not-allowed' : 'pointer',
              opacity: googleLoading ? 0.7 : 1,
              fontSize: 14,
              fontWeight: 500,
              color: '#3c3c3c',
              transition: 'opacity 0.2s',
            }}
          >
            {googleLoading ? (
              <span>Signing in…</span>
            ) : (
              <>
                {/* Google "G" logo */}
                <svg width="18" height="18" viewBox="0 0 18 18" xmlns="http://www.w3.org/2000/svg">
                  <g fill="none" fillRule="evenodd">
                    <path d="M17.64 9.205c0-.639-.057-1.252-.164-1.841H9v3.481h4.844a4.14 4.14 0 0 1-1.796 2.716v2.259h2.908c1.702-1.567 2.684-3.875 2.684-6.615z" fill="#4285F4"/>
                    <path d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 0 0 9 18z" fill="#34A853"/>
                    <path d="M3.964 10.71A5.41 5.41 0 0 1 3.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 0 0 0 9c0 1.452.348 2.827.957 4.042l3.007-2.332z" fill="#FBBC05"/>
                    <path d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 0 0 .957 4.958L3.964 7.29C4.672 5.163 6.656 3.58 9 3.58z" fill="#EA4335"/>
                  </g>
                </svg>
                Continue with Google
              </>
            )}
          </button>
        </div>
      </Card>

      <div style={{ marginTop: '1.25rem', textAlign: 'center' }}>
        <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.75rem', color: 'rgba(244,228,193,0.35)' }}>
          By creating an account, you agree to our{' '}
          <Link to="/terms"   style={{ color: 'rgba(200,134,26,0.65)', textDecoration: 'none' }}>Terms of Service</Link>
          {' '}and{' '}
          <Link to="/privacy" style={{ color: 'rgba(200,134,26,0.65)', textDecoration: 'none' }}>Privacy Policy</Link>.
        </Text>
      </div>

      <Modal
        open={!!reaccept}
        closable={false}
        maskClosable={false}
        title={<Text style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>Our Terms of Service have been updated</Text>}
        footer={[
          <Button key="agree" type="primary" loading={reacceptLoading} onClick={handleAcceptUpdatedTerms}>
            I Agree
          </Button>,
        ]}
      >
        <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.85rem', color: 'rgba(244,228,193,0.7)' }}>
          We've clarified our zero-tolerance policy for objectionable content and abusive behavior, including new
          in-app reporting and blocking tools. Please review our{' '}
          <Link to="/terms" target="_blank" style={{ color: 'var(--gold)' }}>updated Terms of Service</Link>{' '}
          before continuing.
        </Text>
      </Modal>
    </div>
  );
}
