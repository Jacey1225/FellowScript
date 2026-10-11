// Task 20261011-web-session-screenshare-rooms (step 2). Client for the
// /session-rooms/* API (api/routes/session_rooms.py), mirroring iOS
// NetworkService+SessionRooms.swift. Throw-not-fabricate: every non-2xx,
// transport failure or undecodable body throws SessionRoomsError carrying the
// backend's machine `detail.code`; the UI maps the code to warm copy
// (callRoomState.RoomCopy) and never shows server text. Writes are never
// retried. Requests use the same session cookie as every other call
// (credentials: 'include'); ids are URL-encoded; nothing is logged.
import { API } from '../config.js';

export class SessionRoomsError extends Error {
  constructor(status, code) {
    super(code);
    this.name = 'SessionRoomsError';
    this.status = status;
    this.code = code;
  }
}

const NETWORK = () => new SessionRoomsError(0, 'network');

async function call(path, method, body) {
  let res;
  try {
    res = await fetch(`${API}${path}`, {
      method,
      credentials: 'include',
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw NETWORK();
  }
  if (!res.ok) {
    let code = res.status === 429 ? 'rate_limited' : 'error';
    try {
      const j = await res.json();
      const c = j && j.detail && j.detail.code;
      if (typeof c === 'string' && c) code = c;
    } catch { /* keep the status-derived code */ }
    throw new SessionRoomsError(res.status, code);
  }
  try {
    return await res.json();
  } catch {
    throw NETWORK();
  }
}

const enc = encodeURIComponent;
const base = userId => `/session-rooms/${enc(userId)}`;

const isObj = v => v && typeof v === 'object' && !Array.isArray(v);

// Lenient per-field decode (iOS SessionRoom.init(from:)): only `id` is
// required, so a server that adds or omits a field never blanks the list.
export function normalizeRoom(r) {
  if (!isObj(r) || typeof r.id !== 'string' || !r.id) return null;
  const slot = Number.isInteger(r.slot) ? r.slot : 0;
  const name = typeof r.name === 'string' ? r.name : '';
  const members = Array.isArray(r.members)
    ? r.members
      .filter(m => isObj(m) && typeof m.user_id === 'string' && m.user_id)
      .map(m => ({ user_id: m.user_id, username: typeof m.username === 'string' ? m.username : '' }))
    : [];
  return {
    id: r.id,
    session_id: typeof r.session_id === 'string' ? r.session_id : '',
    slot,
    title: typeof r.title === 'string' ? r.title : '',
    name,
    displayName: name || (slot > 0 ? `Room ${slot}` : 'Room'),
    visibility: r.visibility === 'invite_only' ? 'invite_only' : 'open',
    is_invited: r.is_invited === true,
    can_join: r.can_join !== false,
    member_count: Number.isInteger(r.member_count) ? r.member_count : members.length,
    members,
    max_members: Number.isInteger(r.max_members) ? r.max_members : 8,
    is_full: r.is_full === true,
    is_member: r.is_member === true,
    can_end: r.can_end === true,
    is_creator: r.is_creator === true,
    can_invite: r.can_invite === true,
  };
}

export async function listRooms(userId, sessionId) {
  const body = await call(`${base(userId)}/sessions/${enc(sessionId)}/rooms`, 'GET');
  if (!isObj(body)) throw NETWORK();
  return {
    rooms: (Array.isArray(body.rooms) ? body.rooms : []).map(normalizeRoom).filter(Boolean),
    max_members: Number.isInteger(body.max_members) ? body.max_members : 8,
    max_rooms: Number.isInteger(body.max_rooms) ? body.max_rooms : 6,
    // Absent means "unknown", which must not block Create; only an explicit
    // false does (matches iOS, which defaults the field to true).
    main_live: body.main_live !== false,
  };
}

export async function createRoom(userId, sessionId, { title, inviteOnly, inviteeIds }) {
  const payload = { mode: inviteOnly ? 'invite_only' : 'open' };
  if (title) payload.title = title;
  if (inviteOnly && inviteeIds && inviteeIds.length) payload.invite_user_ids = inviteeIds;
  const body = await call(`${base(userId)}/sessions/${enc(sessionId)}/rooms`, 'POST', payload);
  const room = normalizeRoom(body);
  if (!room) throw NETWORK();
  return room;
}

// -> { room, Meeting, Attendee }. Meeting and Attendee go straight into the
// Chime SDK and are never logged.
export async function joinRoom(userId, roomId) {
  const body = await call(`${base(userId)}/rooms/${enc(roomId)}/join`, 'POST');
  const room = isObj(body) ? normalizeRoom(body.room) : null;
  if (!room || !isObj(body.Meeting) || !isObj(body.Attendee)) throw NETWORK();
  return { room, Meeting: body.Meeting, Attendee: body.Attendee };
}

export async function leaveRoom(userId, roomId) {
  await call(`${base(userId)}/rooms/${enc(roomId)}/leave`, 'POST');
}

export async function heartbeatRoom(userId, roomId) {
  await call(`${base(userId)}/rooms/${enc(roomId)}/heartbeat`, 'POST');
}

export async function renameRoom(userId, roomId, title) {
  await call(`${base(userId)}/rooms/${enc(roomId)}`, 'PATCH', { title });
}

export async function endRoom(userId, roomId) {
  await call(`${base(userId)}/rooms/${enc(roomId)}`, 'DELETE');
}

export async function inviteToRoom(userId, roomId, inviteeIds) {
  await call(`${base(userId)}/rooms/${enc(roomId)}/invites`, 'POST', { user_ids: inviteeIds });
}
