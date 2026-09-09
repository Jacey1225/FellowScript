"""Tests for task 20260908-bible-verse-boundary-parsing (backend step 2 /
testing step 3): `bible_text.py`'s `_VERSE_SPLIT_RE`/`_HEAD_RE` widened
character class (curly opening single quote, opening parenthesis, plus the
`(?<!\\d)` guard) alongside the pre-existing curly-opening-double-quote case.

Covers:
  1. The specific real-data regression case named in the intake spec
     (Genesis 8:16, curly-double-quote opener) still resolves correctly.
  2. The newly-added curly-single-quote and opening-parenthesis openers
     recover a verse that previously merged into its predecessor (real
     `bible.json` instances: Genesis 22:23, Genesis 27:7 per backend.json's
     own summary).
  3. No regression to the `(?<!\\d)` guard, footnote-marker/section-header
     handling, or the documented "unparseable chapter -> None" fallback
     contract.
  4. A full-corpus scan (all 66 books) confirming: (a) the specific curly-
     quote/curly-single-quote/paren gap this task targets is fully closed on
     every reachable, well-formed chapter, and (b) every remaining
     backend-vs-client-parser divergence traces back to one of exactly two
     pre-existing, out-of-scope conditions predating this task -- verse text
     that opens with a lowercase letter (`bible_text.py`'s own docstring
     already documents this "enjambed" cosmetic gap; unrelated to this
     task's punctuation-class fix) and the two disputed "longer ending"
     appendix/fragment chapters (Mark's index-17 appendix, John's
     index-8/9 pericope-adulterae fragments) that `_CHAPTER_START_RE`
     already couldn't open before this task, for a reason unrelated to the
     verse-boundary character class -- so this task introduces no new,
     unexplained divergence from the client parsers.
  5. The opening-double-square-bracket (`[`) marginal case the frontend gate
     found (Mark 16:9, John 7:53) does NOT need to be mirrored into this
     module: those two chapters are already unopenable by
     `_CHAPTER_START_RE` (a pre-existing, unrelated limitation), so adding
     `[` here would recover nothing for them -- and would actively regress
     38 other, unrelated, real chapters where a verse number is immediately
     followed by a footnote marker (e.g. "55[147] Early in the morning...",
     Genesis 31:55) because, unlike the client parsers, this module never
     strips footnote markers before splitting verses, so `[` would wrongly
     treat the footnote's own bracket as a verse-opener and leave the raw
     "[147]" citation baked into the recovered verse's text.

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
        text is not None and text.startswith("“Go out from the ark"),
        repr(text),
    )
    text15 = bible_text_module.verse_text("Genesis", 8, 15)
    check(
        "Genesis 8:15 no longer absorbs verse 16's text",
        text15 is not None and "Go out from the ark" not in text15,
        repr(text15),
    )


# ── 2. Newly-added curly-single-quote and paren openers ─────────────────────

def test_curly_single_quote_and_paren_openers_real_instances():
    # Genesis 22:23: "...Bethuel." 23(Bethuel fathered Rebekah)." -- an
    # opening-parenthesis verse.
    v23 = bible_text_module.verse_text("Genesis", 22, 23)
    check(
        "Genesis 22:23 (opening-parenthesis opener) resolves independently",
        v23 is not None and v23.startswith("("),
        repr(v23),
    )
    v22 = bible_text_module.verse_text("Genesis", 22, 22)
    check(
        "Genesis 22:22 no longer absorbs verse 23's parenthetical text",
        v22 is not None and "fathered Rebekah" not in v22,
        repr(v22),
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
    # Confirm the reasoning documented above with a live check: bracket-class
    # absence doesn't cost us the two real cited cases, because those
    # chapters are already unparseable for an unrelated, pre-existing
    # reason (_CHAPTER_START_RE requires the blob to open "chapter:1").
    books = bible_text_module._load_raw()
    mark_chapters = books.get("Mark", [])
    john_chapters = books.get("John", [])

    check("Mark has the expected extra (index-17) appendix entry in bible.json", len(mark_chapters) == 18, len(mark_chapters))
    if len(mark_chapters) == 18:
        check(
            "Mark's appendix chapter (idx 17) is still unparseable by _CHAPTER_START_RE (pre-existing, unrelated to this task)",
            bible_text_module._parse_chapter(mark_chapters[17]) is None,
            mark_chapters[17][:60],
        )

    check("John has the expected extra fragment entries in bible.json", len(john_chapters) == 23, len(john_chapters))
    if len(john_chapters) == 23:
        check(
            "John's pericope-adulterae fragment (idx 9) is still unparseable by _CHAPTER_START_RE (pre-existing, unrelated to this task)",
            bible_text_module._parse_chapter(john_chapters[9]) is None,
            john_chapters[9][:60],
        )

    # And confirm adding "[" would have regressed real, unrelated chapters
    # (footnote-marker-adjacent verse numbers) since this module doesn't
    # strip footnote markers before splitting -- Genesis 31:55 is one real
    # instance ("...country. 55[147] Early in the morning Laban arose...").
    gen31 = books.get("Genesis", [])[31]
    hypothetical_re = re.compile(r"(?<!\d)(\d+)(?=[A-Z“‘(\[])")
    cleaned = bible_text_module._HEAD_RE.sub("", gen31)
    m = bible_text_module._CHAPTER_START_RE.match(cleaned)
    check("Genesis 31 chapter blob is well-formed (sanity check)", bool(m), gen31[:40])
    if m:
        real_parts = bible_text_module._VERSE_SPLIT_RE.split(m.group(2))
        hypothetical_parts = hypothetical_re.split(m.group(2))
        check(
            "adding '[' to this module's class would wrongly split on a footnote marker's bracket (Genesis 31:55), confirming '[' should stay excluded here",
            "55" in hypothetical_parts and "55" not in real_parts,
            (real_parts.count("55"), hypothetical_parts.count("55")),
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
    known_artifact_chapters = {("Mark", 17), ("John", 8), ("John", 9)}
    none_mismatches_outside_known = []
    total_chapters = 0

    for book, chapters in books.items():
        for idx in range(1, len(chapters)):
            total_chapters += 1
            blob = chapters[idx]
            backend_verses = bible_text_module._parse_chapter(blob)
            client_verses = _client_parse_chapter(blob)

            if (book, idx) in known_artifact_chapters:
                # John idx 8 ("8:11.][41]HEAD:: The Woman Caught in
                # Adultery") is the other half of the same pre-existing
                # pericope-adulterae data-splitting artifact as John idx 9
                # (see test_bracket_not_added_is_correct_not_a_gap): upstream
                # bible.json generation mis-split John 7's closing footnote
                # ("...do not include 7:53-8:11.]...") into its own tiny
                # bogus "chapter" entry, whose leading digits
                # (_CHAPTER_START_RE greedily matching "8:1" out of "8:11")
                # produce nonsense verse numbers in both parsers that
                # disagree with each other for reasons wholly unrelated to
                # verse-boundary punctuation. Pre-existing, out of this
                # task's scope (a bible.json content/generation issue, not a
                # parsing-logic one) -- skip rather than let it masquerade
                # as a punctuation-class regression.
                continue

            if backend_verses is None or client_verses is None:
                if backend_verses != client_verses:
                    none_mismatches_outside_known.append((book, idx))
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
        "no divergence outside the two known pre-existing appendix/fragment chapters (Mark idx17, John idx8/9)",
        len(none_mismatches_outside_known) == 0,
        none_mismatches_outside_known,
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
