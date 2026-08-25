// Regression test for task 20260824-web-notes-untitled-placeholder-rows.
// Mirrors src/utils.test.js for the legacy vanilla-JS unwrapNotesEnvelope
// (used by frontend/js/notes.js, the non-React reader.html/index.html
// sidebar). See src/utils.test.js for the full failure-mode writeup.
//
// Run with: cd frontend && npm test -- --run js/utils.test.js
import { describe, test, expect } from 'vitest';
import { unwrapNotesEnvelope } from './utils.js';

describe('unwrapNotesEnvelope (frontend/js)', () => {
  test('unwraps a well-formed envelope to just its notes map', () => {
    const envelope = {
      notes: { 'note-1': { title: 'A' }, 'note-2': { title: 'B' } },
      next_cursor_created_at: '2026-08-17T00:00:00Z',
      next_cursor_id: 'note-2',
      has_more: true,
    };
    expect(unwrapNotesEnvelope(envelope)).toBe(envelope.notes);
  });

  test('an empty notes map unwraps to an empty object', () => {
    expect(unwrapNotesEnvelope({ notes: {}, next_cursor_created_at: null, next_cursor_id: null, has_more: false }))
      .toEqual({});
  });

  test('a raw envelope missing the .notes key fails safe instead of exposing its 4 keys as fake notes', () => {
    const rawEnvelopeMissingNotesKey = {
      next_cursor_created_at: '2026-08-17T00:00:00Z',
      next_cursor_id: 'note-2',
      has_more: true,
    };
    expect(unwrapNotesEnvelope(rawEnvelopeMissingNotesKey)).toEqual({});
  });

  test('a bare pre-pagination {note_id: note} dict (old backend shape) is treated as "no notes"', () => {
    const barePreShape = {
      'note-1': { title: 'A', text: 'body a' },
      'note-2': { title: 'B', text: 'body b' },
    };
    expect(unwrapNotesEnvelope(barePreShape)).toEqual({});
  });

  test('a non-object .notes (string) fails safe', () => {
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
