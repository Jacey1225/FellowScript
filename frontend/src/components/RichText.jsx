/**
 * RichText.jsx — centralized formatting for notes and agent messages.
 *
 * Notes are stored as HTML (from the contentEditable editor using document.execCommand).
 * Agent messages are stored as Markdown (from the LLM via OpenRouter/DeepSeek).
 *
 * This module:
 *  • sanitizeNoteHtml(html)   — strips unsafe tags/attrs before rendering
 *  • stripHtml(html)          — plain-text extract (for card previews)
 *  • detectScripture(text)    — wraps "Book C:V" patterns in a <ScriptureChip>
 *  • <NoteBody html />        — sanitized, themed HTML note body
 *  • <AgentMessage text isMine /> — Markdown (AI) or pre-wrap plain text (user)
 */

import React, { useMemo } from 'react';
import ReactMarkdown from 'react-markdown';

// ── Constants ─────────────────────────────────────────────────────────────────

// Tags the note editor can produce; everything else gets stripped to text.
const ALLOWED_TAGS = new Set([
  'B', 'STRONG', 'I', 'EM', 'U', 'S', 'DEL',
  'MARK', 'SPAN', 'FONT',
  'BR', 'P', 'DIV',
]);

// Per-tag list of allowed attributes (empty = none).
const ALLOWED_ATTRS = {
  FONT: ['color'],
  SPAN: ['style'],
};

// Bible book names for scripture reference detection.
const BIBLE_BOOKS = [
  'Genesis','Exodus','Leviticus','Numbers','Deuteronomy','Joshua','Judges','Ruth',
  '1 Samuel','2 Samuel','1 Kings','2 Kings','1 Chronicles','2 Chronicles',
  'Ezra','Nehemiah','Esther','Job','Psalms','Psalm','Proverbs','Ecclesiastes',
  'Song of Solomon','Isaiah','Jeremiah','Lamentations','Ezekiel','Daniel',
  'Hosea','Joel','Amos','Obadiah','Jonah','Micah','Nahum','Habakkuk',
  'Zephaniah','Haggai','Zechariah','Malachi',
  'Matthew','Mark','Luke','John','Acts','Romans',
  '1 Corinthians','2 Corinthians','Galatians','Ephesians','Philippians',
  'Colossians','1 Thessalonians','2 Thessalonians','1 Timothy','2 Timothy',
  'Titus','Philemon','Hebrews','James','1 Peter','2 Peter',
  '1 John','2 John','3 John','Jude','Revelation',
];

// Regex: matches "Book C:V" or "Book C:V-V2" (verse ranges).
// Books with a leading numeral use a non-word-boundary prefix (e.g. "1 John").
const SCRIPTURE_RE = new RegExp(
  '(' + BIBLE_BOOKS.map(b => b.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|') + ')' +
  '\\s+(\\d+):(\\d+(?:-\\d+)?)',
  'g'
);

// ── HTML sanitizer ────────────────────────────────────────────────────────────

/**
 * Walk the DOM tree rooted at `node`, removing any element whose tag is not in
 * ALLOWED_TAGS (replacing it with its children's text) and stripping all
 * attributes except those explicitly permitted.
 */
function cleanNode(node) {
  const children = [...node.childNodes];
  for (const child of children) {
    if (child.nodeType === Node.TEXT_NODE) continue;

    if (child.nodeType !== Node.ELEMENT_NODE) {
      node.removeChild(child);
      continue;
    }

    const tag = child.tagName;
    if (!ALLOWED_TAGS.has(tag)) {
      // Unwrap: keep inner text, discard the element wrapper. The promoted
      // children can themselves be disallowed tags, or allowed tags carrying
      // disallowed attributes (e.g. a <span onclick="…"> nested inside a
      // disallowed <iframe>) — recursively clean the fragment *before*
      // splicing it in, so every promoted node is visited exactly once
      // regardless of how many ancestor wrappers got unwrapped around it.
      // Without this, a single unwrap pass left one level of newly-promoted
      // children unvisited and let attributes like onclick survive into
      // dangerouslySetInnerHTML.
      const frag = document.createDocumentFragment();
      while (child.firstChild) frag.appendChild(child.firstChild);
      cleanNode(frag);
      node.replaceChild(frag, child);
      continue;
    }

    // Strip disallowed attributes.
    const permitted = ALLOWED_ATTRS[tag] || [];
    [...child.attributes].forEach(attr => {
      if (!permitted.includes(attr.name)) {
        child.removeAttribute(attr.name);
      }
    });

    // For <span style="...">, keep only `color` and `text-decoration`.
    if (tag === 'SPAN' && child.hasAttribute('style')) {
      const color  = child.style.color;
      const deco   = child.style.textDecoration;
      const parts  = [];
      if (color) parts.push(`color:${color}`);
      if (deco)  parts.push(`text-decoration:${deco}`);
      parts.length ? child.setAttribute('style', parts.join(';')) : child.removeAttribute('style');
    }

    cleanNode(child);
  }
}

/**
 * Sanitize HTML produced by the contentEditable note editor.
 * Returns a safe HTML string suitable for dangerouslySetInnerHTML.
 */
