// Task 20261007-email-verification. Landing page for the emailed link
// (/#/verify-email?token=...). The token is consumed by a POST on load (mail
// scanners that only GET the link cannot burn it). Every failure shows the same
// message. The token is stripped from the address bar after the attempt.
import React, { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate, Link } from 'react-router-dom';
import { Card, Button, Typography, Alert, Spin } from 'antd';
import Seo from '../components/Seo.jsx';
import { verifyEmailToken } from '../lib/emailVerificationApi.js';

const { Title } = Typography;

export default function VerifyEmail() {
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
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '2rem' }}>
      <Seo title="Verify Email — FellowScript" path="/verify-email" noindex />
      <Card style={{ width: '100%', maxWidth: 420, background: 'rgba(10,6,2,0.88)', border: '1px solid rgba(200,134,26,0.2)', backdropFilter: 'blur(12px)' }}>
        <div style={{ textAlign: 'center', marginBottom: '1.5rem' }}>
          <Title level={3} style={{ margin: 0, fontFamily: "'Playfair Display', serif" }}>
            <span style={{ color: 'var(--parchment)' }}>Verify</span>{' '}
            <em style={{ color: 'var(--gold)' }}>email</em>
          </Title>
        </div>
        {phase === 'loading' && <div style={{ textAlign: 'center' }}><Spin /></div>}
        {phase === 'done' && (
          <>
            <Alert type="success" showIcon message="Email verified" description="Thanks, your email address is confirmed." style={{ marginBottom: 16 }} />
            <Link to="/account"><Button type="primary" block>Continue to your account</Button></Link>
          </>
        )}
        {phase === 'invalid' && (
          <>
            <Alert
              type="error" showIcon message="This verification link is invalid or has expired."
              description="Sign in and request a new verification email from your account page."
              style={{ marginBottom: 16 }}
            />
            <Link to="/account"><Button type="primary" block>Go to your account</Button></Link>
          </>
        )}
      </Card>
    </div>
  );
}
