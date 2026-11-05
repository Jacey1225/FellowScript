"""Editor-safe markup for AI-written notes (task 20261104-ai-note-format-normalizer).

Notes are stored as HTML and rendered by the in-app editors, which only understand a
tiny tag set (web ``sanitizeNoteHtml`` in frontend/src/components/RichText.jsx; iOS
``htmlToAttributedString``). LLM output is markdown-ish prose, so the markers show up
literally. ``normalize_note_markup`` turns untrusted LLM text into the exact set the iOS
serializer round-trips: ``<b> <em> <u> <mark> <br>``, no attributes, all text escaped.

Pipeline: (1) markdown to private sentinel characters, line by line; (2) the stdlib
``html.parser`` walks any HTML, drops every tag outside the allow-list (unwrapping its
text), discards ``script``/``style`` content and all attributes; (3) a renderer emits
balanced tags with ``<br>`` line breaks (never ``\\n``: web renders bodies pre-wrap, so a
newline next to a ``<br>`` would double, and iOS only converts bare newlines when the body
has no tag at all). Lists and headings have no editor form: list lines keep a literal
``1.`` / ``•`` marker, headings become a bold line.

Throw-not-fabricate: if nothing renderable is left, ``NoteMarkupError`` is raised and the
caller must fail the write; no placeholder text is ever substituted. Idempotent: the
output of this function (and clean editor HTML) normalizes to itself.

Used only for AI-originated writes, never for user-typed notes.
"""
from __future__ import annotations

import html
import re
from html.parser import HTMLParser

# Module constant, deliberately not configurable (no speculative config knobs).
EMIT_TAGS = ("b", "em", "u", "mark")
_TAG_ALIASES = {"b": "b", "strong": "b", "i": "em", "em": "em", "u": "u", "mark": "mark"}
_SKIP_TAGS = frozenset({"script", "style", "noscript", "template", "iframe", "object", "embed"})
_BLOCK_ONE = frozenset({
    "div", "li", "ul", "ol", "tr", "table", "blockquote", "pre", "hr", "section", "article",
    "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "p",
})
_BLOCK_TWO_CLOSE = frozenset({"p"})
_HEADINGS = frozenset({"h1", "h2", "h3", "h4", "h5", "h6"})
_MAX_BR = 2

# Private-use sentinels carrying markdown emphasis into the HTML pass.
_OPEN = {"b": "", "em": ""}
_CLOSE = {"b": "", "em": ""}
_SENTINEL_TAG = {"": ("b", 1), "": ("b", -1), "": ("em", 1), "": ("em", -1)}
_SENTINEL_RE = re.compile("[-]")
_SPLIT_SENTINEL_RE = re.compile("([-])")
_B_O, _B_C, _E_O, _E_C = _OPEN["b"], _CLOSE["b"], _OPEN["em"], _CLOSE["em"]


class NoteMarkupError(ValueError):
    """Normalization left nothing renderable (or the input was not text)."""


# ── Markdown (line level, then inline) ───────────────────────────────────────

_FENCE_RE = re.compile(r"^\s*(```|~~~)")
_HR_RE = re.compile(r"^\s*(?:-{3,}|\*{3,}|_{3,}|(?:-\s+){2,}-)\s*$")
_HEADING_RE = re.compile(r"^\s{0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?\s*$")
_BULLET_RE = re.compile(r"^\s*[-*+•][ \t]+(.*)$")
_ORDERED_RE = re.compile(r"^\s*(\d{1,3})[.)][ \t]+(.*)$")
_QUOTE_RE = re.compile(r"^\s*>[ \t]?")
_TABLE_SEP_RE = re.compile(r"^\s*\|?(?:\s*:?-{2,}:?\s*\|)+\s*:?-*:?\s*\|?\s*$")

