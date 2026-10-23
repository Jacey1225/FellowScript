import React, { useState, useEffect } from 'react';
import { Button, Modal, Alert } from 'antd';
import { FormSkin, Field, ChipGroup, StickyActionBar } from './forms/index.js';
import { HeartFilled } from '@ant-design/icons';
import { API } from '../config.js';

const PRESETS = [5, 10, 25, 50];

export default function DonationButton({ email }) {
  const [open,   setOpen]   = useState(false);
  const [amount, setAmount] = useState(10);   // selected preset (dollars)
  const [custom, setCustom] = useState('');   // custom dollars (string)
  const [busy,   setBusy]   = useState(false);
  const [err,    setErr]    = useState('');
  const [thanks, setThanks] = useState(false);

  // Handle the redirect back from Stripe (?donate=success | ?donate=cancel).
  useEffect(() => {
    const p = new URLSearchParams(window.location.search);
    const d = p.get('donate');
    if (!d) return;
    window.history.replaceState({}, '', window.location.pathname + window.location.hash);
    if (d === 'success') { setThanks(true); setTimeout(() => setThanks(false), 7000); }
  }, []);

  const dollars = custom !== '' ? (parseFloat(custom) || 0) : amount;
  const cents   = Math.round(dollars * 100);

  const donate = async () => {
    setErr('');
    if (!cents || cents < 100) { setErr('Please enter at least $1.'); return; }
    setBusy(true);
    try {
      const res  = await fetch(`${API}/donate/checkout`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ amount_cents: cents, email: email || '' }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok && data.url) { window.location.href = data.url; return; }
      setErr(data.detail || 'Could not start donation.');
    } catch { setErr('Could not reach the server.'); }
    finally { setBusy(false); }
  };

  return (
    <FormSkin>
      {thanks && (
        <Alert type="success" showIcon
          message="Thank you for supporting FellowScript! 🙏"
          style={{ marginBottom: '1.5rem', borderRadius: 12 }} />
      )}

      <Button block icon={<HeartFilled style={{ color: '#e0698a' }} />} onClick={() => setOpen(true)}
        style={{
          marginBottom: '1.5rem', height: 46, borderRadius: 12,
          background: 'rgba(154,154,154,0.16)', border: '1px solid rgba(255,255,255,0.14)',
          color: 'var(--parchment)',
        }}>
        Support FellowScript
      </Button>

      <Modal
        open={open}
        onCancel={() => setOpen(false)}
        footer={null}
        title="Support FellowScript"
        destroyOnClose
      >
        <div className="ff-formstack">
          <p className="ff-helper" style={{ fontSize: 14, margin: 0 }}>
            FellowScript is built with love. If it has been a blessing to you, a one-time gift helps keep it growing and freely available. Thank you 🙏
          </p>
          {err && <div className="ff-alert" role="alert"><div className="ff-alert__title">{err}</div></div>}

          <div className="ff-field">
            <span className="ff-label" id="ff-donate-amount">Amount</span>
            <ChipGroup label="Donation amount" options={PRESETS.map(v => ({ value: v, label: `$${v}` }))}
              value={custom === '' ? amount : null}
              onChange={(v) => { setAmount(v); setCustom(''); }} />
          </div>

          <Field label="Other amount" value={custom} placeholder="0.00" inputMode="decimal" autoComplete="off"
            leading={<span aria-hidden="true">$</span>}
            onChange={(v) => setCustom(v.replace(/[^\d.]/g, ''))} />

          <StickyActionBar variant="page" primaryLabel={`Donate $${dollars.toFixed(2)}`} saving={busy}
            primaryDisabled={!cents || cents < 100} onPrimary={donate} />

          <p className="ff-helper ff-center" style={{ margin: 0 }}>Secure one-time payment via Stripe.</p>
        </div>
      </Modal>
    </FormSkin>
  );
}
