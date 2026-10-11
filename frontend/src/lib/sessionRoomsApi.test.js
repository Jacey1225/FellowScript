// Task 20261011-web-session-screenshare-rooms testing: /session-rooms client.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import * as api from './sessionRoomsApi.js';

const json = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
let fetchMock;
beforeEach(() => { fetchMock = vi.fn(); vi.stubGlobal('fetch', fetchMock); });
afterEach(() => vi.unstubAllGlobals());

describe('normalizeRoom', () => {
  test('requires id; lenient on the rest; never fabricates members', () => {
    expect(api.normalizeRoom(null)).toBeNull();
    expect(api.normalizeRoom({})).toBeNull();
    expect(api.normalizeRoom({ id: 5 })).toBeNull();
    const r = api.normalizeRoom({ id: 'r', slot: 2, members: [{ user_id: 'u' }, { nope: 1 }, 'x'] });
    expect(r.displayName).toBe('Room 2');
    expect(r.members).toEqual([{ user_id: 'u', username: '' }]);
    expect(r.visibility).toBe('open');
    expect(r.is_member).toBe(false);
    expect(r.can_join).toBe(true);
    expect(api.normalizeRoom({ id: 'r', name: 'Study' }).displayName).toBe('Study');
  });
});

describe('requests', () => {
  test('list: GET with cookie credentials, encoded ids, decodes defaults', async () => {
    fetchMock.mockResolvedValue(json(200, { rooms: [{ id: 'a' }, { bad: 1 }] }));
    const res = await api.listRooms('u/1', 's 2');
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toContain('/session-rooms/u%2F1/sessions/s%202/rooms');
    expect(opts.method).toBe('GET');
    expect(opts.credentials).toBe('include');
    expect(res.rooms).toHaveLength(1);
    expect(res.main_live).toBe(true);
    expect(res.max_rooms).toBe(6);
  });
  test('main_live only false when explicitly false', async () => {
    fetchMock.mockResolvedValue(json(200, { rooms: [], main_live: false }));
    expect((await api.listRooms('u', 's')).main_live).toBe(false);
  });
  test('create payload shape', async () => {
    fetchMock.mockResolvedValue(json(200, { id: 'n' }));
    await api.createRoom('u', 's', { title: 'T', inviteOnly: true, inviteeIds: ['x'] });
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ mode: 'invite_only', title: 'T', invite_user_ids: ['x'] });
    await api.createRoom('u', 's', { inviteOnly: false, inviteeIds: ['x'] });
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ mode: 'open' });
  });
  test('join returns room + Meeting + Attendee; missing pieces throw (no fabrication)', async () => {
    fetchMock.mockResolvedValueOnce(json(200, { room: { id: 'r' }, Meeting: { m: 1 }, Attendee: { a: 1 } }));
    const j = await api.joinRoom('u', 'r');
    expect(j.Meeting).toEqual({ m: 1 });
    fetchMock.mockResolvedValueOnce(json(200, { room: { id: 'r' } }));
    await expect(api.joinRoom('u', 'r')).rejects.toMatchObject({ code: 'network' });
  });
  test('verbs and paths for leave/heartbeat/rename/end/invite', async () => {
    fetchMock.mockResolvedValue(json(200, {}));
    await api.leaveRoom('u', 'r'); await api.heartbeatRoom('u', 'r');
    await api.renameRoom('u', 'r', 'N'); await api.endRoom('u', 'r'); await api.inviteToRoom('u', 'r', ['a']);
    const calls = fetchMock.mock.calls.map(([u, o]) => `${o.method} ${u.replace(/^.*\/session-rooms/, '')}`);
    expect(calls).toEqual([
      'POST /u/rooms/r/leave', 'POST /u/rooms/r/heartbeat', 'PATCH /u/rooms/r', 'DELETE /u/rooms/r', 'POST /u/rooms/r/invites',
    ]);
    expect(JSON.parse(fetchMock.mock.calls[2][1].body)).toEqual({ title: 'N' });
    expect(JSON.parse(fetchMock.mock.calls[4][1].body)).toEqual({ user_ids: ['a'] });
  });
});

describe('errors (throw-not-fabricate)', () => {
  test('backend detail.code surfaces; status kept', async () => {
    fetchMock.mockResolvedValue(json(409, { detail: { code: 'room_full', message: 'secret server text' } }));
    const e = await api.joinRoom('u', 'r').catch(x => x);
    expect(e).toBeInstanceOf(api.SessionRoomsError);
    expect(e.code).toBe('room_full');
    expect(e.status).toBe(409);
  });
  test('429 -> rate_limited; unparseable error -> error', async () => {
    fetchMock.mockResolvedValueOnce({ ok: false, status: 429, json: async () => { throw new Error('x'); } });
    expect((await api.listRooms('u', 's').catch(x => x)).code).toBe('rate_limited');
    fetchMock.mockResolvedValueOnce({ ok: false, status: 500, json: async () => { throw new Error('x'); } });
    expect((await api.listRooms('u', 's').catch(x => x)).code).toBe('error');
  });
  test('flag-off uniform 404 throws', async () => {
    fetchMock.mockResolvedValue(json(404, { detail: 'Not Found' }));
    await expect(api.listRooms('u', 's')).rejects.toMatchObject({ status: 404 });
  });
  test('transport failure and bad body -> network, writes not retried', async () => {
    fetchMock.mockRejectedValue(new TypeError('offline'));
    await expect(api.createRoom('u', 's', {})).rejects.toMatchObject({ code: 'network', status: 0 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    fetchMock.mockResolvedValue({ ok: true, status: 200, json: async () => { throw new Error('bad'); } });
    await expect(api.listRooms('u', 's')).rejects.toMatchObject({ code: 'network' });
  });
});
