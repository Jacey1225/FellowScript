"""In-process Bible verse text lookup, backed by a static bundled JSON asset.

Round 3 of task 20260904-friend-activity-push-triggers: `_friend_went_active_
notify` (scheduler.py) and `FriendsManager.get_friend_activity` (friends.py)
both need to resolve `book/chapter/verse -> plain text` at read/send time so a
highlight push/preview can show real verse content instead of a bare
reference. `bible.json` (copied here from
`FellowScript/FellowScript/Bible/bible.json`, the same asset the iOS reader
already ships) is a static, already-generated, rarely-changing ~4.2MB
reference dataset -- a DB table or an outbound third-party API call would be
real added maintenance/failure-mode surface for content that never changes at
runtime, so this is a plain in-process load instead (see
architecture-design-thinking: boring solution, least complexity for the
actual need). No DB table, no migration, no network call.

Deliberately does NOT reuse `backend/bibleHandling/convertDict.py` or its
dependencies (fitz/pandas/spacy) -- that's one-off PDF-conversion tooling
that produced this JSON in the first place and must never become a runtime
API dependency. Only the JSON it already produced travels into the API
image (picked up by the root Dockerfile's existing `COPY api/ .`).

Data shape: `bible.json` is `{book_name: [chapter_0_blob, chapter_1_blob,
...]}`, one list entry per chapter PLUS a leading index-0 header/junk entry
(so `chapters[chapter_num]` is chapter `chapter_num`'s own blob -- there is
no chapter 0). Each chapter blob is a flowing-text blob of the shape
`"{chapter}:1 {verse 1 text}2{verse 2 text}3{verse 3 text}..."` -- the first
verse is prefixed `chapter:1`, every later verse is a bare verse number
immediately followed (no space) by its text's capitalized first letter or an
opening curly quote. Section subheadings are embedded inline as
`HEAD::<subheading text>` and are not verse content.

This is a best-effort parse of an already-imperfect generated asset, not a
guaranteed-exact Bible text engine: verified against several real book
entries (Genesis, Exodus, John, Psalms, Matthew, Revelation) during
development, but a poetic/enjambed verse that continues a sentence with a
lowercase first word (occasionally seen in Psalms) won't be detected as its
own boundary and instead merges into the preceding verse's text -- cosmetic
only, not a crash or a silent-wrong-verse mismatch for the verse that *was*
requested. A genuine miss (unrecognized book name, out-of-range chapter/
verse, or a chapter blob that doesn't match the expected pattern at all)
returns None rather than raising -- callers fall back to reference-only text
(e.g. "highlighted John 3:16" with no quoted content), matching this task's
existing safe-fallback-on-one-row posture (the same class of edge case
`_friend_went_active_notify` already documents for a missing
`last_activity_type`).
"""

import json
import logging
import os
import re
import threading

logger = logging.getLogger(__name__)

_BIBLE_JSON_PATH = os.path.join(os.path.dirname(__file__), "bible_data", "bible.json")

# Inline section subheadings ("HEAD::<text>") embedded in the flowing chapter
# text -- strip them (and their text, up to the next verse marker or the end
# of the blob) before splitting into verses; they are never verse content.
_HEAD_RE = re.compile(r"HEAD::.*?(?=\d+[A-Z“]|\Z)", re.S)
# A chapter blob always opens "{chapter}:1 {verse 1 text}...".
_CHAPTER_START_RE = re.compile(r"^(\d+):1\s*(.*)", re.S)
# Every verse after the first is a bare number immediately followed by a
# capital letter or an opening curly quote (footnote markers like "[12]" are
# always followed by "]", never directly by a letter, so they never match).
_VERSE_SPLIT_RE = re.compile(r"(\d+)(?=[A-Z“])")

_raw_books: dict[str, list[str]] | None = None
_chapter_cache: dict[tuple[str, int], dict[int, str]] = {}
_load_lock = threading.Lock()


def _load_raw() -> dict[str, list[str]]:
    """Parse `bible.json` into memory on first use. A load failure (missing
    file, bad JSON) logs and leaves the lookup permanently empty for this
    process rather than raising -- every caller of `verse_text` already
    treats a miss as a normal, handled case."""
    global _raw_books
    if _raw_books is None:
        with _load_lock:
            if _raw_books is None:  # re-check inside the lock
                try:
                    with open(_BIBLE_JSON_PATH, "r", encoding="utf-8") as f:
                        _raw_books = json.load(f)
                except Exception as e:
                    logger.error("Failed to load bible.json: %s", e)
                    _raw_books = {}
    return _raw_books


