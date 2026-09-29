import React, { useState, useRef, useEffect } from 'react';
import { Spin } from 'antd';
import { ANNOUNCEMENT_LIMITS, uploadAnnouncementBanner } from '../lib/announcementsApi.js';
import BannerCropper from './BannerCropper.jsx';
import TitleColorPicker from './TitleColorPicker.jsx';
import { normalizeHex, bannerColor, colorName } from '../lib/announcementTitleColor.js';

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
  const fileRef = useRef(null);
  const mountedRef = useRef(true);
  useEffect(() => { mountedRef.current = true; return () => { mountedRef.current = false; }; }, []);
  useEffect(() => () => { if (bannerPreview) URL.revokeObjectURL?.(bannerPreview); }, [bannerPreview]);

  const tz = (() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone; } catch (e) { return ''; } })();
  const currentBanner = bannerKey === null ? null : (bannerPreview || (bannerKey === undefined ? item?.banner_url : null));
  const trimmedTitle = title.trim();
  const trimmedDesc = description.trim();
  const scheduleInvalid = canReschedule && mode === 'schedule' && (!when || Number.isNaN(new Date(when).getTime()));
  const canSubmit = !!trimmedTitle && !!trimmedDesc && !scheduleInvalid && !saving && !bannerBusy;
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

  const heading = editing ? 'Edit announcement' : 'New announcement';
  return (
    <div className="group-info-announcements-form-wrap">
      <div className="group-info-announcements-bar">
        <button type="button" className="group-info-text-btn" onClick={cancel}>Cancel</button>
        <h3 ref={headingRef} tabIndex={-1} className="group-info-announcements-title">{heading}</h3>
        <button type="button" className="group-info-pill" onClick={submit} disabled={!canSubmit}>
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
          {currentBanner ? (
            <div className="group-info-announcements-banner-preview">
              <img src={currentBanner} alt="" />
              {bannerBusy && <Spin className="group-info-avatar-spin" />}
              <div className="group-info-announcements-banner-actions">
                <button type="button" className="group-info-text-btn" disabled={bannerBusy} onClick={() => setCropSource({ url: currentBanner })}>Adjust crop</button>
                <button type="button" className="group-info-text-btn" disabled={bannerBusy} onClick={() => fileRef.current?.click()}>Replace photo</button>
                <button type="button" className="group-info-text-btn group-info-danger" disabled={bannerBusy}
                  onClick={() => { setBannerKey(null); setBannerPreview(null); setTouched(true); }}>Remove</button>
              </div>
            </div>
          ) : (
            <button type="button" className="group-info-announcements-drop" disabled={bannerBusy} onClick={() => fileRef.current?.click()}>
              {bannerBusy ? <Spin size="small" /> : <span>Add banner photo</span>}
              <span className="group-info-helper">{ANNOUNCEMENT_LIMITS.bannerHelper}</span>
            </button>
          )}
          <input ref={fileRef} type="file" accept={ANNOUNCEMENT_LIMITS.bannerAccept.join(',')} className="hidden-file-input"
            aria-hidden="true" tabIndex={-1} data-testid="announcement-banner-input" onChange={onFile} />
          {bannerError && <p className="group-info-error" role="alert">{bannerError}</p>}
        </div>

        <div className="group-info-announcements-field">
          <label className="group-info-label" htmlFor="announcement-title">Title</label>
          <input id="announcement-title" className="group-info-input" value={title} disabled={saving}
            maxLength={ANNOUNCEMENT_LIMITS.titleMax} aria-describedby="announcement-title-help"
            onChange={(e) => { setTitle(e.target.value); setTouched(true); }} />
          {title.length >= ANNOUNCEMENT_LIMITS.titleMax - 20 && <span className="group-info-counter">{title.length}/{ANNOUNCEMENT_LIMITS.titleMax}</span>}
          {!trimmedTitle && <p id="announcement-title-help" className="group-info-helper">Give it a title.</p>}
        </div>

        <div className="group-info-announcements-field">
          <span className="group-info-label">Title color</span>
          <div className={`announce-widget-card title-color-preview${currentBanner ? '' : ' announce-widget-fallback'}`}
            role="img" aria-label={`Preview of the announcement title in ${colorName(titleColor)}`}>
            {currentBanner && <img className="announce-widget-img" src={currentBanner} alt="" />}
            <span className="announce-widget-scrim" aria-hidden="true" />
            <span className="announce-widget-text">
              <span className="announce-widget-label">ANNOUNCEMENT</span>
              <span className="announce-widget-title" style={{ '--title-color': bannerColor(titleColor) }}>{trimmedTitle || 'Your title'}</span>
            </span>
          </div>
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
