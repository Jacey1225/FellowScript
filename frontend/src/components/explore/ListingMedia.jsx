import React, { useState } from 'react';
import MediaUploader from './MediaUploader.jsx';
import { safeMediaUrl } from '../../lib/safeMediaUrl.js';
import { applyGroupPhoto, deleteListingMedia } from '../../lib/listingMediaApi.js';
import { describeOwnerError } from './manageStatus.js';

// Task 20261002-explorer-listing-media step 4. Photo (profile image) and
// banner section of the owner form. These act on the server immediately
// (they are not part of "Save"); the listing must be saved once first. Images
// shown here come only from server-issued URLs via safeMediaUrl.
// props: media = { userId, groupId, listing, options, onChange(patch, item?), disabled }
export default function ListingMedia({ media }) {
  const { userId, groupId, listing, options, onChange, disabled } = media;
  const [busy, setBusy] = useState(null);
  const [msg, setMsg] = useState('');
  const [error, setError] = useState(null);
  const saved = !!listing;
  const items = listing?.media || [];
  const photo = items.find((m) => m.kind === 'photo');
  const banner = items.find((m) => m.kind === 'banner');
  const off = disabled || !saved || !!busy;

  const applied = (kind, item, announce) => {
    setError(null); setMsg(announce);
    onChange({ kind, item });
  };

  const useGroup = async () => {
    setBusy('group'); setError(null); setMsg('');
    try {
      const item = await applyGroupPhoto(userId, groupId);
      applied('photo', item, 'Group photo added as the listing photo.');
    } catch (err) { setError(describeOwnerError(err).message); } finally { setBusy(null); }
  };

  const remove = async (item, noun) => {
    setBusy(item.media_id); setError(null); setMsg('');
    try {
      await deleteListingMedia(userId, groupId, item.media_id);
      setMsg(`${noun} removed.`);
      onChange({ kind: item.kind, removed: item.media_id });
    } catch (err) { setError(describeOwnerError(err).message); } finally { setBusy(null); }
  };

  const slot = (kind, item, title, noun, hint) => {
    const url = item ? safeMediaUrl(item.url) : null;
    return (
      <div className={`ex-media-slot ex-media-slot--${kind}`}>
        <h3 className="ex-media-h">{title}</h3>
        <p className="ex-hint">{hint}</p>
        {item && (
          <figure className="ex-media-preview">
            {url
              ? <img src={url} alt={item.alt_text || ''} loading="lazy" referrerPolicy="no-referrer" />
              : <span className="ex-hint">The picture is not available to preview right now.</span>}
            {item.alt_text && <figcaption className="ex-hint">Description: {item.alt_text}</figcaption>}
          </figure>
        )}
        <MediaUploader
          userId={userId} groupId={groupId} kind={kind} mediaOptions={options}
          label={item ? `Replace ${noun}` : `Add ${noun}`} disabled={off}
          altRequired={kind === 'banner'} crop={kind === 'banner'}
          onDone={(it) => applied(kind, it, `${title} saved.`)}
        >
          {kind === 'photo' && (
            <button type="button" className="ex-btn ex-btn--quiet" onClick={useGroup} disabled={off}>
              Use current group photo
            </button>
          )}
          {item && (
            <button type="button" className="ex-btn ex-btn--quiet" onClick={() => remove(item, title)} disabled={off}
              aria-label={`Remove ${noun}`}>
              Remove
            </button>
          )}
        </MediaUploader>
      </div>
    );
  };

  return (
    <div className="ex-form-section" data-testid="listing-media">
      <h2 className="ex-form-h">Photo and banner</h2>
      {!saved && <p className="ex-hint">Save your draft first, then you can add a photo and banner.</p>}
      {saved && <p className="ex-hint">Images save as soon as they upload. JPEG, PNG or WebP only. A change after your listing is live sends it back for review.</p>}
      {slot('photo', photo, 'Profile photo', 'photo', 'A square-ish picture shown in a circle on your listing.')}
      {slot('banner', banner, 'Banner', 'banner', 'A wide picture across the top. You will crop it and describe it.')}
      <div className="ex-sr-only" role="status" aria-live="polite">{msg}</div>
      {error && <p className="ex-error" role="alert">{error}</p>}
    </div>
  );
}
