// Task 20261017-chat-mentions: pure logic for offsets, validation, trigger
// detection, filtering and rendering runs.
import { describe, test, expect } from 'vitest';
import {
  rangesAreValid, mentionsFromWire, mentionSegments, verifyMentions, prepareSend, applyEdit,
  deleteAcrossMentions, findTrigger, filterMembers, insertMention, toWireMentions, MAX_MENTIONS,
} from './mentions.js';
import { parsePage, reconcileAck } from './chatPaging.js';
import { threadFrameToRow } from '../utils.js';

const M = (userId, username, start) => ({ userId, username, start, length: username.length + 1 });
const MEMBERS = [
  { user_id: 'a', username: 'Matthew' },
  { user_id: 'b', username: 'Mary Ann' },
  { user_id: 'c', username: 'Émile' },
  { user_id: 'd', username: 'tom_matt' },
  { user_id: 'e', username: 'Ada' },
];

describe('UTF-16 offsets', () => {
  test('emoji before a mention counts two code units each', () => {
    const r = insertMention('😀😀 @ma', { start: 5, end: 8, query: 'ma' }, MEMBERS[0], []);
    expect(r.text).toBe('😀😀 @Matthew ');
    expect(r.mentions).toEqual([{ userId: 'a', username: 'Matthew', start: 5, length: 8 }]);
    expect(r.text.slice(5, 13)).toBe('@Matthew');
    expect(r.caret).toBe(14);
  });
  test('accented and astral usernames measure in code units', () => {
    const astral = { user_id: 'z', username: 'a😀b' };
    const r = insertMention('@', { start: 0, end: 1, query: '' }, astral, []);
    expect(r.mentions[0].length).toBe('@a😀b'.length);
    expect(r.mentions[0].length).toBe(5);
    const e = insertMention('hi @é', { start: 3, end: 5, query: 'é' }, MEMBERS[2], []);
    expect(e.mentions[0]).toMatchObject({ start: 3, length: 6 });
  });
  test('no second space when whitespace already follows; caret moves past it', () => {
    const r = insertMention('@ma there', { start: 0, end: 3, query: 'ma' }, MEMBERS[0], []);
    expect(r.text).toBe('@Matthew there');
    expect(r.caret).toBe(9);
  });
  test('inserting before an existing mention shifts it', () => {
    const existing = [M('e', 'Ada', 7)];
    const r = insertMention('@ma hi @Ada', { start: 0, end: 3, query: 'ma' }, MEMBERS[0], existing);
    expect(r.text).toBe('@Matthew hi @Ada');
    expect(r.mentions.map(m => m.userId)).toEqual(['a', 'e']);
    r.mentions.forEach(m => expect(r.text.slice(m.start, m.start + m.length)).toBe(`@${m.username}`));
  });
});

describe('applyEdit keeps ranges correct', () => {
  const text = 'hi @Ada and @Matthew ok';
  const ms = [M('e', 'Ada', 3), M('a', 'Matthew', 12)];
  test('typing before shifts both', () => {
    const next = applyEdit(text, 'yo! hi @Ada and @Matthew ok', ms);
    expect(next.map(m => m.start)).toEqual([7, 16]);
    next.forEach(m => expect(('yo! hi @Ada and @Matthew ok').slice(m.start, m.start + m.length)).toBe(`@${m.username}`));
  });
  test('emoji typed between shifts by two units', () => {
    const t2 = 'hi 😀@Ada and @Matthew ok';
    const next = applyEdit('hi @Ada and @Matthew ok', t2, ms);
    expect(next.map(m => m.start)).toEqual([5, 14]);
  });
  test('editing inside a mention drops only that mention', () => {
    const t2 = text.replace('@Ada', '@Aa');
    const next = applyEdit(text, t2, ms);
    expect(next.map(m => m.userId)).toEqual(['a']);
    expect(next[0].start).toBe(11);
  });
  test('word character typed against the end drops it; space or punctuation keeps it', () => {
    expect(applyEdit('@Ada', '@Adax', [M('e', 'Ada', 0)])).toEqual([]);
    expect(applyEdit('@Ada', '@Ada,', [M('e', 'Ada', 0)])).toHaveLength(1);
    expect(applyEdit('@Ada', '@Ada ', [M('e', 'Ada', 0)])).toHaveLength(1);
  });
  test('typing at the very start keeps and shifts', () => {
    expect(applyEdit('@Ada', 'x @Ada', [M('e', 'Ada', 0)])[0].start).toBe(2);
  });
  test('deleting text after the mention leaves it alone', () => {
    expect(applyEdit('@Ada hello', '@Ada hell', [M('e', 'Ada', 0)])[0].start).toBe(0);
  });
  test('result never contains a range that no longer matches', () => {
    const next = applyEdit('@Ada x', '@Adb x', [M('e', 'Ada', 0)]);
    expect(next).toEqual([]);
  });
  test('no mentions in, none out', () => {
    expect(applyEdit('a', 'ab', [])).toEqual([]);
  });
  test('pasting over a selection that spans a mention drops it', () => {
    expect(applyEdit('a @Ada b', 'a Q b', [M('e', 'Ada', 2)])).toEqual([]);
  });
});

