"""Generation/sync pipeline that (re)builds ``bible.json`` from the vendored
World English Bible (WEB) USFX source, replacing both the retired
``archive/convertDict.py`` PDF-scrape tool and the never-shipped, since-
superseded api.esv.org integration (``archive/esv_client.py``) -- task
20260927-esv-bible-source-migration, revision 2 (ESV/api.esv.org dropped
entirely in favor of the public-domain WEB; see
``docs/legal/bible-translation-source.md``).

Why this structurally can't reproduce the old scrape's bug classes -- and
the fourth one found while building this
------------------------------------------------------------------------
``convertDict.py`` scanned a *linear* PDF text dump and heuristically
guessed where each book/chapter started. That's what let John 7:53-8:11 (a
disputed/bracketed passage) get flushed out into its own orphan array
entry mid-scan, shifting every later chapter's index by one, and separately
left 11 books with no leading index-0 placeholder at all.

This generator never scans a continuous document: it asks
``web_source.extract_book`` for one *real* ``(book, chapter)`` at a time,
keyed directly off the vendored USFX file's own ``<c>``/``<v>`` structural
markers (``bible_books.BOOK_CHAPTER_COUNTS`` drives which books/chapter
counts to expect; ``web_source.py``'s own docstring is the full writeup of
why this makes the orphan-array-entry, missing-placeholder, and heading-
swallowing bug classes structurally impossible for this source -- plus a
fourth, WEB-specific bug class found and fixed in this same session: an
empty verse marker gluing its bare digit onto the following verse's own
marker, e.g. a raw ``"...baptized?"3738He commanded..."`` blob for Acts 8,
confirmed and fixed here in ``build_chapter_blob`` below). Every book
unconditionally gets the same uniform ``[""] + [chapter_1, ..., chapter_N]``
shape (including single-chapter books like Obadiah/Philemon/2 John/3 John/
Jude), so ``chapters[chapter_num]`` is chapter_num's real text for every
book, always, by construction.

WEB's own editorial choices about disputed/bracketed passages were
confirmed directly against the vendored file rather than assumed to match
ESV's (they don't need to, and don't): WEB includes John 7:53-8:11 and Mark
16:9-20 in full as ordinary numbered verses (its translators judged both
reliable -- see the source file's own footnotes, stripped from output like
all footnotes), while numbered-but-textless verses like Acts 8:37, Acts
15:34, Acts 24:7, and Luke 17:36 (traditional verse numbers WEB's
translators omitted as absent from the earliest manuscripts) are dropped
from the output entirely rather than left as bare, textless numeral
markers -- exactly the fourth bug class this module fixes.

Output shape is unchanged from the pre-existing data (frontend/iOS/backend
parser compatibility -- confirmed again this revision, same as revision 1's
own frontend checkpoint): each book maps to a list of flowing-text chapter
blobs, ``"{chapter}:1 {verse 1 text}2{verse 2 text}..."``, parsed by
``bible_text.py``/``BibleReaderView.swift``/``frontend/src/utils.js``/
``frontend/js/bible.js``'s existing verse-boundary regexes. This vendored
USFX source carries no mid-chapter section headings at all (confirmed:
zero ``<s>`` elements anywhere in the file), so this generator never emits
an inline ``HEAD::`` marker for WEB data -- the existing consumers' HEAD::-
stripping logic simply never has anything to strip here, which is itself
the correct, structurally-guaranteed fix for the heading-swallowing bug
class (nothing pre-verse-1 is ever embedded to be swallowed in the first
place; see ``web_source.py``'s docstring).

Run as a script (see ``__main__`` below). Needs no credential and makes no
network call -- the vendored ``data/vendor/eng-web.usfx.xml`` (see
``data/vendor/SOURCE.md``) is parsed entirely offline, unlike the retired
api.esv.org integration this replaces. Never imported by any runtime
request path -- ``bible_text.py`` stays a static, in-process, no-network
lookup at serve time; this only ever runs as a manual/CI batch job that
regenerates the checked-in ``data/bible.json`` and syncs it to both shipped
copies.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import sys
from pathlib import Path

from backend.bibleHandling import web_source
from backend.bibleHandling.bible_books import BOOK_CHAPTER_COUNTS
from backend.bibleHandling.web_source import WebSourceError, clean_whitespace

logger = logging.getLogger(__name__)

_REPO_ROOT = Path(__file__).resolve().parents[3]
CANONICAL_PATH = _REPO_ROOT / "data" / "bible.json"
SHIPPED_COPY_PATHS = [
    _REPO_ROOT / "FellowScript" / "FellowScript" / "Bible" / "bible.json",
    _REPO_ROOT / "api" / "backend" / "interactions" / "bible_data" / "bible.json",
]


class BibleGenerationError(RuntimeError):
    """The generation pipeline itself produced something it can't stand
    behind -- e.g. a chapter with no verse 1 at all. Raised instead of
    writing a silently-malformed chapter blob (Architecture/Implementation
    Q26/Q27 -- explicit propagation over a quiet best-effort guess, now
    that the source itself is meant to be trustworthy)."""


def build_chapter_blob(book: str, chapter_num: int, verses: dict[int, str]) -> str:
    """Turn one chapter's ``{verse_num: raw_text}`` (as returned by
    ``web_source.extract_book``) into this project's existing flowing-blob
    shape.

    Any verse whose cleaned text is empty is dropped entirely -- not
    emitted as a bare, textless numeral -- see this module's own docstring
    and ``web_source.py``'s for why: a small number of WEB verses (Acts
    8:37, Acts 15:34, Acts 24:7, Luke 17:36, ...) carry a real ``<v>``
    marker whose entire content the translators omitted into a footnote as
    absent from the earliest manuscripts. Emitting that marker's bare digit
    with no following text glues it directly onto the *next* verse's own
    digit marker (e.g. raw ``"...baptized?"3738He commanded..."`` for Acts
    8, before this fix), which breaks every downstream consumer's
    ``(?<!\\d)`` verse-boundary guard and silently merges two real verses
    into one bogus one. Dropping it entirely instead reproduces the
    ordinary, already-documented "translator omitted this verse number"
    contract every consumer's parser already expects.
    """
    verse_1 = clean_whitespace(verses.get(1, ""))
    if not verse_1:
        raise BibleGenerationError(
            f"{book} {chapter_num}: no (non-empty) verse 1 found in the vendored source -- "
            "refusing to write a chapter with no real opening verse."
        )

    max_verse = max(verses.keys())
    pieces = [f"{chapter_num}:1 {verse_1}"]
    for vnum in range(2, max_verse + 1):
        raw = verses.get(vnum)
        if raw is None:
            continue  # no such verse number in this chapter at all (normal -- not every chapter's verses are contiguous ints in the source)
        text = clean_whitespace(raw)
        if not text:
            logger.debug(
                "%s %d:%d: translator-omitted verse (marker present, no text) -- dropping "
                "the marker entirely rather than emitting a textless numeral.",
                book, chapter_num, vnum,
            )
            continue
        pieces.append(f"{vnum}{text}")
    return "".join(pieces)


def generate_book(book: str, num_chapters: int) -> list[str]:
    """Extract every real chapter of ``book`` from the vendored source and
    return the uniform ``[""] + [chapter_1, ..., chapter_N]`` list -- index
    0 is always an unused empty placeholder, for every book (see module
    docstring)."""
    chapters_raw = web_source.extract_book(book)

    missing = [n for n in range(1, num_chapters + 1) if n not in chapters_raw]
    if missing:
        raise BibleGenerationError(
            f"{book}: vendored source is missing chapter(s) {missing} "
            f"(expected {num_chapters} chapters per bible_books.BOOK_CHAPTER_COUNTS)."
        )
    extra = sorted(set(chapters_raw) - set(range(1, num_chapters + 1)))
    if extra:
        logger.warning(
            "%s: vendored source has chapter(s) %s beyond the expected %d -- "
            "ignoring them (bible_books.BOOK_CHAPTER_COUNTS is authoritative).",
            book, extra, num_chapters,
        )

    chapters = [""]
    for chapter_num in range(1, num_chapters + 1):
        chapters.append(build_chapter_blob(book, chapter_num, chapters_raw[chapter_num]))
    return chapters


def generate_all() -> dict[str, list[str]]:
    data: dict[str, list[str]] = {}
    errors: list[str] = []
    for book, num_chapters in BOOK_CHAPTER_COUNTS.items():
        try:
            data[book] = generate_book(book, num_chapters)
        except (WebSourceError, BibleGenerationError) as e:
            errors.append(f"{book}: {e}")
            logger.error("Failed to generate %s: %s", book, e)
    if errors:
        raise BibleGenerationError(
            f"{len(errors)}/{len(BOOK_CHAPTER_COUNTS)} book(s) failed to generate -- "
            f"refusing to write a partial dataset:\n" + "\n".join(errors)
        )
    return data


def write_canonical(data: dict[str, list[str]], path: Path = CANONICAL_PATH) -> None:
    """Atomic write (temp file + rename) so a crash mid-write can never
    leave a truncated/corrupt canonical bible.json on disk."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, path)
    logger.info("Wrote canonical bible data to %s", path)


