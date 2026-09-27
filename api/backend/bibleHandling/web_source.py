"""Extraction layer for the vendored World English Bible (WEB) USFX source.

Replaces ``archive/esv_client.py``'s role in the pipeline (task
20260927-esv-bible-source-migration, revision 2 -- ESV/api.esv.org dropped
entirely in favor of the public-domain WEB): where ``esv_client.py`` made
one live, credentialed HTTP request per chapter, this module makes zero
network calls at generation time. It parses ``data/vendor/eng-web.usfx.xml``
(a pinned, vendored snapshot -- see ``data/vendor/SOURCE.md`` for exact
provenance) once, in full, and hands ``generate_bible_data.py`` one real
chapter's plain-text verses at a time via ``extract_book``.

Why this structurally can't reproduce the ESV pipeline's bug classes
------------------------------------------------------------------
USFX is real structural markup, not a linear text stream to heuristically
re-split: every chapter is an explicit ``<c id="N"/>`` marker and every
verse an explicit ``<v id="N"/>`` marker, both carrying their *real* book-
relative numbers as XML attributes. ``_flatten_book`` walks the whole book
subtree in document order and buckets text purely by "which real (chapter,
verse) marker did we most recently see" -- there is no "does this look like
a new chapter" guess anywhere, so:

  - **Orphan-array-entry bug (John 7:53-8:11, Mark 16:9-20, etc.):**
    structurally impossible here. A disputed/bracketed passage is just
    verses inside its home chapter's own ``<c>``/``<v>`` markers, wherever
    WEB's own translators chose to place it -- confirmed directly against
    this vendored file: WEB includes John 7:53-8:11 as ordinary John 7:53
    and John 8:1-11 (no split), and includes Mark 16:9-20 in full as
    ordinary Mark 16:9-20 (WEB's translators judged the longer ending
    reliable -- see the file's own translator footnote at Mark 16:9,
    preserved as a stripped ``<f>`` in the source but never in the output;
    this is WEB's own editorial choice, confirmed rather than assumed to
    match ESV's -- it doesn't, and doesn't need to).
  - **Missing-index-0-placeholder bug (11 books under the old ESV
    pipeline):** impossible by construction -- ``generate_book`` in
    ``generate_bible_data.py`` always emits ``[""] + [chapter_1, ...]``
    for every book, including single-chapter ones, regardless of what this
    module returns.
  - **Heading-before-verse-1-swallowing bug:** this vendored USFX file
    carries **no mid-chapter section headings at all** (confirmed directly:
    zero ``<s>`` elements anywhere in ``eng-web.usfx.xml``), so there is no
    ``HEAD::``-worthy content to embed inline in the first place for this
    source. The one real analog -- a Psalm's descriptive title (``<d>``,
    e.g. Psalm 3's "A Psalm by David, when he fled from Absalom his son.",
    which sits between the chapter marker and verse 1, exactly where
    ESV's chapter-opening headings did) -- is handled the same way the ESV
    pipeline's precedent established: dropped, never embedded, because
    ``bible_text.py``'s ``_HEAD_RE`` (and its Swift/JS equivalents) have no
    digit marker to stop at before verse 1's own un-prefixed text and would
    otherwise swallow it. ``_flatten_book`` achieves this for free: any
    text encountered after a ``<c>`` event but before that chapter's first
    ``<v>`` event is simply never bucketed into any verse, so it's dropped
    by construction, not by a special case.
  - **New bug class found and fixed in this same session (WEB-specific,
    did not exist in the ESV pipeline): an empty verse marker glues its
    bare digit onto the next verse's marker.** Some WEB verses that
    tradition numbers but whose entire content the translators omitted as
    not present in the earliest manuscripts (e.g. Acts 8:37, Acts 15:34,
    Acts 24:7, Luke 17:36) still carry a real ``<v id="N"/>`` marker in the
    XML -- but with every byte of would-be content wrapped in a translator
    ``<f>`` footnote explaining the omission, which this module correctly
    excludes. Naively still emitting that verse's bare numeral (with empty
    text) glues it directly onto the immediately following verse's own
    numeral with no letter/quote/paren between them -- confirmed directly:
    without this fix, Acts 8 produced a literal ``"...baptized?"3738He
    commanded..."`` blob, where the digit-adjacency broke every
    downstream consumer's ``(?<!\\d)`` guard and silently merged verses 37
    and 38 into one bogus verse "3738". ``build_chapter_verses`` (below)
    fixes this the same way the other three bug classes are fixed --
    structurally, not by special-casing specific verses: a verse whose
    fully-assembled, whitespace-cleaned text is empty is dropped from the
    output entirely, the same as if the ``<v>`` marker had never existed.
    This correctly reproduces the ordinary, already-documented "translator
    omitted this verse number" contract every consumer's parser already
    expects (``verse_text()`` returns ``None`` for it, same as any other
    legitimate numbering gap) without corrupting the verse *after* it.

Footnotes (``<f>``) and cross-references (``<x>``) are excluded from output
entirely (skipped subtree, but their ``.tail`` text -- what continues after
the closing tag -- is preserved), mirroring the old ESV pipeline's
``include-footnotes=false``/``include-passage-references=false`` choice:
neither was ever displayed by any of the four existing consumers, so
excluding them at the source removes a whole class of transform risk for
content nothing shows anyway.

Parsing uses ``defusedxml`` (external entity resolution disabled) rather
than bare ``xml.etree.ElementTree`` as ordinary secure practice for parsing
an externally-sourced document, even though this file is vendored (not
fetched live at request time) and was manually confirmed to carry no
``<!DOCTYPE``/``<!ENTITY`` declarations -- defense in depth costs nothing
here and was already an available, vetted dependency (see
``requirements.txt``'s own comment on this pin).
"""

