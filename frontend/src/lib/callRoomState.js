// Task 20261011-web-session-screenshare-rooms (step 2). Pure, SDK-free logic
// for discussion rooms, ported from iOS CallRoomState.swift. Plain functions
// and constants so the rules (flag gate, switch state machine, warm copy,
// list presentation, heartbeat outcomes) are unit testable with no Chime SDK,
// React or network.

// ── Feature gate ────────────────────────────────────────────────────────────
export const ROOMS_FLAG = 'discussion_rooms';

// A DM session (group_id "uidA|uidB") has nobody to split from.
export function isDirectMessage(session) {
  return typeof session?.group_id === 'string' && session.group_id.includes('|');
}

// Fail closed: only an explicit `true` capability on a non-DM session.
export function roomsAvailable(isEnabled, session) {
  if (typeof isEnabled !== 'function' || !session) return false;
  return isEnabled(ROOMS_FLAG) === true && !isDirectMessage(session);
}

// ── Room-switch state machine ───────────────────────────────────────────────
// { kind: 'main' | 'joining' | 'inRoom' | 'returning' | 'returnFailed', roomId?, name? }
export const MAIN_STATE = Object.freeze({ kind: 'main' });

export const isBusy = s => s.kind === 'joining' || s.kind === 'returning';
export const isInRoom = s => s.kind === 'inRoom';
// True while the user is, or is about to be, away from the main meeting: the
// Back to main exits must stay reachable.
export const showsBackToMain = s => s.kind === 'inRoom' || s.kind === 'returning' || s.kind === 'returnFailed';
export const stateRoomId = s => (s.kind === 'inRoom' || s.kind === 'joining' ? s.roomId : null);
export const stateRoomName = s => (s.kind === 'main' ? null : s.name || null);

// Transitions. Invalid ones are no-ops so a late callback can never corrupt
// the machine.
export function beginJoin(s, roomId, name) {
  return s.kind === 'main' || s.kind === 'inRoom' ? { kind: 'joining', roomId, name } : s;
}
export function joinSucceeded(s) {
  return s.kind === 'joining' ? { kind: 'inRoom', roomId: s.roomId, name: s.name } : s;
}
// The backend join failed BEFORE anything was torn down: stay where we were.
export function joinFailed(s, previous) {
  return s.kind === 'joining' ? previous : s;
}
export function beginReturn(s) {
  return s.kind === 'inRoom' || s.kind === 'returnFailed' ? { kind: 'returning', name: s.name } : s;
}
export function returnSucceeded(s) {
  return s.kind === 'returning' ? MAIN_STATE : s;
}
export function returnFailed(s) {
  return s.kind === 'returning' ? { kind: 'returnFailed', name: s.name } : s;
}

// ── Warm copy (backend `code` -> text). Raw server text is never shown. ─────
export function roomMessage(code, action) {
  const busy = "That's busy right now. Please try again.";
  switch (code) {
    case 'room_full': return 'This room is full.';
    case 'cannot_join': return "You can't join this room right now.";
    case 'room_ended':
    case 'not_in_room': return 'That room has ended.';
    case 'rooms_full': return 'All rooms are in use. Try again once one ends.';
    case 'rate_limited': return action === 'create'
      ? "You're opening rooms too quickly. Try again in a minute."
      : busy;
    case 'invalid_invitee':
    case 'too_many_invites':
    case 'invite_limit': return "Some of those people couldn't be invited. Adjust your choices.";
    case 'title_rejected':
    case 'title_too_long': return 'Please choose a different name.';
    case 'forbidden': return 'Only the person who made this room can do that.';
    case 'chime_error':
    case 'network': return action === 'join' ? "Couldn't start the room call. Please try again." : busy;
    case 'busy': return busy;
    case 'main_not_live': return 'The session has ended.';
    default: return action === 'load' ? "Couldn't load rooms." : busy;
  }
}

export const roomErrorMessage = (err, action) => roomMessage((err && err.code) || 'network', action);
export const isMainEnded = err => !!err && err.code === 'main_not_live';
export const isRoomGone = err => !!err && (err.code === 'room_ended' || err.code === 'not_in_room' || err.status === 410);

export const ROOM_COPY = {
  roomEnded: name => `${name} has ended. You're back in the main session.`,
  returnFailed: "Couldn't reach the main session.",
  mainEnded: 'The session has ended.',
};

// ── Heartbeat ───────────────────────────────────────────────────────────────
export const HEARTBEAT_INTERVAL_MS = 30000;
export const LIST_POLL_INTERVAL_MS = 5000;

// Heartbeat failures never eject a user on their own: only the server's
// explicit "room is gone" / "main is gone" answers do.
export function heartbeatOutcome(err) {
  if (isMainEnded(err)) return 'mainEnded';
  if (isRoomGone(err)) return 'roomGone';
  return 'keepGoing';
}

// ── Room list presentation ──────────────────────────────────────────────────
// Precedence: is_member, then is_full, then !can_join, then invited, else join.
export function trailingState(room) {
  if (room.is_member) return 'here';
  if (room.is_full) return 'full';
  if (!room.can_join) return 'hidden';
  if (room.visibility === 'invite_only' && room.is_invited) return 'invitedJoin';
  return 'join';
}

export function visibleRooms(rooms) {
  return (rooms || []).filter(r => trailingState(r) !== 'hidden').sort((a, b) => a.slot - b.slot);
}

export function roomActions(room) {
  const out = [];
  if (room.is_creator) out.push('rename');
  if (room.can_invite) out.push('invite');
  if (room.can_end) out.push('end');
  return out;
}

export function roomSubtitle(room) {
  return `${room.member_count} of ${room.max_members} · ${room.visibility === 'invite_only' ? 'Invite only' : 'Open'}`;
}

// "Ana, Ben +2": at most two names shown.
export function memberNames(room, limit = 2) {
  const names = (room.members || []).map(m => m.username).filter(Boolean);
  if (!names.length) return null;
  const shown = names.slice(0, limit).join(', ');
  const extra = names.length - limit;
  return extra > 0 ? `${shown} +${extra}` : shown;
}

// Why Create is unavailable (null = enabled). `rooms_full` from the server
// stays authoritative; this is a best-effort pre-check.
export function createBlock(list) {
  if (!list) return null;
  if (!list.main_live) return { kind: 'mainNotLive' };
  if (list.rooms.length >= list.max_rooms) return { kind: 'roomsFull', max: list.max_rooms };
  return null;
}

export function createBlockCaption(block) {
  return block.kind === 'roomsFull'
    ? `All ${block.max} rooms are in use`
    : "The session call isn't running right now";
}

// ── Create / rename form ────────────────────────────────────────────────────
export const ROOM_NAME_MAX = 40;
export const ROOM_COUNTER_THRESHOLD = 30;
export const ROOM_MAX_INVITES = 50;

// Whitespace-collapsed, capped.
export function cleanRoomName(raw) {
  return String(raw || '').split(/\s+/).filter(Boolean).join(' ').slice(0, ROOM_NAME_MAX);
}
