import { useState, useRef, useCallback, useEffect } from 'react';
import { message } from 'antd';
import { API, WS_BASE } from '../config.js';
import { compareTimestamps } from '../utils.js';

export function useAgentChat({ user, onNoteSaved }) {
  const [agents,               setAgents]               = useState([]);
  const [agentMessages,        setAgentMessages]        = useState([]);
  const [activeAgent,          setActiveAgent]          = useState(null);
  const [agentThinking,        setAgentThinking]        = useState(false);
  const [heartbeats,           setHeartbeats]           = useState([]);
  const [pendingNotifications, setPendingNotifications] = useState([]);
  const agentWsRef     = useRef(null);
  const heartbeatsRef  = useRef([]);
  const firedTodayRef  = useRef(new Set());
  const onNoteSavedRef = useRef(onNoteSaved);

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
            content: 'A scheduled check-in failed to save. Retrying automatically.',
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

  // ── WebSocket ─────────────────────────────────────────────────────────────

  const connectAgentWS = useCallback((agentId) => {
    if (agentWsRef.current) agentWsRef.current.close();
    agentWsRef.current = new WebSocket(`${WS_BASE}/agent/ws/${agentId}/${user.user_id}`);
    agentWsRef.current.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data);
        setAgentThinking(false);
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
    agentWsRef.current.onclose = () => setAgentThinking(false);
  }, [user]);

  const disconnectAgentWS = useCallback(() => {
    if (agentWsRef.current) { agentWsRef.current.close(); agentWsRef.current = null; }
  }, []);

  // ── Open / close ──────────────────────────────────────────────────────────

  const openAgentChat = useCallback(async (agent) => {
    setActiveAgent(agent);
    setAgentMessages([]);
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agent.id}/messages`);
      if (res.ok) {
        const data = await res.json();
        const msgs = Object.entries(data).map(([, m]) => ({
          text:      m.content,
          mine:      m.title === 'user',
          timestamp: m.timestamp,
          sender:    m.title === 'user' ? '' : 'Agent',
        })).sort(compareTimestamps);
        setAgentMessages(msgs);
      }
    } catch (err) {
      console.error('Failed to load agent chat history:', err);
      message.error('Could not load that conversation. Check your connection and try again.');
    }
    connectAgentWS(agent.id);
  }, [user, connectAgentWS]);

  const closeAgentChat = useCallback(() => {
    setActiveAgent(null);
    setAgentMessages([]);
    disconnectAgentWS();
  }, [disconnectAgentWS]);

  // ── Send ──────────────────────────────────────────────────────────────────

  const sendAgentMessage = useCallback((content) => {
    if (!agentWsRef.current || agentWsRef.current.readyState !== 1) return;
    agentWsRef.current.send(JSON.stringify({ content }));
    setAgentMessages(prev => [...prev, {
      text: content, mine: true, timestamp: new Date().toISOString(), sender: '',
    }]);
    setAgentThinking(true);
  }, []);

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
      message.error('Could not save that check-in schedule. Please try again.');
    } catch (err) {
      console.error('Failed to add heartbeat:', err);
      message.error('Could not save that check-in schedule. Check your connection and try again.');
    }
    return false;
  }, [user, agents, loadHeartbeats]);

  const summarizeSession = useCallback(async (agentId, sessionData, groupId) => {
    if (!user) return false;
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agentId}/summarize`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ session: sessionData, group_id: groupId }),
      });
      if (!res.ok) message.error('Could not summarize that session. Please try again.');
      return res.ok;
    } catch (err) {
      console.error('Failed to summarize session:', err);
      message.error('Could not summarize that session. Check your connection and try again.');
    }
    return false;
  }, [user]);

  return {
    agents, agentMessages, activeAgent, agentThinking, agentWsRef,
    heartbeats, pendingNotifications,
    loadAgents, loadHeartbeats, openAgentChat, closeAgentChat, sendAgentMessage,
    createAgent, updateAgent, deleteAgent, addHeartbeat, summarizeSession,
  };
}
