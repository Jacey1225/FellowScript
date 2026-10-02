import { useState, useRef, useCallback, useEffect } from 'react';
import { message } from 'antd';
import { API, WS_BASE } from '../config.js';
import { compareTimestamps, threadFrameToRow } from '../utils.js';
import { useCapabilities } from './useCapabilities.js';
import {
  INITIAL_PAGE_LIMIT, OLDER_PAGE_LIMIT, ACK_FALLBACK_MS,
  newClientRef, parsePage, pageQuery,
  mergeOlder, mergeLive, reconcileAck, findLostAckMatch,
} from '../lib/chatPaging.js';
import {
  createThread, deleteGroupMessage, restoreGroupMessage, fetchThreadMessagesUrl,
  insertRestored, DEFAULT_UNDO_SECONDS,
} from '../lib/threadsApi.js';

// WS reconnect backoff: 3s -> 30s cap, doubling each failed attempt.
const WS_RECONNECT_MIN_MS = 3000;
const WS_RECONNECT_MAX_MS = 30000;
// After this many consecutive failed attempts, the "reconnecting" indicator
// switches to a firmer "offline" one rather than looking like it's about to succeed.
const WS_OFFLINE_AFTER_ATTEMPTS = 3;

// Task 20261001-chat-pagination: state of the open thread's older-page loader.
const PAGING_IDLE = { paged: false, hasMore: false, loading: false, error: false, loadedCount: 0, loadedTick: 0 };

