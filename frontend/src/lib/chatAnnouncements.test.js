// Task 20261030-chat-announcements testing: pure helpers for announcement
// lines in a group chat timeline.
import { describe, test, expect } from 'vitest';
import {
  parseCard, announcementFields, isAnnouncementLine, isOwnAnnouncementFrame, parseSync,
  removeAnnouncementLines, announcementLinesFromHistory, mergeAnnouncementLines,
  openErrorMessage, chatPostBody, OPEN_ERROR, GONE_ERROR,
} from './chatAnnouncements.js';
import { toMessage } from './chatPaging.js';
import { insertRestored } from './threadsApi.js';

const card = (o = {}) => ({ id: 'a1', title: 'Potluck', description: 'Bring food', creator_username: 'ann', ...o });
const line = (o = {}) => ({ id: 'm1', text: 'posted an announcement', system_kind: 'announcement', announcement: card(), ...o });

describe('parseCard', () => {
  test('keeps usable fields and defaults the rest', () => {
    expect(parseCard(card({ edited: true, banner_url: 'https://x/b.png' }))).toMatchObject({
      id: 'a1', title: 'Potluck', description: 'Bring food', edited: true, banner_url: 'https://x/b.png', location: null,
    });
  });
  test('empty title string is still a card; missing id/title is not', () => {
    expect(parseCard(card({ title: '' }))).not.toBeNull();
    expect(parseCard({ title: 't' })).toBeNull();
    expect(parseCard({ id: 'a' })).toBeNull();
    expect(parseCard({ id: 5, title: 't' })).toBeNull();
    expect(parseCard(null)).toBeNull();
    expect(parseCard('x')).toBeNull();
  });
  test('wrong-typed optional fields are dropped, edited only true when boolean true', () => {
    const c = parseCard(card({ banner_url: 5, title_color: {}, edited: 'yes' }));
    expect(c.banner_url).toBeNull();
    expect(c.title_color).toBeNull();
    expect(c.edited).toBe(false);
  });
});

describe('announcementFields', () => {
  test('only for system_kind announcement with a usable card', () => {
    expect(announcementFields(line())).toMatchObject({ systemKind: 'announcement', announcement: { id: 'a1' } });
    expect(announcementFields(line({ system_kind: 'pin' }))).toEqual({});
    expect(announcementFields({ text: 'hi' })).toEqual({});
    expect(announcementFields(null)).toEqual({});
  });
  test('unusable card yields no fields, so the row falls back to plain text (no placeholder)', () => {
    expect(announcementFields(line({ announcement: { title: 'x' } }))).toEqual({});
    expect(announcementFields(line({ announcement: undefined }))).toEqual({});
  });
  test('toMessage wires announcement fields through (history path)', () => {
    const m = toMessage({ id: 'm1', text: 'posted an announcement', sender: 'ann', timestamp: '2026-10-30T10:00:00Z',
      system_kind: 'announcement', announcement: card({ edited: true }) }, false);
    expect(m.systemKind).toBe('announcement');
    expect(m.announcement.edited).toBe(true);
    expect(isAnnouncementLine(m)).toBe(true);
    const plain = toMessage({ id: 'm2', text: 'hello', sender: 'bob', timestamp: '2026-10-30T10:00:00Z' }, false);
    expect(plain.announcement).toBeUndefined();
    expect(isAnnouncementLine(plain)).toBe(false);
  });
});

describe('isOwnAnnouncementFrame (self-echo exception)', () => {
  const frame = { system_kind: 'announcement', from_user: 'u1', announcement: card() };
  test('kept for the poster only, with a usable card', () => {
    expect(isOwnAnnouncementFrame(frame, 'u1')).toBe(true);
    expect(isOwnAnnouncementFrame(frame, 'u2')).toBe(false);
    expect(isOwnAnnouncementFrame(frame, '')).toBe(false);
    expect(isOwnAnnouncementFrame({ ...frame, announcement: null }, 'u1')).toBe(false);
    expect(isOwnAnnouncementFrame({ ...frame, system_kind: 'pin' }, 'u1')).toBe(false);
    expect(isOwnAnnouncementFrame(null, 'u1')).toBe(false);
  });
});