_IMAGE_RE = re.compile(r"!\[([^\]\n]*)\]\(([^)\s]*)[^)\n]*\)")
_LINK_RE = re.compile(r"\[([^\]\n]+)\]\(\s*([^)\s]+)(?:\s+\"[^\"\n]*\")?\s*\)")
_CODE_RE = re.compile(r"`+([^`\n]+?)`+")
_BOLD_ITALIC_RE = re.compile(r"(?<![\w*])(\*\*\*|___)(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![\w*])")
_BOLD_STAR_RE = re.compile(r"\*\*(?=[^\s*])(.+?)(?<=[^\s*])\*\*")
_BOLD_UNDER_RE = re.compile(r"(?<![\w_])__(?=[^\s_])(.+?)(?<=[^\s_])__(?![\w_])")
_EM_STAR_RE = re.compile(r"(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])")
_EM_UNDER_RE = re.compile(r"(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])")
_STRIKE_RE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~")


def _inline(line: str) -> str:
    line = _IMAGE_RE.sub(lambda m: m.group(1) or m.group(2), line)
    line = _LINK_RE.sub(lambda m: m.group(1) if m.group(1).strip() == m.group(2) else f"{m.group(1)} ({m.group(2)})", line)
    line = _CODE_RE.sub(lambda m: m.group(1), line)
    line = _BOLD_ITALIC_RE.sub(lambda m: f"{_B_O}{_E_O}{m.group(2)}{_E_C}{_B_C}", line)
    line = _BOLD_STAR_RE.sub(lambda m: f"{_B_O}{m.group(1)}{_B_C}", line)
    line = _BOLD_UNDER_RE.sub(lambda m: f"{_B_O}{m.group(1)}{_B_C}", line)
    line = _EM_STAR_RE.sub(lambda m: f"{_E_O}{m.group(1)}{_E_C}", line)
    line = _EM_UNDER_RE.sub(lambda m: f"{_E_O}{m.group(1)}{_E_C}", line)
    line = _STRIKE_RE.sub(lambda m: m.group(1), line)
    return line


def _markdown_to_sentinels(raw: str) -> str:
    out: list[str] = []
    in_fence = False
    for line in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if _FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            # No code rendering exists in the editors; inline markers still go, so the
            # output stays stable when normalized again.
            out.append(_inline(line))
            continue
        if _HR_RE.match(line) or _TABLE_SEP_RE.match(line):
            out.append("")
            continue
        line = _QUOTE_RE.sub("", line)
        m = _HEADING_RE.match(line)
        if m:
            out.append(f"{_B_O}{_inline(m.group(1))}{_B_C}")
            continue
        m = _BULLET_RE.match(line)
        if m and not _BOLD_STAR_RE.match(line.lstrip()):
            out.append("• " + _inline(m.group(1)))
            continue
        m = _ORDERED_RE.match(line)
        if m:
            out.append(f"{m.group(1)}. " + _inline(m.group(2)))
            continue
        out.append(_inline(line))
    return "\n".join(out)


# ── HTML pass: allow-list, break handling, balanced output ───────────────────

