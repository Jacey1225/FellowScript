"""Tests for task 20260908-bible-verse-boundary-parsing (backend step 2 /
testing step 3): `bible_text.py`'s `_VERSE_SPLIT_RE`/`_HEAD_RE` widened
character class (curly opening single quote, opening parenthesis, plus the
`(?<!\\d)` guard) alongside the pre-existing curly-opening-double-quote case.

**Updated for task 20260927-esv-bible-source-migration (testing step 2):**
this file's real-instance assertions originally hardcoded ESV's exact
wording/structure. ESV has since been fully replaced by the public-domain
World English Bible (WEB), sourced from `seven1m/bible_api`'s USFX dataset
(see `web_source.py`/`generate_bible_data.py`) -- a wording/structure
change, not a parsing regression: the verse-boundary split logic itself was
confirmed unchanged and still passes its own structural checks (see
`test_web_bible_migration_regression.py` for this migration's own bug-class
regression coverage: John/Mark disputed-passage indexing, the 11-book
placeholder fix, heading-swallowing, and the newly-found digit-gluing bug).
The specific fixes made here:
  - Genesis 8:16's expected wording updated to real WEB text (WEB renders
    the passage differently from ESV; the split point is what this test
    verifies, not the exact prose).
  - Genesis 22:23 no longer opens with an opening parenthesis under WEB (WEB
    phrases that verse as a plain declarative sentence) -- replaced with
    Deuteronomy 2:9/2:10, a real WEB instance that does open on "(", so the
    opening-parenthesis-opener path still has real-data coverage.
  - The old "Mark has an 18th/John has a 23rd orphan array entry" assertions
    inverted ESV-scrape-bug artifacts that no longer exist under the WEB
    pipeline (that pipeline extracts by real `<c>`/`<v>` structural markers,
    so the orphan-entry bug class is structurally impossible) -- replaced
    with an assertion that no such orphan entry exists, which is the fix
    working as intended, not a regression.
  - The Genesis 31:55 footnote-bracket ("[147]") collision check no longer
    applies: WEB generation strips footnote subtrees entirely at the
    source (confirmed: zero literal "[" characters appear anywhere in the
    generated corpus), so there is no footnote-marker text left to collide
    with an opening-bracket verse-splitter class at all under this source.
    Replaced with a direct corpus-wide confirmation of that fact.
  - The full-corpus parity scan's `known_artifact_chapters` skip-list
    (`Mark` idx 17, `John` idx 8/9) targeted the old ESV pipeline's orphan
    array slots. Under WEB, Mark has only 17 entries total (idx 17 is out of
    range -- harmless leftover) but John has 22 entries, meaning idx 8 and 9
    are now John's own *real* chapters 8 and 9 -- keeping the skip would
    silently exclude real chapters from the parity scan. Removed.

Covers:
  1. The specific real-data regression case named in the intake spec
     (Genesis 8:16, curly-double-quote opener) still resolves correctly.
  2. The newly-added curly-single-quote and opening-parenthesis openers
     recover a verse that previously merged into its predecessor (real WEB
     `bible.json` instances: Genesis 8:16, Deuteronomy 2:10).
  3. No regression to the `(?<!\\d)` guard, footnote-marker/section-header
     handling, or the documented "unparseable chapter -> None" fallback
     contract.
  4. A full-corpus scan (all 66 books, every chapter, no skip-list)
     confirming every backend-vs-client-parser divergence traces back to
     exactly one pre-existing, out-of-scope condition predating this task --
     verse text that opens with a lowercase letter (`bible_text.py`'s own
     docstring already documents this "enjambed" cosmetic gap; unrelated to
     this task's punctuation-class fix) -- so this task introduces no new,
     unexplained divergence from the client parsers.
  5. The opening-double-square-bracket (`[`) marginal case the frontend gate
     found under the old ESV data does NOT need to be mirrored into this
     module: under WEB, footnotes (the only source of literal "[" brackets
     in the old data) are stripped entirely at generation, so there is no
     bracket anywhere in the corpus for `[` to collide with in the first
     place -- confirmed directly rather than assumed.

Run:  cd api && ../.venv/bin/python tests/test_bible_verse_boundary_parsing.py
"""
import _pathfix  # noqa: F401,E402

import re
import sys

import backend.interactions.bible_text as bible_text_module  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── 1. Real-data regression case named in the intake spec ──────────────────

def test_genesis_8_16_curly_double_quote():
    text = bible_text_module.verse_text("Genesis", 8, 16)
    check(
        "Genesis 8:16 (curly-double-quote opener) resolves independently",
        text is not None and text.startswith("“Go out of the ship"),
        repr(text),
    )
    text15 = bible_text_module.verse_text("Genesis", 8, 15)
    check(
        "Genesis 8:15 no longer absorbs verse 16's text",
        text15 is not None and "Go out of the ship" not in text15,
        repr(text15),
    )


# ── 2. Newly-added curly-single-quote and paren openers ─────────────────────

