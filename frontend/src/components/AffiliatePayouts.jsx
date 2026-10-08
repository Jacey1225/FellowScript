import React, { useEffect, useState, useCallback, useRef } from 'react';
import { Spin, Alert, Button, Tag, Input, Select, Modal } from 'antd';
import {
  getPayoutStatus, requestPayoutCode, verifyPayoutCode, savePayoutDetails, deletePayoutDetails,
  validatePayoutFields, payoutErrorMessage,
} from '../lib/payoutsApi.js';

const CARD = {
  background: 'rgba(32,24,16,0.62)', border: '1px solid rgba(200,134,26,0.22)', backdropFilter: 'blur(14px)',
  borderRadius: 22, marginBottom: '1.25rem', padding: '1.25rem 1.4rem',
};
const LABEL = {
  fontFamily: "'Inter', sans-serif", fontWeight: 600, fontSize: '0.62rem', letterSpacing: '0.22em',
  textTransform: 'uppercase', color: 'rgba(224,170,60,0.78)', display: 'block', margin: '0 0 4px',
};
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.5)' };
const BODY = { fontFamily: "'Inter', sans-serif", fontSize: '0.9rem', color: 'rgba(244,228,193,0.85)', lineHeight: 1.6 };
const FIELD = { display: 'block', marginBottom: '0.8rem' };
const ERR = { color: '#ff7875', fontSize: '0.78rem', margin: '2px 0 0' };
const BLANK = { routing_number: '', account_number: '', account_confirm: '', account_type: 'checking', holder_name: '' };

