import React, { useState } from 'react';
import { useNavigate, useLocation, Link } from 'react-router-dom';
import { Card, Form, Input, Button, Typography, Alert } from 'antd';
import { useAuth } from '../context/AuthContext.jsx';
import { API } from '../config.js';

const { Title, Text } = Typography;

export default function VerifyMfa() {
  const { signIn } = useAuth();
  const navigate    = useNavigate();
  const location    = useLocation();
  const userId      = location.state?.user_id;
  const [code,    setCode]    = useState('');
  const [error,   setError]   = useState('');
  const [loading, setLoading] = useState(false);

  if (!userId) {
    return (
      <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '2rem' }}>
        <Card style={{ width: '100%', maxWidth: 420, background: 'rgba(10,6,2,0.88)', border: '1px solid rgba(200,134,26,0.2)' }}>
          <Text style={{ fontFamily: "'Lora', serif", color: 'rgba(244,228,193,0.6)' }}>
            No sign-in in progress. <Link to="/signin" style={{ color: 'var(--gold)' }}>Return to sign in</Link>.
          </Text>
        </Card>
      </div>
    );
  }

  const handleVerify = async () => {
    setError('');
    setLoading(true);
    try {
      const res  = await fetch(`${API}/auth/mfa/verify-login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ user_id: userId, code: code.trim() }),
      });
      const data = await res.json();
      if (!res.ok) { setError(data.detail || 'Invalid or expired code.'); return; }
      signIn(data);
      navigate('/reader');
    } catch {
      setError('Could not reach the server.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '2rem' }}>
      <Card style={{ width: '100%', maxWidth: 420, background: 'rgba(10,6,2,0.88)', border: '1px solid rgba(200,134,26,0.2)', backdropFilter: 'blur(12px)' }}>
        <div style={{ textAlign: 'center', marginBottom: '1.5rem' }}>
          <Title level={3} style={{ margin: 0, fontFamily: "'Playfair Display', serif" }}>
            <span style={{ color: 'var(--parchment)' }}>Verify</span>{' '}
            <em style={{ color: 'var(--gold)' }}>it's you</em>
          </Title>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.82rem', color: 'rgba(244,228,193,0.5)' }}>
            We emailed a 6-digit code to finish signing in.
          </Text>
        </div>

        <Form layout="vertical" onFinish={handleVerify} style={{ marginTop: 8 }}>
          {error && <Alert message={error} type="error" showIcon style={{ marginBottom: 16 }} />}
          <Form.Item>
            <Input
              placeholder="123456"
              value={code}
              onChange={e => setCode(e.target.value)}
              maxLength={6}
              autoFocus
              style={{ fontSize: '1.2rem', letterSpacing: '0.35em', textAlign: 'center' }}
            />
          </Form.Item>
          <Button type="primary" htmlType="submit" loading={loading} block>Verify</Button>
        </Form>

        <div style={{ textAlign: 'center', marginTop: '1.25rem' }}>
          <Link to="/signin" style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.4)' }}>
            Back to sign in
          </Link>
        </div>
      </Card>
    </div>
  );
}
