import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Card, Form, Input, Button, Typography, Tabs, Alert } from 'antd';
import { UserOutlined, LockOutlined, MailOutlined } from '@ant-design/icons';
import { useAuth } from '../context/AuthContext.jsx';
import { API } from '../config.js';

const { Title, Text } = Typography;

export default function SignIn() {
  const { signIn } = useAuth();
  const navigate   = useNavigate();
  const [siForm]   = Form.useForm();
  const [suForm]   = Form.useForm();
  const [siError,  setSiError]  = useState('');
  const [suError,  setSuError]  = useState('');
  const [siLoading, setSiLoading] = useState(false);
  const [suLoading, setSuLoading] = useState(false);

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
      signIn(data);
      navigate('/reader');
    } catch {
      setSiError('Could not reach the server.');
    } finally {
      setSiLoading(false);
    }
  };

  const handleSignup = async (vals) => {
    setSuError('');
    setSuLoading(true);
    try {
      const res  = await fetch(`${API}/signup`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: vals.username.trim(), email: vals.email.trim(), plain_pass: vals.password }),
      });
      const data = await res.json();
      if (!res.ok) { setSuError(data.detail || 'Sign up failed.'); return; }
      signIn(data);
      localStorage.setItem('fs_tour', 'reader');
      navigate('/reader');
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
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '2rem' }}>
      <video id="bg-video" autoPlay muted loop playsInline>
        <source src="/data/bg.mp4" type="video/mp4" />
      </video>

      <Card style={{ width: '100%', maxWidth: 420, background: 'rgba(10,6,2,0.88)', border: '1px solid rgba(200,134,26,0.2)', backdropFilter: 'blur(12px)' }}>
        <div style={{ textAlign: 'center', marginBottom: '1.5rem' }}>
          <Title level={3} style={{ margin: 0, fontFamily: "'Playfair Display', serif" }}>
            <span style={{ color: 'var(--parchment)' }}>Fellow</span>
            <em style={{ color: 'var(--gold)' }}>Script</em>
          </Title>
          <div style={{ width: 40, height: 1, background: 'rgba(200,134,26,0.3)', margin: '1rem auto 0' }} />
        </div>
        <Tabs items={tabs} centered />
      </Card>
    </div>
  );
}
