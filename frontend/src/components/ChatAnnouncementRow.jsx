import React, { useState } from 'react';
import { createPortal } from 'react-dom';
import { fetchAnnouncement, rsvpJoin, rsvpLeave, pollVote, pollRetract } from '../lib/announcementsApi.js';
import { openErrorMessage } from '../lib/chatAnnouncements.js';
import GroupAnnouncementViewer from './GroupAnnouncementViewer.jsx';
import AnnouncementCardFace, { formatShortDate } from './AnnouncementCardFace.jsx';
import '../styles/chatAnnouncements.css';

// Task 20261030-chat-announcements: the in-timeline row for an announcement a
// member posted into the group chat. Renders the SAME banner card face as the
// header widget (no second visual) with the poster and an "edited" marker.
// Opening fetches the full announcement and shows the existing read-only
// viewer (RSVP and polls work as in the widget); a failed fetch shows a warm
// error and nothing is built from the line's card. The row is only rendered by
// ChatThread while the chat_announcements capability is on.
export default function ChatAnnouncementRow({ message, userId, groupId }) {
  const card = message.announcement;
  const [full, setFull] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [bannerFailed, setBannerFailed] = useState(false);
  const who = message.mine ? 'You' : (card.creator_username || message.sender || 'A member');
  const meta = `Posted by ${who}${card.edited ? ' · edited' : ''}`;

  const open = async () => {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const item = await fetchAnnouncement(userId, groupId, card.id);
      setFull({ ...item, can_edit: false }); // edit/delete stay in the group info panel
    } catch (err) {
      setError(openErrorMessage(err));
    } finally {
      setBusy(false);
    }
  };
  const merge = (updated) => { const next = { ...full, ...updated, can_edit: false }; setFull(next); return next; };
  const rsvp = async (join) => merge(await (join ? rsvpJoin : rsvpLeave)(userId, groupId, full.id));
  const pollActions = {
    vote: async (ids) => merge(await pollVote(userId, groupId, full.id, ids)),
    retract: async () => merge(await pollRetract(userId, groupId, full.id)),
  };

  return (
    <div className="chat-announcement-row" data-msg-id={message.key ?? undefined}>
      <div className="chat-announcement-card">
        <AnnouncementCardFace as="button" type="button"
          title={card.title} titleColor={card.title_color} titleFont={card.title_font} bgTheme={card.bg_theme}
          bannerUrl={card.banner_url && !bannerFailed ? card.banner_url : null} location={card.location}
          date={formatShortDate(card.publish_at)} onImgError={() => setBannerFailed(true)}
          aria-label={`Announcement: ${card.title}. ${meta}. Open`} aria-busy={busy}
          onClick={open} />
      </div>
      <span className="chat-announcement-meta">{meta}</span>
      {error && <span className="chat-announcement-error" role="alert">{error}</span>}
      {full && createPortal(
        <div className="group-info-scrim announce-widget-modal" role="dialog" aria-modal="true" aria-label="Announcement"
          onClick={(e) => { if (e.target === e.currentTarget) setFull(null); }}>
          <div className="announce-widget-modal-body">
            <GroupAnnouncementViewer item={full} onBack={() => setFull(null)} onRsvp={rsvp} onPoll={pollActions} />
          </div>
        </div>,
        document.body,
      )}
    </div>
  );
}
