"""Plain-script tests for backend/interactions/note_markup.normalize_note_markup
(task 20261104-ai-note-format-normalizer). Run: python tests/test_note_markup.py
Pure function, no DB."""
import _pathfix  # noqa: F401

import re
import sys

from backend.interactions.note_markup import NoteMarkupError, normalize_note_markup as n

ALLOWED = {"b", "em", "u", "mark", "br"}
_fail = []


def check(name, cond, detail=""):
    if not cond:
        _fail.append(name)
        print(f"FAIL {name} {detail}")
    else:
        print(f"ok   {name}")


def tags(out):
    return set(re.findall(r"</?([a-zA-Z0-9]+)", out))


def only_allowed(out):
    return tags(out) <= ALLOWED and not re.search(r"<[a-z]+\s+[^>]", out)


def balanced(out):
    st = []
    for m in re.finditer(r"<(/?)(b|em|u|mark)>", out):
        if m.group(1):
            if not st or st.pop() != m.group(2):
                return False
        else:
            st.append(m.group(2))
    return not st


def main():
    # Markdown conversion
    check("bold", n("**Bold** x") == "<b>Bold</b> x")
    check("bold_under", n("__x__ y") == "<b>x</b> y")
    check("italic_star", n("a *it* b") == "a <em>it</em> b")
    check("italic_under", n("a _it_ b") == "a <em>it</em> b")
    o = n("***both***")
    check("bold_italic", "*" not in o and "<b>" in o and "<em>" in o, o)
    o = n("# Title\n\n## Sub\ntext")
    # adjacent bold runs may be merged into one <b> spanning the <br>s; renders identically
    check("headings", "#" not in o and balanced(o) and re.sub(r"</?b>", "", o) == "Title<br><br>Sub<br>text"
          and o.startswith("<b>Title") and "Sub</b><br>text" in o, o)
    o = n("1. one\n2. two")
    check("ordered_list", o == "1. one<br>2. two", o)
    o = n("- a\n* b\n+ c")
    check("bullets", o == "• a<br>• b<br>• c", o)
    o = n("```py\nx = **1**\n```\nafter")
    check("fence", "`" not in o and "*" not in o and "after" in o, o)
    o = n("see [site](http://x.com) and `code`")
    check("link_code", "[" not in o and "`" not in o and "x.com" in o and "site" in o, o)
    check("hr", "-" not in n("a\n---\nb") and "b" in n("a\n---\nb"))
    # legit asterisks/underscores preserved
    check("snake_case", n("use snake_case_name") == "use snake_case_name")
    check("math_star", n("2 * 3 = 6") == "2 * 3 = 6")
    # HTML handling
    o = n("<script>alert(1)</script>hi")
    check("script_dropped", o == "hi", o)
    o = n("<style>b{}</style>hi")
    check("style_dropped", o == "hi", o)
    o = n("<h1>T</h1><ul><li>a</li><li>b</li></ul>")
    check("h1_ul", only_allowed(o) and "T" in o and "• a" in o, o)
    o = n("<table><tr><td>x</td></tr></table>")
    check("table", o == "x", o)
    o = n('<b onclick="evil()" style="x:y">y</b><img src=x onerror=alert(1)>')
    check("attrs_stripped", o == "<b>y</b>", o)
    o = n('<a href="javascript:alert(1)">click</a>')
    check("js_link", o == "click", o)
    o = n('<span style="color:red">r</span><font color="red">f</font>')
    check("span_font", o == "rf", o)
    o = n("<strong>s</strong><i>i</i><u>u</u><mark>m</mark>")
    check("aliases", o == "<b>s</b><em>i</em><u>u</u><mark>m</mark>", o)
    o = n("<b>unclosed <i>x")
    check("unclosed_balanced", balanced(o) and only_allowed(o), o)
    o = n("</b></i>stray <b>ok</b>")
    check("stray_close", balanced(o) and "ok" in o, o)
    o = n("<p>a</p><p>b</p>")
    check("paragraphs_br", o == "a<br><br>b", o)
    check("newline_to_br", n("a\nb") == "a<br>b" and "\n" not in n("a\nb\n\nc"))
    check("br_capped", n("a\n\n\n\n\nb") == "a<br><br>b")
    o = n("1 < 2 & 3 > 2 <b>x</b>")
    check("escaping", "&amp;" in o and "&lt;" in o and only_allowed(o), o)
    o = n("&lt;script&gt;alert(1)&lt;/script&gt;")
    check("entity_not_reactivated", "<script" not in o and "&lt;script" in o, o)
    # sentinel spoofing
    o = n("abc")
    check("sentinel_spoof", only_allowed(o) and re.search("[-]", o) is None, repr(o))
    # idempotence, incl. clean editor html
    for s in ["**Bold** *it* __u__\n# H\n1. a\n- b\n\ntext", "<b>x</b> <em>y</em><br>z", "plain",
              "<p>a</p><ul><li>x</li></ul>", "<b>unclosed <i>x", "2 * 3 and snake_case",
              "a &amp; b", "<mark>m</mark><u>u</u><br><br>end"]:
        a = n(s)
        check(f"idempotent[{s[:20]!r}]", n(a) == a, f"{a!r} -> {n(a)!r}")
        check(f"allowed[{s[:20]!r}]", only_allowed(a) and balanced(a), a)
    # throw-not-fabricate
    for bad in ["", "   \n ", "<script>x</script>", "<div></div>", "---", "```\n```"]:
        try:
            r = n(bad)
            check(f"raises[{bad!r}]", False, f"returned {r!r}")
        except NoteMarkupError:
            check(f"raises[{bad!r}]", True)
    for bad in [None, 5, b"x", ["a"]]:
        try:
            n(bad)
            check(f"raises_nonstr[{bad!r}]", False)
        except NoteMarkupError:
            check(f"raises_nonstr[{bad!r}]", True)

    if _fail:
        print(f"\n{len(_fail)} FAILED: {_fail}")
        sys.exit(1)
    print("\nall passed")


if __name__ == "__main__":
    main()