describe('parseSync', () => {
  test('accepts the three actions', () => {
    for (const action of ['updated', 'deleted', 'restored']) {
      expect(parseSync({ type: 'announcement_updated', announcement_id: 'a1', action })).toEqual({ announcementId: 'a1', action });
    }
  });
  test('rejects wrong type, missing id, unknown action', () => {
    expect(parseSync({ type: 'message', announcement_id: 'a1', action: 'updated' })).toBeNull();
    expect(parseSync({ type: 'announcement_updated', action: 'updated' })).toBeNull();
    expect(parseSync({ type: 'announcement_updated', announcement_id: 'a1', action: 'purged' })).toBeNull();
    expect(parseSync(undefined)).toBeNull();
  });
});

describe('removeAnnouncementLines', () => {
  const a = { id: 'm1', systemKind: 'announcement', announcement: { id: 'a1' } };
  const b = { id: 'm2', systemKind: 'announcement', announcement: { id: 'a2' } };
  const t = { id: 'm3', text: 'hi' };
  test('removes only the matching announcement line', () => {
    expect(removeAnnouncementLines([a, b, t], 'a1')).toEqual([b, t]);
  });
  test('returns the same array when nothing matches (no re-render)', () => {
    const list = [a, t];
    expect(removeAnnouncementLines(list, 'zzz')).toBe(list);
  });
});

describe('announcementLinesFromHistory', () => {
  const to = (r, mine) => ({ id: r.id, mine, ...announcementFields(r) });
  test('paged shape', () => {
    const out = announcementLinesFromHistory({ messages: [line(), { id: 'x', text: 'hi' }] }, to);
    expect(out.map(m => m.id)).toEqual(['m1']);
  });
  test('legacy host/other shape keeps mine flag', () => {
    const out = announcementLinesFromHistory({ host_msgs: [line({ id: 'h' })], other_msgs: [line({ id: 'o' })] }, to);
    expect(out.map(m => [m.id, m.mine])).toEqual([['h', true], ['o', false]]);
  });
  test('garbage bodies give nothing', () => {
    expect(announcementLinesFromHistory(null, to)).toEqual([]);
    expect(announcementLinesFromHistory('x', to)).toEqual([]);
    expect(announcementLinesFromHistory({}, to)).toEqual([]);
  });
});

describe('mergeAnnouncementLines', () => {
  const mk = (id, title, ts) => ({ id, timestamp: ts, systemKind: 'announcement', announcement: { id: `a-${id}`, title } });
  test('edited card replaces in place; unrelated rows and older lines untouched', () => {
    const current = [mk('m1', 'Old', '2026-10-30T10:00:00Z'), { id: 'x', timestamp: '2026-10-30T10:01:00Z', text: 'hi' }];
    const out = mergeAnnouncementLines(current, [mk('m1', 'New', '2026-10-30T10:00:00Z')], insertRestored);
    expect(out[0].announcement.title).toBe('New');
    expect(out[1]).toBe(current[1]);
    expect(out).toHaveLength(2);
  });
  test('identical card keeps the same array', () => {
    const current = [mk('m1', 'Same', '2026-10-30T10:00:00Z')];
    expect(mergeAnnouncementLines(current, [mk('m1', 'Same', '2026-10-30T10:00:00Z')], insertRestored)).toBe(current);
  });
  test('restored line is inserted at its time position', () => {
    const current = [{ id: 'a', timestamp: '2026-10-30T10:00:00Z' }, { id: 'c', timestamp: '2026-10-30T12:00:00Z' }];
    const out = mergeAnnouncementLines(current, [mk('m2', 'Back', '2026-10-30T11:00:00Z')], insertRestored);
    expect(out.map(m => m.id)).toEqual(['a', 'm2', 'c']);
  });
  test('lines missing from the fresh window are left alone', () => {
    const current = [mk('old', 'Old page', '2026-01-01T00:00:00Z')];
    expect(mergeAnnouncementLines(current, [], insertRestored)).toBe(current);
  });
});

describe('errors and create body', () => {
  test('404 -> gone copy, anything else -> generic', () => {
    expect(openErrorMessage({ status: 404 })).toBe(GONE_ERROR);
    expect(openErrorMessage({ status: 500 })).toBe(OPEN_ERROR);
    expect(openErrorMessage(new Error('x'))).toBe(OPEN_ERROR);
    expect(openErrorMessage(null)).toBe(OPEN_ERROR);
  });
  test('chatPostBody adds post_to_chat true without mutating the input', () => {
    const body = { title: 't', description: 'd' };
    expect(chatPostBody(body)).toEqual({ title: 't', description: 'd', post_to_chat: true });
    expect(body.post_to_chat).toBeUndefined();
  });
});
