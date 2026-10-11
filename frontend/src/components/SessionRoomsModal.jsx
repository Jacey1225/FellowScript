import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Modal, Button, Spin } from 'antd';
import {
  CheckOutlined, EllipsisOutlined, LockOutlined, PlusOutlined, RollbackOutlined, TeamOutlined,
} from '@ant-design/icons';
import * as roomsApi from '../lib/sessionRoomsApi.js';
import {
  LIST_POLL_INTERVAL_MS, ROOM_COUNTER_THRESHOLD, ROOM_MAX_INVITES, ROOM_NAME_MAX,
  cleanRoomName, createBlock, createBlockCaption, isBusy, isMainEnded, memberNames,
  roomActions, roomErrorMessage, roomMessage, roomSubtitle, showsBackToMain, stateRoomName,
  trailingState, visibleRooms,
} from '../lib/callRoomState.js';

// Task 20261011-web-session-screenshare-rooms (step 2). Web port of iOS
// RoomsSheet: a dialog OVER the call (the call keeps running underneath) to
// list, create, join, rename, invite to and end discussion (breakout) rooms.
// Views: list | create | rename | invite | end (confirm). Room switching
// itself is the controller's job (useCallRooms); this only asks it. All copy
// comes from callRoomState.roomMessage, never raw server text. The list polls
// every 5s only while the dialog is open and the tab is visible; the last good
// list is kept across a failed poll.

function RowPillButton({ children, onClick, disabled, ariaLabel, danger }) {
  return (
    <Button
      type={danger ? 'default' : 'primary'}
      danger={danger}
      disabled={disabled}
      onClick={onClick}
      aria-label={ariaLabel}
      style={{ minHeight: 44, minWidth: 64 }}
    >
      {children}
    </Button>
  );
}

