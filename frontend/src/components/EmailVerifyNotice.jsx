// Task 20261007-email-verification. "Check your email" state with a resend
// control. Self-contained: asks GET /auth/email/status and renders nothing when
// the feature is off, the email is already verified, or the check fails (the
// server stays the enforcement; this is only UX). The resend cooldown is per
// user, so the control is always offered here, including right after an email
// change (pass the current email as `emailKey` to re-check on change).
import React, { useCallback, useEffect, useState } from 'react';
import { Alert, Button } from 'antd';
import { getEmailStatus, resendVerification } from '../lib/emailVerificationApi.js';

export default function EmailVerifyNotice({ emailKey, context }) {
  const [status, setStatus] = useState(null);
  const [wait, setWait] = useState(0);
  const [sending, setSending] = useState(false);
  const [msg, setMsg] = useState(null);

  useEffect(() => {
    let live = true;
    setStatus(null); setMsg(null);
    getEmailStatus().then((s) => { if (live) setStatus(s); }).catch(() => {});
    return () => { live = false; };
  }, [emailKey]);

  useEffect(() => {
    if (wait <= 0) return undefined;
    const t = setTimeout(() => setWait((n) => n - 1), 1000);
    return () => clearTimeout(t);
  }, [wait]);

  const resend = useCallback(async () => {
    setSending(true); setMsg(null);
    try {
      const r = await resendVerification();
      setMsg({ type: 'success', text: 'If a verification email is due, it is on its way. Check your inbox and spam folder.' });
      setWait(Number(r.resend_cooldown_seconds) || Number(status?.resend_cooldown_seconds) || 60);
    } catch (err) {
      if (err.status === 429) setMsg({ type: 'warning', text: 'Too many requests. Please wait a bit and try again.' });
      else setMsg({ type: 'error', text: err.message });
    } finally {
      setSending(false);
    }
  }, [status]);

  if (!status || !status.enabled || status.verified) return null;

  return (
    <Alert
      type="info" showIcon data-testid="email-verify-notice"
      style={{ marginBottom: 16 }}
      message={context === 'affiliates' ? 'Verify your email to use the creator program' : 'Check your email'}
      description={(
        <div>
          <p style={{ margin: '0 0 8px' }}>
            We sent a verification link to the email on your account. Open it to confirm the address is yours.
          </p>
          {msg && <p role="status" style={{ margin: '0 0 8px' }}>{msg.text}</p>}
          <Button size="small" onClick={resend} loading={sending} disabled={wait > 0}>
            {wait > 0 ? `Resend in ${wait}s` : 'Resend verification email'}
          </Button>
        </div>
      )}
    />
  );
}
