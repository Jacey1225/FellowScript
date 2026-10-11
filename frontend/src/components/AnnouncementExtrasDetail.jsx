import React, { useState } from 'react';
import {
  EXTRAS_LIMITS, paymentProvider, parseLink, linkDisplayHost, isLookalikeHost, locationMapsUrl,
} from '../lib/announcementStyle.js';

// Extras block of the announcement detail view (mirrors iOS
// AnnouncementExtrasDetail): photos, links, event payments, location, RSVP.
// Every block hides when its data is empty, so an announcement with no extras
// (or a server with the flags off, which omits the keys) renders as before.
//
// Safety: every user-supplied URL reaches an href only through parseLink()
// (http/https, dotted host, no credentials) with rel=noopener noreferrer, and
// always shows its host. Payment handles are plain text, never a link.

export default function AnnouncementExtrasDetail({ item, onRsvp, onOpenLightbox }) {
  const [override, setOverride] = useState(null); // { count, joined }
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [copied, setCopied] = useState(null);

  const gallery = (item.gallery || []).filter((g) => typeof g?.url === 'string' && g.url);
  const links = (item.links || []).map((l) => ({ l, url: parseLink(l?.url) })).filter((x) => x.url);
  const handles = item.is_event === true
    ? (item.payment_handles || []).map((h) => ({ p: paymentProvider(h?.provider), handle: h?.handle })).filter((x) => x.p && x.handle)
    : [];
  const place = (item.location || '').trim();
  const capacity = Number.isInteger(item.capacity) ? item.capacity : null;

  if (!gallery.length && !links.length && !handles.length && !place && capacity == null) return null;

  const count = override?.count ?? item.rsvp_count ?? 0;
  const joined = override?.joined ?? item.rsvp_joined ?? false;
  const full = capacity != null && count >= capacity && !joined;
  const canAct = !!onRsvp && item.published !== false;

  const toggle = async () => {
    if (busy || !onRsvp) return;
    const before = override;
    setBusy(true); setError(null);
    setOverride({ count: Math.max(0, count + (joined ? -1 : 1)), joined: !joined }); // optimistic
    try {
      const updated = await onRsvp(!joined);
      setOverride({ count: updated?.rsvp_count ?? count, joined: updated?.rsvp_joined ?? !joined });
    } catch (err) {
      setOverride(before);
      setError(err?.status === 409 ? 'This event is full.' : "Couldn't update your RSVP. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  const copy = async (text, key) => {
    try { await navigator.clipboard.writeText(text); setCopied(key); setTimeout(() => setCopied((c) => (c === key ? null : c)), 1500); } catch { /* clipboard unavailable: handle stays selectable */ }
  };

  return (
    <div className="ann-extras-detail">
      {gallery.length > 0 && (
        <section className="ann-extra-block" aria-label="Photos">
          <h4 className="ann-extra-heading">Photos</h4>
          <ul className="ann-gallery">
            {gallery.map((g, i) => (
              <li key={g.key || g.url}>
                {onOpenLightbox ? (
                  <button type="button" className="ann-gallery-item" aria-label={`Photo ${i + 1} of ${gallery.length}, open larger`}
                    onClick={(e) => onOpenLightbox('image', g.url, e)}>
                    <img src={g.url} alt="" loading="lazy" />
                  </button>
                ) : (
                  <a className="ann-gallery-item" href={g.url} target="_blank" rel="noopener noreferrer"
                    aria-label={`Photo ${i + 1} of ${gallery.length}, opens in a new tab`}>
                    <img src={g.url} alt="" loading="lazy" />
                  </a>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}

      {links.length > 0 && (
        <section className="ann-extra-block" aria-label="Links">
          <h4 className="ann-extra-heading">Links</h4>
          <ul className="ann-extra-list">
            {links.map(({ l, url }) => {
              const host = linkDisplayHost(url);
              const risky = isLookalikeHost(host);
              const title = (l.label || '').trim() || host;
              return (
                <li key={url}>
                  <a className="ann-card ann-link" href={url} target="_blank" rel="noopener noreferrer"
                    aria-label={`${title}, link to ${host}, opens in a new tab`}>
                    <span className="ann-card-text">
                      <span className="ann-card-title">{title}</span>
                      <span className="ann-card-sub">{host}</span>
                      {risky && <span className="ann-card-warn">Unusual characters in this address. Check it before you continue.</span>}
                    </span>
                    <span className="ann-card-icon" aria-hidden="true">↗</span>
                  </a>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      {place && (
        <section className="ann-extra-block" aria-label="Location">
          <h4 className="ann-extra-heading">Location</h4>
          <a className="ann-card ann-link" href={locationMapsUrl(place)} target="_blank" rel="noopener noreferrer"
            aria-label={`Location, ${place}, opens in maps`}>
            <span className="ann-card-text"><span className="ann-card-title">{place}</span></span>
            <span className="ann-card-icon" aria-hidden="true">↗</span>
          </a>
        </section>
      )}

      {handles.length > 0 && (
        <section className="ann-extra-block" aria-label="Event payments">
          <h4 className="ann-extra-heading">Event payments</h4>
          <div className="ann-card ann-card-static">
            {handles.map(({ p, handle }) => (
              <div className="ann-handle" key={p.key}>
                <span className="ann-card-text">
                  <span className="ann-card-sub">{p.title}</span>
                  <span className="ann-card-title ann-selectable">{handle}</span>
                </span>
                <button type="button" className="group-info-text-btn" aria-label={`Copy ${p.title} handle`} onClick={() => copy(handle, p.key)}>
                  {copied === p.key ? 'Copied' : 'Copy'}
                </button>
              </div>
            ))}
            <p className="ann-note">{EXTRAS_LIMITS.paymentDisclaimer}</p>
          </div>
        </section>
      )}

      {capacity != null && (
        <section className="ann-extra-block" aria-label="RSVP">
          <h4 className="ann-extra-heading">RSVP</h4>
          <div className="ann-card ann-card-static">
            <div className="ann-rsvp-row">
              <span className="ann-card-title" aria-live="polite">{count} of {capacity} going{joined ? ', including you' : ''}</span>
              {canAct && (
                <button type="button" className={joined || full ? 'group-info-secondary-pill ann-rsvp-btn' : 'group-info-pill ann-rsvp-btn'}
                  disabled={busy || full} onClick={toggle}
                  aria-label={joined ? 'Cancel your RSVP' : (full ? 'Event is full' : "RSVP, I'm going")}>
                  {joined ? 'Cancel RSVP' : (full ? 'Full' : "I'm going")}
                </button>
              )}
            </div>
            {error && <p className="group-info-error" role="alert">{error}</p>}
            <p className="ann-note">RSVP only. It doesn't change your group membership.</p>
          </div>
        </section>
      )}
    </div>
  );
}
