// Tests for the per-note character cap helpers in noteFormat.js
// (task 20260929-free-note-char-cap). The server counts Python len() of the
// text exactly as sent (rich-text HTML); these helpers must match it.
//
// Run with: cd frontend && npm test -- --run src/components/panels/notes/noteFormat.charCap.test.js
import { describe, test, expect } from 'vitest';
import {
  countCodePoints, approxWords, noteLimitState, isNoteSaveBlocked, NOTE_WARN_RATIO,
} from './noteFormat.js';

describe('countCodePoints — parity with server len() (code points, not UTF-16 units)', () => {
  test('ASCII, empty and nullish', () => {
    expect(countCodePoints('abc')).toBe(3);
    expect(countCodePoints('')).toBe(0);
    expect(countCodePoints(null)).toBe(0);
    expect(countCodePoints(undefined)).toBe(0);
  });

  test('astral emoji count as one code point (JS .length would say 2)', () => {
    const s = '\u{1F600}';
    expect(s.length).toBe(2);
    expect(countCodePoints(s)).toBe(1);
    expect(countCodePoints('a\u{1F600}\u{1F64F}b')).toBe(4);
  });

  test('ZWJ emoji sequence counts every scalar (not one grapheme)', () => {
    // man + ZWJ + woman + ZWJ + girl = 5 code points, one grapheme
    const family = '\u{1F468}‍\u{1F469}‍\u{1F467}';
    expect(countCodePoints(family)).toBe(5);
  });

  test('combining marks count separately', () => {
    expect(countCodePoints('é')).toBe(2);
  });

  test('CJK BMP characters count one each', () => {
    expect(countCodePoints('你好世界')).toBe(4);
  });

  test('CRLF counts as 2, no normalization', () => {
    expect(countCodePoints('a\r\nb')).toBe(4);
  });

  test('counts the rich-text HTML as sent, tags included', () => {
    expect(countCodePoints('<b>hi</b>')).toBe(9);
    expect(countCodePoints('<p>\u{1F600}</p>')).toBe(8);
  });

  test('30,000 boundary strings', () => {
    expect(countCodePoints('x'.repeat(30000))).toBe(30000);
    expect(countCodePoints('\u{1F600}'.repeat(30000))).toBe(30000);
  });
});

describe('approxWords', () => {
  test('strips tags and counts whitespace-separated words', () => {
    expect(approxWords('<p>Hello <b>brave</b> new world</p>')).toBe(4);
  });
  test('empty / whitespace-only / nullish is 0', () => {
    expect(approxWords('')).toBe(0);
    expect(approxWords('<p>   </p>')).toBe(0);
    expect(approxWords(null)).toBe(0);
  });
  test('does not count tag attributes as words', () => {
    expect(approxWords('<span style="color: red">one</span>')).toBe(1);
  });
});

describe('noteLimitState', () => {
  const LIMIT = 30000;
  test('no limit known means never warn/over', () => {
    expect(noteLimitState(999999, null)).toBe('ok');
    expect(noteLimitState(5, 0)).toBe('ok');
    expect(noteLimitState(5, undefined)).toBe('ok');
  });
  test('normal below 90%', () => {
    expect(noteLimitState(0, LIMIT)).toBe('ok');
    expect(noteLimitState(26999, LIMIT)).toBe('ok');
  });
  test('warn from exactly 90% up to and including the limit', () => {
    expect(NOTE_WARN_RATIO).toBe(0.9);
    expect(noteLimitState(27000, LIMIT)).toBe('warn');
    expect(noteLimitState(30000, LIMIT)).toBe('warn');
  });
  test('over strictly above the limit (30,001)', () => {
    expect(noteLimitState(30001, LIMIT)).toBe('over');
  });
  test('works with the paid limit', () => {
    expect(noteLimitState(90000, 100000)).toBe('warn');
    expect(noteLimitState(100001, 100000)).toBe('over');
  });
});

describe('isNoteSaveBlocked — shrink-only grandfather rule', () => {
  const LIMIT = 30000;
  test('within the limit is never blocked (create or edit)', () => {
    expect(isNoteSaveBlocked(30000, LIMIT, 0, false)).toBe(false);
    expect(isNoteSaveBlocked(30000, LIMIT, 10, true)).toBe(false);
  });
  test('unknown limit never blocks (server still enforces)', () => {
    expect(isNoteSaveBlocked(999999, null, 0, false)).toBe(false);
  });
  test('new note over the limit is blocked', () => {
    expect(isNoteSaveBlocked(30001, LIMIT, 0, false)).toBe(true);
  });
  test('existing over-limit note: shorter is allowed', () => {
    expect(isNoteSaveBlocked(34000, LIMIT, 35000, true)).toBe(false);
  });
  test('existing over-limit note: same length is allowed', () => {
    expect(isNoteSaveBlocked(35000, LIMIT, 35000, true)).toBe(false);
  });
  test('existing over-limit note: growing by even one is blocked', () => {
    expect(isNoteSaveBlocked(35001, LIMIT, 35000, true)).toBe(true);
  });
  test('existing under-limit note pushed over is blocked', () => {
    expect(isNoteSaveBlocked(30001, LIMIT, 29000, true)).toBe(true);
  });
  test('paid limit 100,000 uses the same rule', () => {
    expect(isNoteSaveBlocked(100001, 100000, 0, false)).toBe(true);
    expect(isNoteSaveBlocked(100000, 100000, 0, false)).toBe(false);
    expect(isNoteSaveBlocked(100500, 100000, 101000, true)).toBe(false);
  });
});
