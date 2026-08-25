// Regression test for task 20260824-web-notes-untitled-placeholder-rows.
//
// Pins the exact pre-8710a27a failure mode from the reported screenshot: the
// old code did `allNotes = await res.json()` / `const data = await
// res.json()`, i.e. treated the *whole* keyset-paginated envelope
// ({notes, next_cursor_created_at, next_cursor_id, has_more} -- exactly 4
// top-level keys) as if it were the note-id-keyed map. None of those 4
// envelope keys has .title/.text/.verses, so each rendered as an empty
// "Untitled" card grouped under "General" (the no-verse-tag fallback) --
// which is exactly "4 Untitled/General rows" from the bug report.
//
// unwrapNotesEnvelope() is the defensive guard added in this task: it only
// trusts payload.notes as the notes map when payload.notes is present *and*
// an object; any other shape is treated as "no notes" (returns {}) rather
// than risking that same fabricated-row symptom, whether from a genuinely
// missing .notes key, a non-object .notes, or a caller accidentally passing
// the raw envelope itself where a notes map was expected.
//
// Run with: cd frontend && npm test -- --run src/utils.test.js
import { describe, test, expect } from 'vitest';
import { unwrapNotesEnvelope } from './utils.js';

describe('unwrapNotesEnvelope', () => {
  test('unwraps a well-formed envelope to just its notes map', () => {
    const envelope = {
      notes: { 'note-1': { title: 'A' }, 'note-2': { title: 'B' } },
      next_cursor_created_at: '2026-08-17T00:00:00Z',
      next_cursor_id: 'note-2',
      has_more: true,
    };
    expect(unwrapNotesEnvelope(envelope)).toBe(envelope.notes);
  });

  test('an empty notes map unwraps to an empty object, not falsy/undefined', () => {
    expect(unwrapNotesEnvelope({ notes: {}, next_cursor_created_at: null, next_cursor_id: null, has_more: false }))
      .toEqual({});
  });

  test('the pre-8710a27a failure mode: passing the raw envelope itself as "payload.notes" input fails safe, not iterated as 4 fake notes', () => {
    // Simulates what would happen if a caller regressed to the old
    // `allNotes = envelope` bug and then that whole envelope got handed to
    // unwrapNotesEnvelope one level too high (i.e. envelope.notes doesn't
    // exist because "envelope" was mistakenly passed where "envelope.notes"
    // was, or a backend regression flattened the shape). The 4 top-level
    // keys (notes, next_cursor_created_at, next_cursor_id, has_more) must
    // never be treated as note ids.
    const rawEnvelopeMissingNotesKey = {
      next_cursor_created_at: '2026-08-17T00:00:00Z',
      next_cursor_id: 'note-2',
      has_more: true,
      // no .notes key at all -- e.g. a backend regression back to the old
      // bare {note_id: note} shape would also fall in here, since none of
      // its top-level keys is literally "notes".
    };
    expect(unwrapNotesEnvelope(rawEnvelopeMissingNotesKey)).toEqual({});
  });

  test('a bare pre-pagination {note_id: note} dict (old backend shape) is treated as "no notes", not iterated as note ids', () => {
    const barePreShape = {
      'note-1': { title: 'A', text: 'body a' },
      'note-2': { title: 'B', text: 'body b' },
    };
    expect(unwrapNotesEnvelope(barePreShape)).toEqual({});
  });

  test('a non-object .notes (string) fails safe instead of being iterated char-by-char', () => {
    expect(unwrapNotesEnvelope({ notes: 'not-an-object' })).toEqual({});
  });

  test('a null .notes fails safe', () => {
    expect(unwrapNotesEnvelope({ notes: null })).toEqual({});
  });

  test('null/undefined payload fails safe', () => {
    expect(unwrapNotesEnvelope(null)).toEqual({});
    expect(unwrapNotesEnvelope(undefined)).toEqual({});
  });
});
