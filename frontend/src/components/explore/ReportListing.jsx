import React, { useState } from 'react';
import { REPORT_REASONS, reportListing } from '../../lib/explorerApi.js';

// Report action. Signed in: a small inline form that sends the public_id.
// Signed out: a mailto link to the support address (no account needed).
export default function ReportListing({ publicId, signedIn, supportEmail }) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [detail, setDetail] = useState('');
  const [state, setState] = useState('idle'); // idle | sending | sent | error | busy
  const [msg, setMsg] = useState('');

  if (!signedIn) {
    if (!supportEmail) return null;
    const subject = encodeURIComponent(`Report a listing (${publicId})`);
    return <a className="ex-link" href={`mailto:${supportEmail}?subject=${subject}`}>Report a problem</a>;
  }

  if (state === 'sent') return <p className="ex-hint" role="status">Thanks. We will review this listing.</p>;

  const submit = async (e) => {
    e.preventDefault();
    if (!reason || state === 'sending') return;
    setState('sending'); setMsg('');
    try {
      await reportListing(publicId, reason, detail.trim().slice(0, 500));
      setState('sent');
    } catch (err) {
      setState(err.status === 429 ? 'busy' : 'error');
      setMsg(err.status === 429
        ? "You've sent a few reports already. Please try again later."
        : "Couldn't send your report. Please try again.");
    }
  };

  if (!open) {
    return <button type="button" className="ex-btn ex-btn--quiet" onClick={() => setOpen(true)} aria-expanded="false">Report</button>;
  }
  return (
    <form className="ex-report" onSubmit={submit} aria-label="Report this listing">
      <label className="ex-field">
        <span>Reason</span>
        <select value={reason} onChange={(e) => setReason(e.target.value)} required>
          <option value="">Choose a reason</option>
          {REPORT_REASONS.map((r) => <option key={r.value} value={r.value}>{r.label}</option>)}
        </select>
      </label>
      <label className="ex-field">
        <span>Details (optional)</span>
        <textarea value={detail} maxLength={500} rows={3} onChange={(e) => setDetail(e.target.value)} />
      </label>
      {msg && <p className="ex-error" role="alert">{msg}</p>}
      <div className="ex-report-actions">
        <button type="button" className="ex-btn ex-btn--quiet" onClick={() => setOpen(false)}>Cancel</button>
        <button type="submit" className="ex-btn ex-btn--primary" disabled={!reason || state === 'sending'}>
          {state === 'sending' ? 'Sending' : 'Send report'}
        </button>
      </div>
    </form>
  );
}
