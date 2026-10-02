import React, { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Spin, Alert, Button, Select, Segmented } from 'antd';
import { AdminPageHeader } from '../components/AdminShell.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import {
  QUEUE_STATUSES, REJECT_REASONS, HIDE_REASONS,
  fetchQueue, approveListing, rejectListing, hideListing, restoreListing, removeListing,
} from '../lib/adminListingsApi.js';

const CARD_STYLE = {
  background: 'rgba(92,68,42,0.34)',
  border: '1px solid rgba(255,225,170,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 22,
  marginBottom: '1rem',
  padding: '1.1rem 1.3rem',
};
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.6)' };

const TAB_LABEL = {
  pending_review: 'Pending review', published: 'Published', hidden: 'Hidden', rejected: 'Rejected',
};
const EMPTY_COPY = {
  pending_review: 'Nothing is waiting for review.',
  published: 'No published listings.',
  hidden: 'No hidden listings.',
  rejected: 'No rejected listings.',
};
const reasonLabel = (code) => code.replace(/_/g, ' ');
const place = (l) => [l.city, l.region, l.country].filter(Boolean).join(', ');

// Admin page (/#/admin/listings): moderation queue for Explorer listings.
// Server-side `require_admin` is the real enforcement; 401 -> sign in,
// 403 -> home, 404 -> feature off.
export default function AdminListings() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const [status, setStatus] = useState('pending_review');
  const [items, setItems] = useState(null);
  const [error, setError] = useState(null);
  const [unavailable, setUnavailable] = useState(false);
  const [busyId, setBusyId] = useState(null);
  // per-listing pending action: { id, kind: 'reject'|'hide'|'remove', reason }
  const [pending, setPending] = useState(null);

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
      const out = await fetchQueue(status);
      setItems(out.items || []);
    } catch (err) {
      if (!handleAuthError(err)) { setError(err.message || "Couldn't load listings."); setItems([]); }
    }
  }, [user, status, handleAuthError]);

  useEffect(() => { setItems(null); setPending(null); load(); }, [load]);

  const run = async (id, fn) => {
    setBusyId(id);
    setError(null);
    try {
      await fn();
      setPending(null);
      await load();
    } catch (err) {
      if (!handleAuthError(err)) setError(err.message || 'That action failed.');
    } finally {
      setBusyId(null);
    }
  };

  const startReason = (id, kind) => setPending({ id, kind, reason: kind === 'reject' ? REJECT_REASONS[0] : HIDE_REASONS[0] });

  const confirmPending = (l) => {
    const { kind, reason } = pending;
    if (kind === 'reject') return run(l.public_id, () => rejectListing(l.public_id, reason));
    if (kind === 'hide') return run(l.public_id, () => hideListing(l.public_id, reason));
    return run(l.public_id, () => removeListing(l.public_id));
  };

  return (
    <div>
      <AdminPageHeader title="Group listings" />
      {unavailable ? (
        <Alert type="info" showIcon message="Explorer listings aren't enabled." style={{ borderRadius: 8 }} />
      ) : (
        <>
          <Segmented
            value={status}
            onChange={setStatus}
            options={QUEUE_STATUSES.map((s) => ({ value: s, label: TAB_LABEL[s] }))}
            style={{ marginBottom: '1.1rem' }}
            aria-label="Listing status"
          />
          {error && <Alert type="error" showIcon message={error} style={{ borderRadius: 8, marginBottom: '1rem' }} />}
          {items === null ? (
            <div style={{ minHeight: '30vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Spin size="large" /></div>
          ) : items.length === 0 ? (
            <p style={MUTED}>{EMPTY_COPY[status]}</p>
          ) : (
            <ul style={{ listStyle: 'none', margin: 0, padding: 0 }} aria-label="Listings">
              {items.map((l) => {
                const open = pending && pending.id === l.public_id ? pending : null;
                const busy = busyId === l.public_id;
                return (
                  <li key={l.public_id} style={CARD_STYLE} data-testid={`listing-${l.public_id}`}>
                    <h2 style={{ margin: 0, fontSize: '1.1rem', color: '#f4e4c1' }}>{l.title || '(untitled)'}</h2>
                    <p style={{ ...MUTED, margin: '0.2rem 0 0.6rem' }}>
                      {[l.church_name, place(l)].filter(Boolean).join(' · ') || 'No church or location given'}
                      {l.open_reports > 0 && ` · ${l.open_reports} open report${l.open_reports === 1 ? '' : 's'}`}
                      {l.hidden_reason_code && ` · hidden: ${reasonLabel(l.hidden_reason_code)}`}
                      {l.reject_reason_code && ` · rejected: ${reasonLabel(l.reject_reason_code)}`}
                    </p>
                    {l.summary && <p style={{ margin: '0 0 0.5rem', color: '#f4e4c1' }}>{l.summary}</p>}
                    {l.description_text && (
                      <p style={{ margin: '0 0 0.8rem', color: 'rgba(244,228,193,0.8)', whiteSpace: 'pre-wrap' }}>{l.description_text}</p>
                    )}
                    {open ? (
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.6rem', alignItems: 'center' }}>
                        {open.kind !== 'remove' ? (
                          <Select
                            value={open.reason}
                            onChange={(reason) => setPending({ ...open, reason })}
                            options={(open.kind === 'reject' ? REJECT_REASONS : HIDE_REASONS).map((r) => ({ value: r, label: reasonLabel(r) }))}
                            style={{ minWidth: 190 }}
                            aria-label="Reason"
                          />
                        ) : (
                          <span style={MUTED}>Delete this listing permanently?</span>
                        )}
                        <Button danger type="primary" loading={busy} onClick={() => confirmPending(l)}>
                          {open.kind === 'reject' ? 'Reject' : open.kind === 'hide' ? 'Hide' : 'Delete'}
                        </Button>
                        <Button onClick={() => setPending(null)} disabled={busy}>Cancel</Button>
                      </div>
                    ) : (
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.6rem' }}>
                        {status === 'pending_review' && (
                          <>
                            <Button type="primary" loading={busy} onClick={() => run(l.public_id, () => approveListing(l.public_id))}>Approve</Button>
                            <Button onClick={() => startReason(l.public_id, 'reject')}>Reject</Button>
                            <Button onClick={() => startReason(l.public_id, 'hide')}>Hide</Button>
                          </>
                        )}
                        {status === 'published' && <Button onClick={() => startReason(l.public_id, 'hide')}>Hide</Button>}
                        {status === 'hidden' && (
                          <Button type="primary" loading={busy} onClick={() => run(l.public_id, () => restoreListing(l.public_id))}>Restore</Button>
                        )}
                        <Button danger onClick={() => setPending({ id: l.public_id, kind: 'remove' })}>Delete</Button>
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </>
      )}
    </div>
  );
}