describe('deleteAcrossMentions (backspace removes a whole mention)', () => {
  const text = 'hey @Ada ok';
  const ms = [M('e', 'Ada', 4)];
  test('backspace at the end of the mention removes it', () => {
    const r = deleteAcrossMentions(text, ms, 8, 8, 'Backspace');
    expect(r).toEqual({ text: 'hey  ok', mentions: [], caret: 4 });
  });
  test('backspace after the trailing space removes mention and space', () => {
    const r = deleteAcrossMentions(text, ms, 9, 9, 'Backspace');
    expect(r.text).toBe('hey ok');
    expect(r.mentions).toEqual([]);
  });
  test('forward delete at the start removes it; later mentions shift', () => {
    const t = '@Ada @Matthew';
    const r = deleteAcrossMentions(t, [M('e', 'Ada', 0), M('a', 'Matthew', 5)], 0, 0, 'Delete');
    expect(r.text).toBe(' @Matthew');
    expect(r.mentions).toEqual([{ userId: 'a', username: 'Matthew', start: 1, length: 8 }]);
  });
  test('selection partly over a mention removes the whole mention', () => {
    const r = deleteAcrossMentions(text, ms, 2, 6, 'Backspace');
    expect(r.text).toBe('he ok');
    expect(r.mentions).toEqual([]);
  });
  test('ordinary backspace elsewhere is left to the browser', () => {
    expect(deleteAcrossMentions(text, ms, 2, 2, 'Backspace')).toBeNull();
    expect(deleteAcrossMentions(text, [], 8, 8, 'Backspace')).toBeNull();
  });
});

describe('prepareSend / verifyMentions', () => {
  test('leading trim shifts offsets and the trimmed text is what is measured', () => {
    const r = prepareSend('   hi @Ada  ', [M('e', 'Ada', 6)]);
    expect(r.text).toBe('hi @Ada');
    expect(r.mentions).toEqual([{ userId: 'e', username: 'Ada', start: 3, length: 4 }]);
  });
  test('a stale range is dropped, never sent', () => {
    expect(prepareSend('hi @Adx', [M('e', 'Ada', 3)]).mentions).toEqual([]);
  });
  test('duplicate users, overlaps and the cap are enforced', () => {
    expect(verifyMentions('@Ada @Ada', [M('e', 'Ada', 0), M('e', 'Ada', 5)])).toHaveLength(1);
    const many = Array.from({ length: 12 }, (_, i) => ({ userId: `u${i}`, username: `n${i}`, start: i * 4, length: 3 }));
    const t = Array.from({ length: 12 }, (_, i) => `@n${i}`).join(' ');
    const ok = many.map((m, i) => ({ ...m, start: t.indexOf(`@n${i}`) }));
    expect(verifyMentions(t, ok)).toHaveLength(MAX_MENTIONS);
  });
  test('wire shape has exactly the three contract keys', () => {
    expect(toWireMentions([M('e', 'Ada', 3)])).toEqual([{ user_id: 'e', start: 3, length: 4 }]);
  });
});

