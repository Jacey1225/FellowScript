"""Tests for task 20261030-thread-share-notes-verses, backend (flags ``threads`` + ``chat_shared_objects``).

Scratch database only (asserts SHOW port = 55432 first). Proves:
  1. Thread send: shared_verse / shared_note are accepted into a thread; stored attachment_meta and
     fallback text are SERVER built (forged title/preview/text/owner ignored); nothing is written to
     ``messages``; live frame body and push body use the fallback line; ack returned.
  2. Send denials all give the one uniform ``not_allowed`` frame and store nothing: forged/unowned
     note, another user's private note, reply note, bad note id, invalid verse reference, attachment_key
     on a shared kind, non-dict meta, non-member, suspended sender, unknown thread, ``threads`` flag
     off, ``chat_shared_objects`` flag off. Plain text and image attachment sends in threads still work.
  3. Thread history applies clean_shared_note_meta (markup in a stored preview/title is stripped on read,
     the stored row is untouched) and returns the shared kinds.
  4. Note read grant for thread messages (GET /shared-objects/{uid}/note/{thread_message_id}):
     current group member reads; every denial is the IDENTICAL 404: non-member, former member, sender
     left group, block pair (both directions), suspended viewer, soft-deleted thread message, verse
     message, plain message, note now private / deleted / turned into a reply, threads flag off,
     unknown and malformed ids. Grant is one note only. Chat grant unaffected.
  5. No note text in logs.
Run with: cd api && python tests/test_thread_shared_objects.py
"""
import _pathfix  # noqa: F401
from _thr_common import (  # noqa: F401
    FAILED, FakeWS, LogCapture, add_tmsg, check, cookie, finish, make_group, make_msg, make_thread,
    make_user, own_key, require_scratch_db, set_flag, sql, tcount,
)

import asyncio
import logging
import uuid
from datetime import datetime, timezone

from fastapi.testclient import TestClient

import main as main_module
from backend.interactions import shared_objects as so
from backend.interactions import thread_send
from backend.interactions.thread_send import send_thread_message
from backend.interactions.websockets import ConnectionManager
from backend.rate_limiting import limiter

NOT_FOUND = {"detail": {"code": "not_found", "message": "Not found"}}
NOTES: list = []
SECRET = "SECRET-NOTE-BODY-XYZZY"


def make_note(owner, title="My title", text="Body text", public=False, group_id=None, is_reply=False):
    nid = str(uuid.uuid4())
    sql("INSERT INTO notes (_id,user_id,title,text,public,group_id,is_reply,timestamp,created_at) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,NOW(),NOW())", (nid, owner, title, text, public, group_id, is_reply))
    NOTES.append(nid)
    return nid


def is_404(r):
    return r.status_code == 404 and r.json() == NOT_FOUND


class Env:
    def __init__(self, *uids):
        self.manager = ConnectionManager()
        self.ws = {u: FakeWS() for u in uids}
        for u, w in self.ws.items():
            self.manager.active_connections[u] = w
        self.pushed = []

        async def fake_push(token, title, body, data=None):
            self.pushed.append({"token": token, "title": title, "body": body, "data": data})
            return True

        self._orig = thread_send.send_push
        thread_send.send_push = fake_push

    def send(self, sender, **fields):
        asyncio.run(send_thread_message(self.manager, {"from_user": sender, "type": "thread_message", **fields}))

    def frames(self, uid, kind):
        return [f for f in self.ws[uid].sent if f.get("type") == kind]

    def clear(self):
        for w in self.ws.values():
            w.sent.clear()
        self.pushed.clear()

    def close(self):
        thread_send.send_push = self._orig
        self.manager.close()


def trows(tid):
    return sql("SELECT _id::text, text, attachment_kind, attachment_key, attachment_meta, from_user::text "
               "FROM thread_messages WHERE thread_id=%s ORDER BY created_at, seq", (tid,))