export function sanitizeNoteHtml(html) {
  if (!html) return '';
  const el = document.createElement('div');
  el.innerHTML = html;
  cleanNode(el);
  return el.innerHTML;
}

/**
 * Strip all HTML tags and return plain text (used for note card previews).
 */
export function stripHtml(html) {
  if (!html) return '';
  const el = document.createElement('div');
  el.innerHTML = html;
  return el.textContent || '';
}

// ── Scripture reference detection ─────────────────────────────────────────────

/**
 * Split `text` into segments, tagging matches of "Book C:V[-V2]" so the
 * caller can render each segment as plain text or as a scripture chip.
 *
 * Returns: Array<{ type: 'text'|'scripture', value: string, book?, chapter?, verse? }>
 */
export function parseScriptureRefs(text) {
  if (!text) return [{ type: 'text', value: '' }];

  const segments = [];
  let last = 0;
  SCRIPTURE_RE.lastIndex = 0;

  let match;
  while ((match = SCRIPTURE_RE.exec(text)) !== null) {
    if (match.index > last) {
      segments.push({ type: 'text', value: text.slice(last, match.index) });
    }
    segments.push({
      type:    'scripture',
      value:   match[0],
      book:    match[1],
      chapter: parseInt(match[2], 10),
      verse:   match[3],
    });
    last = match.index + match[0].length;
  }

  if (last < text.length) {
    segments.push({ type: 'text', value: text.slice(last) });
  }

  return segments.length ? segments : [{ type: 'text', value: text }];
}

// ── Scripture chip ────────────────────────────────────────────────────────────

function ScriptureChip({ value, book, chapter, verse, onNavigate }) {
  return (
    <button
      onClick={() => onNavigate && onNavigate(book, chapter, parseInt(verse, 10))}
      style={{
        display:        'inline',
        background:     'rgba(255,198,26,0.13)',
        border:         '1px solid rgba(255,255,255,0.192)',
        borderRadius:   4,
        padding:        '0.05rem 0.42rem',
        fontFamily:     "'Spectral', serif",
        fontStyle:      'italic',
        fontSize:       '0.84em',
        color:          'var(--gold)',
        cursor:         onNavigate ? 'pointer' : 'default',
        lineHeight:     'inherit',
        verticalAlign:  'baseline',
        transition:     'background 0.15s, border-color 0.15s',
        margin:         '0 1px',
      }}
      onMouseEnter={e => {
        if (!onNavigate) return;
        e.currentTarget.style.background    = 'rgba(255,198,26,0.25)';
        e.currentTarget.style.borderColor   = 'rgba(255,255,255,0.36)';
      }}
      onMouseLeave={e => {
        e.currentTarget.style.background    = 'rgba(255,198,26,0.13)';
        e.currentTarget.style.borderColor   = 'rgba(255,255,255,0.192)';
      }}
    >
      {value}
    </button>
  );
}

/**
 * Render a string, replacing "Book C:V" patterns with <ScriptureChip>s.
 * Pass `onNavigate(book, chapter, verse)` to make chips clickable.
 */
export function ScriptureText({ text, onNavigate }) {
  const segments = useMemo(() => parseScriptureRefs(text), [text]);
  return (
    <>
      {segments.map((seg, i) =>
        seg.type === 'scripture' ? (
          <ScriptureChip key={i} {...seg} onNavigate={onNavigate} />
        ) : (
          <span key={i}>{seg.value}</span>
        )
      )}
    </>
  );
}

// ── Note body ─────────────────────────────────────────────────────────────────

/**
 * Render a note's rich-text body.
 * Sanitizes the stored HTML and injects theme-matching styles for `<mark>` and
 * `<font>` tags so editor output looks consistent on the dark background.
 */
export function NoteBody({ html, className, style }) {
  const safe = useMemo(() => sanitizeNoteHtml(html), [html]);

  return (
    <>
      <style>{NOTE_BODY_CSS}</style>
      <div
        className={`fs-note-body${className ? ` ${className}` : ''}`}
        style={style}
        dangerouslySetInnerHTML={{ __html: safe }}
      />
    </>
  );
}

const NOTE_BODY_CSS = `
.fs-note-body {
  font-family: 'Inter', -apple-system, sans-serif;
  font-size: 0.88rem;
  color: rgba(242,242,242,0.80);
  line-height: 1.85;
  white-space: pre-wrap;
  word-break: break-word;
}
.fs-note-body b,
.fs-note-body strong {
  font-weight: 700;
  color: rgba(242,242,242,0.95);
}
.fs-note-body i,
.fs-note-body em {
  font-style: italic;
  color: rgba(242,242,242,0.85);
}
.fs-note-body u {
  text-decoration: underline;
  text-decoration-color: rgba(255,198,26,0.55);
  text-underline-offset: 2px;
}
.fs-note-body s,
.fs-note-body del {
  text-decoration: line-through;
  color: rgba(242,242,242,0.45);
}
.fs-note-body mark {
  background: rgba(255,198,26,0.28);
  color: inherit;
  border-radius: 2px;
  padding: 0 2px;
}
.fs-note-body div,
.fs-note-body p {
  min-height: 1.2em;
}
`;

