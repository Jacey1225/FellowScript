"""End-to-end (scratch DB) regression for task 20261031-thread-verse-send-fail.

Genesis 1:15 starts lowercase in the World English Bible; `verse_text` used to return None for it, so
`build_verse` raised ShareRejected and the whole send came back as the generic not_allowed frame.
Proves, against real tables, that a lowercase-start verse is accepted and stored by BOTH
`thread_send.send_thread_message` (thread) and `ConnectionManager.send_msg` (group chat), with
server-built meta/text, an ack, a live frame and no error frame; and that John 3:16 still works.
Scratch database only (asserts SHOW port = 55432 first).
Run with: cd api && python tests/test_verse_share_lowercase_e2e.py
"""
import _pathfix  # noqa: F401
from _thr_common import (  # noqa: F401
    FakeWS, check, finish, make_group, make_msg, make_thread, make_user, require_scratch_db, set_flag, sql,
)

import asyncio
from datetime import datetime, timezone

from backend.interactions import shared_objects as so
from backend.interactions import thread_send
from backend.interactions.thread_send import send_thread_message
from backend.interactions.websockets import ConnectionManager

VERSES = [("Genesis", 1, 15), ("Genesis", 1, 18), ("Genesis", 2, 6), ("John", 3, 16)]


def main():
    require_scratch_db()
    alice, bob = make_user("vl"), make_user("vl")
    gid = make_group([alice, bob], creator=alice)
    set_flag("threads", "on", alice)
    set_flag(so.FLAG, "on", alice)
    root = make_msg(alice, gid, "root")
    tid = make_thread(gid, root, alice, title="vl")
    mgr = ConnectionManager()
    ws = {alice: FakeWS(), bob: FakeWS()}
    mgr.active_connections.update(ws)

    async def fake_push(*a, **k):
        return True

    orig = thread_send.send_push
    thread_send.send_push = fake_push
    try:
        for book, ch, v in VERSES:
            ref = f"{book} {ch}:{v}"
            meta = {"book": book, "chapter": ch, "verse": v}
            print(f"thread + chat share of {ref}")
            for w in ws.values():
                w.sent.clear()
            asyncio.run(send_thread_message(mgr, {
                "from_user": alice, "type": "thread_message", "thread_id": tid,
                "text": "client fallback FORGED", "attachment_kind": "shared_verse",
                "attachment_meta": dict(meta), "client_ref": f"r-{ch}-{v}"}))
            rows = sql("SELECT text, attachment_meta FROM thread_messages WHERE thread_id=%s AND "
                       "attachment_kind='shared_verse' AND attachment_meta->>'reference'=%s", (tid, ref))
            check(f"{ref}: thread share stored", len(rows) == 1, rows)
            if rows:
                text, m = rows[0]
                check(f"{ref}: thread meta/text server built", m.get("reference") == ref
                      and "FORGED" not in text and text.endswith(f"— {ref}") and len(text) > len(ref) + 6, (text, m))
            check(f"{ref}: thread sender acked, no error frame",
                  any(f.get("type") == "ack" for f in ws[alice].sent)
                  and not [f for f in ws[alice].sent if f.get("type") == "error"], ws[alice].sent)
            check(f"{ref}: member got live thread frame",
                  any(f.get("type") == "thread_message" and f.get("attachment_kind") == "shared_verse"
                      for f in ws[bob].sent), ws[bob].sent)

            for w in ws.values():
                w.sent.clear()
            asyncio.run(mgr.send_msg({
                "from_user": alice, "to_users": [alice], "group_id": gid, "text": "client fallback FORGED",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "attachment_kind": "shared_verse", "attachment_meta": dict(meta)}))
            mrows = sql("SELECT text, attachment_meta FROM messages WHERE group_id=%s AND "
                        "attachment_kind='shared_verse' AND attachment_meta->>'reference'=%s", (gid, ref))
            check(f"{ref}: group chat share stored", len(mrows) == 1, mrows)
            if mrows:
                check(f"{ref}: chat text server built",
                      "FORGED" not in mrows[0][0] and mrows[0][0].endswith(f"— {ref}"), mrows[0])
            check(f"{ref}: chat sender gets no error frame",
                  not [f for f in ws[alice].sent if f.get("type") == "error"], ws[alice].sent)
    finally:
        thread_send.send_push = orig
        mgr.close()
        try:
            sql("DELETE FROM thread_messages WHERE thread_id=%s", (tid,))
            sql("DELETE FROM messages WHERE group_id=%s", (gid,))
        except Exception as e:  # noqa: BLE001
            print("cleanup issue:", type(e).__name__)
        finish(("threads", so.FLAG))


if __name__ == "__main__":
    main()
