import React, { useState, useEffect, useRef, useCallback, useMemo } from 'react';
import { Link } from 'react-router-dom';
import { Spin } from 'antd';
import AppBloom from '../components/AppBloom.jsx';
import AppNav from '../components/AppNav.jsx';
import Seo from '../components/Seo.jsx';
import ListingCard from '../components/explore/ListingCard.jsx';
import FilterPanel, { countActiveFilters, MULTI_FACETS, SINGLE_FACETS } from '../components/explore/FilterPanel.jsx';
import { labelFor } from '../components/explore/exploreLabels.js';
import { fetchFilters, fetchListings } from '../lib/explorerApi.js';
import { useCountdown } from '../hooks/useCountdown.js';
import '../styles/explore.css';

// Task 20261001-explorer-listings step 9. /#/explore: public (signed-out)
// gallery of published group listings with a filter sheet (design Proposal A).
// Explicit "Load more" (never infinite scroll). noindex: HashRouter routes are
// not crawlable and listings are deliberately not indexed in this task.

export const COPY = {
  rate: { title: 'Lots of people are looking right now.', body: 'Wait a moment and try again.' },
  network: { title: "Couldn't reach FellowScript.", body: 'Check your connection and try again.' },
  filter: { title: "Those filters didn't work.", body: 'Clear them and try a different search.' },
  off: { title: "This page isn't available.", body: null },
};

export function errorKind(err) {
  if (err.status === 404) return 'off';
  if (err.status === 429) return 'rate';
  if (err.status === 422) return 'filter';
  return 'network';
}

