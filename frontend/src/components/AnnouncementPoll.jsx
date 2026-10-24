import React, { useState } from 'react';

// Poll block of the announcement detail view (task 20261024-announcement-polls). Live counts for
// every member; votes are anonymous (the server only ever sends counts plus the caller's own
// selection). Voting again replaces the previous choice. Closed polls keep their results.
// `actions` = { vote(optionIds), retract(), close() }; each resolves to the updated announcement.

export default function AnnouncementPoll({ item, actions }) {
  const poll = item.poll;
  const [override, setOverride] = useState(null); // updated poll from the last action
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  if (!poll) return null;
  const p = override || poll;
  const mine = new Set(p.my_votes || []);
  const canVote = !!actions && !p.closed && item.published !== false;
  const best = Math.max(0, ...p.options.map((o) => o.votes));

  const run = async (fn) => {
    if (busy) return;
    setBusy(true); setError(null);
    try {
      const updated = await fn();
      if (updated?.poll) setOverride(updated.poll);
    } catch (err) {
      setError(err?.status === 409 ? 'This poll just closed.' : (err?.message || "Couldn't update the poll. Please try again."));
    } finally {
      setBusy(false);
    }
  };

  const toggle = (optionId) => {
    if (!canVote) return;
    if (p.multiple) {
      const next = new Set(mine);
      if (next.has(optionId)) next.delete(optionId); else next.add(optionId);
      if (next.size === 0) { run(() => actions.retract()); return; }
      run(() => actions.vote([...next]));
    } else if (!mine.has(optionId)) {
      run(() => actions.vote([optionId]));
    }
  };

  const total = p.total_voters || 0;
  const closes = p.closes_at ? new Date(p.closes_at) : null;
  return (
    <section className="ann-extra-block" aria-label="Poll">
      <h4 className="ann-extra-heading">Poll</h4>
      <div className="ann-card ann-card-static ann-poll">
        <p className="ann-poll-question">{p.question}</p>
        <ul className="ann-poll-options" role={p.multiple ? 'group' : 'radiogroup'} aria-label={p.question}>
          {p.options.map((o) => {
            const selected = mine.has(o.id);
            return (
              <li key={o.id}>
                <button type="button" className={`ann-poll-option${selected ? ' ann-poll-option-on' : ''}${p.closed && o.votes === best && best > 0 ? ' ann-poll-option-lead' : ''}`}
                  role={p.multiple ? 'checkbox' : 'radio'} aria-checked={selected}
                  aria-disabled={!canVote || undefined} disabled={busy && !p.closed}
                  aria-label={`${o.label}, ${o.votes} ${o.votes === 1 ? 'vote' : 'votes'}, ${o.percent}%${selected ? ', your choice' : ''}`}
                  onClick={() => toggle(o.id)}>
                  <span className="ann-poll-fill" style={{ width: `${o.percent}%` }} aria-hidden="true" />
                  <span className="ann-poll-mark" aria-hidden="true">{selected ? (p.multiple ? '✓' : '●') : (p.multiple ? '' : '○')}</span>
                  <span className="ann-poll-label">{o.label}</span>
                  <span className="ann-poll-pct" aria-hidden="true">{o.percent}%</span>
                </button>
              </li>
            );
          })}
        </ul>
        <div className="ann-poll-foot" aria-live="polite">
          <span className="ann-card-sub">
            {total} {total === 1 ? 'person has' : 'people have'} voted
            {p.multiple ? ' · pick all that apply' : ''}
            {p.closed ? ' · Poll closed' : (closes ? ` · closes ${closes.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}` : '')}
          </span>
          {canVote && mine.size > 0 && (
            <button type="button" className="group-info-text-btn" disabled={busy} onClick={() => run(() => actions.retract())}>Clear my vote</button>
          )}
          {item.can_edit && !p.closed && actions?.close && (
            <button type="button" className="group-info-text-btn" disabled={busy} onClick={() => run(() => actions.close())}>Close poll</button>
          )}
        </div>
        {error && <p className="group-info-error" role="alert">{error}</p>}
        <p className="ann-note">Votes are anonymous. Only counts are shown.</p>
      </div>
    </section>
  );
}
