import React, { useState, useEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { CloseOutlined } from '@ant-design/icons';
import { fetchLatestAnnouncement, rsvpJoin, rsvpLeave, pollVote, pollRetract, ANNOUNCEMENTS_ENABLED } from '../lib/announcementsApi.js';
import GroupAnnouncementViewer from './GroupAnnouncementViewer.jsx';
import AnnouncementCardFace, { formatShortDate } from './AnnouncementCardFace.jsx';

// Task 20260929-announcement-push-widget (design-notes.md). In-flow banner card
// directly under the group chat header, compact and right-aligned (task
// 20261010-web-announcements-parity); honors bg_theme/title_font/title_color
// and shows location + date. The detail dialog is portaled to <body> so no
// clipped ancestor can cut it off. Groups only (the caller decides).
// Failure behavior (throw-not-fabricate, preserve-cache-on-failed-refresh):
// the fetch throws; a failed refresh keeps the last good announcement in the
// module cache and shows no error UI. If nothing was ever loaded, renders nothing.

const EXIT_MS = 160;
// Swipe-left to dismiss (parity with iOS). The X button stays as the keyboard path.
const SWIPE_DISMISS_PX = 72;

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
  const swipeRef = useRef(null);
  const [dragX, setDragX] = useState(0);
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

  const onPointerDown = (e) => {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    swipeRef.current = { x: e.clientX, y: e.clientY, active: false };
  };
  const onPointerMove = (e) => {
    const st = swipeRef.current;
    if (!st) return;
    const dx = e.clientX - st.x;
    const dy = e.clientY - st.y;
    if (!st.active) {
      if (Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy)) st.active = true; else return;
    }
    setDragX(Math.min(0, dx));
  };
  const onPointerEnd = (e) => {
    const st = swipeRef.current;
    swipeRef.current = null;
    if (!st?.active) return;
    const dx = e.clientX - st.x;
    setDragX(0);
    if (e.type === 'pointerup' && dx <= -SWIPE_DISMISS_PX) dismiss();
  };

  const closeViewer = () => { setViewing(false); setTimeout(() => cardRef.current?.focus(), 0); };

  if (!item || item.published === false || item.id === dismissedId) return null;

  const showBanner = !!item.banner_url && !bannerFailed;
  const rsvp = async (join) => {
    const updated = await (join ? rsvpJoin : rsvpLeave)(userId, groupId, item.id);
    const merged = { ...item, ...updated };
    latestCache.set(cacheKey, merged);
    setItem(merged);
    return merged;
  };
  const pollActions = {
    vote: async (ids) => { const merged = { ...item, ...(await pollVote(userId, groupId, item.id, ids)) }; latestCache.set(cacheKey, merged); setItem(merged); return merged; },
    retract: async () => { const merged = { ...item, ...(await pollRetract(userId, groupId, item.id)) }; latestCache.set(cacheKey, merged); setItem(merged); return merged; },
  };
  return (
    <section className={`announce-widget${leaving ? ' announce-widget-leaving' : ''}`} role="region" aria-label="Latest announcement"
      style={dragX ? { transform: `translateX(${dragX}px)`, opacity: Math.max(0.4, 1 + dragX / 300), touchAction: 'pan-y' } : { touchAction: 'pan-y' }}
      onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerEnd} onPointerCancel={onPointerEnd}>
      <AnnouncementCardFace as="button" ref={cardRef} type="button"
        title={item.title} titleColor={item.title_color} titleFont={item.title_font} bgTheme={item.bg_theme}
        bannerUrl={showBanner ? item.banner_url : null} location={item.location} date={formatShortDate(item.publish_at)}
        onImgError={() => setBannerFailed(true)}
        aria-label={`Announcement: ${item.title}. Open`}
        onClick={() => setViewing(true)} />
      <button type="button" className="announce-widget-dismiss" aria-label="Dismiss announcement" onClick={dismiss}>
        <span className="announce-widget-dismiss-chip"><CloseOutlined /></span>
      </button>
      {viewing && createPortal(
        <div className="group-info-scrim announce-widget-modal" role="dialog" aria-modal="true" aria-label="Announcement"
          onClick={(e) => { if (e.target === e.currentTarget) closeViewer(); }}>
          <div className="announce-widget-modal-body">
            {/* Edit/Delete stay in the group info panel; the widget viewer is read-only. */}
            <GroupAnnouncementViewer item={{ ...item, can_edit: false }} onBack={closeViewer} onRsvp={rsvp} onPoll={pollActions} />
          </div>
        </div>,
        document.body,
      )}
    </section>
  );
}
