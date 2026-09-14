import React, { useState } from 'react';
import { Typography, Button, Tag, Alert } from 'antd';
import { CrownOutlined } from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { API } from '../config.js';

const { Text } = Typography;

// Same card treatment as AdminDetections.jsx's own CARD_STYLE (kept as a
// local copy, not a shared import, so this component stays fully additive
// and AdminDetections.jsx's own styling constants are never touched).
const CARD_STYLE = {
  background: 'rgba(6,4,1,0.88)',
  border: '1px solid rgba(200,134,26,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 14,
  marginBottom: '1.5rem',
  padding: '1.1rem 1.25rem',
};

// Admin-only self-service free individual-membership comp grant (task
// 20260914-admin-free-membership). Lives on the same gated /admin surface
// as AdminDetections alongside it, without altering that page's own
// filter/fetch/pagination behavior -- this component owns its own state
// and makes its own single-purpose request.
//
// Plainly labeled button + minimal loading/success/error feedback, per the
// intake spec's UI/UX Q2 (familiarity for utility screens -- no novel
// interaction pattern) and Q17 (minimal empty/loading/error states).
//
// Server-side `require_admin` on POST /subscriptions/admin/grant-individual
// is the real enforcement (see api/routes/subscription.py); this component
// is only reachable through the already-admin-gated /admin route (AdminGate
// + this page's own gate-fetch), so a 401/403 here would mean the admin's
// session lapsed or was demoted between page load and the click -- handled
// the same way AdminDetections.jsx's own fetch handles those statuses.
export default function AdminMembershipGrant() {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState(null); // granted subscription dict, once obtained
  const [error, setError] = useState(null);

  const grant = async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch(`${API}/subscriptions/admin/grant-individual`, { method: 'POST' });
      if (res.status === 401) { navigate('/signin', { replace: true }); return; }
      if (res.status === 403) { navigate('/', { replace: true }); return; }
      if (!res.ok) {
        const d = await res.json().catch(() => ({}));
        setError(d.detail || 'Could not grant membership.');
        return;
      }
      setResult(await res.json());
    } catch {
      setError('Could not reach the server.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={CARD_STYLE}>
      <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.6rem', letterSpacing: '0.28em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.6rem' }}>
        Admin Membership
      </Text>

      {result ? (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <CrownOutlined style={{ color: 'var(--gold)' }} />
          <Text style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.85rem', color: 'var(--parchment)' }}>
            Individual membership active
          </Text>
          <Tag color="gold" style={{ textTransform: 'capitalize' }}>{result.status}</Tag>
        </div>
      ) : (
        <>
          <Text style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.5)', display: 'block', marginBottom: '0.8rem' }}>
            Grant yourself a free, unbilled individual membership — no Stripe/Apple billing involved.
          </Text>
          <Button type="primary" loading={loading} onClick={grant} style={{ borderRadius: 8, fontFamily: "'Inter', sans-serif" }}>
            Grant free individual membership
          </Button>
        </>
      )}

      {error && <Alert type="error" showIcon message={error} style={{ marginTop: '0.8rem', borderRadius: 8 }} />}
    </div>
  );
}
