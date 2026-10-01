import React, { useEffect, useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { Typography, Spin, Alert, Button, Input, InputNumber, Tag, Select } from 'antd';
import { AdminPageHeader } from '../components/AdminShell.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import {
  createCreatorCode, listCodesOverview, deactivateCode,
} from '../lib/ownerRewardsApi.js';

const { Text } = Typography;

const CARD_STYLE = {
  background: 'rgba(32,24,16,0.62)',
  border: '1px solid rgba(200,134,26,0.22)',
  backdropFilter: 'blur(14px)',
  borderRadius: 22,
  marginBottom: '1.25rem',
  padding: '1.25rem 1.4rem',
};
const LABEL = {
  fontFamily: "'Inter', sans-serif", fontWeight: 600, fontSize: '0.62rem', letterSpacing: '0.22em',
  textTransform: 'uppercase', color: 'rgba(224,170,60,0.78)', display: 'block', marginBottom: 4,
};
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.5)' };
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Task 20261001-promo-owner-rewards: admin page (/#/admin/promo) to create secure
// creator codes bound to an owner email, deactivate them, and see redemption and
// reward counts. Server-side `require_admin` is the real enforcement; this page
// only reads the answer. Hidden like /admin (not linked from user nav). A 404 means
// the feature flag is off: the page shows a neutral "not available" notice.
export default function AdminPromoCodes() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const [checked, setChecked] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [rows, setRows] = useState([]);
  const [kind, setKind] = useState('');
  const [error, setError] = useState(null);

  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [notes, setNotes] = useState('');
  const [maxRedemptions, setMaxRedemptions] = useState(null);
  const [creating, setCreating] = useState(false);
  const [formError, setFormError] = useState(null);
  const [created, setCreated] = useState(null); // { creator, code }
  const [busyId, setBusyId] = useState(null);

  // 401 -> sign in, 403 -> home, 404 -> feature off. Returns true if handled.
  const handleAuthError = useCallback((err) => {
    if (err.status === 401) { navigate('/signin', { replace: true }); return true; }
    if (err.status === 403) { navigate('/', { replace: true }); return true; }
    if (err.status === 404) { setUnavailable(true); return true; }
    return false;
  }, [navigate]);

  const load = useCallback(async () => {
    if (!user) return;
    setError(null);
    try {
      setRows(await listCodesOverview({ kind: kind || undefined }));
    } catch (err) {
      if (!handleAuthError(err)) setError(err.message || "Couldn't load codes.");
    } finally {
      setChecked(true);
    }
  }, [user, kind, handleAuthError]);

  useEffect(() => { load(); }, [load]);

  const submit = async (e) => {
    e.preventDefault();
    setFormError(null);
    if (!name.trim()) { setFormError('Enter a creator name.'); return; }
    if (!EMAIL_RE.test(email.trim())) { setFormError('Enter a valid owner email.'); return; }
    setCreating(true);
    try {
      const out = await createCreatorCode({
        name: name.trim(), notes: notes.trim(), ownerEmail: email.trim(),
        maxRedemptions: maxRedemptions || undefined,
      });
      setCreated(out);
      setName(''); setEmail(''); setNotes(''); setMaxRedemptions(null);
      await load();
    } catch (err) {
      if (!handleAuthError(err)) setFormError(err.message || "Couldn't create the code.");
    } finally {
      setCreating(false);
    }
  };

  const deactivate = async (row) => {
    setBusyId(row.id);
    setError(null);
    try {
      await deactivateCode(row.id);
      await load();
    } catch (err) {
      if (!handleAuthError(err)) setError(err.message || "Couldn't deactivate the code.");
    } finally {
      setBusyId(null);
    }
  };

  if (!checked) {
    return (
      <div style={{ minHeight: '40vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Spin size="large" />
      </div>
    );
  }

  return (
    <div>
        <AdminPageHeader title="Promo codes" />

        {unavailable ? (
          <Alert type="info" showIcon message="Owner rewards aren't enabled." style={{ borderRadius: 8 }} />
        ) : (
          <>
            <form onSubmit={submit} style={CARD_STYLE} aria-label="Create creator code">
              <Text style={LABEL}>New creator code</Text>
              <p style={{ ...MUTED, margin: '0 0 0.8rem' }}>
                Creates a creator and a secure random code attached to the owner email.
                When someone buys with the code, the owner earns a reward if they hold a plan.
              </p>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.9rem' }}>
                <div style={{ minWidth: 220, flex: 1 }}>
                  <label htmlFor="cc-name" style={LABEL}>Creator name</label>
                  <Input id="cc-name" value={name} maxLength={120} onChange={(e) => setName(e.target.value)} />
                </div>
                <div style={{ minWidth: 240, flex: 1 }}>
                  <label htmlFor="cc-email" style={LABEL}>Owner email</label>
                  <Input id="cc-email" type="email" value={email} maxLength={255} onChange={(e) => setEmail(e.target.value)} />
                </div>
                <div style={{ minWidth: 160 }}>
                  <label htmlFor="cc-max" style={LABEL}>Max redemptions</label>
                  <InputNumber id="cc-max" min={1} value={maxRedemptions} onChange={setMaxRedemptions} placeholder="No limit" style={{ width: '100%' }} />
                </div>
              </div>
              <div style={{ marginTop: '0.9rem' }}>
                <label htmlFor="cc-notes" style={LABEL}>Notes (optional)</label>
                <Input.TextArea id="cc-notes" rows={2} maxLength={2000} value={notes} onChange={(e) => setNotes(e.target.value)} />
              </div>
              <Button type="primary" htmlType="submit" loading={creating} style={{ marginTop: '0.9rem', borderRadius: 999 }}>
                Create code
              </Button>
              {formError && <Alert role="alert" type="error" showIcon message={formError} style={{ marginTop: '0.8rem', borderRadius: 8 }} />}
              {created?.code?.code && (
                <Alert
                  type="success" showIcon style={{ marginTop: '0.8rem', borderRadius: 8 }}
                  message={<span>Created code <strong data-testid="created-code" style={{ letterSpacing: '0.1em' }}>{created.code.code}</strong> for the owner.</span>}
                />
              )}
            </form>

            <div style={CARD_STYLE}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '0.8rem', gap: 12, flexWrap: 'wrap' }}>
                <Text style={{ ...LABEL, marginBottom: 0 }}>Codes</Text>
                <Select
                  aria-label="Filter by kind" value={kind} onChange={setKind} style={{ width: 160 }}
                  options={[{ value: '', label: 'All kinds' }, { value: 'creator', label: 'Creator' }, { value: 'friend', label: 'Friend' }]}
                />
              </div>
              {error && <Alert role="alert" type="error" showIcon message={error} style={{ marginBottom: '0.8rem', borderRadius: 8 }} />}
              {rows.length === 0 ? (
                <Text style={MUTED}>No codes yet.</Text>
              ) : (
                <div style={{ overflowX: 'auto' }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', ...MUTED }}>
                    <thead>
                      <tr style={{ textAlign: 'left' }}>
                        {['Code', 'Kind', 'Owner email', 'Redemptions', 'Rewards earned / claimed', 'Status', ''].map((h) => (
                          <th key={h} scope="col" style={{ ...LABEL, padding: '0 8px 8px 0' }}>{h}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {rows.map((r) => (
                        <tr key={r.id} data-testid="code-row" style={{ borderTop: '1px solid rgba(200,134,26,0.1)' }}>
                          <td style={{ padding: '8px 8px 8px 0', color: 'var(--parchment)', fontFamily: 'ui-monospace, Menlo, monospace' }}>
                            {r.code}{r.creator_name ? <div style={MUTED}>{r.creator_name}</div> : null}
                          </td>
                          <td style={{ padding: 8 }}>{r.kind}</td>
                          <td style={{ padding: 8 }}>{r.owner_email || '—'}</td>
                          <td style={{ padding: 8 }}>{r.redemption_count}{r.max_redemptions ? ` / ${r.max_redemptions}` : ''}</td>
                          <td style={{ padding: 8 }}>{r.rewards_earned} / {r.rewards_claimed}</td>
                          <td style={{ padding: 8 }}><Tag color={r.active ? 'gold' : 'default'}>{r.active ? 'Active' : 'Inactive'}</Tag></td>
                          <td style={{ padding: 8 }}>
                            {r.active && (
                              <Button size="small" danger shape="round" loading={busyId === r.id} onClick={() => deactivate(r)} aria-label={`Deactivate ${r.code}`}>
                                Deactivate
                              </Button>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          </>
        )}
    </div>
  );
}
