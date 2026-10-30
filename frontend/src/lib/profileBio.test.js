// Task 20261030-user-profiles testing step 8: client mirror of the server's
// bio counting rule (NFC + collapsed whitespace, trimmed) and counter tones.
import { describe, test, expect } from 'vitest';
import { normalizeBioDraft, bioCounter, BIO_WARN_REMAINING } from './profileBio.js';

describe('normalizeBioDraft', () => {
  test('collapses whitespace and newlines to single spaces and trims', () => {
    expect(normalizeBioDraft('  a \n\n b\t c  ')).toBe('a b c');
  });
  test('NFC normalizes', () => {
    expect(normalizeBioDraft('é')).toBe('é');
  });
  test('null and undefined become empty', () => {
    expect(normalizeBioDraft(null)).toBe('');
    expect(normalizeBioDraft(undefined)).toBe('');
  });
});

describe('bioCounter', () => {
  test('normal tone shows length/max', () => {
    const c = bioCounter('hello');
    expect(c).toMatchObject({ length: 5, remaining: 155, over: 0, tone: 'normal', label: '5/160' });
  });
  test('warn tone at exactly 20 left', () => {
    const c = bioCounter('a'.repeat(160 - BIO_WARN_REMAINING));
    expect(c.tone).toBe('warn');
    expect(c.label).toBe('20 left');
  });
  test('exactly 160 is allowed (warn, not over)', () => {
    const c = bioCounter('a'.repeat(160));
    expect(c.over).toBe(0);
    expect(c.tone).toBe('warn');
    expect(c.label).toBe('0 left');
  });
  test('161 is over by 1', () => {
    const c = bioCounter('a'.repeat(161));
    expect(c.over).toBe(1);
    expect(c.tone).toBe('over');
    expect(c.label).toBe('Over by 1');
  });
  test('length is counted after normalization, so padding and newlines do not count', () => {
    expect(bioCounter('  ' + 'a'.repeat(160) + '\n\n').over).toBe(0);
    expect(bioCounter('a'.repeat(80) + '\n\n\n\n' + 'b'.repeat(79)).over).toBe(0);
  });
});
