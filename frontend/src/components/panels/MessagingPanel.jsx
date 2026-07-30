import React from 'react';
import ContactsPanel from '../ContactsPanel.jsx';
import ChatThread from '../ChatThread.jsx';
import { useMessagingPanel } from '../../context/ReaderPanelContexts.jsx';

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

  return (
    <div style={{ position: 'relative', height: '100%', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      <ContactsPanel
        user={user} friends={friends || []} groups={groups || {}} currentContact={currentContact}
        onOpen={onOpen}
        onAddFriend={onAddFriend} onRemoveFriend={onRemoveFriend}
        onReportUser={onReportUser} onBlockUser={onBlockUser}
        onCreateGroup={onCreateGroup} onUpdateGroup={onUpdateGroup} onLeaveGroup={onLeaveGroup}
        loaded={loaded} onLoad={onLoad}
        showAgents={false}
      />
      {currentContact && (
        <div className="chat-overlay">
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
        </div>
      )}
    </div>
  );
}
