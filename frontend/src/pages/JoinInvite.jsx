import React, { useState, useEffect, useRef, useCallback } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { Avatar, Spin } from 'antd';
import { useAuth } from '../context/AuthContext.jsx';
import AppBloom from '../components/AppBloom.jsx';
import Seo from '../components/Seo.jsx';
import { isDesktopApp } from '../lib/desktopScope.js';
import {
  previewInvite, redeemInvite, isWellFormedInviteToken,
} from '../lib/invitesApi.js';
import {
  setPendingInvite, clearPendingInvite, setGroupToOpen,
} from '../lib/pendingInvite.js';

// Task 20260929-group-invite-links (design-notes.md B, C). /#/join/<token>.
// Preview is public, so the group and inviter show signed out; joining needs
// a session. Nothing here fabricates: an unusable token is the backend's
// uniform not-found, every other failure is shown with a way out, and the
// pending invite is only cleared on a terminal outcome (success, 404/410/409/
// 403, Cancel) -- it survives 429/5xx/network so "Try again" works.

export const COPY = {
  invalid: { title: "This invite link isn't valid anymore", body: 'It may have expired, been revoked, or reached its limit. Ask the person who invited you for a new link.' },
  expired: { title: 'This invite link has expired.', body: 'Ask the person who invited you for a new link.' },
  revoked: { title: 'This invite link was revoked.', body: 'Ask the person who invited you for a new link.' },
  full: { title: 'This invite link has reached its limit.', body: 'Ask the person who invited you for a new link.' },
  blocked: { title: "You can't join this group.", body: null },
  otherPlan: { title: "You're already on a paid plan.", body: 'Leave your current plan first, then open this link again to request a seat.' },
  blockedPlan: { title: "You can't request to join this plan.", body: null },
  rate: { title: 'Too many tries.', body: 'Wait a minute and try again.' },
  network: { title: "Couldn't reach FellowScript.", body: 'Check your connection and try again.' },
};

function errorKind(err) {
  if (err.status === 0 || err.status >= 500) return 'network';
  if (err.status === 429) return 'rate';
  if (err.status === 404) return 'invalid';
  if (err.status === 410) return err.code === 'revoked' ? 'revoked' : 'expired';
  if (err.status === 409) return err.code === 'other_plan' ? 'otherPlan' : 'full';
  if (err.status === 403) return 'blocked';
  return 'network';
}
const RETRYABLE = new Set(['rate', 'network']);