from __future__ import annotations

import re
from pathlib import Path

from defusedxml import ElementTree as _SafeET

_REPO_ROOT = Path(__file__).resolve().parents[3]
VENDORED_SOURCE_PATH = _REPO_ROOT / "data" / "vendor" / "eng-web.usfx.xml"

# This app's canonical 66 book names (bible_books.BOOK_CHAPTER_COUNTS' own
# key order) -> the USFX/OSIS 3-4 letter book id eng-web.usfx.xml uses.
# Confirmed directly against the vendored file: exactly these 66 ids are
# present, each with a chapter count matching BOOK_CHAPTER_COUNTS -- the
# file's other ~20 <book> entries (FRT front matter, GLO glossary, and
# deuterocanonical/apocryphal books like TOB/JDT/WIS/SIR/1MA/2MA/etc.) are
# never referenced here and never touch generation, matching this app's
# existing 66-book-Protestant-canon scope (unchanged by this migration).
USFX_BOOK_IDS: dict[str, str] = {
    "Genesis": "GEN", "Exodus": "EXO", "Leviticus": "LEV", "Numbers": "NUM",
    "Deuteronomy": "DEU", "Joshua": "JOS", "Judges": "JDG", "Ruth": "RUT",
    "1 Samuel": "1SA", "2 Samuel": "2SA", "1 Kings": "1KI", "2 Kings": "2KI",
    "1 Chronicles": "1CH", "2 Chronicles": "2CH", "Ezra": "EZR",
    "Nehemiah": "NEH", "Esther": "EST", "Job": "JOB", "Psalms": "PSA",
    "Proverbs": "PRO", "Ecclesiastes": "ECC", "Song of Solomon": "SNG",
    "Isaiah": "ISA", "Jeremiah": "JER", "Lamentations": "LAM",
    "Ezekiel": "EZK", "Daniel": "DAN", "Hosea": "HOS", "Joel": "JOL",
    "Amos": "AMO", "Obadiah": "OBA", "Jonah": "JON", "Micah": "MIC",
    "Nahum": "NAM", "Habakkuk": "HAB", "Zephaniah": "ZEP", "Haggai": "HAG",
    "Zechariah": "ZEC", "Malachi": "MAL", "Matthew": "MAT", "Mark": "MRK",
    "Luke": "LUK", "John": "JHN", "Acts": "ACT", "Romans": "ROM",
    "1 Corinthians": "1CO", "2 Corinthians": "2CO", "Galatians": "GAL",
    "Ephesians": "EPH", "Philippians": "PHP", "Colossians": "COL",
    "1 Thessalonians": "1TH", "2 Thessalonians": "2TH", "1 Timothy": "1TI",
    "2 Timothy": "2TI", "Titus": "TIT", "Philemon": "PHM", "Hebrews": "HEB",
    "James": "JAS", "1 Peter": "1PE", "2 Peter": "2PE", "1 John": "1JN",
    "2 John": "2JN", "3 John": "3JN", "Jude": "JUD", "Revelation": "REV",
}

# Element tags whose entire subtree (text + descendants) is excluded from
# extracted verse text -- footnotes and cross-references, never displayed
# by any of the four existing consumers. A skipped element's own `.tail`
# (text after its closing tag) is NOT excluded -- that's ordinary flow text
# that continues after the footnote/xref, not part of it.
_EXCLUDED_SUBTREE_TAGS = frozenset({"f", "x"})


class WebSourceError(RuntimeError):
    """The vendored USFX file is missing, unreadable, malformed, or missing
    a book/chapter this app's canon expects. Raised eagerly -- a corrupt or
    incomplete vendored source should stop generation loudly, not produce a
    partial/wrong dataset (Architecture/Implementation Q26/Q27)."""


_book_index: dict[str, "_SafeET.Element"] | None = None  # type: ignore[name-defined]