describe('findTrigger', () => {
  test('opens at index 0 and after whitespace', () => {
    expect(findTrigger('@', 1)).toEqual({ start: 0, end: 1, query: '' });
    expect(findTrigger('hi @ma', 6)).toEqual({ start: 3, end: 6, query: 'ma' });
    expect(findTrigger('hi\n@ma', 6)).toMatchObject({ start: 3 });
  });
  test('does not open mid-word or for an email', () => {
    expect(findTrigger('a@b', 3)).toBeNull();
    expect(findTrigger('mail me a@b.com', 15)).toBeNull();
  });
  test('closes once whitespace sits between the @ and the caret, or the caret moves out', () => {
    expect(findTrigger('hi @ma ', 7)).toBeNull();
    expect(findTrigger('hi @ma there', 4)).toMatchObject({ query: '' });
    expect(findTrigger('hi there', 3)).toBeNull();
    expect(findTrigger('', 0)).toBeNull();
  });
  test('works after an emoji', () => {
    expect(findTrigger('😀 @x', 5)).toEqual({ start: 3, end: 5, query: 'x' });
  });
  test('does not reopen inside an inserted mention', () => {
    expect(findTrigger('@Ada ', 4, [M('e', 'Ada', 0)])).toBeNull();
    expect(findTrigger('@Ada @', 6, [M('e', 'Ada', 0)])).toMatchObject({ start: 5 });
  });
});

describe('filterMembers', () => {
  const names = (q, ex) => filterMembers(MEMBERS, q, ex).map(m => m.username);
  test('empty query lists everyone in member order', () => {
    expect(names('')).toEqual(['Matthew', 'Mary Ann', 'Émile', 'tom_matt', 'Ada']);
  });
  test('prefix first, then word start, then contains; case-insensitive', () => {
    expect(names('ma')).toEqual(['Matthew', 'Mary Ann', 'tom_matt']);
    expect(names('ANN')).toEqual(['Mary Ann']);
    expect(names('att')).toEqual(['Matthew', 'tom_matt']);
    expect(names('é')).toEqual(['Émile']);
  });
  test('excluded ids never appear; no match is an empty list', () => {
    expect(names('ma', ['a'])).toEqual(['Mary Ann', 'tom_matt']);
    expect(names('zzz')).toEqual([]);
  });
  test('regex metacharacters in the query are literal', () => {
    expect(names('.*')).toEqual([]);
    expect(names('(')).toEqual([]);
  });
});

