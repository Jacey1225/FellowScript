"""Canonical book list and real chapter counts, used by
``generate_bible_data.py``/``web_source.py`` to drive per-(book, chapter)
extraction from the vendored WEB source (task
20260927-esv-bible-source-migration, revision 2).

This is standard Bible versification (chapter counts are the same across
virtually every modern English translation, WEB and the now-retired ESV
alike -- structural information, not any one translation's own copyrighted
or public-domain verse text), not scraped or source-derived. The dict below
is the exact same 66 keys/ordering already used throughout the codebase as
dictionary keys (``data/bible.json``, ``BibleData.bookNames`` in the iOS
app, the frontend copies) -- reused verbatim so nothing downstream needs a
name-mapping layer.

Cross-checked directly against the vendored ``data/vendor/eng-web.usfx.xml``
(counted real ``<c>`` elements per book) before this migration shipped --
confirmed to match for all 66 books, not trusted blindly. ``generate_book``
in ``generate_bible_data.py`` also raises loudly (``BibleGenerationError``)
if the vendored source is ever missing a chapter this table expects.
"""

from __future__ import annotations

# book name -> real chapter count (order matches data/bible.json's existing
# key order, which matches canonical Bible book order).
BOOK_CHAPTER_COUNTS: dict[str, int] = {
    "Genesis": 50,
    "Exodus": 40,
    "Leviticus": 27,
    "Numbers": 36,
    "Deuteronomy": 34,
    "Joshua": 24,
    "Judges": 21,
    "Ruth": 4,
    "1 Samuel": 31,
    "2 Samuel": 24,
    "1 Kings": 22,
    "2 Kings": 25,
    "1 Chronicles": 29,
    "2 Chronicles": 36,
    "Ezra": 10,
    "Nehemiah": 13,
    "Esther": 10,
    "Job": 42,
    "Psalms": 150,
    "Proverbs": 31,
    "Ecclesiastes": 12,
    "Song of Solomon": 8,
    "Isaiah": 66,
    "Jeremiah": 52,
    "Lamentations": 5,
    "Ezekiel": 48,
    "Daniel": 12,
    "Hosea": 14,
    "Joel": 3,
    "Amos": 9,
    "Obadiah": 1,
    "Jonah": 4,
    "Micah": 7,
    "Nahum": 3,
    "Habakkuk": 3,
    "Zephaniah": 3,
    "Haggai": 2,
    "Zechariah": 14,
    "Malachi": 4,
    "Matthew": 28,
    "Mark": 16,
    "Luke": 24,
    "John": 21,
    "Acts": 28,
    "Romans": 16,
    "1 Corinthians": 16,
    "2 Corinthians": 13,
    "Galatians": 6,
    "Ephesians": 6,
    "Philippians": 4,
    "Colossians": 4,
    "1 Thessalonians": 5,
    "2 Thessalonians": 3,
    "1 Timothy": 6,
    "2 Timothy": 4,
    "Titus": 3,
    "Philemon": 1,
    "Hebrews": 13,
    "James": 5,
    "1 Peter": 5,
    "2 Peter": 3,
    "1 John": 5,
    "2 John": 1,
    "3 John": 1,
    "Jude": 1,
    "Revelation": 22,
}

BOOK_NAMES: list[str] = list(BOOK_CHAPTER_COUNTS.keys())

# Traditionally disputed/textually-uncertain passages -- verses or spans
# where different manuscript traditions disagree, so different translations
# make different editorial choices about whether/how to include them. Kept
# here purely as a spot-check/regression target list (task
# 20260927-esv-bible-source-migration) -- NOT used to special-case
# generation. The whole reason the old convertDict.py PDF-scrape produced an
# orphan array entry for John 7:53-8:11 is that it heuristically split a
# *linear* text stream on "chapter"-looking lines; generate_bible_data.py
# instead extracts by real (book, chapter) structural markers in the
# vendored USFX source, so a disputed passage embedded inside its home
# chapter's own text can never again split off into its own array slot, for
# any book, regardless of which translation is the source.
#
# IMPORTANT: this list was originally compiled against ESV's own editorial
# choices (which passages ESV brackets, and how) and has NOT been re-derived
# per-translation -- WEB's own choices were confirmed directly against the
# vendored source instead of assumed to match this list item-by-item, and do
# differ in places. Confirmed directly for this migration: WEB includes
# Mark 16:9-20 and John 7:53-8:11 in full as ordinary numbered verses (its
# translators judged both reliable, per the source file's own translator
# footnotes -- stripped from generated output like all footnotes), while
# Acts 8:37, Acts 15:34, Acts 24:7, and Luke 17:36 are traditional verse
# numbers WEB's translators omitted as absent from the earliest manuscripts
# (the vendored source still carries a marker for each, but with no verse
# text -- generate_bible_data.py's build_chapter_blob drops these entirely
# rather than emit a textless numeral; see that module's docstring). The
# remaining entries below are retained as ESV-era spot-check candidates
# worth re-confirming against WEB specifically, not verified line-by-line
# here.
KNOWN_DISPUTED_PASSAGES: list[tuple[str, str]] = [
    ("Matthew", "Matthew 17:21 (bracketed/omitted in some translations)"),
    ("Matthew", "Matthew 18:11 (bracketed/omitted in some translations)"),
    ("Matthew", "Matthew 23:14 (bracketed/omitted in some translations)"),
    ("Mark", "Mark 16:9-20 (the 'longer ending' -- WEB includes in full, confirmed)"),
    ("Luke", "Luke 17:36 (WEB: verse number present, no text -- confirmed dropped)"),
    ("Luke", "Luke 22:43-44 (bracketed/disputed in some translations)"),
    ("Luke", "Luke 23:17 (bracketed/omitted in some translations)"),
    ("Luke", "Luke 23:34a (bracketed/disputed, 'Father, forgive them')"),
    ("John", "John 5:3b-4 (bracketed/disputed, the stirring of the water)"),
    ("John", "John 7:53-8:11 (the woman caught in adultery -- WEB includes in full, confirmed)"),
    ("Acts", "Acts 8:37 (WEB: verse number present, no text -- confirmed dropped)"),
    ("Acts", "Acts 15:34 (WEB: verse number present, no text -- confirmed dropped)"),
    ("Acts", "Acts 24:6b-8 (WEB: verse 7 number present, no text -- confirmed dropped)"),
    ("Acts", "Acts 28:29 (bracketed/omitted in some translations)"),
    ("Romans", "Romans 16:24 (bracketed/disputed in some translations)"),
    ("1 John", "1 John 5:7-8 (Comma Johanneum, bracketed/omitted in most modern translations)"),
]
