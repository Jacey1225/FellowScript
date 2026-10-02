import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../../context/AuthContext.jsx';
import { useCapabilities } from '../../hooks/useCapabilities.js';
import { setPendingExplore } from '../../lib/pendingInvite.js';
import { fetchMyRequests, requestToJoin, withdrawRequest, joinRequestsEnabled, NOTE_MAX } from '../../lib/joinRequestsApi.js';
import '../../styles/joinRequests.css';

// Task 20261001-explorer-join-requests step 7: the "Request to join" CTA on the
// Explore listing detail page (design B). Shown only when the join_requests
// capability is true (fail closed); a signed-out visitor sees a sign-in prompt
// that returns here through the single pendingExplore key and never
// auto-requests. Every "not possible" cause shows the same generic copy (no
// oracle). The note is plain text.
const GENERIC = "You can't request to join this group right now.";

export default function JoinCtaSlot({ listing }) {
  const { user } = useAuth() || {};
  const userId = user?.user_id || null;
  const caps = useCapabilities();
  const navigate = useNavigate();
  const publicId = listing?.public_id;
  const enabled = joinRequestsEnabled(caps?.features);
  const [state, setState] = useState('loading'); // loading | can | pending | member | blocked | error
  const [reqId, setReqId] = useState(null);
  const [note, setNote] = useState('');
  const [showNote, setShowNote] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);

  const load = useCallback(async () => {
    if (!userId || !enabled || !publicId) return;
    setState('loading'); setMsg('');
    try {
      const d = await fetchMyRequests(userId, publicId);
      if (!mounted.current) return;
      if (d.already_member) { setState('member'); return; }
      const latest = (d.requests || [])[0];
      if (latest?.status === 'pending') { setReqId(latest.id); setState('pending'); return; }
      if (latest?.status === 'not_approved') { setState('blocked'); return; }
      setState(listing?.requestable === false ? 'blocked' : 'can');
    } catch (err) {
      if (!mounted.current) return;
      setState(err?.status === 404 || err?.status === 403 ? 'blocked' : 'error');
    }
  }, [userId, enabled, publicId, listing?.requestable]);
  useEffect(() => { load(); }, [load]);

  const fail = (err) => {
    if (err?.status === 403 && err?.code === 'terms_reaccept_required') {
      Promise.resolve(caps?.refresh?.()).catch(() => {});
      setMsg('Please accept our updated Terms of Service to continue.');
    } else if (err?.status === 429) setMsg('Too many tries. Wait a moment and try again.');
    else if (err?.status === 0) setMsg("Couldn't reach FellowScript. Check your connection and try again.");
    else if (err?.status === 403 || err?.status === 404) setState('blocked');
    else setMsg("Couldn't send your request. Please try again.");
  };

  const send = async () => {
    if (busy) return;
    setBusy(true); setMsg('');
    try {
      const res = await requestToJoin(userId, publicId, note);
      if (!mounted.current) return;
      if (res?.status === 'already_member') setState('member');
      else { setReqId(res?.id || null); setState('pending'); setNote(''); }
    } catch (err) { if (mounted.current) fail(err); } finally { if (mounted.current) setBusy(false); }
  };

  const withdraw = async () => {
    if (busy || !reqId) return;
    setBusy(true); setMsg('');
    try {
      await withdrawRequest(userId, reqId);
      if (mounted.current) { setState('can'); setReqId(null); }
    } catch (err) {
      if (!mounted.current) return;
      if (err?.code === 'not_pending') load(); else setMsg("Couldn't withdraw your request. Please try again.");
    } finally { if (mounted.current) setBusy(false); }
  };

  const signIn = () => {
    setPendingExplore(`/explore/${encodeURIComponent(publicId)}`);
    navigate('/signin', { state: { tab: 'signin' } });
  };

  let body = null;
  if (!userId) {
    if (listing?.requestable !== true) return <div className="ex-join-slot" data-slot="join-cta" />;
    body = <button type="button" className="jr-btn jr-btn--primary" onClick={signIn}>Sign in to request to join</button>;
  } else if (!enabled) {
    return <div className="ex-join-slot" data-slot="join-cta" />;
  } else if (state === 'loading') {
    body = <div className="jr-skeleton" aria-hidden="true" />;
  } else if (state === 'can') {
    body = (
      <>
        <button type="button" className="jr-btn jr-btn--primary" onClick={send} disabled={busy}>{busy ? 'Sending...' : 'Request to join'}</button>
        {!showNote ? (
          <button type="button" className="jr-link" onClick={() => setShowNote(true)} aria-expanded="false">Add a note</button>
        ) : (
          <label className="jr-field">
            <span>Note (optional)</span>
            <textarea value={note} maxLength={NOTE_MAX} rows={3} onChange={(e) => setNote(e.target.value)} aria-describedby="jr-note-help" />
            <span id="jr-note-help" className="jr-helper">Only the group owner sees this. {note.length}/{NOTE_MAX}</span>
          </label>
        )}
        <p className="jr-helper">The owner will see your username and photo.</p>
      </>
    );
  } else if (state === 'pending') {
    body = (
      <>
        <span className="jr-chip">Request sent</span>
        <button type="button" className="jr-link" onClick={withdraw} disabled={busy}>Withdraw request</button>
      </>
    );
  } else if (state === 'member') {
    body = <span className="jr-chip">You're in this group</span>;
  } else if (state === 'error') {
    body = (<><p className="jr-error">Couldn't check your request.</p><button type="button" className="jr-btn" onClick={load}>Try again</button></>);
  } else {
    body = <p className="jr-helper">{GENERIC}</p>;
  }

  return (
    <div className="ex-join-slot jr-cta" data-slot="join-cta">
      {body}
      {msg && <p className="jr-error" role="alert">{msg}</p>}
    </div>
  );
}
