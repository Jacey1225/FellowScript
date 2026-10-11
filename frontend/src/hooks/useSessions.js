import { useState, useRef, useCallback, useEffect } from 'react';
import {
  ConsoleLogger,
  DefaultDeviceController,
  DefaultMeetingSession,
  LogLevel,
  MeetingSessionConfiguration,
} from 'amazon-chime-sdk-js';
import { message } from 'antd';
import { handleBlockedResponse } from '../lib/upgradePrompt.js';
import { API } from '../config.js';
import {
  SCREEN_SHARE_COPY, classifyCaptureError, contentOwnerId, isDisplayCaptureSupported,
} from '../lib/screenShareState.js';
import { useCallRooms } from './useCallRooms.js';

const SHARE_NOTICE_MS = 6000;

// For 1-on-1 friend chats the two users each see the other as currentContact,
// so contact.id differs per side. Sorting both IDs gives a stable shared key.
function roomKey(contact, userId) {
  if (!contact) return null;
  if (contact.type === 'friend') return [userId, contact.id].sort().join('|');
  return contact.id;
}

export function useSessions({ user, wsRef, currentContact }) {
  const [sessions,        setSessions]        = useState([]);
  const [activeSessionId, setActiveSessionId] = useState(null);
  const [talkingUserId,   setTalkingUserId]   = useState(null);
  const [showCreator,     setShowCreator]     = useState(false);
  const [editingSession,  setEditingSession]  = useState(null);
  const [videoEnabled,    setVideoEnabled]    = useState(false);
  const [videoTiles,      setVideoTiles]      = useState([]);
  const [muted,           setMuted]           = useState(false);
  // { sessionId, message } for the call-join failure this session most
  // recently hit, or null. Chime call-join used to fail completely
  // silently on a meeting-creation or attendee-token fetch error (no
  // error, no retry, no signal) -- this surfaces an explicit, retryable
  // error state instead, matching the already-fixed iOS
  // CallController.joinError behavior (Architecture Q27: propagate
  // failures upward rather than silently substituting a default).
  const [joinError,       setJoinError]       = useState(null);
  // Screen share (task 20261011-web-session-screenshare-rooms). sharePhase is
  // MY outgoing share: 'idle' | 'starting' | 'sharing'. contentTile is someone
  // ELSE's incoming share ({ tileId, sharerId }); my own content tile is never
  // rendered. shareNotice is a warm, self-dismissing fail-soft message.
  const [sharePhase,      setSharePhase]      = useState('idle');
  const [contentTile,     setContentTile]     = useState(null);
  const [shareNotice,     setShareNotice]     = useState(null);
  // External user ids present in the CURRENT Chime meeting (drives the room
  // bubbles; the main session uses the server participant list instead).
  const [meetingPresence, setMeetingPresence] = useState([]);

  const sessionsRef       = useRef([]);
  const activeIdRef       = useRef(null);
  const currentContactRef = useRef(currentContact);
  const chimeSession      = useRef(null);   // DefaultMeetingSession instance
  const chimeAudioEl      = useRef(null);   // <audio> element Chime binds to
  const talkStopTimer     = useRef(null);
  const chimeObserverRef  = useRef(null);
  const videoEnabledRef   = useRef(false);
  const mutedRef          = useRef(false);
  const sharePhaseRef     = useRef('idle');
  const shareAttemptRef   = useRef(0);      // bumps on every start/end so stale async work bails
  const screenStreamRef   = useRef(null);   // MediaStream from getDisplayMedia
  const contentObserverRef = useRef(null);
  const presenceCbRef     = useRef(null);
  const shareNoticeTimer  = useRef(null);
  const contentTileRef    = useRef(null);
  const leaveSessionRef   = useRef(null);

  useEffect(() => { sessionsRef.current = sessions; },           [sessions]);
  useEffect(() => { activeIdRef.current = activeSessionId; },    [activeSessionId]);
  useEffect(() => { currentContactRef.current = currentContact; }, [currentContact]);
  useEffect(() => { videoEnabledRef.current = videoEnabled; },   [videoEnabled]);
  useEffect(() => { mutedRef.current = muted; },                 [muted]);
  useEffect(() => { contentTileRef.current = contentTile; },     [contentTile]);

  const loadSessionsRef = useRef(null);

  // ── Creator open/close ────────────────────────────────────────────────────

  const openCreator = useCallback((session = null) => {
    setEditingSession(session || null);
    setShowCreator(true);
  }, []);

  const closeCreator = useCallback(() => {
    setEditingSession(null);
    setShowCreator(false);
  }, []);

  // ── Mute (client-only; no endpoint) ───────────────────────────────────────
  const toggleMute = useCallback(() => {
    const av = chimeSession.current?.audioVideo;
    if (!av) return;
    try {
      if (mutedRef.current) {
        av.realtimeUnmuteLocalAudio();
        setMuted(false);
      } else {
        av.realtimeMuteLocalAudio();
        setMuted(true);
      }
    } catch (err) {
      console.error('Failed to toggle microphone mute:', err);
    }
  }, []);

  // ── Video ─────────────────────────────────────────────────────────────────

  const toggleVideo = useCallback(async () => {
    if (!chimeSession.current) return;
    if (videoEnabledRef.current) {
      chimeSession.current.audioVideo.stopLocalVideoTile();
      try {
        await chimeSession.current.audioVideo.stopVideoInput();
      } catch (err) {
        console.error('Failed to stop video input:', err);
      }
      setVideoEnabled(false);
    } else {
      try {
        const inputs = await chimeSession.current.audioVideo.listVideoInputDevices();
        if (!inputs.length) {
          message.error('No camera found. Please connect one and try again.');
          return;
        }
        await chimeSession.current.audioVideo.startVideoInput(inputs[0].deviceId);
        chimeSession.current.audioVideo.startLocalVideoTile();
        setVideoEnabled(true);
      } catch (err) {
        console.error('Failed to start video input:', err);
        message.error('Could not start your camera. Check permissions and try again.');
      }
    }
  }, []);

  const bindVideoTile = useCallback((tileId, el) => {
    if (!chimeSession.current || !el) return;
    chimeSession.current.audioVideo.bindVideoElement(tileId, el);
  }, []);

  // ── Screen share (Chime content share) ────────────────────────────────────
  // Sending uses getDisplayMedia on an explicit user click only, then
  // audioVideo.startContentShare(stream). Every exit path (Stop, picker
  // cancelled, OS "stop sharing", Chime stop, leave, room switch, unmount)
  // funnels through endScreenShare/releaseScreenStream, which stop every
  // captured track.

  const setPhase = useCallback((phase) => {
    sharePhaseRef.current = phase;
    setSharePhase(phase);
  }, []);

  const postShareNotice = useCallback((text) => {
    setShareNotice(text);
    clearTimeout(shareNoticeTimer.current);
    shareNoticeTimer.current = setTimeout(() => setShareNotice(n => (n === text ? null : n)), SHARE_NOTICE_MS);
  }, []);

  const clearShareNotice = useCallback(() => {
    clearTimeout(shareNoticeTimer.current);
    setShareNotice(null);
  }, []);

  const releaseScreenStream = useCallback(() => {
    const stream = screenStreamRef.current;
    screenStreamRef.current = null;
    if (!stream) return;
    stream.getTracks().forEach(track => {
      track.onended = null;
      try { track.stop(); } catch (err) { console.error('Failed to stop a screen capture track:', err); }
    });
  }, []);

  // Ends MY share on any path. Phase is set idle BEFORE stopContentShare so the
  // Chime observer's contentShareDidStop does not announce a second time.
  const endScreenShare = useCallback(({ notice } = {}) => {
    shareAttemptRef.current += 1;
    const wasActive = sharePhaseRef.current !== 'idle';
    const hadStream = !!screenStreamRef.current;
    releaseScreenStream();
    setPhase('idle');
    if (wasActive || hadStream) {
      try { chimeSession.current?.audioVideo.stopContentShare(); } catch (err) { console.error('Failed to stop the content share:', err); }
    }
    if (notice && wasActive) postShareNotice(notice);
  }, [releaseScreenStream, setPhase, postShareNotice]);

  const stopScreenShare = useCallback(() => endScreenShare(), [endScreenShare]);

  const startScreenShare = useCallback(async () => {
    const av = chimeSession.current?.audioVideo;
    if (!av || sharePhaseRef.current !== 'idle') return { ok: false, reason: 'busy' };
    if (contentTileRef.current) {
      postShareNotice(SCREEN_SHARE_COPY.someoneElse);
      return { ok: false, reason: 'someoneElse' };
    }
    if (!isDisplayCaptureSupported()) {
      postShareNotice(SCREEN_SHARE_COPY.couldNotStart);
      return { ok: false, reason: 'unsupported' };
    }
    const attempt = ++shareAttemptRef.current;
    setPhase('starting');
    let stream;
    try {
      // Requested only here, from a direct click on the Share screen row.
      stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false });
    } catch (err) {
      if (shareAttemptRef.current === attempt) {
        setPhase('idle');
        postShareNotice(classifyCaptureError(err) === 'cancelled'
          ? SCREEN_SHARE_COPY.notStarted : SCREEN_SHARE_COPY.couldNotStart);
      }
      return { ok: false, reason: classifyCaptureError(err) };
    }
    // The call ended or another start/stop happened while the picker was open.
    if (shareAttemptRef.current !== attempt || chimeSession.current?.audioVideo !== av) {
      stream.getTracks().forEach(t => { try { t.stop(); } catch (err) { console.error('Failed to stop a screen capture track:', err); } });
      return { ok: false, reason: 'cancelled' };
    }
    screenStreamRef.current = stream;
    // OS or browser "Stop sharing" ends the track: tear everything down.
    stream.getTracks().forEach(track => {
      track.onended = () => {
        if (screenStreamRef.current === stream) endScreenShare({ notice: SCREEN_SHARE_COPY.ended });
      };
    });
    try {
      await av.startContentShare(stream);
    } catch (err) {
      console.error('Failed to start the content share:', err);
      if (shareAttemptRef.current === attempt) {
        releaseScreenStream();
        setPhase('idle');
        postShareNotice(SCREEN_SHARE_COPY.couldNotStart);
      }
      return { ok: false, reason: 'failed' };
    }
    if (shareAttemptRef.current !== attempt) return { ok: false, reason: 'cancelled' };
    setPhase('sharing');
    return { ok: true };
  }, [endScreenShare, releaseScreenStream, setPhase, postShareNotice]);

  // ── Meeting lifecycle (shared by join, room switch and leave) ─────────────

  // Builds and starts a Chime meeting session from Meeting/Attendee data.
  // `broadcastTalking` is true for the main session only: a room must not
  // light up the "talking" indicator for people in the main session.
  const startMeeting = useCallback(async (meetingData, attendeeData, { sessionId, broadcastTalking }) => {
    // 4. Build the Chime meeting session
    const logger           = new ConsoleLogger('FellowScript', LogLevel.WARN);
    const deviceController = new DefaultDeviceController(logger);
    const config           = new MeetingSessionConfiguration(meetingData, attendeeData);
    const session          = new DefaultMeetingSession(config, logger, deviceController);
    chimeSession.current   = session;

    // 5. Select default mic input
    try {
      const inputs = await session.audioVideo.listAudioInputDevices();
      if (inputs.length) await session.audioVideo.startAudioInput(inputs[0].deviceId);
    } catch (err) {
      // Non-fatal -- the call still starts without a preferred mic selected.
      console.error('Failed to select a default microphone:', err);
    }

    // 6. Bind a hidden <audio> element for speaker output
    if (!chimeAudioEl.current) {
      chimeAudioEl.current = document.createElement('audio');
      document.body.appendChild(chimeAudioEl.current);
    }
    session.audioVideo.bindAudioElement(chimeAudioEl.current);

    // 7. Subscribe to volume indicator to drive the "talking" UI
    session.audioVideo.realtimeSubscribeToVolumeIndicator(
      attendeeData.AttendeeId,
      (attId, volume) => {
        if (volume !== null && volume > 0) {
          setTalkingUserId(user.user_id);
          clearTimeout(talkStopTimer.current);
          talkStopTimer.current = setTimeout(() => setTalkingUserId(null), 1500);

          // Broadcast to others so their UI shows the talking indicator too
          if (!broadcastTalking) return;
          const sesh   = sessionsRef.current.find(s => s.id === sessionId);
          const others = (sesh?.participants || []).filter(id => id !== user.user_id);
          if (others.length && wsRef.current?.readyState === 1) {
            wsRef.current.send(JSON.stringify({
              type: 'talking', from_user: user.user_id, to_users: others, session_id: sessionId,
            }));
          }
        }
      }
    );

    // Who is in THIS meeting (external user id == user_id). Content attendees
    // ("<id>#content") are not people and are skipped.
    const presenceCb = (attendeeId, present, externalUserId) => {
      if (typeof externalUserId !== 'string' || !externalUserId || externalUserId.endsWith('#content')) return;
      setMeetingPresence(prev => {
        const has = prev.includes(externalUserId);
        if (present) return has ? prev : [...prev, externalUserId];
        return has ? prev.filter(id => id !== externalUserId) : prev;
      });
    };
    presenceCbRef.current = presenceCb;
    session.audioVideo.realtimeSubscribeToAttendeeIdPresence(presenceCb);

    // 8. Start the Chime audio/video session
    session.audioVideo.start();

    // 9. Observe video tile lifecycle so the UI can render remote cameras and
    //    an incoming content share
    const observer = {
      videoTileDidUpdate: (tileState) => {
        if (!tileState.boundAttendeeId) return;
        if (tileState.isContent) {
          // My own content tile is never rendered (no hall of mirrors); the
          // UI shows "You are sharing your screen" instead.
          const owner = contentOwnerId(tileState.boundExternalUserId);
          if (tileState.localTile || !owner || owner === user.user_id) return;
          setContentTile(prev => (
            prev && prev.tileId === tileState.tileId && prev.sharerId === owner
              ? prev : { tileId: tileState.tileId, sharerId: owner }
          ));
          return;
        }
        setVideoTiles(prev => {
          if (prev.some(t => t.tileId === tileState.tileId)) return prev;
          return [...prev, {
            tileId:  tileState.tileId,
            isLocal: tileState.localTile,
            userId:  tileState.boundExternalUserId || '',
          }];
        });
      },
      videoTileWasRemoved: (tileId) => {
        setContentTile(prev => (prev && prev.tileId === tileId ? null : prev));
        setVideoTiles(prev => prev.filter(t => t.tileId !== tileId));
      },
    };
    chimeObserverRef.current = observer;
    session.audioVideo.addObserver(observer);

    const contentObserver = {
      contentShareDidStart: () => {
        if (sharePhaseRef.current === 'starting') setPhase('sharing');
      },
      contentShareDidStop: () => {
        // Already idle when the user stopped it ourselves; otherwise Chime
        // ended it (network, policy): fail soft and clean up.
        if (sharePhaseRef.current === 'idle') return;
        endScreenShare({ notice: SCREEN_SHARE_COPY.failedMidShare });
      },
    };
    contentObserverRef.current = contentObserver;
    session.audioVideo.addContentShareObserver(contentObserver);
  }, [user, wsRef, setPhase, endScreenShare]);

  // Tears down the current Chime meeting and everything bound to it. Used by
  // leave and by room switches. Never throws.
  const teardownMeeting = useCallback(async () => {
    clearTimeout(talkStopTimer.current);
    endScreenShare();

    // Stop video if active. These are hardware-teardown calls on a session
    // that's being discarded either way -- log for a trail, but there's
    // nothing actionable left to surface to the user.
    if (videoEnabledRef.current && chimeSession.current) {
      try { chimeSession.current.audioVideo.stopLocalVideoTile(); } catch (err) { console.error('Failed to stop local video tile on leave:', err); }
      try { await chimeSession.current.audioVideo.stopVideoInput(); } catch (err) { console.error('Failed to stop video input on leave:', err); }
    }

    // Remove tile/content/presence observers and reset per-meeting state
    if (chimeSession.current) {
      const av = chimeSession.current.audioVideo;
      if (chimeObserverRef.current) {
        try { av.removeObserver(chimeObserverRef.current); } catch (err) { console.error('Failed to remove video observer on leave:', err); }
      }
      if (contentObserverRef.current) {
        try { av.removeContentShareObserver(contentObserverRef.current); } catch (err) { console.error('Failed to remove content share observer on leave:', err); }
      }
      if (presenceCbRef.current) {
        try { av.realtimeUnsubscribeToAttendeeIdPresence(presenceCbRef.current); } catch (err) { console.error('Failed to remove presence subscription on leave:', err); }
      }
    }
    chimeObserverRef.current = null;
    contentObserverRef.current = null;
    presenceCbRef.current = null;
    setVideoEnabled(false);
    setVideoTiles([]);
    setContentTile(null);
    setMeetingPresence([]);
    setMuted(false);

    // Stop the Chime session
    if (chimeSession.current) {
      try { chimeSession.current.audioVideo.stop(); } catch (err) { console.error('Failed to stop Chime audio/video on leave:', err); }
      chimeSession.current = null;
    }
    if (chimeAudioEl.current) {
      chimeAudioEl.current.srcObject = null;
      chimeAudioEl.current.remove();
      chimeAudioEl.current = null;
    }
  }, [endScreenShare]);

  // Fresh MAIN meeting + attendee (same endpoints as joinSession). Throws on
  // any failure; callers decide the copy (throw-not-fabricate).
  const fetchMainMeeting = useCallback(async (sessionId) => {
    if (!user) throw new Error('not signed in');
    const meetingRes = await fetch(`${API}/chime/${encodeURIComponent(sessionId)}`, { method: 'POST' });
    if (!meetingRes.ok) throw new Error('meeting');
    const Meeting = (await meetingRes.json()).Meeting;
    const attendeeRes = await fetch(
      `${API}/chime/${encodeURIComponent(sessionId)}/${encodeURIComponent(user.user_id)}/attend`,
      { method: 'POST' }
    );
    if (!attendeeRes.ok) throw new Error('attendee');
    const Attendee = (await attendeeRes.json()).Attendee;
    if (!Meeting || !Attendee) throw new Error('shape');
    return { Meeting, Attendee };
  }, [user]);

  // Swaps the audio/video meeting under the SAME main session (rooms): the
  // main session id, participant list and call card stay put. A share is
  // stopped (tracks released) first; mute is carried over.
  const switchMeeting = useCallback(async (meeting, attendee, { room = false } = {}) => {
    const sessionId = activeIdRef.current;
    if (!sessionId || !user) throw new Error('no active call');
    const wasMuted = mutedRef.current;
    if (sharePhaseRef.current !== 'idle') endScreenShare({ notice: SCREEN_SHARE_COPY.changedRooms });
    await teardownMeeting();
    await startMeeting(meeting, attendee, { sessionId, broadcastTalking: !room });
    if (wasMuted) {
      try {
        chimeSession.current?.audioVideo.realtimeMuteLocalAudio();
        setMuted(true);
      } catch (err) {
        console.error('Failed to keep the microphone muted after switching:', err);
      }
    }
  }, [user, endScreenShare, teardownMeeting, startMeeting]);

  // ── Load ──────────────────────────────────────────────────────────────────

  const loadSessions = useCallback(async (contactOverride) => {
    const contact = (contactOverride && typeof contactOverride === 'object')
      ? contactOverride
      : currentContact;
    const contactId = roomKey(contact, user?.user_id);
    if (!user || !contactId) return;
    try {
      const res = await fetch(`${API}/devotions/contact/${encodeURIComponent(contactId)}`);
      if (res.ok) setSessions((await res.json()).sessions || []);
    } catch (err) {
      // Background refresh -- log only, matching useMessaging.loadContacts'
      // established convention for passive/background loads.
      console.error('Failed to load sessions:', err);
    }
  }, [user, currentContact]);

  useEffect(() => { loadSessionsRef.current = loadSessions; }, [loadSessions]);

  useEffect(() => {
    if (currentContact) loadSessions();
    else setSessions([]);
  }, [currentContact]);

  useEffect(() => {
    const TWELVE_HOURS = 12 * 60 * 60 * 1000;
    let hiddenAt = null;
    const handleVisibility = () => {
      if (document.visibilityState === 'hidden') {
        hiddenAt = Date.now();
      } else if (document.visibilityState === 'visible' && hiddenAt) {
        if (Date.now() - hiddenAt >= TWELVE_HOURS) loadSessionsRef.current?.();
        hiddenAt = null;
      }
    };
    document.addEventListener('visibilitychange', handleVisibility);
    return () => document.removeEventListener('visibilitychange', handleVisibility);
  }, []);

  // ── Create ────────────────────────────────────────────────────────────────

  const createSession = useCallback(async ({ title, timeStart, timeEnd, verses, prompts = [], recurring = false, summarize = false }) => {
    if (!user || !currentContact) return false;
    const gid = roomKey(currentContact, user.user_id);
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
            group_id: gid,
            creator_id: user.user_id,
            participants: [],
            verses,
            prompts,
            recurring,
            summarize,
          },
        }),
      });
      if (!res.ok) {
        if (await handleBlockedResponse(res)) return false;
        message.error('Could not create that session. Please try again.');
        return false;
      }
      const { id } = await res.json();
      const others = (currentContact.toUsers || []).filter(uid => uid !== user.user_id);
      if (others.length && wsRef.current?.readyState === 1) {
        wsRef.current.send(JSON.stringify({
          type: 'session-created',
          from_user: user.user_id,
          to_users: others,
          session_id: id,
          group_id: gid,
        }));
      }
      await loadSessions();
      return true;
    } catch (err) {
      console.error('Failed to create session:', err);
      message.error('Could not create that session. Check your connection and try again.');
      return false;
    }
  }, [user, currentContact, wsRef, loadSessions]);

  // ── Update ────────────────────────────────────────────────────────────────

  const updateSession = useCallback(async (sessionId, { title, timeStart, timeEnd, verses, prompts = [], recurring = false, summarize = false }) => {
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
            prompts,
            recurring,
            summarize,
          },
        }),
      });
      if (!res.ok) {
        // Same shared upgrade modal as create, in case the server plan-gates an edit.
        if (await handleBlockedResponse(res)) return false;
        message.error('Could not update that session. Please try again.');
        return false;
      }
      await loadSessions();
      return true;
    } catch (err) {
      console.error('Failed to update session:', err);
      message.error('Could not update that session. Check your connection and try again.');
      return false;
    }
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
      if (!res.ok) {
        message.error('Could not delete that session. Please try again.');
        return false;
      }
      await loadSessions();
      return true;
    } catch (err) {
      console.error('Failed to delete session:', err);
      message.error('Could not delete that session. Check your connection and try again.');
      return false;
    }
  }, [user, loadSessions]);

  // ── Join ──────────────────────────────────────────────────────────────────

  const joinSession = useCallback(async (sessionId) => {
    if (!user || activeIdRef.current) return;

    // Clear any stale error from a previous failed attempt so a retry
    // starts clean (mirrors CallController.start() resetting joinError).
    setJoinError(null);

    // 1. Add user to participants list on the backend
    try {
      await fetch(
        `${API}/devotions/join?user_id=${encodeURIComponent(user.user_id)}&session_id=${encodeURIComponent(sessionId)}`,
        { method: 'POST' }
      );
    } catch (err) {
      // Non-fatal to the call itself -- the join proceeds either way -- but
      // still worth a trail if participant lists start looking wrong.
      console.error('Failed to record session join on the backend:', err);
    }

    // 2. Get or create the Chime meeting for this session
    let meetingData, attendeeData;
    try {
      const meetingRes = await fetch(`${API}/chime/${encodeURIComponent(sessionId)}`, { method: 'POST' });
      if (!meetingRes.ok) {
        setJoinError({ sessionId, message: 'Could not start the call. Please try again.' });
        return;
      }
      meetingData = (await meetingRes.json()).Meeting;
    } catch (err) {
      console.error('Failed to create Chime meeting:', err);
      setJoinError({ sessionId, message: 'Could not reach the server to start the call.' });
      return;
    }

    // 3. Create an attendee token for this user
    try {
      const attendeeRes = await fetch(
        `${API}/chime/${encodeURIComponent(sessionId)}/${encodeURIComponent(user.user_id)}/attend`,
        { method: 'POST' }
      );
      if (!attendeeRes.ok) {
        setJoinError({ sessionId, message: 'Could not join the call. Please try again.' });
        return;
      }
      attendeeData = (await attendeeRes.json()).Attendee;
    } catch (err) {
      console.error('Failed to create Chime attendee token:', err);
      setJoinError({ sessionId, message: 'Could not reach the server to join the call.' });
      return;
    }

    // 4-9. Build and start the Chime meeting session (shared with room switches)
    try {
      await startMeeting(meetingData, attendeeData, { sessionId, broadcastTalking: true });
    } catch (err) {
      // Same surface as the other join failures: explicit, retryable.
      console.error('Failed to start the Chime meeting session:', err);
      await teardownMeeting();
      setJoinError({ sessionId, message: 'Could not join the call. Please try again.' });
      return;
    }

    setActiveSessionId(sessionId);

    // 10. Fetch fresh session data and notify existing participants so their UI updates
    try {
      const contact   = currentContactRef.current;
      const contactId = roomKey(contact, user.user_id);
      if (contactId) {
        const res = await fetch(`${API}/devotions/contact/${encodeURIComponent(contactId)}`);
        if (res.ok) {
          const data  = await res.json();
          const sesh  = (data.sessions || []).find(s => s.id === sessionId);
          const others = (sesh?.participants || []).filter(id => id !== user.user_id);
          setSessions(data.sessions || []);
          if (others.length && wsRef.current?.readyState === 1) {
            wsRef.current.send(JSON.stringify({
              type: 'session-joined',
              from_user: user.user_id,
              to_users: others,
              session_id: sessionId,
            }));
          }
        }
      }
    } catch (err) {
      // Background refresh -- log only, matching the loadSessions convention.
      console.error('Failed to refresh session data after joining:', err);
    }
  }, [user, wsRef, startMeeting, teardownMeeting]);

  const clearJoinError = useCallback(() => setJoinError(null), []);

  // ── Leave ─────────────────────────────────────────────────────────────────

  const leaveSession = useCallback(async () => {
    const sessionId = activeIdRef.current;
    if (!sessionId || !user) return;

    // Stops any screen share (releasing capture tracks), video, observers and
    // the Chime session itself.
    await teardownMeeting();

    const others = (sessionsRef.current.find(s => s.id === sessionId)?.participants || [])
      .filter(id => id !== user.user_id);
    if (others.length && wsRef.current?.readyState === 1) {
      wsRef.current.send(JSON.stringify({
        type: 'session-left', from_user: user.user_id, to_users: others, session_id: sessionId,
      }));
    }

    try {
      await fetch(
        `${API}/devotions/leave?user_id=${encodeURIComponent(user.user_id)}&session_id=${encodeURIComponent(sessionId)}`,
        { method: 'POST' }
      );
    } catch (err) {
      // The call has already been torn down locally either way -- surface a
      // soft warning rather than blocking the user from continuing, but log
      // it since the backend's participant list may now be stale.
      console.error('Failed to notify the server of session leave:', err);
      message.warning("Left the call, but couldn't confirm it with the server.");
    }

    setActiveSessionId(null);
    setTalkingUserId(null);
    setJoinError(null);
    await loadSessions();
  }, [user, wsRef, loadSessions, teardownMeeting]);

  useEffect(() => { leaveSessionRef.current = leaveSession; }, [leaveSession]);

  // ── Discussion rooms (flag-gated in the UI; inert until a room is joined) ──
  const rooms = useCallRooms({
    user,
    sessionId: activeSessionId,
    switchMeeting,
    fetchMainMeeting,
    onMainEnded: () => leaveSessionRef.current?.(),
  });

  // ── Signal handler ────────────────────────────────────────────────────────
  // offer/answer/ice-candidate are gone — Chime handles all WebRTC internally.
  // These signals now only drive UI state (participant list, talking indicator).

  const handleSignal = useCallback(async (payload) => {
    const { type, from_user, session_id, group_id } = payload;

    if (type === 'session-created') {
      const localKey = roomKey(currentContact, user?.user_id);
      if (!group_id || !currentContact || group_id === localKey) {
        await loadSessions();
      }
      return;
    }

    if (type === 'session-joined' || type === 'session-left') {
      await loadSessions();
      return;
    }

    if (type === 'talking') {
      setTalkingUserId(from_user);
      clearTimeout(talkStopTimer.current);
      talkStopTimer.current = setTimeout(() => setTalkingUserId(null), 1500);
    }
  }, [user, currentContact, loadSessions]);

  // ── Cleanup ───────────────────────────────────────────────────────────────

  useEffect(() => {
    return () => {
      clearTimeout(talkStopTimer.current);
      clearTimeout(shareNoticeTimer.current);
      // Never leave the screen capture running after the hook goes away.
      const stream = screenStreamRef.current;
      screenStreamRef.current = null;
      if (stream) stream.getTracks().forEach(t => { try { t.onended = null; t.stop(); } catch (err) { console.error('Failed to stop a screen capture track on unmount:', err); } });
      if (chimeSession.current) {
        // Component is unmounting -- nothing left to surface to, but still
        // worth a console trail if hardware teardown fails.
        try { chimeSession.current.audioVideo.stop(); } catch (err) { console.error('Failed to stop Chime audio/video on unmount:', err); }
      }
      if (chimeAudioEl.current) {
        chimeAudioEl.current.srcObject = null;
        chimeAudioEl.current.remove();
      }
    };
  }, []);

  return {
    sessions, activeSessionId, talkingUserId,
    showCreator, editingSession,
    openCreator, closeCreator,
    loadSessions, createSession, updateSession, deleteSession,
    joinSession, leaveSession,
    joinError, clearJoinError,
    handleSignal,
    videoEnabled, videoTiles, toggleVideo, bindVideoTile,
    muted, toggleMute,
    // Screen share + discussion rooms (task 20261011-web-session-screenshare-rooms)
    sharePhase, contentTile, shareNotice, meetingPresence,
    startScreenShare, stopScreenShare, clearShareNotice,
    rooms,
  };
}
