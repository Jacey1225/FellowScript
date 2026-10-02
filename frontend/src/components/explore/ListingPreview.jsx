import React from 'react';
import ListingHero from './ListingHero.jsx';
import DescriptionBlocks from './DescriptionBlocks.jsx';
import { labelFor, placeLine } from './exploreLabels.js';

// Preview of a listing as visitors will see it, rendered from the owner's
// form state through the SAME safe renderers as the public detail page
// (restricted Markdown, no images or HTML, nofollow links). Preview only:
// nothing here is saved or sent.
const GROUPS = [
  ['denominations', 'denominations', 'Denomination'],
  ['goals', 'goals', 'Goals'],
  ['practices', 'practices', 'Practices'],
  ['hobbies', 'hobbies', 'Hobbies'],
  ['age_ranges', 'age_ranges', 'Age range'],
  ['life_stages', 'life_stages', 'Life stage'],
  ['languages', 'languages', 'Language'],
  ['meeting_format', 'meeting_formats', 'Meeting format'],
  ['frequency', 'frequencies', 'Frequency'],
  ['gender_makeup', 'gender_makeup', 'Group makeup'],
];

export default function ListingPreview({ listing, vocab }) {
  const place = placeLine(listing);
  const blocks = (listing.description_blocks || []).filter((b) => b.type === 'text' && b.text.trim());
  return (
    <article className="ex-detail ex-preview" aria-label="Preview of your listing">
      <ListingHero listing={{ ...listing, title: listing.title || 'Your group name' }} size="detail" />
      <div className="ex-detail-grid ex-preview-grid">
        <div className="ex-detail-main">
          {listing.summary && <p className="ex-detail-summary">{listing.summary}</p>}
          <div className="ex-meta">
            {place && <p className="ex-meta-line">{place}</p>}
            {listing.church_name && <p className="ex-meta-line">{listing.church_name}</p>}
          </div>
          {GROUPS.map(([field, vocabKey, title]) => {
            const raw = listing[field];
            const values = Array.isArray(raw) ? raw : (raw ? [raw] : []);
            if (!values.length) return null;
            return (
              <div className="ex-chipgroup" key={field}>
                <h3 className="ex-chipgroup-title">{title}</h3>
                <div className="ex-chip-row">
                  {values.map((v) => <span className="ex-chip" key={v}>{labelFor(vocab, vocabKey, v)}</span>)}
                </div>
              </div>
            );
          })}
          {listing.free_tags?.length > 0 && (
            <div className="ex-chipgroup">
              <h3 className="ex-chipgroup-title">Tags</h3>
              <div className="ex-chip-row">
                {listing.free_tags.map((t) => <span className="ex-chip" key={t}>{t}</span>)}
              </div>
            </div>
          )}
          <DescriptionBlocks blocks={blocks} />
        </div>
      </div>
    </article>
  );
}
