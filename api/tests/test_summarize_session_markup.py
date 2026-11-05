"""Route-level coverage for task 20261104-ai-note-format-normalizer:
POST /agent/{user_id}/{agent_id}/summarize must store editor-renderable markup,
never raw LLM markdown. Reuses the harness helpers of
test_summarize_session_content_fixes.py. Run: python tests/test_summarize_session_markup.py
"""
import _pathfix  # noqa: F401

import json
import re
import uuid

import test_summarize_session_content_fixes as H
from test_summarize_session_content_fixes import (
    TestClient, agent_module, check, cleanup, cookie_header, latest_note_text, main_module,
    make_agent, note_count, signup, summarize,
)

MD = ("# Sunday Service\n\n**Key insight:** grace is *free*.\n\n1. Pray\n2. Read __daily__\n"
      "- share it\n\n<script>alert(1)</script><h2>Next</h2><a href=\"javascript:x\">go</a>")


def test_markdown_response_is_normalized(client):
    print("\n=== 1. Markdown/unsupported-HTML LLM output is stored as editor markup ===")
    uid, token = signup(client, f"mkup_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        seen = {}

        def fake(self, role, msgs):
            seen["msgs"] = json.dumps(msgs)
            return MD
        agent_module.AgentManager._call_api = fake
        r = summarize(client, token, uid, agent_id, {"title": "Sunday Service", "prompts": ["p"], "verses": ["John 3:16"]})
        check("201", r.status_code == 201, f"{r.status_code} {r.text}")
        t = latest_note_text(uid) or ""
        print("   stored:", repr(t))
        check("no ** / # / __ markers", not re.search(r"\*|#|__", t), t)
        check("no script/h2/a/newline", not re.search(r"<(script|h\d|a)\b|alert|\n", t), t)
        check("only allowed tags", set(re.findall(r"</?([a-z0-9]+)", t)) <= {"b", "em", "u", "mark", "br"}, t)
        check("bold+italic rendered", "Key insight:</b>" in t and "<em>free</em>" in t, t)
        check("list markers kept as text lines", "1. Pray<br>2. Read" in t and "• share it" in t, t)
        check("prompt states allowed tags / forbids markdown",
              "<b>bold</b>" in seen["msgs"] and "Do NOT use markdown" in seen["msgs"])
    finally:
        cleanup(uid)


def test_salvaged_json_text_is_normalized(client):
    print("\n=== 2. Salvaged create_note text is normalized too ===")
    uid, token = signup(client, f"mkjson_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        leaked = json.dumps({"__action": "create_note", "title": "x", "text": "**Hi** there", "public": False,
                             "group_id": "", "theme": "n/a", "verses": []})
        agent_module.AgentManager._call_api = lambda self, role, msgs: leaked
        r = summarize(client, token, uid, agent_id, {"title": "t", "prompts": ["p"], "verses": []})
        check("201", r.status_code == 201, f"{r.status_code} {r.text}")
        check("normalized", latest_note_text(uid) == "<b>Hi</b> there", str(latest_note_text(uid)))
    finally:
        cleanup(uid)


def test_nothing_renderable_fails_loudly(client):
    print("\n=== 3. Output with nothing renderable -> 502, no note ===")
    uid, token = signup(client, f"mkempty_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        for bad in ["<script>alert(1)</script>", "---", "```\n```"]:
            agent_module.AgentManager._call_api = lambda self, role, msgs, b=bad: b
            before = note_count(uid)
            r = summarize(client, token, uid, agent_id, {"title": "t", "prompts": ["p"], "verses": []})
            check(f"502 for {bad!r}", r.status_code == 502, f"{r.status_code} {r.text}")
            check(f"no note for {bad!r}", note_count(uid) == before)
            check(f"no content echoed for {bad!r}", "alert" not in r.text)
    finally:
        cleanup(uid)


def test_idempotent_on_clean_html(client):
    print("\n=== 4. Already-clean editor HTML is stored unchanged ===")
    uid, token = signup(client, f"mkclean_{uuid.uuid4().hex[:8]}")
    try:
        agent_id = make_agent(uid)
        clean = "<b>Title</b><br><br>1. one<br>2. two<br>plain &amp; <em>x</em>"
        agent_module.AgentManager._call_api = lambda self, role, msgs: clean
        r = summarize(client, token, uid, agent_id, {"title": "t", "prompts": ["p"], "verses": []})
        check("201", r.status_code == 201)
        check("unchanged", latest_note_text(uid) == clean, str(latest_note_text(uid)))
    finally:
        cleanup(uid)


def main():
    orig = agent_module.AgentManager._call_api
    try:
        with TestClient(main_module.app) as client:
            test_markdown_response_is_normalized(client)
            test_salvaged_json_text_is_normalized(client)
            test_nothing_renderable_fails_loudly(client)
            test_idempotent_on_clean_html(client)
    finally:
        agent_module.AgentManager._call_api = orig
    P, F = H.PASSED, H.FAILED
    print(f"\nRESULT: {len(P)} passed, {len(F)} failed")
    if F:
        for l, d in F:
            print("  X", l, "--", d)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
