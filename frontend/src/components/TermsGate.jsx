import React, { useState } from 'react';
import { Modal, Button, Typography } from 'antd';
import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { useCapabilities } from '../hooks/useCapabilities.js';
import { acceptCurrentTerms } from '../lib/capabilities.js';

const { Text } = Typography;

// Task 20261002-shared-foundation step 8 (contract 6.12). Presents the same
// "Our Terms of Service have been updated" gate SignIn.jsx and VerifyMfa.jsx
// show, for a user who is already signed in when the Terms version changes.
// Shown only when /app/capabilities answered terms_current === false; a
// missing or failing endpoint reads as "current", so users are never trapped.
export default function TermsGate() {
  const { user, signOut } = useAuth() || {};
  const { termsCurrent, refresh } = useCapabilities();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const open = !!user?.user_id && termsCurrent === false;

  const accept = async () => {
    setLoading(true);
    setError('');
    try {
      await acceptCurrentTerms(user.user_id);
      await refresh();
    } catch (err) {
      setError(err?.message || "Couldn't save your agreement. Please try again.");
    } finally {
      setLoading(false);
    }
  };

  if (!open) return null;
  return (
    <Modal
      open
      closable={false}
      maskClosable={false}
      keyboard={false}
      title={<Text style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>Our Terms of Service have been updated</Text>}
      footer={[
        <Button key="out" onClick={signOut} disabled={loading}>Sign out</Button>,
        <Button key="agree" type="primary" loading={loading} onClick={accept}>I Agree</Button>,
      ]}
    >
      <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.85rem', color: 'rgba(244,228,193,0.7)' }}>
        Please review our{' '}
        <Link to="/terms" target="_blank" style={{ color: 'var(--gold)' }}>updated Terms of Service</Link>{' '}
        before continuing.
      </Text>
      {error && <p role="alert" style={{ color: 'var(--danger, #e57373)', marginTop: 8 }}>{error}</p>}
    </Modal>
  );
}