describe('wire validation and rendering runs', () => {
  const text = 'hi @Matthew, hello';
  const wire = [{ user_id: 'ABC', start: 3, length: 8, username: 'Matthew' }];
  test('valid ranges parse with a lowercased id', () => {
    expect(mentionsFromWire(wire, text)).toEqual([{ userId: 'abc', start: 3, length: 8, username: 'Matthew' }]);
  });
  test('absent, null, empty are no mentions', () => {
    expect(mentionsFromWire(undefined, text)).toBeNull();
    expect(mentionsFromWire(null, text)).toBeNull();
    expect(mentionsFromWire([], text)).toBeNull();
  });
  test('invalid ranges render plain (null)', () => {
    const bad = (e) => mentionsFromWire([{ user_id: 'a', start: 3, length: 8, ...e }], text);
    expect(bad({ start: 15 })).toBeNull();          // beyond the text
    expect(bad({ start: 4 })).toBeNull();           // not on an "@"
    expect(bad({ length: 1 })).toBeNull();
    expect(bad({ start: -1 })).toBeNull();
    expect(bad({ start: 3.5 })).toBeNull();
    expect(bad({ start: '3' })).toBeNull();
    expect(bad({ user_id: 5 })).toBeNull();
    expect(mentionsFromWire([{ user_id: 'a', start: 3, length: 8 }, { user_id: 'b', start: 5, length: 4 }], text)).toBeNull(); // overlap
    expect(mentionsFromWire([{ user_id: 'a', start: 0, length: 2 }], 'xx')).toBeNull();
    expect(mentionsFromWire('nope', text)).toBeNull();
    expect(mentionsFromWire([null], text)).toBeNull();
  });
  test('unsorted ranges are invalid', () => {
    const t = '@a @b';
    expect(mentionsFromWire([{ user_id: 'b', start: 3, length: 2 }, { user_id: 'a', start: 0, length: 2 }], t)).toBeNull();
  });
  test('a range that splits a surrogate pair is invalid', () => {
    expect(rangesAreValid('@😀x', [{ start: 0, length: 2 }])).toBe(false);
    expect(rangesAreValid('@😀x', [{ start: 0, length: 3 }])).toBe(true);
  });
  test('segments: plain, bold run, plain; username wins over the stored slice', () => {
    const ms = mentionsFromWire(wire, text);
    expect(mentionSegments(text, ms)).toEqual([
      { type: 'text', text: 'hi ' },
      { type: 'mention', text: '@Matthew' },
      { type: 'text', text: ', hello' },
    ]);
    const renamed = mentionsFromWire([{ user_id: 'a', start: 3, length: 8, username: 'Matt' }], text);
    expect(mentionSegments(text, renamed).map(s => s.text).join('')).toBe('hi @Matt, hello');
  });
  test('without a username the stored slice is shown; mention at start and end', () => {
    const t = '@Ada';
    expect(mentionSegments(t, [{ userId: 'a', start: 0, length: 4 }])).toEqual([{ type: 'mention', text: '@Ada' }]);
  });
  test('invalid or missing mentions give a single plain run', () => {
    expect(mentionSegments(text, null)).toEqual([{ type: 'text', text }]);
    expect(mentionSegments(text, [{ userId: 'a', start: 99, length: 4 }])).toEqual([{ type: 'text', text }]);
  });
  test('emoji before a mention', () => {
    const t = '😀 @Ada!';
    const ms = mentionsFromWire([{ user_id: 'a', start: 3, length: 4, username: 'Ada' }], t);
    expect(mentionSegments(t, ms).map(s => s.type)).toEqual(['text', 'mention', 'text']);
  });
});

describe('consumers tolerate the field', () => {
  test('history page rows without mentions have no mentions key; with ones they parse', () => {
    const page = parsePage({
      page: { has_more: false },
      messages: [
        { id: 'm1', text: 'plain', timestamp: 't', from_user: 'x' },
        { id: 'm2', text: 'yo @Ada', timestamp: 't', from_user: 'x', mentions: [{ user_id: 'E', start: 3, length: 4, username: 'Ada' }] },
        { id: 'm3', text: 'bad @Ada', timestamp: 't', from_user: 'x', mentions: [{ user_id: 'E', start: 40, length: 4 }] },
      ],
    });
    expect('mentions' in page.messages[0]).toBe(false);
    expect(page.messages[1].mentions).toEqual([{ userId: 'e', start: 3, length: 4, username: 'Ada' }]);
    expect('mentions' in page.messages[2]).toBe(false);
  });
  test('thread frames carry mentions against the body', () => {
    const row = threadFrameToRow({ id: 't1', body: 'hey @Ada', created_at: 'x', sender: 's', mentions: [{ user_id: 'e', start: 4, length: 4, username: 'Ada' }] });
    expect(row.mentions).toHaveLength(1);
    expect('mentions' in threadFrameToRow({ id: 't2', body: 'hey', created_at: 'x', sender: 's' })).toBe(false);
  });
  test('an ack replaces the optimistic mentions; an ack without them keeps them', () => {
    const current = [{ clientRef: 'r', text: 'hi @Ada', pending: true, mentions: [{ userId: 'e', username: 'Ada', start: 3, length: 4 }] }];
    const kept = reconcileAck(current, { client_ref: 'r', id: 'srv' });
    expect(kept[0].mentions).toEqual(current[0].mentions);
    const replaced = reconcileAck(current, { client_ref: 'r', id: 'srv', mentions: [{ user_id: 'e', start: 3, length: 4, username: 'Adaline' }] });
    expect(replaced[0].mentions[0].username).toBe('Adaline');
  });
});
