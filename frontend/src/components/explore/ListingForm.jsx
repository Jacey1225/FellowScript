import React, { useId, useMemo, useState } from 'react';
import { MULTI_FIELDS, SINGLE_FIELDS, newBlock, countryLabel } from './listingForm.js';

// Details form for an Explorer listing: controlled vocabulary pills and
// selects (from /explorer/{user}/options), place as country + region + city
// only (never a street address), and the description as a list of text
// paragraphs (Markdown subset). No media here; banner and photo belong to a
// later task. `disabled` makes the whole form read-only (hidden listings).
export default function ListingForm({ form, onChange, options, disabled = false }) {
  const uid = useId();
  const [tagDraft, setTagDraft] = useState('');
  const { vocab = {}, limits = {}, countries = [] } = options || {};
  const maxValues = limits.max_values_per_field || 5;
  const set = (patch) => onChange({ ...form, ...patch });

  const countryOptions = useMemo(
    () => countries.map((c) => ({ code: c, label: countryLabel(c) })).sort((a, b) => a.label.localeCompare(b.label)),
    [countries],
  );

  const toggle = (field, slug) => {
    const cur = form[field];
    set({ [field]: cur.includes(slug) ? cur.filter((s) => s !== slug) : [...cur, slug] });
  };

  const addTag = () => {
    const t = tagDraft.trim().replace(/\s+/g, ' ');
    if (!t || form.free_tags.length >= (limits.max_free_tags || 5)) return;
    if (!form.free_tags.some((x) => x.toLowerCase() === t.toLowerCase())) set({ free_tags: [...form.free_tags, t] });
    setTagDraft('');
  };

  const setBlock = (id, text) => set({ blocks: form.blocks.map((b) => (b.id === id ? { ...b, text } : b)) });
  const moveBlock = (i, d) => {
    const next = [...form.blocks];
    const j = i + d;
    if (j < 0 || j >= next.length) return;
    [next[i], next[j]] = [next[j], next[i]];
    set({ blocks: next });
  };
  const maxBlocks = limits.description_max_blocks || 30;
  const totalChars = form.blocks.reduce((n, b) => n + b.text.length, 0);

  return (
    <fieldset className="ex-form" disabled={disabled}>
      <legend className="ex-sr-only">Listing details</legend>

      <div className="ex-form-section">
        <h2 className="ex-form-h">The basics</h2>
        <label className="ex-field">
          <span>Group name</span>
          <input type="text" value={form.title} maxLength={limits.title || 80} required
            onChange={(e) => set({ title: e.target.value })} autoComplete="off" />
        </label>
        <label className="ex-field">
          <span>Short summary</span>
          <textarea value={form.summary} rows={3} maxLength={limits.summary || 280}
            onChange={(e) => set({ summary: e.target.value })} aria-describedby={`${uid}-sum`} />
          <span id={`${uid}-sum`} className="ex-hint">{form.summary.length} of {limits.summary || 280}. Shown on the group's card.</span>
        </label>
        <label className="ex-field">
          <span>Church (optional)</span>
          <input type="text" value={form.church_name} maxLength={limits.church_name || 120}
            onChange={(e) => set({ church_name: e.target.value })} autoComplete="off" />
        </label>
      </div>

      <div className="ex-form-section">
        <h2 className="ex-form-h">Where you meet</h2>
        <p className="ex-hint">Country, region and city only. Never add a street address or phone number.</p>
        <div className="ex-field-row">
          <label className="ex-field">
            <span>Country</span>
            <select value={form.country} onChange={(e) => set({ country: e.target.value })}>
              <option value="">Not set</option>
              {countryOptions.map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}
            </select>
          </label>
          <label className="ex-field">
            <span>Region or state</span>
            <input type="text" value={form.region} maxLength={limits.region || 80}
              onChange={(e) => set({ region: e.target.value })} autoComplete="off" />
          </label>
          <label className="ex-field">
            <span>City</span>
            <input type="text" value={form.city} maxLength={limits.city || 80}
              onChange={(e) => set({ city: e.target.value })} autoComplete="off" />
          </label>
        </div>
      </div>

      <div className="ex-form-section">
        <h2 className="ex-form-h">About the group</h2>
        <p className="ex-hint">These help people find you. Pick up to {maxValues} in each list.</p>
        {MULTI_FIELDS.map(([field, vocabKey, title]) => {
          const opts = vocab[vocabKey] || [];
          if (!opts.length) return null;
          const cur = form[field];
          const atCap = cur.length >= maxValues;
          return (
            <fieldset className="ex-facet" key={field}>
              <legend className="ex-facet-title">{title}</legend>
              <div className="ex-pill-grid">
                {opts.map((o) => {
                  const checked = cur.includes(o.slug);
                  return (
                    <label key={o.slug} className={`ex-pill${checked ? ' is-on' : ''}${!checked && atCap ? ' is-disabled' : ''}`}>
                      <input type="checkbox" checked={checked} disabled={!checked && atCap} onChange={() => toggle(field, o.slug)} />
                      <span>{o.label}</span>
                    </label>
                  );
                })}
              </div>
              {atCap && <p className="ex-hint">You can pick up to {maxValues}.</p>}
            </fieldset>
          );
        })}
        <div className="ex-field-row">
          {SINGLE_FIELDS.map(([field, vocabKey, title]) => {
            const opts = vocab[vocabKey] || [];
            if (!opts.length) return null;
            return (
              <label className="ex-field" key={field}>
                <span>{title}</span>
                <select value={form[field]} onChange={(e) => set({ [field]: e.target.value })}>
                  <option value="">Not set</option>
                  {opts.map((o) => <option key={o.slug} value={o.slug}>{o.label}</option>)}
                </select>
              </label>
            );
          })}
        </div>
        <div className="ex-field">
          <label htmlFor={`${uid}-tag`}>Your own tags (optional)</label>
          <div className="ex-tag-row">
            <input id={`${uid}-tag`} type="text" value={tagDraft} maxLength={limits.free_tag_max_length || 30}
              onChange={(e) => setTagDraft(e.target.value)} autoComplete="off"
              onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); addTag(); } }} />
            <button type="button" className="ex-btn ex-btn--pill" onClick={addTag}
              disabled={!tagDraft.trim() || form.free_tags.length >= (limits.max_free_tags || 5)}>Add tag</button>
          </div>
          {form.free_tags.length > 0 && (
            <ul className="ex-active" aria-label="Your tags">
              {form.free_tags.map((t) => (
                <li key={t}>
                  <button type="button" className="ex-chip ex-chip--remove"
                    onClick={() => set({ free_tags: form.free_tags.filter((x) => x !== t) })}>
                    {t}<span aria-hidden="true"> ×</span><span className="ex-sr-only"> remove tag</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>

      <div className="ex-form-section">
        <h2 className="ex-form-h">Description</h2>
        <p className="ex-hint">
          Tell people what your group is like. You can use **bold**, *italics*, lists and links that start with https://.
          Images, videos and raw HTML are not supported yet.
        </p>
        {form.blocks.map((b, i) => (
          <div className="ex-block" key={b.id}>
            <label className="ex-field">
              <span>Paragraph {i + 1}</span>
              <textarea value={b.text} rows={5} maxLength={limits.description_max_block_chars || 2000}
                onChange={(e) => setBlock(b.id, e.target.value)} />
            </label>
            <div className="ex-block-actions">
              <button type="button" className="ex-btn ex-btn--quiet" onClick={() => moveBlock(i, -1)} disabled={i === 0}
                aria-label={`Move paragraph ${i + 1} up`}>Up</button>
              <button type="button" className="ex-btn ex-btn--quiet" onClick={() => moveBlock(i, 1)} disabled={i === form.blocks.length - 1}
                aria-label={`Move paragraph ${i + 1} down`}>Down</button>
              <button type="button" className="ex-btn ex-btn--quiet" onClick={() => set({ blocks: form.blocks.filter((x) => x.id !== b.id) })}
                aria-label={`Remove paragraph ${i + 1}`}>Remove</button>
            </div>
          </div>
        ))}
        <div className="ex-block-foot">
          <button type="button" className="ex-btn ex-btn--pill" onClick={() => set({ blocks: [...form.blocks, newBlock()] })}
            disabled={form.blocks.length >= maxBlocks}>Add a paragraph</button>
          <span className="ex-hint">{totalChars} of {limits.description_max_text_chars || 5000} characters</span>
        </div>
      </div>
    </fieldset>
  );
}