def sync_shipped_copies(
    canonical_path: Path = CANONICAL_PATH,
    targets: list[Path] = SHIPPED_COPY_PATHS,
) -> None:
    """Copy the canonical generated file byte-for-byte to every shipped
    location, then verify the copies actually match -- "one shared source,
    not two independently-copied files that can drift" (acceptance
    criteria). Never hand-edit a shipped copy directly; always regenerate
    the canonical file and re-run this."""
    canonical_bytes = canonical_path.read_bytes()
    for target in targets:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(canonical_path, target)
        if target.read_bytes() != canonical_bytes:
            raise BibleGenerationError(f"Sync verification failed: {target} does not match {canonical_path}")
        logger.info("Synced %s", target)


def _self_check(data: dict[str, list[str]]) -> None:
    """Run `bible_text.validate_bible_data()` against the just-generated
    dataset before declaring the run successful -- catches a generation-
    side regression immediately, rather than only at the next app boot.
    Forces a fresh load/cache reset first since `bible_text` caches its
    parsed data at module-import scope and this script runs in the same
    process that just wrote the file."""
    from backend.interactions import bible_text
    bible_text._raw_books = None  # noqa: SLF001 -- same-process cache reset, script-only
    bible_text._chapter_cache.clear()
    bible_text.validate_bible_data()
    logger.info("Self-check passed: validate_bible_data() found no issues in the freshly generated data.")


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        data = generate_all()
    except (BibleGenerationError,) as e:
        logger.error("Generation aborted: %s", e)
        return 1
    write_canonical(data)
    sync_shipped_copies()
    _self_check(data)
    logger.info("Done: %d books written to %s and synced to %d shipped copies.",
                len(data), CANONICAL_PATH, len(SHIPPED_COPY_PATHS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
