"""Task 20261017-devotion-note-format, testing gate: pure (no DB, no network)
tests for api/backend/interactions/note_template.py.

The class of bug: the SAME schedule's notes drifted day to day in whitespace,
heading markup, colons, quote style and where the scripture reference sat,
because the model wrote free-form text. The fix is a per-schedule template
plus one deterministic renderer. These tests prove:

  1. Same template + different days (and deliberately sloppy model output:
     markdown, HTML, odd whitespace, straight quotes) -> identical layout.
  2. Different templates -> different layouts (layout is per schedule).
  3. Freeform fallback renders title-less light paragraphs, no invented
     sections.
  4. Strict template validation rejects malformed templates (never repairs).
  5. Per-day field validation rejects bad model output (missing, empty,
     over-length, generic check-in, wrong passage, wrong types).
  6. Plain-text output has no markup (no tags, entities, markdown).
  7. Timeline day contract: build, normalize, legacy plain-string days.
  8. Check-in rule: follow-up only when a real prior application exists.

Run: cd api && ../.venv/bin/python tests/test_note_template.py
"""
import _pathfix  # noqa: F401

import copy
import json
import re
import sys

from backend.interactions import note_template as nt

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def raises(exc, fn, *a, **k) -> bool:
    try:
        fn(*a, **k)
    except exc:
        return True
    except Exception:
        return False
    return False


# The Oct 15/16/17 schedule's five sections (check-in, scripture, scripture
# summary, discussion prompt, application prompt) as a derived template.
FIVE = {
    "kind": "structured",
    "title": {"mode": "pattern", "pattern": "{theme}: {reference}"},
    "sections": [
        {"key": "check_in", "title": "Check-in", "layout": "heading", "kind": "text",
         "role": "check_in", "max_words": 40},
        {"key": "scripture", "title": "Scripture", "layout": "heading", "kind": "scripture",
         "max_words": 200},
        {"key": "summary", "title": "Scripture summary", "layout": "heading", "kind": "text",
         "max_words": 120},
        {"key": "discussion", "title": "Discussion prompt", "layout": "label", "kind": "text",
         "max_words": 50},
        {"key": "application", "title": "Application prompt", "layout": "label", "kind": "text",
         "role": "application", "max_words": 50},
    ],
}

# A very different schedule: free title, a quote, a list, a bare paragraph.
OTHER = {
    "kind": "structured",
    "title": {"mode": "free"},
    "sections": [
        {"key": "opener", "title": None, "layout": "paragraph", "kind": "text", "max_words": 60},
        {"key": "quote", "title": "Quote of the day", "layout": "label", "kind": "quote", "max_words": 40},
        {"key": "steps", "title": "Steps", "layout": "heading", "kind": "list", "max_words": 80},
    ],
}


def day_fields(passage: str, **over) -> dict:
    d = {
        "__action": "create_note",
        "theme": "Peace",
        "check_in": "How did you do with yesterday's kindness challenge?",
        "scripture": {"reference": passage, "text": "Be at peace among yourselves."},
        "summary": "Paul urges the church to live in peace.",
        "discussion": "Where is peace hardest for you?",
        "application": "Offer one act of patience today.",
    }
    d.update(over)
    return d


def render(tpl_raw, data, day=None) -> str:
    tpl = nt.validate_template(tpl_raw)
    return nt.render_note(tpl, nt.validate_fields(data, tpl, day))


def skeleton(text: str) -> list:
    """Layout fingerprint: each line reduced to its structural role, with
    content words masked so only whitespace/heading/colon/quote placement
    remains."""
    out = []
    for line in text.split("\n"):
        if not line.strip():
            out.append("<blank>")
        elif line in ("Check-in", "Scripture", "Scripture summary"):
            out.append(f"H[{line}]")
        elif line.startswith(("Discussion prompt: ", "Application prompt: ")):
            out.append("L[" + line.split(":")[0] + "]")
        elif line.startswith("“") and line.endswith("”"):
            out.append("<quoted>")
        elif re.match(r"^[1-3]?\s?[A-Za-z ]+ \d+:\d+(-\d+)?$", line):
            out.append("<ref>")
        else:
            out.append("<body>")
    return out


