import React, { useState } from 'react';
import { useLocation, Link } from 'react-router-dom';
import { Card, Form, Input, Button, Typography, Alert } from 'antd';
import { LockOutlined } from '@ant-design/icons';
import { API } from '../config.js';

const { Title, Text } = Typography;

export default function ResetPassword() {
  const location = useLocation();
  const token     = new URLSearchParams(location.search).get('token') || '';
  const [password, setPassword] = useState('');
  const [error,    setError]    = useState('');
  const [done,     setDone]     = useState(false);
  const [loading,  setLoading]  = useState(false);

  if (!token) {
    return (
      <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '2rem' }}>
        <Card style={{ width: '100%', maxWidth: 420, background: 'rgba(10,6,2,0.88)', border: '1px solid rgba(200,134,26,0.2)' }}>
          <Text style={{ fontFamily: "'Lora', serif", color: 'rgba(244,228,193,0.6)' }}>
            This reset link is missing its token. <Link to="/forgot-password" style={{ color: 'var(--gold)' }}>Request a new one</Link>.
          </Text>
        </Card>
      </div>
    );
  }

  const handleSubmit = async () => {
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
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '2rem' }}>
      <Card style={{ width: '100%', maxWidth: 420, background: 'rgba(10,6,2,0.88)', border: '1px solid rgba(200,134,26,0.2)', backdropFilter: 'blur(12px)' }}>
        <div style={{ textAlign: 'center', marginBottom: '1.5rem' }}>
          <Title level={3} style={{ margin: 0, fontFamily: "'Playfair Display', serif" }}>
            <span style={{ color: 'var(--parchment)' }}>Reset</span>{' '}
            <em style={{ color: 'var(--gold)' }}>password</em>
          </Title>
        </div>

        {done ? (
          <>
            <Alert
              type="success"
              showIcon
              message="Password updated"
              description="You've been signed out everywhere for security. Sign in with your new password."
              style={{ marginBottom: 16 }}
            />
            <Link to="/signin"><Button type="primary" block>Go to sign in</Button></Link>
          </>
        ) : (
          <Form layout="vertical" onFinish={handleSubmit} style={{ marginTop: 8 }}>
            {error && <Alert message={error} type="error" showIcon style={{ marginBottom: 16 }} />}
            <Form.Item label="New password">
              <Input.Password
                prefix={<LockOutlined />}
                placeholder="New password"
                value={password}
                onChange={e => setPassword(e.target.value)}
                autoFocus
              />
            </Form.Item>
            <Button type="primary" htmlType="submit" loading={loading} block>Reset password</Button>
          </Form>
        )}
      </Card>
    </div>
  );
}
