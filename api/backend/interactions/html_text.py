"""Plain-text extraction from rich-text note HTML (task 20261013-shared-note-preview-html-leak).

Notes store rich-text HTML. Shared-note card previews must be plain text, so the server
reduces the HTML with the stdlib parser (never regex-only): tags are dropped, ``script`` /
``style`` content is discarded, block-level tags become spaces, entities are decoded, and
whitespace is collapsed. The output is inert text; clients render it as text, never as markup.
"""
from __future__ import annotations

from html.parser import HTMLParser

_BLOCK_TAGS = frozenset({
    "p", "div", "br", "li", "ul", "ol", "tr", "td", "th", "table", "blockquote", "pre", "hr",
    "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header", "footer",
})
_SKIP_TAGS = frozenset({"script", "style"})
_NOTE_KIND = "shared_note"


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in _SKIP_TAGS:
            self._skip += 1
        elif tag in _BLOCK_TAGS:
            self.parts.append(" ")

    def handle_startendtag(self, tag, attrs):
        if tag in _BLOCK_TAGS:
            self.parts.append(" ")

    def handle_endtag(self, tag):
        if tag in _SKIP_TAGS:
            self._skip = max(0, self._skip - 1)
        elif tag in _BLOCK_TAGS:
            self.parts.append(" ")

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)


def html_to_text(value) -> str:
    """Plain text of ``value`` (HTML or plain), whitespace-collapsed, never raises."""
    s = str(value or "")
    if "<" not in s and "&" not in s:
        return " ".join(s.split())
    parser = _TextExtractor()
    try:
        parser.feed(s)
        parser.close()
    except Exception:  # malformed input must never break sharing or reading
        return ""
    text = "".join(parser.parts)
    return " ".join(text.replace("\xa0", " ").split())


def clean_shared_note_meta(kind, meta):
    """Read-time guard for rows stored before previews were stripped at share time.

    Returns ``meta`` unchanged unless it is a ``shared_note`` whose preview/title still
    carries markup or entities, in which case a copy with plain-text fields is returned.
    The stored row is never modified.
    """
    if kind != _NOTE_KIND or not isinstance(meta, dict):
        return meta
    out = meta
    for field in ("preview", "title"):
        v = meta.get(field)
        if isinstance(v, str) and ("<" in v or "&" in v):
            if out is meta:
                out = dict(meta)
            out[field] = html_to_text(v)
    return out
