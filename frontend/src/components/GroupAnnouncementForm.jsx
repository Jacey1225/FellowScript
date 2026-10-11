import React, { useState, useRef, useEffect } from 'react';
import { Spin } from 'antd';
import { PictureOutlined, BgColorsOutlined } from '@ant-design/icons';
import { ANNOUNCEMENT_LIMITS, uploadAnnouncementBanner } from '../lib/announcementsApi.js';
import BannerCropper from './BannerCropper.jsx';
import TitleColorPicker from './TitleColorPicker.jsx';
import { normalizeHex, colorName } from '../lib/announcementTitleColor.js';
import { useCapabilities } from '../hooks/useCapabilities.js';
import AnnouncementCardFace, { formatShortDate } from './AnnouncementCardFace.jsx';
import {
  ANNOUNCEMENT_FLAGS as FLAG, BG_THEMES, BG_THEME_GRADIENTS, BG_THEME_SOLIDS, TITLE_FONTS, TITLE_FONT_KEYS, EXTRAS_LIMITS,
  PAYMENT_PROVIDERS, resolveBgTheme, bgThemeStoredKey, bgThemeCss, bgThemeLabel, resolveTitleFont, titleFontStoredKey,
  titleFontLabel, titleFontStyle, bgThemeReadableText, titleColorOnTheme, parseLink, linkError, handleError, locationError,
} from '../lib/announcementStyle.js';

// Create/edit form for a group announcement (design-notes.md, "Create / edit
// form"). Owns only form state; the parent performs the save via `onSubmit`
// (which throws on failure) and handles the free-limit prompt via `gateHit`.

