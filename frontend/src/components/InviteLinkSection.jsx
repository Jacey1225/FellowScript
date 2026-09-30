import React, { useState, useEffect, useRef, useCallback } from 'react';
import { Spin } from 'antd';
import {
  listGroupInvites, createGroupInvite, revokeInvite, resetGroupInvites,
} from '../lib/invitesApi.js';

// Task 20260929-group-invite-links (design-notes.md A). The "Invite link"
// section of the group info panel. The plaintext link exists only in this
// component's state right after creation (never stored anywhere, cleared on
// unmount); the list is metadata from the server. If the backend feature flag
// is off, list answers the uniform 404 and the whole section is hidden. The
// last server-confirmed list is cached per group so a failed refresh keeps it.

const listCache = new Map();
export function _clearInviteCaches() { listCache.clear(); }

const LEAVE_MS = 200;

function expiryLabel(iso, now = Date.now()) {
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return '';
  const ms = t - now;
  if (ms < 24 * 3600 * 1000) {
    const hours = Math.max(1, Math.ceil(ms / 3600000));
    return `Expires in ${hours} ${hours === 1 ? 'hour' : 'hours'}`;
  }
  return `Expires ${new Date(t).toLocaleDateString([], { month: 'short', day: 'numeric' })}`;
}

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

function createErrorCopy(err) {
  if (err.status === 409 && err.code === 'link_limit') return 'You have the maximum number of active links for this group. Revoke one to make another.';
  if (err.status === 429) return 'Too many tries. Wait a minute and try again.';
  if (err.status === 403) return "You can't create an invite link for this group.";
  return "Couldn't create the link. Please try again.";
}

