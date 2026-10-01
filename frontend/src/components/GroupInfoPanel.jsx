import React, { useState, useEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { Avatar, Switch, Spin } from 'antd';
import {
  CloseOutlined, CameraOutlined, EditOutlined, BellOutlined, FileOutlined,
  PlayCircleOutlined, DownloadOutlined, NotificationOutlined, RightOutlined,
} from '@ant-design/icons';
import { useFocusTrap } from '../hooks/useFocusTrap.js';
import {
  fetchGroupInfo, renameGroup, setGroupMuted, setGroupMaxMembers, uploadGroupPhoto,
  removeGroupPhoto, confirmGroupPhoto, fetchGroupGallery, GROUP_PHOTO_LIMITS,
} from '../lib/groupInfoApi.js';
import { ANNOUNCEMENTS_ENABLED } from '../lib/announcementsApi.js';
import GroupAnnouncements from './GroupAnnouncements.jsx';
import InviteLinkSection from './InviteLinkSection.jsx';

// Task 20260929-group-info-panel (design-notes.md). Groups only. All network
// calls throw on failure (lib/groupInfoApi.js) and this component never
// fabricates a success: mute state always shows the last server-confirmed
// value, and a failed refresh keeps whatever was cached (module-level maps
// below) rather than blanking it.

const MAX_TITLE = 255;
const UNDO_MS = 8000;
const SIDE_PANEL_QUERY = '(min-width: 768px)';

const FILTERS = [
  { key: 'all', label: 'All', kind: null, empty: 'Nothing shared yet. Photos, GIFs, and files from this group will gather here.' },
  { key: 'image', label: 'Photos', kind: 'image', empty: 'No photos yet.' },
  { key: 'video', label: 'Videos', kind: 'video', empty: 'No videos yet.' },
  { key: 'gif', label: 'GIFs', kind: 'gif', empty: 'No GIFs yet.' },
  { key: 'file', label: 'Files', kind: 'file', empty: 'No files yet.' },
];

// Last-known-good data, keyed by group (and filter for the gallery).
const infoCache = new Map();
const galleryCache = new Map();
export function _clearGroupInfoCaches() { infoCache.clear(); galleryCache.clear(); }

function useSidePanelLayout() {
  const [wide, setWide] = useState(() =>
    typeof window !== 'undefined' && window.matchMedia ? window.matchMedia(SIDE_PANEL_QUERY).matches : true);
  useEffect(() => {
    if (!window.matchMedia) return undefined;
    const mql = window.matchMedia(SIDE_PANEL_QUERY);
    const onChange = (e) => setWide(e.matches);
    mql.addEventListener('change', onChange);
    return () => mql.removeEventListener('change', onChange);
  }, []);
  return wide;
}

function formatDate(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' });
}

function GalleryTile({ item, onOpenLightbox }) {
  const label = `${item.kind === 'video' ? 'Video' : item.kind === 'gif' ? 'GIF' : 'Photo'} from ${item.from_user || 'a member'}, ${formatDate(item.timestamp)}`;
  if (!item.url) return <div className="group-info-tile group-info-tile-missing" aria-label={`${label}, unavailable`} />;
  if (item.kind === 'video') {
    return (
      <a className="group-info-tile" href={item.url} target="_blank" rel="noreferrer" aria-label={label}>
        {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
        <video src={item.url} preload="metadata" muted />
        <PlayCircleOutlined className="group-info-tile-badge" />
      </a>
    );
  }
  return (
    <button type="button" className="group-info-tile" aria-label={label}
      onClick={(e) => onOpenLightbox?.(item.kind, item.url, e)}>
      <img src={(item.kind === 'gif' && item.meta?.preview_url) || item.url} alt="" loading="lazy" />
      {item.kind === 'gif' && <span className="group-info-tile-tag">GIF</span>}
    </button>
  );
}

export default function GroupInfoPanel({
  open, onClose, contact, user, groupMembers = [], onGroupChanged, onGroupGone, onOpenLightbox,
}) {
  const groupId = contact?.id;
  const userId = user?.user_id;
  const wide = useSidePanelLayout();
  const reducedMotion = typeof window !== 'undefined' && !!window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const panelRef = useRef(null);
  const headingRef = useRef(null);
  const photoInputRef = useRef(null);
  const undoTimerRef = useRef(null);
  const mountedRef = useRef(true);
  useEffect(() => { mountedRef.current = true; return () => { mountedRef.current = false; clearTimeout(undoTimerRef.current); }; }, []);

  useFocusTrap(open && !wide, panelRef);

  const [info, setInfo] = useState(null);           // last server-confirmed info
  const [refreshError, setRefreshError] = useState(false);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState('');
  const [saving, setSaving] = useState(false);
  const [nameError, setNameError] = useState(null);
  const [photoBusy, setPhotoBusy] = useState(false);
  const [photoError, setPhotoError] = useState(null);
  const [photoMenu, setPhotoMenu] = useState(false);
  const [photoJustUpdated, setPhotoJustUpdated] = useState(false);
  const [undo, setUndo] = useState(null);           // { restoreKey }
  const [capDraft, setCapDraft] = useState('');
  const [capSaving, setCapSaving] = useState(false);
  const [capError, setCapError] = useState(null);
  const [capSaved, setCapSaved] = useState(false);
  const [mutePending, setMutePending] = useState(false);
  const [muteError, setMuteError] = useState(null);
  const [view, setView] = useState('main');       // 'main' | 'announcements'
  const viewRef = useRef('main');
  viewRef.current = view;
  const announcementsRowRef = useRef(null);
  const [filter, setFilter] = useState('all');
  const [gallery, setGallery] = useState(null);     // { items, cursor, hasMore }
  const [galleryLoading, setGalleryLoading] = useState(false);
  const [galleryError, setGalleryError] = useState(null);

  const handleFailure = useCallback((err) => {
    if (err?.status === 403) { onGroupGone?.(); return true; }
    return false;
  }, [onGroupGone]);

  // Info: cached first, then refresh. A failed refresh keeps the cache.
  useEffect(() => {
    if (!open || !groupId || !userId) return undefined;
    setInfo(infoCache.get(groupId) || null);
    setRefreshError(false);
    setEditing(false); setNameError(null); setPhotoError(null); setMuteError(null); setView('main');
    let cancelled = false;
    fetchGroupInfo(userId, groupId)
      .then((data) => { if (cancelled) return; infoCache.set(groupId, data); setInfo(data); })
      .catch((err) => { if (cancelled) return; if (!handleFailure(err)) setRefreshError(true); });
    return () => { cancelled = true; };
  }, [open, groupId, userId, handleFailure]);

  const filterDef = FILTERS.find(f => f.key === filter) || FILTERS[0];

  // Gallery first page for the active filter: cached first, then refresh.
  const loadGalleryFirstPage = useCallback(() => {
    if (!groupId || !userId) return () => {};
    const cacheKey = `${groupId}:${filterDef.key}`;
    setGallery(galleryCache.get(cacheKey) || null);
    setGalleryError(null);
    let cancelled = false;
    setGalleryLoading(true);
    fetchGroupGallery(userId, groupId, { kind: filterDef.kind })
      .then((page) => {
        if (cancelled) return;
        const next = {
          items: page.items || [],
          cursor: page.has_more ? { timestamp: page.next_cursor_timestamp, id: page.next_cursor_id } : null,
          hasMore: !!page.has_more,
        };
        galleryCache.set(cacheKey, next);
        setGallery(next);
      })
      .catch((err) => { if (cancelled) return; if (!handleFailure(err)) setGalleryError(err.message || "Couldn't load shared items."); })
      .finally(() => { if (!cancelled) setGalleryLoading(false); });
    return () => { cancelled = true; };
  }, [groupId, userId, filterDef.key, filterDef.kind, handleFailure]);

  useEffect(() => (open ? loadGalleryFirstPage() : undefined), [open, loadGalleryFirstPage]);

  const loadMore = async () => {
    if (!gallery?.cursor || galleryLoading) return;
    setGalleryLoading(true);
    setGalleryError(null);
    try {
      const page = await fetchGroupGallery(userId, groupId, { kind: filterDef.kind, cursor: gallery.cursor });
      if (!mountedRef.current) return;
      const next = {
        items: [...gallery.items, ...(page.items || [])],
        cursor: page.has_more ? { timestamp: page.next_cursor_timestamp, id: page.next_cursor_id } : null,
        hasMore: !!page.has_more,
      };
      galleryCache.set(`${groupId}:${filterDef.key}`, next);
      setGallery(next);
    } catch (err) {
      if (mountedRef.current && !handleFailure(err)) setGalleryError(err.message || "Couldn't load more.");
    } finally {
      if (mountedRef.current) setGalleryLoading(false);
    }
  };

  // Esc closes (web only); focus moves to the heading on open.
  useEffect(() => {
    if (!open) return undefined;
    headingRef.current?.focus();
    // Sub-views own Esc (back one level); the panel only closes from main.
    const onKey = (e) => { if (e.key === 'Escape' && !e.defaultPrevented && viewRef.current === 'main') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  const applyInfo = (patch) => {
    setInfo((prev) => {
      const next = { ...(prev || {}), ...patch };
      infoCache.set(groupId, next);
      return next;
    });
  };

  const capInitial = info?.max_members == null ? '' : String(info.max_members);
  useEffect(() => { setCapDraft(capInitial); setCapError(null); setCapSaved(false); }, [capInitial, groupId]);

  const saveCap = async () => {
    if (capSaving) return;
    const raw = capDraft.trim();
    let value = null;
    if (raw !== '') {
      if (!/^\d+$/.test(raw)) { setCapError('Enter a whole number.'); return; }
      value = parseInt(raw, 10);
    }
    setCapSaving(true); setCapError(null); setCapSaved(false);
    try {
      await setGroupMaxMembers(userId, groupId, value);
      if (!mountedRef.current) return;
      applyInfo({ max_members: value });
      setCapSaved(true);
    } catch (err) {
      if (!mountedRef.current) return;
      if (err?.status === 403) setCapError('Only the group owner can change this.');
      else setCapError(err?.status === 422 && err.message ? err.message : "Couldn't save the limit. Please try again.");
    } finally {
      if (mountedRef.current) setCapSaving(false);
    }
  };

  const startEdit = () => { setDraft(info?.title ?? contact?.name ?? ''); setNameError(null); setEditing(true); };
  const trimmed = draft.trim();
  const saveName = async () => {
    if (!trimmed || saving) return;
    setSaving(true); setNameError(null);
    try {
      const res = await renameGroup(userId, groupId, trimmed);
      applyInfo({ title: res.title });
      onGroupChanged?.({ title: res.title });
      setEditing(false);
    } catch (err) {
      if (!handleFailure(err)) setNameError(err.status === 422 ? (err.message || "That name isn't allowed here. Try something else.") : (err.message || "That name didn't save. Please try again."));
    } finally {
      setSaving(false);
    }
  };

  const flashPhoto = () => { setPhotoJustUpdated(true); setTimeout(() => mountedRef.current && setPhotoJustUpdated(false), 650); };

  const onPhotoChosen = async (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;
    setPhotoError(null); setPhotoBusy(true); setUndo(null);
    try {
      const res = await uploadGroupPhoto(userId, groupId, file);
      applyInfo({ photo_url: res.photo_url });
      onGroupChanged?.({ photoUrl: res.photo_url });
      flashPhoto();
    } catch (err) {
      if (!handleFailure(err)) setPhotoError(err.message || 'Upload failed. Please try again.');
    } finally {
      if (mountedRef.current) setPhotoBusy(false);
    }
  };

  const onRemovePhoto = async () => {
    setPhotoMenu(false); setPhotoError(null); setPhotoBusy(true);
    try {
      const res = await removeGroupPhoto(userId, groupId);
      applyInfo({ photo_url: null });
      onGroupChanged?.({ photoUrl: null });
      flashPhoto();
      if (res.restore_key) {
        setUndo({ restoreKey: res.restore_key });
        clearTimeout(undoTimerRef.current);
        undoTimerRef.current = setTimeout(() => mountedRef.current && setUndo(null), UNDO_MS);
      }
    } catch (err) {
      if (!handleFailure(err)) setPhotoError(err.message || "Couldn't remove the photo. Please try again.");
    } finally {
      if (mountedRef.current) setPhotoBusy(false);
    }
  };

  const onUndoRemove = async () => {
    if (!undo) return;
    const { restoreKey } = undo;
    clearTimeout(undoTimerRef.current);
    setUndo(null); setPhotoBusy(true);
    try {
      const res = await confirmGroupPhoto(userId, groupId, restoreKey);
      applyInfo({ photo_url: res.photo_url });
      onGroupChanged?.({ photoUrl: res.photo_url });
      flashPhoto();
    } catch (err) {
      if (!handleFailure(err)) setPhotoError("Couldn't restore the photo. Please choose it again.");
    } finally {
      if (mountedRef.current) setPhotoBusy(false);
    }
  };

  const onToggleMute = async (next) => {
    if (mutePending) return;
    setMutePending(true); setMuteError(null);
    try {
      const res = await setGroupMuted(userId, groupId, next);
      applyInfo({ muted: !!res.muted });
    } catch (err) {
      if (!handleFailure(err)) setMuteError("Couldn't update notifications. Please try again.");
    } finally {
      if (mountedRef.current) setMutePending(false);
    }
  };

  if (!open || !contact || contact.type !== 'group') return null;

  const title = info?.title ?? contact.name;
  const photoUrl = info ? info.photo_url : contact.photoUrl;
  const initial = (title || '?')[0].toUpperCase();
  const memberList = [
    { key: 'me', username: user?.username, photoUrl: user?.profile_photo_url, me: true },
    ...groupMembers.map((m, i) => ({ key: m.user_id || i, username: m.username || m.user_id?.slice(0, 8) || '?', photoUrl: m.photoUrl })),
  ];
  const items = gallery?.items || [];
  const fileItems = items.filter(i => i.kind === 'file');
  const mediaItems = items.filter(i => i.kind !== 'file');

  const body = (
    <div
      ref={panelRef}
      className={`group-info-panel ${wide ? 'group-info-side' : 'group-info-sheet'}${reducedMotion ? ' group-info-still' : ''}`}
      role="dialog"
      aria-modal={wide ? undefined : 'true'}
      aria-labelledby="group-info-heading"
    >
      {!wide && <div className="group-info-handle" aria-hidden="true" />}
      <div className="group-info-top">
        <h2 id="group-info-heading" ref={headingRef} tabIndex={-1} className="group-info-heading">Group info</h2>
        <button type="button" className="group-info-icon-btn" onClick={onClose} aria-label="Close group info">
          <CloseOutlined />
        </button>
      </div>

      {view === 'announcements' && (
        <div className="group-info-scroll">
          <GroupAnnouncements
            userId={userId} groupId={groupId}
            onBack={() => { setView('main'); setTimeout(() => announcementsRowRef.current?.focus(), 0); }}
            onGroupGone={() => onGroupGone?.()}
            onUpgrade={() => { window.location.assign('/account'); }}
            onOpenLightbox={onOpenLightbox}
          />
        </div>
      )}

      <div className="group-info-scroll" hidden={view !== 'main'}>
        {refreshError && (
          <div className="group-info-banner" role="status">
            <span>Couldn't refresh just now. Showing what we have.</span>
            <button type="button" className="group-info-text-btn"
              onClick={() => { setRefreshError(false); fetchGroupInfo(userId, groupId).then(d => { infoCache.set(groupId, d); setInfo(d); }).catch(err => { if (!handleFailure(err)) setRefreshError(true); }); }}>
              Try again
            </button>
          </div>
        )}

        {/* Identity */}
        <section className="group-info-identity">
          <div className="group-info-avatar-wrap">
            <button type="button" className="group-info-avatar-btn" aria-label="Change group photo"
              aria-haspopup="menu" aria-expanded={photoMenu} disabled={photoBusy}
              onClick={() => (photoUrl ? setPhotoMenu(v => !v) : photoInputRef.current?.click())}>
              <Avatar size={88} src={photoUrl} className={photoJustUpdated ? 'fs-avatar-crossfade' : undefined}
                style={{ background: 'rgba(255,198,26,0.12)', color: 'var(--gold)', fontSize: '1.8rem', opacity: photoBusy ? 0.4 : 1 }}>
                {initial}
              </Avatar>
              {photoBusy && <Spin className="group-info-avatar-spin" />}
              <span className="group-info-camera" aria-hidden="true"><CameraOutlined /></span>
            </button>
            <input ref={photoInputRef} type="file" accept={GROUP_PHOTO_LIMITS.accept.join(',')}
              className="hidden-file-input" onChange={onPhotoChosen} aria-hidden="true" tabIndex={-1} />
          </div>
          {photoMenu && (
            <div className="group-info-menu" role="menu">
              <button type="button" role="menuitem" className="group-info-text-btn"
                onClick={() => { setPhotoMenu(false); photoInputRef.current?.click(); }}>Choose photo</button>
              <button type="button" role="menuitem" className="group-info-text-btn group-info-danger" onClick={onRemovePhoto}>Remove photo</button>
            </div>
          )}
          {photoError && <p className="group-info-error" role="alert">{photoError}</p>}

          {editing ? (
            <div className="group-info-rename">
              <input className="group-info-input" value={draft} maxLength={MAX_TITLE} disabled={saving}
                aria-label="Group name" autoFocus
                onChange={(e) => setDraft(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') saveName(); if (e.key === 'Escape') { e.stopPropagation(); setEditing(false); } }} />
              {draft.length >= 230 && <span className="group-info-counter">{draft.length}/{MAX_TITLE}</span>}
              {!trimmed && <p className="group-info-helper">Give the group a name.</p>}
              {nameError && <p className="group-info-error" role="alert">{nameError}</p>}
              <div className="group-info-rename-actions">
                <button type="button" className="group-info-pill" onClick={saveName} disabled={!trimmed || saving}>
                  {saving ? <Spin size="small" /> : 'Save'}
                </button>
                <button type="button" className="group-info-text-btn" onClick={() => setEditing(false)} disabled={saving}>Cancel</button>
              </div>
            </div>
          ) : (
            <div className="group-info-name-row">
              <span className="group-info-name">{title}</span>
              <button type="button" className="group-info-text-btn" onClick={startEdit} aria-label="Edit group name">
                <EditOutlined /> Edit name
              </button>
            </div>
          )}
        </section>

        {/* Notifications */}
        <section className="group-info-card" aria-label="Notifications">
          <BellOutlined className="group-info-card-icon" />
          <div className="group-info-card-text">
            <span id="group-info-mute-label">Mute notifications</span>
            <span className="group-info-helper">You will still get messages here, just no alerts.</span>
            {muteError && <span className="group-info-error" role="alert">{muteError}</span>}
          </div>
          {info ? (
            <Switch checked={!!info.muted} loading={mutePending} disabled={mutePending}
              onChange={onToggleMute} aria-labelledby="group-info-mute-label" />
          ) : (
            <span className="group-info-skeleton" aria-hidden="true" />
          )}
        </section>

        {/* Announcements */}
        {ANNOUNCEMENTS_ENABLED && (
          <button type="button" ref={announcementsRowRef} className="group-info-card group-info-card-button"
            aria-label="Announcements" onClick={() => setView('announcements')}>
            <NotificationOutlined className="group-info-card-icon" />
            <span className="group-info-card-text">
              <span>Announcements</span>
              <span className="group-info-helper">Updates for everyone in this group.</span>
            </span>
            <RightOutlined aria-hidden="true" />
          </button>
        )}

        {/* Invite link (task 20260929-group-invite-links). Hides itself when
            the feature flag is off (uniform 404 from the list endpoint). */}
        <InviteLinkSection userId={userId} groupId={groupId} reducedMotion={reducedMotion}
          onForbidden={handleFailure} />

        {/* Member limit: owner edits, everyone else sees a read-only value. */}
        {info && (info.is_owner || info.max_members != null) && (
          <section aria-label="Member limit">
            <h3 className="group-info-label">Member limit</h3>
            {info.is_owner ? (
              <div className="group-info-rename">
                <label htmlFor="group-max-members" className="group-info-helper">
                  Most people allowed in this group. Leave blank for no limit.
                </label>
                <input id="group-max-members" className="group-info-input" inputMode="numeric"
                  value={capDraft} disabled={capSaving} placeholder="No limit"
                  onChange={(e) => { setCapDraft(e.target.value); setCapError(null); setCapSaved(false); }}
                  onKeyDown={(e) => { if (e.key === 'Enter') saveCap(); }}
                  aria-invalid={!!capError} aria-describedby={capError ? 'group-max-members-error' : undefined} />
                {info.max_members_ceiling != null && (
                  <span className="group-info-helper">Up to {info.max_members_ceiling}. Not lower than the {memberList.length} {memberList.length === 1 ? 'person' : 'people'} here now.</span>
                )}
                {capError && <p id="group-max-members-error" className="group-info-error" role="alert">{capError}</p>}
                <div className="group-info-rename-actions">
                  <button type="button" className="group-info-pill" onClick={saveCap}
                    disabled={capSaving || capDraft.trim() === capInitial}>
                    {capSaving ? <Spin size="small" /> : 'Save limit'}
                  </button>
                </div>
                <span className="group-info-sr" aria-live="polite">{capSaved ? 'Member limit saved' : ''}</span>
              </div>
            ) : (
              <p className="group-info-helper">Up to {info.max_members} people can be in this group.</p>
            )}
          </section>
        )}

        {/* Members */}
        <section>
          <h3 className="group-info-label">Members · {memberList.length}</h3>
          <div className={memberList.length > 8 ? 'group-info-members group-info-members-scroll' : 'group-info-members'}>
            {memberList.map((m) => (
              <div key={m.key} className="group-info-member">
                <Avatar size={32} src={m.photoUrl} style={{ background: 'rgba(255,198,26,0.12)', color: 'var(--gold)' }}>
                  {(m.username || '?')[0].toUpperCase()}
                </Avatar>
                <span className={m.me ? 'group-info-member-me' : undefined}>{m.username}{m.me ? ' (you)' : ''}</span>
              </div>
            ))}
          </div>
        </section>

        {/* Shared */}
        <section>
          <h3 className="group-info-label">Shared</h3>
          <div className="group-info-chips" role="tablist" aria-label="Filter shared items">
            {FILTERS.map(f => (
              <button key={f.key} type="button" role="tab" aria-selected={filter === f.key}
                className={`group-info-chip${filter === f.key ? ' group-info-chip-on' : ''}`}
                onClick={() => setFilter(f.key)}>{f.label}</button>
            ))}
          </div>

          {!gallery && galleryLoading && <div className="group-info-skeleton-grid" aria-label="Loading shared items" />}
          {galleryError && (
            <p className="group-info-error" role="alert">
              {galleryError}{' '}
              <button type="button" className="group-info-text-btn" onClick={gallery ? loadMore : loadGalleryFirstPage}>Try again</button>
            </p>
          )}
          {gallery && items.length === 0 && !galleryError && <p className="group-info-empty">{filterDef.empty}</p>}
          {mediaItems.length > 0 && (
            <div className="group-info-grid">
              {mediaItems.map(it => <GalleryTile key={it.id} item={it} onOpenLightbox={onOpenLightbox} />)}
            </div>
          )}
          {fileItems.length > 0 && (
            <div className="group-info-files">
              {fileItems.map(it => (
                <a key={it.id} className="group-info-file" href={it.url || undefined} target="_blank" rel="noreferrer"
                  aria-label={`File ${it.meta?.filename || 'file'} from ${it.from_user || 'a member'}, download`}>
                  <FileOutlined style={{ color: 'var(--gold)' }} />
                  <span className="group-info-file-text">
                    <span className="group-info-file-name">{it.meta?.filename || 'File'}</span>
                    <span className="group-info-helper">{it.from_user} · {formatDate(it.timestamp)}</span>
                  </span>
                  <DownloadOutlined />
                </a>
              ))}
            </div>
          )}
          {gallery?.hasMore && (
            <button type="button" className="group-info-secondary-pill" onClick={loadMore} disabled={galleryLoading}
              aria-label="Load more shared items">
              {galleryLoading ? <Spin size="small" /> : 'Load more'}
            </button>
          )}
        </section>
      </div>

      {undo && (
        <div className="group-info-toast" role="status">
          <span>Group photo removed.</span>
          <button type="button" className="group-info-text-btn" onClick={onUndoRemove}>Undo</button>
        </div>
      )}
    </div>
  );

  if (wide) return body;
  return createPortal(
    <>
      <div className="group-info-scrim" onClick={onClose} aria-hidden="true" />
      {body}
    </>,
    document.body,
  );
}
