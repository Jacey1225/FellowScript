import { useState, useRef, useCallback, useEffect } from 'react';
import { message } from 'antd';
import { API, WS_BASE } from '../config.js';

// WS reconnect backoff: 3s -> 30s cap, doubling each failed attempt.
const WS_RECONNECT_MIN_MS = 3000;
const WS_RECONNECT_MAX_MS = 30000;
// After this many consecutive failed attempts, the "reconnecting" indicator
// switches to a firmer "offline" one rather than looking like it's about to succeed.
const WS_OFFLINE_AFTER_ATTEMPTS = 3;

export function useMessaging({ user }) {
  const [friends,        setFriends]        = useState([]);
  const [groups,         setGroups]         = useState({});
  const [currentContact, setCurrentContact] = useState(null);
  const [messages,       setMessages]       = useState([]);
  const [groupMembers,   setGroupMembers]   = useState([]);
  const [wsStatus,       setWsStatus]       = useState('connecting'); // 'connecting' | 'connected' | 'reconnecting' | 'offline'
  const wsRef              = useRef(null);
  const friendCache        = useRef({});
  const sessionSignalCbRef = useRef(null);
  const reconnectAttemptsRef = useRef(0);
  const reconnectTimeoutRef  = useRef(null);

  // ── WebSocket ──────────────────────────────────────────────────────────────

  const connectWS = useCallback(() => {
    if (!user) return;
    clearTimeout(reconnectTimeoutRef.current);
    wsRef.current = new WebSocket(`${WS_BASE}/message/ws/${user.user_id}`);
    const SESSION_TYPES = new Set(['offer', 'answer', 'ice-candidate', 'session-created', 'session-joined', 'session-left', 'talking']);
    wsRef.current.onopen = () => {
      if (reconnectAttemptsRef.current > 0) {
        message.success({ content: 'Reconnected.', key: 'fs-ws-status', duration: 2 });
      }
      reconnectAttemptsRef.current = 0;
      setWsStatus('connected');
    };
    wsRef.current.onmessage = e => {
      try {
        const data = JSON.parse(e.data);
        if (SESSION_TYPES.has(data.type)) {
          sessionSignalCbRef.current?.(data);
          return;
        }
        setCurrentContact(cc => {
          if (cc && data.from_user !== user.user_id &&
              (data.group_id || '') === (cc.group_id || '')) {
            setMessages(prev => [...prev, {
              text: data.text || '',
              mine: false,
              timestamp: data.timestamp,
              sender: data.from_user || '',
            }]);
          }
          return cc;
        });
      } catch (err) {
        console.error('Failed to parse incoming WS message:', err);
      }
    };
    wsRef.current.onerror = (err) => {
      console.error('Messaging WebSocket error:', err);
    };
    wsRef.current.onclose = () => {
      // Reconnect with exponential backoff (3s -> 30s cap) unless this was an
      // intentional disconnect (disconnectWS nulls onclose before closing).
      if (!wsRef.current) return;
      const attempt = reconnectAttemptsRef.current + 1;
      reconnectAttemptsRef.current = attempt;
      const delay = Math.min(WS_RECONNECT_MIN_MS * 2 ** (attempt - 1), WS_RECONNECT_MAX_MS);
      const offline = attempt >= WS_OFFLINE_AFTER_ATTEMPTS;
      setWsStatus(offline ? 'offline' : 'reconnecting');
      message.warning({
        content: offline ? "You're offline. Still trying to reconnect…" : 'Reconnecting…',
        key: 'fs-ws-status',
        duration: 0,
      });
      reconnectTimeoutRef.current = setTimeout(connectWS, delay);
    };
  }, [user]);

  const disconnectWS = useCallback(() => {
    clearTimeout(reconnectTimeoutRef.current);
    reconnectAttemptsRef.current = 0;
    message.destroy('fs-ws-status');
    if (wsRef.current) { wsRef.current.onclose = null; wsRef.current.close(); wsRef.current = null; }
    setWsStatus('connecting');
  }, []);

  const setOnSessionSignal = useCallback((cb) => { sessionSignalCbRef.current = cb; }, []);

  useEffect(() => () => disconnectWS(), [disconnectWS]);

  // ── Contacts ──────────────────────────────────────────────────────────────

  const loadContacts = useCallback(async () => {
    if (!user) return;
    let freshUser = user;
    try {
      const res = await fetch(`${API}/user/${user.user_id}`);
      if (res.ok) freshUser = await res.json();
    } catch (err) {
      console.error('Failed to refresh user before loading contacts:', err);
    }

    // Friends
    const friendIds = freshUser.friends || [];
    const friendList = await Promise.all(friendIds.map(async fid => {
      if (!friendCache.current[fid]) {
        try {
          const r = await fetch(`${API}/user/${fid}`);
          if (r.ok) { const d = await r.json(); friendCache.current[fid] = d.username; }
        } catch (err) {
          console.error(`Failed to load friend ${fid}:`, err);
          friendCache.current[fid] = fid.slice(0, 8);
        }
      }
      const name = friendCache.current[fid] || fid.slice(0, 8);
      let preview = '';
      try {
        const mr = await fetch(`${API}/message/messages/${user.user_id}/?guest_user=${fid}`);
        if (mr.ok) {
          const md  = await mr.json();
          const all = [...(md.payload?.host_msgs || []), ...(md.payload?.other_msgs || [])];
          if (all.length) {
            all.sort((a, b) => (a.timestamp || '') < (b.timestamp || '') ? -1 : 1);
            preview = all[all.length - 1].text || '';
          }
        }
      } catch (err) {
        console.error(`Failed to load message preview for friend ${fid}:`, err);
      }
      return { id: fid, name, type: 'friend', toUsers: [fid], preview };
    }));
    setFriends(friendList);

    // Groups
    const groupIds = Array.isArray(freshUser.groups) ? freshUser.groups : [];
    const groupMap = {};
    const groupList = await Promise.all(groupIds.map(async gid => {
      try {
        const r = await fetch(`${API}/groups/${user.user_id}/${gid}`);
        if (r.ok) {
          const data = await r.json();
          const g = data.group || {};
          groupMap[gid] = { title: g.title || gid, users: g.users || [] };
          const allMsgs = [...(data.host_msgs || []), ...(data.other_msgs || [])];
          let preview = '';
          if (allMsgs.length) {
            allMsgs.sort((a, b) => (a.timestamp || '') < (b.timestamp || '') ? -1 : 1);
            preview = allMsgs[allMsgs.length - 1].text || '';
          }
          return { id: gid, name: g.title || gid, type: 'group', toUsers: g.users || [], preview };
        }
      } catch (err) {
        console.error(`Failed to load group ${gid}:`, err);
      }
      return { id: gid, name: gid.slice(0, 8), type: 'group', toUsers: [], preview: '' };
    }));
    setGroups(groupMap);
    return { friends: friendList, groups: groupList };
  }, [user]);

  // ── Open chat ─────────────────────────────────────────────────────────────

  const openChat = useCallback(async (contact) => {
    setCurrentContact(contact);
    setMessages([]);
    setGroupMembers([]);
    try {
      const res = contact.type === 'friend'
        ? await fetch(`${API}/friends/${user.user_id}/${contact.id}`)
        : await fetch(`${API}/groups/${user.user_id}/${contact.id}`);
      if (res.ok) {
        const data = await res.json();
        if (contact.type === 'group') {
          setGroupMembers(data.members || []);
        }
        const all = [
          ...(data.host_msgs  || []).map(m => ({ ...m, mine: true })),
          ...(data.other_msgs || []).map(m => ({ ...m, mine: false })),
        ].sort((a, b) => (a.timestamp > b.timestamp ? 1 : -1));
        setMessages(all.map(m => ({
          text: m.text, mine: m.mine, timestamp: m.timestamp,
          sender: m.mine ? '' : (m.from_user || ''),
        })));
      }
    } catch (err) {
      console.error('Failed to open chat:', err);
      message.error('Could not load that conversation. Check your connection and try again.');
    }
  }, [user]);

  const closeChat = useCallback(() => {
    setCurrentContact(null);
    setMessages([]);
    setGroupMembers([]);
  }, []);

  // ── Send message ──────────────────────────────────────────────────────────

  const sendMessage = useCallback((text) => {
    if (!user || !currentContact || !wsRef.current || wsRef.current.readyState !== 1) return;
    const payload = {
      from_user: user.user_id,
      timestamp: new Date().toISOString(),
      to_users:  currentContact.toUsers,
      group_id:  currentContact.group_id || '',
      text,
    };
    wsRef.current.send(JSON.stringify(payload));
    setMessages(prev => [...prev, { text, mine: true, timestamp: payload.timestamp, sender: '' }]);
  }, [user, currentContact]);

  // ── Friend actions ────────────────────────────────────────────────────────

  const addFriend = useCallback(async (username) => {
    if (!user || !username) return { ok: false, detail: 'Not signed in.' };
    try {
      const res = await fetch(
        `${API}/friends/${user.user_id}/request?friend_username=${encodeURIComponent(username)}`,
        { method: 'POST' }
      );
      if (res.ok || res.status === 204) return { ok: true };
      let detail = 'Request failed.';
      try { const d = await res.json(); detail = d.detail || detail; } catch (err) {
        console.error('Failed to parse add-friend error response:', err);
      }
      return { ok: false, detail };
    } catch (err) {
      console.error('Failed to send friend request:', err);
      return { ok: false, detail: 'Could not reach the server.' };
    }
  }, [user]);

  const removeFriend = useCallback(async (friendId) => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/friends/${user.user_id}/${encodeURIComponent(friendId)}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) {
        setFriends(prev => prev.filter(f => f.id !== friendId));
        return true;
      }
      message.error('Could not remove that friend. Please try again.');
    } catch (err) {
      console.error('Failed to remove friend:', err);
      message.error('Could not remove that friend. Check your connection and try again.');
    }
    return false;
  }, [user]);

  // ── Guideline 1.2: report & block ────────────────────────────────────────

  const reportUser = useCallback(async (reportedUserId, reason, detail = '') => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/reports/`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content_type: 'user', reported_user_id: reportedUserId, reason, detail }),
      });
      const ok = res.ok || res.status === 201;
      if (!ok) message.error('Could not submit your report. Please try again.');
      return ok;
    } catch (err) {
      console.error('Failed to submit report:', err);
      message.error('Could not submit your report. Check your connection and try again.');
      return false;
    }
  }, [user]);

  const blockUser = useCallback(async (blockedId) => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/blocks/${user.user_id}/${encodeURIComponent(blockedId)}`, { method: 'POST' });
      if (res.ok || res.status === 204) {
        // Instant removal from the feed — don't wait for a refetch: drop the
        // friend row and, if we're mid-conversation with them, close the chat.
        setFriends(prev => prev.filter(f => f.id !== blockedId));
        setCurrentContact(cc => (cc && cc.id === blockedId ? null : cc));
        return true;
      }
    } catch (err) {
      console.error('Failed to block user:', err);
    }
    return false;
  }, [user]);

  // ── Group actions ─────────────────────────────────────────────────────────

  const createGroup = useCallback(async (title, memberIds) => {
    if (!user) return false;
    const groupId = crypto.randomUUID();
    const allUsers = [...new Set([user.user_id, ...memberIds])];
    try {
      const res = await fetch(`${API}/groups/${user.user_id}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ group_id: groupId, title, users: allUsers }),
      });
      const ok = res.ok || res.status === 201;
      if (!ok) message.error('Could not create that group. Please try again.');
      return ok;
    } catch (err) {
      console.error('Failed to create group:', err);
      message.error('Could not create that group. Check your connection and try again.');
      return false;
    }
  }, [user]);

  const updateGroup = useCallback(async (groupId, title, memberIds) => {
    if (!user) return false;
    const allUsers = [...new Set([user.user_id, ...memberIds])];
    try {
      const res = await fetch(`${API}/groups/${user.user_id}/${groupId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ group_id: groupId, title, users: allUsers }),
      });
      if (res.ok || res.status === 204) {
        setGroups(prev => ({ ...prev, [groupId]: { title, users: allUsers } }));
        return true;
      }
      message.error('Could not update that group. Please try again.');
    } catch (err) {
      console.error('Failed to update group:', err);
      message.error('Could not update that group. Check your connection and try again.');
    }
    return false;
  }, [user]);

  const leaveGroup = useCallback(async (groupId) => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/groups/${user.user_id}/${groupId}`, { method: 'DELETE' });
      const ok = res.ok || res.status === 204;
      if (!ok) message.error('Could not leave that group. Please try again.');
      return ok;
    } catch (err) {
      console.error('Failed to leave group:', err);
      message.error('Could not leave that group. Check your connection and try again.');
      return false;
    }
  }, [user]);

  return {
    friends, groups, currentContact, messages, groupMembers, wsStatus,
    wsRef, friendCache,
    connectWS, disconnectWS, setOnSessionSignal,
    loadContacts, openChat, closeChat, sendMessage,
    addFriend, removeFriend, createGroup, updateGroup, leaveGroup,
    reportUser, blockUser,
  };
}