def _parse_chapter(blob: str) -> dict[int, str] | None:
    """Split one chapter's raw blob into ``{verse_num: text}``, or None if it
    doesn't match the expected leading ``chapter:1 `` pattern at all."""
    cleaned = _HEAD_RE.sub("", blob)
    m = _CHAPTER_START_RE.match(cleaned)
    if not m:
        return None
    parts = _VERSE_SPLIT_RE.split(m.group(2))
    verses = {1: parts[0].strip()}
    i = 1
    while i < len(parts) - 1:
        try:
            vnum = int(parts[i])
        except ValueError:
            i += 2
            continue
        verses[vnum] = parts[i + 1].strip()
        i += 2
    return verses


def verse_text(book: str, chapter: int, verse: int) -> str | None:
    """Look up one verse's plain text. Returns None on any miss (unknown
    book, out-of-range chapter/verse, or an unparseable chapter blob) --
    never raises. See this module's docstring for the fallback contract
    callers are expected to follow on a miss."""
    if not book or not isinstance(chapter, int) or not isinstance(verse, int):
        return None
    books = _load_raw()
    chapters = books.get(book)
    if not chapters or chapter < 1 or chapter >= len(chapters):
        return None
    cache_key = (book, chapter)
    verses = _chapter_cache.get(cache_key)
    if verses is None:
        try:
            verses = _parse_chapter(chapters[chapter]) or {}
        except Exception as e:
            logger.error("Failed to parse %s %d: %s", book, chapter, e)
            verses = {}
        _chapter_cache[cache_key] = verses
    return verses.get(verse)


MAX_VERSE_NUMBER = 176  # Psalm 119, the longest chapter in the Bible.


def is_valid_reference(book: str, chapter: int, verse: int) -> bool:
    """True if (book, chapter, verse) is a plausible Bible reference: `book`
    is one of this dataset's exact 66 known keys, `chapter` is in range for
    that book, and `verse` is a positive integer within `MAX_VERSE_NUMBER`.

    This deliberately does NOT require `verse_text(...)` to resolve non-None
    for that reference -- this module's own docstring documents legitimate
    parse gaps (e.g. some enjambed Psalms verses) where a real, in-range
    verse still can't be isolated from its chapter blob; rejecting those as
    "invalid" would be a functional regression, not a security fix.

    Added for task 20260904-friend-activity-push-triggers: prior to that
    task, `book`/`chapter`/`verse` on a highlight were accepted at
    `POST /notes/highlight/{user_id}` with no format/range check beyond
    truthiness, which was harmless while a highlight's reference was never
    shown to anyone (see friends.py's now-superseded docstring on that
    point). Now that a highlight's reference is exposed to friends --
    directly in a push notification body and in the friend-activity widget,
    verbatim, whenever `verse_text` can't resolve real content -- an
    unvalidated `book` string is a stored content-injection vector into a
    second user's device notification, not just this user's own data
    anymore. Reject at write time instead.
    """
    if not isinstance(book, str) or not isinstance(chapter, int) or not isinstance(verse, int):
        return False
    if isinstance(chapter, bool) or isinstance(verse, bool):  # bool is an int subclass
        return False
    chapters = _load_raw().get(book)
    if not chapters or chapter < 1 or chapter >= len(chapters):
        return False
    return 1 <= verse <= MAX_VERSE_NUMBER


def parse_highlight_key(key: str) -> tuple[str, int, int] | None:
    """Split a ``highlights.key`` value (``f"{book}-{chapter}-{verse}"``, see
    ``routes/notes.py``'s ``highlight_verse``) back into ``(book, chapter,
    verse)``. None of this app's fixed 66 Bible book names contain a dash, so
    the last two dash-separated segments are always chapter/verse -- but
    this is read defensively against any historical/malformed key rather
    than assumed: a missing/non-numeric chapter or verse component returns
    None instead of raising."""
    if not key:
        return None
    parts = key.rsplit("-", 2)
    if len(parts) != 3:
        return None
    book, chapter_s, verse_s = parts
    try:
        return book, int(chapter_s), int(verse_s)
    except ValueError:
        return None
