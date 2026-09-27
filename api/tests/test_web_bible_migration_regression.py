"""Regression tests for task 20260927-esv-bible-source-migration (testing
step 2): spot-checks the WEB-sourced ``bible.json`` (replacing ESV) for the
four bug classes this migration specifically had to fix, plus the "one
shared source, no independent hand-copy" acceptance criterion.

Covers:
  1. John/Mark disputed-passage indexing: the old ESV PDF-scrape split John
     7:53-8:11 and Mark 16:9-20 out into orphan array entries, shifting every
     later chapter's index by one. The WEB/USFX pipeline extracts by real
     ``<c>``/``<v>`` structural markers, so this is structurally impossible --
     confirmed here by exact array length (no orphan slot) and by both
     passages resolving as ordinary verses inside their real home chapters.
  2. The missing-index-0-placeholder bug: 11 books (Isaiah, Song of Solomon,
     Jeremiah, Hosea, Joel, Amos, Micah, Nahum, Habakkuk, Zephaniah, Malachi)
     previously had no leading placeholder slot under the old ESV pipeline.
     ``generate_book`` now unconditionally emits ``[""] + [...]`` for every
     book -- confirmed for all 66, not just the 11 originally named.
  3. The heading-before-verse-1-swallowing bug: a chapter-opening heading
     (e.g. a Psalm superscription) sitting between the chapter marker and
     verse 1 must never be embedded into verse 1's own text.
  4. The newly-found empty-omitted-verse digit-gluing bug (WEB-specific,
     did not exist in the ESV pipeline): a handful of WEB verses carry a
     real ``<v>`` marker whose entire content is a translator footnote
     explaining the traditional verse number is absent from the earliest
     manuscripts (Acts 8:37, Acts 15:34, Acts 24:7, Luke 17:36). Emitting
     that verse's bare digit with no text glues it onto the *next* verse's
     digit marker (e.g. a literal "...baptized?"3738He commanded..." blob
     for Acts 8), corrupting both verses. Confirms each such verse is
     dropped cleanly (None) rather than glued, and that its neighbors on
     both sides resolve independently and correctly.
  5. One shared source of truth: all three shipped copies
     (``data/bible.json``, the iOS bundle copy, the backend API copy) are
     byte-identical -- no independent hand-copy drift.
  6. ``validate_bible_data()`` (wired into ``main.py``'s lifespan) passes
     cleanly against the real generated data.
  7. A full-corpus scan confirms no digit-gluing artifact survives anywhere
     in the dataset (not just the four instances named in the intake spec),
     by checking no parsed verse number ever exceeds
     ``bible_text.MAX_VERSE_NUMBER``.

Run:  cd api && ../.venv/bin/python tests/test_web_bible_migration_regression.py
"""
import _pathfix  # noqa: F401,E402

import hashlib
import sys
from pathlib import Path

import backend.interactions.bible_text as bible_text_module  # noqa: E402
from backend.bibleHandling.generate_bible_data import (  # noqa: E402
    CANONICAL_PATH,
    SHIPPED_COPY_PATHS,
)

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── 1. John/Mark disputed-passage indexing ──────────────────────────────────

def test_john_mark_disputed_passage_indexing():
    books = bible_text_module._load_raw()
    john = books.get("John", [])
    mark = books.get("Mark", [])

    check("John has exactly 22 entries (placeholder + 21 real chapters, no orphan)", len(john) == 22, len(john))
    check("Mark has exactly 17 entries (placeholder + 16 real chapters, no orphan)", len(mark) == 17, len(mark))

    # John 7:53-8:11 (the disputed pericope adulterae) resolves as ordinary
    # verses inside John's real chapters 7 and 8, not a split-off fragment.
    j7_53 = bible_text_module.verse_text("John", 7, 53)
    j8_1 = bible_text_module.verse_text("John", 8, 1)
    j8_11 = bible_text_module.verse_text("John", 8, 11)
    check("John 7:53 resolves inside real chapter 7", j7_53 is not None, repr(j7_53))
    check("John 8:1 resolves inside real chapter 8", j8_1 is not None, repr(j8_1))
    check(
        "John 8:11 (end of the disputed passage) resolves inside real chapter 8",
        j8_11 is not None and "condemn" in j8_11.lower(),
        repr(j8_11),
    )

    # Mark 16:9-20 (the "longer ending") resolves as ordinary verses inside
    # Mark's real chapter 16, not an appendix entry.
    m16_9 = bible_text_module.verse_text("Mark", 16, 9)
    m16_20 = bible_text_module.verse_text("Mark", 16, 20)
    check("Mark 16:9 resolves inside real chapter 16", m16_9 is not None and "Magdalene" in m16_9, repr(m16_9))
    check("Mark 16:20 resolves inside real chapter 16 (end of the longer ending)", m16_20 is not None, repr(m16_20))

    # Chapter immediately after the old orphan-shift point still indexes
    # correctly by real chapter number (the original bug's own symptom:
    # array position N held chapter N-1's real text).
    j15_1 = bible_text_module.verse_text("John", 15, 1)
    check(
        "John 15:1 holds chapter 15's own real text (the vine discourse), not chapter 14's",
        j15_1 is not None and "vine" in j15_1.lower(),
        repr(j15_1),
    )


# ── 2. Missing-index-0-placeholder bug (11 books, audited across all 66) ────

_PREVIOUSLY_AFFECTED_11 = [
    "Isaiah", "Song of Solomon", "Jeremiah", "Hosea", "Joel", "Amos",
    "Micah", "Nahum", "Habakkuk", "Zephaniah", "Malachi",
]