const pad = (n) => String(n).padStart(2, '0');
function toLocalInput(date) {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export default function GroupAnnouncementForm({ userId, groupId, item, gate, gateHit, upgrade, onSubmit, onCancel, headingRef }) {
  const editing = !!item;
  const canReschedule = !editing || item.published === false;
  const [title, setTitle] = useState(item?.title || '');
  const [titleColor, setTitleColor] = useState(normalizeHex(item?.title_color));
  const [description, setDescription] = useState(item?.description || '');
  // Appearance (task 20261010-web-announcements-parity). null = default/none.
  const caps = useCapabilities();
  const on = (f) => caps?.isEnabled?.(f) === true;
  const [titleFont, setTitleFont] = useState(titleFontStoredKey(item?.title_font));
  const [bgTheme, setBgTheme] = useState(bgThemeStoredKey(item?.bg_theme));
  // Extras
  const [location, setLocation] = useState(item?.location || '');
  const [isEvent, setIsEvent] = useState(item?.is_event === true);
  const [handles, setHandles] = useState(() => Object.fromEntries((item?.payment_handles || []).map((h) => [h.provider, h.handle])));
  const [rsvpOn, setRsvpOn] = useState(Number.isInteger(item?.capacity));
  const [capacity, setCapacity] = useState(Number.isInteger(item?.capacity) ? item.capacity : EXTRAS_LIMITS.capacityDefault);
  const linkId = useRef(0);
  const [links, setLinks] = useState(() => (item?.links || []).map((l) => ({ id: linkId.current++, url: l.url || '', label: l.label || '' })));
  const [gallery, setGallery] = useState(() => (item?.gallery || []).map((g) => ({ key: g.key, url: g.url || null })));
  const [galleryBusy, setGalleryBusy] = useState(false);
  const [galleryError, setGalleryError] = useState(null);
  const galleryRef = useRef(null);
  const [mode, setMode] = useState(editing && item.published === false ? 'schedule' : 'now');
  const [when, setWhen] = useState(editing && item.published === false ? toLocalInput(new Date(item.publish_at)) : '');
  // bannerKey: undefined = unchanged (edit), null = removed, string = new upload.
  const [bannerKey, setBannerKey] = useState(undefined);
  const [bannerPreview, setBannerPreview] = useState(null);
  const [bannerBusy, setBannerBusy] = useState(false);
  const [bannerError, setBannerError] = useState(null);
  const [cropSource, setCropSource] = useState(null); // { file } | { url } while the crop step is open
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [touched, setTouched] = useState(false);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [themeOpen, setThemeOpen] = useState(false);
  const fileRef = useRef(null);
  const mountedRef = useRef(true);
  useEffect(() => { mountedRef.current = true; return () => { mountedRef.current = false; }; }, []);
  useEffect(() => () => { if (bannerPreview) URL.revokeObjectURL?.(bannerPreview); }, [bannerPreview]);

  const tz = (() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone; } catch (e) { return ''; } })();
  const currentBanner = bannerKey === null ? null : (bannerPreview || (bannerKey === undefined ? item?.banner_url : null));
  const trimmedTitle = title.trim();
  const trimmedDesc = description.trim();
  const scheduleInvalid = canReschedule && mode === 'schedule' && (!when || Number.isNaN(new Date(when).getTime()));
  const showFont = on(FLAG.titleFont);
  const showTheme = on(FLAG.bgTheme);
  const showLocation = on(FLAG.location);
  const showLinks = on(FLAG.links);
  const showGallery = on(FLAG.gallery);
  const showPayments = on(FLAG.payments);
  const showRsvp = on(FLAG.rsvp);
  const showExtras = showLocation || showLinks || showGallery || showPayments || showRsvp;
  const trimmedLocation = location.trim().slice(0, EXTRAS_LIMITS.maxLocationLength);
  // First reason the extras can't be saved as they stand (the server stays the source of truth).
  const extrasError = (showLocation && locationError(location))
    || (showLinks && links.some((l) => linkError(l.url)) && 'Fix the highlighted link.')
    || (showPayments && isEvent && PAYMENT_PROVIDERS.some((p) => handleError(handles[p.key])) && 'Fix the highlighted payment handle.')
    || null;
  const extrasCount = (showLocation && trimmedLocation ? 1 : 0) + (showLinks ? links.filter((l) => parseLink(l.url)).length : 0)
    + (showGallery ? gallery.length : 0) + (showPayments && isEvent ? 1 : 0) + (showRsvp && rsvpOn ? 1 : 0);
  const canSubmit = !!trimmedTitle && !!trimmedDesc && !scheduleInvalid && !extrasError && !saving && !bannerBusy && !galleryBusy;
  const dirty = touched;

  // Picking a photo opens the crop step; nothing uploads until the crop is confirmed.
  const onFile = (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;
    setBannerError(null);
    if (file.size > ANNOUNCEMENT_LIMITS.bannerMaxBytes || !ANNOUNCEMENT_LIMITS.bannerAccept.includes(file.type)) {
      setBannerError(`Choose a JPG, PNG, or WebP under ${ANNOUNCEMENT_LIMITS.bannerMaxBytes / 1024 / 1024}MB.`);
      return;
    }
    setCropSource({ file });
  };

  // The cropper hands back the baked 3:1 JPEG; upload exactly that file.
  const onCropped = async (cropped) => {
    setCropSource(null);
    setBannerError(null); setBannerBusy(true); setTouched(true);
    try {
      const key = await uploadAnnouncementBanner(userId, groupId, cropped);
      if (!mountedRef.current) return;
      setBannerKey(key);
      setBannerPreview(URL.createObjectURL ? URL.createObjectURL(cropped) : null);
    } catch (err) {
      if (mountedRef.current) setBannerError(err.status === 0 && err.message ? err.message : `Choose a JPG, PNG, or WebP under ${ANNOUNCEMENT_LIMITS.bannerMaxBytes / 1024 / 1024}MB.`);
    } finally {
      if (mountedRef.current) setBannerBusy(false);
    }
  };

  const submit = async () => {
    if (!canSubmit) return;
    setSaving(true); setError(null);
    const body = { title: trimmedTitle, description: trimmedDesc };
    if (bannerKey !== undefined) body.banner_key = bannerKey;
    // Create: send only a non-default color. Edit: send only a change (null resets).
    const originalColor = normalizeHex(item?.title_color);
    if (titleColor !== originalColor) body.title_color = titleColor;
    // Appearance + extras: only what changed, and only for flags that are ON
    // (a flag-off key sent to the server is a 422). null clears.
    if (showFont && titleFont !== titleFontStoredKey(item?.title_font)) body.title_font = titleFont;
    if (showTheme && bgTheme !== bgThemeStoredKey(item?.bg_theme)) body.bg_theme = bgTheme;
    if (showLocation && trimmedLocation !== (item?.location || '').trim()) body.location = trimmedLocation || null;
    if (showLinks) {
      const cur = links.map((l) => ({ url: parseLink(l.url), label: l.label.trim() })).filter((l) => l.url)
        .map((l) => (l.label ? { url: l.url, label: l.label } : { url: l.url }));
      const orig = (item?.links || []).map((l) => ((l.label || '').trim() ? { url: l.url, label: l.label.trim() } : { url: l.url }));
      if (JSON.stringify(cur) !== JSON.stringify(orig)) body.links = cur.length ? cur : null;
    }
    if (showGallery) {
      const cur = gallery.map((g) => g.key);
      const orig = (item?.gallery || []).map((g) => g.key);
      if (JSON.stringify(cur) !== JSON.stringify(orig)) body.gallery_keys = cur.length ? cur : null;
    }
    if (showPayments) {
      const origEvent = item?.is_event === true;
      const cur = isEvent ? PAYMENT_PROVIDERS.map((p) => ({ provider: p.key, handle: (handles[p.key] || '').trim() })).filter((h) => h.handle) : [];
      const orig = item?.payment_handles || [];
      const sig = (a) => JSON.stringify([...a].map((h) => `${h.provider}|${h.handle}`).sort());
      if (isEvent !== origEvent) body.is_event = isEvent;
      if (sig(cur) !== sig(orig)) body.payment_handles = cur.length ? cur : null;
    }
    if (showRsvp) {
      const cur = rsvpOn ? Math.min(Math.max(Math.trunc(Number(capacity)) || EXTRAS_LIMITS.capacityDefault, EXTRAS_LIMITS.capacityMin), EXTRAS_LIMITS.capacityMax) : null;
      const orig = Number.isInteger(item?.capacity) ? item.capacity : null;
      if (cur !== orig) body.capacity = cur;
    }
    if (canReschedule) {
      if (mode === 'schedule') body.publish_at = new Date(when).toISOString();
      else if (editing) body.publish_at = new Date().toISOString();
      else body.publish_at = null;
    }
    try {
      await onSubmit(body);
    } catch (err) {
      if (mountedRef.current) setError(err.status === 422 ? (err.message || 'That isn\'t allowed here. Try something else.') : "That didn't save. Please try again.");
    } finally {
      if (mountedRef.current) setSaving(false);
    }
  };

  const onGalleryFiles = async (e) => {
    const files = Array.from(e.target.files || []);
    e.target.value = '';
    if (!files.length) return;
    setGalleryError(null); setTouched(true); setGalleryBusy(true);
    let count = gallery.length;
    try {
      for (const file of files) {
        if (count + 1 > EXTRAS_LIMITS.maxGallery) { setGalleryError(`You can add up to ${EXTRAS_LIMITS.maxGallery} photos.`); break; }
        // Same presigned flow and size/type pre-flight as the banner; the server re-checks the key.
        const key = await uploadAnnouncementBanner(userId, groupId, file);
        if (!mountedRef.current) return;
        const url = URL.createObjectURL ? URL.createObjectURL(file) : null;
        setGallery((g) => [...g, { key, url, local: true }]);
        count += 1;
      }
    } catch (err) {
      if (mountedRef.current) setGalleryError(err.message || 'That photo could not be added.');
    } finally {
      if (mountedRef.current) setGalleryBusy(false);
    }
  };

  const cancel = () => (dirty ? setConfirmDiscard(true) : onCancel());

  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== 'Escape' || e.defaultPrevented || cropSource) return;
      e.preventDefault();
      cancel();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  });

  const stripTheme = showTheme ? resolveBgTheme(bgTheme) : 'none';
  const stripText = stripTheme === 'none' ? undefined : bgThemeReadableText(stripTheme);
  const stripStyle = stripTheme === 'none' ? undefined : { background: bgThemeCss(stripTheme), color: stripText };
  const stripTitleColor = titleColor ? (stripTheme === 'none' ? titleColor : titleColorOnTheme(titleColor, stripTheme, stripText)) : stripText;
  const heading = editing ? 'Edit announcement' : 'New announcement';
  return (
    <div className="group-info-announcements-form-wrap">
      <div className="group-info-announcements-bar">
        <button type="button" className="ann-outline-pill" onClick={cancel}>Cancel</button>
        <h3 ref={headingRef} tabIndex={-1} className="group-info-announcements-title">{heading}</h3>
        <button type="button" className="ann-outline-pill ann-outline-pill-post" onClick={submit} disabled={!canSubmit}>
          {saving ? <Spin size="small" /> : bannerBusy ? 'Uploading…' : (editing ? 'Save' : (mode === 'schedule' ? 'Schedule' : 'Post'))}
        </button>
      </div>

      {cropSource && <BannerCropper source={cropSource} onConfirm={onCropped} onCancel={() => setCropSource(null)} />}

      {confirmDiscard && (
        <div className="group-info-banner" role="alertdialog" aria-label="Discard this announcement?">
          <span>Discard this announcement?</span>
          <span>
            <button type="button" className="group-info-text-btn" onClick={() => setConfirmDiscard(false)}>Keep editing</button>
            <button type="button" className="group-info-text-btn group-info-danger" onClick={onCancel}>Discard</button>
          </span>
        </div>
      )}

      <form className="group-info-announcements-form" onSubmit={(e) => { e.preventDefault(); submit(); }}>
        <div className="group-info-announcements-field">
          <span className="group-info-label">Banner photo (optional)</span>
          <div className="ann-banner-tile">
            <AnnouncementCardFace className="title-color-preview" as="div" role="img"
              aria-label={`Preview of the announcement title in ${colorName(titleColor)}${showFont ? `, ${titleFontLabel(titleFont)} font` : ''}${showTheme ? `, ${bgThemeLabel(bgTheme)}` : ''}`}
              title={trimmedTitle || 'Your title'} titleColor={titleColor} titleFont={showFont ? titleFont : item?.title_font}
              bgTheme={showTheme ? bgTheme : item?.bg_theme} bannerUrl={currentBanner}
              location={showLocation ? trimmedLocation : item?.location} date={formatShortDate(new Date().toISOString())} />
            {bannerBusy && <Spin className="group-info-avatar-spin" />}
            <div className="ann-banner-actions">
              {currentBanner ? (
                <>
                  <button type="button" className="ann-glass-pill" disabled={bannerBusy} onClick={() => setCropSource({ url: currentBanner })}>Adjust crop</button>
                  <button type="button" className="ann-glass-pill" disabled={bannerBusy} onClick={() => fileRef.current?.click()}>Replace photo</button>
                  <button type="button" className="ann-glass-pill ann-glass-pill-danger" disabled={bannerBusy}
                    onClick={() => { setBannerKey(null); setBannerPreview(null); setTouched(true); }}>Remove</button>
                </>
              ) : (
                <button type="button" className="ann-glass-pill" disabled={bannerBusy} onClick={() => fileRef.current?.click()}>
                  <PictureOutlined aria-hidden="true" /> Upload
                </button>
              )}
            </div>
          </div>
          {!currentBanner && <span className="group-info-helper">{ANNOUNCEMENT_LIMITS.bannerHelper}</span>}
          <input ref={fileRef} type="file" accept={ANNOUNCEMENT_LIMITS.bannerAccept.join(',')} className="hidden-file-input"
            aria-hidden="true" tabIndex={-1} data-testid="announcement-banner-input" onChange={onFile} />
          {bannerError && <p className="group-info-error" role="alert">{bannerError}</p>}

          {showFont && (
            <div className="ann-font-row" role="radiogroup" aria-label="Title font">
              {TITLE_FONT_KEYS.map((k) => {
                const selected = resolveTitleFont(titleFont) === k;
                return (
                  <button key={k} type="button" role="radio" aria-checked={selected} aria-label={titleFontLabel(k)} disabled={saving}
                    className={`ann-font-chip${selected ? ' ann-font-chip-on' : ''}${k === 'default' ? '' : ' ann-font-chip-sample'}`}
                    style={k === 'default' ? undefined : titleFontStyle(k)}
                    onClick={() => { setTitleFont(titleFontStoredKey(k)); setTouched(true); }}>
                    {k === 'default' ? 'Default' : 'Aa'}
                  </button>
                );
              })}
            </div>
          )}

          <div className="ann-theme-strip" style={stripStyle}>
            <span className="ann-theme-strip-title" style={{ ...(showFont ? titleFontStyle(titleFont) : {}), color: stripTitleColor }}>{trimmedTitle || 'Your title'}</span>
            <span className="ann-theme-strip-msg">{trimmedDesc || 'Your message appears here.'}</span>
            {showTheme && (
              <button type="button" className="ann-palette-btn" aria-label="Background theme" aria-expanded={themeOpen}
                title={`Background theme: ${bgThemeLabel(bgTheme)}`} disabled={saving}
                onClick={() => setThemeOpen((v) => !v)}><BgColorsOutlined aria-hidden="true" /></button>
            )}
          </div>
          {showTheme && themeOpen && (
            <div className="ann-theme-grid" role="radiogroup" aria-label="Background theme">
              {['none', ...BG_THEME_GRADIENTS, ...BG_THEME_SOLIDS].map((k) => {
                const selected = resolveBgTheme(bgTheme) === k;
                return (
                  <button key={k} type="button" role="radio" aria-checked={selected} aria-label={bgThemeLabel(k)} title={BG_THEMES[k].name}
                    disabled={saving} className={`ann-theme-tile${selected ? ' ann-theme-tile-on' : ''}`}
                    onClick={() => { setBgTheme(bgThemeStoredKey(k)); setTouched(true); }}>
                    <span className="ann-theme-dot" style={bgThemeCss(k) ? { background: bgThemeCss(k) } : undefined}>
                      {k === 'none' ? '∅' : (selected ? '✓' : '')}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
        </div>

        <div className="group-info-announcements-field">
          <label className="group-info-label" htmlFor="announcement-title">Title</label>
          <input id="announcement-title" className="group-info-input" value={title} disabled={saving} placeholder="Title"
            maxLength={ANNOUNCEMENT_LIMITS.titleMax} aria-describedby="announcement-title-help"
            onChange={(e) => { setTitle(e.target.value); setTouched(true); }} />
          {title.length >= ANNOUNCEMENT_LIMITS.titleMax - 20 && <span className="group-info-counter">{title.length}/{ANNOUNCEMENT_LIMITS.titleMax}</span>}
          {!trimmedTitle && <p id="announcement-title-help" className="group-info-helper">Give it a title.</p>}
        </div>

        <div className="group-info-announcements-field">
          <span className="group-info-label">Title color</span>
          <TitleColorPicker value={titleColor} disabled={saving} onChange={(c) => { setTitleColor(c); setTouched(true); }} />
        </div>

        <div className="group-info-announcements-field">
          <label className="group-info-label" htmlFor="announcement-description">Message</label>
          <textarea id="announcement-description" className="group-info-input group-info-announcements-textarea" rows={4}
            value={description} disabled={saving} maxLength={ANNOUNCEMENT_LIMITS.descriptionMax}
            aria-describedby="announcement-desc-help"
            onChange={(e) => { setDescription(e.target.value); setTouched(true); }} />
          {description.length >= ANNOUNCEMENT_LIMITS.descriptionMax - 200 && <span className="group-info-counter">{description.length}/{ANNOUNCEMENT_LIMITS.descriptionMax}</span>}
          {!trimmedDesc && <p id="announcement-desc-help" className="group-info-helper">Write a message for the group.</p>}
        </div>

        {showExtras && (
          <details className="group-info-announcements-field ann-extras" open={editing && extrasCount > 0 ? true : undefined}>
            <summary className="ann-extras-summary">Add extras{extrasCount > 0 ? ` (${extrasCount})` : ''}</summary>

            {showLocation && (
              <div className="group-info-announcements-field">
                <label className="group-info-label" htmlFor="announcement-location">Location</label>
                <input id="announcement-location" className="group-info-input" value={location} disabled={saving}
                  maxLength={EXTRAS_LIMITS.maxLocationLength} placeholder="Where is it?"
                  aria-invalid={!!locationError(location)} aria-describedby={locationError(location) ? 'announcement-location-err' : undefined}
                  onChange={(e) => { setLocation(e.target.value); setTouched(true); }} />
                {locationError(location) && <p id="announcement-location-err" className="group-info-error" role="alert">{locationError(location)}</p>}
              </div>
            )}

            {showRsvp && (
              <div className="group-info-announcements-field">
                <label className="ann-toggle">
                  <input type="checkbox" checked={rsvpOn} disabled={saving}
                    onChange={(e) => { setRsvpOn(e.target.checked); setTouched(true); }} />
                  <span>Let members RSVP</span>
                </label>
                {rsvpOn && (
                  <>
                    <label className="group-info-helper" htmlFor="announcement-capacity">Capacity</label>
                    <input id="announcement-capacity" type="number" inputMode="numeric" className="group-info-input ann-capacity"
                      min={EXTRAS_LIMITS.capacityMin} max={EXTRAS_LIMITS.capacityMax} value={capacity} disabled={saving}
                      onChange={(e) => { setCapacity(e.target.value); setTouched(true); }} />
                    <p className="group-info-helper">RSVP only. It doesn't change anyone's group membership.</p>
                  </>
                )}
              </div>
            )}

            {showPayments && (
              <div className="group-info-announcements-field">
                <label className="ann-toggle">
                  <input type="checkbox" checked={isEvent} disabled={saving}
                    onChange={(e) => { setIsEvent(e.target.checked); setTouched(true); }} />
                  <span>This is an event with payments</span>
                </label>
                {isEvent && (
                  <>
                    {PAYMENT_PROVIDERS.map((p) => {
                      const err = handleError(handles[p.key]);
                      return (
                        <div key={p.key} className="group-info-announcements-field">
                          <label className="group-info-helper" htmlFor={`announcement-pay-${p.key}`}>{p.title}</label>
                          <input id={`announcement-pay-${p.key}`} className="group-info-input" value={handles[p.key] || ''} disabled={saving}
                            maxLength={EXTRAS_LIMITS.maxHandleLength + 10} placeholder={p.placeholder} aria-invalid={!!err}
                            onChange={(e) => { setHandles((h) => ({ ...h, [p.key]: e.target.value })); setTouched(true); }} />
                          {err && <p className="group-info-error" role="alert">{err}</p>}
                        </div>
                      );
                    })}
                    <p className="group-info-helper">{EXTRAS_LIMITS.paymentDisclaimer}</p>
                  </>
                )}
              </div>
            )}

            {showLinks && (
              <div className="group-info-announcements-field">
                <span className="group-info-label">Links</span>
                {links.map((l, i) => {
                  const err = linkError(l.url);
                  return (
                    <div key={l.id} className="ann-link-row">
                      <input className="group-info-input" value={l.url} disabled={saving} placeholder="example.com" aria-label={`Link ${i + 1} address`}
                        maxLength={EXTRAS_LIMITS.maxLinkLength} aria-invalid={!!err}
                        onChange={(e) => { const v = e.target.value; setLinks((ls) => ls.map((x) => (x.id === l.id ? { ...x, url: v } : x))); setTouched(true); }} />
                      <input className="group-info-input" value={l.label} disabled={saving} placeholder="Label (optional)" aria-label={`Link ${i + 1} label`}
                        maxLength={EXTRAS_LIMITS.maxLabelLength}
                        onChange={(e) => { const v = e.target.value; setLinks((ls) => ls.map((x) => (x.id === l.id ? { ...x, label: v } : x))); setTouched(true); }} />
                      {err && <p className="group-info-error" role="alert">{err}</p>}
                      <button type="button" className="group-info-text-btn group-info-danger ann-link-remove" disabled={saving}
                        aria-label={`Remove link ${i + 1}`}
                        onClick={() => { setLinks((ls) => ls.filter((x) => x.id !== l.id)); setTouched(true); }}>Remove</button>
                    </div>
                  );
                })}
                {links.length < EXTRAS_LIMITS.maxLinks && (
                  <button type="button" className="group-info-text-btn ann-add" disabled={saving}
                    onClick={() => { setLinks((ls) => [...ls, { id: linkId.current++, url: '', label: '' }]); setTouched(true); }}>Add link</button>
                )}
              </div>
            )}

            {showGallery && (
              <div className="group-info-announcements-field">
                <span className="group-info-label">Photos</span>
                {gallery.length > 0 && (
                  <ul className="ann-gallery ann-gallery-form">
                    {gallery.map((g, i) => (
                      <li key={g.key} className="ann-gallery-form-item">
                        {g.url && <img src={g.url} alt="" />}
                        <button type="button" className="group-info-text-btn group-info-danger" disabled={saving} aria-label={`Remove photo ${i + 1}`}
                          onClick={() => { setGallery((gs) => gs.filter((x) => x.key !== g.key)); setTouched(true); }}>Remove</button>
                      </li>
                    ))}
                  </ul>
                )}
                {gallery.length < EXTRAS_LIMITS.maxGallery && (
                  <button type="button" className="group-info-text-btn ann-add" disabled={saving || galleryBusy}
                    onClick={() => galleryRef.current?.click()}>{galleryBusy ? 'Uploading…' : 'Add photos'}</button>
                )}
                <input ref={galleryRef} type="file" multiple accept={ANNOUNCEMENT_LIMITS.bannerAccept.join(',')} className="hidden-file-input"
                  aria-hidden="true" tabIndex={-1} data-testid="announcement-gallery-input" onChange={onGalleryFiles} />
                <p className="group-info-helper">Up to {EXTRAS_LIMITS.maxGallery} photos. {ANNOUNCEMENT_LIMITS.bannerHelper}</p>
                {galleryError && <p className="group-info-error" role="alert">{galleryError}</p>}
              </div>
            )}
          </details>
        )}
        {extrasError && <p className="group-info-error" role="alert">{extrasError}</p>}

        {canReschedule && (
          <div className="group-info-announcements-field">
            <span className="group-info-label" id="announcement-publish-label">Publish</span>
            <div className="group-info-chips" role="radiogroup" aria-labelledby="announcement-publish-label">
              {[['now', 'Now'], ['schedule', 'Schedule']].map(([key, label]) => (
                <button key={key} type="button" role="radio" aria-checked={mode === key}
                  className={`group-info-chip${mode === key ? ' group-info-chip-on' : ''}`}
                  onClick={() => { setMode(key); setTouched(true); }}>{label}</button>
              ))}
            </div>
            {mode === 'schedule' && (
              <>
                <input type="datetime-local" className="group-info-input" aria-label="Publish date and time" value={when}
                  min={toLocalInput(new Date())} disabled={saving}
                  max={toLocalInput(new Date(Date.now() + ANNOUNCEMENT_LIMITS.scheduleHorizonDays * 86400000))}
                  onChange={(e) => { setWhen(e.target.value); setTouched(true); }} />
                <p className="group-info-helper">Shown in your time zone{tz ? `, ${tz}` : ''}.</p>
              </>
            )}
          </div>
        )}

        {!editing && gate && !gate.unlimited && !gateHit && (
          <p className="group-info-helper">Free plan: {gate.limit} announcement per week. Used {gate.used} of {gate.limit}.</p>
        )}

        {gateHit && upgrade}
        {error && <p className="group-info-error" role="alert">{error}</p>}
      </form>
    </div>
  );
}