class _Renderer(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.out: list[str] = []
        self.stack: list[str] = []       # tags currently open in the output
        self.depth = {t: 0 for t in EMIT_TAGS}
        self.order: list[str] = []       # active tags, in activation order
        self.started = False
        self.pending_br = 0
        self.pending_space = False
        self.block_fresh = False
        self.skip_tag: str | None = None
        self.lists: list[list] = []      # ["ul"] or ["ol", next_number]

    # -- state helpers
    def _toggle(self, tag: str, delta: int) -> None:
        if delta > 0:
            if self.depth[tag] == 0:
                self.order.append(tag)
            self.depth[tag] += 1
        elif self.depth[tag] > 0:
            self.depth[tag] -= 1
            if self.depth[tag] == 0:
                self.order.remove(tag)

    def _block(self, n: int = 1) -> None:
        if self.started:
            self.pending_br = max(self.pending_br, n)
            self.block_fresh = True

    def _explicit_br(self) -> None:
        if self.started:
            self.pending_br += 1
            self.block_fresh = False

    def _close_stale(self) -> list[str]:
        """Close output tags that are no longer active (before any space/break is
        written, so separators land outside the closed tags). Returns tags to open."""
        target = list(self.order)
        k = 0
        while k < len(self.stack) and k < len(target) and self.stack[k] == target[k]:
            k += 1
        for t in reversed(self.stack[k:]):
            self.out.append(f"</{t}>")
        self.stack = self.stack[:k]
        return target[k:]

    def _emit(self, piece: str) -> None:
        if piece.startswith(" "):
            self.pending_space = True
            piece = piece.lstrip(" ")
        if not piece:
            return
        trailing = piece.endswith(" ")
        piece = piece.rstrip(" ")
        to_open = self._close_stale()
        if self.started:
            brs = min(self.pending_br, _MAX_BR)
            if brs:
                self.out.append("<br>" * brs)
            elif self.pending_space:
                self.out.append(" ")
        self.pending_br = 0
        for t in to_open:
            self.out.append(f"<{t}>")
        self.stack += to_open
        self.out.append(html.escape(piece, quote=False))
        self.started = True
        self.block_fresh = False
        self.pending_space = trailing

    def _text(self, data: str) -> None:
        for sub in _SPLIT_SENTINEL_RE.split(data):
            if not sub:
                continue
            if sub in _SENTINEL_TAG:
                tag, delta = _SENTINEL_TAG[sub]
                self._toggle(tag, delta)
                continue
            lines = sub.split("\n")
            for i, ln in enumerate(lines):
                if i:
                    if self.started and not self.block_fresh:
                        self.pending_br += 1
                    self.pending_space = False
                ln = re.sub(r"[\s ​]+", " ", ln)
                if ln:
                    self._emit(ln)

    # -- HTMLParser callbacks
    def handle_starttag(self, tag, attrs):
        if self.skip_tag:
            return
        if tag in _SKIP_TAGS:
            self.skip_tag = tag
            return
        if tag in _TAG_ALIASES:
            self._toggle(_TAG_ALIASES[tag], 1)
        elif tag == "br":
            self._explicit_br()
        elif tag in ("ul", "ol"):
            self._block()
            self.lists.append([tag, 1])
        elif tag == "li":
            self._block()
            if self.lists and self.lists[-1][0] == "ol":
                marker = f"{self.lists[-1][1]}. "
                self.lists[-1][1] += 1
            else:
                marker = "• "
            self._emit(marker)
        elif tag in _HEADINGS:
            self._block()
            self._toggle("b", 1)
        elif tag in _BLOCK_ONE:
            self._block()

    def handle_endtag(self, tag):
        if self.skip_tag:
            if tag == self.skip_tag:
                self.skip_tag = None
            return
        if tag in _TAG_ALIASES:
            self._toggle(_TAG_ALIASES[tag], -1)
        elif tag in ("ul", "ol"):
            if self.lists:
                self.lists.pop()
            self._block()
        elif tag in _HEADINGS:
            self._toggle("b", -1)
            self._block()
        elif tag in _BLOCK_ONE:
            self._block(2 if tag in _BLOCK_TWO_CLOSE else 1)

    def handle_data(self, data):
        if not self.skip_tag:
            self._text(data)

    def finish(self) -> str:
        for t in reversed(self.stack):
            self.out.append(f"</{t}>")
        self.stack = []
        return "".join(self.out)


def normalize_note_markup(value) -> str:
    """Editor-safe HTML for untrusted AI text. Raises ``NoteMarkupError`` on non-text input
    or when nothing renderable remains; never returns placeholder content."""
    if not isinstance(value, str):
        raise NoteMarkupError("note text is not a string")
    raw = _SENTINEL_RE.sub("", value)
    marked = _markdown_to_sentinels(raw)
    parser = _Renderer()
    try:
        parser.feed(marked)
        parser.close()
    except Exception as e:  # noqa: BLE001 - malformed input must fail the write, not pass through
        raise NoteMarkupError("note text could not be parsed") from e
    result = parser.finish()
    if not result.strip():
        raise NoteMarkupError("note text is empty after normalization")
    return result
