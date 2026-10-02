import React, { useState, useEffect, useRef, useCallback } from 'react';
import { useCapabilities } from '../hooks/useCapabilities.js';
import AcceptRequestsSwitch from './AcceptRequestsSwitch.jsx';
import { REPORT_REASONS } from '../lib/explorerApi.js';
import {
  fetchGroupRequests, approveRequest, denyRequest, undoDenyRequest, setAccepting,
  reportApplicant, blockApplicant, dateLabel, UNDO_FALLBACK_MS,
} from '../lib/joinRequestsApi.js';
import '../styles/joinRequests.css';

// Task 20261001-explorer-join-requests step 7. One shared owner list used on the
// manage page tab and in the group info section (design Proposal 1: flat inline
// list). SECURITY: applicant usernames and notes are untrusted and are rendered
// as plain React text nodes only (never HTML, never markdown, never a link);
// applicant_user_id is used solely for Report and Block.

const NOTE_CLAMP = 120;

function errText(err, fallback) {
  if (err?.code === 'group_full') return 'Group is full. Raise the member limit or remove someone, then approve.';
  if (err?.code === 'busy') return 'Busy, try again.';
  if (err?.status === 429) return 'Too many tries. Wait a moment and try again.';
  if (err?.status === 0) return "Couldn't reach FellowScript. Check your connection.";
  return fallback;
}

function Row({ req, state, actions }) {
  const { id, username, profile_photo_url: photo, note, created_at: at } = req;
  const [expanded, setExpanded] = useState(false);
  const [menu, setMenu] = useState(false);
  const [mode, setMode] = useState(null); // confirmApprove | report | confirmBlock
  const [reason, setReason] = useState('');
  const busy = state.busy === id;
  const long = typeof note === 'string' && note.length > NOTE_CLAMP;
  const shown = long && !expanded ? `${note.slice(0, NOTE_CLAMP)}...` : note;
  const name = username || 'Someone';
  return (
    <li className="jr-row" data-request-id={id}>
      <div className="jr-row-main">
        {photo ? <img className="jr-avatar" src={photo} alt="" width="40" height="40" referrerPolicy="no-referrer" /> : <span className="jr-avatar jr-avatar--blank" aria-hidden="true" />}
        <div className="jr-row-body">
          <p className="jr-name">{name}</p>
          <p className="jr-date">Requested {dateLabel(at)}</p>
          {note ? (
            <p className="jr-note">
              {shown}
              {long && (
                <button type="button" className="jr-link" onClick={() => setExpanded((v) => !v)} aria-expanded={expanded}>
                  {expanded ? 'Show less' : 'Show more'}
                </button>
              )}
            </p>
          ) : null}
        </div>
      </div>
      {state.rowError[id] && <p className="jr-error" role="alert">{state.rowError[id]}</p>}
      {state.rowInfo[id] && <p className="jr-helper" role="status">{state.rowInfo[id]}</p>}

      {mode === 'confirmApprove' ? (
        <div className="jr-confirm" role="group" aria-label={`Confirm approving ${name}`}>
          <span className="jr-helper">Add {name} to the group?</span>
          <button type="button" className="jr-btn jr-btn--primary" disabled={busy} onClick={async () => { await actions.approve(req); setMode(null); }}>Add</button>
          <button type="button" className="jr-btn" onClick={() => setMode(null)}>Cancel</button>
        </div>
      ) : mode === 'report' ? (
        <form className="jr-confirm" aria-label={`Report ${name}`} onSubmit={async (e) => { e.preventDefault(); if (!reason) return; await actions.report(req, reason); setMode(null); setMenu(false); }}>
          <label className="jr-field"><span>Reason</span>
            <select value={reason} onChange={(e) => setReason(e.target.value)} required>
              <option value="">Choose a reason</option>
              {REPORT_REASONS.filter((r) => r.value !== 'not_adults_only').map((r) => <option key={r.value} value={r.value}>{r.label}</option>)}
            </select>
          </label>
          <button type="submit" className="jr-btn jr-btn--primary" disabled={!reason || busy}>Send report</button>
          <button type="button" className="jr-btn" onClick={() => setMode(null)}>Cancel</button>
        </form>
      ) : mode === 'confirmBlock' ? (
        <div className="jr-confirm" role="group" aria-label={`Confirm blocking ${name}`}>
          <span className="jr-helper">Block {name}? You will not see each other's activity.</span>
          <button type="button" className="jr-btn jr-btn--primary" disabled={busy} onClick={async () => { await actions.block(req); setMode(null); setMenu(false); }}>Block</button>
          <button type="button" className="jr-btn" onClick={() => setMode(null)}>Cancel</button>
        </div>
      ) : (
        <div className="jr-actions">
          <button type="button" className="jr-btn jr-btn--primary" disabled={busy} aria-label={`Approve ${name}`} onClick={() => setMode('confirmApprove')}>Approve</button>
          <button type="button" className="jr-btn" disabled={busy} aria-label={`Deny ${name}`} onClick={() => actions.deny(req, false)}>Deny</button>
          <button type="button" className="jr-btn jr-btn--quiet" aria-expanded={menu} aria-label={`More actions for ${name}`} onClick={() => setMenu((v) => !v)}>More</button>
        </div>
      )}
      {menu && !mode && (
        <div className="jr-menu" role="group" aria-label={`More actions for ${name}`}>
          <button type="button" className="jr-btn jr-btn--quiet" disabled={busy} onClick={() => actions.deny(req, true)}>Deny and block from requesting again</button>
          <button type="button" className="jr-btn jr-btn--quiet" onClick={() => setMode('report')}>Report</button>
          <button type="button" className="jr-btn jr-btn--quiet" onClick={() => setMode('confirmBlock')}>Block</button>
        </div>
      )}
    </li>
  );
}

