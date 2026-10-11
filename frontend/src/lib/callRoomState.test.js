// Task 20261011-web-session-screenshare-rooms testing: pure discussion-room rules.
import { describe, test, expect } from 'vitest';
import * as S from './callRoomState.js';

const room = (o = {}) => ({
  id: 'r1', slot: 1, is_member: false, is_full: false, can_join: true, visibility: 'open',
  is_invited: false, is_creator: false, can_invite: false, can_end: false,
  member_count: 1, max_members: 8, members: [], ...o,
});

describe('availability gate', () => {
  const on = f => f === 'discussion_rooms';
  test('only explicit true on a non-DM session', () => {
    expect(S.ROOMS_FLAG).toBe('discussion_rooms');
    expect(S.roomsAvailable(on, { group_id: 'g1' })).toBe(true);
    expect(S.roomsAvailable(() => false, { group_id: 'g1' })).toBe(false);
    expect(S.roomsAvailable(() => 'yes', { group_id: 'g1' })).toBe(false);
    expect(S.roomsAvailable(on, { group_id: 'a|b' })).toBe(false);
    expect(S.roomsAvailable(on, null)).toBe(false);
    expect(S.roomsAvailable(undefined, { group_id: 'g' })).toBe(false);
  });
});

describe('switch state machine', () => {
  test('happy path main -> joining -> inRoom -> returning -> main', () => {
    let s = S.beginJoin(S.MAIN_STATE, 'r1', 'Room 1');
    expect(s.kind).toBe('joining');
    expect(S.stateRoomId(s)).toBe('r1');
    s = S.joinSucceeded(s);
    expect(S.isInRoom(s)).toBe(true);
    expect(S.showsBackToMain(s)).toBe(true);
    s = S.beginReturn(s);
    expect(S.isBusy(s)).toBe(true);
    expect(S.stateRoomId(s)).toBeNull();
    expect(S.returnSucceeded(s)).toEqual(S.MAIN_STATE);
  });
  test('join failure restores previous; return failure keeps Back to main reachable', () => {
    const prev = { kind: 'inRoom', roomId: 'a', name: 'A' };
    expect(S.joinFailed(S.beginJoin(prev, 'b', 'B'), prev)).toBe(prev);
    const f = S.returnFailed(S.beginReturn(prev));
    expect(f.kind).toBe('returnFailed');
    expect(S.showsBackToMain(f)).toBe(true);
    expect(S.beginReturn(f).kind).toBe('returning');
  });
  test('invalid transitions are no-ops', () => {
    expect(S.joinSucceeded(S.MAIN_STATE)).toBe(S.MAIN_STATE);
    expect(S.beginReturn(S.MAIN_STATE)).toBe(S.MAIN_STATE);
    expect(S.returnSucceeded(S.MAIN_STATE)).toBe(S.MAIN_STATE);
    const j = { kind: 'joining', roomId: 'x' };
    expect(S.beginJoin(j, 'y')).toBe(j);
  });
});

describe('copy and error mapping', () => {
  test('known codes map to warm fixed text, never raw server text', () => {
    expect(S.roomMessage('room_full')).toBe('This room is full.');
    expect(S.roomMessage('room_ended')).toBe('That room has ended.');
    expect(S.roomMessage('not_in_room')).toBe('That room has ended.');
    expect(S.roomMessage('main_not_live')).toBe('The session has ended.');
    expect(S.roomMessage('rate_limited', 'create')).toMatch(/too quickly/);
    expect(S.roomMessage('network', 'join')).toMatch(/Couldn't start the room call/);
    expect(S.roomMessage('weird <b>', 'load')).toBe("Couldn't load rooms.");
    expect(S.roomErrorMessage(null, 'join')).toMatch(/Couldn't start/);
  });
  test('main ended / room gone detection', () => {
    expect(S.isMainEnded({ code: 'main_not_live' })).toBe(true);
    expect(S.isRoomGone({ code: 'room_ended' })).toBe(true);
    expect(S.isRoomGone({ status: 410 })).toBe(true);
    expect(S.isRoomGone({ code: 'network' })).toBe(false);
    expect(S.isMainEnded(null)).toBe(false);
  });
  test('heartbeat never ejects on transient failures', () => {
    expect(S.heartbeatOutcome({ code: 'main_not_live' })).toBe('mainEnded');
    expect(S.heartbeatOutcome({ code: 'room_ended' })).toBe('roomGone');
    expect(S.heartbeatOutcome({ code: 'not_in_room' })).toBe('roomGone');
    expect(S.heartbeatOutcome({ code: 'network', status: 0 })).toBe('keepGoing');
    expect(S.heartbeatOutcome({ status: 500 })).toBe('keepGoing');
    expect(S.heartbeatOutcome(new Error('x'))).toBe('keepGoing');
    expect(S.HEARTBEAT_INTERVAL_MS).toBe(30000);
    expect(S.LIST_POLL_INTERVAL_MS).toBe(5000);
  });
  test('roomEnded copy interpolates the name', () => {
    expect(S.ROOM_COPY.roomEnded('Room 2')).toBe("Room 2 has ended. You're back in the main session.");
  });
});

describe('list presentation', () => {
  test('trailing state precedence member > full > hidden > invited > join', () => {
    expect(S.trailingState(room({ is_member: true, is_full: true }))).toBe('here');
    expect(S.trailingState(room({ is_full: true, can_join: false }))).toBe('full');
    expect(S.trailingState(room({ can_join: false }))).toBe('hidden');
    expect(S.trailingState(room({ visibility: 'invite_only', is_invited: true }))).toBe('invitedJoin');
    expect(S.trailingState(room())).toBe('join');
  });
  test('visibleRooms drops hidden (invite-only, not invited) and sorts by slot', () => {
    const v = S.visibleRooms([room({ id: 'b', slot: 3 }), room({ id: 'h', slot: 2, can_join: false }), room({ id: 'a', slot: 1 })]);
    expect(v.map(r => r.id)).toEqual(['a', 'b']);
    expect(S.visibleRooms(null)).toEqual([]);
  });
  test('actions, subtitle, member names', () => {
    expect(S.roomActions(room({ is_creator: true, can_invite: true, can_end: true }))).toEqual(['rename', 'invite', 'end']);
    expect(S.roomActions(room())).toEqual([]);
    expect(S.roomSubtitle(room({ member_count: 2, visibility: 'invite_only' }))).toBe('2 of 8 · Invite only');
    expect(S.memberNames(room({ members: [{ username: 'Ana' }, { username: 'Ben' }, { username: 'Cy' }, { username: 'Di' }] }))).toBe('Ana, Ben +2');
    expect(S.memberNames(room())).toBeNull();
  });
  test('create block: main not live / rooms full / ok', () => {
    expect(S.createBlock(null)).toBeNull();
    expect(S.createBlock({ main_live: false, rooms: [], max_rooms: 6 }).kind).toBe('mainNotLive');
    const full = S.createBlock({ main_live: true, rooms: new Array(6).fill(1), max_rooms: 6 });
    expect(full).toEqual({ kind: 'roomsFull', max: 6 });
    expect(S.createBlockCaption(full)).toBe('All 6 rooms are in use');
    expect(S.createBlock({ main_live: true, rooms: [], max_rooms: 6 })).toBeNull();
  });
  test('cleanRoomName collapses whitespace and caps length', () => {
    expect(S.cleanRoomName('  a   b \n c ')).toBe('a b c');
    expect(S.cleanRoomName('x'.repeat(100))).toHaveLength(S.ROOM_NAME_MAX);
    expect(S.cleanRoomName(null)).toBe('');
  });
});