def _load_book_index() -> dict:
    """Parse the vendored USFX file once (module-level cache -- this
    generation script processes all 66 books in one run) and index its
    ``<book>`` elements by id."""
    global _book_index
    if _book_index is not None:
        return _book_index

    if not VENDORED_SOURCE_PATH.exists():
        raise WebSourceError(
            f"Vendored WEB source not found at {VENDORED_SOURCE_PATH} -- "
            "see data/vendor/SOURCE.md for how to (re-)pull it. This is a "
            "checked-in file, not fetched at runtime; it should not be "
            "missing in a normal checkout."
        )

    try:
        tree = _SafeET.parse(str(VENDORED_SOURCE_PATH))
    except Exception as e:  # defusedxml raises its own entity-related types
        raise WebSourceError(f"Failed to parse {VENDORED_SOURCE_PATH}: {e}") from e

    root = tree.getroot()
    _book_index = {b.get("id"): b for b in root.findall("book")}
    return _book_index


def clean_whitespace(text: str) -> str:
    """Collapse internal whitespace (poetry line breaks, multi-space
    indentation from the source XML's own formatting) to single spaces --
    a deliberate simplification, not a parity requirement: the verse-
    boundary regexes in all four consumers only ever key off the verse-
    number/heading markers, never internal whitespace width. Public (no
    leading underscore) because ``generate_bible_data.py`` also calls this,
    once per verse, after deciding whether that verse's text is empty."""
    return re.sub(r"\s+", " ", text).strip()


def _flatten_book(book_elem) -> list[tuple[str, object]]:
    """Walk one ``<book>`` element's full subtree in document order,
    producing a flat event stream: ``("c", chapter_num)``,
    ``("v", verse_num)``, or ``("text", str)``. Footnote/cross-reference
    subtrees are skipped entirely (their ``.tail`` text is still emitted,
    by the caller, once the recursive call returns) -- see module docstring
    for why this makes the orphan-array-entry and heading-swallowing bug
    classes structurally impossible rather than patched around."""
    events: list[tuple[str, object]] = []

    def walk(elem) -> None:
        tag = elem.tag
        if tag in _EXCLUDED_SUBTREE_TAGS:
            return
        if tag == "c":
            events.append(("c", int(elem.get("id"))))
            return
        if tag == "v":
            events.append(("v", int(elem.get("id"))))
            return
        if tag == "ve":
            return  # verse-end marker -- no action; the next v/c naturally closes the prior verse
        if elem.text:
            events.append(("text", elem.text))
        for child in elem:
            walk(child)
            if child.tail:
                events.append(("text", child.tail))

    for child in book_elem:
        walk(child)
        if child.tail:
            events.append(("text", child.tail))
    return events


def extract_book(book_name: str) -> dict[int, dict[int, str]]:
    """Return ``{chapter_num: {verse_num: raw_text_pieces_joined}}`` for one
    canonical book name, built purely from real ``<c>``/``<v>`` structural
    markers -- never a heuristic scan.

    Any text appearing before the first ``<c>`` marker (book title/preface
    front matter) or between a ``<c>`` marker and that chapter's first
    ``<v>`` marker (a chapter-opening heading/Psalm superscription) is
    dropped, not returned -- see module docstring's heading-swallowing-bug
    section. Verse text is NOT whitespace-cleaned here (that's
    ``generate_bible_data.build_chapter_blob``'s job, once per verse,
    against the fully-joined text) and empty verses are NOT filtered here
    either -- both are the caller's responsibility, kept there so this
    function's contract stays a straightforward structural extraction.
    """
    usfx_id = USFX_BOOK_IDS.get(book_name)
    if usfx_id is None:
        raise WebSourceError(f"{book_name!r} is not a known canonical book name (see USFX_BOOK_IDS).")

    book_index = _load_book_index()
    book_elem = book_index.get(usfx_id)
    if book_elem is None:
        raise WebSourceError(
            f"{book_name!r} (USFX id {usfx_id!r}) not found in {VENDORED_SOURCE_PATH} -- "
            "the vendored file may be corrupt, truncated, or the wrong translation."
        )

    events = _flatten_book(book_elem)
    chapters: dict[int, dict[int, list[str]]] = {}
    cur_chapter: int | None = None
    cur_verse: int | None = None
    for kind, val in events:
        if kind == "c":
            cur_chapter, cur_verse = val, None  # type: ignore[assignment]
        elif kind == "v":
            cur_verse = val  # type: ignore[assignment]
        elif kind == "text":
            if cur_chapter is not None and cur_verse is not None:
                chapters.setdefault(cur_chapter, {}).setdefault(cur_verse, []).append(val)  # type: ignore[arg-type]

    # Join each verse's accumulated text pieces into one string per verse
    # (still uncleaned -- caller cleans once, after deciding whether the
    # verse is empty).
    return {
        chapter_num: {verse_num: "".join(pieces) for verse_num, pieces in verses.items()}
        for chapter_num, verses in chapters.items()
    }
