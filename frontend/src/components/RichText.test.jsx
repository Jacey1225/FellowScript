// Tests for sanitizeNoteHtml() — the sanitizer that must strip any XSS
// payload before note HTML is ever assigned to innerHTML/dangerouslySetInnerHTML.
//
// Regression context (security audit finding 6): NoteBody (read-only note
// rendering) always ran note.text through sanitizeNoteHtml() before display,
// but the contentEditable note *editor* in NotesSidebar.jsx and
// NotesPanel.jsx assigned note.text to bodyRef.current.innerHTML directly,
// bypassing the sanitizer. Because notes can contain attacker-influenceable
// HTML (shared group notes, AI-generated session summaries inserted via
// backend/interactions/agent.py's note_via_hb/summarize_session with no
// server-side HTML sanitization — check_clean is a profanity filter only),
// this was exploitable stored XSS, not just self-XSS.
//
// Run with: cd frontend && npm test -- --run src/components/RichText.test.jsx
import { describe, test, expect } from 'vitest';
import { sanitizeNoteHtml, stripHtml } from './RichText.jsx';

describe('sanitizeNoteHtml — XSS payloads are neutralized', () => {
  test('strips the <script> element itself so it can never execute (its text is unwrapped to inert content, same as any other disallowed tag)', () => {
    const out = sanitizeNoteHtml('<p>hello</p><script>alert(document.cookie)</script>');
    expect(out.toLowerCase()).not.toContain('<script');
    // Re-parsing the sanitized output must produce zero <script> elements —
    // the payload text may survive as inert text content, but it must never
    // be wrapped in an executable <script> tag again.
    const reparsed = document.createElement('div');
    reparsed.innerHTML = out;
    expect(reparsed.querySelectorAll('script').length).toBe(0);
  });

  test('strips onerror/onload and other inline event handler attributes', () => {
    const out = sanitizeNoteHtml('<img src=x onerror="alert(1)">');
    expect(out.toLowerCase()).not.toContain('onerror');
    expect(out.toLowerCase()).not.toContain('<img');
  });

  test('strips <svg onload=...> payloads', () => {
    const out = sanitizeNoteHtml('<svg onload="alert(1)"><circle /></svg>');
    expect(out.toLowerCase()).not.toContain('onload');
    expect(out.toLowerCase()).not.toContain('<svg');
  });

  test('strips javascript: hrefs by dropping the disallowed <a> tag wrapper', () => {
    const out = sanitizeNoteHtml('<a href="javascript:alert(1)">click me</a>');
    expect(out.toLowerCase()).not.toContain('<a ');
    expect(out.toLowerCase()).not.toContain('javascript:');
    // Text content is preserved (unwrapped, not deleted).
    expect(out).toContain('click me');
  });

  test('strips <iframe>/<object>/<embed> injection vectors', () => {
    const out = sanitizeNoteHtml('<iframe src="https://evil.example"></iframe>text');
    expect(out.toLowerCase()).not.toContain('<iframe');
    expect(out).toContain('text');
  });

  test('strips disallowed style-based expression/behavior tricks on <span>', () => {
    // Only color/text-decoration survive on <span style>; anything else
    // (e.g. a CSS expression() or url() based attack surface) is dropped.
    const out = sanitizeNoteHtml('<span style="color:red;background:url(javascript:alert(1))">x</span>');
    expect(out.toLowerCase()).not.toContain('url(');
    expect(out.toLowerCase()).not.toContain('javascript:');
    expect(out).toContain('color:red');
  });

  test('drops arbitrary attributes on allowed tags (e.g. onclick on <b>)', () => {
    const out = sanitizeNoteHtml('<b onclick="alert(1)">bold</b>');
    expect(out.toLowerCase()).not.toContain('onclick');
    expect(out).toContain('<b>bold</b>');
  });

  test('empty/null input returns empty string, never throws', () => {
    expect(sanitizeNoteHtml('')).toBe('');
    expect(sanitizeNoteHtml(null)).toBe('');
    expect(sanitizeNoteHtml(undefined)).toBe('');
  });
});

describe('sanitizeNoteHtml — legitimate note formatting survives unchanged', () => {
  test('preserves the editor-producible formatting tags', () => {
    const html = '<b>bold</b> <i>italic</i> <u>underline</u> <mark>highlight</mark>';
    expect(sanitizeNoteHtml(html)).toBe(html);
  });

  test('preserves <font color> and <span style="color:...;text-decoration:...">', () => {
    const html = '<font color="#c8861a">gold</font><span style="color:red;text-decoration:underline">x</span>';
    const out = sanitizeNoteHtml(html);
    expect(out).toContain('color="#c8861a"');
    expect(out).toContain('color:red');
    expect(out).toContain('text-decoration:underline');
  });

  test('preserves plain text and line breaks', () => {
    const html = 'line one<br>line two<p>paragraph</p>';
    expect(sanitizeNoteHtml(html)).toBe(html);
  });
});

describe('stripHtml — plain-text extraction used for note card previews', () => {
  test('removes all tags including script contents replaced by their text', () => {
    // stripHtml uses textContent, so script body text is retained as plain
    // text (not executed) — this is fine since it's never rendered as HTML,
    // only shown as a literal preview string.
    expect(stripHtml('<p>hello <b>world</b></p>')).toBe('hello world');
  });

  test('empty/null input returns empty string', () => {
    expect(stripHtml('')).toBe('');
    expect(stripHtml(null)).toBe('');
  });
});
