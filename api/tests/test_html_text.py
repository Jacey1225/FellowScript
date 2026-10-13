"""Tests for task 20261013-shared-note-preview-html-leak: html_text helper (no database).

Run with: cd api && ../.venv/bin/python tests/test_html_text.py
"""
import _pathfix  # noqa: F401

from backend.interactions.html_text import clean_shared_note_meta, html_to_text
from backend.interactions.shared_objects import _clip

failures = []


def check(name, got, want):
    if got != want:
        failures.append(name)
        print(f"FAIL {name}: got {got!r}, want {want!r}")
    else:
        print(f"ok   {name}")


check("bold", html_to_text("<b>Matthew 28:19 — Go and make disciples</b>"), "Matthew 28:19 — Go and make disciples")
check("entities", html_to_text("Tom &amp; Jerry&nbsp;&#39;s"), "Tom & Jerry 's")
check("blocks", html_to_text("<p>a</p><div>b</div>c<br>d<li>e</li><h1>f</h1>"), "a b c d e f")
check("script_style", html_to_text("x<script>alert(1)</script><style>p{}</style>y"), "xy")
check("img_onerror", html_to_text("hi<img src=x onerror=alert(1)>there"), "hithere")
check("unclosed", html_to_text("<b>one <i>two"), "one two")
check("partial_tag", html_to_text("keep <spa"), "keep")
check("plain", html_to_text("  plain   text "), "plain text")
check("none", html_to_text(None), "")
check("empty_after_strip", html_to_text("<p></p><br>"), "")
# strip BEFORE clip: a cut can never leave half a tag
check("clip_after_strip", _clip(html_to_text("<b>" + "word " * 50 + "</b>"), 20).count("<"), 0)
check("clip_len", len(_clip(html_to_text("<b>" + "word " * 50 + "</b>"), 20)) <= 20, True)

stale = {"note_id": "n", "title": "T", "preview": "<b>Matthew 28:19 &amp; more…"}
cleaned = clean_shared_note_meta("shared_note", stale)
check("stale_preview", cleaned["preview"], "Matthew 28:19 & more…")
check("stale_original_untouched", stale["preview"], "<b>Matthew 28:19 &amp; more…")
clean = {"preview": "plain"}
check("clean_same_object", clean_shared_note_meta("shared_note", clean) is clean, True)
check("other_kind_untouched", clean_shared_note_meta("shared_verse", {"preview": "<b>x"}), {"preview": "<b>x"})
check("non_dict", clean_shared_note_meta("shared_note", None), None)

if failures:
    raise SystemExit(f"{len(failures)} failed: {failures}")
print("all passed")
