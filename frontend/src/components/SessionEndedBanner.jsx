import React from 'react';
import { Button } from 'antd';
import { useAuth } from '../context/AuthContext.jsx';
import { useSessionEnded } from '../hooks/useSessionEnded.js';
import { SESSION_ENDED_MESSAGE } from '../lib/sessionEnd.js';

// Shown when the server rejected the sign-in session (401). Chat/note state
// already on screen stays readable; "Sign in" runs the normal sign-out flow
// (which also ends the stale server session) and the app returns to sign-in.
export default function SessionEndedBanner() {
  const { user, signOut } = useAuth() || {};
  const ended = useSessionEnded();
  if (!ended || !user?.user_id) return null;
  return (
    <div
      role="alert"
      className="fs-session-ended"
      style={{
        position: 'fixed', top: 12, left: '50%', transform: 'translateX(-50%)',
        zIndex: 2000, display: 'flex', alignItems: 'center', gap: 12,
        padding: '8px 14px', borderRadius: 8,
        background: 'var(--bg-elevated, #1a1a1a)', color: 'var(--parchment, #F2F2F2)',
        border: '1px solid var(--gold, #FFC61A)', boxShadow: '0 4px 16px rgba(0,0,0,0.4)',
        fontFamily: "'Lora', serif", fontSize: '0.9rem',
      }}
    >
      <span>{SESSION_ENDED_MESSAGE}</span>
      <Button type="primary" size="small" onClick={signOut}>Sign in</Button>
    </div>
  );
}
