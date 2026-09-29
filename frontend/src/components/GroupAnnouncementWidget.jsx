import React, { useState, useEffect, useRef, useCallback } from 'react';
import { CloseOutlined, RightOutlined } from '@ant-design/icons';
import { fetchLatestAnnouncement, ANNOUNCEMENTS_ENABLED } from '../lib/announcementsApi.js';
import GroupAnnouncementViewer from './GroupAnnouncementViewer.jsx';

// Task 20260929-announcement-push-widget (design-notes.md). In-flow banner card
// directly under the group chat header. Groups only (the caller decides).
// Failure behavior (throw-not-fabricate, preserve-cache-on-failed-refresh):
// the fetch throws; a failed refresh keeps the last good announcement in the
// module cache and shows no error UI. If nothing was ever loaded, renders nothing.

const EXIT_MS = 160;

// Last-known-good announcement keyed by `${userId}:${groupId}` (null = none).
const latestCache = new Map();
export function _clearWidgetCache() { latestCache.clear(); }

export const dismissKey = (userId, groupId) => `fs.announcementDismissed.${userId}.${groupId}`;
function readDismissed(userId, groupId) {
  try { return window.localStorage.getItem(dismissKey(userId, groupId)); } catch (err) { return null; }
}
function writeDismissed(userId, groupId, id) {
  try { window.localStorage.setItem(dismissKey(userId, groupId), id); } catch (err) { /* private mode: dismissal is session-only */ }
}
const prefersReducedMotion = () =>
  typeof window !== 'undefined' && typeof window.matchMedia === 'function'
  && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

export default function GroupAnnouncementWidget({ userId, groupId, onAfterDismiss }) {
  const cacheKey = `${userId}:${groupId}`;
  const [item, setItem] = useState(() => latestCache.get(cacheKey) ?? null);
  const [dismissedId, setDismissedId] = useState(() => readDismissed(userId, groupId));
  const [leaving, setLeaving] = useState(false);
  const [viewing, setViewing] = useState(false);
  const cardRef = useRef(null);
  const [bannerFailed, setBannerFailed] = useState(false);

  const refresh = useCallback(() => {
    if (!ANNOUNCEMENTS_ENABLED || !userId || !groupId) return () => {};
    let live = true;
    fetchLatestAnnouncement(userId, groupId)
      .then(res => {
        if (!live) return;
        const next = res?.announcement ?? null;
        latestCache.set(cacheKey, next);
        setItem(next);
      })
      .catch(() => { /* keep the previously shown widget; no error UI */ });
    return () => { live = false; };
  }, [userId, groupId, cacheKey]);

  useEffect(() => {
    setItem(latestCache.get(cacheKey) ?? null);
    setDismissedId(readDismissed(userId, groupId));
    setLeaving(false);
    setViewing(false);
    return refresh();
  }, [cacheKey, userId, groupId, refresh]);

  useEffect(() => { setBannerFailed(false); }, [item?.id, item?.banner_url]);

  useEffect(() => {
    const onFocus = () => { refresh(); };
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [refresh]);

  const dismiss = () => {
    if (!item) return;
    const id = item.id;
    writeDismissed(userId, groupId, id);
    const finish = () => { setDismissedId(id); setLeaving(false); onAfterDismiss?.(); };
    if (prefersReducedMotion()) { finish(); return; }
    setLeaving(true);
    setTimeout(finish, EXIT_MS);
  };

  const closeViewer = () => { setViewing(false); setTimeout(() => cardRef.current?.focus(), 0); };

  if (!item || item.published === false || item.id === dismissedId) return null;

  const showBanner = !!item.banner_url && !bannerFailed;
  return (
    <section className={`announce-widget${leaving ? ' announce-widget-leaving' : ''}`} role="region" aria-label="Latest announcement">
      <button ref={cardRef} type="button"
        className={`announce-widget-card${showBanner ? '' : ' announce-widget-fallback'}`}
        aria-label={`Announcement: ${item.title}. Open`}
        onClick={() => setViewing(true)}>
        {showBanner && (
          <img className="announce-widget-img" src={item.banner_url} alt="" loading="lazy" onError={() => setBannerFailed(true)} />
        )}
        <span className="announce-widget-scrim" aria-hidden="true" />
        <span className="announce-widget-text">
          <span className="announce-widget-label">ANNOUNCEMENT</span>
          <span className="announce-widget-title">{item.title}</span>
        </span>
        <span className="announce-widget-cta" aria-hidden="true">View <RightOutlined /></span>
      </button>
      <button type="button" className="announce-widget-dismiss" aria-label="Dismiss announcement" onClick={dismiss}>
        <span className="announce-widget-dismiss-chip"><CloseOutlined /></span>
      </button>
      {viewing && (
        <div className="group-info-scrim announce-widget-modal" role="dialog" aria-modal="true" aria-label="Announcement"
          onClick={(e) => { if (e.target === e.currentTarget) closeViewer(); }}>
          <div className="announce-widget-modal-body">
            {/* Edit/Delete stay in the group info panel; the widget viewer is read-only. */}
            <GroupAnnouncementViewer item={{ ...item, can_edit: false }} onBack={closeViewer} />
          </div>
        </div>
      )}
    </section>
  );
}
