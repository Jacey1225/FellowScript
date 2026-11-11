"""Regression tests for task 20261031-thread-verse-send-fail (no database needed).

Bug: sending a Bible verse into a chat/thread failed ("Couldn't send") for ~10% of verses because
`bible_text._VERSE_SPLIT_RE` only split on a verse number followed by an UPPERCASE letter, but the World
English Bible has many verses that open lowercase (Genesis 1:15 ...). `verse_text()` returned None, so
`build_verse` raised ShareRejected("verse_text_unavailable") -> uniform not_allowed frame. Also, the main
chat content filter ran on the client's fallback text before the share was rebuilt server-side.

Proves:
  1. Corpus: the server parser recognises exactly the verses the client regex does; none resolve to None;
     no verse text contains a neighbour's number-prefixed text (digit-run bleed).
  2. Genesis 1:14 / 1:15 / 1:18 / 2:6 resolve with their own text; build_verse and the thread resolver
     (resolve_thread_share) accept them; verses that parsed before are byte-identical (frozen sample).
  3. Main chat `send_msg`: a lowercase-start verse reaches save_message with server-built text; a verse
     whose client fallback text the content filter rejects no longer fails; plain text is still filtered;
     a note share's server-built text is still filtered.
Run with: cd api && DB_PASSWORD=x python tests/test_verse_share_lowercase.py
"""
import _pathfix  # noqa: F401

import asyncio
import os
import re
import sys

os.environ.setdefault("DB_PASSWORD", "x")

from backend.errors import SaveFailedError  # noqa: E402
from backend.interactions import bible_text, flags  # noqa: E402
from backend.interactions import shared_objects as so  # noqa: E402
from backend.interactions import thread_shared_objects  # noqa: E402
from backend.interactions import websockets as wsmod  # noqa: E402
from backend.interactions.send_guard import SendDecision  # noqa: E402
from backend.moderation.content_filter import ContentRejected, check_clean  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


CLIENT_RE = re.compile(r"(?<!\d)(\d+)(?=[A-Za-z“‘(\[])")  # iOS / web verse-boundary regex
FIRST_RE = re.compile(r"^(\d+):1\s*(.*)", re.S)


def test_corpus():
    books = bible_text._load_raw()
    total = none_count = mismatched = bleed = 0
    for book, chapters in books.items():
        for ch in range(1, len(chapters)):
            m = FIRST_RE.match(chapters[ch])
            expected = {1} | {int(n) for n in CLIENT_RE.findall(m.group(2))}
            for v in expected:
                total += 1
                t = bible_text.verse_text(book, ch, v)
                if t is None:
                    none_count += 1
                elif CLIENT_RE.search(t):
                    bleed += 1
            if set(bible_text._parse_chapter(chapters[ch])) != expected:
                mismatched += 1
    check("corpus: client regex recognises the full verse set", total > 31000, total)
    check("corpus: verse_text resolves every client-recognised verse (0 None)", none_count == 0, none_count)
    check("corpus: server verse set == client verse set for every chapter", mismatched == 0, mismatched)
    check("corpus: no verse text contains a neighbour's number-prefixed text", bleed == 0, bleed)
    bible_text.validate_bible_data()
    check("validate_bible_data still passes", True)


def test_specific_verses():
    g14 = bible_text.verse_text("Genesis", 1, 14)
    g15 = bible_text.verse_text("Genesis", 1, 15)
    check("Genesis 1:15 resolves, opens lowercase", bool(g15) and g15.startswith("and let them be for lights"), g15)
    check("Genesis 1:14 no longer swallows verse 15", g14 is not None and "for lights" not in g14, g14)
    for ref in [("Genesis", 1, 18), ("Genesis", 2, 6), ("Genesis", 2, 12), ("Genesis", 2, 17)]:
        check(f"{ref} resolves", bool(bible_text.verse_text(*ref)))
    # Verses that already parsed before the fix must be unchanged (frozen from the pre-fix parser).
    check("John 3:16 unchanged", bible_text.verse_text("John", 3, 16) ==
          "For God so loved the world, that he gave his one and only Son, that whoever believes in him should not perish, but have eternal life.",
          bible_text.verse_text("John", 3, 16))
    check("Genesis 1:1 unchanged", bible_text.verse_text("Genesis", 1, 1) ==
          "In the beginning, God created the heavens and the earth.", bible_text.verse_text("Genesis", 1, 1))


