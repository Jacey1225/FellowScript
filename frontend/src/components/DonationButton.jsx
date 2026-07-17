import React, { useState, useEffect } from 'react';
import { Button, Modal, Input, Alert } from 'antd';
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
    <>
      {thanks && (
        <Alert type="success" showIcon
          message="Thank you for supporting FellowScript! 🙏"
          style={{ marginBottom: '1.5rem', borderRadius: 12 }} />
      )}

      <Button block icon={<HeartFilled style={{ color: '#e0698a' }} />} onClick={() => setOpen(true)}
        style={{
          marginBottom: '1.5rem', height: 46, borderRadius: 12,
          fontFamily: "'Lora', serif", letterSpacing: '0.06em',
          background: 'rgba(200,134,26,0.06)', border: '1px solid rgba(200,134,26,0.2)',
          color: 'var(--parchment)',
        }}>
        Support FellowScript
      </Button>

      <Modal
        open={open}
        onCancel={() => setOpen(false)}
        footer={null}
        title={<span style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>
          Support FellowScript
        </span>}
        destroyOnClose
      >
        <p style={{ fontFamily: "'Lora', serif", fontSize: '0.85rem', color: 'rgba(244,228,193,0.55)', lineHeight: 1.65, marginBottom: 16 }}>
          FellowScript is built with love. If it has been a blessing to you, a one-time gift helps keep it growing and freely available. Thank you 🙏
        </p>
        {err && <Alert type="error" message={err} showIcon style={{ marginBottom: 12, borderRadius: 8 }} />}

        <div style={{ display: 'flex', gap: 8, marginBottom: 12, flexWrap: 'wrap' }}>
          {PRESETS.map(v => {
            const sel = custom === '' && amount === v;
            return (
              <button key={v} onClick={() => { setAmount(v); setCustom(''); }}
                style={{
                  flex: 1, minWidth: 64, padding: '10px 0', borderRadius: 10, cursor: 'pointer',
                  border: `1px solid ${sel ? 'var(--gold)' : 'rgba(200,134,26,0.25)'}`,
                  background: sel ? 'rgba(200,134,26,0.18)' : 'transparent',
                  color: sel ? 'var(--gold)' : 'rgba(244,228,193,0.7)',
                  fontFamily: "'Lora', serif", fontSize: '0.95rem',
                }}>
                ${v}
              </button>
            );
          })}
        </div>

        <Input prefix="$" placeholder="Other amount" inputMode="decimal" value={custom}
          onChange={e => setCustom(e.target.value.replace(/[^\d.]/g, ''))}
          style={{ marginBottom: 16 }} />

        <Button type="primary" block loading={busy} onClick={donate} icon={<HeartFilled />}
          disabled={!cents || cents < 100}
          style={{ borderRadius: 8, height: 42, fontFamily: "'Lora', serif" }}>
          Donate ${dollars.toFixed(2)}
        </Button>

        <p style={{ fontFamily: "'Lora', serif", fontSize: '0.68rem', color: 'rgba(244,228,193,0.3)', marginTop: 12, marginBottom: 0, textAlign: 'center' }}>
          Secure one-time payment via Stripe.
        </p>
      </Modal>
    </>
  );
}
