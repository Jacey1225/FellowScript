import React, { forwardRef } from 'react';
import { bannerColor, normalizeHex } from '../lib/announcementTitleColor.js';
import {
  bgThemeCss, resolveBgTheme, bgThemeReadableText, titleColorOnTheme, titleFontStyle,
} from '../lib/announcementStyle.js';

// The compact banner card face shared by the chat widget and the form's live
// preview (task 20261010-web-announcements-parity), so the two can't drift.
// Layering: image < scrim < text. The card's box comes from the parent
// (3:1), the image is out-of-flow so a huge photo can never grow it.

export function formatShortDate(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

const AnnouncementCardFace = forwardRef(function AnnouncementCardFace({
  as: Tag = 'div', title, titleColor, titleFont, bgTheme, bannerUrl, location, date, onImgError, className = '', ...rest
}, ref) {
  const theme = resolveBgTheme(bgTheme);
  const themed = theme !== 'none';
  const hasBanner = !!bannerUrl;
  // Over a photo the color is judged against the scrim; over a bare theme, against the theme.
  const color = hasBanner || !themed
    ? bannerColor(titleColor)
    : (titleColorOnTheme(normalizeHex(titleColor), theme, bgThemeReadableText(theme)));
  const style = themed && !hasBanner ? { background: bgThemeCss(theme) } : undefined;
  const cls = `announce-widget-card${hasBanner || themed ? '' : ' announce-widget-fallback'}${themed ? ' announce-widget-themed' : ''} ${className}`.trim();
  const place = (location || '').trim();
  return (
    <Tag ref={ref} className={cls} style={style} {...rest}>
      {hasBanner && <img className="announce-widget-img" src={bannerUrl} alt="" loading="lazy" onError={onImgError} />}
      <span className="announce-widget-scrim" aria-hidden="true" />
      <span className="announce-widget-text">
        <span className="announce-widget-label">ANNOUNCEMENT</span>
        <span className="announce-widget-title" style={{ '--title-color': color, ...titleFontStyle(titleFont) }}>{title}</span>
        {(place || date) && (
          <span className="announce-widget-meta">
            {place && <span className="announce-widget-meta-place">{place}</span>}
            {place && date && <span aria-hidden="true"> · </span>}
            {date && <span className="announce-widget-meta-date">{date}</span>}
          </span>
        )}
      </span>
    </Tag>
  );
});

export default AnnouncementCardFace;
