import React, { useState, useEffect, useRef, useCallback, useMemo } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { Spin } from 'antd';
import { useAuth } from '../context/AuthContext.jsx';
import { useCapabilities } from '../hooks/useCapabilities.js';
import { useCountdown } from '../hooks/useCountdown.js';
import AppBloom from '../components/AppBloom.jsx';
import AppNav from '../components/AppNav.jsx';
import { useWarmCanvas } from '../hooks/useWarmCanvas.js';
import Seo from '../components/Seo.jsx';
import JoinRequestsList from '../components/JoinRequestsList.jsx';
import ListingForm from '../components/explore/ListingForm.jsx';
import ListingPreview from '../components/explore/ListingPreview.jsx';
import {
  bodyFromForm, emptyForm, formFromListing, formSignature, imageBlocksMissingAlt, unreferencedImageIds,
} from '../components/explore/listingForm.js';
import { STATUS_COPY, describeOwnerError, reasonLabel } from '../components/explore/manageStatus.js';
import {
  fetchOwnerOptions, fetchOwnerGroups, fetchOwnerListing, saveOwnerListing,
  submitOwnerListing, unpublishOwnerListing, deleteOwnerListing,
} from '../lib/explorerOwnerApi.js';
import { deleteListingMedia } from '../lib/listingMediaApi.js';
import { setPendingExplore } from '../lib/pendingInvite.js';
import { showUpgradePrompt } from '../lib/upgradePrompt.js';
import '../styles/explore.css';

// Task 20261001-explorer-listings step 10. /#/explore/manage: owner-only,
// text-only publish page (sign-in required, explorer_publish capability,
// fail closed). A group owner picks a group (?group=<id> preselects it),
// fills in the details, previews, then submits for review with consent and
// the adult attestation. Status, edit, unpublish and delete live here too.
// Photo, banner and description images (task 20261002-explorer-listing-media)
// upload straight away from the form once the draft exists. Wording of the consent block is
// owned by the legal-copy task and kept together in CONSENT_COPY.

export const CONSENT_COPY = {
  consent: "I understand this group's listing (name, summary, details, description, church and general location) will be public on the FellowScript website for anyone to see, including people who are not signed in. It never shows a street address, and my name is not shown.",
  adult: 'I am 18 or over, and this group is for adults 18 and over. It is not for teens, youth or minors.',
  accepting: 'Let people ask to join (you approve every request)',
};

const GROUP_ID_RE = /^[A-Za-z0-9-]{8,64}$/;
const LIVE = ['pending_review', 'published'];

function GatePage({ title, children, headingRef }) {
  return (
    <div className="ex-page">
      <Seo title="Publish to Explore — FellowScript" description="Publish your group to Explore." path="/explore/manage" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <main className="ex-main ex-main--narrow">
        <div className="ex-state">
          <h1 className="ex-state-title" ref={headingRef} tabIndex={-1}>{title}</h1>
          {children}
        </div>
      </main>
    </div>
  );
}