export default function InviteLinkSection({ userId, groupId, reducedMotion = false, onForbidden }) {
  const mountedRef = useRef(true);
  const urlRef = useRef(null);
  const copyTimerRef = useRef(null);
  useEffect(() => {
    mountedRef.current = true;
    return () => { mountedRef.current = false; clearTimeout(copyTimerRef.current); };
  }, []);

  const [data, setData] = useState(null);            // { invites, options } last server-confirmed
  const [unavailable, setUnavailable] = useState(false);
  const [loadError, setLoadError] = useState(null);   // first-load failure (nothing cached)
  const [refreshError, setRefreshError] = useState(false);
  const [optionsOpen, setOptionsOpen] = useState(false);
  const [expiryDays, setExpiryDays] = useState(null);
  const [maxUses, setMaxUses] = useState(null);
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState(null);
  const [reveal, setReveal] = useState(null);         // { url } -- state only, never persisted
  const [copyState, setCopyState] = useState('idle'); // idle | copied | failed
  const [confirmId, setConfirmId] = useState(null);
  const [leavingIds, setLeavingIds] = useState([]);
  const [rowErrors, setRowErrors] = useState({});
  const [confirmReset, setConfirmReset] = useState(false);
  const [resetBusy, setResetBusy] = useState(false);
  const [resetStatus, setResetStatus] = useState(null);
  const [resetError, setResetError] = useState(null);

  const applyList = useCallback((next) => {
    listCache.set(groupId, next);
    setData(next);
  }, [groupId]);

  const load = useCallback(() => {
    if (!userId || !groupId) return () => {};
    let cancelled = false;
    const cached = listCache.get(groupId) || null;
    setData(cached); setUnavailable(false); setLoadError(null); setRefreshError(false);
    listGroupInvites(userId, groupId)
      .then((res) => {
        if (cancelled) return;
        const next = { invites: res.invites || [], options: res.options };
        listCache.set(groupId, next);
        setData(next);
        setExpiryDays((v) => v ?? next.options.default_expiry_days);
        setMaxUses((v) => v ?? next.options.default_max_uses);
      })
      .catch((err) => {
        if (cancelled) return;
        if (err.status === 404) { setUnavailable(true); listCache.delete(groupId); return; }
        if (err.status === 403) { onForbidden?.(err); return; }
        if (cached) setRefreshError(true);
        else setLoadError("Couldn't load invite links.");
      });
    return () => { cancelled = true; };
  }, [userId, groupId, onForbidden]);

  useEffect(() => {
    setReveal(null); setCreateError(null); setConfirmId(null); setOptionsOpen(false);
    setResetStatus(null); setResetError(null); setConfirmReset(false); setRowErrors({});
    setExpiryDays(null); setMaxUses(null); setCopyState('idle');
    return load();
  }, [load]);

  useEffect(() => {
    if (data?.options) {
      setExpiryDays((v) => v ?? data.options.default_expiry_days);
      setMaxUses((v) => v ?? data.options.default_max_uses);
    }
  }, [data]);

  useEffect(() => { if (reveal) urlRef.current?.focus(); }, [reveal]);

  if (unavailable) return null;

  const onCreate = async () => {
    if (creating || !data?.options) return;
    setCreating(true); setCreateError(null); setResetStatus(null);
    try {
      const res = await createGroupInvite(userId, groupId, { expiresInDays: expiryDays, maxUses });
      if (!mountedRef.current) return;
      setReveal({ url: res.url });
      setCopyState('idle');
      setOptionsOpen(false);
      const created = {
        invite_id: res.invite_id, created_by_username: null, is_mine: true,
        created_at: res.created_at, expires_at: res.expires_at,
        max_uses: res.max_uses, use_count: res.use_count, remaining_uses: res.max_uses - res.use_count,
      };
      applyList({ ...data, invites: [created, ...data.invites] });
    } catch (err) {
      if (!mountedRef.current) return;
      if (err.status === 404) { setUnavailable(true); return; }
      setCreateError(createErrorCopy(err));
    } finally {
      if (mountedRef.current) setCreating(false);
    }
  };

  const onCopy = async () => {
    if (!reveal) return;
    clearTimeout(copyTimerRef.current);
    try {
      await navigator.clipboard.writeText(reveal.url);
      setCopyState('copied');
      copyTimerRef.current = setTimeout(() => mountedRef.current && setCopyState('idle'), 2000);
    } catch {
      setCopyState('failed');
    }
  };

  const canShare = typeof navigator !== 'undefined' && typeof navigator.share === 'function';
  const onShare = async () => {
    if (!reveal) return;
    try {
      await navigator.share({ url: reveal.url });
    } catch {
      // User dismissed the share sheet (AbortError) or it failed: the link is
      // still on screen with Copy, nothing to report.
    }
  };

  const removeRow = (id) => {
    const drop = () => mountedRef.current && setData((prev) => {
      const next = { ...prev, invites: prev.invites.filter((i) => i.invite_id !== id) };
      listCache.set(groupId, next);
      return next;
    });
    if (reducedMotion) { drop(); return; }
    setLeavingIds((ids) => [...ids, id]);
    setTimeout(() => { drop(); if (mountedRef.current) setLeavingIds((ids) => ids.filter((x) => x !== id)); }, LEAVE_MS);
  };

  const onRevoke = async (inv) => {
    setRowErrors((e) => ({ ...e, [inv.invite_id]: null }));
    try {
      await revokeInvite(userId, inv.invite_id);
      if (!mountedRef.current) return;
      setConfirmId(null);
      removeRow(inv.invite_id);
    } catch (err) {
      if (!mountedRef.current) return;
      setConfirmId(null);
      const copy = err.status === 403
        ? 'Only the person who made this link, or the group creator, can revoke it.'
        : "Couldn't revoke. Please try again.";
      setRowErrors((e) => ({ ...e, [inv.invite_id]: copy }));
    }
  };

  const onReset = async () => {
    if (resetBusy) return;
    setResetBusy(true); setResetError(null);
    try {
      const res = await resetGroupInvites(userId, groupId);
      if (!mountedRef.current) return;
      setConfirmReset(false);
      setReveal(null);
      applyList({ ...data, invites: [] });
      setResetStatus(`${plural(res.revoked, 'link', 'links')} revoked`);
    } catch (err) {
      if (mountedRef.current) setResetError(err.status === 429 ? 'Too many tries. Wait a minute and try again.' : "Couldn't reset the links. Please try again.");
    } finally {
      if (mountedRef.current) setResetBusy(false);
    }
  };

  const invites = data?.invites || [];
  const options = data?.options;
  const still = reducedMotion ? ' group-info-still' : '';

  return (
    <section aria-label="Invite link" className={`group-info-invite${still}`}>
      <h3 className="group-info-label">Invite link</h3>

      {refreshError && (
        <div className="group-info-banner" role="status">
          <span>Couldn't refresh just now. Showing what we have.</span>
          <button type="button" className="group-info-text-btn" onClick={load}>Try again</button>
        </div>
      )}

      {!data && !loadError && <div className="group-info-skeleton-grid" aria-label="Loading invite links" />}
      {loadError && (
        <p className="group-info-error" role="alert">
          {loadError}{' '}
          <button type="button" className="group-info-text-btn" onClick={load}>Try again</button>
        </p>
      )}

      {data && (
        <>
          {invites.length === 0 && !reveal && (
            <p className="group-info-helper">Anyone with the link can join this group until it expires.</p>
          )}

          {reveal ? (
            <div className="group-info-invite-reveal">
              <div ref={urlRef} tabIndex={-1} className="group-info-invite-url" aria-label={`Invite link ${reveal.url}`}>
                {reveal.url}
              </div>
              <div className="group-info-invite-actions">
                <button type="button" className="group-info-pill" onClick={onCopy}>
                  {copyState === 'copied' ? 'Copied' : 'Copy'}
                </button>
                {canShare && <button type="button" className="group-info-secondary-pill group-info-invite-share" onClick={onShare}>Share</button>}
              </div>
              <span className="group-info-sr" aria-live="polite">{copyState === 'copied' ? 'Link copied' : ''}</span>
              {copyState === 'failed' && (
                <p className="group-info-error" role="alert">Couldn't copy. Select the link and copy it.</p>
              )}
              <p className="group-info-helper">This link is shown once. If you close this, make a new link to share again.</p>
              <button type="button" className="group-info-text-btn" onClick={() => setReveal(null)}>Done</button>
            </div>
          ) : (
            <div className="group-info-invite-create">
              <button type="button" className="group-info-pill" onClick={onCreate} disabled={creating || !options}>
                {creating ? <Spin size="small" /> : 'Create invite link'}
              </button>
              {options && (
                <button type="button" className="group-info-text-btn" aria-expanded={optionsOpen}
                  onClick={() => setOptionsOpen((v) => !v)}>
                  Expires in {plural(expiryDays ?? options.default_expiry_days, 'day', 'days')} · Up to {plural(maxUses ?? options.default_max_uses, 'person', 'people')}
                </button>
              )}
              {optionsOpen && options && (
                <div className="group-info-invite-options">
                  <div className="group-info-chips" role="radiogroup" aria-label="Link expires in">
                    {options.allowed_expiry_days.map((d) => (
                      <button key={d} type="button" role="radio" aria-checked={expiryDays === d}
                        className={`group-info-chip${expiryDays === d ? ' group-info-chip-on' : ''}`}
                        onClick={() => setExpiryDays(d)}>{plural(d, 'day', 'days')}</button>
                    ))}
                  </div>
                  <div className="group-info-chips" role="radiogroup" aria-label="Number of people who can join">
                    {options.allowed_max_uses.map((n) => (
                      <button key={n} type="button" role="radio" aria-checked={maxUses === n}
                        className={`group-info-chip${maxUses === n ? ' group-info-chip-on' : ''}`}
                        onClick={() => setMaxUses(n)}>{n === 1 ? '1' : n}</button>
                    ))}
                  </div>
                </div>
              )}
              {createError && <p className="group-info-error" role="alert">{createError}</p>}
            </div>
          )}

          {invites.length > 0 && (
            <>
              <p className="group-info-helper">Links can't be shown again after they're created.</p>
              <ul className="group-info-invite-list">
                {invites.map((inv) => {
                  const label = expiryLabel(inv.expires_at);
                  const who = inv.is_mine ? 'you' : inv.created_by_username;
                  const leaving = leavingIds.includes(inv.invite_id);
                  return (
                    <li key={inv.invite_id} className={`group-info-invite-row${leaving ? ' group-info-invite-leaving' : ''}`}>
                      <div className="group-info-invite-meta">
                        <span>{label}</span>
                        <span className="group-info-helper">
                          {inv.remaining_uses} of {inv.max_uses} spots left · Created by {who}
                        </span>
                        {rowErrors[inv.invite_id] && <span className="group-info-error" role="alert">{rowErrors[inv.invite_id]}</span>}
                      </div>
                      {confirmId === inv.invite_id ? (
                        <div className="group-info-invite-confirm" role="group" aria-label="Confirm revoke">
                          <span className="group-info-helper">Revoke this link? People with it will no longer be able to join.</span>
                          <div>
                            <button type="button" className="group-info-text-btn group-info-danger" onClick={() => onRevoke(inv)}>Revoke</button>
                            <button type="button" className="group-info-text-btn" onClick={() => setConfirmId(null)}>Cancel</button>
                          </div>
                        </div>
                      ) : (
                        <button type="button" className="group-info-text-btn group-info-danger"
                          aria-label={`Revoke link ${label.toLowerCase()}, created by ${who}`}
                          onClick={() => setConfirmId(inv.invite_id)}>Revoke</button>
                      )}
                    </li>
                  );
                })}
              </ul>
            </>
          )}

          {invites.length >= 2 && (
            confirmReset ? (
              <div className="group-info-invite-confirm" role="group" aria-label="Confirm reset all links">
                <span className="group-info-helper">Revoke all links you can manage? Nobody will be able to join with them.</span>
                <div>
                  <button type="button" className="group-info-text-btn group-info-danger" onClick={onReset} disabled={resetBusy}>
                    {resetBusy ? <Spin size="small" /> : 'Revoke all'}
                  </button>
                  <button type="button" className="group-info-text-btn" onClick={() => setConfirmReset(false)} disabled={resetBusy}>Cancel</button>
                </div>
                {resetError && <p className="group-info-error" role="alert">{resetError}</p>}
              </div>
            ) : (
              <button type="button" className="group-info-text-btn group-info-danger" onClick={() => { setConfirmReset(true); setResetError(null); }}>
                Reset all links
              </button>
            )
          )}
          {resetStatus && <p className="group-info-helper" role="status">{resetStatus}</p>}
        </>
      )}
    </section>
  );
}
