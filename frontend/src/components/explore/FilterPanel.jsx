import React, { useEffect, useRef, useState } from 'react';
import { useFocusTrap } from '../../hooks/useFocusTrap.js';

// Filter sheet (Proposal A): bottom sheet on phones, right-anchored panel on
// desktop (CSS only). Edits are held as a draft and applied with "Show results".
// Multi-select facets are real checkboxes (keyboard + screen reader native),
// styled as pills; the server cap per facet is enforced here with a visible hint.

export const MULTI_FACETS = [
  ['denominations', 'denominations', 'Denomination'],
  ['goals', 'goals', 'Goals'],
  ['practices', 'practices', 'Practices'],
  ['hobbies', 'hobbies', 'Hobbies'],
  ['age_ranges', 'age_ranges', 'Age range'],
  ['life_stages', 'life_stages', 'Life stage'],
  ['languages', 'languages', 'Language'],
];
export const SINGLE_FACETS = [
  ['gender_makeup', 'gender_makeup', 'Group makeup'],
  ['meeting_format', 'meeting_formats', 'Meeting format'],
  ['frequency', 'frequencies', 'Frequency'],
];

export function countActiveFilters(filters) {
  return Object.values(filters).reduce((n, v) => n + (Array.isArray(v) ? v.length : (v ? 1 : 0)), 0);
}

export default function FilterPanel({ open, onClose, filters, onApply, meta }) {
  const [draft, setDraft] = useState(filters);
  const ref = useRef(null);
  useFocusTrap(open, ref);

  useEffect(() => { if (open) setDraft(filters); }, [open, filters]);
  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  if (!open) return null;
  const { vocab = {}, limits = {}, countries = [] } = meta || {};
  const cap = limits.max_facet_values || 5;

  const toggle = (field, slug) => setDraft((d) => {
    const cur = d[field] || [];
    const next = cur.includes(slug) ? cur.filter((s) => s !== slug) : [...cur, slug];
    return { ...d, [field]: next };
  });
  const setSingle = (field, value) => setDraft((d) => ({ ...d, [field]: value }));
  const clean = () => {
    const out = {};
    Object.entries(draft).forEach(([k, v]) => {
      if (Array.isArray(v) ? v.length : (typeof v === 'string' && v.trim())) out[k] = v;
    });
    return out;
  };

  return (
    <div className="ex-sheet-wrap">
      <div className="ex-sheet-backdrop" onClick={onClose} aria-hidden="true" />
      <div className="ex-sheet" role="dialog" aria-modal="true" aria-labelledby="ex-filters-title" ref={ref}>
        <div className="ex-sheet-head">
          <h2 id="ex-filters-title" className="ex-sheet-title">Filters</h2>
          <button type="button" className="ex-btn ex-btn--quiet" onClick={onClose}>Close</button>
        </div>
        <div className="ex-sheet-body">
          <div className="ex-facet">
            <h3 className="ex-facet-title">Location</h3>
            <div className="ex-field-row">
              <label className="ex-field">
                <span>Country</span>
                <select value={draft.country || ''} onChange={(e) => setSingle('country', e.target.value)}>
                  <option value="">Anywhere</option>
                  {countries.map((c) => <option key={c} value={c}>{c}</option>)}
                </select>
              </label>
              <label className="ex-field">
                <span>Region</span>
                <input type="text" value={draft.region || ''} maxLength={limits.region_max_length || 60}
                  onChange={(e) => setSingle('region', e.target.value)} autoComplete="off" />
              </label>
              <label className="ex-field">
                <span>City</span>
                <input type="text" value={draft.city || ''} maxLength={limits.city_max_length || 60}
                  onChange={(e) => setSingle('city', e.target.value)} autoComplete="off" />
              </label>
            </div>
          </div>

          {MULTI_FACETS.map(([field, vocabKey, title]) => {
            const options = vocab[vocabKey] || [];
            if (!options.length) return null;
            const cur = draft[field] || [];
            const atCap = cur.length >= cap;
            return (
              <fieldset className="ex-facet" key={field}>
                <legend className="ex-facet-title">{title}</legend>
                <div className="ex-pill-grid">
                  {options.map((o) => {
                    const checked = cur.includes(o.slug);
                    return (
                      <label key={o.slug} className={`ex-pill${checked ? ' is-on' : ''}${!checked && atCap ? ' is-disabled' : ''}`}>
                        <input type="checkbox" checked={checked} disabled={!checked && atCap}
                          onChange={() => toggle(field, o.slug)} />
                        <span>{o.label}</span>
                      </label>
                    );
                  })}
                </div>
                {atCap && <p className="ex-hint">Up to {cap} per filter.</p>}
              </fieldset>
            );
          })}

          {SINGLE_FACETS.map(([field, vocabKey, title]) => {
            const options = vocab[vocabKey] || [];
            if (!options.length) return null;
            return (
              <div className="ex-facet" key={field}>
                <label className="ex-field">
                  <span className="ex-facet-title">{title}</span>
                  <select value={draft[field] || ''} onChange={(e) => setSingle(field, e.target.value)}>
                    <option value="">Any</option>
                    {options.map((o) => <option key={o.slug} value={o.slug}>{o.label}</option>)}
                  </select>
                </label>
              </div>
            );
          })}
        </div>
        <div className="ex-sheet-foot">
          <button type="button" className="ex-btn ex-btn--quiet" onClick={() => setDraft({})}>Clear</button>
          <button type="button" className="ex-btn ex-btn--primary" onClick={() => { onApply(clean()); onClose(); }}>
            Show results
          </button>
        </div>
      </div>
    </div>
  );
}