// ── Markdown components for agent messages ────────────────────────────────────

/**
 * Custom ReactMarkdown component overrides styled to match the dark theme.
 */
const MD_COMPONENTS = {
  p:          ({ children }) => <p style={{ margin: '0 0 0.6em', lineHeight: 1.75 }}>{children}</p>,
  strong:     ({ children }) => <strong style={{ fontWeight: 700, color: 'rgba(242,242,242,0.95)' }}>{children}</strong>,
  em:         ({ children }) => <em style={{ fontStyle: 'italic', color: 'rgba(242,242,242,0.85)' }}>{children}</em>,
  h1:         ({ children }) => <h2 style={headingStyle(1.05)}>{children}</h2>,
  h2:         ({ children }) => <h3 style={headingStyle(0.97)}>{children}</h3>,
  h3:         ({ children }) => <h4 style={headingStyle(0.90)}>{children}</h4>,
  ul:         ({ children }) => <ul style={{ margin: '0.4em 0', paddingLeft: '1.4em' }}>{children}</ul>,
  ol:         ({ children }) => <ol style={{ margin: '0.4em 0', paddingLeft: '1.4em' }}>{children}</ol>,
  li:         ({ children }) => <li style={{ marginBottom: '0.25em', lineHeight: 1.65 }}>{children}</li>,
  blockquote: ({ children }) => (
    <blockquote style={{
      borderLeft:  '2px solid rgba(255,255,255,0.24)',
      margin:      '0.5em 0',
      padding:     '0.1em 0 0.1em 0.85em',
      color:       'rgba(242,242,242,0.6)',
      fontStyle:   'italic',
      fontFamily:  "'Spectral', serif",
    }}>
      {children}
    </blockquote>
  ),
  code: ({ inline, children }) => inline ? (
    <code style={{
      background:   'rgba(255,198,26,0.12)',
      border:       '1px solid rgba(255,255,255,0.12)',
      borderRadius: 3,
      padding:      '0.05em 0.35em',
      fontFamily:   'monospace',
      fontSize:     '0.82em',
      color:        'var(--gold)',
    }}>
      {children}
    </code>
  ) : (
    <pre style={{
      background:   'rgba(0,0,0,0.3)',
      border:       '1px solid rgba(255,255,255,0.09)',
      borderRadius: 6,
      padding:      '0.6em 0.8em',
      overflowX:    'auto',
      fontSize:     '0.8em',
      fontFamily:   'monospace',
      color:        'rgba(242,242,242,0.75)',
      margin:       '0.5em 0',
    }}>
      <code>{children}</code>
    </pre>
  ),
  hr: () => (
    <hr style={{ border: 'none', borderTop: '1px solid rgba(255,255,255,0.12)', margin: '0.75em 0' }} />
  ),
  a: ({ href, children }) => (
    <a href={href} target="_blank" rel="noopener noreferrer"
      style={{ color: 'var(--gold)', textDecoration: 'underline', textDecorationColor: 'rgba(255,198,26,0.4)' }}>
      {children}
    </a>
  ),
};

function headingStyle(size) {
  return {
    fontFamily:   "'Space Grotesk', sans-serif",
    fontSize:     `${size}rem`,
    fontWeight:   600,
    color:        'rgba(242,242,242,0.92)',
    margin:       '0.7em 0 0.3em',
    lineHeight:   1.3,
  };
}

/**
 * Render an agent chat message.
 *  - AI responses  → themed ReactMarkdown with scripture-reference chips
 *  - User messages → pre-wrap plain text
 */
export function AgentMessage({ text, isMine, onNavigate }) {
  if (isMine) {
    return (
      <span style={{ whiteSpace: 'pre-wrap', lineHeight: 1.7 }}>
        {text}
      </span>
    );
  }

  return (
    <div className="fs-agent-markdown">
      <ReactMarkdown
        components={{
          ...MD_COMPONENTS,
          // Override paragraph to scan for scripture refs
          p: ({ children }) => (
            <p style={{ margin: '0 0 0.6em', lineHeight: 1.75 }}>
              {injectScripture(children, onNavigate)}
            </p>
          ),
          li: ({ children }) => (
            <li style={{ marginBottom: '0.25em', lineHeight: 1.65 }}>
              {injectScripture(children, onNavigate)}
            </li>
          ),
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
}

/**
 * Walk ReactMarkdown's children tree and replace scripture references in any
 * plain string leaf with <ScriptureChip>s.
 */
function injectScripture(children, onNavigate) {
  if (!onNavigate) return children;

  return React.Children.map(children, child => {
    if (typeof child !== 'string') return child;
    const segs = parseScriptureRefs(child);
    if (segs.length === 1 && segs[0].type === 'text') return child;
    return segs.map((seg, i) =>
      seg.type === 'scripture'
        ? <ScriptureChip key={i} {...seg} onNavigate={onNavigate} />
        : <span key={i}>{seg.value}</span>
    );
  });
}