def test_no_placeholder_bug_fixed_for_all_66_books():
    books = bible_text_module._load_raw()
    check("bible.json has all 66 canonical books", len(books) == 66, len(books))

    for book in _PREVIOUSLY_AFFECTED_11:
        check(f"{book} (previously-affected) has an empty index-0 placeholder", books[book][0] == "", repr(books[book][0])[:60])

    missing_placeholder = [b for b, chs in books.items() if not chs or chs[0] != ""]
    check("every book (all 66, not just the 11 originally named) has an empty index-0 placeholder", missing_placeholder == [], missing_placeholder)


# ── 3. Heading-before-verse-1-swallowing bug ────────────────────────────────

def test_heading_before_verse_1_not_swallowed():
    # Psalm 3 carries a real superscription ("A Psalm by David, when he fled
    # from Absalom his son.") between the chapter marker and verse 1's own
    # text -- it must not be prepended into verse 1.
    p3_1 = bible_text_module.verse_text("Psalms", 3, 1)
    check("Psalm 3:1 resolves", p3_1 is not None, repr(p3_1))
    if p3_1 is not None:
        check(
            "Psalm 3:1 does not have the superscription swallowed into its own text",
            "Absalom" not in p3_1 and not p3_1.startswith("A Psalm"),
            repr(p3_1),
        )
        check("Psalm 3:1 is the psalm's own opening line", p3_1.startswith("Yahweh"), repr(p3_1))


# ── 4. Newly-found empty-omitted-verse digit-gluing bug ─────────────────────

_OMITTED_VERSES_AND_NEIGHBORS = [
    ("Acts", 8, 36, 37, 38),
    ("Acts", 15, 33, 34, 35),
    ("Acts", 24, 6, 7, 8),
    ("Luke", 17, 35, 36, 37),
]


def test_empty_omitted_verse_digit_gluing_fixed():
    for book, chapter, before, omitted, after in _OMITTED_VERSES_AND_NEIGHBORS:
        v_before = bible_text_module.verse_text(book, chapter, before)
        v_omitted = bible_text_module.verse_text(book, chapter, omitted)
        v_after = bible_text_module.verse_text(book, chapter, after)

        check(f"{book} {chapter}:{omitted} (translator-omitted) resolves to None, not a glued digit", v_omitted is None, repr(v_omitted))
        check(f"{book} {chapter}:{before} resolves independently and is not empty", bool(v_before), repr(v_before))
        check(f"{book} {chapter}:{after} resolves independently and is not empty", bool(v_after), repr(v_after))
        # The specific corruption this bug caused: verse N's text getting
        # glued with verse N+1's digits (e.g. a literal "3738" run). Confirm
        # neither neighbor's text contains a bare concatenation of the
        # omitted verse number with the next one.
        glued = f"{omitted}{after}"
        check(
            f"{book} {chapter}:{before} does not contain the glued-digit artifact ('{glued}')",
            glued not in (v_before or ""),
            repr(v_before),
        )


def test_no_digit_gluing_artifact_anywhere_in_corpus():
    """Full-corpus check, not just the four named instances: no parsed verse
    number should ever exceed MAX_VERSE_NUMBER (176, Psalm 119) -- a glued
    multi-digit artifact (e.g. "3738") would blow past this ceiling."""
    books = bible_text_module._load_raw()
    max_verse = bible_text_module.MAX_VERSE_NUMBER
    offenders = []
    for book, chapters in books.items():
        for idx in range(1, len(chapters)):
            verses = bible_text_module._parse_chapter(chapters[idx])
            if verses is None:
                continue
            for vnum in verses:
                if vnum > max_verse:
                    offenders.append((book, idx, vnum))
    check(f"no parsed verse number exceeds MAX_VERSE_NUMBER ({max_verse}) anywhere in the corpus", offenders == [], offenders[:10])


# ── 5. One shared source of truth (no independent hand-copy drift) ─────────

def test_shipped_copies_are_byte_identical_to_canonical():
    check("canonical bible.json exists", CANONICAL_PATH.exists(), str(CANONICAL_PATH))
    if not CANONICAL_PATH.exists():
        return
    canonical_hash = hashlib.sha256(CANONICAL_PATH.read_bytes()).hexdigest()
    for target in SHIPPED_COPY_PATHS:
        check(f"{target} exists", target.exists(), str(target))
        if target.exists():
            target_hash = hashlib.sha256(target.read_bytes()).hexdigest()
            check(f"{target} is byte-identical to canonical {CANONICAL_PATH}", target_hash == canonical_hash, (canonical_hash, target_hash))


# ── 6. validate_bible_data() passes cleanly ─────────────────────────────────

def test_validate_bible_data_passes():
    try:
        bible_text_module.validate_bible_data()
        check("validate_bible_data() raises no BibleDataError against the real generated data", True)
    except bible_text_module.BibleDataError as e:
        check("validate_bible_data() raises no BibleDataError against the real generated data", False, str(e)[:500])


def main():
    test_john_mark_disputed_passage_indexing()
    test_no_placeholder_bug_fixed_for_all_66_books()
    test_heading_before_verse_1_not_swallowed()
    test_empty_omitted_verse_digit_gluing_fixed()
    test_no_digit_gluing_artifact_anywhere_in_corpus()
    test_shipped_copies_are_byte_identical_to_canonical()
    test_validate_bible_data_passes()

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
