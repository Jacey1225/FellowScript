import React, { useEffect } from 'react';

// Read-only view of one announcement (design-notes.md, "Viewer"). Edit and
// Delete only render for users the server marked `can_edit` (author or group
// creator); they are hidden, not disabled, for everyone else.

export function formatDateTime(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleString([], { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' });
}

export default function GroupAnnouncementViewer({ item, onBack, onEdit, onDelete, onOpenLightbox, headingRef }) {
  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== 'Escape' || e.defaultPrevented) return;
      e.preventDefault();
      onBack();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onBack]);

  return (
    <article className="group-info-announcements-viewer" aria-labelledby="announcement-viewer-title">
      <div className="group-info-announcements-bar">
        <button type="button" className="group-info-text-btn" onClick={onBack} aria-label="Back to announcements">Back</button>
        <span className="group-info-announcements-bar-spacer" />
        {item.can_edit && (
          <>
            <button type="button" className="group-info-text-btn group-info-danger" onClick={() => onDelete(item)}>Delete</button>
            <button type="button" className="group-info-pill" onClick={() => onEdit(item)}>Edit</button>
          </>
        )}
      </div>
      {item.banner_url && (
        <button type="button" className="group-info-announcements-banner" aria-label={`Banner for ${item.title}, open larger`}
          onClick={(e) => onOpenLightbox?.('image', item.banner_url, e)}>
          <img src={item.banner_url} alt="" loading="lazy" />
        </button>
      )}
      {!item.published && <span className="group-info-announcements-chip">Scheduled for {formatDateTime(item.publish_at)}</span>}
      <h3 id="announcement-viewer-title" ref={headingRef} tabIndex={-1} className="group-info-announcements-viewer-title">{item.title}</h3>
      <p className="group-info-helper">By {item.creator_username || 'a member'}, {formatDateTime(item.publish_at)}</p>
      <p className="group-info-announcements-body">{item.description}</p>
    </article>
  );
}