export default function JoinInvite() {
  const { token } = useParams();
  const { user } = useAuth();
  const navigate = useNavigate();
  const headingRef = useRef(null);
  const mountedRef = useRef(true);
  const validToken = isWellFormedInviteToken(token);
  const desktop = isDesktopApp();

  // phase: resolving | ready | joining | done | error
  const [phase, setPhase] = useState(validToken ? 'resolving' : 'error');
  const [preview, setPreview] = useState(null);
  const [errKind, setErrKind] = useState(validToken ? null : 'invalid');
  const [outcome, setOutcome] = useState(null); // subscription: 'requested' | 'member'
  const [errAction, setErrAction] = useState(null); // 'preview' | 'redeem'

  useEffect(() => { mountedRef.current = true; return () => { mountedRef.current = false; }; }, []);

  // A different link replaces whatever was pending (no silent merge).
  useEffect(() => { if (validToken) setPendingInvite(token); }, [token, validToken]);

  const fail = useCallback((err, action) => {
    const kind = errorKind(err);
    if (!RETRYABLE.has(kind)) clearPendingInvite();
    setErrKind(kind); setErrAction(action); setPhase('error');
  }, []);

  const loadPreview = useCallback(() => {
    if (!validToken) return () => {};
    let cancelled = false;
    setPhase('resolving'); setErrKind(null);
    previewInvite(token)
      .then((data) => { if (!cancelled) { setPreview(data); setPhase('ready'); } })
      .catch((err) => { if (!cancelled) fail(err, 'preview'); });
    return () => { cancelled = true; };
  }, [token, validToken, fail]);

  useEffect(() => loadPreview(), [loadPreview]);

  useEffect(() => { if (phase !== 'resolving') headingRef.current?.focus(); }, [phase]);

  const goToGroup = (groupId) => {
    clearPendingInvite();
    if (desktop) {
      setGroupToOpen(groupId);
      navigate('/reader', { replace: true });
    } else {
      setPhase('done');
    }
  };

  const onJoin = async () => {
    if (phase === 'joining' || !user) return;
    setPhase('joining');
    try {
      const res = await redeemInvite(user.user_id, token);
      if (!mountedRef.current) return;
      if (res.kind === 'subscription') {
        // A request, not membership: the plan owner still has to approve.
        clearPendingInvite();
        setOutcome(res.already_member ? 'member' : 'requested');
        setPhase('done');
        return;
      }
      goToGroup(res.target_id);
    } catch (err) {
      if (!mountedRef.current) return;
      if (err.status === 401) {
        // Session is gone: keep the pending invite and go sign in.
        setPhase('ready');
        navigate('/signin', { state: { tab: 'signin' } });
        return;
      }
      fail(err, 'redeem');
    }
  };

  const onCancel = () => { clearPendingInvite(); navigate('/'); };
  const onRetry = () => { if (errAction === 'redeem') { setPhase('ready'); onJoin(); } else loadPreview(); };
  const leave = () => { navigate('/'); };

  const isSub = preview?.kind === 'subscription';
  const groupName = preview?.group_name || 'this group';
  const initial = groupName[0].toUpperCase();

  let content;
  if (phase === 'resolving') {
    content = (
      <div className="join-body" role="status">
        <Spin />
        <p className="join-helper">Checking this invite...</p>
      </div>
    );
  } else if (phase === 'error') {
    const base = COPY[errKind] || COPY.invalid;
    const c = isSub && errKind === 'blocked' ? COPY.blockedPlan : base;
    const canRetry = RETRYABLE.has(errKind) && errAction;
    content = (
      <div className="join-body" role="alert">
        <h1 ref={headingRef} tabIndex={-1} className="join-heading">{c.title}</h1>
        {c.body && <p className="join-copy">{c.body}</p>}
        {canRetry && <button type="button" className="join-pill" onClick={onRetry}>Try again</button>}
        <button type="button" className={canRetry ? 'join-text-btn' : 'join-pill'} onClick={leave}>Back to FellowScript</button>
      </div>
    );
  } else if (phase === 'done' && isSub) {
    content = (
      <div className="join-body" role="status">
        <h1 ref={headingRef} tabIndex={-1} className="join-heading">
          {outcome === 'member' ? "You're already on this plan" : 'Request sent'}
        </h1>
        <p className="join-copy">
          {outcome === 'member'
            ? 'You already have access through this plan.'
            : `${preview?.inviter_username || 'The plan owner'} has to approve your request. You get access to the plan once they accept it.`}
        </p>
        <Link className="join-pill" to={desktop ? '/reader' : '/download'}>{desktop ? 'Back to FellowScript' : 'Get the app'}</Link>
      </div>
    );
  } else if (phase === 'done') {
    content = (
      <div className="join-body" role="status">
        <h1 ref={headingRef} tabIndex={-1} className="join-heading">You're in</h1>
        <p className="join-copy">You joined {groupName}. Open the FellowScript app to chat with the group.</p>
        <Link className="join-pill" to="/download">Get the app</Link>
      </div>
    );
  } else if (isSub) {
    const joining = phase === 'joining';
    content = (
      <div className="join-body">
        <h1 ref={headingRef} tabIndex={-1} className="join-heading">Request to join {preview?.inviter_username}'s plan</h1>
        <p className="join-copy">
          {preview?.inviter_username} invited you to their FellowScript plan.
          <br />
          They approve each request before you get access.
        </p>
        {user ? (
          <>
            <button type="button" className="join-pill join-pill-wide" onClick={onJoin} disabled={joining}>
              {joining ? <Spin size="small" /> : 'Request to join'}
            </button>
            <button type="button" className="join-text-btn" onClick={onCancel} disabled={joining}>Cancel</button>
          </>
        ) : (
          <>
            <button type="button" className="join-pill join-pill-wide"
              onClick={() => navigate('/signin', { state: { tab: 'signin' } })}>Sign in to request</button>
            <button type="button" className="join-text-btn"
              onClick={() => navigate('/signin', { state: { tab: 'signup' } })}>Create an account</button>
            <button type="button" className="join-text-btn" onClick={onCancel}>Cancel</button>
          </>
        )}
      </div>
    );
  } else {
    const joining = phase === 'joining';
    content = (
      <div className="join-body">
        <Avatar size={96} src={preview?.photo_url || undefined}
          style={{ background: 'rgba(255,198,26,0.12)', color: 'var(--gold)', fontSize: '2.2rem' }}>{initial}</Avatar>
        <h1 ref={headingRef} tabIndex={-1} className="join-heading">{preview?.group_name}</h1>
        <p className="join-copy">
          Invited by {preview?.inviter_username}
          <br />
          {preview?.member_count} {preview?.member_count === 1 ? 'member' : 'members'}
        </p>
        {user ? (
          <>
            <button type="button" className="join-pill join-pill-wide" onClick={onJoin} disabled={joining}>
              {joining ? <Spin size="small" /> : 'Join group'}
            </button>
            <button type="button" className="join-text-btn" onClick={onCancel} disabled={joining}>Cancel</button>
          </>
        ) : (
          <>
            <button type="button" className="join-pill join-pill-wide"
              onClick={() => navigate('/signin', { state: { tab: 'signin' } })}>Sign in to join</button>
            <button type="button" className="join-text-btn"
              onClick={() => navigate('/signin', { state: { tab: 'signup' } })}>Create an account</button>
            <button type="button" className="join-text-btn" onClick={onCancel}>Cancel</button>
          </>
        )}
      </div>
    );
  }

  return (
    <div className="join-page">
      <Seo title="Join a group — FellowScript" description="Join a FellowScript group with an invite link." path="/join" noindex />
      <AppBloom variant="account" />
      <main className="join-column">{content}</main>
    </div>
  );
}
