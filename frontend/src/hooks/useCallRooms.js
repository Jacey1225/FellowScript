import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import * as roomsApi from '../lib/sessionRoomsApi.js';
import {
  MAIN_STATE, ROOM_COPY, HEARTBEAT_INTERVAL_MS,
  beginJoin, beginReturn, returnFailed, isBusy, showsBackToMain, stateRoomId, stateRoomName,
  heartbeatOutcome, isMainEnded, roomMessage, roomErrorMessage,
} from '../lib/callRoomState.js';

// Task 20261011-web-session-screenshare-rooms (step 2). Web port of iOS
// CallRoomController: owns the room-switch state machine and the heartbeat.
// It knows nothing about the Chime SDK; the media swap and the "fetch a fresh
// main meeting" step are injected by useSessions.
//
// Rules carried over from iOS:
//  * Network first, teardown second: the backend join (or the main-meeting
//    fetch) is awaited BEFORE the current meeting is touched, so a failure
//    leaves the user exactly where they were.
//  * Heartbeat failures never eject a user; only the server's explicit
//    "room is gone" / "main is gone" answers do.
//  * Best-effort room leave on every exit; a failed leave never blocks.
//  * Nothing is logged: no ids, tokens or response bodies.

const NOTICE_MS = 6000;

export function useCallRooms({ user, sessionId, switchMeeting, fetchMainMeeting, onMainEnded }) {
  const [state, setState] = useState(MAIN_STATE);
  const [notice, setNotice] = useState(null);
  const [announcement, setAnnouncement] = useState('');
  const [currentRoom, setCurrentRoom] = useState(null);
  const [seedNames, setSeedNames] = useState({});

  const stateRef = useRef(MAIN_STATE);
  const activeRoomRef = useRef(null);
  const currentRoomRef = useRef(null);
  const sessionRef = useRef(sessionId);
  const userIdRef = useRef(user?.user_id || null);
  const cbRef = useRef({});
  const noticeTimer = useRef(null);

  sessionRef.current = sessionId;
  userIdRef.current = user?.user_id || null;
  cbRef.current = { switchMeeting, fetchMainMeeting, onMainEnded };

  const setSt = useCallback((next) => { stateRef.current = next; setState(next); }, []);
  const setRoom = useCallback((room) => { currentRoomRef.current = room; setCurrentRoom(room); }, []);
  const announce = useCallback((text) => setAnnouncement(text), []);

  const showNotice = useCallback((text) => {
    setNotice(text);
    clearTimeout(noticeTimer.current);
    noticeTimer.current = setTimeout(() => setNotice(n => (n === text ? null : n)), NOTICE_MS);
  }, []);
  const clearNotice = useCallback(() => { clearTimeout(noticeTimer.current); setNotice(null); }, []);

  const leaveQuietly = useCallback((roomId) => {
    const uid = userIdRef.current;
    if (!roomId || !uid) return;
    roomsApi.leaveRoom(uid, roomId).catch(() => { /* best effort: the sweeper frees stale seats */ });
  }, []);

  // ── Call teardown ─────────────────────────────────────────────────────────
  const callEnded = useCallback(() => {
    leaveQuietly(activeRoomRef.current);
    activeRoomRef.current = null;
    clearTimeout(noticeTimer.current);
    setSt(MAIN_STATE);
    setRoom(null);
    setNotice(null);
    setSeedNames({});
    setAnnouncement('');
  }, [leaveQuietly, setSt, setRoom]);

  // The call went away (leave, main ended, unmount): reset and leave the room.
  useEffect(() => {
    if (!sessionId && (activeRoomRef.current || stateRef.current.kind !== 'main')) callEnded();
  }, [sessionId, callEnded]);

  useEffect(() => () => {
    clearTimeout(noticeTimer.current);
    leaveQuietly(activeRoomRef.current);
  }, [leaveQuietly]);

  const mainEnded = useCallback(() => {
    showNotice(ROOM_COPY.mainEnded);
    cbRef.current.onMainEnded?.();
  }, [showNotice]);

  // ── Back to main ──────────────────────────────────────────────────────────
  // Returns true when the user is back in the main meeting.
  const returnToMain = useCallback(async () => {
    const s = stateRef.current;
    const uid = userIdRef.current;
    const sid = sessionRef.current;
    if (!showsBackToMain(s) || s.kind === 'returning' || !uid || !sid) return false;
    const roomId = activeRoomRef.current;
    setSt(beginReturn(s));
    try {
      const main = await cbRef.current.fetchMainMeeting(sid);            // network first
      if (sessionRef.current !== sid) return false;                       // call ended meanwhile
      await cbRef.current.switchMeeting(main.Meeting, main.Attendee, { room: false });
      if (sessionRef.current !== sid) return false;
      activeRoomRef.current = null;
      setSt(MAIN_STATE);
      setRoom(null);
      leaveQuietly(roomId);
      announce('Back in the main session');
      return true;
    } catch {
      if (sessionRef.current === sid) {
        setSt(returnFailed(stateRef.current));
        showNotice(ROOM_COPY.returnFailed);
        announce(ROOM_COPY.returnFailed);
      }
      return false;
    }
  }, [setSt, setRoom, leaveQuietly, announce, showNotice]);

  const roomGone = useCallback(async (fallbackName) => {
    const name = stateRoomName(stateRef.current) || fallbackName || 'The room';
    announce(`${name} has ended, returning to the main session`);
    if (stateRef.current.kind === 'returning') return;
    const back = await returnToMain();
    if (back) showNotice(ROOM_COPY.roomEnded(name));
  }, [announce, returnToMain, showNotice]);

  // ── Join / switch ─────────────────────────────────────────────────────────
  // Resolves to a warm error message on failure, null on success. On a backend
  // failure nothing was torn down and the user stays where they were.
  const join = useCallback(async (room) => {
    const uid = userIdRef.current;
    const sid = sessionRef.current;
    if (!uid || !sid || isBusy(stateRef.current)) return roomMessage('busy', 'join');
    if (stateRoomId(stateRef.current) === room.id) return null;
    const previous = stateRef.current;
    setSt(beginJoin(previous, room.id, room.displayName));
    let resp;
    try {
      resp = await roomsApi.joinRoom(uid, room.id);
    } catch (err) {
      setSt(previous);
      if (isMainEnded(err)) { mainEnded(); return ROOM_COPY.mainEnded; }
      const text = roomErrorMessage(err, 'join');
      announce(text);
      return text;
    }
    if (sessionRef.current !== sid) { leaveQuietly(room.id); return null; }
    try {
      await cbRef.current.switchMeeting(resp.Meeting, resp.Attendee, { room: true });
    } catch {
      // The media swap failed after the old meeting was torn down: we are in
      // neither call. Offer Back to main (Try again) rather than pretending.
      leaveQuietly(room.id);
      if (sessionRef.current === sid) {
        setSt({ kind: 'returnFailed', name: room.displayName });
        showNotice(ROOM_COPY.returnFailed);
      }
      return roomMessage('chime_error', 'join');
    }
    if (sessionRef.current !== sid) { leaveQuietly(room.id); return null; }
    activeRoomRef.current = room.id;
    setRoom(resp.room);
    setSt({ kind: 'inRoom', roomId: room.id, name: resp.room.displayName });
    setSeedNames(Object.fromEntries(resp.room.members.map(m => [m.user_id, m.username]).filter(([, n]) => n)));
    announce(`Joined ${resp.room.displayName}`);
    return null;
  }, [setSt, setRoom, announce, leaveQuietly, mainEnded, showNotice]);

  // ── Heartbeat ─────────────────────────────────────────────────────────────
  const beat = useCallback(async () => {
    const uid = userIdRef.current;
    const roomId = activeRoomRef.current;
    if (!uid || !roomId || !showsBackToMain(stateRef.current)) return;
    try {
      await roomsApi.heartbeatRoom(uid, roomId);
    } catch (err) {
      const outcome = heartbeatOutcome(err);
      if (outcome === 'mainEnded') mainEnded();
      else if (outcome === 'roomGone') await roomGone(currentRoomRef.current?.displayName);
    }
  }, [mainEnded, roomGone]);

  const away = showsBackToMain(state);
  useEffect(() => {
    if (!away) return undefined;
    const id = setInterval(beat, HEARTBEAT_INTERVAL_MS);
    const onVisible = () => { if (document.visibilityState === 'visible') beat(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => { clearInterval(id); document.removeEventListener('visibilitychange', onVisible); };
  }, [away, beat]);

  // ── Management used by the panel ──────────────────────────────────────────
  const noteRoomsList = useCallback((list) => {
    const id = activeRoomRef.current;
    const mine = id && list.rooms.find(r => r.id === id);
    if (mine) setRoom(mine);
  }, [setRoom]);

  const didEndRoom = useCallback(async (id) => {
    if (id && id === activeRoomRef.current) await roomGone(currentRoomRef.current?.displayName);
  }, [roomGone]);

  return useMemo(() => ({
    state, notice, announcement, currentRoom, seedNames,
    inRoom: away,
    join, returnToMain, noteRoomsList, didEndRoom, clearNotice, showNotice, callEnded, mainEnded,
  }), [state, notice, announcement, currentRoom, seedNames, away,
    join, returnToMain, noteRoomsList, didEndRoom, clearNotice, showNotice, callEnded, mainEnded]);
}