export default function Explore() {
  const [meta, setMeta] = useState(null);
  const [query, setQuery] = useState('');
  const [applied, setApplied] = useState({ q: '', filters: {}, includeFull: false });
  const [items, setItems] = useState([]);
  const [page, setPage] = useState(null);
  const [phase, setPhase] = useState('loading'); // loading | ready | error
  const [loadingMore, setLoadingMore] = useState(false);
  const [err, setErr] = useState(null); // { kind, retryAfter, more }
  const [sheetOpen, setSheetOpen] = useState(false);
  const reqRef = useRef(0);
  const filterBtnRef = useRef(null);
  const headingRef = useRef(null);

  // Vocabulary for labels and the filter sheet. Failure only disables the
  // sheet and falls back to raw slugs; browsing still works.
  useEffect(() => {
    let cancelled = false;
    fetchFilters().then((m) => { if (!cancelled) setMeta(m); }).catch(() => {});
    return () => { cancelled = true; };
  }, []);

  const load = useCallback((state, cursor) => {
    const id = ++reqRef.current;
    const more = !!cursor;
    if (more) setLoadingMore(true); else { setPhase('loading'); setErr(null); }
    fetchListings(state.filters, {
      q: state.q, includeFull: state.includeFull, cursor,
      limit: meta?.limits?.page_size_default,
    })
      .then((res) => {
        if (id !== reqRef.current) return;
        const incoming = Array.isArray(res.listings) ? res.listings : [];
        setItems((prev) => {
          if (!more) return incoming;
          const seen = new Set(prev.map((l) => l.public_id));
          return [...prev, ...incoming.filter((l) => !seen.has(l.public_id))];
        });
        setPage(res.page || null);
        setPhase('ready'); setErr(null); setLoadingMore(false);
      })
      .catch((e) => {
        if (id !== reqRef.current) return;
        setErr({ kind: errorKind(e), retryAfter: e.retryAfter, more });
        setLoadingMore(false);
        if (!more) setPhase('error');
      });
  // meta only supplies the page-size default; do not refetch when it arrives.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => { load(applied, null); }, [applied, load]);

  const wait = useCountdown(err?.kind === 'rate' ? (err.retryAfter ?? 5) : 0);

  const retry = () => {
    if (err?.more && page?.next_cursor_timestamp) {
      load(applied, { timestamp: page.next_cursor_timestamp, id: page.next_cursor_id });
    } else {
      load(applied, null);
    }
  };

  const loadMore = () => {
    if (!page?.has_more || loadingMore) return;
    load(applied, { timestamp: page.next_cursor_timestamp, id: page.next_cursor_id });
  };

  const submitSearch = (e) => {
    e.preventDefault();
    setApplied((a) => ({ ...a, q: query.trim() }));
  };

  const setFilters = (filters) => setApplied((a) => ({ ...a, filters }));
  const removeFilter = (field, slug) => setApplied((a) => {
    const f = { ...a.filters };
    if (slug !== null && Array.isArray(f[field])) {
      f[field] = f[field].filter((s) => s !== slug);
      if (!f[field].length) delete f[field];
    } else delete f[field];
    return { ...a, filters: f };
  });
  const clearAll = () => { setQuery(''); setApplied({ q: '', filters: {}, includeFull: false }); };

  const vocab = meta?.vocab;
  const chips = useMemo(() => {
    const out = [];
    MULTI_FACETS.forEach(([field, vocabKey]) => {
      (applied.filters[field] || []).forEach((slug) => out.push({ key: `${field}:${slug}`, field, slug, label: labelFor(vocab, vocabKey, slug) }));
    });
    SINGLE_FACETS.forEach(([field, vocabKey]) => {
      const slug = applied.filters[field];
      if (slug) out.push({ key: field, field, slug: null, label: labelFor(vocab, vocabKey, slug) });
    });
    ['country', 'region', 'city'].forEach((field) => {
      if (applied.filters[field]) out.push({ key: field, field, slug: null, label: applied.filters[field] });
    });
    return out;
  }, [applied.filters, vocab]);

  const activeCount = countActiveFilters(applied.filters);
  const anyActive = activeCount > 0 || applied.q || applied.includeFull;
  const closeSheet = useCallback(() => {
    setSheetOpen(false);
    setTimeout(() => filterBtnRef.current?.focus(), 0);
  }, []);

  const busy = phase === 'loading' || loadingMore;
  const summary = phase === 'ready'
    ? `Showing ${items.length} ${items.length === 1 ? 'group' : 'groups'}${page?.has_more ? ', more available' : ''}`
    : '';

  return (
    <div className="ex-page">
      <Seo title="Explore groups — FellowScript" description="Find a FellowScript group to join." path="/explore" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <main className="ex-main">
        <header className="ex-head">
          <h1 className="ex-h1" ref={headingRef}>Explore groups</h1>
          <p className="ex-sub">Find a group near your faith and season of life.</p>
          <Link to="/explore/manage" className="ex-btn ex-btn--primary ex-list-cta">List your group</Link>
        </header>

        <form className="ex-controls" role="search" onSubmit={submitSearch}>
          <label className="ex-search">
            <span className="ex-sr-only">Search groups</span>
            <input type="search" value={query} placeholder="Search groups"
              maxLength={meta?.limits?.q_max_length || 80}
              onChange={(e) => setQuery(e.target.value)} />
          </label>
          <button type="submit" className="ex-btn ex-btn--primary">Search</button>
          <button type="button" className="ex-btn ex-btn--pill" ref={filterBtnRef}
            onClick={() => setSheetOpen(true)} disabled={!meta}
            aria-haspopup="dialog" aria-expanded={sheetOpen}>
            Filters{activeCount > 0 && <span className="ex-badge" aria-label={`${activeCount} active`}>{activeCount}</span>}
          </button>
          <label className="ex-toggle">
            <input type="checkbox" checked={applied.includeFull}
              onChange={(e) => setApplied((a) => ({ ...a, includeFull: e.target.checked }))} />
            <span>Include full groups</span>
          </label>
        </form>

        {(chips.length > 0 || applied.q) && (
          <ul className="ex-active" aria-label="Active filters">
            {applied.q && (
              <li><button type="button" className="ex-chip ex-chip--remove" onClick={() => { setQuery(''); setApplied((a) => ({ ...a, q: '' })); }}>
                Search: {applied.q}<span aria-hidden="true"> ×</span><span className="ex-sr-only"> remove</span>
              </button></li>
            )}
            {chips.map((c) => (
              <li key={c.key}><button type="button" className="ex-chip ex-chip--remove" onClick={() => removeFilter(c.field, c.slug)}>
                {c.label}<span aria-hidden="true"> ×</span><span className="ex-sr-only"> remove</span>
              </button></li>
            ))}
          </ul>
        )}

        <div className="ex-sr-only" role="status" aria-live="polite">{summary}</div>

        <section aria-busy={busy} aria-label="Groups">
          {phase === 'loading' && (
            <div className="ex-center"><Spin size="large" aria-label="Loading groups" /></div>
          )}

          {phase === 'error' && err && (
            <div className="ex-state" role="alert">
              <p className="ex-state-title">{COPY[err.kind].title}</p>
              {COPY[err.kind].body && <p className="ex-state-body">{COPY[err.kind].body}</p>}
              {err.kind === 'filter' && <button type="button" className="ex-btn ex-btn--quiet" onClick={clearAll}>Clear filters</button>}
              {(err.kind === 'rate' || err.kind === 'network') && (
                <button type="button" className="ex-btn ex-btn--primary" onClick={retry} disabled={wait > 0}>
                  {wait > 0 ? `Try again in ${wait}s` : 'Try again'}
                </button>
              )}
            </div>
          )}

          {phase === 'ready' && items.length === 0 && (
            <div className="ex-state">
              <p className="ex-state-title">{anyActive ? 'No groups match these filters.' : 'No groups listed yet.'}</p>
              {anyActive && <button type="button" className="ex-btn ex-btn--quiet" onClick={clearAll}>Clear filters</button>}
            </div>
          )}

          {phase === 'ready' && items.length > 0 && (
            <ul className="ex-grid">
              {items.map((l) => <ListingCard key={l.public_id} listing={l} vocab={vocab} />)}
            </ul>
          )}

          {phase === 'ready' && err?.more && (
            <div className="ex-state ex-state--inline" role="alert">
              <p className="ex-state-title">{COPY[err.kind].title}</p>
              {COPY[err.kind].body && <p className="ex-state-body">{COPY[err.kind].body}</p>}
              <button type="button" className="ex-btn ex-btn--primary" onClick={retry} disabled={wait > 0}>
                {wait > 0 ? `Try again in ${wait}s` : 'Try again'}
              </button>
            </div>
          )}

          {phase === 'ready' && page?.has_more && !err?.more && (
            <div className="ex-more">
              <button type="button" className="ex-btn ex-btn--pill" onClick={loadMore} disabled={loadingMore}>
                {loadingMore ? <Spin size="small" /> : 'Load more'}
              </button>
            </div>
          )}
        </section>

        <p className="ex-foot"><Link to="/" className="ex-link">Back to home</Link></p>
      </main>

      <FilterPanel open={sheetOpen} onClose={closeSheet} filters={applied.filters} onApply={setFilters} meta={meta} />
    </div>
  );
}
