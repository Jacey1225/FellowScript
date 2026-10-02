import React, { useState, useEffect, useRef, useCallback } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Spin } from 'antd';
import { useAuth } from '../context/AuthContext.jsx';
import { useCapabilities } from '../hooks/useCapabilities.js';
import AppBloom from '../components/AppBloom.jsx';
import AppNav from '../components/AppNav.jsx';
import Seo from '../components/Seo.jsx';
import { fetchMyRequests, withdrawRequest, dateLabel, joinRequestsEnabled } from '../lib/joinRequestsApi.js';
import { setPendingExplore } from '../lib/pendingInvite.js';
import '../styles/explore.css';
import '../styles/joinRequests.css';

// Task 20261001-explorer-join-requests step 7. /#/explore/requests: "My requests"
// (design D). Sign-in required; hidden unless the join_requests capability is on.
const STATUS = { pending: 'Pending', approved: 'Approved', not_approved: 'Not approved', withdrawn: 'Withdrawn' };

export default function ExploreRequests() {
  const { user } = useAuth() || {};
  const userId = user?.user_id || null;
  const caps = useCapabilities();
  const navigate = useNavigate();
  const headingRef = useRef(null);
  const [gate, setGate] = useState('checking');
  const [rows, setRows] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(null);

  useEffect(() => { if (!userId) setPendingExplore('/explore/requests'); }, [userId]);
  useEffect(() => {
    if (!userId) return undefined;
    let cancelled = false;
    Promise.resolve(caps?.refresh?.())
      .then((c) => { if (!cancelled) setGate(joinRequestsEnabled(c?.features) ? 'on' : 'off'); })
      .catch(() => { if (!cancelled) setGate('off'); });
    return () => { cancelled = true; };
  }, [userId]); // eslint-disable-line react-hooks/exhaustive-deps

  const load = useCallback(() => {
    if (!userId || gate !== 'on') return;
    setError(null);
    fetchMyRequests(userId)
      .then((d) => setRows(d.requests || []))
      .catch((e) => { if (e?.status === 404) setGate('off'); else setError("Couldn't load your requests."); });
  }, [userId, gate]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => { if (gate !== 'checking') headingRef.current?.focus(); }, [gate, rows]);

  const withdraw = async (id) => {
    if (busy) return;
    setBusy(id);
    try { await withdrawRequest(userId, id); load(); } catch { setError("Couldn't withdraw your request. Please try again."); } finally { setBusy(null); }
  };

  let content;
  if (!userId) {
    content = (
      <div className="ex-state">
        <h1 className="ex-state-title" ref={headingRef} tabIndex={-1}>Sign in to see your requests</h1>
        <button type="button" className="ex-btn ex-btn--primary" onClick={() => navigate('/signin', { state: { tab: 'signin' } })}>Sign in</button>
      </div>
    );
  } else if (gate === 'checking') {
    content = <div className="ex-center"><Spin size="large" aria-label="Loading" /></div>;
  } else if (gate === 'off') {
    content = (
      <div className="ex-state">
        <h1 className="ex-state-title" ref={headingRef} tabIndex={-1}>This page isn't available.</h1>
        <Link to="/explore" className="ex-link">Back to Explore</Link>
      </div>
    );
  } else {
    content = (
      <>
        <header className="ex-head">
          <h1 className="ex-h1" ref={headingRef} tabIndex={-1}>My requests</h1>
        </header>
        {error && <p className="ex-error" role="alert">{error}</p>}
        {rows === null && !error && <div className="ex-center"><Spin size="large" aria-label="Loading requests" /></div>}
        {rows && rows.length === 0 && <p className="ex-state-body">You haven't requested to join any groups.</p>}
        {rows && rows.length > 0 && (
          <ul className="jr-list" aria-label="My join requests">
            {rows.map((r) => (
              <li className="jr-row" key={r.id}>
                <div className="jr-row-main">
                  <div className="jr-row-body">
                    <p className="jr-name">
                      {r.public_id ? <Link className="ex-link" to={`/explore/${encodeURIComponent(r.public_id)}`}>{r.title || 'Group'}</Link> : (r.title || 'Group')}
                    </p>
                    <p className="jr-date"><span className="jr-chip">{STATUS[r.status] || 'Not approved'}</span> {dateLabel(r.created_at)}</p>
                  </div>
                </div>
                <div className="jr-actions">
                  {r.status === 'pending' && <button type="button" className="jr-btn" disabled={busy === r.id} onClick={() => withdraw(r.id)} aria-label={`Withdraw request to ${r.title || 'group'}`}>Withdraw</button>}
                </div>
              </li>
            ))}
          </ul>
        )}
      </>
    );
  }
  return (
    <div className="ex-page">
      <Seo title="My requests — FellowScript Explore" path="/explore/requests" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <main className="ex-main ex-main--narrow">
        {content}
        <p className="ex-foot"><Link to="/explore" className="ex-link">Back to Explore</Link></p>
      </main>
    </div>
  );
}