export default function ExploreManage() {
  useWarmCanvas();
  const { user } = useAuth() || {};
  const userId = user?.user_id || null;
  const { refresh, features } = useCapabilities() || {};
  const joinOn = features?.join_requests === true;
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const wantedGroup = params.get('group');
  const wantedValid = wantedGroup && GROUP_ID_RE.test(wantedGroup) ? wantedGroup : null;
  const headingRef = useRef(null);

  const [gate, setGate] = useState('checking'); // checking | on | off
  const [options, setOptions] = useState(null);
  const [groupsData, setGroupsData] = useState(null);
  const [loadError, setLoadError] = useState(null);
  const [groupId, setGroupId] = useState(null);
  const [listing, setListing] = useState(null);
  const [listingLoading, setListingLoading] = useState(false);
  const [form, setForm] = useState(null);
  const [savedSig, setSavedSig] = useState('');
  const [showPreview, setShowPreview] = useState(false);
  const [consent, setConsent] = useState(false);
  const [adult, setAdult] = useState(false);
  const [accepting, setAccepting] = useState(true);
  const [busy, setBusy] = useState(null); // save | submit | unpublish | delete
  const [notice, setNotice] = useState(null); // { kind: 'ok'|'error', message, retryAfter }
  const [confirmDelete, setConfirmDelete] = useState(false);
  const mounted = useRef(true);
  const loadSeq = useRef(0);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);

  // Signed out: remember where to come back to after sign-in.
  useEffect(() => {
    if (userId) return;
    setPendingExplore(wantedValid ? `/explore/manage?group=${wantedValid}` : '/explore/manage');
  }, [userId, wantedValid]);

  // Capability gate (fail closed): only a fresh answer of explorer_publish=true opens the page.
  useEffect(() => {
    if (!userId) return undefined;
    let cancelled = false;
    setGate('checking');
    Promise.resolve(refresh())
      .then((c) => { if (!cancelled) setGate(c?.features?.explorer_publish === true ? 'on' : 'off'); })
      .catch(() => { if (!cancelled) setGate('off'); });
    return () => { cancelled = true; };
  }, [userId, refresh]);

  const loadGroups = useCallback(async () => {
    const data = await fetchOwnerGroups(userId);
    if (mounted.current) setGroupsData(data);
    return data;
  }, [userId]);

  const handleError = useCallback((err) => {
    // Free-plan block on publish: shared themed upgrade modal (task 20261002-free-plan-limits-ui).
    if (err?.blocked) {
      showUpgradePrompt(err.blocked);
      return { kind: 'blocked', message: '' };
    }
    const d = describeOwnerError(err);
    if (d.kind === 'off') { setGate('off'); return d; }
    if (d.kind === 'auth') { navigate('/signin', { replace: true }); return d; }
    if (d.kind === 'terms') refresh();
    setNotice({ kind: 'error', message: d.message, retryAfter: err?.retryAfter ?? null, terms: d.kind === 'terms' });
    return d;
  }, [navigate, refresh]);

  // Initial load: options and the owner's groups.
  const loadInitial = useCallback(() => {
    if (!userId || gate !== 'on') return;
    setLoadError(null);
    Promise.all([fetchOwnerOptions(userId), fetchOwnerGroups(userId)])
      .then(([opts, groups]) => {
        if (!mounted.current) return;
        setOptions(opts);
        setGroupsData(groups);
        const list = groups.groups || [];
        const pick = (wantedValid && list.find((g) => g.group_id === wantedValid))
          || (list.length === 1 ? list[0] : null);
        if (pick) setGroupId(pick.group_id);
      })
      .catch((err) => {
        if (!mounted.current) return;
        const d = describeOwnerError(err);
        if (d.kind === 'off') setGate('off');
        else setLoadError(d);
      });
  }, [userId, gate, wantedValid]);
  useEffect(() => { loadInitial(); }, [loadInitial]);

  const group = useMemo(
    () => (groupsData?.groups || []).find((g) => g.group_id === groupId) || null,
    [groupsData, groupId],
  );

  // Load the selected group's own listing (404 = none yet: blank form).
  useEffect(() => {
    if (!groupId || !group) return undefined;
    const seq = ++loadSeq.current;
    setListingLoading(true); setNotice(null); setConfirmDelete(false);
    setConsent(false); setAdult(false); setAccepting(true); setShowPreview(false);
    const apply = (l) => {
      if (seq !== loadSeq.current || !mounted.current) return;
      const f = formFromListing(l, group.title);
      setListing(l); setForm(f); setSavedSig(l ? formSignature(f) : '');
      setListingLoading(false);
    };
    fetchOwnerListing(userId, groupId)
      .then(apply)
      .catch((err) => {
        if (seq !== loadSeq.current || !mounted.current) return;
        if (err?.status === 404) { apply(null); return; }
        setListingLoading(false);
        handleError(err);
      });
    return () => { loadSeq.current += 1; };
    // group.title only seeds a blank form; reload on group change only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [groupId, userId]);

  useEffect(() => {
    if (gate !== 'checking' && (groupsData || loadError || gate === 'off' || !userId)) headingRef.current?.focus();
  }, [gate, groupsData, loadError, userId]);

  const wait = useCountdown(notice?.retryAfter || 0);

  const status = listing?.status || null;
  const readOnly = status === 'hidden';
  const dirty = form ? formSignature(form) !== savedSig : false;
  const showAccepting = !status || status === 'draft' || status === 'rejected';

  const missingAlt = form ? imageBlocksMissingAlt(form).length > 0 : false;

  // Photo/banner/image changed on the server: patch local state at once, then
  // refresh the status (a change on a live listing sends it back for review).
  const onMediaChange = useCallback(({ kind, item, removed }) => {
    setListing((cur) => {
      if (!cur) return cur;
      let media = cur.media || [];
      const patch = {};
      if (removed) {
        media = media.filter((m) => m.media_id !== removed);
        if (kind === 'photo') patch.photo_url = null;
        if (kind === 'banner') { patch.banner_url = null; patch.banner_alt = null; }
      } else if (item) {
        media = kind === 'image' ? [...media, item] : [...media.filter((m) => m.kind !== kind), item];
        if (kind === 'photo') patch.photo_url = item.url;
        if (kind === 'banner') { patch.banner_url = item.url; patch.banner_alt = item.alt_text; }
      }
      return { ...cur, ...patch, media };
    });
    fetchOwnerListing(userId, groupId)
      .then((l) => {
        if (!mounted.current) return;
        setListing((cur) => (cur ? { ...cur, status: l.status, reject_reason_code: l.reject_reason_code, hidden_reason_code: l.hidden_reason_code } : cur));
        loadGroups().catch(() => {});
      })
      .catch(() => {});
  }, [userId, groupId, loadGroups]);

  const save = async () => {
    const saved = await saveOwnerListing(userId, groupId, bodyFromForm(form));
    if (!mounted.current) return saved;
    setListing(saved);
    setSavedSig(formSignature(form));
    // Description images no paragraph block points at any more are released (best effort).
    const stale = unreferencedImageIds(saved.media, form.blocks);
    if (stale.length) {
      Promise.all(stale.map((id) => deleteListingMedia(userId, groupId, id).catch(() => null)))
        .then(() => fetchOwnerListing(userId, groupId))
        .then((l) => { if (mounted.current && l) setListing(l); })
        .catch(() => {});
    }
    return saved;
  };

  const run = async (kind, fn, okMessage) => {
    if (busy) return;
    setBusy(kind); setNotice(null);
    try {
      await fn();
      if (!mounted.current) return;
      await loadGroups().catch(() => {});
      if (okMessage && mounted.current) setNotice({ kind: 'ok', message: okMessage });
    } catch (err) {
      if (mounted.current) handleError(err);
    } finally {
      if (mounted.current) setBusy(null);
    }
  };

  const onSave = () => run('save', save, 'Saved.');

  const onSubmit = () => run('submit', async () => {
    if (dirty || !listing) await save();
    const res = await submitOwnerListing(userId, groupId, {
      consent: true,
      adult_attested: true,
      ...(showAccepting ? { accepting_requests: accepting } : {}),
    });
    if (mounted.current) { setListing(res); setConsent(false); setAdult(false); }
  }, null);

  const onUnpublish = () => run('unpublish', async () => {
    const res = await unpublishOwnerListing(userId, groupId);
    if (mounted.current) setListing(res);
  }, 'Your listing is no longer shown on Explore.');

  const onDelete = () => run('delete', async () => {
    await deleteOwnerListing(userId, groupId);
    if (mounted.current) {
      setListing(null); setConfirmDelete(false);
      const f = emptyForm(group?.title || '');
      setForm(f); setSavedSig('');
    }
  }, 'Your listing was deleted.');

  // ---- rendering -----------------------------------------------------------

  if (!userId) {
    return (
      <GatePage title="Sign in to publish your group" headingRef={headingRef}>
        <p className="ex-state-body">Publishing a group to Explore needs a FellowScript account.</p>
        <div className="ex-actions">
          <button type="button" className="ex-btn ex-btn--primary" onClick={() => navigate('/signin', { state: { tab: 'signin' } })}>Sign in</button>
          <button type="button" className="ex-btn ex-btn--pill" onClick={() => navigate('/signin', { state: { tab: 'signup' } })}>Create an account</button>
        </div>
      </GatePage>
    );
  }
  if (gate === 'checking') {
    return <GatePage title="Publish to Explore" headingRef={headingRef}><Spin size="large" aria-label="Loading" /></GatePage>;
  }
  if (gate === 'off') {
    return (
      <GatePage title="This page isn't available." headingRef={headingRef}>
        <Link to="/" className="ex-link">Back to home</Link>
      </GatePage>
    );
  }
  if (loadError) {
    return (
      <GatePage title="We couldn't load this page." headingRef={headingRef}>
        <p className="ex-state-body">{loadError.message}</p>
        <button type="button" className="ex-btn ex-btn--primary" onClick={loadInitial}>Try again</button>
      </GatePage>
    );
  }
  if (!groupsData || !options) {
    return <GatePage title="Publish to Explore" headingRef={headingRef}><Spin size="large" aria-label="Loading" /></GatePage>;
  }

  const groups = groupsData.groups || [];
  const statusCopy = status ? STATUS_COPY[status] : null;
  const supportMail = options.support_email ? `mailto:${options.support_email}?subject=${encodeURIComponent('Explore listing question')}` : null;
  const canSubmit = !!form && !readOnly && !LIVE.includes(status) && consent && adult && !!form.title.trim() && !missingAlt && !busy;

  return (
    <div className="ex-page">
      <Seo title="Publish to Explore — FellowScript" description="Publish your group to Explore." path="/explore/manage" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <main className="ex-main ex-main--narrow">
        <header className="ex-head">
          <h1 className="ex-h1" ref={headingRef} tabIndex={-1}>Publish to Explore</h1>
          <p className="ex-sub">Let adults looking for a group find yours. You approve everyone who asks to join.</p>
        </header>

        <div className="ex-sr-only" role="status" aria-live="polite">{notice?.kind === 'ok' ? notice.message : ''}</div>

        {groups.length === 0 ? (
          <div className="ex-state">
            <p className="ex-state-title">You haven't created a group yet.</p>
            <p className="ex-state-body">Only the person who created a group can publish it. Create one in the FellowScript app, then come back.</p>
            <Link to="/reader" className="ex-link">Open FellowScript</Link>
          </div>
        ) : (
          <>
            <div className="ex-form-section">
              {groups.length > 1 ? (
                <label className="ex-field">
                  <span>Group</span>
                  <select value={groupId || ''} onChange={(e) => { setGroupId(e.target.value || null); setForm(null); setListing(null); }}>
                    <option value="">Choose a group</option>
                    {groups.map((g) => (
                      <option key={g.group_id} value={g.group_id}>
                        {g.title}{g.listing ? ` (${STATUS_COPY[g.listing.status]?.label || g.listing.status})` : ''}
                      </option>
                    ))}
                  </select>
                </label>
              ) : (
                <p className="ex-meta-line"><strong>{groups[0].title}</strong></p>
              )}
              <p className="ex-hint">{groupsData.listings_used} of {groupsData.listing_cap} listings used.</p>
            </div>

            {listingLoading && <div className="ex-center"><Spin size="large" aria-label="Loading listing" /></div>}

            {!listingLoading && groupId && form && (
              <>
                {statusCopy && (
                  <section className={`ex-status ex-status--${status}`} aria-labelledby="ex-status-h">
                    <h2 id="ex-status-h" className="ex-status-h">
                      Status: <span className="ex-status-pill">{statusCopy.label}</span>
                    </h2>
                    <p className="ex-hint">{statusCopy.body}</p>
                    {status === 'rejected' && listing.reject_reason_code && <p className="ex-status-reason">{reasonLabel(listing.reject_reason_code)}</p>}
                    {status === 'hidden' && (
                      <>
                        {listing.hidden_reason_code && <p className="ex-status-reason">{reasonLabel(listing.hidden_reason_code)}</p>}
                        <p className="ex-hint">
                          If you think this is a mistake, email{' '}
                          {supportMail ? <a className="ex-link" href={supportMail}>{options.support_email}</a> : 'support'}.
                        </p>
                      </>
                    )}
                    {status === 'published' && listing.public_id && (
                      <Link to={`/explore/${encodeURIComponent(listing.public_id)}`} className="ex-link">View your public listing</Link>
                    )}
                    {LIVE.includes(status) && <p className="ex-hint">Changing the text sends your listing back for review.</p>}
                  </section>
                )}

                <ListingForm form={form} onChange={setForm} options={options} disabled={readOnly || !!busy}
                  media={options.media ? { userId, groupId, listing, options: options.media, onChange: onMediaChange, disabled: readOnly || !!busy } : null} />
                {missingAlt && <p className="ex-error" role="alert">Every image needs a description before you can save.</p>}

                {notice?.kind === 'error' && (
                  <p className="ex-error" role="alert">
                    {notice.message}
                    {notice.terms && ' You will see the Updated Terms prompt.'}
                    {wait > 0 && ` Try again in ${wait}s.`}
                  </p>
                )}
                {notice?.kind === 'ok' && <p className="ex-ok">{notice.message}</p>}

                <div className="ex-actions">
                  <button type="button" className="ex-btn ex-btn--pill" onClick={onSave}
                    disabled={readOnly || !!busy || !dirty || !form.title.trim() || missingAlt || wait > 0}>
                    {busy === 'save' ? <Spin size="small" /> : (listing ? 'Save changes' : 'Save draft')}
                  </button>
                  <button type="button" className="ex-btn ex-btn--quiet" onClick={() => setShowPreview((v) => !v)}
                    aria-expanded={showPreview} aria-controls="ex-preview">
                    {showPreview ? 'Hide preview' : 'Preview'}
                  </button>
                </div>

                {showPreview && (
                  <div id="ex-preview" className="ex-preview-wrap">
                    <p className="ex-hint">This is how visitors will see your listing.</p>
                    <ListingPreview
                      vocab={options.vocab}
                      listing={{
                        ...bodyFromForm(form),
                        photo_url: listing?.photo_url || null,
                        banner_url: listing?.banner_url || null,
                        banner_alt: listing?.banner_alt || null,
                        media: listing?.media || [],
                      }}
                    />
                  </div>
                )}

                {!readOnly && !LIVE.includes(status) && (
                  <section className="ex-form-section ex-submit" aria-labelledby="ex-submit-h">
                    <h2 id="ex-submit-h" className="ex-form-h">Submit for review</h2>
                    <label className="ex-check">
                      <input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} />
                      <span>{CONSENT_COPY.consent}{' '}
                        <Link to="/terms" target="_blank" className="ex-link">Terms</Link>{' · '}
                        <Link to="/privacy" target="_blank" className="ex-link">Privacy</Link>
                      </span>
                    </label>
                    <label className="ex-check">
                      <input type="checkbox" checked={adult} onChange={(e) => setAdult(e.target.checked)} />
                      <span>{CONSENT_COPY.adult}</span>
                    </label>
                    {showAccepting && (
                      <label className="ex-check">
                        <input type="checkbox" checked={accepting} onChange={(e) => setAccepting(e.target.checked)} />
                        <span>{CONSENT_COPY.accepting}</span>
                      </label>
                    )}
                    <p className="ex-hint">A person reviews every listing before it appears, usually within 24 hours.</p>
                    <div className="ex-actions">
                      <button type="button" className="ex-btn ex-btn--primary" onClick={onSubmit} disabled={!canSubmit || wait > 0}>
                        {busy === 'submit' ? <Spin size="small" /> : 'Submit for review'}
                      </button>
                    </div>
                  </section>
                )}

                {listing && (
                  <section className="ex-form-section ex-danger" aria-labelledby="ex-manage-h">
                    <h2 id="ex-manage-h" className="ex-form-h">Manage</h2>
                    <div className="ex-actions">
                      {LIVE.includes(status) && (
                        <button type="button" className="ex-btn ex-btn--pill" onClick={onUnpublish} disabled={!!busy}>
                          {busy === 'unpublish' ? <Spin size="small" /> : 'Unpublish'}
                        </button>
                      )}
                      {!confirmDelete ? (
                        <button type="button" className="ex-btn ex-btn--quiet" onClick={() => setConfirmDelete(true)} disabled={!!busy}>
                          Delete listing
                        </button>
                      ) : (
                        <span className="ex-confirm" role="group" aria-label="Confirm delete">
                          <span className="ex-hint">Delete this listing for good? Your group is not affected.</span>
                          <button type="button" className="ex-btn ex-btn--danger" onClick={onDelete} disabled={!!busy}>
                            {busy === 'delete' ? <Spin size="small" /> : 'Yes, delete'}
                          </button>
                          <button type="button" className="ex-btn ex-btn--quiet" onClick={() => setConfirmDelete(false)} disabled={!!busy}>Keep it</button>
                        </span>
                      )}
                    </div>
                  </section>
                )}

                {/* Join requests (join-requests task): hidden unless the capability is true. */}
<div className="ex-join-requests-slot" data-slot="join-requests">
                  {joinOn && listing && (
                    <section className="ex-form-section" aria-labelledby="ex-jr-h">
                      <h2 id="ex-jr-h" className="ex-form-h">Join requests</h2>
                      <JoinRequestsList userId={userId} groupId={groupId} />
                    </section>
                  )}
                </div>
              </>
            )}
          </>
        )}

        <p className="ex-foot">
          {joinOn && <><Link to="/explore/requests" className="ex-link">My requests</Link>{' · '}</>}
          <Link to="/explore" className="ex-link">Back to Explore</Link>
        </p>
      </main>
    </div>
  );
}