// Task 20261008-affiliate-payout-details. Renders nothing when the feature is off
// (404) or the viewer isn't allowed. Values live only in component state, are cleared
// after save/cancel/unmount, and never touch URLs, storage, logs, or error reports.
export default function AffiliatePayouts() {
  const [phase, setPhase] = useState('loading'); // loading | hidden | ready | error
  const [view, setView] = useState(null);
  const [mode, setMode] = useState('idle'); // idle | code | form
  const [code, setCode] = useState('');
  const [password, setPassword] = useState('');
  const [needsPassword, setNeedsPassword] = useState(false);
  const proofRef = useRef(null); // single-use proof, memory only
  const [form, setForm] = useState(BLANK);
  const [fieldErrs, setFieldErrs] = useState({});
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const [intent, setIntent] = useState('save'); // save | delete

  const load = useCallback(async () => {
    setPhase('loading');
    try { setView(await getPayoutStatus()); setPhase('ready'); }
    catch (err) { setPhase(err.status === 404 || err.status === 403 || err.status === 401 ? 'hidden' : 'error'); }
  }, []);
  useEffect(() => { load(); }, [load]);
  useEffect(() => () => { proofRef.current = null; }, []);

  const reset = () => {
    proofRef.current = null; setForm(BLANK); setCode(''); setPassword('');
    setFieldErrs({}); setMode('idle'); setMsg(null);
  };

  const startReauth = async (which) => {
    setIntent(which); setBusy(true); setMsg(null);
    try {
      const r = await requestPayoutCode();
      setNeedsPassword(Boolean(r.password_required));
      setMode('code');
    } catch (err) { setMsg(payoutErrorMessage(err)); }
    setBusy(false);
  };

  const submitCode = async () => {
    setBusy(true); setMsg(null);
    try {
      const r = await verifyPayoutCode(code.trim(), needsPassword ? password : undefined);
      proofRef.current = r.proof; setCode(''); setPassword('');
      if (intent === 'delete') { setMode('idle'); setConfirmDelete(true); } else setMode('form');
    } catch (err) { setMsg(payoutErrorMessage(err)); }
    setBusy(false);
  };

  const [confirmDelete, setConfirmDelete] = useState(false);
  const doDelete = async () => {
    setBusy(true); setMsg(null);
    try {
      await deletePayoutDetails(proofRef.current);
      proofRef.current = null; setConfirmDelete(false); setView({ status: 'not_set' });
    } catch (err) { setConfirmDelete(false); setMsg(payoutErrorMessage(err)); proofRef.current = null; }
    setBusy(false);
  };

  const submitForm = async () => {
    const errs = validatePayoutFields(form);
    setFieldErrs(errs);
    if (Object.keys(errs).length) return;
    setBusy(true); setMsg(null);
    try {
      const { routing_number, account_number, account_type, holder_name } = form;
      const v = await savePayoutDetails(proofRef.current, {
        routing_number, account_number, account_type, holder_name: holder_name.trim(),
      });
      setView(v); reset();
    } catch (err) {
      proofRef.current = null; // proof is single use; user must verify again
      setMsg(payoutErrorMessage(err));
      if (err.code === 'reauth_required' || err.code === 'reauth_failed') { setForm(BLANK); setMode('idle'); }
    }
    setBusy(false);
  };

  if (phase === 'hidden') return null;
  if (phase === 'loading') return <div style={{ ...CARD, textAlign: 'center' }}><Spin /></div>;
  if (phase === 'error') {
    return (
      <div style={CARD} role="alert">
        <Alert type="error" showIcon message="Couldn't load your payout details."
          action={<Button size="small" onClick={load}>Try again</Button>} />
      </div>
    );
  }

  const isSet = view && view.status === 'set';
  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));
  const digits = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value.replace(/\D/g, '') }));

  return (
    <div style={CARD} data-testid="payout-details">
      <h2 style={LABEL}>Payout details</h2>
      <p style={BODY}>
        Add your US bank account so FellowScript can pay your commission by direct deposit. Payouts are still sent manually.
      </p>

      {mode === 'idle' && (
        <>
          {isSet ? (
            <div style={{ marginBottom: '0.8rem' }}>
              <Tag color="gold">Set</Tag>
              <p style={BODY} data-testid="payout-summary">
                {view.holder_name_masked} · {view.account_type} · routing ending {view.routing_last4} · account ending {view.account_last4}
              </p>
              {view.updated_at && <p style={MUTED}>Last updated {new Date(view.updated_at).toLocaleDateString()}</p>}
            </div>
          ) : (
            <p style={MUTED} data-testid="payout-empty"><Tag>Not set</Tag> You haven't added payout details yet.</p>
          )}
          <div style={{ display: 'flex', gap: '0.6rem', flexWrap: 'wrap' }}>
            <Button type="primary" shape="round" style={{ minHeight: 44 }} loading={busy}
              onClick={() => startReauth('save')}>{isSet ? 'Change details' : 'Add details'}</Button>
            {isSet && (
              <Button danger shape="round" style={{ minHeight: 44 }} loading={busy}
                onClick={() => startReauth('delete')}>Delete details</Button>
            )}
          </div>
        </>
      )}

      {mode === 'code' && (
        <form onSubmit={(e) => { e.preventDefault(); submitCode(); }} autoComplete="off">
          <p style={BODY}>We emailed you a 6-digit code. Enter it to continue.{needsPassword ? ' Also enter your password.' : ''}</p>
          <label style={FIELD}><span style={MUTED}>Verification code</span>
            <Input value={code} inputMode="numeric" maxLength={6} autoComplete="one-time-code" aria-label="Verification code"
              onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} /></label>
          {needsPassword && (
            <label style={FIELD}><span style={MUTED}>Password</span>
              <Input.Password value={password} autoComplete="current-password" aria-label="Password"
                onChange={(e) => setPassword(e.target.value)} /></label>
          )}
          <div style={{ display: 'flex', gap: '0.6rem' }}>
            <Button type="primary" shape="round" htmlType="submit" loading={busy}
              disabled={code.length !== 6 || (needsPassword && !password)} style={{ minHeight: 44 }}>Verify</Button>
            <Button shape="round" onClick={reset} style={{ minHeight: 44 }}>Cancel</Button>
          </div>
        </form>
      )}

      {mode === 'form' && (
        <form onSubmit={(e) => { e.preventDefault(); submitForm(); }} autoComplete="off">
          <label style={FIELD}><span style={MUTED}>Account holder name</span>
            <Input value={form.holder_name} onChange={set('holder_name')} autoComplete="off" maxLength={100} aria-label="Account holder name" />
            {fieldErrs.holder_name && <p style={ERR}>{fieldErrs.holder_name}</p>}</label>
          <label style={FIELD}><span style={MUTED}>Account type</span>
            <Select value={form.account_type} style={{ width: '100%' }} aria-label="Account type"
              onChange={(v) => setForm((f) => ({ ...f, account_type: v }))}
              options={[{ value: 'checking', label: 'Checking' }, { value: 'savings', label: 'Savings' }]} /></label>
          <label style={FIELD}><span style={MUTED}>Routing number (9 digits)</span>
            <Input value={form.routing_number} onChange={digits('routing_number')} inputMode="numeric" maxLength={9}
              autoComplete="off" aria-label="Routing number" />
            {fieldErrs.routing_number && <p style={ERR}>{fieldErrs.routing_number}</p>}</label>
          <label style={FIELD}><span style={MUTED}>Account number</span>
            <Input value={form.account_number} onChange={digits('account_number')} inputMode="numeric" maxLength={17}
              autoComplete="off" aria-label="Account number" />
            {fieldErrs.account_number && <p style={ERR}>{fieldErrs.account_number}</p>}</label>
          <label style={FIELD}><span style={MUTED}>Confirm account number</span>
            <Input value={form.account_confirm} onChange={digits('account_confirm')} inputMode="numeric" maxLength={17}
              autoComplete="off" aria-label="Confirm account number" />
            {fieldErrs.account_confirm && <p style={ERR}>{fieldErrs.account_confirm}</p>}</label>
          <div style={{ display: 'flex', gap: '0.6rem' }}>
            <Button type="primary" shape="round" htmlType="submit" loading={busy} style={{ minHeight: 44 }}>Save details</Button>
            <Button shape="round" onClick={reset} style={{ minHeight: 44 }}>Cancel</Button>
          </div>
        </form>
      )}

      {msg && <div role="alert" style={{ marginTop: '0.8rem' }}><Alert type="error" showIcon message={msg} /></div>}

      <Modal open={confirmDelete} title="Delete payout details?" okText="Delete" okButtonProps={{ danger: true, loading: busy }}
        onOk={doDelete} onCancel={() => { proofRef.current = null; setConfirmDelete(false); }}>
        Your stored bank details will be permanently removed.
      </Modal>

      <p style={{ ...MUTED, margin: '1rem 0 0' }} data-testid="payout-privacy">
        Privacy: we store your holder name, account type, routing number and account number encrypted at rest. Only the last 4
        digits are ever shown back to you. Only you and authorized FellowScript staff can access them, and each staff access is
        logged and emailed to you. Changing or deleting details needs an emailed code. You can delete your details at any time;
        they are removed immediately, though encrypted backups may keep a copy until they expire.
      </p>
    </div>
  );
}