def main():
    tpl = nt.validate_template(FIVE)

    print("=== 1. Same schedule, different days -> identical layout ===")
    clean = render(FIVE, day_fields("1 Thessalonians 5:12-15"))
    # Sloppy output a model might emit: markdown headings, bold, HTML, extra
    # whitespace, straight quotes, a translation-free but oddly spaced ref.
    sloppy = day_fields(
        "1  Thessalonians   5:16-22",
        theme="  **Joy**  ",
        check_in="<p>How did **yesterday’s** act of patience go?</p>\n\n\n",
        summary="## Summary\n\nPaul says:   rejoice &amp; pray.\n\n\nGive thanks.",
        discussion="  > What makes joy hard?  ",
        application="- Thank God for <b>three</b> things.",
        scripture={"reference": "1 Thessalonians 5:16-22",
                   "text": '"Rejoice always, pray without ceasing."'},
    )
    other_day = render(FIVE, sloppy)
    third = render(FIVE, day_fields("1 Thessalonians 5:23-28", theme="Faithfulness",
                                    scripture={"reference": "1 Thessalonians 5:23-28",
                                               "text": "“God is faithful.”"}))
    check("day 1 vs day 2 same skeleton (summary has an extra paragraph so compare headings)",
          [s for s in skeleton(clean) if s.startswith(("H[", "L["))]
          == [s for s in skeleton(other_day) if s.startswith(("H[", "L["))])
    check("day 1 vs day 3 identical skeleton", skeleton(clean) == skeleton(third),
          f"{skeleton(clean)} vs {skeleton(third)}")
    check("title follows the pattern every day",
          nt.validate_fields(day_fields("1 Thessalonians 5:12-15"), tpl)["title"] == "Peace: 1 Thessalonians 5:12-15"
          and nt.validate_fields(sloppy, tpl)["title"] == "Joy: 1 Thessalonians 5:16-22")
    check("reference sits directly under the Scripture heading, then the quoted text",
          "Scripture\n1 Thessalonians 5:12-15\n“Be at peace among yourselves.”" in clean, clean)
    check("sloppy output also puts the reference under the heading",
          "Scripture\n1 Thessalonians 5:16-22\n“Rejoice always, pray without ceasing.”" in other_day, other_day)
    check("sections separated by exactly one blank line (never 2+)",
          "\n\n\n" not in clean and "\n\n\n" not in other_day and "\n\n\n" not in third)
    check("no leading/trailing whitespace on the note",
          clean == clean.strip() and other_day == other_day.strip())
    check("heading sections: title, newline, body; label sections: 'Title: body'",
          "Check-in\nHow did you do" in clean and "Discussion prompt: Where is peace hardest for you?" in clean
          and "Application prompt: Offer one act" in clean, clean)
    check("rendering is deterministic", render(FIVE, day_fields("1 Thessalonians 5:12-15")) == clean)
    check("section order matches the template",
          [clean.index(t) for t in ("Check-in", "Scripture\n", "Scripture summary", "Discussion prompt", "Application prompt")]
          == sorted(clean.index(t) for t in ("Check-in", "Scripture\n", "Scripture summary", "Discussion prompt", "Application prompt")))

    print("\n=== 2. Different schedules -> different layouts ===")
    o = render(OTHER, {"__action": "create_note", "title": "Gentle start", "theme": "Gentleness",
                       "opener": "Good morning.", "quote": '"Be kind."',
                       "steps": ["Breathe", "Pray"]})
    check("other template renders its own layout",
          o == "Good morning.\n\nQuote of the day: “Be kind.”\n\nSteps\n• Breathe\n• Pray", repr(o))
    check("layouts of the two schedules differ", skeleton(o) != skeleton(clean))
    fields_o = nt.validate_fields({"__action": "create_note", "title": "Gentle start", "theme": "Gentleness",
                                   "opener": "Good morning.", "quote": "Be kind.", "steps": ["Breathe"]},
                                  nt.validate_template(OTHER))
    check("free title mode uses the model title", fields_o["title"] == "Gentle start")
    check("no reference section -> verses come from optional model field (none here)", fields_o["verses"] == [])

    lab = render({"kind": "structured", "title": {"mode": "free"},
                  "sections": [{"key": "items", "title": "Prayer points", "layout": "label", "kind": "list", "max_words": 40},
                               {"key": "note", "title": "Note", "layout": "label", "kind": "text", "max_words": 40}]},
                 {"__action": "create_note", "title": "T", "theme": "x", "items": ["a", "b"], "note": "hi"})
    check("label section with a multi-line body puts the colon at the end of its own line",
          lab == "Prayer points:\n\u2022 a\n\u2022 b\n\nNote: hi", repr(lab))

    print("\n=== 3. Freeform fallback ===")
    ff = nt.validate_template({"kind": "freeform"})
    check("freeform expands to the explicit freeform template", ff == nt.FREEFORM_TEMPLATE and nt.is_freeform(ff))
    ff_in = {"__action": "create_note", "title": "A Title", "theme": "x", "text": "  First para.  \n\n\n\n Second   para. "}
    ff_out = nt.render_note(ff, nt.validate_fields(ff_in, ff))
    check("freeform: trimmed, blank-line separated paragraphs, no title in body",
          ff_out == "First para.\n\nSecond para.", repr(ff_out))
    check("freeform does not invent sections (single body section)", len(ff["sections"]) == 1)
    check("freeform theme optional", nt.validate_fields({"__action": "create_note", "title": "T", "text": "Body."}, ff)["theme"] == "")
    check("freeform with empty body is rejected",
          raises(nt.NoteValidationError, nt.validate_fields, {"__action": "create_note", "title": "T", "text": "  "}, ff))
    check("freeform with empty title is rejected",
          raises(nt.NoteValidationError, nt.validate_fields, {"__action": "create_note", "title": "", "text": "x"}, ff))

    print("\n=== 4. Template validation (strict, never repaired) ===")
    def bad(mutator) -> bool:
        t = copy.deepcopy(FIVE)
        mutator(t)
        return raises(nt.TemplateValidationError, nt.validate_template, t)

    check("not an object", raises(nt.TemplateValidationError, nt.validate_template, ["x"]))
    check("unknown kind", raises(nt.TemplateValidationError, nt.validate_template, {"kind": "weird"}))
    check("unsupported version", bad(lambda t: t.update(version=99)))
    check("empty sections", bad(lambda t: t.update(sections=[])))
    check("more than 12 sections", bad(lambda t: t.update(sections=[
        {"key": f"s{i}", "title": "T", "layout": "heading", "kind": "text", "max_words": 10} for i in range(13)])))
    check("duplicate key", bad(lambda t: t["sections"][1].update(key="check_in")))
    check("reserved key", bad(lambda t: t["sections"][0].update(key="title")))
    check("bad key charset", bad(lambda t: t["sections"][0].update(key="Bad Key")))
    check("unknown layout", bad(lambda t: t["sections"][0].update(layout="banner")))
    check("unknown field kind", bad(lambda t: t["sections"][0].update(kind="html")))
    check("heading without title", bad(lambda t: t["sections"][0].update(title="")))
    check("title with markup chars", bad(lambda t: t["sections"][0].update(title="<b>Hi</b>")))
    check("title with markdown heading char", bad(lambda t: t["sections"][0].update(title="# Hi")))
    check("title with braces", bad(lambda t: t["sections"][0].update(title="{x}")))
    check("title too long", bad(lambda t: t["sections"][0].update(title="x" * 61)))
    check("paragraph section may not have a title", bad(lambda t: t["sections"][2].update(layout="paragraph")))
    check("max_words below minimum", bad(lambda t: t["sections"][0].update(max_words=1)))
    check("max_words above maximum", bad(lambda t: t["sections"][0].update(max_words=601)))
    check("max_words bool rejected", bad(lambda t: t["sections"][0].update(max_words=True)))
    check("unknown role", bad(lambda t: t["sections"][0].update(role="boss")))
    check("role used twice", bad(lambda t: t["sections"][2].update(role="check_in")))
    check("role on a non-text kind", bad(lambda t: t["sections"][1].update(role="application")))
    check("two reference/scripture sections", bad(lambda t: t["sections"].append(
        {"key": "ref2", "title": "Ref", "layout": "label", "kind": "reference", "max_words": 10})))
    check("title mode invalid", bad(lambda t: t["title"].update(mode="html")))
    check("title pattern with unknown placeholder", bad(lambda t: t["title"].update(pattern="{theme} {evil}")))
    check("title pattern without placeholder", bad(lambda t: t["title"].update(pattern="Static")))
    check("title pattern with markup", bad(lambda t: t["title"].update(pattern="<i>{theme}</i>")))
    check("{reference} in pattern with no reference section",
          raises(nt.TemplateValidationError, nt.validate_template,
                 {"kind": "structured", "title": {"mode": "pattern", "pattern": "{reference}"},
                  "sections": [OTHER["sections"][0]]}))
    check("oversized template", bad(lambda t: t["sections"][0].update(title="a" * 59, extra="z" * 9000)))
    ok = nt.validate_template(FIVE)
    check("valid template normalises with version", ok["version"] == nt.TEMPLATE_VERSION and ok["kind"] == "structured")
    check("round-trip dump/load stable", nt.load_stored_template(nt.dump_template(ok)) == ok)
    check("load_stored_template None for empty", nt.load_stored_template(None) is None and nt.load_stored_template("") is None)
    check("load_stored_template None for corrupt/invalid", nt.load_stored_template("{not json") is None
          and nt.load_stored_template(json.dumps({"kind": "structured", "sections": []})) is None)
    check("prompt_hash stable and prompt-sensitive",
          nt.prompt_hash("a") == nt.prompt_hash("a") and nt.prompt_hash("a") != nt.prompt_hash("b"))

    print("\n=== 5. Per-day field validation (throws, never fabricates) ===")
    def rej(**over) -> bool:
        d = day_fields("Romans 8:1-4")
        d.update(over)
        return raises(nt.NoteValidationError, nt.validate_fields, d, tpl)

    def drop(key) -> bool:
        d = day_fields("Romans 8:1-4")
        d.pop(key)
        return raises(nt.NoteValidationError, nt.validate_fields, d, tpl)

    for k in ("check_in", "scripture", "summary", "discussion", "application", "theme"):
        check(f"missing {k} rejected", drop(k))
    check("wrong __action rejected", rej(__action="other"))
    check("non-object rejected", raises(nt.NoteValidationError, nt.validate_fields, "text", tpl))
    check("empty section rejected", rej(summary="   "))
    check("non-string section rejected", rej(summary=42))
    check("scripture as bare string rejected", rej(scripture="Romans 8:1-4"))
    check("scripture without reference rejected", rej(scripture={"text": "x"}))
    check("scripture with translation label rejected", rej(scripture={"reference": "Romans 8:1-4 (ESV)", "text": "x"}))
    check("reference ending before start rejected", rej(scripture={"reference": "Romans 8:9-4", "text": "x"}))
    check("over-length section rejected (beyond 1.5x)", rej(summary="word " * 200))
    check("generic check-in rejected", rej(check_in="Check in with group for past applications?"))
    check("check-in with no question rejected", rej(check_in="Tell us how it went."))
    check("wrong planned passage rejected",
          raises(nt.NoteValidationError, nt.validate_fields, day_fields("Romans 8:1-4"), tpl,
                 {"passage": "Romans 8:5-8", "instruction": "x", "lengths": {}}))
    check("matching planned passage accepted",
          nt.validate_fields(day_fields("Romans 8:1-4"), tpl,
                             {"passage": "Romans 8:1-4", "instruction": "x", "lengths": {}})["verses"]
          == [["Romans", 8, v] for v in (1, 2, 3, 4)])
    check("planned theme overrides the model's theme",
          nt.validate_fields(day_fields("Romans 8:1-4", theme="Whatever"), tpl,
                             {"theme": "Grace", "instruction": "x", "lengths": {}})["theme"] == "Grace")
    check("per-day plan length tightens the limit",
          raises(nt.NoteValidationError, nt.validate_fields, day_fields("Romans 8:1-4", summary="word " * 20), tpl,
                 {"lengths": {"summary": 5}, "instruction": "x"}))
    check("list section: empty list rejected",
          raises(nt.NoteValidationError, nt.validate_fields,
                 {"__action": "create_note", "title": "T", "theme": "x", "opener": "hi", "quote": "q", "steps": []},
                 nt.validate_template(OTHER)))
    check("list section: non-list rejected",
          raises(nt.NoteValidationError, nt.validate_fields,
                 {"__action": "create_note", "title": "T", "theme": "x", "opener": "hi", "quote": "q", "steps": "a"},
                 nt.validate_template(OTHER)))
    check("free-title mode with missing title rejected",
          raises(nt.NoteValidationError, nt.validate_fields,
                 {"__action": "create_note", "theme": "x", "opener": "hi", "quote": "q", "steps": ["a"]},
                 nt.validate_template(OTHER)))
    check("unknown extra keys from the model are ignored, not rendered",
          "INJECTED" not in render(FIVE, day_fields("Romans 8:1-4", evil="INJECTED")))
    check("verses on cross-chapter ref use endpoints only (no fabricated middle)",
          nt.verses_from_reference("Psalm 1:5-2:3") == [["Psalm", 1, 5], ["Psalm", 2, 3]])
    check("canonical reference collapses whitespace",
          nt.canonical_reference("1  Thessalonians  5:12 - 15") == "1 Thessalonians 5:12-15")

    print("\n=== 6. Plain-text output has no markup ===")
    hostile = day_fields(
        "Romans 8:1-4", theme="<script>x</script>Grace",
        check_in="**Bold?** <img src=x onerror=alert(1)> ok?",
        summary="# H1\n## H2\n- a\n* b\n1. c\n> q\n`code` __u__ ~~s~~ &lt;b&gt; <a href='x'>link</a>",
        discussion="<br/>Why&nbsp;now?",
        application="<div>Do <i>it</i></div>",
        scripture={"reference": "Romans 8:1-4", "text": "<b>No condemnation</b> &amp; life"},
    )
    out = render(FIVE, hostile)
    check("no angle brackets", "<" not in out and ">" not in out, out)
    check("no html entities", not re.search(r"&#?\w+;", out), out)
    check("no markdown emphasis/code/strike", not any(m in out for m in ("**", "__", "`", "~~")), out)
    check("no markdown line starters (#, >, -, *, 1.)",
          not re.search(r"(?m)^\s*(#{1,6}\s|>\s?|[-*+]\s|\d+[.)]\s)", out), out)
    check("no straight double quotes (one quote style)", '"' not in out, out)
    t = nt.validate_fields(hostile, tpl)["title"]
    check("title also markup-free", "<" not in t and "*" not in t and "#" not in t, t)

    print("\n=== 7. Quote normalisation ===")
    q = render(FIVE, day_fields("Romans 8:1-4", scripture={"reference": "Romans 8:1-4",
                                                          "text": '"He said, “hello” to me"'}))
    check("wrapping quotes stripped then a single curly pair; inner doubles become single",
          "“He said, ‘hello’ to me”" in q, q)
    check("apostrophe typographic", "’" in render(FIVE, day_fields("Romans 8:1-4", summary="God's love")))

    print("\n=== 8. Timeline day contract ===")
    entry = nt.build_day_entry({"instruction": "Cover peace", "theme": "Peace", "passage": "1  Thessalonians 5:12-15"},
                               tpl, nt.CHECK_IN_FOLLOW_UP)
    check("structured entry carries passage (canonical), theme, check_in_rule, lengths",
          entry["passage"] == "1 Thessalonians 5:12-15" and entry["theme"] == "Peace"
          and entry["check_in_rule"] == nt.CHECK_IN_FOLLOW_UP and entry["lengths"]["summary"] == 120, str(entry))
    check("entry without a passage rejected when template has a scripture section",
          raises(nt.NoteValidationError, nt.build_day_entry, {"instruction": "x", "theme": "t"}, tpl, None))
    check("plain-string entry rejected for structured template",
          raises(nt.NoteValidationError, nt.build_day_entry, "just text", tpl, None))
    check("entry missing theme rejected",
          raises(nt.NoteValidationError, nt.build_day_entry, {"instruction": "x", "passage": "Romans 8:1-4"}, tpl, None))
    other_t = nt.validate_template(OTHER)
    oe = nt.build_day_entry({"instruction": "Do X", "theme": "T", "passage": "garbage"}, other_t, nt.CHECK_IN_FOLLOW_UP)
    check("no passage/check_in_rule when template has no such section", "passage" not in oe and "check_in_rule" not in oe, str(oe))
    check("freeform keeps plain string day entries", nt.build_day_entry("  do a thing ", ff, None) == "do a thing")
    check("freeform entry empty rejected", raises(nt.NoteValidationError, nt.build_day_entry, "  ", ff, None))
    check("wants_contract only for structured", nt.wants_contract(tpl) and not nt.wants_contract(ff) and not nt.wants_contract(None))

    legacy = nt.normalize_day("Read Romans 8", tpl)
    check("legacy plain-string day still decodes", legacy and legacy["instruction"] == "Read Romans 8"
          and legacy["passage"] is None and legacy["lengths"] == {})
    check("empty/None/garbage day -> None", nt.normalize_day("", tpl) is None and nt.normalize_day(None, tpl) is None
          and nt.normalize_day(42, tpl) is None)
    nd = nt.normalize_day({"instruction": "x", "passage": "bad ref", "lengths": {"summary": 30, "bad": "z"}}, tpl)
    check("stored dict with stale parts tolerated (bad passage dropped, bad lengths dropped)",
          nd["passage"] is None and nd["lengths"] == {"summary": 30})
    check("legacy day with a structured template still produces a prompt and validates fields",
          nt.validate_fields(day_fields("Romans 8:1-4"), tpl, legacy)["title"].endswith("Romans 8:1-4"))

    print("\n=== 9. Check-in rule ===")
    check("follow-up only with a real prior application",
          nt.effective_check_in_rule(None, "Be patient.") == nt.CHECK_IN_FOLLOW_UP
          and nt.effective_check_in_rule(None, None) == nt.CHECK_IN_THEME
          and nt.effective_check_in_rule(None, "   ") == nt.CHECK_IN_THEME)
    p_follow = nt.build_note_prompt("Daily devotion", tpl, None, "Be patient with your kids.")
    p_first = nt.build_note_prompt("Daily devotion", tpl, None, None)
    check("prompt cites the prior application when present", "Be patient with your kids." in p_follow and "previous note" in p_follow)
    check("prompt has no 'previous note' claim when none exists",
          "Be patient" not in p_first and "Do not refer to any earlier note" in p_first)
    p_other = nt.build_note_prompt("Daily", other_t, None, "Something")
    check("template without check-in section gets no check-in rule", "CHECK-IN RULE" not in p_other)
    check("model told not to format (no headings) and given only template keys",
          "do not add numbering, headings or markup" in p_follow and '"summary"' in p_follow and '"opener"' not in p_follow)
    check("application_text returns the application section; None when absent",
          nt.application_text(tpl, nt.validate_fields(day_fields("Romans 8:1-4"), tpl)) == "Offer one act of patience today."
          and nt.application_text(other_t, fields_o) is None)
    check("note_data shape", set(nt.note_data(tpl, nt.validate_fields(day_fields("Romans 8:1-4"), tpl)))
          == {"title", "text", "theme", "verses"})

    print("\n=== 10. Golden: Oct 15/16/17 style notes ===")
    golden = render(FIVE, day_fields("1 Thessalonians 5:12-15"))
    expected = (
        "Check-in\nHow did you do with yesterday’s kindness challenge?\n\n"
        "Scripture\n1 Thessalonians 5:12-15\n“Be at peace among yourselves.”\n\n"
        "Scripture summary\nPaul urges the church to live in peace.\n\n"
        "Discussion prompt: Where is peace hardest for you?\n\n"
        "Application prompt: Offer one act of patience today."
    )
    check("golden five-section rendering exact", golden == expected, repr(golden))

    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        for label, detail in FAILED:
            print(f"  FAILED: {label}: {detail}")
        sys.exit(1)


if __name__ == "__main__":
    main()
