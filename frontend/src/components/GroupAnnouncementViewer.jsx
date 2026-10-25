import { surfaceColor } from '../lib/announcementTitleColor.js';
import React, { useEffect, useState } from 'react';
import { LeftOutlined, DeleteOutlined, EditOutlined } from '@ant-design/icons';
import {
  bgThemeCss, bgThemeReadableText, resolveBgTheme, titleColorOnTheme, titleFontStyle,
} from '../lib/announcementStyle.js';
import AnnouncementExtrasDetail from './AnnouncementExtrasDetail.jsx';

// Read-only view of one announcement (design-notes.md, "Viewer"). Edit and
// Delete only render for users the server marked `can_edit` (author or group
// creator); they are hidden, not disabled, for everyone else.

export function formatDateTime(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleString([], { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' });
}

// Layout (iOS GroupAnnouncementDetailView): the theme fills the page; the
// banner is a full-bleed decorative background that fades into it (mask
// gradient + light scrim), then title, By creator + date, description, extras.
export default function GroupAnnouncementViewer({ item, onBack, onEdit, onDelete, onOpenLightbox, onRsvp, onPoll, headingRef }) {
  const [bannerFailed, setBannerFailed] = useState(false);
  useEffect(() => { setBannerFailed(false); }, [item.id, item.banner_url]);
  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== 'Escape' || e.defaultPrevented) return;
      e.preventDefault();
      onBack();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onBack]);

  const theme = resolveBgTheme(item.bg_theme);
  const themed = theme !== 'none';
  const hasBanner = !!item.banner_url && !bannerFailed;
  const readable = bgThemeReadableText(theme);
  const titleColor = themed ? titleColorOnTheme(item.title_color, theme, readable) : surfaceColor(item.title_color);
  const articleStyle = themed ? { background: bgThemeCss(theme), color: readable } : undefined;

  return (
    <article className={`group-info-announcements-viewer ann-detail${themed ? ' ann-detail-themed' : ''}`}
      aria-labelledby="announcement-viewer-title" style={articleStyle}>
      {hasBanner && (
        <div className="ann-detail-bg" aria-hidden="true">
          <img src={item.banner_url} alt="" onError={() => setBannerFailed(true)} />
        </div>
      )}
      <div className={`ann-detail-content${hasBanner ? ' ann-detail-has-banner' : ''}`}>
        <div className="group-info-announcements-bar">
          <button type="button" className="ann-circle-btn ann-detail-back" onClick={onBack} aria-label="Back to announcements" title="Back"><LeftOutlined /></button>
          <span className="group-info-announcements-bar-spacer" />
          {item.can_edit && (
            <>
              <button type="button" className="ann-circle-btn group-info-danger" onClick={() => onDelete(item)} aria-label="Delete" title="Delete"><DeleteOutlined /></button>
              <button type="button" className="ann-circle-btn ann-circle-btn-primary" onClick={() => onEdit(item)} aria-label="Edit" title="Edit"><EditOutlined /></button>
            </>
          )}
        </div>
        {!item.published && <span className="group-info-announcements-chip">Scheduled for {formatDateTime(item.publish_at)}</span>}
        <h3 id="announcement-viewer-title" ref={headingRef} tabIndex={-1} className="group-info-announcements-viewer-title"
          style={{ color: titleColor, ...titleFontStyle(item.title_font) }}>{item.title}</h3>
        <p className="group-info-helper ann-detail-by">By {item.creator_username || 'a member'}, {formatDateTime(item.publish_at)}</p>
        <p className="group-info-announcements-body">{item.description}</p>
        <AnnouncementExtrasDetail item={item} onRsvp={onRsvp} onOpenLightbox={onOpenLightbox} pollActions={onPoll} />
      </div>
    </article>
  );
}
