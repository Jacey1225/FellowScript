import React, { useState, useEffect, useRef, useLayoutEffect, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { PhoneOutlined, PlusOutlined, CloseOutlined } from '@ant-design/icons';
import { SessionCard } from './SessionWidget.jsx';

// Sessions header button + anchored glass submenu (mirrors iOS sessionsMenuCard).
// The joined session is NOT listed here: ChatThread pins it outside the menu so
// its video tiles stay mounted.
export function splitSessions(sessions, activeSessionId, now = Date.now()) {
  const upcoming = [];
  const past = [];
  (sessions || []).forEach(s => {
    if (s.id === activeSessionId) return;
    const ended = s.time_end && new Date(s.time_end).getTime() <= now;
    if (ended) {
      // Existing rule: ended with nobody in it is hidden.
      if ((s.participants || []).length > 0) past.push(s);
    } else {
      upcoming.push(s);
    }
  });
  const t = v => (v ? new Date(v).getTime() : 0);
  upcoming.sort((a, b) => t(a.time_start) - t(b.time_start));
  past.sort((a, b) => t(b.time_end || b.time_start) - t(a.time_end || a.time_start));
  return { upcoming, past };
}

export default function SessionsMenu({
  sessions, activeSessionId, joinError, onClearJoinError,
  onJoin, onLeave, onEdit, onDelete, onOpenSessionCreator,
  user, talkingUserId, onNavigateVerse,
  videoEnabled, videoTiles, onToggleVideo, bindVideoTile, ringCandidates,
}) {
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState(null);
  const btnRef = useRef(null);
  const closeRef = useRef(null);

  const { upcoming, past } = splitSessions(sessions, activeSessionId);
  const inCall = !!activeSessionId;
  const listedError = !!joinError && [...upcoming, ...past].some(s => s.id === joinError.sessionId);

  const close = useCallback(() => {
    setOpen(false);
    btnRef.current?.focus();
  }, []);

  const reposition = useCallback(() => {
    const r = btnRef.current?.getBoundingClientRect();
    if (!r) return;
    setPos({ top: r.bottom + 6, right: Math.max(8, window.innerWidth - r.right) });
  }, []);

  useLayoutEffect(() => {
    if (!open) return undefined;
    reposition();
    window.addEventListener('resize', reposition);
    window.addEventListener('scroll', reposition, true);
    return () => {
      window.removeEventListener('resize', reposition);
      window.removeEventListener('scroll', reposition, true);
    };
  }, [open, reposition]);

  useEffect(() => {
    if (!open) return undefined;
    closeRef.current?.focus();
    const onKey = e => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, close]);

  const cardProps = {
    user, activeSessionId, talkingUserId, onJoin, onLeave, onEdit, onDelete, onNavigateVerse,
    videoEnabled, videoTiles, onToggleVideo, bindVideoTile, joinError, onClearJoinError, ringCandidates,
  };
  const empty = upcoming.length === 0 && past.length === 0;
  const label = inCall ? 'Sessions, in a call' : listedError ? 'Sessions, needs attention' : 'Sessions';

  return (
    <>
      <button
        ref={btnRef}
        type="button"
        className={`sessions-menu-btn${open ? ' sessions-menu-btn-open' : ''}`}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls="sessions-menu"
        aria-label={label}
        onClick={() => (open ? close() : setOpen(true))}
      >
        <PhoneOutlined aria-hidden="true" />
        <span>Sessions</span>
        {(inCall || listedError) && (
          <span aria-hidden="true" className={`sessions-menu-dot${!inCall && listedError ? ' sessions-menu-dot-error' : ''}`} />
        )}
      </button>
      {open && pos && createPortal(
        <>
          <div className="sessions-menu-scrim" data-testid="sessions-menu-scrim" onClick={close} />
          <div
            id="sessions-menu"
            className="sessions-menu"
            role="dialog"
            aria-label="Sessions"
            style={{ top: pos.top, right: pos.right }}
          >
            <div className="sessions-menu-header">
              <h2 className="sessions-menu-title">Sessions</h2>
              <button ref={closeRef} type="button" className="sessions-menu-close" aria-label="Close sessions menu" onClick={close}>
                <CloseOutlined aria-hidden="true" />
              </button>
            </div>
            <div className="sessions-menu-list">
              {empty && <p className="sessions-menu-empty">No sessions scheduled.</p>}
              {upcoming.length > 0 && (
                <>
                  <div className="sessions-menu-section-label">Upcoming</div>
                  {upcoming.map(s => <SessionCard key={s.id} session={s} {...cardProps} />)}
                </>
              )}
              {past.length > 0 && (
                <>
                  <div className="sessions-menu-section-label">Past</div>
                  <div className="sessions-menu-past">
                    {past.map(s => <SessionCard key={s.id} session={s} {...cardProps} />)}
                  </div>
                </>
              )}
            </div>
            <div className="sessions-menu-footer">
              <button
                type="button"
                className="sessions-menu-schedule"
                onClick={() => { onOpenSessionCreator?.(); close(); }}
              >
                <PlusOutlined aria-hidden="true" /> Schedule session
              </button>
            </div>
          </div>
        </>,
        document.body,
      )}
    </>
  );
}