export default function JoinRequestsList({ userId, groupId, onCount }) {
  const caps = useCapabilities();
  const [data, setData] = useState(null);
  const [phase, setPhase] = useState('loading'); // loading | ready | none | error
  const [listError, setListError] = useState(null);
  const [accepting, setAcceptingState] = useState(true);
  const [switchError, setSwitchError] = useState(null);
  const [switchBusy, setSwitchBusy] = useState(false);
  const [busy, setBusy] = useState(null);
  const [rowError, setRowError] = useState({});
  const [rowInfo, setRowInfo] = useState({});
  const [toast, setToast] = useState(null); // { req, block, seconds }
  const [announce, setAnnounce] = useState('');
  const mounted = useRef(true);
  const seq = useRef(0);
  const timer = useRef(null);
  const listRef = useRef(null);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; clearTimeout(timer.current); }; }, []);

  const handleTerms = useCallback((err) => {
    if (err?.status === 403 && err?.code === 'terms_reaccept_required') {
      Promise.resolve(caps?.refresh?.()).catch(() => {});
      return 'Please accept our updated Terms of Service to continue.';
    }
    return null;
  }, [caps]);

  const load = useCallback(async () => {
    const my = ++seq.current;
    setListError(null);
    try {
      const d = await fetchGroupRequests(userId, groupId);
      if (my !== seq.current || !mounted.current) return;
      setData(d); setAcceptingState(d.accepting_requests !== false); setPhase('ready');
    } catch (err) {
      if (my !== seq.current || !mounted.current) return;
      if (err?.status === 404) { setPhase('none'); return; }
      setListError(handleTerms(err) || errText(err, "Couldn't load join requests."));
      setPhase((p) => (p === 'ready' ? 'ready' : 'error'));
    }
  }, [userId, groupId, handleTerms]);
  useEffect(() => { setPhase('loading'); setData(null); setToast(null); load(); }, [load]);

  const requests = data?.requests || [];
  const count = data ? (data.pending_count ?? requests.length) : 0;
  useEffect(() => { if (onCount) onCount(phase === 'ready' ? requests.length : 0); }, [phase, requests.length, onCount]);

  const removeRow = (id) => setData((d) => (d ? { ...d, pending_count: Math.max(0, (d.pending_count || 1) - 1), requests: d.requests.filter((r) => r.id !== id) } : d));
  const setErr = (id, msg) => setRowError((m) => ({ ...m, [id]: msg }));

  const actions = {
    approve: async (req) => {
      setBusy(req.id); setErr(req.id, null);
      try {
        await approveRequest(userId, groupId, req.id);
        if (!mounted.current) return;
        removeRow(req.id); setAnnounce(`${req.username || 'Someone'} was added to the group.`);
        listRef.current?.focus();
      } catch (err) {
        if (!mounted.current) return;
        if (err?.code === 'no_longer_available' || err?.code === 'not_pending') {
          removeRow(req.id); setAnnounce('No longer available.'); return;
        }
        setErr(req.id, handleTerms(err) || errText(err, "Couldn't approve this request."));
      } finally { if (mounted.current) setBusy(null); }
    },
    deny: async (req, block) => {
      setBusy(req.id); setErr(req.id, null);
      try {
        const res = await denyRequest(userId, groupId, req.id, block);
        if (!mounted.current) return;
        removeRow(req.id);
        const ms = (Number(res?.undo_seconds) || 0) * 1000 || UNDO_FALLBACK_MS;
        setToast({ req, block, ms });
        setAnnounce('Request denied. Undo available.');
        listRef.current?.focus();
      } catch (err) {
        if (!mounted.current) return;
        if (err?.code === 'not_pending') { removeRow(req.id); return; }
        setErr(req.id, handleTerms(err) || errText(err, "Couldn't deny this request."));
      } finally { if (mounted.current) setBusy(null); }
    },
    report: async (req, reason) => {
      setErr(req.id, null);
      try {
        await reportApplicant(req.applicant_user_id, reason);
        if (mounted.current) setRowInfo((m) => ({ ...m, [req.id]: 'Thanks. We will review this report.' }));
      } catch (err) { if (mounted.current) setErr(req.id, errText(err, "Couldn't send your report. Please try again.")); }
    },
    block: async (req) => {
      setErr(req.id, null);
      try {
        await blockApplicant(userId, req.applicant_user_id);
        if (mounted.current) setRowInfo((m) => ({ ...m, [req.id]: 'Blocked. You can still approve or deny this request.' }));
      } catch (err) { if (mounted.current) setErr(req.id, errText(err, "Couldn't block this person. Please try again.")); }
    },
  };

  // Undo toast: auto-dismisses after the server's undo window (10 s by default),
  // paused while the toast has focus so a keyboard user can reach Undo.
  const armToast = useCallback((ms) => {
    clearTimeout(timer.current);
    timer.current = setTimeout(() => { if (mounted.current) setToast(null); }, ms);
  }, []);
  useEffect(() => { if (toast) armToast(toast.ms); return () => clearTimeout(timer.current); }, [toast, armToast]);

  const undo = async () => {
    const t = toast;
    if (!t) return;
    clearTimeout(timer.current); setToast(null);
    try {
      await undoDenyRequest(userId, groupId, t.req.id);
      if (mounted.current) setAnnounce('Denial undone.');
    } catch {
      if (mounted.current) setListError('That denial can no longer be undone.');
    }
    if (mounted.current) load();
  };

  const toggle = async (next) => {
    if (switchBusy) return;
    const prev = accepting;
    setAcceptingState(next); setSwitchError(null); setSwitchBusy(true);
    try {
      await setAccepting(userId, groupId, next);
    } catch (err) {
      if (mounted.current) { setAcceptingState(prev); setSwitchError(handleTerms(err) || "Couldn't update. Try again."); }
    } finally { if (mounted.current) setSwitchBusy(false); }
  };

  if (phase === 'loading') {
    return <div className="jr" aria-busy="true"><div className="jr-skeleton" aria-hidden="true" /><span className="jr-sr">Loading join requests</span></div>;
  }
  if (phase === 'none') {
    return <div className="jr"><p className="jr-helper">Publish this group to the Explorer to accept requests.</p></div>;
  }
  if (phase === 'error') {
    return (
      <div className="jr">
        <p className="jr-error" role="alert">{listError}</p>
        <button type="button" className="jr-btn" onClick={() => { setPhase('loading'); load(); }}>Try again</button>
      </div>
    );
  }

  return (
    <div className="jr">
      <AcceptRequestsSwitch checked={accepting} onChange={toggle} disabled={switchBusy} error={switchError} />
      {requests.length > 0 && <p className="jr-count" aria-label={`${count} pending ${count === 1 ? 'request' : 'requests'}`}>{count} pending</p>}
      {listError && (
        <p className="jr-error" role="alert">{listError}{' '}<button type="button" className="jr-link" onClick={load}>Try again</button></p>
      )}
      {!accepting && <p className="jr-helper">New requests are paused. Pending requests below stay open.</p>}
      <div className="jr-sr" role="status" aria-live="polite">{announce}</div>
      <div ref={listRef} tabIndex={-1} className="jr-list-wrap">
        {requests.length === 0 ? (
          <p className="jr-helper">No requests yet.</p>
        ) : (
          <ul className="jr-list" aria-label="Pending join requests">
            {requests.map((r) => <Row key={r.id} req={r} state={{ busy, rowError, rowInfo }} actions={actions} />)}
          </ul>
        )}
      </div>
      {toast && (
        <div className="jr-toast" role="status" onFocus={() => clearTimeout(timer.current)} onBlur={() => armToast(toast.ms)}>
          <span>Request denied.</span>
          <button type="button" className="jr-btn jr-btn--primary" onClick={undo}>Undo</button>
        </div>
      )}
    </div>
  );
}
