import { useState, useRef, useCallback, useEffect } from 'react';
import { API, WS_BASE } from '../config.js';

export function useMessaging({ user }) {
  const [friends,        setFriends]        = useState([]);
  const [groups,         setGroups]         = useState({});
  const [currentContact, setCurrentContact] = useState(null);
  const [messages,       setMessages]       = useState([]);
  const [groupMembers,   setGroupMembers]   = useState([]);
  const wsRef       = useRef(null);
  const friendCache = useRef({});

  // ── WebSocket ──────────────────────────────────────────────────────────────

  const connectWS = useCallback(() => {
    if (!user) return;
    wsRef.current = new WebSocket(`${WS_BASE}/message/ws/${user.user_id}`);
    wsRef.current.onmessage = e => {
      try {
        const data = JSON.parse(e.data);
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
      } catch {}
    };
    wsRef.current.onclose = () => {
      // reconnect if still open
      if (wsRef.current) setTimeout(connectWS, 3000);
    };
  }, [user]);

  const disconnectWS = useCallback(() => {
    if (wsRef.current) { wsRef.current.onclose = null; wsRef.current.close(); wsRef.current = null; }
  }, []);

  useEffect(() => () => disconnectWS(), [disconnectWS]);

  // ── Contacts ──────────────────────────────────────────────────────────────

  const loadContacts = useCallback(async () => {
    if (!user) return;
    let freshUser = user;
    try {
      const res = await fetch(`${API}/user/${user.user_id}`);
      if (res.ok) freshUser = await res.json();
    } catch {}

    // Friends
    const friendIds = freshUser.friends || [];
    const friendList = await Promise.all(friendIds.map(async fid => {
      if (!friendCache.current[fid]) {
        try {
          const r = await fetch(`${API}/user/${fid}`);
          if (r.ok) { const d = await r.json(); friendCache.current[fid] = d.username; }
        } catch { friendCache.current[fid] = fid.slice(0, 8); }
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
      } catch {}
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
      } catch {}
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
    } catch {}
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
    if (!user || !username) return false;
    try {
      const res = await fetch(
        `${API}/friends/${user.user_id}/request?friend_username=${encodeURIComponent(username)}`,
        { method: 'POST' }
      );
      return res.ok || res.status === 204;
    } catch { return false; }
  }, [user]);

  const removeFriend = useCallback(async (friendId) => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/friends/${user.user_id}/${encodeURIComponent(friendId)}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) {
        setFriends(prev => prev.filter(f => f.id !== friendId));
        return true;
      }
    } catch {}
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
      return res.ok || res.status === 201;
    } catch { return false; }
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
    } catch {}
    return false;
  }, [user]);

  const leaveGroup = useCallback(async (groupId) => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/groups/${user.user_id}/${groupId}`, { method: 'DELETE' });
      return res.ok || res.status === 204;
    } catch { return false; }
  }, [user]);

  return {
    friends, groups, currentContact, messages, groupMembers,
    wsRef, friendCache,
    connectWS, disconnectWS,
    loadContacts, openChat, closeChat, sendMessage,
    addFriend, removeFriend, createGroup, updateGroup, leaveGroup,
  };
}