def main_count(gid):
    return sql("SELECT COUNT(*) FROM messages WHERE group_id=%s", (gid,))[0][0]


def view(cli, viewer, mid, path_uid=None):
    limiter.reset()
    return cli.get(f"/shared-objects/{path_uid or viewer}/note/{mid}", headers=cookie(viewer))


def main():
    require_scratch_db()
    cli = TestClient(main_module.app)
    saved = sql("SELECT state, canary_user_ids::text[] FROM feature_flags WHERE name=%s", (so.FLAG,))
    alice, bob, carol, dave, outsider, susp = (make_user("tso") for _ in range(6))
    gid = make_group([alice, bob, carol, dave, susp], creator=alice)
    gid_other = make_group([outsider, bob], creator=outsider)
    set_flag("threads", "on", alice)
    set_flag(so.FLAG, "on", alice)
    root = make_msg(alice, gid, "root")
    tid = make_thread(gid, root, alice, title="thr")
    root_o = make_msg(outsider, gid_other, "other root")
    tid_other = make_thread(gid_other, root_o, outsider, title="other")
    env = Env(alice, bob, carol, dave, outsider, susp)
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    limiter.reset()
    try:
        a_priv = make_note(alice, "Alice private", SECRET)
        a_grp_priv = make_note(alice, "Alice grp", "grp body", public=False, group_id=gid)
        a_grp_edit = make_note(alice, "Whole group", "editable", public=True, group_id=gid)
        b_priv = make_note(bob, "Bob private", "bob secret")
        reply = make_note(alice, "reply", "r", is_reply=True)

        print("verse share into a thread")
        before_main = main_count(gid)
        n = tcount(tid)
        env.send(alice, thread_id=tid, text="client text FORGED", attachment_kind="shared_verse",
                 attachment_meta={"book": "John", "chapter": 3, "verse": 16, "text": "FORGED", "reference": "FORGED"},
                 client_ref="r1")
        rows = trows(tid)
        check("verse stored in thread_messages", tcount(tid) == n + 1 and rows[-1][2] == "shared_verse", rows)
        r = rows[-1]
        check("verse: no object key, meta server built (WEB text), forged fields ignored",
              r[3] is None and r[4]["reference"] == "John 3:16" and r[4]["translation"] == "WEB"
              and "FORGED" not in str(r[4]), r[4])
        check("verse: fallback text is plain quote + reference, client text ignored",
              r[1].endswith("— John 3:16") and "FORGED" not in r[1], r[1])
        check("verse: nothing written to messages", main_count(gid) == before_main)
        check("verse: sender gets an ack and no error", len(env.frames(alice, "ack")) == 1 and not env.frames(alice, "error"), env.ws[alice].sent)
        fr = env.frames(bob, "thread_message")
        check("verse: member gets live frame with shared kind and fallback body",
              len(fr) == 1 and fr[0]["attachment_kind"] == "shared_verse" and fr[0]["body"] == r[1]
              and fr[0]["attachment_meta"]["reference"] == "John 3:16", env.ws[bob].sent)
        check("verse: outsider gets nothing", env.ws[outsider].sent == [])
        env.clear()

        print("note share into a thread")
        n = tcount(tid)
        env.send(alice, thread_id=tid, text="FORGED TEXT", attachment_kind="shared_note",
                 attachment_meta={"note_id": a_priv, "title": "FORGED TITLE", "preview": "FORGED", "owner_id": bob})
        rows = trows(tid)
        check("note stored", tcount(tid) == n + 1 and rows[-1][2] == "shared_note", rows)
        r = rows[-1]
        mid_note = r[0]
        check("note: meta rebuilt on server (forged title/preview/owner ignored)",
              r[4]["note_id"] == a_priv and r[4]["title"] == "Alice private" and r[4]["owner_id"] == alice
              and "FORGED" not in str(r[4]) and r[3] is None, r[4])
        check("note: fallback text", r[1] == "Shared a note: Alice private", r[1])
        fr = env.frames(bob, "thread_message")
        check("note: live frame carries fallback body", len(fr) == 1 and fr[0]["body"] == r[1], env.ws[bob].sent)
        env.clear()
        env.send(alice, thread_id=tid, text="", attachment_kind="shared_note", attachment_meta={"note_id": a_grp_priv})
        check("own group note accepted", trows(tid)[-1][4]["note_id"] == a_grp_priv)
        env.clear()
        env.send(bob, thread_id=tid, text="", attachment_kind="shared_note", attachment_meta={"note_id": a_grp_edit})
        check("public group note of a live member accepted", trows(tid)[-1][4]["note_id"] == a_grp_edit)
        env.clear()

        print("push uses fallback line")
        sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) ON CONFLICT DO NOTHING", (dave, "tok-" + uuid.uuid4().hex[:8]))
        sql("INSERT INTO thread_followers (thread_id, user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (tid, dave))
        del env.manager.active_connections[dave]
        env.send(alice, thread_id=tid, text="", attachment_kind="shared_verse",
                 attachment_meta={"book": "John", "chapter": 3, "verse": 16})
        check("offline follower pushed once", len(env.pushed) == 1, env.pushed)
        if env.pushed:
            p = env.pushed[0]
            check("push body is a readable line with no raw meta/key/note text",
                  isinstance(p["body"], str) and p["body"] and "attachment_meta" not in str(p) and SECRET not in str(p), p)
        env.manager.active_connections[dave] = env.ws[dave]
        env.clear()

        print("send denials (uniform not_allowed, nothing stored)")
        sql("UPDATE users SET suspended_at=NOW() WHERE _id=%s", (susp,))
        n = tcount(tid)
        k = own_key(alice)
        cases = [
            ("another user's private note", alice, dict(thread_id=tid, attachment_kind="shared_note", attachment_meta={"note_id": b_priv})),
            ("reply note", alice, dict(thread_id=tid, attachment_kind="shared_note", attachment_meta={"note_id": reply})),
            ("unknown note id", alice, dict(thread_id=tid, attachment_kind="shared_note", attachment_meta={"note_id": str(uuid.uuid4())})),
            ("malformed note id", alice, dict(thread_id=tid, attachment_kind="shared_note", attachment_meta={"note_id": "x'; --"})),
            ("missing note id", alice, dict(thread_id=tid, attachment_kind="shared_note", attachment_meta={})),
            ("non-dict meta", alice, dict(thread_id=tid, attachment_kind="shared_note", attachment_meta="oops")),
            ("list meta", alice, dict(thread_id=tid, attachment_kind="shared_verse", attachment_meta=[1])),
            ("unknown book", alice, dict(thread_id=tid, attachment_kind="shared_verse", attachment_meta={"book": "Hezekiah", "chapter": 1, "verse": 1})),
            ("chapter out of range", alice, dict(thread_id=tid, attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": 99, "verse": 1})),
            ("range over cap", alice, dict(thread_id=tid, attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": 3, "verse": 1, "verse_end": 30})),
            ("string chapter", alice, dict(thread_id=tid, attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": "3", "verse": 16})),
            ("attachment_key on a shared verse", alice, dict(thread_id=tid, attachment_kind="shared_verse", attachment_key=k, attachment_meta={"book": "John", "chapter": 3, "verse": 16})),
            ("attachment_key on a shared note", alice, dict(thread_id=tid, attachment_kind="shared_note", attachment_key=k, attachment_meta={"note_id": a_priv})),
            ("non-member of the thread's group", outsider, dict(thread_id=tid, attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": 3, "verse": 16})),
            ("non-member forging own group id", outsider, dict(thread_id=tid, group_id=gid_other, attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": 3, "verse": 16})),
            ("suspended sender", susp, dict(thread_id=tid, attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": 3, "verse": 16})),
            ("unknown thread", alice, dict(thread_id=str(uuid.uuid4()), attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": 3, "verse": 16})),
            ("malformed thread id", alice, dict(thread_id="nope", attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": 3, "verse": 16})),
        ]
        for name, sender, kw in cases:
            env.clear()
            env.send(sender, text="", **kw)
            errs = env.frames(sender, "error")
            check(f"denied: {name}", len(errs) == 1 and errs[0]["reason"] == "not_allowed" and set(errs[0]) == {"type", "reason", "detail"}
                  and tcount(tid) == n and tcount(tid_other) == 0 and all(not env.frames(x, "thread_message") for x in env.ws)
                  and env.frames(sender, "ack") == [], env.ws[sender].sent)
        check("denials stored nothing in main chat", main_count(gid) == before_main)

        print("flag matrix")
        set_flag(so.FLAG, "off", alice)
        env.clear()
        env.send(alice, thread_id=tid, text="", attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": 3, "verse": 16})
        errs = env.frames(alice, "error")
        check("chat_shared_objects off: not_allowed, nothing stored", len(errs) == 1 and errs[0]["reason"] == "not_allowed" and tcount(tid) == n, env.ws[alice].sent)
        env.clear()
        env.send(alice, thread_id=tid, text="plain still works with share flag off")
        check("chat_shared_objects off: plain text still sends", tcount(tid) == n + 1)
        n += 1
        set_flag(so.FLAG, "on", alice)
        set_flag("threads", "off", alice)
        env.clear()
        env.send(alice, thread_id=tid, text="", attachment_kind="shared_verse", attachment_meta={"book": "John", "chapter": 3, "verse": 16})
        errs = env.frames(alice, "error")
        check("threads off: not_allowed, nothing stored", len(errs) == 1 and errs[0]["reason"] == "not_allowed" and tcount(tid) == n, env.ws[alice].sent)
        set_flag("threads", "on", alice)
        env.clear()

        print("regression: plain and existing attachments in threads")
        env.send(alice, thread_id=tid, text="hello thread")
        check("plain text send unchanged", tcount(tid) == n + 1 and trows(tid)[-1][1] == "hello thread")
        n += 1
        env.clear()
        env.send(alice, thread_id=tid, text="", attachment_kind="image", attachment_key=own_key(alice), attachment_meta={"width": 3})
        check("image attachment with own key unchanged", tcount(tid) == n + 1 and trows(tid)[-1][2] == "image")
        n += 1
        env.clear()
        env.send(alice, thread_id=tid, text="x", attachment_kind="image", attachment_key=None)
        check("image without key still rejected", tcount(tid) == n and env.frames(alice, "error")[0]["reason"] == "not_allowed")
        env.clear()
        env.send(alice, thread_id=tid, text="x", attachment_kind="hologram", attachment_key="k")
        check("unknown kind still rejected", tcount(tid) == n)
        env.clear()

        print("thread history cleaning")
        dirty = str(uuid.uuid4())
        sql("INSERT INTO thread_messages (_id, thread_id, from_user, text, attachment_kind, attachment_meta, created_at) "
            "VALUES (%s,%s,%s,%s,'shared_note',%s::jsonb,NOW())",
            (dirty, tid, alice, "Shared a note: x",
             '{"note_id": "%s", "title": "T &amp; <b>U</b>", "preview": "<p>hi &amp; bye</p>", "owner_id": "%s"}' % (a_priv, alice)))
        limiter.reset()
        rr = cli.get(f"/groups/{bob}/{gid}/threads/{tid}/messages", params={"limit": 100}, headers=cookie(bob))
        check("history 200", rr.status_code == 200, (rr.status_code, rr.text[:200]))
        msgs = rr.json().get("messages", []) if rr.status_code == 200 else []
        d = next((m for m in msgs if m["id"] == dirty), None)
        check("history returns the dirty shared note", d is not None and d["attachment_kind"] == "shared_note", d)
        if d:
            check("history strips markup/entities from preview and title",
                  "<" not in d["attachment_meta"]["preview"] and "&amp;" not in d["attachment_meta"]["preview"]
                  and "<" not in d["attachment_meta"]["title"] and "&amp;" not in d["attachment_meta"]["title"], d["attachment_meta"])
        check("stored row untouched", "<b>" in sql("SELECT attachment_meta->>'title' FROM thread_messages WHERE _id=%s", (dirty,))[0][0])
        verse_msgs = [m for m in msgs if m["attachment_kind"] == "shared_verse"]
        check("history returns shared verse with server meta", verse_msgs and verse_msgs[0]["attachment_meta"]["reference"] == "John 3:16", verse_msgs[:1])
        sql("DELETE FROM thread_messages WHERE _id=%s", (dirty,))

        print("thread note read grant")
        r = view(cli, bob, mid_note)
        check("current group member reads a shared note from a thread", r.status_code == 200, (r.status_code, r.text[:200]))
        if r.status_code == 200:
            check("read is read-only with the shared note's content", r.json().get("title") == "Alice private", r.json())
        check("sender can read own thread share", view(cli, alice, mid_note).status_code == 200)
        limiter.reset()
        ordinary = cli.get(f"/notes/{bob}/note/{a_priv}", headers=cookie(bob))
        check("grant is one note only: ordinary notes route still refuses",
              "cannot find note" in ordinary.text or ordinary.status_code in (403, 404), (ordinary.status_code, ordinary.text[:100]))
        limiter.reset()
        put = cli.put(f"/notes/{bob}?note_id={a_priv}", headers=cookie(bob), json={"title": "pwn", "text": "pwn"})
        check("recipient cannot edit via the grant", put.status_code in (401, 403, 404) and
              sql("SELECT title FROM notes WHERE _id=%s", (a_priv,))[0][0] == "Alice private", put.status_code)

        verse_mid = next(r_[0] for r_ in trows(tid) if r_[2] == "shared_verse")
        plain_mid = add_tmsg(tid, alice, "plain")
        denials = {
            "non-member": view(cli, outsider, mid_note),
            "other user's path": view(cli, bob, mid_note, path_uid=alice),
            "verse thread message": view(cli, bob, verse_mid),
            "plain thread message": view(cli, bob, plain_mid),
            "unknown id": view(cli, bob, str(uuid.uuid4())),
            "malformed id": view(cli, bob, "not-a-uuid"),
            "sql-ish id": view(cli, bob, "x'%20OR%201=1"),
        }
        for label, resp in denials.items():
            if label == "other user's path":
                check(f"denied: {label}", resp.status_code in (401, 403), resp.status_code)
            else:
                check(f"identical 404: {label}", is_404(resp), (resp.status_code, resp.text[:120]))
        limiter.reset()
        check("unauthenticated -> 401/403", cli.get(f"/shared-objects/{bob}/note/{mid_note}").status_code in (401, 403))

        # block pair, both directions
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (bob, alice))
        check("404: viewer blocked the sender", is_404(view(cli, bob, mid_note)))
        sql("DELETE FROM blocked_users WHERE blocker_id=%s", (bob,))
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (alice, bob))
        check("404: sender blocked the viewer", is_404(view(cli, bob, mid_note)))
        sql("DELETE FROM blocked_users WHERE blocker_id=%s", (alice,))
        check("blocks lifted -> readable again", view(cli, bob, mid_note).status_code == 200)

        # membership changes
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (carol, gid))
        check("404: viewer who left the group", is_404(view(cli, carol, mid_note)))
        sql("UPDATE groups SET users = array_append(users, %s) WHERE _id=%s", (carol, gid))
        check("rejoined member reads again", view(cli, carol, mid_note).status_code == 200)
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (alice, gid))
        check("404: sender no longer a live member", is_404(view(cli, bob, mid_note)))
        sql("UPDATE groups SET users = array_append(users, %s) WHERE _id=%s", (alice, gid))
        check("sender back in group -> readable", view(cli, bob, mid_note).status_code == 200)

        # suspended viewer
        sql("UPDATE users SET suspended_at=NOW() WHERE _id=%s", (susp,))
        check("404: suspended viewer (still listed in group)", is_404(view(cli, susp, mid_note)))

        # soft-deleted thread message
        sql("UPDATE thread_messages SET deleted_at=NOW() WHERE _id=%s", (mid_note,))
        check("404: soft-deleted thread message revokes the grant (viewer and sender)",
              is_404(view(cli, bob, mid_note)) and is_404(view(cli, alice, mid_note)))
        sql("UPDATE thread_messages SET deleted_at=NULL WHERE _id=%s", (mid_note,))
        check("restored message restores the grant", view(cli, bob, mid_note).status_code == 200)

        # note changes (grant re-checked at read time)
        sql("UPDATE notes SET is_reply=TRUE WHERE _id=%s", (a_priv,))
        check("404: note became a reply", is_404(view(cli, bob, mid_note)))
        sql("UPDATE notes SET is_reply=FALSE WHERE _id=%s", (a_priv,))
        sql("UPDATE notes SET user_id=%s WHERE _id=%s", (bob, a_priv))
        check("404: sender no longer allowed to share the note (ownership moved, not public)", is_404(view(cli, carol, mid_note)))
        sql("UPDATE notes SET user_id=%s WHERE _id=%s", (alice, a_priv))
        check("ownership restored -> readable", view(cli, carol, mid_note).status_code == 200)
        # group editable note shared by bob, then made private
        env.send(bob, thread_id=tid, text="", attachment_kind="shared_note", attachment_meta={"note_id": a_grp_edit})
        mid_edit = trows(tid)[-1][0]
        check("editable group note thread share readable", view(cli, carol, mid_edit).status_code == 200)
        sql("UPDATE notes SET public=FALSE WHERE _id=%s", (a_grp_edit,))
        check("404: note made private after share (sender no longer allowed)", is_404(view(cli, carol, mid_edit)))
        sql("UPDATE notes SET public=TRUE WHERE _id=%s", (a_grp_edit,))
        sql("DELETE FROM notes WHERE _id=%s", (a_priv,))
        check("404: note deleted", is_404(view(cli, bob, mid_note)))

        # flag off at read time
        set_flag("threads", "off", alice)
        check("404: threads flag off at read time", is_404(view(cli, carol, mid_edit)))
        set_flag("threads", "on", alice)

        print("log hygiene")
        blob = " ".join(str(rec.getMessage()) for rec in cap.records)
        check("no note text in logs", SECRET not in blob and "Alice private" not in blob)
        check("no bare ERROR-level records from share paths", not [r_ for r_ in cap.records if r_.levelno >= logging.ERROR],
              [r_.getMessage() for r_ in cap.records if r_.levelno >= logging.ERROR][:3])
    finally:
        logging.getLogger().removeHandler(cap)
        env.close()
        try:
            for nid in NOTES:
                sql("DELETE FROM notes WHERE _id=%s", (nid,))
            sql("DELETE FROM thread_followers WHERE thread_id = ANY(%s::uuid[])", ([tid, tid_other],))
            sql("DELETE FROM device_tokens WHERE user_id=%s", (dave,))
            if saved:
                sql("UPDATE feature_flags SET state=%s, canary_user_ids=%s::uuid[] WHERE name=%s",
                    (saved[0][0], saved[0][1] or [], so.FLAG))
            else:
                sql("UPDATE feature_flags SET state='off' WHERE name=%s", (so.FLAG,))
            from backend.interactions import flags
            flags.invalidate()
        except Exception as e:  # noqa: BLE001
            print("cleanup issue:", type(e).__name__)
        finish()


if __name__ == "__main__":
    main()