def test_curly_single_quote_and_paren_openers_real_instances():
    # Deuteronomy 2:9-10: "...for a possession.” 10(The Emim lived
    # therein before...)" -- a real WEB opening-parenthesis verse. (Genesis
    # 22:23, the ESV-era real instance for this case, no longer opens with a
    # parenthesis under WEB's phrasing -- see this module's docstring.)
    v10 = bible_text_module.verse_text("Deuteronomy", 2, 10)
    check(
        "Deuteronomy 2:10 (opening-parenthesis opener) resolves independently",
        v10 is not None and v10.startswith("("),
        repr(v10),
    )
    v9 = bible_text_module.verse_text("Deuteronomy", 2, 9)
    check(
        "Deuteronomy 2:9 no longer absorbs verse 10's parenthetical text",
        v9 is not None and "Emim" not in v9,
        repr(v9),
    )


def test_verse_split_re_character_class_matches_client_scope():
    # Direct regex-level check of the widened class this task targets:
    # curly double quote, curly single quote, opening parenthesis, plus the
    # (?<!\d) guard -- independent of any specific bible.json row, in case
    # the underlying data shifts.
    pattern = bible_text_module._VERSE_SPLIT_RE
    for opener, label in [
        ("“", "curly double quote"),
        ("‘", "curly single quote"),
        ("(", "opening parenthesis"),
        ("A", "capital letter (pre-existing)"),
    ]:
        sample = f"first verse text. 2{opener}next verse text"
        m = pattern.search(sample)
        check(f"_VERSE_SPLIT_RE recognizes {label} as a verse-opener", bool(m) and m.group(1) == "2", repr(sample))

    # (?<!\d) guard: a multi-digit verse number shouldn't spuriously split on
    # its own trailing digit.
    sample_guard = "text ending in the year 1914“Quoted speech follows"
    matches = list(pattern.finditer(sample_guard))
    check(
        "(?<!\\d) guard prevents a false split mid multi-digit number",
        all(m.group(1) != "4" for m in matches),
        [m.group(1) for m in matches],
    )


# ── 3. No regression to existing behavior ───────────────────────────────────

def test_no_regression_footnote_and_head_and_first_verse():
    # John 1:1-2 still parse correctly (footnote-marker-adjacent, capital-
    # letter opener, HEAD:: stripping all pre-existing/unchanged behavior).
    v1 = bible_text_module.verse_text("John", 1, 1)
    check("John 1:1 still resolves (first-verse chapter:verse pattern intact)", v1 is not None, repr(v1))

    v2 = bible_text_module.verse_text("Mark", 1, 9)
    check(
        "Mark 1:9 still resolves after a HEAD:: section (section-header stripping intact)",
        v2 is not None and v2.startswith("In those days"),
        repr(v2),
    )

    # Unparseable chapter (out-of-range) still returns None, not a raise.
    miss = bible_text_module.verse_text("Genesis", 999, 1)
    check("out-of-range chapter still returns None (fallback contract preserved)", miss is None, repr(miss))


def test_bracket_not_added_is_correct_not_a_gap():
    # Under WEB, the ESV-era orphan-array-entry bug this test originally
    # documented no longer exists at all: the WEB/USFX pipeline extracts by
    # real <c>/<v> structural markers, so a disputed passage can never split
    # off into its own array slot. Confirm the fix directly (no orphan
    # entry, exact expected entry counts) rather than the old bug's
    # continued presence.
    books = bible_text_module._load_raw()
    mark_chapters = books.get("Mark", [])
    john_chapters = books.get("John", [])

    check("Mark has no orphan appendix entry (exactly 17: placeholder + 16 real chapters)", len(mark_chapters) == 17, len(mark_chapters))
    check("John has no orphan fragment entries (exactly 22: placeholder + 21 real chapters)", len(john_chapters) == 22, len(john_chapters))

    # Mark 16's "longer ending" and John 8's half of the disputed pericope
    # (the passages that caused the old orphan entries) now parse as
    # ordinary verses inside their real home chapters.
    check(
        "Mark 16 (containing the longer ending, 16:9-20) parses normally as an ordinary chapter",
        len(mark_chapters) > 16 and bible_text_module._parse_chapter(mark_chapters[16]) is not None,
        mark_chapters[16][:60] if len(mark_chapters) > 16 else None,
    )
    check(
        "John 8 (containing 8:1-11, the back half of the disputed pericope) parses normally as an ordinary chapter",
        len(john_chapters) > 8 and bible_text_module._parse_chapter(john_chapters[8]) is not None,
        john_chapters[8][:60] if len(john_chapters) > 8 else None,
    )

    # And confirm "[" staying excluded from this module's verse-split class
    # costs nothing under WEB: footnotes (the old data's only source of
    # literal "[147]"-style brackets) are stripped entirely at generation
    # for this source, so there is no bracket anywhere in the corpus left
    # for "[" to collide with -- Genesis 31:55, the ESV-era real instance
    # cited here previously, no longer carries one.
    gen31 = books.get("Genesis", [])[31]
    check(
        "Genesis 31 chapter blob carries no literal '[' (footnotes are stripped entirely under WEB)",
        "[" not in gen31,
        gen31[:200],
    )
    bracket_chapters = [
        (book, idx)
        for book, chapters in books.items()
        for idx in range(1, len(chapters))
        if "[" in chapters[idx]
    ]
    check(
        "no chapter anywhere in the corpus contains a literal '[' (confirms '[' would recover nothing if added to this module's class)",
        bracket_chapters == [],
        bracket_chapters[:10],
    )


