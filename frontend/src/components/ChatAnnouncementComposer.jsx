import React, { useState } from 'react';
import { createPortal } from 'react-dom';
import { message as antMessage } from 'antd';
import { createAnnouncement } from '../lib/announcementsApi.js';
import { chatPostBody } from '../lib/chatAnnouncements.js';
import GroupAnnouncementForm from './GroupAnnouncementForm.jsx';
import '../styles/chatAnnouncements.css';

// Task 20261030-chat-announcements: composer entry point. The "Announcement"
// item in the "+" attach menu opens the existing GroupAnnouncementForm in a
// dialog; submit creates the announcement with post_to_chat so it also lands in
// the timeline. Content, scheduling, banner, polls, RSVP and the free-plan
// limit behave exactly as in the Announcements list. A failed post keeps the
// form (and its content) open with the error; nothing is added to the chat
// locally, the line arrives from the server.
export default function ChatAnnouncementComposer({ userId, groupId, onClose }) {
  const [gateHit, setGateHit] = useState(false);
  const [gate, setGate] = useState(null);

  const submit = async (body) => {
    try {
      await createAnnouncement(userId, groupId, chatPostBody(body));
    } catch (err) {
      if (err.status === 403 && err.gate) { setGate(err.gate); setGateHit(true); }
      throw err;
    }
    antMessage.success(body.publish_at ? 'Announcement scheduled.' : 'Announcement posted.');
    onClose();
  };

  return createPortal(
    <div className="group-info-scrim announce-widget-modal" role="dialog" aria-modal="true" aria-label="New announcement">
      <div className="announce-widget-modal-body chat-announcement-dialog">
        <GroupAnnouncementForm
          userId={userId} groupId={groupId} item={null} gate={gate} gateHit={gateHit}
          upgrade={(
            <div className="group-info-announcements-gate" role="region" aria-label="Announcement limit reached">
              <strong>You've used this week's announcement</strong>
              <p className="group-info-helper">
                Free plans can post {gate?.limit ?? 1} announcement every 7 days. Upgrade for unlimited announcements.
              </p>
            </div>
          )}
          onSubmit={submit}
          onCancel={onClose}
        />
      </div>
    </div>,
    document.body,
  );
}
