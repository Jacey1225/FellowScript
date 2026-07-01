import { useState, useRef, useCallback, useEffect } from 'react';
import { API, WS_BASE } from '../config.js';

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
    } catch {}
  }, [user]);

  const loadHeartbeats = useCallback(async (agentList) => {
    if (!user || !agentList?.length) return;
    try {
      const results = await Promise.all(
        agentList.map(agent =>
          fetch(`${API}/agent/${user.user_id}/${agent.id}/heartbeats`)
            .then(r => r.ok ? r.json() : [])
            .then(list => list.map(hb => ({ ...hb, agent_id: agent.id })))
            .catch(() => [])
        )
      );
      setHeartbeats(results.flat());
    } catch {}
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
      const curH     = now.getHours();
      const curM     = now.getMinutes();
      const todayStr = now.toISOString().slice(0, 10); // "YYYY-MM-DD"

      for (const hb of heartbeatsRef.current) {
        const fireKey = `${hb._id}-${todayStr}`;
        if (firedTodayRef.current.has(fireKey)) continue;

        const scheduled = new Date(hb.timestamp);
        if (isNaN(scheduled.getTime())) continue;

        const dayMatch  = (hb.days_per_week || []).includes(dayName);
        const timeMatch = scheduled.getHours() === curH && scheduled.getMinutes() === curM;

        if (!dayMatch || !timeMatch) continue;

        firedTodayRef.current.add(fireKey);
        try {
          const res = await fetch(`${API}/agent/${user.user_id}/${hb.agent_id}/commit_heartbeat`, {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ prompt: hb.prompt }),
          });
          if (!res.ok) continue;
          const data = await res.json();
          if (data.success === 'saved note') {
            onNoteSavedRef.current?.();
          } else if (data.__action === 'create_notification') {
            setPendingNotifications(prev => [...prev, data]);
          }
        } catch {}
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
      } catch {}
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
        })).sort((a, b) => (a.timestamp > b.timestamp ? 1 : -1));
        setAgentMessages(msgs);
      }
    } catch {}
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
    } catch {}
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
    } catch {}
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
    } catch {}
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
    } catch {}
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
      return res.ok;
    } catch {}
    return false;
  }, [user]);

  return {
    agents, agentMessages, activeAgent, agentThinking, agentWsRef,
    heartbeats, pendingNotifications,
    loadAgents, loadHeartbeats, openAgentChat, closeAgentChat, sendAgentMessage,
    createAgent, updateAgent, deleteAgent, addHeartbeat, summarizeSession,
  };
}
