import React, { useState, useRef, useEffect } from 'react';
import { Button } from 'antd';
import { CopyOutlined, ShareAltOutlined } from '@ant-design/icons';
import { fetchFriendCode } from '../lib/promoCode.js';

// Task 20260930-creator-friend-codes. Personal friend invite code: generated
// on demand (the server creates it on the first click, then returns the same
// one), shown with copy / share. A friend who enters it at checkout gets
// percentOff off their first month. Rendered by SubscriptionCard only when the
// promo feature flag is on.
const LABEL = {
  fontFamily: "'Inter', sans-serif", fontSize: '0.56rem', letterSpacing: '0.3em',
  textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block',
};
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.35)' };

export default function FriendInviteCode({ userId, percentOff: knownPercent }) {
  const [data, setData] = useState(null);       // { code, link }
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState('');     // '' | 'code' | 'link' | 'failed'
  const timer = useRef(null);
  useEffect(() => () => clearTimeout(timer.current), []);

  const reveal = async () => {
    setBusy(true); setError('');
    try { setData(await fetchFriendCode(userId)); }
    catch { setError("Couldn't get your invite code. Please try again."); }
    finally { setBusy(false); }
  };

  const copy = async (what, text) => {
    let ok = false;
    try { await navigator.clipboard.writeText(text); ok = true; } catch { /* fall through */ }
    setCopied(ok ? what : 'failed');
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setCopied(''), 2000);
  };

  const share = async () => {
    const text = `Use my FellowScript code ${data.code} for ${offText} your first month.`;
    try { await navigator.share({ title: 'FellowScript', text, url: data.link }); }
    catch { /* dismissed or unavailable */ }
  };

  const percentOff = data?.percent_off ?? knownPercent;
  const offText = percentOff ? `${percentOff}% off` : 'a discount on';
  const canShare = typeof navigator !== 'undefined' && typeof navigator.share === 'function';

  return (
    <div style={{ marginTop: '1.2rem', paddingTop: '1rem', borderTop: '1px solid rgba(200,134,26,0.1)' }}>
      <span style={{ ...LABEL, marginBottom: '0.5rem' }}>Invite a friend</span>
      <p style={{ ...MUTED, margin: '0 0 0.7rem', lineHeight: 1.6 }}>
        Share your code. A friend who is new to paid plans gets {offText} their first month of an individual plan.
      </p>
      {!data ? (
        <Button size="small" loading={busy} onClick={reveal} style={{ borderRadius: 8, fontFamily: "'Inter', sans-serif" }}>
          Get my invite code
        </Button>
      ) : (
        <div>
          <div data-testid="friend-code" style={{ fontFamily: "'DM Serif Display', serif", fontSize: '1.3rem', letterSpacing: '0.12em', color: 'var(--gold)', marginBottom: '0.5rem' }}>
            {data.code}
          </div>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
            <Button size="small" icon={<CopyOutlined />} onClick={() => copy('code', data.code)} style={{ borderRadius: 8 }}>
              {copied === 'code' ? 'Copied' : 'Copy code'}
            </Button>
            <Button size="small" icon={<CopyOutlined />} onClick={() => copy('link', data.link)} style={{ borderRadius: 8 }}>
              {copied === 'link' ? 'Copied' : 'Copy link'}
            </Button>
            {canShare && (
              <Button size="small" icon={<ShareAltOutlined />} onClick={share} style={{ borderRadius: 8 }}>Share</Button>
            )}
            {copied === 'failed' && <span style={{ ...MUTED, color: '#e07b6a' }}>Copy failed. Select the code and copy it by hand.</span>}
          </div>
        </div>
      )}
      {error && <div role="alert" style={{ ...MUTED, color: '#e07b6a', marginTop: 6 }}>{error}</div>}
    </div>
  );
}
