import React, { useRef } from 'react';
import { createPortal } from 'react-dom';
import ContactsPanel from '../ContactsPanel.jsx';
import ChatThread from '../ChatThread.jsx';
import { useMessagingPanel } from '../../context/ReaderPanelContexts.jsx';
import { useHostRect } from '../../hooks/useHostRect.js';

// Dockview panel: Messaging (friends + groups), without agents — Agent Chat is
// its own independently dockable panel. Preserves the existing "chat overlay
// slides in over the contact list" pattern, just nested inside this panel.
export default function MessagingPanel() {
  const {
    user, friends, groups, currentContact, messages, groupMembers,
    onOpen, onBack, onAddFriend, onRemoveFriend, onReportUser, onBlockUser,
    onCreateGroup, onUpdateGroup, onLeaveGroup,
    loaded, onLoad, sendMessage,
    sessions, activeSessionId, talkingUserId,
    onJoinSession, onLeaveSession, onOpenSessionCreator, onEditSession, onDeleteSession,
    onNavigateVerse,
    videoEnabled, videoTiles, onToggleVideo, bindVideoTile,
  } = useMessagingPanel() || {};

  // createPortal'd to document.body (see useHostRect's own comment) so this
  // full-bleed overlay escapes .dv-groupview's own backdrop-filter, which
  // otherwise suppresses this panel's independent backdrop-filter from
  // blurring the contacts list behind it regardless of blur radius --
  // .chat-overlay shares .notes-filter-panel's exact structural setup
  // (sibling overlay + backdrop-filter nested inside the same
  // backdrop-filtered .dv-groupview ancestor), so it carries the same latent
  // bug even though no user complaint had been raised for it yet
  // (20260826-notes-filter-panel-blur-increase). `position: fixed` + the
  // tracked rect replace the old `position: absolute; inset: 0`, which
  // relied on being a normal descendant of this positioned wrapper.
  const hostRef = useRef(null);
  const rect = useHostRect(!!currentContact, hostRef);

  return (
    <div ref={hostRef} style={{ position: 'relative', height: '100%', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      <ContactsPanel
        user={user} friends={friends || []} groups={groups || {}} currentContact={currentContact}
        onOpen={onOpen}
        onAddFriend={onAddFriend} onRemoveFriend={onRemoveFriend}
        onReportUser={onReportUser} onBlockUser={onBlockUser}
        onCreateGroup={onCreateGroup} onUpdateGroup={onUpdateGroup} onLeaveGroup={onLeaveGroup}
        loaded={loaded} onLoad={onLoad}
        showAgents={false}
      />
      {currentContact && createPortal(
        <div
          className="chat-overlay"
          style={{
            position: 'fixed',
            top: rect?.top ?? 0,
            left: rect?.left ?? 0,
            width: rect?.width ?? '100%',
            height: rect?.height ?? '100%',
            // Now a document.body-level sibling of .reader-dock-container
            // (z-index: 10) and the dock rail (z-index: 15) instead of a
            // local descendant of this panel -- needs to clear both to
            // still visually cover the panel it's portaled out of (see
            // global.css's .chat-overlay comment).
            zIndex: 50,
            visibility: rect ? 'visible' : 'hidden',
          }}
        >
          <ChatThread
            contact={currentContact}
            messages={messages || []}
            groupMembers={groupMembers || []}
            user={user}
            onBack={onBack}
            onSend={sendMessage}
            sessions={sessions || []}
            activeSessionId={activeSessionId}
            talkingUserId={talkingUserId}
            onJoinSession={onJoinSession}
            onLeaveSession={onLeaveSession}
            onOpenSessionCreator={onOpenSessionCreator}
            onEditSession={onEditSession}
            onDeleteSession={onDeleteSession}
            onNavigateVerse={onNavigateVerse}
            videoEnabled={videoEnabled}
            videoTiles={videoTiles}
            onToggleVideo={onToggleVideo}
            bindVideoTile={bindVideoTile}
          />
        </div>,
        document.body,
      )}
    </div>
  );
}
