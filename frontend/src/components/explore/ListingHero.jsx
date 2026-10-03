import React from 'react';
import { initialsOf } from './exploreLabels.js';
import { safeMediaUrl } from '../../lib/safeMediaUrl.js';

// Banner with the group name over a mandatory scrim, and the photo circle
// overlapping the bottom-left. When the API returns `banner_url` / `photo_url`
// (media task) they are used only as the src of an <img>, and only if they are
// first-party https URLs (safeMediaUrl); otherwise the gold gradient and
// initials are the fallback. Never rendered as markup.
export default function ListingHero({ listing, size = 'card', headingRef, as: Tag = 'span' }) {
  const bannerUrl = safeMediaUrl(listing.banner_url);
  const photoUrl = safeMediaUrl(listing.photo_url);
  const bannerAlt = typeof listing.banner_alt === 'string' ? listing.banner_alt : '';
  return (
    <div className={`ex-hero ex-hero--${size}`}>
      <div className="ex-hero-banner">
        {bannerUrl && <img src={bannerUrl} alt={bannerAlt} className="ex-hero-img" loading="lazy" referrerPolicy="no-referrer" />}
        <div className="ex-hero-scrim" />
        <Tag className="ex-hero-title" ref={headingRef} tabIndex={headingRef ? -1 : undefined}>
          {listing.title}
        </Tag>
      </div>
      <div className="ex-hero-photo" aria-hidden="true">
        {photoUrl ? <img src={photoUrl} alt="" loading="lazy" referrerPolicy="no-referrer" /> : <span>{initialsOf(listing.title)}</span>}
      </div>
    </div>
  );
}
