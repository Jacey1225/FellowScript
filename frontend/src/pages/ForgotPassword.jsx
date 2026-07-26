import React, { useState } from 'react';
import { Link } from 'react-router-dom';
import { Card, Form, Input, Button, Typography, Alert } from 'antd';
import { MailOutlined } from '@ant-design/icons';
import { API } from '../config.js';

const { Title, Text } = Typography;

export default function ForgotPassword() {
  const [email,   setEmail]   = useState('');
  const [error,   setError]   = useState('');
  const [sent,    setSent]    = useState(false);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async () => {
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
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '2rem' }}>
      <Card style={{ width: '100%', maxWidth: 420, background: 'rgba(10,6,2,0.88)', border: '1px solid rgba(200,134,26,0.2)', backdropFilter: 'blur(12px)' }}>
        <div style={{ textAlign: 'center', marginBottom: '1.5rem' }}>
          <Title level={3} style={{ margin: 0, fontFamily: "'Playfair Display', serif" }}>
            <span style={{ color: 'var(--parchment)' }}>Forgot</span>{' '}
            <em style={{ color: 'var(--gold)' }}>password</em>
          </Title>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.82rem', color: 'rgba(244,228,193,0.5)' }}>
            Enter your account email and we'll send a reset link.
          </Text>
        </div>

        {sent ? (
          <Alert
            type="success"
            showIcon
            message="Check your email"
            description="If an account with that email exists, a password reset link has been sent. It expires in 30 minutes."
          />
        ) : (
          <Form layout="vertical" onFinish={handleSubmit} style={{ marginTop: 8 }}>
            {error && <Alert message={error} type="error" showIcon style={{ marginBottom: 16 }} />}
            <Form.Item>
              <Input
                prefix={<MailOutlined />}
                placeholder="you@example.com"
                type="email"
                value={email}
                onChange={e => setEmail(e.target.value)}
                autoFocus
              />
            </Form.Item>
            <Button type="primary" htmlType="submit" loading={loading} block>Send reset link</Button>
          </Form>
        )}

        <div style={{ textAlign: 'center', marginTop: '1.25rem' }}>
          <Link to="/signin" style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.4)' }}>
            Back to sign in
          </Link>
        </div>
      </Card>
    </div>
  );
}
