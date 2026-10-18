import { useState, useRef, useCallback, useEffect } from 'react';
import { message } from 'antd';
import { API, WS_BASE } from '../config.js';
import { handleBlockedResponse } from '../lib/upgradePrompt.js';
import { compareTimestamps } from '../utils.js';
import {
  AgentChatHttpError, createChatErrorMessage, pickInitialChatId, readLastChat, writeLastChat,
} from '../lib/agentChats.js';
import { probeSession, markSessionEnded } from '../lib/sessionEnd.js';

// Deferred-summary retry: server presence goes stale after 45 s, so retry ~50 s apart.
const SUMMARIZE_DEFER_RETRY_MS = 50_000;
const SUMMARIZE_DEFER_MAX_RETRIES = 2;

// Pending-send key for the legacy (flag off) single chat.
const LEGACY_CHAT_KEY = '';

function mapHistory(data) {
  return Object.entries(data).map(([, m]) => ({
    text:      m.content,
    mine:      m.title === 'user',
    timestamp: m.timestamp,
    sender:    m.title === 'user' ? '' : 'Agent',
  })).sort(compareTimestamps);
}

// multiChat = capability `agent_chats`. Off: the legacy single flat chat, no
// chat_id anywhere. On: per-agent chat list, chat-scoped history and socket.
export function useAgentChat({ user, onNoteSaved, multiChat = false }) {
  const [agents,               setAgents]               = useState([]);
  const [agentMessages,        setAgentMessages]        = useState([]);
  const [activeAgent,          setActiveAgent]          = useState(null);
  const [pendingChats,         setPendingChats]         = useState(() => new Set());
  const [chats,                setChats]                = useState([]);
  const [chatsLoaded,          setChatsLoaded]          = useState(false);
  const [chatsLoading,         setChatsLoading]         = useState(false);
  const [chatsError,           setChatsError]           = useState(null);
  const [activeChatId,         setActiveChatId]         = useState(null);
  const [createChatError,      setCreateChatError]      = useState(null);
  const [creatingChat,         setCreatingChat]         = useState(false);
  const [historyError,         setHistoryError]         = useState(null);
  const [historyLoading,       setHistoryLoading]       = useState(false);
  const [heartbeats,           setHeartbeats]           = useState([]);
  const [pendingNotifications, setPendingNotifications] = useState([]);
  const agentWsRef     = useRef(null);
  const heartbeatsRef  = useRef([]);
  const firedTodayRef  = useRef(new Set());
  const onNoteSavedRef = useRef(onNoteSaved);
  // Mirrors of state read inside socket/async callbacks.
  const activeAgentRef = useRef(null);
  const activeChatRef  = useRef(null);
  const multiChatRef   = useRef(multiChat);
  const historySeqRef  = useRef(0);   // stale-response guard for history fetches
  const chatsSeqRef    = useRef(0);   // stale-response guard for list fetches
  // Per-chat transcript cache so a failed refresh keeps the prior messages.
  const messageCacheRef = useRef(new Map());
  multiChatRef.current = multiChat;

  useEffect(() => { heartbeatsRef.current  = heartbeats;  }, [heartbeats]);
  useEffect(() => { onNoteSavedRef.current = onNoteSaved; }, [onNoteSaved]);

  // ── Load ──────────────────────────────────────────────────────────────────

  const loadAgents = useCallback(async () => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/agent/${user.user_id}`);
      if (res.ok) {
        const data = await res.json();
        const list = Object.entries(data).map(([id, a]) => ({ id, ...a }));
        setAgents(list);
      }
    } catch (err) {
      // Background load -- log only, matching useMessaging.loadContacts'
      // established convention for passive/background loads.
      console.error('Failed to load agents:', err);
    }
  }, [user]);

  const loadHeartbeats = useCallback(async (agentList) => {
    if (!user || !agentList?.length) return;
    try {
      const results = await Promise.all(
        agentList.map(agent =>
          fetch(`${API}/agent/${user.user_id}/${agent.id}/heartbeats`)
            .then(r => r.ok ? r.json() : [])
            .then(list => list.map(hb => ({ ...hb, agent_id: agent.id })))
            .catch(err => {
              console.error(`Failed to load heartbeats for agent ${agent.id}:`, err);
              return [];
            })
        )
      );
      setHeartbeats(results.flat());
    } catch (err) {
      console.error('Failed to load heartbeats:', err);
    }
  }, [user]);

  // Reload heartbeats whenever the agents list changes
  useEffect(() => {
    if (agents.length) loadHeartbeats(agents);
  }, [agents, loadHeartbeats]);

  // ── Heartbeat monitor ─────────────────────────────────────────────────────

  useEffect(() => {
    if (!user) return;

    const checkHeartbeats = async () => {
      const now      = new Date();
      const dayName  = now.toLocaleDateString('en-US', { weekday: 'long' }); // e.g. "Monday"
      const todayStr = now.toISOString().slice(0, 10); // "YYYY-MM-DD"

      for (const hb of heartbeatsRef.current) {
        const fireKey = `${hb._id}-${todayStr}`;
        if (firedTodayRef.current.has(fireKey)) continue;

        const scheduled = new Date(hb.timestamp);
        if (isNaN(scheduled.getTime())) continue;

        const dayMatch = (hb.days_per_week || []).includes(dayName);
        if (!dayMatch) continue;

        // Match the heartbeat's scheduled hour/minute against *today's*
        // date rather than requiring this exact tick to land on that exact
        // minute (logic-errors #4): this 60s interval isn't guaranteed to
        // run precisely on the minute (a throttled/backgrounded tab, or the
        // app simply opening after the scheduled time already passed), so
        // this fires as soon as we notice we're at or past today's
        // scheduled time instead of silently losing the check-in for the
        // rest of the day.
        const scheduledToday = new Date(now);
        scheduledToday.setHours(scheduled.getHours(), scheduled.getMinutes(), 0, 0);
        if (now.getTime() < scheduledToday.getTime()) continue;

        try {
          const res = await fetch(`${API}/agent/${user.user_id}/${hb.agent_id}/${hb._id}/commit_heartbeat`, {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ prompt: hb.prompt }),
          });
          if (!res.ok) throw new Error(`Heartbeat check-in failed with status ${res.status}`);

          // Only mark today's check-in as "fired" once the POST is actually
          // confirmed (H7) -- marking it beforehand meant a failed check-in
          // silently never happened for the rest of the day (Architecture
          // Q27: propagate failures upward rather than silently
          // substituting a default).
          firedTodayRef.current.add(fireKey);

          const data = await res.json();
          if (data.success === 'saved note') {
            onNoteSavedRef.current?.();
          } else if (data.__action === 'create_notification') {
            setPendingNotifications(prev => [...prev, data]);
          }
        } catch (err) {
          console.error(`Heartbeat check-in failed for agent ${hb.agent_id}:`, err);
          // Keyed so a repeated failure on the next 60s tick refreshes this
          // same toast instead of stacking new ones (matches useMessaging's
          // 'fs-ws-status' keyed-toast pattern).
          message.error({
            content: 'A scheduled devotion failed to save. Retrying automatically.',
            key: `fs-heartbeat-${hb._id}`,
            duration: 4,
          });
          // Deliberately not added to firedTodayRef -- since timeMatch above
          // no longer requires an exact minute, the next 60s tick retries
          // automatically until it succeeds or the day rolls over.
        }
      }
    };

    const id = setInterval(checkHeartbeats, 60_000);
    return () => clearInterval(id);
  }, [user]);

  // ── Pending ("thinking") tracking, per chat ───────────────────────────────

  const setPending = useCallback((chatKey, on) => {
    setPendingChats(prev => {
      if (prev.has(chatKey) === on) return prev;
      const next = new Set(prev);
      if (on) next.add(chatKey); else next.delete(chatKey);
      return next;
    });
  }, []);

  // ── WebSocket ─────────────────────────────────────────────────────────────

  const connectAgentWS = useCallback((agentId, chatId) => {
    if (agentWsRef.current) agentWsRef.current.close();
    const key = chatId || LEGACY_CHAT_KEY;
    const qs = chatId ? `?chat_id=${encodeURIComponent(chatId)}` : '';
    const ws = new WebSocket(`${WS_BASE}/agent/ws/${agentId}/${user.user_id}${qs}`);
    agentWsRef.current = ws;
    ws.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data);
        // A frame tagged for another chat never touches this transcript.
        if (multiChatRef.current && data.chat_id && data.chat_id !== key) return;
        setPending(key, false);
        setAgentMessages(prev => [...prev, {
          text:      data.content,
          mine:      false,
          timestamp: data.timestamp,
          sender:    'Agent',
        }]);
      } catch (err) {
        // Matches useMessaging's WS onmessage handler -- log a malformed
        // frame rather than crashing the socket handler.
        console.error('Failed to parse incoming agent WS message:', err);
      }
    };
    ws.onclose = () => {
      setPending(key, false);
      // No reconnect here. If the socket was not closed on purpose (the ref
      // still points at it), check whether the session ended so the user sees
      // the global "Your session ended" banner instead of a silent dead chat.
      if (agentWsRef.current !== ws) return;
      probeSession(user.user_id).then((state) => {
        if (state === 'ended') markSessionEnded();
      });
    };
  }, [user, setPending]);

  const disconnectAgentWS = useCallback(() => {
    if (agentWsRef.current) { agentWsRef.current.close(); agentWsRef.current = null; }
  }, []);

  // ── Chats (flag agent_chats) ──────────────────────────────────────────────

  const fetchChatList = useCallback(async (agentId) => {
    const res = await fetch(`${API}/agent/${user.user_id}/${agentId}/chats`);
    if (!res.ok) throw new AgentChatHttpError(res.status);
    const data = await res.json();
    return Array.isArray(data?.chats) ? data.chats : [];
  }, [user]);

  // Load one chat's history. Throws nothing: sets historyError and keeps the
  // cached transcript instead (never shows a failed load as an empty chat).
  // Returns 'ok' | 'not_found' | 'error' | 'stale'.
  const loadHistory = useCallback(async (agentId, chatId) => {
    const seq = ++historySeqRef.current;
    setHistoryLoading(true);
    setHistoryError(null);
    const qs = chatId ? `?chat_id=${encodeURIComponent(chatId)}` : '';
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agentId}/messages${qs}`);
      if (seq !== historySeqRef.current) return 'stale';
      if (!res.ok) {
        setHistoryLoading(false);
        if (res.status === 404 && chatId) return 'not_found';
        setHistoryError("Couldn't load this chat. Try again");
        return 'error';
      }
      const data = await res.json();
      if (seq !== historySeqRef.current) return 'stale';
      const msgs = mapHistory(data);
      messageCacheRef.current.set(chatId || LEGACY_CHAT_KEY, msgs);
      setAgentMessages(msgs);
      setHistoryLoading(false);
      return 'ok';
    } catch (err) {
      if (seq !== historySeqRef.current) return 'stale';
      console.error('Failed to load agent chat history:', err);
      setHistoryLoading(false);
      setHistoryError("Couldn't load this chat. Try again");
      return 'error';
    }
  }, [user]);

  const activateChat = useCallback(async (agent, chatId) => {
    activeChatRef.current = chatId;
    setActiveChatId(chatId);
    if (chatId) writeLastChat(user.user_id, agent.id, chatId);
    setAgentMessages(messageCacheRef.current.get(chatId || LEGACY_CHAT_KEY) || []);
    connectAgentWS(agent.id, chatId);
    return loadHistory(agent.id, chatId);
  }, [user, connectAgentWS, loadHistory]);

  // Re-fetch the list. A failed refresh keeps the existing list and sets
  // chatsError; it never blanks or fabricates chats. Returns the list or null.
  const refreshChats = useCallback(async (agent) => {
    const target = agent || activeAgentRef.current;
    if (!user || !target) return null;
    const seq = ++chatsSeqRef.current;
    setChatsLoading(true);
    try {
      const list = await fetchChatList(target.id);
      if (seq !== chatsSeqRef.current || activeAgentRef.current?.id !== target.id) return null;
      setChats(list);
      setChatsLoaded(true);
      setChatsError(null);
      setChatsLoading(false);
      return list;
    } catch (err) {
      if (seq !== chatsSeqRef.current) return null;
      console.error('Failed to load agent chats:', err);
      setChatsError("Couldn't load chats");
      setChatsLoading(false);
      return null;
    }
  }, [user, fetchChatList]);

  const selectChat = useCallback(async (chatId) => {
    const agent = activeAgentRef.current;
    if (!agent || !chatId || chatId === activeChatRef.current) return;
    setCreateChatError(null);
    const result = await activateChat(agent, chatId);
    if (result === 'not_found') {
      // Foreign/unknown chat: say so, refetch, fall back (never a fallback by the server).
      setHistoryError('That chat is no longer available.');
      const list = await refreshChats(agent);
      if (list && activeAgentRef.current?.id === agent.id) {
        const fallback = pickInitialChatId(list, readLastChat(user.user_id, agent.id));
        if (fallback && fallback !== chatId) await activateChat(agent, fallback);
      }
    }
  }, [user, activateChat, refreshChats]);

  const createChat = useCallback(async () => {
    const agent = activeAgentRef.current;
    if (!user || !agent || creatingChat) return null;
    setCreatingChat(true);
    setCreateChatError(null);
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agent.id}/chats`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{}',
      });
      if (!res.ok) {
        let code = null;
        try { const body = await res.json(); code = body?.detail?.code || body?.code || null; } catch { /* no body */ }
        throw new AgentChatHttpError(res.status, code);
      }
      const chat = await res.json();
      if (activeAgentRef.current?.id !== agent.id) return null;
      setChats(prev => [chat, ...prev.filter(c => c.id !== chat.id)]);
      messageCacheRef.current.set(chat.id, []);
      setHistoryError(null);
      activeChatRef.current = chat.id;
      setActiveChatId(chat.id);
      writeLastChat(user.user_id, agent.id, chat.id);
      setAgentMessages([]);
      connectAgentWS(agent.id, chat.id);
      return chat;
    } catch (err) {
      console.error('Failed to create agent chat:', err);
      // Current chat stays active; no chat is invented client-side.
      setCreateChatError(createChatErrorMessage(err, agent.name || 'this agent'));
      return null;
    } finally {
      setCreatingChat(false);
    }
  }, [user, creatingChat, connectAgentWS]);

  const retryHistory = useCallback(() => {
    const agent = activeAgentRef.current;
    if (agent) loadHistory(agent.id, activeChatRef.current);
  }, [loadHistory]);

  const clearChatErrors = useCallback(() => {
    setCreateChatError(null);
    setHistoryError(null);
  }, []);

  const resetChatState = useCallback(() => {
    chatsSeqRef.current += 1;
    historySeqRef.current += 1;
    activeChatRef.current = null;
    messageCacheRef.current = new Map();
    setChats([]);
    setChatsLoaded(false);
    setChatsLoading(false);
    setChatsError(null);
    setActiveChatId(null);
    setCreateChatError(null);
    setHistoryError(null);
    setHistoryLoading(false);
  }, []);

  // ── Open / close ──────────────────────────────────────────────────────────

  const openAgentChat = useCallback(async (agent) => {
    activeAgentRef.current = agent;
    setActiveAgent(agent);
    setAgentMessages([]);
    resetChatState();

    if (!multiChatRef.current) {
      // Legacy single flat chat: unchanged (no chat_id, no chat UI).
      try {
        const res = await fetch(`${API}/agent/${user.user_id}/${agent.id}/messages`);
        if (res.ok) {
          const data = await res.json();
          setAgentMessages(mapHistory(data));
        }
      } catch (err) {
        console.error('Failed to load agent chat history:', err);
        message.error('Could not load that conversation. Check your connection and try again.');
      }
      connectAgentWS(agent.id);
      return;
    }

    const list = await refreshChats(agent);
    if (activeAgentRef.current?.id !== agent.id) return;
    if (list === null) {
      // List failed: chatsError is set. Absent chat_id is the server's default
      // chat, so history and sends still work without inventing a chat.
      await activateChat(agent, null);
      return;
    }
    await activateChat(agent, pickInitialChatId(list, readLastChat(user.user_id, agent.id)));
  }, [user, resetChatState, refreshChats, activateChat, connectAgentWS]);

  const closeAgentChat = useCallback(() => {
    activeAgentRef.current = null;
    setActiveAgent(null);
    setAgentMessages([]);
    resetChatState();
    disconnectAgentWS();
  }, [disconnectAgentWS, resetChatState]);

  // ── Send ──────────────────────────────────────────────────────────────────

  const sendAgentMessage = useCallback((content) => {
    if (!agentWsRef.current || agentWsRef.current.readyState !== 1) return;
    const chatId = multiChatRef.current ? activeChatRef.current : null;
    const frame = chatId ? { content, chat_id: chatId } : { content };
    agentWsRef.current.send(JSON.stringify(frame));
    setAgentMessages(prev => [...prev, {
      text: content, mine: true, timestamp: new Date().toISOString(), sender: '',
    }]);
    setPending(chatId || LEGACY_CHAT_KEY, true);
  }, [setPending]);

  // ── CRUD ──────────────────────────────────────────────────────────────────

  const createAgent = useCallback(async (role) => {
    if (!user) return null;
    const body = { user_id: user.user_id, chats: [], enabled: true };
    if (role) body.role = role;
    try {
      const res = await fetch(`${API}/agent/${user.user_id}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (res.ok || res.status === 201) {
        const data = await res.json();
        await loadAgents();
        return { id: data.id, user_id: user.user_id, role: role || '', chats: [], enabled: true };
      }
      message.error('Could not create that agent. Please try again.');
    } catch (err) {
      console.error('Failed to create agent:', err);
      message.error('Could not create that agent. Check your connection and try again.');
    }
    return null;
  }, [user, loadAgents]);

  const updateAgent = useCallback(async (agentId, updates) => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agentId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(updates),
      });
      if (res.ok) { await loadAgents(); return true; }
      message.error('Could not update that agent. Please try again.');
    } catch (err) {
      console.error('Failed to update agent:', err);
      message.error('Could not update that agent. Check your connection and try again.');
    }
    return false;
  }, [user, loadAgents]);

  const deleteAgent = useCallback(async (agentId) => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agentId}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) {
        setAgents(prev => prev.filter(a => a.id !== agentId));
        return true;
      }
      message.error('Could not delete that agent. Please try again.');
    } catch (err) {
      console.error('Failed to delete agent:', err);
      message.error('Could not delete that agent. Check your connection and try again.');
    }
    return false;
  }, [user]);

  const addHeartbeat = useCallback(async (agentId, heartbeat) => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agentId}/heartbeat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ agent_id: agentId, user_id: user.user_id, ...heartbeat }),
      });
      if (res.ok || res.status === 201) {
        await loadHeartbeats(agents);
        return true;
      }
      if (await handleBlockedResponse(res)) return false;
      message.error('Could not save that scheduled devotion. Please try again.');
    } catch (err) {
      console.error('Failed to add heartbeat:', err);
      message.error('Could not save that scheduled devotion. Check your connection and try again.');
    }
    return false;
  }, [user, agents, loadHeartbeats]);

  // Task 20261013-session-call-live-transcript-summary (bounce 2): the server
  // answers {ok: true, deferred: true} (no note yet) while another paid
  // attendee still counts as present. A ghost attendee goes stale after 45 s,
  // so retry the same request a couple of times just past that window. The
  // retry timers live here (not in a component that unmounts on leave); if the
  // tab is closed they are simply lost. Retries are silent and never re-flush
  // the transcript tail (that happens before the first call).
  const postSummarize = useCallback(async (userId, agentId, sessionData, groupId) => {
    const res = await fetch(`${API}/agent/${userId}/${agentId}/summarize`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ session: sessionData, group_id: groupId }),
    });
    let deferred = false;
    if (res.ok) {
      try { deferred = (await res.json())?.deferred === true; } catch { deferred = false; }
    }
    return { res, deferred };
  }, []);

  const summarizeSession = useCallback(async (agentId, sessionData, groupId, onGenerated) => {
    if (!user) return false;
    const userId = user.user_id;
    try {
      const { res, deferred } = await postSummarize(userId, agentId, sessionData, groupId);
      if (!res.ok) {
        if (await handleBlockedResponse(res)) return false;
        message.error('Could not summarize that session. Please try again.');
        return false;
      }
      if (deferred) {
        let attempt = 0;
        const retry = () => {
          attempt += 1;
          setTimeout(async () => {
            try {
              const r = await postSummarize(userId, agentId, sessionData, groupId);
              if (!r.res.ok) return;                       // non-retryable: give up silently
              if (r.deferred) {
                if (attempt < SUMMARIZE_DEFER_MAX_RETRIES) retry();
                return;
              }
              if (typeof onGenerated === 'function') onGenerated();
            } catch { /* network error on a silent retry: give up */ }
          }, SUMMARIZE_DEFER_RETRY_MS);
        };
        retry();
      }
      return true;
    } catch (err) {
      console.error('Failed to summarize session:', err);
      message.error('Could not summarize that session. Check your connection and try again.');
    }
    return false;
  }, [user, postSummarize]);

  // Thinking reflects only the active chat.
  const agentThinking = pendingChats.has(activeChatId || LEGACY_CHAT_KEY);

  return {
    agents, agentMessages, activeAgent, agentThinking, agentWsRef,
    multiChat, chats, chatsLoaded, chatsLoading, chatsError, activeChatId,
    createChatError, creatingChat, historyError, historyLoading,
    selectChat, createChat, refreshChats, retryHistory, clearChatErrors,
    heartbeats, pendingNotifications,
    loadAgents, loadHeartbeats, openAgentChat, closeAgentChat, sendAgentMessage,
    createAgent, updateAgent, deleteAgent, addHeartbeat, summarizeSession,
  };
}
