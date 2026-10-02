import React from 'react';
import ReactMarkdown from 'react-markdown';

// Task 20261001-explorer-listings step 9. Listing descriptions are untrusted
// public text. Security rules (LST#8 review): markdown only, NO images and NO
// iframes/embeds, raw HTML skipped, links are http/https only and always carry
// rel="nofollow noopener noreferrer ugc". Image and video blocks are added by
// the media task (LSM) through BLOCK_RENDERERS below; an unknown block type
// renders nothing (never its raw content).

export const ALLOWED_ELEMENTS = ['p', 'br', 'strong', 'em', 'a', 'ul', 'ol', 'li', 'blockquote', 'h3', 'h4'];
export const LINK_REL = 'nofollow noopener noreferrer ugc';

// Returns the url when it is an absolute http(s) URL, else '' (the link is
// then rendered as plain text by the anchor override below).
export function safeUrl(url) {
  if (typeof url !== 'string') return '';
  const trimmed = url.trim();
  if (!/^https?:\/\//i.test(trimmed)) return '';
  try {
    const u = new URL(trimmed);
    return u.protocol === 'http:' || u.protocol === 'https:' ? trimmed : '';
  } catch {
    return '';
  }
}

function SafeLink({ href, children }) {
  const safe = safeUrl(href);
  if (!safe) return <span>{children}</span>;
  return (
    <a href={safe} target="_blank" rel={LINK_REL} className="ex-link">
      {children}
      <span className="ex-sr-only"> (opens in a new tab)</span>
    </a>
  );
}

// Headings in user text never outrank the page's own H1/H2.
function Heading({ children }) {
  return <h3 className="ex-desc-heading">{children}</h3>;
}

export function TextBlock({ text }) {
  return (
    <div className="ex-desc-block">
      <ReactMarkdown
        skipHtml
        allowedElements={ALLOWED_ELEMENTS}
        unwrapDisallowed
        urlTransform={safeUrl}
        components={{ a: SafeLink, h3: Heading, h4: Heading, img: () => null }}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
}

export const BLOCK_RENDERERS = {
  text: TextBlock,
};

export default function DescriptionBlocks({ blocks }) {
  if (!Array.isArray(blocks) || blocks.length === 0) return null;
  return (
    <div className="ex-desc">
      {blocks.map((block, i) => {
        const Renderer = block && BLOCK_RENDERERS[block.type];
        if (!Renderer) return null;
        // Blocks are append-only display data; index keys are stable here.
        return <Renderer key={i} {...(block.type === 'text' ? { text: typeof block.text === 'string' ? block.text : '' } : block)} />;
      })}
    </div>
  );
}
