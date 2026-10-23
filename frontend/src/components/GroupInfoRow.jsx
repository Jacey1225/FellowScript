import React, { useEffect, useRef, useState, useLayoutEffect } from 'react';
import { createPortal } from 'react-dom';
import { CloseOutlined } from '@ant-design/icons';
import { ANNOUNCEMENTS_ENABLED, rsvpJoin, rsvpLeave } from '../lib/announcementsApi.js';
import { MEDIA_FEATURE } from '../lib/groupMediaApi.js';
import GroupAnnouncementViewer from './GroupAnnouncementViewer.jsx';
import { PinnedListBody } from './PinnedMessagesPanel.jsx';
import { AnnouncementsList, ThreadsList, MediaGrid } from './GroupInfoLists.jsx';

// Task 20261023-group-info-row (design-spec.md). The chip row under a group
// chat header (Announcements, Threads, Pinned, Media) and the bottom submenu it
// opens. Desktop is this web build, so this is also the Tauri UI. Groups only;
// the caller never renders either piece in DMs, the agent chat or a thread.
// Each chip is gated by its own flag; no visible chip means no row at all.

export const PANEL_ID = 'group-info-panel';

export const CHIP_LABELS = {
  announcements: 'Announcements',
  threads: 'Threads',
  pinned: 'Pinned',
  media: 'Media',
};

// Pure gating: the ordered list of chip ids the viewer may see.
export function visibleChips({ features = {}, pinsOn = false, hasUser = true } = {}) {
  const out = [];
  if (ANNOUNCEMENTS_ENABLED && hasUser) out.push('announcements');
  if (features.threads === true && hasUser) out.push('threads');
  if (pinsOn) out.push('pinned');
  if (features[MEDIA_FEATURE] === true && hasUser) out.push('media');
  return out;
}

export function GroupInfoRow({ chips = [], openId, onToggle, pinCount = 0, chipRefs, trailing = null }) {
  if (chips.length === 0 && !trailing) return null;
  return (
    <div className="group-info-row" data-testid="group-info-row">
      <div className="group-info-row-scroll" role="group" aria-label="Group sections">
      {chips.map((id) => {
        const selected = openId === id;
        return (
          <button
            key={id}
            type="button"
            ref={(el) => { if (chipRefs) chipRefs.current[id] = el; }}
            className={`group-info-chip${selected ? ' group-info-chip-selected' : ''}`}
            aria-label={id === 'pinned' && pinCount > 0 ? `Pinned, ${pinCount}` : undefined}
            aria-haspopup="dialog"
            aria-expanded={selected}
            aria-controls={PANEL_ID}
            onClick={() => onToggle(id)}
          >
            {CHIP_LABELS[id]}
            {id === 'pinned' && pinCount > 0 && (
              <span className="group-info-chip-count" aria-hidden="true">{pinCount > 99 ? '99+' : pinCount}</span>
            )}
          </button>
        );
      })}
      </div>
      {trailing && <div className="group-info-row-trailing">{trailing}</div>}
    </div>
  );
}

const prefersReducedMotion = () =>
  typeof window !== 'undefined' && typeof window.matchMedia === 'function'
  && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

// Rendered inside the message area wrapper (position: relative), so the scrim
// covers messages only and the panel is exactly the chat pane wide, directly
// above the composer.
export default function GroupInfoSubmenu({
  openId, onClose, userId, groupId, groupName, pins, viewerId, pinsOn,
  onOpenThread, onJumpPin, onJumpMessage, onOpenLightbox, lightboxOpen,
}) {
  const panelRef = useRef(null);
  const titleRef = useRef(null);
  const [viewing, setViewing] = useState(null);
  const [width, setWidth] = useState(0);
  const [closing, setClosing] = useState(false);

  useEffect(() => { titleRef.current?.focus?.({ preventScroll: true }); }, []);
  useEffect(() => { setViewing(null); }, [openId]);

  useLayoutEffect(() => {
    const el = panelRef.current;
    if (!el) return undefined;
    const measure = () => setWidth(el.clientWidth || el.getBoundingClientRect().width || 0);
    measure();
    if (typeof ResizeObserver === 'undefined') return undefined;
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Esc closes, unless a viewer/lightbox is on top (it owns Esc then).
  useEffect(() => {
    if (viewing || lightboxOpen) return undefined;
    const onKey = (e) => {
      if (e.key !== 'Escape' || e.defaultPrevented) return;
      e.preventDefault();
      e.stopPropagation();
      onClose(true);
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose, viewing, lightboxOpen]);

  const rsvp = async (join) => {
    const updated = await (join ? rsvpJoin : rsvpLeave)(userId, groupId, viewing.id);
    const merged = { ...viewing, ...updated };
    setViewing(merged);
    return merged;
  };

  const requestClose = (restoreFocus = true) => {
    if (prefersReducedMotion() || closing) { onClose(restoreFocus); return; }
    setClosing(true);
    setTimeout(() => onClose(restoreFocus), 200);
  };

  const title = CHIP_LABELS[openId] || '';
  let body = null;
  if (openId === 'announcements') {
    body = <AnnouncementsList userId={userId} groupId={groupId} groupName={groupName} onOpen={setViewing} />;
  } else if (openId === 'threads') {
    body = <ThreadsList userId={userId} groupId={groupId} onOpenThread={(t) => { onClose(false); onOpenThread?.(t); }} />;
  } else if (openId === 'pinned' && pinsOn) {
    body = (
      <PinnedListBody
        spinner
        list={pins.list}
        viewerId={viewerId}
        onJump={onJumpPin}
        onUnpin={(p) => pins.onUnpin(p.messageId)}
        onLoadMore={pins.onLoadMore}
        onRetry={pins.onLoad}
      />
    );
  } else if (openId === 'media') {
    body = (
      <MediaGrid
        userId={userId}
        groupId={groupId}
        width={width}
        onOpenImage={(item, e) => onOpenLightbox?.(item.kind, item.url || item.thumbUrl, e)}
        onShowInChat={(item) => { onClose(false); onJumpMessage?.(item.messageId); }}
      />
    );
  }

  return (
    <>
      {/* eslint-disable-next-line jsx-a11y/no-static-element-interactions */}
      <div className={`group-info-panel-scrim${closing ? ' group-info-panel-closing' : ''}`} aria-hidden="true"
        data-testid="group-info-scrim" onClick={() => requestClose(true)} />
      <div
        ref={panelRef}
        id={PANEL_ID}
        role="dialog"
        aria-label={title}
        className={`group-info-panel${closing ? ' group-info-panel-closing' : ''}`}
      >
        <div className="group-info-panel-head">
          <h2 ref={titleRef} tabIndex={-1} className="group-info-panel-title">{title}</h2>
          <button type="button" className="group-info-panel-close" aria-label={`Close ${title}`} onClick={() => requestClose(true)}>
            <CloseOutlined aria-hidden="true" />
          </button>
        </div>
        <div className="group-info-panel-body" key={openId}>{body}</div>
      </div>
      {viewing && createPortal(
        <div className="group-info-scrim announce-widget-modal" role="dialog" aria-modal="true" aria-label="Announcement"
          onClick={(e) => { if (e.target === e.currentTarget) setViewing(null); }}>
          <div className="announce-widget-modal-body">
            {/* Read-only, like the old chat widget: Edit/Delete stay in group info. */}
            <GroupAnnouncementViewer item={{ ...viewing, can_edit: false }} onBack={() => setViewing(null)} onRsvp={rsvp} />
          </div>
        </div>,
        document.body,
      )}
    </>
  );
}