export function useMessaging({ user }) {
  const [friends,        setFriends]        = useState([]);
  const [groups,         setGroups]         = useState({});
  const [currentContact, setCurrentContact] = useState(null);
  const [messages,       setMessages]       = useState([]);
  const [groupMembers,   setGroupMembers]   = useState([]);
  const [wsStatus,       setWsStatus]       = useState('connecting'); // 'connecting' | 'connected' | 'reconnecting' | 'offline'
  const [olderPage,      setOlderPage]      = useState(PAGING_IDLE);
  // Task 20261001-message-threads. One open thread at a time, one level deep:
  // threadView = { thread } while a thread is open over the group chat.
  const [threadView,     setThreadView]     = useState(null);
  const [threadMessages, setThreadMessages] = useState([]);
  const [threadPage,     setThreadPage]     = useState(PAGING_IDLE);
  const [threadLoad,     setThreadLoad]     = useState('idle'); // 'idle' | 'loading' | 'error'
  // A thread send that failed hands its text back so the composer can refill.
  const [restoredDraft,  setRestoredDraft]  = useState(null);
  // Task 20261001-chat-pagination. Server-gated feature flags come from the
  // SF capabilities client; a missing/false capability (or no provider) means
  // the legacy full-history fetch. Read through a ref so callbacks stay stable.
  const caps = useCapabilities();
  const capsRef = useRef(caps);
  capsRef.current = caps;
  const isPagedFor = (type) => capsRef.current?.isEnabled?.(type === 'group' ? 'chat_pagination' : 'chat_pagination_dm') === true;
  // Per-open-thread paging state. `token` changes on every openChat/closeChat
  // so a late response for a previous thread is dropped.
  const chatTokenRef = useRef(0);
  const pageRef = useRef({ cursor: null, hasMore: false, loading: false, paged: false });
  const ackTimersRef = useRef(new Map());
  const threadViewRef = useRef(null);
  const threadTokenRef = useRef(0);
  const threadPageRef = useRef({ cursor: null, hasMore: false, loading: false });
  const threadMessagesRef = useRef([]);
  const deletedRowsRef = useRef(new Map());
  const threadFrameCbRef = useRef(null);
  useEffect(() => { threadViewRef.current = threadView; }, [threadView]);
  useEffect(() => { threadMessagesRef.current = threadMessages; }, [threadMessages]);
  const messagesRef = useRef([]);
  useEffect(() => { messagesRef.current = messages; }, [messages]);
  const clearAckTimers = useCallback(() => {
    ackTimersRef.current.forEach(t => clearTimeout(t));
    ackTimersRef.current.clear();
  }, []);
  useEffect(() => clearAckTimers, [clearAckTimers]);
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
        // Task 20260923-chat-phantom-empty-bubbles: explicitly discriminate
        // a control frame's `type` instead of the old catch-all fallthrough
        // -- any frame whose `type` wasn't a session type used to be treated
        // as an ordinary chat message with zero shape validation, so a
        // backend `{"type":"ping"}` heartbeat (ConnectionManager.
        // HEARTBEAT_INTERVAL, every 25s) or `{"type":"error",...}` frame
        // (send_msg's content-rejection/save-failure paths) got appended as
        // a contentless bubble whenever the open thread was a DM (both
        // group_id fall back to '' and trivially match). Mirrors the fix
        // already shipped for iOS under task
        // 20260910-chat-message-disappear-reentry (ChatThreadView.swift's
        // receiveLoop() explicit switch on json["type"]).
        if (data.type === 'ping') {
          return; // heartbeat -- no-op, never a chat message
        }
        // Task 20261001-chat-pagination: sender-only ack of a message sent
        // with a client_ref. Reconciles the optimistic bubble in place; never
        // rendered as a bubble itself. An `error` frame (no client_ref) is
        // never treated as an ack.
        if (data.type === 'ack') {
          if (typeof data.client_ref === 'string' && data.client_ref && typeof data.id === 'string' && data.id) {
            const t = ackTimersRef.current.get(data.client_ref);
            if (t) { clearTimeout(t); ackTimersRef.current.delete(data.client_ref); }
            // A thread send's ack carries thread_id: reconcile only the list
            // that holds the optimistic bubble.
            if (typeof data.thread_id === 'string' && data.thread_id) {
              setThreadMessages(prev => reconcileAck(prev, data));
            } else {
              setMessages(prev => reconcileAck(prev, data));
            }
          }
          return;
        }
        // Task 20261001-message-threads: thread / delete frames go through a
        // callback ref (same style as sessionSignalCbRef); never a second
        // WebSocket. Not chat bubbles in their own right.
        if (data.type === 'thread_message' || data.type === 'message_deleted' || data.type === 'message_restored') {
          threadFrameCbRef.current?.(data);
          return;
        }
        if (data.type === 'error') {
          // A rejected/failed send (content-filter rejection, blocked
          // relationship, or a save failure -- websockets.py's send_msg).
          // Never append this as a chat bubble. Per Q17 (empty/loading/
          // error states stay minimal/unfussy, and the sub-question of an
          // inline retry affordance is explicitly left open/undecided --
          // see intake-spec.md's Open Questions), this stops at a
          // lightweight, self-dismissing toast rather than any persistent
          // bubble/retry UI -- reusing `message.error`, which this hook
          // already calls for the same class of failure elsewhere (e.g.
          // openChat, removeFriend) -- plus a console log for diagnosis, so
          // the failure isn't silently swallowed.
          console.error('WS error frame:', data.reason || 'unknown', data.detail || '');
          if (data.reason === 'terms_reaccept_required') {
            // Present the Updated Terms gate (capabilities refresh flips
            // termsCurrent), keep what the user typed.
            capsRef.current?.refresh?.();
          }
          threadFrameCbRef.current?.({ type: 'thread_send_failed', reason: data.reason });
          message.error({
            content: data.reason === 'terms_reaccept_required'
              ? 'Please review and accept the updated Terms to continue.'
              : (data.detail || "Couldn't send that message. Please try again."),
            key: 'fs-ws-send-error',
            duration: 4,
          });
          return;
        }
        // Anything else falls through to the ordinary-chat-message path
        // below, but only if it actually carries chat-message shape
        // (`from_user`/`text`/`timestamp`) -- a real inbound delivery frame
        // carries no `type` key at all, so this also fails safe against any
        // future unrecognized control frame instead of rendering it as a
        // blank bubble.
        if (typeof data.from_user !== 'string' || !data.from_user ||
            typeof data.text !== 'string' ||
            data.timestamp === undefined || data.timestamp === null) {
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
          setMessages(prev => mergeLive(prev, {
            // Message id (new servers); absent on an old server's frame.
            ...(typeof data.id === 'string' && data.id ? { id: data.id, key: data.id } : {}),
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
          }));
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
        // Task 20261001-chat-pagination: limit=1 preview when the DM flag is
        // on; a response with no `page` block is the legacy full history.
        const previewLimit = isPagedFor('friend') ? '&limit=1' : '';
        const mr = await fetch(`${API}/message/messages/${user.user_id}/?guest_user=${fid}${previewLimit}`);
        if (mr.ok) {
          const md  = await mr.json();
          const pg  = parsePage(md.payload);
          if (pg) {
            preview = pg.messages.length ? (pg.messages[pg.messages.length - 1].text || '') : '';
          } else {
            const all = [...(md.payload?.host_msgs || []), ...(md.payload?.other_msgs || [])];
            if (all.length) {
              all.sort(compareTimestamps);
              preview = all[all.length - 1].text || '';
            }
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
        const r = await fetch(`${API}/groups/${user.user_id}/${gid}${isPagedFor('group') ? '?limit=1' : ''}`);
        if (r.ok) {
          const data = await r.json();
          const g = data.group || {};
          const meta = { title: g.title || gid, users: g.users || [], photoUrl: g.photo_url || null };
          groupMap[gid] = meta;
          const pg = parsePage(data);
          const allMsgs = pg ? pg.messages : [...(data.host_msgs || []), ...(data.other_msgs || [])];
          let preview = '';
          if (allMsgs.length) {
            if (!pg) allMsgs.sort(compareTimestamps);
            preview = allMsgs[allMsgs.length - 1].text || '';
          }
          const entry = { id: gid, name: g.title || gid, type: 'group', toUsers: g.users || [], preview, photoUrl: g.photo_url || null };
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

  // ── Threads (task 20261001-message-threads) ────────────────────────────────

  const resetThread = useCallback(() => {
    threadTokenRef.current += 1;
    threadPageRef.current = { cursor: null, hasMore: false, loading: false };
    threadViewRef.current = null;
    setThreadView(null);
    setThreadMessages([]);
    setThreadPage(PAGING_IDLE);
    setThreadLoad('idle');
    setRestoredDraft(null);
  }, []);

  const groupIdOfContact = (cc) => (cc && cc.type === 'group') ? (cc.group_id || cc.id) : null;

  const fetchThreadFirstPage = useCallback(async (thread, token) => {
    const gid = groupIdOfContact(currentContactRef.current);
    if (!user || !gid) return;
    setThreadLoad('loading');
    try {
      const res = await fetch(fetchThreadMessagesUrl(user.user_id, gid, thread.id, INITIAL_PAGE_LIMIT, null));
      if (token !== threadTokenRef.current) return;
      if (res.status === 404) {
        message.info("That thread isn't available anymore.");
        resetThread();
        return;
      }
      if (!res.ok) throw new Error(`thread page HTTP ${res.status}`);
      const pg = parsePage(await res.json());
      if (token !== threadTokenRef.current) return;
      if (!pg) throw new Error('thread page response had no page block');
      threadPageRef.current = { cursor: pg.cursor, hasMore: pg.hasMore, loading: false };
      setThreadPage({ ...PAGING_IDLE, paged: true, hasMore: pg.hasMore });
      setThreadMessages(pg.messages);
      setThreadLoad('idle');
    } catch (err) {
      if (token !== threadTokenRef.current) return;
      console.error('Failed to open thread:', err);
      setThreadLoad('error');
    }
  }, [user, resetThread]);

  const openThread = useCallback((thread) => {
    if (!thread || typeof thread.id !== 'string') return;
    const token = ++threadTokenRef.current;
    threadPageRef.current = { cursor: null, hasMore: false, loading: false };
    threadViewRef.current = { thread };
    setThreadView({ thread });
    setThreadMessages([]);
    setThreadPage(PAGING_IDLE);
    setRestoredDraft(null);
    fetchThreadFirstPage(thread, token);
  }, [fetchThreadFirstPage]);

  const retryThread = useCallback(() => {
    const tv = threadViewRef.current;
    if (tv) fetchThreadFirstPage(tv.thread, threadTokenRef.current);
  }, [fetchThreadFirstPage]);

  const closeThread = useCallback(() => { resetThread(); }, [resetThread]);

  const loadOlderThread = useCallback(async () => {
    const tv = threadViewRef.current;
    const gid = groupIdOfContact(currentContactRef.current);
    const st = threadPageRef.current;
    if (!user || !tv || !gid || !st.hasMore || !st.cursor || st.loading) return;
    const token = threadTokenRef.current;
    st.loading = true;
    setThreadPage(p => ({ ...p, loading: true, error: false }));
    try {
      const res = await fetch(fetchThreadMessagesUrl(user.user_id, gid, tv.thread.id, OLDER_PAGE_LIMIT, st.cursor));
      if (token !== threadTokenRef.current) return;
      if (!res.ok) throw new Error(`older thread page HTTP ${res.status}`);
      const pg = parsePage(await res.json());
      if (token !== threadTokenRef.current) return;
      if (!pg) throw new Error('older thread page had no page block');
      st.cursor = pg.cursor;
      st.hasMore = pg.hasMore;
      st.loading = false;
      setThreadMessages(prev => mergeOlder(prev, pg.messages));
      setThreadPage(p => ({
        ...p, hasMore: pg.hasMore, loading: false, error: false,
        loadedCount: pg.messages.length, loadedTick: p.loadedTick + 1,
      }));
    } catch (err) {
      if (token !== threadTokenRef.current) return;
      console.error('Failed to load older thread messages:', err);
      st.loading = false;
      setThreadPage(p => ({ ...p, loading: false, error: true }));
    }
  }, [user]);

  // Start (or open the existing) thread anchored on a main-chat message.
  // Returns true when a thread was opened.
  const startThread = useCallback(async (msg) => {
    const gid = groupIdOfContact(currentContactRef.current);
    if (!user || !gid || !msg || !msg.id) return false;
    try {
      const summary = await createThread(user.user_id, gid, msg.id);
      openThread(summary);
      return true;
    } catch (err) {
      if (err && err.code === 'terms_reaccept_required') {
        capsRef.current?.refresh?.();
        message.info('Please review and accept the updated Terms to start a thread.');
      } else if (err && err.code === 'thread_limit') {
        message.error('This group has reached its thread limit.');
      } else if (err && err.status === 404) {
        message.error("Couldn't start a thread on that message.");
      } else {
        message.error(err?.message || "Couldn't start a thread. Please try again.");
      }
      return false;
    }
  }, [user, openThread]);

  // Thread messages go over the existing socket as a thread_message frame; the
  // server derives the group and recipients from thread_id.
  const sendThreadMessage = useCallback((text, attachment = null) => {
    const tv = threadViewRef.current;
    if (!user || !tv || !wsRef.current || wsRef.current.readyState !== 1) return;
    const clientRef = newClientRef();
    const payload = {
      type: 'thread_message',
      from_user: user.user_id,
      thread_id: tv.thread.id,
      text,
      client_ref: clientRef,
    };
    if (attachment) {
      payload.attachment_kind = attachment.kind;
      payload.attachment_meta = attachment.meta || {};
      if (attachment.objectKey) payload.attachment_key = attachment.objectKey;
    }
    wsRef.current.send(JSON.stringify(payload));
    setThreadMessages(prev => [...prev, {
      key: `c:${clientRef}`, clientRef, pending: true,
      text, mine: true, timestamp: new Date().toISOString(), sender: '',
      attachmentKind: attachment ? attachment.kind : null,
      attachmentMeta: attachment ? (attachment.meta || null) : null,
      attachmentUrl: (attachment && attachment.kind === 'gif') ? null : (attachment?.localUrl || null),
    }]);
  }, [user]);

  // Delete (author only, group chat) with the server's undo window. The row
  // leaves the list immediately and is put back if the call fails. Resolves to
  // { id, undoSeconds } or null.
  const deleteMessage = useCallback(async (msg) => {
    const gid = groupIdOfContact(currentContactRef.current);
    if (!user || !gid || !msg || !msg.id) return null;
    deletedRowsRef.current.set(msg.id, msg);
    setMessages(prev => prev.filter(m => m.id !== msg.id));
    try {
      const res = await deleteGroupMessage(user.user_id, gid, msg.id);
      const secs = Number(res && res.undo_seconds);
      return { id: msg.id, undoSeconds: secs > 0 ? secs : DEFAULT_UNDO_SECONDS };
    } catch (err) {
      console.error('Failed to delete message:', err);
      deletedRowsRef.current.delete(msg.id);
      setMessages(prev => insertRestored(prev, msg));
      message.error("Couldn't delete that message. Please try again.");
      return null;
    }
  }, [user]);

  const restoreMessage = useCallback(async (messageId) => {
    const gid = groupIdOfContact(currentContactRef.current);
    const row = deletedRowsRef.current.get(messageId);
    if (!user || !gid || !row) return false;
    try {
      await restoreGroupMessage(user.user_id, gid, messageId);
      deletedRowsRef.current.delete(messageId);
      setMessages(prev => insertRestored(prev, row));
      return true;
    } catch (err) {
      console.error('Failed to restore message:', err);
      deletedRowsRef.current.delete(messageId);
      message.error("Couldn't undo that delete. It can only be undone for a few seconds.");
      return false;
    }
  }, [user]);

  // Frames from the one socket (registered through threadFrameCbRef above).
  const handleThreadFrame = useCallback((data) => {
    const cc = currentContactRef.current;
    const gid = groupIdOfContact(cc);
    const sameGroup = gid && typeof data.group_id === 'string' && data.group_id.toLowerCase() === String(gid).toLowerCase();
    if (data.type === 'thread_message') {
      const tv = threadViewRef.current;
      if (!tv || data.thread_id !== tv.thread.id) return;
      const row = threadFrameToRow(data);
      if (row) setThreadMessages(prev => mergeLive(prev, row));
      return;
    }
    if (data.type === 'message_deleted') {
      if (!sameGroup || typeof data.id !== 'string') return;
      setMessages(prev => prev.filter(m => m.id !== data.id));
      const tv = threadViewRef.current;
      if (tv && tv.thread.root_message_id === data.id) {
        const next = { thread: { ...tv.thread, root_deleted: true } };
        threadViewRef.current = next;
        setThreadView(next);
      }
      return;
    }
    if (data.type === 'message_restored') {
      if (!sameGroup) return;
      const row = threadFrameToRow(data);
      if (row) setMessages(prev => insertRestored(prev, row));
      const tv = threadViewRef.current;
      if (tv && tv.thread.root_message_id === data.id && tv.thread.root_deleted) {
        const next = { thread: { ...tv.thread, root_deleted: false } };
        threadViewRef.current = next;
        setThreadView(next);
      }
      return;
    }
    if (data.type === 'thread_send_failed') {
      // The send did not land: drop the unacked optimistic bubble and give the
      // text back to the composer (never lose what the user typed).
      const tv = threadViewRef.current;
      if (!tv) return;
      const pending = [...threadMessagesRef.current].reverse().find(m => m.pending && !m.id);
      if (!pending) return;
      setThreadMessages(prev => prev.filter(m => m !== pending && m.clientRef !== pending.clientRef));
      if (pending.text && !pending.attachmentKind) {
        setRestoredDraft(prev => ({ tick: (prev ? prev.tick : 0) + 1, text: pending.text }));
      }
    }
  }, []);
  useEffect(() => {
    threadFrameCbRef.current = handleThreadFrame;
    return () => { threadFrameCbRef.current = null; };
  }, [handleThreadFrame]);

  // ── Open chat ─────────────────────────────────────────────────────────────

  const openChat = useCallback(async (contact) => {
    const token = ++chatTokenRef.current;
    clearAckTimers();
    resetThread();
    pageRef.current = { cursor: null, hasMore: false, loading: false, paged: false };
    setOlderPage(PAGING_IDLE);
    setCurrentContact(contact);
    setMessages([]);
    setGroupMembers([]);
    try {
      const limitQs = isPagedFor(contact.type) ? `?limit=${INITIAL_PAGE_LIMIT}` : '';
      const res = contact.type === 'friend'
        ? await fetch(`${API}/friends/${user.user_id}/${contact.id}${limitQs}`)
        : await fetch(`${API}/groups/${user.user_id}/${contact.id}${limitQs}`);
      if (token !== chatTokenRef.current) return;
      if (res.ok) {
        const data = await res.json();
        if (token !== chatTokenRef.current) return;
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
          if (token !== chatTokenRef.current) return;
          setGroupMembers(resolvedMembers);
        }
        // Paged response: server order is kept verbatim (oldest-first), never
        // re-sorted by timestamp string. No `page` block = legacy full history.
        const pg = parsePage(data);
        if (pg) {
          pageRef.current = { cursor: pg.cursor, hasMore: pg.hasMore, loading: false, paged: true };
          setOlderPage({ ...PAGING_IDLE, paged: true, hasMore: pg.hasMore });
          setMessages(pg.messages);
          return;
        }
        const all = [
          ...(data.host_msgs  || []).map(m => ({ ...m, mine: true })),
          ...(data.other_msgs || []).map(m => ({ ...m, mine: false })),
        ].sort(compareTimestamps);
        setMessages(all.map(m => ({
          ...(typeof m.id === 'string' && m.id ? { id: m.id, key: m.id } : {}),
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
  }, [user, clearAckTimers, resetThread]);

  const closeChat = useCallback(() => {
    chatTokenRef.current += 1;
    clearAckTimers();
    resetThread();
    pageRef.current = { cursor: null, hasMore: false, loading: false, paged: false };
    setOlderPage(PAGING_IDLE);
    setCurrentContact(null);
    setMessages([]);
    setGroupMembers([]);
  }, [clearAckTimers, resetThread]);

  // Task 20261001-chat-pagination: older page for the open thread. Safe to
  // call repeatedly (no-op while loading or at the start of the conversation);
  // after an error the same call is the retry.
  const loadOlder = useCallback(async () => {
    const cc = currentContactRef.current;
    const st = pageRef.current;
    if (!user || !cc || !st.paged || !st.hasMore || !st.cursor || st.loading) return;
    const token = chatTokenRef.current;
    st.loading = true;
    setOlderPage(p => ({ ...p, loading: true, error: false }));
    try {
      const base = cc.type === 'friend'
        ? `${API}/friends/${user.user_id}/${encodeURIComponent(cc.id)}/messages`
        : `${API}/groups/${user.user_id}/${cc.id}/messages`;
      const res = await fetch(`${base}?${pageQuery(OLDER_PAGE_LIMIT, st.cursor)}`);
      if (token !== chatTokenRef.current) return;
      if (!res.ok) throw new Error(`older page HTTP ${res.status}`);
      const pg = parsePage(await res.json());
      if (token !== chatTokenRef.current) return;
      if (!pg) throw new Error('older page response had no page block');
      st.cursor = pg.cursor;
      st.hasMore = pg.hasMore;
      st.loading = false;
      setMessages(prev => mergeOlder(prev, pg.messages));
      setOlderPage(p => ({
        ...p, hasMore: pg.hasMore, loading: false, error: false,
        loadedCount: pg.messages.length, loadedTick: p.loadedTick + 1,
      }));
    } catch (err) {
      if (token !== chatTokenRef.current) return;
      console.error('Failed to load older messages:', err);
      st.loading = false;
      setOlderPage(p => ({ ...p, loading: false, error: true }));
    }
  }, [user]);

  // Lost-ack fallback (once per send): if no ack arrived within 5 s, refetch
  // the newest page and match the pending bubble by text + attachment kind
  // within 120 s. Never removes the bubble when nothing matches.
  const scheduleAckFallback = useCallback((clientRef, contact, token) => {
    const timer = setTimeout(async () => {
      ackTimersRef.current.delete(clientRef);
      if (token !== chatTokenRef.current) return;
      const pendingMsg = messagesRef.current.find(m => m.clientRef === clientRef && !m.id);
      if (!pendingMsg) return;
      try {
        const base = contact.type === 'friend'
          ? `${API}/friends/${user.user_id}/${encodeURIComponent(contact.id)}/messages`
          : `${API}/groups/${user.user_id}/${contact.id}/messages`;
        const res = await fetch(`${base}?${pageQuery(OLDER_PAGE_LIMIT, null)}`);
        if (!res.ok || token !== chatTokenRef.current) return;
        const pg = parsePage(await res.json());
        if (!pg || token !== chatTokenRef.current) return;
        const match = findLostAckMatch(messagesRef.current, pendingMsg, pg.messages);
        if (match) {
          setMessages(prev => reconcileAck(prev, { client_ref: clientRef, id: match.id, timestamp: match.timestamp }));
        }
      } catch (err) {
        console.error('Lost-ack fallback fetch failed:', err);
      }
    }, ACK_FALLBACK_MS);
    ackTimersRef.current.set(clientRef, timer);
  }, [user]);

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
    // client_ref only on a thread that was opened paged (capability on), so a
    // server without pagination never sees the extra field and no ack is
    // awaited that cannot come.
    const clientRef = pageRef.current.paged ? newClientRef() : null;
    if (clientRef) payload.client_ref = clientRef;
    wsRef.current.send(JSON.stringify(payload));
    if (clientRef) scheduleAckFallback(clientRef, currentContact, chatTokenRef.current);
    setMessages(prev => [...prev, {
      ...(clientRef ? { key: `c:${clientRef}`, clientRef, pending: true } : {}),
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
  }, [user, currentContact, scheduleAckFallback]);

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

  // Task 20260929-group-info-panel: apply a server-confirmed rename/photo
  // change (from GroupInfoPanel) to the list row, the open chat header, and
  // the cached row, so nothing shows the stale value until the next reload.
  // Only ever called after the API call succeeded.
  const applyGroupChange = useCallback((groupId, { title, photoUrl } = {}) => {
    const hasTitle = typeof title === 'string';
    const hasPhoto = photoUrl !== undefined;
    setGroups(prev => prev[groupId] ? {
      ...prev,
      [groupId]: { ...prev[groupId], ...(hasTitle ? { title } : {}), ...(hasPhoto ? { photoUrl } : {}) },
    } : prev);
    setCurrentContact(prev => (prev && prev.id === groupId) ? {
      ...prev, ...(hasTitle ? { name: title } : {}), ...(hasPhoto ? { photoUrl } : {}),
    } : prev);
    const cached = groupEntryCache.current[groupId];
    if (cached) {
      groupEntryCache.current[groupId] = {
        meta: { ...cached.meta, ...(hasTitle ? { title } : {}), ...(hasPhoto ? { photoUrl } : {}) },
        entry: { ...cached.entry, ...(hasTitle ? { name: title } : {}), ...(hasPhoto ? { photoUrl } : {}) },
      };
    }
  }, []);

  // The server said we're no longer a member (403): drop the stale row and
  // leave the chat rather than keep showing it.
  const dropGroup = useCallback((groupId) => {
    delete groupEntryCache.current[groupId];
    setGroups(prev => { const { [groupId]: _gone, ...rest } = prev; return rest; });
    closeChat();
    message.info("You're no longer in this group.");
  }, [closeChat]);

  return {
    applyGroupChange, dropGroup,
    friends, groups, currentContact, messages, groupMembers, wsStatus,
    olderPage, loadOlder,
    threadView, threadMessages, threadPage, threadLoad, restoredDraft,
    openThread, closeThread, retryThread, loadOlderThread, startThread, sendThreadMessage,
    deleteMessage, restoreMessage,
    wsRef, friendCache,
    connectWS, disconnectWS, setOnSessionSignal,
    loadContacts, openChat, closeChat, sendMessage,
    addFriend, removeFriend, createGroup, updateGroup, leaveGroup,
    reportUser, blockUser,
    requestUploadUrl, uploadToS3, searchGifs, browseGifs,
  };
}
