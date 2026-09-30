// NoteEditor per-note character counter / save gating
// (task 20260929-free-note-char-cap). The limit is a prop fed from the
// server's usage endpoint; small limits are used here to keep bodies small.
//
// Run with: cd frontend && npm test -- --run src/components/panels/notes/NoteEditor.charCap.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';

afterEach(() => cleanup());
import NoteEditor from './NoteEditor.jsx';

function renderEditor({ note = null, noteId = null, limit = 100, isSubscribed = false, onSave, onBack } = {}) {
  const save = onSave || vi.fn(async () => true);
  const back = onBack || vi.fn();
  const utils = render(
    <NoteEditor
      note={note} noteId={noteId}
      user={{ user_id: 'u1', username: 'tester' }}
      currentGroupId={null}
      books={['Genesis']} chapterCount={() => 1} verseCount={() => 1}
      noteCharLimit={limit} isSubscribed={isSubscribed}
      onSave={save} onBack={back}
    />
  );
  const body = utils.container.querySelector('.note-body-textarea');
  const type = (html) => { body.innerHTML = html; fireEvent.input(body); };
  const saveBtn = () => screen.getByRole('button', { name: 'Save' });
  const counter = () => utils.container.querySelector('.note-char-counter');
  const live = () => utils.container.querySelector('[role="status"]');
  return { ...utils, body, type, saveBtn, counter, live, save, back };
}

describe('NoteEditor counter states', () => {
  test('no limit known: no counter is rendered and Save is enabled', () => {
    const r = renderEditor({ limit: null });
    expect(r.counter()).toBeNull();
    r.type('x'.repeat(5000));
    expect(r.saveBtn()).not.toBeDisabled();
  });

  test('normal: shows "N / LIMIT characters (~W words)" with no icon or warning text', () => {
    const r = renderEditor({ limit: 100 });
    r.type('hello brave new world');
    expect(r.counter()).toHaveClass('note-char-counter--ok');
    expect(r.counter().textContent).toContain('21 / 100 characters');
    expect(r.counter().textContent).toContain('~4 words');
    expect(r.counter().querySelector('.anticon')).toBeNull();
    expect(r.live().textContent).toBe('');
    expect(r.saveBtn()).not.toBeDisabled();
  });

  test('thousands are formatted with separators for the real-size limits', () => {
    const r = renderEditor({ limit: 30000 });
    r.type('x'.repeat(1234));
    expect(r.counter().textContent).toMatch(/1,234 \/ 30,000 characters/);
  });

  test('warning at 90%: icon + text (not color-only) and a polite announcement', () => {
    const r = renderEditor({ limit: 100 });
    r.type('x'.repeat(90));
    expect(r.counter()).toHaveClass('note-char-counter--warn');
    expect(r.counter().textContent).toContain('Approaching the limit.');
    expect(r.counter().querySelector('.anticon-warning')).toBeTruthy();
    expect(r.live().textContent).toBe('Approaching the character limit.');
    expect(r.live()).toHaveAttribute('aria-live', 'polite');
    expect(r.saveBtn()).not.toBeDisabled();
  });

  test('exactly at the limit is a warning, not over, and Save stays enabled', () => {
    const r = renderEditor({ limit: 100 });
    r.type('x'.repeat(100));
    expect(r.counter()).toHaveClass('note-char-counter--warn');
    expect(r.saveBtn()).not.toBeDisabled();
  });

  test('over limit (new note): icon + chars-over text + announcement, Save disabled', () => {
    const r = renderEditor({ limit: 100 });
    r.type('x'.repeat(130));
    expect(r.counter()).toHaveClass('note-char-counter--over');
    expect(r.counter().textContent).toContain('130 / 100 characters');
    expect(r.counter().textContent).toContain('30 characters over.');
    expect(r.counter().textContent).toContain('Shorten your note to save. Your text is kept.');
    expect(r.counter().querySelector('.anticon-exclamation-circle')).toBeTruthy();
    expect(r.live().textContent).toMatch(/over the character limit\. Saving is disabled/);
    expect(r.saveBtn()).toBeDisabled();
    expect(r.saveBtn()).toHaveAttribute('aria-disabled', 'true');
  });

  test('over limit: free plan sees the upgrade CTA text', () => {
    const r = renderEditor({ limit: 100, isSubscribed: false });
    r.type('x'.repeat(130));
    expect(r.counter().textContent).toContain('Upgrade for a higher limit.');
  });

  test('over limit: paid plan sees NO upgrade CTA', () => {
    const r = renderEditor({ limit: 100000, isSubscribed: true });
    r.type('x'.repeat(100005));
    expect(r.counter().textContent).toContain('5 characters over.');
    expect(r.counter().textContent).not.toMatch(/upgrade/i);
  });

  test('over limit with unknown plan (isSubscribed null) shows no upgrade CTA', () => {
    const r = renderEditor({ limit: 100, isSubscribed: null });
    r.type('x'.repeat(130));
    expect(r.counter().textContent).not.toMatch(/upgrade/i);
  });

  test('counts code points: 60 emoji is 60 characters, not 120', () => {
    const r = renderEditor({ limit: 100 });
    r.type('\u{1F600}'.repeat(60));
    expect(r.counter().textContent).toContain('60 / 100 characters');
    expect(r.counter()).toHaveClass('note-char-counter--ok');
  });

  test('counts the HTML as it will be sent (tags included)', () => {
    const r = renderEditor({ limit: 100 });
    r.type('<b>hi</b>');
    expect(r.counter().textContent).toContain('9 / 100 characters');
  });

  test('going back under the limit re-enables Save and clears the announcement', () => {
    const r = renderEditor({ limit: 100 });
    r.type('x'.repeat(130));
    expect(r.saveBtn()).toBeDisabled();
    r.type('x'.repeat(10));
    expect(r.saveBtn()).not.toBeDisabled();
    expect(r.live().textContent).toBe('');
  });
});

