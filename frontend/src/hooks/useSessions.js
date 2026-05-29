import { useState, useRef, useCallback, useEffect } from 'react';
import { API } from '../config.js';

const STUN = { iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] };
const TALK_THRESHOLD = 18;

export function useSessions({ user, wsRef, currentContact }) {
  const [sessions,        setSessions]        = useState([]);
  const [activeSessionId, setActiveSessionId] = useState(null);
  const [talkingUserId,   setTalkingUserId]   = useState(null);
  const [showCreator,     setShowCreator]     = useState(false);
  const [editingSession,  setEditingSession]  = useState(null);

  const sessionsRef   = useRef([]);
  const activeIdRef   = useRef(null);
  const peerConns     = useRef({});
  const localStream   = useRef(null);
  const analyserRef   = useRef(null);
  const talkInterval  = useRef(null);
  const talkStopTimer = useRef(null);

  useEffect(() => { sessionsRef.current = sessions; }, [sessions]);
  useEffect(() => { activeIdRef.current = activeSessionId; }, [activeSessionId]);

  // ── Creator open/close ────────────────────────────────────────────────────

  const openCreator = useCallback((session = null) => {
    setEditingSession(session || null);
    setShowCreator(true);
  }, []);

  const closeCreator = useCallback(() => {
    setEditingSession(null);
    setShowCreator(false);
  }, []);

  // ── Load ──────────────────────────────────────────────────────────────────

  const loadSessions = useCallback(async () => {
    if (!user || !currentContact) return;
    try {
      const res = await fetch(`${API}/devotions/contact/${encodeURIComponent(currentContact.id)}`);
      if (res.ok) setSessions((await res.json()).sessions || []);
    } catch {}
  }, [user, currentContact]);

  useEffect(() => {
    if (currentContact) loadSessions();
    else setSessions([]);
  }, [currentContact]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Create ────────────────────────────────────────────────────────────────

  const createSession = useCallback(async ({ title, timeStart, timeEnd, verses }) => {
    if (!user || !currentContact) return false;
    try {
      const res = await fetch(`${API}/devotions/`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          devotion_id: '',
          user_id: user.user_id,
          devotion: {
            title,
            time_start: timeStart,
            time_end: timeEnd || '',
            group_id: currentContact.id,
            creator_id: user.user_id,
            participants: [],
            verses,
          },
        }),
      });
      if (!res.ok) return false;
      const { id } = await res.json();
      const others = (currentContact.toUsers || []).filter(uid => uid !== user.user_id);
      if (others.length && wsRef.current?.readyState === 1) {
        wsRef.current.send(JSON.stringify({
          type: 'session-created',
          from_user: user.user_id,
          to_users: others,
          session_id: id,
          group_id: currentContact.id,
        }));
      }
      await loadSessions();
      return true;
    } catch { return false; }
  }, [user, currentContact, wsRef, loadSessions]);

  // ── Update ────────────────────────────────────────────────────────────────

  const updateSession = useCallback(async (sessionId, { title, timeStart, timeEnd, verses }) => {
    if (!user) return false;
    const existing = sessionsRef.current.find(s => s.id === sessionId) || {};
    try {
      const res = await fetch(`${API}/devotions/`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          devotion_id: sessionId,
          user_id: user.user_id,
          devotion: {
            id: sessionId,
            title,
            time_start: timeStart,
            time_end: timeEnd || '',
            group_id: existing.group_id || currentContact?.id || '',
            creator_id: existing.creator_id || user.user_id,
            participants: existing.participants || [],
            verses,
          },
        }),
      });
      if (!res.ok) return false;
      await loadSessions();
      return true;
    } catch { return false; }
  }, [user, currentContact, loadSessions]);

  // ── Delete ────────────────────────────────────────────────────────────────

  const deleteSession = useCallback(async (sessionId) => {
    if (!user) return false;
    const existing = sessionsRef.current.find(s => s.id === sessionId) || {};
    try {
      const res = await fetch(`${API}/devotions/`, {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          devotion_id: sessionId,
          user_id: user.user_id,
          devotion: { id: sessionId, ...existing },
        }),
      });
      if (!res.ok) return false;
      await loadSessions();
      return true;
    } catch { return false; }
  }, [user, loadSessions]);

  // ── Peer connection helpers ────────────────────────────────────────────────

  const initPeer = useRef(null);
  initPeer.current = async (peerId, sessionId, isInitiator) => {
    if (peerConns.current[peerId]) return;
    const pc = new RTCPeerConnection(STUN);
    peerConns.current[peerId] = pc;

    if (localStream.current) {
      localStream.current.getTracks().forEach(t => pc.addTrack(t, localStream.current));
    }

    pc.ontrack = ({ streams }) => {
      const audio = new Audio();
      audio.srcObject = streams[0];
      audio.play().catch(() => {});
    };

    pc.onicecandidate = ({ candidate }) => {
      if (candidate && wsRef.current?.readyState === 1) {
        wsRef.current.send(JSON.stringify({
          type: 'ice-candidate',
          from_user: user.user_id,
          to_users: [peerId],
          candidate,
          session_id: sessionId,
        }));
      }
    };

    if (isInitiator) {
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      if (wsRef.current?.readyState === 1) {
        wsRef.current.send(JSON.stringify({
          type: 'offer',
          from_user: user.user_id,
          to_users: [peerId],
          sdp: offer.sdp,
          session_id: sessionId,
        }));
      }
    }
  };

  // ── Join ──────────────────────────────────────────────────────────────────

  const joinSession = useCallback(async (sessionId) => {
    if (!user || activeIdRef.current) return;

    try {
      await fetch(`${API}/devotions/join?user_id=${encodeURIComponent(user.user_id)}&session_id=${encodeURIComponent(sessionId)}`, { method: 'POST' });
    } catch {}

    try {
      localStream.current = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
    } catch {
      localStream.current = null;
    }

    if (localStream.current) {
      const ctx = new AudioContext();
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 512;
      ctx.createMediaStreamSource(localStream.current).connect(analyser);
      analyserRef.current = analyser;
      const buf = new Uint8Array(analyser.frequencyBinCount);

      talkInterval.current = setInterval(() => {
        if (!analyserRef.current) return;
        analyserRef.current.getByteFrequencyData(buf);
        const avg = buf.reduce((s, v) => s + v, 0) / buf.length;
        if (avg > TALK_THRESHOLD) {
          setTalkingUserId(user.user_id);
          clearTimeout(talkStopTimer.current);
          talkStopTimer.current = setTimeout(() => setTalkingUserId(null), 1500);
          const sesh = sessionsRef.current.find(s => s.id === sessionId);
          const others = (sesh?.participants || []).filter(id => id !== user.user_id);
          if (others.length && wsRef.current?.readyState === 1) {
            wsRef.current.send(JSON.stringify({ type: 'talking', from_user: user.user_id, to_users: others, session_id: sessionId }));
          }
        }
      }, 200);
    }

    const existingParticipants = (sessionsRef.current.find(s => s.id === sessionId)?.participants || [])
      .filter(id => id !== user.user_id);

    setActiveSessionId(sessionId);

    if (existingParticipants.length && wsRef.current?.readyState === 1) {
      wsRef.current.send(JSON.stringify({
        type: 'session-joined',
        from_user: user.user_id,
        to_users: existingParticipants,
        session_id: sessionId,
      }));
    }

    for (const peerId of existingParticipants) {
      await initPeer.current(peerId, sessionId, true);
    }

    await loadSessions();
  }, [user, wsRef, loadSessions]);

  // ── Leave ─────────────────────────────────────────────────────────────────

  const leaveSession = useCallback(async () => {
    const sessionId = activeIdRef.current;
    if (!sessionId || !user) return;

    clearInterval(talkInterval.current);
    clearTimeout(talkStopTimer.current);
    talkInterval.current = null;
    analyserRef.current = null;

    if (localStream.current) {
      localStream.current.getTracks().forEach(t => t.stop());
      localStream.current = null;
    }

    for (const pc of Object.values(peerConns.current)) pc.close();
    peerConns.current = {};

    const others = (sessionsRef.current.find(s => s.id === sessionId)?.participants || [])
      .filter(id => id !== user.user_id);
    if (others.length && wsRef.current?.readyState === 1) {
      wsRef.current.send(JSON.stringify({ type: 'session-left', from_user: user.user_id, to_users: others, session_id: sessionId }));
    }

    try {
      await fetch(`${API}/devotions/leave?user_id=${encodeURIComponent(user.user_id)}&session_id=${encodeURIComponent(sessionId)}`, { method: 'POST' });
    } catch {}

    setActiveSessionId(null);
    setTalkingUserId(null);
    await loadSessions();
  }, [user, wsRef, loadSessions]);

  // ── Signal handler ────────────────────────────────────────────────────────

  const handleSignal = useCallback(async (payload) => {
    const { type, from_user, sdp, candidate, session_id } = payload;
    const activeId = activeIdRef.current;

    if (type === 'session-created') {
      await loadSessions();
      return;
    }

    if (!activeId) return;

    if (type === 'session-joined' && session_id === activeId) {
      await initPeer.current(from_user, activeId, true);
    } else if (type === 'offer' && session_id === activeId) {
      await initPeer.current(from_user, activeId, false);
      const pc = peerConns.current[from_user];
      if (!pc) return;
      await pc.setRemoteDescription({ type: 'offer', sdp });
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      if (wsRef.current?.readyState === 1) {
        wsRef.current.send(JSON.stringify({
          type: 'answer',
          from_user: user.user_id,
          to_users: [from_user],
          sdp: answer.sdp,
          session_id: activeId,
        }));
      }
    } else if (type === 'answer') {
      const pc = peerConns.current[from_user];
      if (pc) await pc.setRemoteDescription({ type: 'answer', sdp });
    } else if (type === 'ice-candidate') {
      const pc = peerConns.current[from_user];
      if (pc && candidate) await pc.addIceCandidate(candidate);
    } else if (type === 'talking') {
      setTalkingUserId(from_user);
      clearTimeout(talkStopTimer.current);
      talkStopTimer.current = setTimeout(() => setTalkingUserId(null), 1500);
    } else if (type === 'session-left') {
      const pc = peerConns.current[from_user];
      if (pc) { pc.close(); delete peerConns.current[from_user]; }
      await loadSessions();
    }
  }, [user, wsRef, loadSessions]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Cleanup ───────────────────────────────────────────────────────────────

  useEffect(() => {
    return () => {
      clearInterval(talkInterval.current);
      clearTimeout(talkStopTimer.current);
      if (localStream.current) localStream.current.getTracks().forEach(t => t.stop());
      for (const pc of Object.values(peerConns.current)) pc.close();
    };
  }, []);

  return {
    sessions, activeSessionId, talkingUserId,
    showCreator, editingSession,
    openCreator, closeCreator,
    loadSessions, createSession, updateSession, deleteSession,
    joinSession, leaveSession,
    handleSignal,
  };
}