function InvitePicker({ candidates, picked, onToggle, capReached, emptyText }) {
  if (candidates.length === 0) return <p className="ring-empty">{emptyText}</p>;
  return (
    <ul className="ring-list">
      {candidates.map(c => {
        const on = picked.has(c.user_id);
        const name = c.username || 'Member';
        return (
          <li key={c.user_id}>
            <button
              type="button"
              role="checkbox"
              aria-checked={on}
              aria-disabled={capReached && !on}
              aria-label={name}
              className="ring-row"
              onClick={() => { if (!capReached || on) onToggle(c.user_id); }}
            >
              <span className="ring-row-avatar" aria-hidden="true">{name[0]?.toUpperCase()}</span>
              <span className="ring-row-text"><span className="ring-row-name">{name}</span></span>
              <span className="ring-row-trailing">{on && <CheckOutlined style={{ color: 'var(--gold)' }} aria-hidden="true" />}</span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

function RoomRow({ room, joining, error, expanded, onToggleActions, onJoin, onRename, onInvite, onEnd }) {
  const trailing = trailingState(room);
  const actions = roomActions(room);
  const invite = room.visibility === 'invite_only';
  const names = memberNames(room);
  return (
    <li className={`rooms-row${trailing === 'full' ? ' rooms-row-full' : ''}`}>
      <div className="rooms-row-main">
        <span className="rooms-row-icon" aria-hidden="true">{invite ? <LockOutlined /> : <TeamOutlined />}</span>
        <div
          className="rooms-row-info"
          role="group"
          aria-label={`${room.displayName}, ${invite ? 'invite only' : 'open'}, ${room.member_count} of ${room.max_members} people${trailing === 'full' ? ', full' : ''}${trailing === 'here' ? ", you're here" : ''}`}
        >
          <span className="rooms-row-name">{room.displayName}</span>
          <span className="rooms-row-sub">{roomSubtitle(room)}</span>
          {names && <span className="rooms-row-sub">{names}</span>}
        </div>
        <div className="rooms-row-trailing">
          {trailing === 'here' && <span className="rooms-badge rooms-badge-here">You&apos;re here</span>}
          {trailing === 'full' && <span className="rooms-badge">Full</span>}
          {trailing === 'invitedJoin' && <span className="rooms-badge rooms-badge-invited">Invited</span>}
          {(trailing === 'join' || trailing === 'invitedJoin') && (
            joining
              ? <Spin size="small" aria-label={`Joining ${room.displayName}`} />
              : <RowPillButton onClick={onJoin} ariaLabel={`Join ${room.displayName}`}>Join</RowPillButton>
          )}
          {actions.length > 0 && (
            <button
              type="button"
              className="rooms-more"
              aria-label={`More actions for ${room.displayName}`}
              aria-expanded={expanded}
              onClick={onToggleActions}
            >
              <EllipsisOutlined aria-hidden="true" />
            </button>
          )}
        </div>
      </div>
      {expanded && actions.length > 0 && (
        <div className="rooms-actions" role="group" aria-label={`Actions for ${room.displayName}`}>
          {actions.includes('rename') && <button type="button" className="rooms-action" onClick={onRename}>Rename room</button>}
          {actions.includes('invite') && <button type="button" className="rooms-action" onClick={onInvite}>Invite people</button>}
          {actions.includes('end') && <button type="button" className="rooms-action rooms-action-danger" onClick={onEnd}>End room</button>}
        </div>
      )}
      {error && <p className="rooms-error" role="alert">{error}</p>}
    </li>
  );
}

function CreateView({ candidates, onSubmit, onCancel }) {
  const [name, setName] = useState('');
  const [inviteOnly, setInviteOnly] = useState(false);
  const [picked, setPicked] = useState(() => new Set());
  const [joinAfter, setJoinAfter] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState(null);
  const capReached = picked.size >= ROOM_MAX_INVITES;

  const toggle = id => setPicked(prev => {
    const next = new Set(prev);
    if (next.has(id)) next.delete(id); else if (next.size < ROOM_MAX_INVITES) next.add(id);
    return next;
  });

  const submit = async () => {
    if (submitting) return;
    setSubmitting(true); setError(null);
    const err = await onSubmit({
      title: cleanRoomName(name),
      inviteOnly,
      inviteeIds: inviteOnly ? [...picked].sort() : [],
      joinAfter,
    });
    setSubmitting(false);
    if (err) setError(err);
  };

  return (
    <form className="rooms-form" onSubmit={e => { e.preventDefault(); submit(); }}>
      <label className="rooms-label" htmlFor="rooms-name">Room name</label>
      <input
        id="rooms-name"
        className="rooms-input"
        type="text"
        value={name}
        maxLength={ROOM_NAME_MAX}
        autoComplete="off"
        placeholder="Room name (optional)"
        aria-describedby="rooms-name-hint"
        onChange={e => setName(e.target.value.slice(0, ROOM_NAME_MAX))}
      />
      <div className="rooms-hint-row">
        <span id="rooms-name-hint" className="rooms-hint">Leave blank for &ldquo;Room N&rdquo;</span>
        {name.length >= ROOM_COUNTER_THRESHOLD && <span className="rooms-hint">{name.length}/{ROOM_NAME_MAX}</span>}
      </div>

      <fieldset className="rooms-fieldset">
        <legend className="rooms-label">Who can join</legend>
        <div className="rooms-segment" role="radiogroup" aria-label="Who can join">
          <button type="button" role="radio" aria-checked={!inviteOnly} className={`rooms-seg${!inviteOnly ? ' rooms-seg-on' : ''}`} onClick={() => setInviteOnly(false)}>Open</button>
          <button type="button" role="radio" aria-checked={inviteOnly} className={`rooms-seg${inviteOnly ? ' rooms-seg-on' : ''}`} onClick={() => setInviteOnly(true)}>Invite only</button>
        </div>
        <span className="rooms-hint">{inviteOnly ? 'Only people you choose can join' : 'Anyone in this session can join'}</span>
      </fieldset>

      {inviteOnly && (
        <div className="rooms-invites">
          <span className="rooms-hint" aria-live="polite">{picked.size} selected</span>
          <InvitePicker candidates={candidates} picked={picked} onToggle={toggle} capReached={capReached} emptyText="No other members to invite." />
          {capReached && <span className="rooms-hint">Invitation limit reached</span>}
          {picked.size === 0 && candidates.length > 0 && <span className="rooms-hint">You can invite people after creating the room.</span>}
        </div>
      )}

      <label className="rooms-check">
        <input type="checkbox" checked={joinAfter} onChange={e => setJoinAfter(e.target.checked)} />
        <span>Join after creating</span>
      </label>

      {error && <p className="rooms-error" role="alert">{error}</p>}
      <div className="rooms-form-actions">
        <Button onClick={onCancel} style={{ minHeight: 44 }}>Cancel</Button>
        <Button type="primary" htmlType="submit" loading={submitting} style={{ minHeight: 44 }}>Create room</Button>
      </div>
    </form>
  );
}

function RenameView({ room, onSubmit, onCancel }) {
  const [text, setText] = useState(room.title || '');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const save = async () => {
    if (saving) return;
    setSaving(true); setError(null);
    const err = await onSubmit(cleanRoomName(text));
    setSaving(false);
    if (err) setError(err);
  };
  return (
    <form className="rooms-form" onSubmit={e => { e.preventDefault(); save(); }}>
      <label className="rooms-label" htmlFor="rooms-rename">Room name</label>
      <input
        id="rooms-rename"
        className="rooms-input"
        type="text"
        value={text}
        maxLength={ROOM_NAME_MAX}
        autoComplete="off"
        onChange={e => setText(e.target.value.slice(0, ROOM_NAME_MAX))}
      />
      <div className="rooms-hint-row">
        <span className="rooms-hint">Leave blank to use &ldquo;Room N&rdquo;</span>
        {text.length >= ROOM_COUNTER_THRESHOLD && <span className="rooms-hint">{text.length}/{ROOM_NAME_MAX}</span>}
      </div>
      {error && <p className="rooms-error" role="alert">{error}</p>}
      <div className="rooms-form-actions">
        <Button onClick={onCancel} style={{ minHeight: 44 }}>Cancel</Button>
        <Button type="primary" htmlType="submit" loading={saving} style={{ minHeight: 44 }}>Save</Button>
      </div>
    </form>
  );
}

function InviteView({ room, candidates, onSubmit, onCancel }) {
  const memberIds = new Set((room.members || []).map(m => m.user_id));
  const eligible = candidates.filter(c => !memberIds.has(c.user_id));
  const [picked, setPicked] = useState(() => new Set());
  const [sending, setSending] = useState(false);
  const [error, setError] = useState(null);
  const capReached = picked.size >= ROOM_MAX_INVITES;
  const toggle = id => setPicked(prev => {
    const next = new Set(prev);
    if (next.has(id)) next.delete(id); else if (next.size < ROOM_MAX_INVITES) next.add(id);
    return next;
  });
  const send = async () => {
    if (sending || picked.size === 0) return;
    setSending(true); setError(null);
    const err = await onSubmit([...picked].sort());
    setSending(false);
    if (err) setError(err);
  };
  return (
    <div className="rooms-form">
      <InvitePicker candidates={eligible} picked={picked} onToggle={toggle} capReached={capReached} emptyText="No other members to invite." />
      {error && <p className="rooms-error" role="alert">{error}</p>}
      <div className="rooms-form-actions">
        <Button onClick={onCancel} style={{ minHeight: 44 }}>Cancel</Button>
        <Button type="primary" disabled={picked.size === 0} loading={sending} onClick={send} style={{ minHeight: 44 }}>
          {picked.size ? `Invite (${picked.size})` : 'Invite'}
        </Button>
      </div>
    </div>
  );
}

export default function SessionRoomsModal({ open, onClose, session, user, rooms, inviteCandidates }) {
  const [list, setList] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadFailed, setLoadFailed] = useState(false);
  const [joiningId, setJoiningId] = useState(null);
  const [rowErrors, setRowErrors] = useState({});
  const [view, setView] = useState({ kind: 'list' });
  const [expandedId, setExpandedId] = useState(null);
  const [manageError, setManageError] = useState(null);
  const listRef = useRef(null);
  const aliveRef = useRef(true);

  const uid = user?.user_id;
  const sid = session?.id;
  const candidates = (inviteCandidates || []).filter(c => c && c.user_id && c.user_id !== uid);

  useEffect(() => { aliveRef.current = true; return () => { aliveRef.current = false; }; }, []);

  const refresh = useCallback(async () => {
    if (!uid || !sid) return;
    try {
      const result = await roomsApi.listRooms(uid, sid);
      if (!aliveRef.current) return;
      listRef.current = result;
      setList(result);
      setLoadFailed(false);
      rooms.noteRoomsList(result);
    } catch (err) {
      if (!aliveRef.current) return;
      if (isMainEnded(err)) rooms.mainEnded();
      else if (!listRef.current) setLoadFailed(true);   // keep the last good list on a poll blip
    }
    if (aliveRef.current) setIsLoading(false);
  }, [uid, sid, rooms]);

  // First fetch, then poll while open and visible. Reset on every open.
  useEffect(() => {
    if (!open) return undefined;
    listRef.current = null;
    setList(null); setIsLoading(true); setLoadFailed(false);
    setView({ kind: 'list' }); setExpandedId(null); setManageError(null); setRowErrors({});
    refresh();
    const id = setInterval(() => { if (document.visibilityState !== 'hidden') refresh(); }, LIST_POLL_INTERVAL_MS);
    const onVisible = () => { if (document.visibilityState === 'visible') refresh(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => { clearInterval(id); document.removeEventListener('visibilitychange', onVisible); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, uid, sid]);

  const shown = visibleRooms(list?.rooms);
  const block = createBlock(list);
  const away = showsBackToMain(rooms.state);

  const join = async (room) => {
    if (joiningId || isBusy(rooms.state)) return;
    setJoiningId(room.id);
    setRowErrors(prev => ({ ...prev, [room.id]: null }));
    const err = await rooms.join(room);
    if (!aliveRef.current) return;
    setJoiningId(null);
    if (err) { setRowErrors(prev => ({ ...prev, [room.id]: err })); refresh(); } else onClose();
  };

  // Resolves to an inline error for the create form, or null when done with it.
  const createRoom = async ({ title, inviteOnly, inviteeIds, joinAfter }) => {
    try {
      const room = await roomsApi.createRoom(uid, sid, { title, inviteOnly, inviteeIds });
      await refresh();
      if (joinAfter) {
        const err = await rooms.join(room);
        if (err) {
          // The room exists: show the join error in its row.
          setRowErrors(prev => ({ ...prev, [room.id]: err }));
          setView({ kind: 'list' });
          return null;
        }
        onClose();
        return null;
      }
      setView({ kind: 'list' });
      return null;
    } catch (err) {
      if (isMainEnded(err)) { rooms.mainEnded(); return roomMessage('main_not_live', 'create'); }
      if (err?.code === 'forbidden') { onClose(); return null; }
      return roomErrorMessage(err, 'create');
    }
  };

  const renameRoom = async (room, title) => {
    try {
      await roomsApi.renameRoom(uid, room.id, title);
      setManageError(null);
      await refresh();
      setView({ kind: 'list' });
      return null;
    } catch (err) { return roomErrorMessage(err, 'manage'); }
  };

  const inviteToRoom = async (room, ids) => {
    try {
      await roomsApi.inviteToRoom(uid, room.id, ids);
      setManageError(null);
      await refresh();
      setView({ kind: 'list' });
      return null;
    } catch (err) { return roomErrorMessage(err, 'manage'); }
  };

  const endRoom = async (room) => {
    try {
      await roomsApi.endRoom(uid, room.id);
      setManageError(null);
      setView({ kind: 'list' });
      await rooms.didEndRoom(room.id);
      await refresh();
    } catch (err) {
      setView({ kind: 'list' });
      setManageError(roomErrorMessage(err, 'manage'));
    }
  };

  const titles = { list: 'Rooms', create: 'New room', rename: 'Rename room', invite: 'Invite people', end: 'End this room?' };
  const back = () => setView({ kind: 'list' });

  const renderList = () => {
    let body;
    if (isLoading && !list) {
      body = <div className="rooms-center"><Spin aria-label="Loading rooms" /></div>;
    } else if (loadFailed && !list) {
      body = (
        <div className="rooms-center">
          <p className="rooms-hint">{roomMessage('network', 'load')}</p>
          <Button onClick={refresh} style={{ minHeight: 44 }}>Try again</Button>
        </div>
      );
    } else if (shown.length === 0) {
      body = <p className="ring-empty">No rooms yet. Start one to talk privately.</p>;
    } else {
      body = (
        <ul className="rooms-list" aria-label="Rooms">
          {shown.map(room => (
            <RoomRow
              key={room.id}
              room={room}
              joining={joiningId === room.id}
              error={rowErrors[room.id]}
              expanded={expandedId === room.id}
              onToggleActions={() => setExpandedId(id => (id === room.id ? null : room.id))}
              onJoin={() => join(room)}
              onRename={() => setView({ kind: 'rename', room })}
              onInvite={() => setView({ kind: 'invite', room })}
              onEnd={() => setView({ kind: 'end', room })}
            />
          ))}
        </ul>
      );
    }
    return (
      <>
        {away && (
          <div className="rooms-current" role="group" aria-label="Current room">
            <h3 className="rooms-current-title">You&apos;re in {stateRoomName(rooms.state) || rooms.currentRoom?.displayName || 'a room'}</h3>
            {rooms.currentRoom && <span className="rooms-hint">{rooms.currentRoom.member_count} of {rooms.currentRoom.max_members} here</span>}
            <Button
              type="primary"
              icon={<RollbackOutlined aria-hidden="true" />}
              disabled={isBusy(rooms.state)}
              onClick={async () => { const back2 = await rooms.returnToMain(); if (back2) onClose(); }}
              style={{ minHeight: 44, alignSelf: 'flex-start' }}
            >
              Back to main
            </Button>
          </div>
        )}
        <Button
          type="primary"
          block
          icon={<PlusOutlined aria-hidden="true" />}
          disabled={!!block}
          onClick={() => setView({ kind: 'create' })}
          style={{ minHeight: 48 }}
        >
          Create a room
        </Button>
        {block && <p className="rooms-hint">{createBlockCaption(block)}</p>}
        {manageError && <p className="rooms-error" role="alert">{manageError}</p>}
        {body}
      </>
    );
  };

  let content;
  if (view.kind === 'create') content = <CreateView candidates={candidates} onSubmit={createRoom} onCancel={back} />;
  else if (view.kind === 'rename') content = <RenameView room={view.room} onSubmit={t => renameRoom(view.room, t)} onCancel={back} />;
  else if (view.kind === 'invite') content = <InviteView room={view.room} candidates={candidates} onSubmit={ids => inviteToRoom(view.room, ids)} onCancel={back} />;
  else if (view.kind === 'end') {
    content = (
      <div className="rooms-form">
        <p className="rooms-confirm">Everyone in it goes back to the main session.</p>
        <div className="rooms-form-actions">
          <Button onClick={back} style={{ minHeight: 44 }}>Cancel</Button>
          <Button danger type="primary" onClick={() => endRoom(view.room)} style={{ minHeight: 44 }}>End {view.room.displayName}</Button>
        </div>
      </div>
    );
  } else content = renderList();

  return (
    <Modal
      open={open}
      onCancel={view.kind === 'list' ? onClose : back}
      title={titles[view.kind]}
      centered
      destroyOnHidden
      footer={view.kind === 'list' ? [<Button key="close" onClick={onClose} style={{ minHeight: 44 }} aria-label="Close rooms">Close</Button>] : null}
      width="min(460px, calc(100vw - 32px))"
      className="ring-modal rooms-modal"
    >
      <div className="rooms-body">{content}</div>
    </Modal>
  );
}