describe('NoteEditor shrink-only save blocking', () => {
  const overNote = { title: 'Big', text: 'y'.repeat(150), public: false, verses: [], replies: [] };

  test('opening an existing over-limit note leaves Save enabled (grandfathered) but shows over state', () => {
    const r = renderEditor({ note: overNote, noteId: 'n1', limit: 100 });
    expect(r.counter()).toHaveClass('note-char-counter--over');
    expect(r.counter().textContent).toContain('50 characters over.');
    expect(r.counter().textContent).toContain('Saving is allowed only if you shorten it.');
    expect(r.saveBtn()).not.toBeDisabled();
  });

  test('existing over-limit note: shortening stays saveable and onSave gets the shortened text', async () => {
    const r = renderEditor({ note: overNote, noteId: 'n1', limit: 100 });
    r.type('y'.repeat(140));
    expect(r.saveBtn()).not.toBeDisabled();
    fireEvent.click(r.saveBtn());
    await waitFor(() => expect(r.save).toHaveBeenCalledTimes(1));
    expect(r.save.mock.calls[0][0].text).toBe('y'.repeat(140));
    expect(r.save.mock.calls[0][1]).toBe('n1');
  });

  test('existing over-limit note: same length stays saveable', () => {
    const r = renderEditor({ note: overNote, noteId: 'n1', limit: 100 });
    r.type('z'.repeat(150));
    expect(r.saveBtn()).not.toBeDisabled();
  });

  test('existing over-limit note: growing by one blocks Save', () => {
    const r = renderEditor({ note: overNote, noteId: 'n1', limit: 100 });
    r.type('y'.repeat(151));
    expect(r.saveBtn()).toBeDisabled();
    expect(r.counter().textContent).toContain('Shorten your note to save.');
  });

  test('existing under-limit note pushed over the limit blocks Save', () => {
    const small = { ...overNote, text: 'y'.repeat(50) };
    const r = renderEditor({ note: small, noteId: 'n1', limit: 100 });
    r.type('y'.repeat(101));
    expect(r.saveBtn()).toBeDisabled();
  });

  test('clicking a disabled Save never calls onSave', () => {
    const r = renderEditor({ limit: 100 });
    r.type('x'.repeat(130));
    fireEvent.click(r.saveBtn());
    expect(r.save).not.toHaveBeenCalled();
  });
});

describe('NoteEditor paste / failed-save draft retention', () => {
  test('pasting past the limit is never truncated: body keeps every character', () => {
    const r = renderEditor({ limit: 100 });
    r.type('x'.repeat(250)); // simulates paste landing in the contentEditable
    expect(r.body.innerHTML).toBe('x'.repeat(250));
    expect(r.counter().textContent).toContain('150 characters over.');
  });

  test('a paste event is not intercepted or default-prevented', () => {
    const r = renderEditor({ limit: 100 });
    const ev = new Event('paste', { bubbles: true, cancelable: true });
    r.body.dispatchEvent(ev);
    expect(ev.defaultPrevented).toBe(false);
  });

  test('failed save (onSave resolves false): editor stays open, draft and title kept, no onBack', async () => {
    const onSave = vi.fn(async () => false);
    const r = renderEditor({ limit: 100000, onSave });
    r.type('<p>my precious draft</p>');
    fireEvent.click(r.saveBtn());
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1));
    await Promise.resolve();
    expect(r.back).not.toHaveBeenCalled();
    expect(r.body.innerHTML).toBe('<p>my precious draft</p>');
  });

  test('successful save closes the editor', async () => {
    const r = renderEditor({ limit: 100000 });
    r.type('fine');
    fireEvent.click(r.saveBtn());
    await waitFor(() => expect(r.back).toHaveBeenCalledTimes(1));
  });
});
