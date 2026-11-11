// "Send in chat" flow (tasks 20261012-share-verses-notes-in-chat and
// 20261030-thread-share-notes-verses). The picker opens the chosen chat (and
// thread, when one was picked), then sends exactly once after its history has
// loaded. Moved out of Reader.jsx; behaviour for chat targets is unchanged.
import { useCallback, useEffect, useRef, useState } from 'react';
import { message } from 'antd';
import { pendingShareStatus } from '../lib/threadShare.js';

export function useChatShare({
  shareReq, setShareReq, onOpenChat, onShowMessaging, currentContact, sendMessage,
  openThread, threadView, threadLoad, sendThreadMessage,
}) {
  const [tick, setTick] = useState(0);
  const pendingRef = useRef(null);

  const performShare = useCallback(async (contact, thread = null) => {
    if (!shareReq) return;
    pendingRef.current = { contactId: contact.id, attachment: shareReq.attachment, thread, opened: false };
    setShareReq(null);
    onShowMessaging();
    await onOpenChat(contact);
    if (pendingRef.current) {
      pendingRef.current.opened = true;
      if (thread) openThread(thread);
    }
    setTick(t => t + 1);
  }, [shareReq, setShareReq, onOpenChat, onShowMessaging, openThread]);

  useEffect(() => {
    const p = pendingRef.current;
    const status = pendingShareStatus(p, { contact: currentContact, threadView, threadLoad });
    if (status === 'wait') return;
    pendingRef.current = null;
    if (status === 'drop') {
      message.error("Couldn't open that thread, so nothing was sent.");
    } else if (p.thread) {
      if (sendThreadMessage('', p.attachment) === false) message.error("Couldn't send that. Check your connection and try again.");
    } else {
      sendMessage('', p.attachment);
    }
  }, [tick, currentContact, threadView, threadLoad, sendMessage, sendThreadMessage]);

  return performShare;
}