def test_build_verse_and_thread_resolver():
    meta, text = so.build_verse({"book": "Genesis", "chapter": 1, "verse": 15})
    check("build_verse Genesis 1:15 succeeds", meta["reference"] == "Genesis 1:15" and "for lights" in text, text)
    meta, _ = so.build_verse({"book": "Genesis", "chapter": 1, "verse": 14, "verse_end": 15})
    check("build_verse range 1:14-15 succeeds", meta["verse_end"] == 15)

    orig = flags.is_enabled
    flags.is_enabled = lambda *_a, **_k: True
    try:
        # sample of previously failing verses through the thread-send share resolver
        sample = [("Genesis", 1, 15), ("Genesis", 1, 18), ("Genesis", 2, 6), ("Exodus", 2, 23), ("Psalms", 23, 2)]
        ok = True
        for b, c, v in sample:
            try:
                m, t = thread_shared_objects.resolve_thread_share(None, "u", so.KIND_VERSE,
                                                                  {"book": b, "chapter": c, "verse": v})
                ok = ok and bool(m["text"]) and t.endswith(f"{b} {c}:{v}")
            except so.ShareRejected as e:
                ok = False
                print("   rejected", b, c, v, e)
        check("thread resolver accepts sampled lowercase-start verses", ok)
    finally:
        flags.is_enabled = orig


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, p):
        self.sent.append(p)


class Captured(Exception):
    pass


def run_send(payload, note_text=None):
    """Drive ConnectionManager.send_msg with the DB layer stubbed; stop at save_message."""
    mgr = wsmod.ConnectionManager.__new__(wsmod.ConnectionManager)
    UID = payload["from_user"]
    mgr.active_connections = {UID: FakeWS()}
    mgr._execute = lambda *a, **k: None

    class Cur:
        def fetchall(self):
            return []

    mgr.cur = Cur()
    saved = {}

    def fake_save(message, **_k):
        saved["m"] = message
        raise SaveFailedError("stop")

    mgr.save_message = fake_save
    if note_text is not None:
        so.build_note = lambda *_a, **_k: ({"note_id": "n"}, note_text)
    orig = (wsmod.authorize_send, flags.is_enabled)
    wsmod.authorize_send = lambda *_a, **_k: SendDecision("group", "g1", ["u1", "u2"])
    flags.is_enabled = lambda *_a, **_k: True
    try:
        asyncio.run(mgr.send_msg(payload))
    finally:
        wsmod.authorize_send, flags.is_enabled = orig
    return saved.get("m"), mgr.active_connections[UID].sent


def base(**kw):
    return {"from_user": "11111111-1111-1111-1111-111111111111", "to_users": ["u1"], "group_id": "g1",
            "timestamp": "2026-10-31T00:00:00Z", **kw}


def test_main_chat():
    uid = "11111111-1111-1111-1111-111111111111"
    saved, frames = run_send(base(from_user=uid, text="x", attachment_kind=so.KIND_VERSE,
                                  attachment_meta={"book": "Genesis", "chapter": 1, "verse": 15}))
    check("main chat: lowercase-start verse reaches save with server-built text",
          saved is not None and saved.text.startswith("“and let them be for lights"), saved)
    check("main chat: stored meta is server-built", saved is not None and saved.attachment_meta.get("translation") == "WEB")

    # Client fallback text the filter would reject, but a clean server-built verse: must not be rejected.
    bad = None
    for cand in ["fuck", "shit", "nigger", "fucking"]:
        try:
            check_clean(text=cand)
        except ContentRejected:
            bad = cand
            break
    check("filter rejects a known-bad string (test precondition)", bad is not None)
    saved, frames = run_send(base(text=bad, attachment_kind=so.KIND_VERSE,
                                  attachment_meta={"book": "John", "chapter": 3, "verse": 16}))
    check("main chat: client fallback text is not filtered for a verse share",
          saved is not None and not any(f.get("reason") == "message_rejected" for f in frames), frames)

    saved, frames = run_send(base(text=bad))
    check("main chat: plain text is still filtered",
          saved is None and any(f.get("reason") == "message_rejected" for f in frames), frames)

    orig_note = so.build_note
    try:
        saved, frames = run_send(base(text="fine", attachment_kind=so.KIND_NOTE, attachment_meta={"note_id": "n"}),
                                 note_text=f"Shared a note: {bad}")
        check("main chat: note share's server-built text is still filtered",
              saved is None and any(f.get("reason") == "message_rejected" for f in frames), frames)
        saved, frames = run_send(base(text="fine", attachment_kind=so.KIND_NOTE, attachment_meta={"note_id": "n"}),
                                 note_text="Shared a note: Groceries")
        check("main chat: clean note share still saves", saved is not None, frames)
    finally:
        so.build_note = orig_note


def main():
    test_corpus()
    test_specific_verses()
    test_build_verse_and_thread_resolver()
    test_main_chat()
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    for f in FAILED:
        print("  X", f)
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
