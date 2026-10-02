import React from 'react';
import { initialsOf } from './exploreLabels.js';

// Banner with the group name over a mandatory scrim, and the photo circle
// overlapping the bottom-left. Banner and photo URLs are absent until the
// media task (LSM) ships, so the gold gradient and initials are the fallback;
// when LSM adds `banner_url` / `photo_url` they are only ever used as the src
// of an <img> / background, never rendered as markup.
export default function ListingHero({ listing, size = 'card', headingRef, as: Tag = 'span' }) {
  const bannerUrl = typeof listing.banner_url === 'string' ? listing.banner_url : null;
  const photoUrl = typeof listing.photo_url === 'string' ? listing.photo_url : null;
  return (
    <div className={`ex-hero ex-hero--${size}`}>
      <div className="ex-hero-banner">
        {bannerUrl && <img src={bannerUrl} alt="" className="ex-hero-img" loading="lazy" />}
        <div className="ex-hero-scrim" />
        <Tag className="ex-hero-title" ref={headingRef} tabIndex={headingRef ? -1 : undefined}>
          {listing.title}
        </Tag>
      </div>
      <div className="ex-hero-photo" aria-hidden="true">
        {photoUrl ? <img src={photoUrl} alt="" /> : <span>{initialsOf(listing.title)}</span>}
      </div>
    </div>
  );
}