# ── 4. Full-corpus scan: confirm no unexplained divergence remains ─────────

_FOOTNOTE_RE = re.compile(r"\[\d+\]")
_HEAD_STRIP_RE = re.compile(r"HEAD::[^0-9]*")
_FIRST_VERSE_RE = re.compile(r"^\s*(\d+):(\d+)\s*")
_SUBSEQUENT_VERSE_RE = re.compile(r"(?<!\d)(\d+)(?=[A-Za-z“‘(\[])")


def _client_parse_chapter(ch_str):
    """Python re-implementation of the client parsers' algorithm (identical
    order of operations to frontend/src/utils.js, frontend/js/bible.js, and
    BibleReaderView.swift's parseVerses): strip footnote markers, strip
    HEAD:: sections, find the first-verse chapter:verse marker, then split
    subsequent verses on the widened lookahead class (now including the
    opening double square bracket the frontend gate added)."""
    text = _FOOTNOTE_RE.sub("", ch_str)
    text = _HEAD_STRIP_RE.sub(" ", text)
    entries = []
    m = _FIRST_VERSE_RE.match(text)
    search_from = 0
    if m:
        entries.append((int(m.group(2)), m.start(), m.end()))
        search_from = m.end()
    for mm in _SUBSEQUENT_VERSE_RE.finditer(text, search_from):
        vnum = int(mm.group(1))
        if vnum > 0:
            entries.append((vnum, mm.start(), mm.end()))
    if not entries:
        return None
    verses = {}
    for i, (num, _numStart, textStart) in enumerate(entries):
        end = entries[i + 1][1] if i + 1 < len(entries) else len(text)
        verses[num] = text[textStart:end].strip()
    return verses


def test_full_corpus_parity_no_unexplained_divergence():
    books = bible_text_module._load_raw()
    check("bible.json loaded with all 66 books", len(books) == 66, len(books))

    unexplained = []
    lowercase_explained = 0
    # NOTE: the old ESV-era skip-list here (`{("Mark", 17), ("John", 8),
    # ("John", 9)}`) targeted the old pipeline's own orphan array slots
    # (John's pericope-adulterae fragment, Mark's appendix entry). Under
    # WEB, Mark has no idx-17 entry at all (harmless if kept, but stale) and
    # John's idx 8/9 are now that book's own *real* chapters 8 and 9 --
    # keeping the skip would silently exclude real chapters from this scan.
    # Removed; every chapter is scanned for real now (confirmed: 0 divergence
    # remains once removed).
    none_mismatches = []
    total_chapters = 0

    for book, chapters in books.items():
        for idx in range(1, len(chapters)):
            total_chapters += 1
            blob = chapters[idx]
            backend_verses = bible_text_module._parse_chapter(blob)
            client_verses = _client_parse_chapter(blob)

            if backend_verses is None or client_verses is None:
                if backend_verses != client_verses:
                    none_mismatches.append((book, idx))
                continue

            bset, cset = set(backend_verses), set(client_verses)
            # Backend should never recognize a verse the client doesn't
            # (that would mean the newer, less-permissive-elsewhere backend
            # regex is somehow over-matching).
            if bset - cset:
                unexplained.append((book, idx, "backend_only", sorted(bset - cset)))
            for v in cset - bset:
                vtext = client_verses[v]
                if vtext and vtext[0].islower():
                    lowercase_explained += 1
                else:
                    unexplained.append((book, idx, v, vtext[:50]))

    check(f"scanned all {total_chapters} chapters across 66 books", total_chapters > 1000, total_chapters)
    check(
        "no None/None-mismatch divergence anywhere in the corpus (no skip-list needed under WEB)",
        len(none_mismatches) == 0,
        none_mismatches,
    )
    check(
        "every remaining backend-vs-client divergence is explained by the documented pre-existing lowercase-opener gap",
        len(unexplained) == 0,
        unexplained[:20],
    )
    print(f"  (info) lowercase-opener divergences explained: {lowercase_explained}")


def main():
    test_genesis_8_16_curly_double_quote()
    test_curly_single_quote_and_paren_openers_real_instances()
    test_verse_split_re_character_class_matches_client_scope()
    test_no_regression_footnote_and_head_and_first_verse()
    test_bracket_not_added_is_correct_not_a_gap()
    test_full_corpus_parity_no_unexplained_divergence()

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
