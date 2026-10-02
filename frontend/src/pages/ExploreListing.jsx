import React, { useState, useEffect, useRef, useCallback } from 'react';
import { useParams, Link } from 'react-router-dom';
import { Spin } from 'antd';
import { useAuth } from '../context/AuthContext.jsx';
import AppBloom from '../components/AppBloom.jsx';
import AppNav from '../components/AppNav.jsx';
import { useWarmCanvas } from '../hooks/useWarmCanvas.js';
import Seo from '../components/Seo.jsx';
import ListingHero from '../components/explore/ListingHero.jsx';
import DescriptionBlocks from '../components/explore/DescriptionBlocks.jsx';
import JoinCtaSlot from '../components/explore/JoinCtaSlot.jsx';
import ReportListing from '../components/explore/ReportListing.jsx';
import { labelFor, placeLine } from '../components/explore/exploreLabels.js';
import { fetchFilters, fetchListing, isWellFormedPublicId } from '../lib/explorerApi.js';
import { useCountdown } from '../hooks/useCountdown.js';
import '../styles/explore.css';

// Task 20261001-explorer-listings step 9. /#/explore/:publicId, public detail.
// The heading takes focus on route entry; the description is rendered by the
// restricted markdown renderer only.

export const COPY = {
  gone: { title: "This group isn't listed anymore.", body: null },
  rate: { title: 'Lots of people are looking right now.', body: 'Wait a moment and try again.' },
  network: { title: "Couldn't reach FellowScript.", body: 'Check your connection and try again.' },
};

function kindOf(err) {
  if (err.status === 404) return 'gone';
  if (err.status === 429) return 'rate';
  return 'network';
}

const CHIP_GROUPS = [
  ['denominations', 'denominations', 'Denomination'],
  ['goals', 'goals', 'Goals'],
  ['practices', 'practices', 'Practices'],
  ['hobbies', 'hobbies', 'Hobbies'],
  ['age_ranges', 'age_ranges', 'Age range'],
  ['life_stages', 'life_stages', 'Life stage'],
  ['languages', 'languages', 'Language'],
];

export default function ExploreListing() {
  useWarmCanvas();
  const { publicId } = useParams();
  const { user } = useAuth();
  const headingRef = useRef(null);
  const valid = isWellFormedPublicId(publicId);
  const [phase, setPhase] = useState(valid ? 'loading' : 'error');
  const [listing, setListing] = useState(null);
  const [meta, setMeta] = useState(null);
  const [errKind, setErrKind] = useState(valid ? null : 'gone');
  const [retryAfter, setRetryAfter] = useState(null);

  useEffect(() => {
    let cancelled = false;
    fetchFilters().then((m) => { if (!cancelled) setMeta(m); }).catch(() => {});
    return () => { cancelled = true; };
  }, []);

  const load = useCallback(() => {
    if (!valid) return () => {};
    let cancelled = false;
    setPhase('loading'); setErrKind(null);
    fetchListing(publicId)
      .then((d) => { if (!cancelled) { setListing(d); setPhase('ready'); } })
      .catch((e) => {
        if (cancelled) return;
        setErrKind(kindOf(e)); setRetryAfter(e.retryAfter ?? null); setPhase('error');
      });
    return () => { cancelled = true; };
  }, [publicId, valid]);

  useEffect(() => load(), [load]);
  useEffect(() => { if (phase !== 'loading') headingRef.current?.focus(); }, [phase]);

  const wait = useCountdown(errKind === 'rate' ? (retryAfter ?? 5) : 0);
  const vocab = meta?.vocab;

  let content;
  if (phase === 'loading') {
    content = <div className="ex-center"><Spin size="large" aria-label="Loading group" /></div>;
  } else if (phase === 'error') {
    const c = COPY[errKind || 'gone'];
    content = (
      <div className="ex-state" role="alert">
        <h1 className="ex-state-title" ref={headingRef} tabIndex={-1}>{c.title}</h1>
        {c.body && <p className="ex-state-body">{c.body}</p>}
        {(errKind === 'rate' || errKind === 'network') && (
          <button type="button" className="ex-btn ex-btn--primary" onClick={load} disabled={wait > 0}>
            {wait > 0 ? `Try again in ${wait}s` : 'Try again'}
          </button>
        )}
        <Link to="/explore" className="ex-link">Back to Explore</Link>
      </div>
    );
  } else {
    const l = listing;
    const place = placeLine(l);
    const full = l.seats === 'full';
    content = (
      <article className="ex-detail">
        <ListingHero listing={l} size="detail" as="h1" headingRef={headingRef} />
        <div className="ex-detail-grid">
          <div className="ex-detail-main">
            {l.summary && <p className="ex-detail-summary">{l.summary}</p>}
            <div className="ex-meta">
              {place && <p className="ex-meta-line">{place}</p>}
              {l.church_name && <p className="ex-meta-line">{l.church_name}</p>}
              <p className="ex-meta-line">
                {l.size_bucket} members
                <span className={`ex-seat ex-seat--${full ? 'full' : 'open'}`}>{full ? 'Full' : 'Open'}</span>
              </p>
            </div>
            {[...CHIP_GROUPS, ['meeting_format', 'meeting_formats', 'Meeting format'], ['frequency', 'frequencies', 'Frequency'], ['gender_makeup', 'gender_makeup', 'Group makeup']].map(([field, vocabKey, title]) => {
              const raw = l[field];
              const values = Array.isArray(raw) ? raw : (raw ? [raw] : []);
              if (!values.length) return null;
              return (
                <div className="ex-chipgroup" key={field}>
                  <h2 className="ex-chipgroup-title">{title}</h2>
                  <ul className="ex-chip-row">
                    {values.map((s) => <li className="ex-chip" key={s}>{labelFor(vocab, vocabKey, s)}</li>)}
                  </ul>
                </div>
              );
            })}
            {l.free_tags?.length > 0 && (
              <div className="ex-chipgroup">
                <h2 className="ex-chipgroup-title">Tags</h2>
                <ul className="ex-chip-row">
                  {l.free_tags.map((t) => <li className="ex-chip" key={t}>{t}</li>)}
                </ul>
              </div>
            )}
            <DescriptionBlocks blocks={l.description_blocks} />
          </div>
          <aside className="ex-detail-side" aria-label="Join">
            <JoinCtaSlot listing={l} />
          </aside>
        </div>
        <footer className="ex-detail-foot">
          <ReportListing publicId={l.public_id} signedIn={!!user} supportEmail={meta?.support_email} />
        </footer>
        <p className="ex-foot"><Link to="/explore" className="ex-link">Back to Explore</Link></p>
      </article>
    );
  }

  return (
    <div className="ex-page">
      <Seo title={`${phase === 'ready' && listing ? listing.title : 'Group'} — FellowScript Explore`} path="/explore" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <main className="ex-main" aria-busy={phase === 'loading'}>{content}</main>
    </div>
  );
}
