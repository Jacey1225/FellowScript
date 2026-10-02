import React from 'react';
import { Link } from 'react-router-dom';
import ListingHero from './ListingHero.jsx';
import { cardChips } from './exploreLabels.js';

// One tab stop per card: the whole card is a single link to the detail page.
// Accessible name is the group name plus its city. No owner identity anywhere.
export default function ListingCard({ listing, vocab }) {
  const chips = cardChips(listing, vocab);
  const label = listing.city ? `${listing.title}, ${listing.city}` : listing.title;
  const full = listing.seats === 'full';
  return (
    <li className="ex-card-item">
      <Link
        to={`/explore/${encodeURIComponent(listing.public_id)}`}
        className="ex-card"
        aria-label={label}
        aria-describedby={`ex-card-desc-${listing.public_id}`}
      >
        <ListingHero listing={listing} size="card" />
        <div className="ex-card-body" id={`ex-card-desc-${listing.public_id}`}>
          {listing.summary && <p className="ex-card-summary">{listing.summary}</p>}
          {chips.length > 0 && (
            <div className="ex-chip-row">
              {chips.map((c) => <span className="ex-chip" key={c}>{c}</span>)}
            </div>
          )}
          <div className="ex-card-status">
            <span className="ex-card-size">{listing.size_bucket} members</span>
            <span className={`ex-seat ex-seat--${full ? 'full' : 'open'}`}>{full ? 'Full' : 'Open'}</span>
          </div>
        </div>
      </Link>
    </li>
  );
}
