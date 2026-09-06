import { useState, useRef, useCallback, useEffect } from 'react';
import { message } from 'antd';
import { API, WS_BASE } from '../config.js';
import { compareTimestamps } from '../utils.js';

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
  // H13 (compliance sweep) -- client-side dedup for loadContacts' N+1
  // fetch-per-friend/per-group pattern. friendCache above already skips
  // re-fetching a friend's *username* once known; friendEntryCache goes
  // further and caches the whole per-friend list row (name + last-message
  // preview), and groupEntryCache does the same for groups (metadata +
  // preview). Both are keyed by id and only ever populated, never
  // refreshed, until explicitly invalidated by removeFriend/blockUser
  // (friend) or updateGroup/leaveGroup (group) below -- so a repeat
  // loadContacts() call (e.g. ContactsPanel/MessagingSidebar calling
  // onLoad() again right after addFriend/createGroup succeeds) reuses
  // every already-known friend/group's row instead of re-fetching its
  // username, group record, and message history all over again just to
  // pick up the one new entry. A cached preview can go briefly stale
  // between such reloads -- an accepted tradeoff for this frontend-only
  // fix; a real batched endpoint (the sweep's own recommended full fix)
  // is out of scope here, see intake-spec.md's Open Questions.
  const friendEntryCache   = useRef({});
  const groupEntryCache    = useRef({});
  // Task 20260905-profile-photo: friendCache above is shared/keyed to a bare
  // username string elsewhere (mirrors messaging.js's legacy equivalent), so
  // a photo URL rides alongside it in its own cache rather than changing
  // friendCache's shape. memberCache is the same idea for resolved group
  // members ({ username, photoUrl } per user_id) -- GroupsManager.fetch_group
  // only ever returns a bare username list (no ids, no photos), so each
  // member is instead resolved from the group's own `toUsers` id list via
  // the same GET /user/{id} endpoint friend resolution already uses.
  const friendPhotoCache   = useRef({});
  const memberCache        = useRef({});
  const sessionSignalCbRef = useRef(null);
  const reconnectAttemptsRef = useRef(0);
  const reconnectTimeoutRef  = useRef(null);
  // Mirrors of currentContact so the WS onmessage handler below can read the
  // latest value without calling setCurrentContact's own updater just to
  // read it (see that handler's comment for why).
  const currentContactRef = useRef(currentContact);
  useEffect(() => { currentContactRef.current = currentContact; }, [currentContact]);

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
        // The setMessages side effect below used to live inside this
        // setCurrentContact updater -- calling another component's setState
        // from inside a different setter's updater function is impure, and
        // React 18 StrictMode's intentional double-invocation of updater
        // functions in development could fire that side effect twice,
        // duplicating the incoming chat bubble. Read currentContact from a
        // ref instead of via setCurrentContact, and never write
        // currentContact here at all (this handler never needs to change
        // it) -- setMessages runs exactly once per incoming message.
        const cc = currentContactRef.current;
        if (cc && data.from_user !== user.user_id &&
            (data.group_id || '') === (cc.group_id || '')) {
          setMessages(prev => [...prev, {
            text: data.text || '',
            mine: false,
            timestamp: data.timestamp,
            sender: data.from_user || '',
            // Task 20260904-messaging-attachments: null/absent for an
            // ordinary text-only message. attachment_url (image/video/file
            // only) is a freshly presigned GET the server resolves at
            // delivery time -- never a durable/storable URL. A "gif"
            // instead carries its playable URL in attachment_meta.url.
            attachmentKind: data.attachment_kind || null,
            attachmentMeta: data.attachment_meta || null,
            attachmentUrl:  data.attachment_url || null,
          }]);
        }
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
      // Already-known friend row (name + preview) -- see friendEntryCache's
      // doc comment above. Skips the /user/{fid} and /message/messages/{fid}
      // fetches entirely for a friend loadContacts already resolved before.
      if (friendEntryCache.current[fid]) return friendEntryCache.current[fid];

      if (!friendCache.current[fid]) {
        try {
          const r = await fetch(`${API}/user/${fid}`);
          if (r.ok) {
            const d = await r.json();
            friendCache.current[fid] = d.username;
            friendPhotoCache.current[fid] = d.profile_photo_url || null;
          }
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
            all.sort(compareTimestamps);
            preview = all[all.length - 1].text || '';
          }
        }
      } catch (err) {
        console.error(`Failed to load message preview for friend ${fid}:`, err);
      }
      const entry = { id: fid, name, type: 'friend', toUsers: [fid], preview, photoUrl: friendPhotoCache.current[fid] || null };
      friendEntryCache.current[fid] = entry;
      return entry;
    }));
    setFriends(friendList);

    // Groups
    const groupIds = Array.isArray(freshUser.groups) ? freshUser.groups : [];
    const groupMap = {};
    const groupList = await Promise.all(groupIds.map(async gid => {
      // Already-known group (metadata + preview) -- see groupEntryCache's
      // doc comment above. Skips the /groups/{gid} re-fetch entirely for a
      // group loadContacts already resolved before.
      const cached = groupEntryCache.current[gid];
      if (cached) { groupMap[gid] = cached.meta; return cached.entry; }

      try {
        const r = await fetch(`${API}/groups/${user.user_id}/${gid}`);
        if (r.ok) {
          const data = await r.json();
          const g = data.group || {};
          const meta = { title: g.title || gid, users: g.users || [] };
          groupMap[gid] = meta;
          const allMsgs = [...(data.host_msgs || []), ...(data.other_msgs || [])];
          let preview = '';
          if (allMsgs.length) {
            allMsgs.sort(compareTimestamps);
            preview = allMsgs[allMsgs.length - 1].text || '';
          }
          const entry = { id: gid, name: g.title || gid, type: 'group', toUsers: g.users || [], preview };
          groupEntryCache.current[gid] = { meta, entry };
          return entry;
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
          // fetch_group's own `data.members` is a bare list of usernames
          // (no ids, no photos) -- resolve the richer { user_id, username,
          // photoUrl } shape ChatThread.jsx/MessagingSidebar.jsx's Members
          // panel already expects from `contact.toUsers` (the group's full
          // member-id list, self included) instead, via the same GET
          // /user/{id} endpoint friend resolution uses. Cached per id so a
          // reopened group doesn't re-fetch members already resolved.
          const memberIds = (contact.toUsers || []).filter(uid => uid !== user.user_id);
          const resolvedMembers = await Promise.all(memberIds.map(async uid => {
            if (memberCache.current[uid]) return { user_id: uid, ...memberCache.current[uid] };
            try {
              const r = await fetch(`${API}/user/${uid}`);
              if (r.ok) {
                const d = await r.json();
                const resolved = { username: d.username || uid.slice(0, 8), photoUrl: d.profile_photo_url || null };
                memberCache.current[uid] = resolved;
                return { user_id: uid, ...resolved };
              }
            } catch (err) {
              console.error(`Failed to resolve group member ${uid}:`, err);
            }
            return { user_id: uid, username: uid.slice(0, 8), photoUrl: null };
          }));
          setGroupMembers(resolvedMembers);
        }
        const all = [
          ...(data.host_msgs  || []).map(m => ({ ...m, mine: true })),
          ...(data.other_msgs || []).map(m => ({ ...m, mine: false })),
        ].sort(compareTimestamps);
        setMessages(all.map(m => ({
          text: m.text, mine: m.mine, timestamp: m.timestamp,
          sender: m.mine ? '' : (m.from_user || ''),
          // Task 20260904-messaging-attachments — see this file's WS
          // onmessage handler above for the field-shape rationale. Note:
          // never read `m.attachment_key` here even if a raw backend
          // response happens to include it (group-message history rows) —
          // the client only ever renders from `attachment_url`/
          // `attachment_meta`, matching the DM path's contract exactly.
          attachmentKind: m.attachment_kind || null,
          attachmentMeta: m.attachment_meta || null,
          attachmentUrl:  m.attachment_url || null,
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
  // `attachment`, when present, is `{ kind, meta, objectKey }` — `kind` is one
  // of "image"/"video"/"file"/"gif" (design gate §1 wire contract), `meta` is
  // the free-form `attachment_meta` dict to send (filename for file; url/
  // preview_url/width/height for gif; width/height for image/video), and
  // `objectKey` is the S3 object key from a completed upload (image/video/
  // file only — always absent for gif, which never uploads bytes of ours).
  const sendMessage = useCallback((text, attachment = null) => {
    if (!user || !currentContact || !wsRef.current || wsRef.current.readyState !== 1) return;
    const payload = {
      from_user: user.user_id,
      timestamp: new Date().toISOString(),
      to_users:  currentContact.toUsers,
      group_id:  currentContact.group_id || '',
      text,
    };
    if (attachment) {
      payload.attachment_kind = attachment.kind;
      payload.attachment_meta = attachment.meta || {};
      if (attachment.objectKey) payload.attachment_key = attachment.objectKey;
    }
    wsRef.current.send(JSON.stringify(payload));
    setMessages(prev => [...prev, {
      text, mine: true, timestamp: payload.timestamp, sender: '',
      attachmentKind: attachment ? attachment.kind : null,
      attachmentMeta: attachment ? (attachment.meta || null) : null,
      // No attachmentUrl on the optimistic echo for image/video/file — the
      // composer keeps the local object URL alive for its own preview
      // (ChatThread.jsx's stagedPreviewUrl) separately from this history
      // entry; a gif renders correctly from attachmentMeta.url alone, same
      // as a real delivered/loaded message (design gate §4).
      attachmentUrl: (attachment && attachment.kind === 'gif') ? null : (attachment?.localUrl || null),
    }]);
  }, [user, currentContact]);

  // ── Attachments (task 20260904-messaging-attachments) ─────────────────────
  // Wire contract per design-notes.md / backend step 2: request a presigned
  // S3 POST policy over plain HTTP, then upload the raw bytes directly to S3
  // with it — this server never receives the file itself. GIF search is a
  // thin authenticated proxy so the provider API key never reaches this
  // client.

  const requestUploadUrl = useCallback(async (attachmentKind, contentType, sizeBytes) => {
    if (!user) throw new Error('Not signed in.');
    const res = await fetch(`${API}/message/upload-url/${user.user_id}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ attachment_kind: attachmentKind, content_type: contentType, size_bytes: sizeBytes }),
    });
    if (!res.ok) {
      let detail = "That file type isn't supported here.";
      try { const d = await res.json(); detail = d.detail || detail; } catch (err) {
        console.error('Failed to parse upload-url error response:', err);
      }
      throw new Error(detail);
    }
    return res.json(); // { url, fields, object_key, expires_in }
  }, [user]);

  /// Uploads raw bytes directly to S3 using the presigned POST policy from
  /// `requestUploadUrl` — a multipart/form-data POST straight to
  /// `uploadInfo.url` (not this app's own API). `uploadInfo.fields` must ride
  /// ahead of the file part (S3's presigned-POST contract).
  const uploadToS3 = useCallback(async (uploadInfo, file) => {
    const form = new FormData();
    Object.entries(uploadInfo.fields || {}).forEach(([key, value]) => form.append(key, value));
    form.append('file', file);
    const res = await fetch(uploadInfo.url, { method: 'POST', body: form });
    if (!res.ok && res.status !== 204) {
      throw new Error('Upload failed. Please try again.');
    }
  }, []);

  const searchGifs = useCallback(async (query) => {
    const trimmed = (query || '').trim();
    if (!trimmed) return [];
    const res = await fetch(`${API}/message/gif-search?q=${encodeURIComponent(trimmed)}`);
    if (!res.ok) throw new Error("Couldn't load GIFs right now — try again in a moment.");
    const data = await res.json();
    return data.results || [];
  }, []);

  // Task 20260905-gif-picker-default-browse: default/trending browse page,
  // shown before any query is typed. Same authenticated proxy endpoint as
  // searchGifs (omitting `q` switches the route to browse mode server-side),
  // paginated via an opaque `next_page_token` the caller passes back
  // unmodified — never parsed/branched-on client-side (design gate §7).
  const browseGifs = useCallback(async (pageToken) => {
    const qs = pageToken ? `?page_token=${encodeURIComponent(pageToken)}` : '';
    const res = await fetch(`${API}/message/gif-search${qs}`);
    if (!res.ok) throw new Error("Couldn't load GIFs right now — try again in a moment.");
    const data = await res.json();
    return {
      results: data.results || [],
      nextPageToken: data.next_page_token ?? null,
      hasMore: !!data.has_more,
    };
  }, []);

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
        // Invalidate this friend's cached row so a later re-add doesn't
        // resurface a stale name/preview from before the removal.
        delete friendEntryCache.current[friendId];
        delete friendCache.current[friendId];
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
        // Same cache invalidation as removeFriend above.
        delete friendEntryCache.current[blockedId];
        delete friendCache.current[blockedId];
        return true;
      }
      // Was the one action in this file with no user-facing failure
      // feedback — bring it in line with reportUser/removeFriend above.
      message.error('Could not block that user. Please try again.');
    } catch (err) {
      console.error('Failed to block user:', err);
      message.error('Could not block that user. Check your connection and try again.');
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
        // Invalidate the cached row so the next loadContacts() call (already
        // triggered right after this by MessagingSidebar/ContactsPanel)
        // re-fetches this group's now-changed title/members instead of
        // reusing the pre-update cached entry.
        delete groupEntryCache.current[groupId];
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
      if (ok) delete groupEntryCache.current[groupId];
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
    requestUploadUrl, uploadToS3, searchGifs, browseGifs,
  };
}
