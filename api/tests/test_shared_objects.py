"""Tests for task 20261012-share-verses-notes-in-chat, backend (flag ``chat_shared_objects``).

Properties proved (scratch database only; asserts SHOW port = 55432 first):
  1. Send authorization (websocket ``send_msg``): own personal note, own group note and a
     public (whole-group-editable) group note of a live member are accepted; another user's
     personal note, a non-public group note of someone else, a public group note when the
     sender is not a live member, a reply note, a missing/malformed note id all give ONE
     identical ``not_allowed`` frame and save nothing. Flag off refuses too.
  2. Server-built payload: the stored attachment_meta and fallback text are rebuilt on the
     server; client-supplied title/preview/text/key are ignored. Verses are validated
     (real reference, range cap) and carry WEB text.
  3. Old-client fallback: stored ``text`` is a plain readable line; existing kinds (text,
     gif) are unaffected; thread sends still reject the new kinds; the group media gallery
     never lists shares.
  4. Share grant (GET /shared-objects/{uid}/note/{mid}): a recipient who cannot otherwise
     see the note reads it (read_only, no replies, no write paths); non-participant, blocked
     pair (DM and group), deleted message, restored message, note gone, note made private,
     sender left the group (editable group note), verse message, plain message, malformed
     ids, flag off and another user's path all give the IDENTICAL 404 (or 401/403 for auth).
     The grant is one note only: the recipient still cannot GET/PUT/DELETE the note through
     the ordinary notes routes.
  5. The view rate limit is configured and trips.

Run with: cd api && FS_SCRATCH_PG_PORT=55432 ../.venv/bin/python tests/test_shared_objects.py
"""
import _pathfix  # noqa: F401

import asyncio
import os
import uuid
from datetime import datetime, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from _thr_common import (  # noqa: E402
    FAILED, USERS, GROUPS, check, require_scratch_db, sql, make_user, make_group, make_msg,
    cookie, set_flag, FakeWS, finish,
)
from backend.interactions import flags  # noqa: E402
from backend.interactions import shared_objects as so  # noqa: E402
from backend.rate_limiting import limiter  # noqa: E402
from routes.messaging import manager as ws_manager  # noqa: E402
from schemas.message import ATTACHMENT_KINDS  # noqa: E402

FLAG = so.FLAG
NOTES: list = []
NOT_ALLOWED = {"type": "error", "reason": "not_allowed", "detail": "Couldn't send your message."}
NOT_FOUND = {"detail": {"code": "not_found", "message": "Not found"}}


def befriend(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s) ON CONFLICT DO NOTHING", (a, b, b, a))


def block(blocker, blocked):
    sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (blocker, blocked))


def unblock_all(*uids):
    for u in uids:
        sql("DELETE FROM blocked_users WHERE blocker_id=%s OR blocked_id=%s", (u, u))


def make_note(owner, title="My title", text="Body text of the note", public=False, group_id=None, is_reply=False):
    nid = str(uuid.uuid4())
    sql("INSERT INTO notes (_id,user_id,title,text,public,group_id,is_reply,timestamp,created_at) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,NOW(),NOW())", (nid, owner, title, text, public, group_id, is_reply))
    NOTES.append(nid)
    return nid


class Sockets:
    def __init__(self, *uids):
        self.ws = {u: FakeWS() for u in uids}
        ws_manager.active_connections.update(self.ws)

    def close(self):
        for u in self.ws:
            ws_manager.active_connections.pop(u, None)


def send(sender, to_users, gid, text, kind=None, meta=None, **extra):
    if gid and not to_users:
        to_users = [sender]
    p = {"from_user": sender, "to_users": to_users, "text": text, "group_id": gid,
         "timestamp": datetime.now(timezone.utc).isoformat()}
    if kind:
        p["attachment_kind"] = kind
        p["attachment_meta"] = meta
    p.update(extra)
    asyncio.run(ws_manager.send_msg(p))


def stored(sender, kind):
    return sql("SELECT _id::text, text, attachment_kind, attachment_key, attachment_meta FROM messages "
               "WHERE from_user=%s AND attachment_kind=%s ORDER BY timestamp DESC", (sender, kind))


def count_kind(sender, kind):
    return len(stored(sender, kind))


def share_note(sender, to, gid, note_id, **extra):
    """Send a note share; return (frames-to-sender, message-id-or-None)."""
    s = Sockets(sender)
    try:
        before = count_kind(sender, so.KIND_NOTE)
        send(sender, to, gid, "client text must be ignored", so.KIND_NOTE, {"note_id": note_id, **extra})
        errs = [f for f in s.ws[sender].sent if f.get("type") == "error"]
        rows = stored(sender, so.KIND_NOTE)
        mid = rows[0][0] if len(rows) > before else None
        return errs, mid
    finally:
        s.close()


def share_verse(sender, to, gid, meta):
    s = Sockets(sender)
    try:
        before = count_kind(sender, so.KIND_VERSE)
        send(sender, to, gid, "client text", so.KIND_VERSE, meta)
        errs = [f for f in s.ws[sender].sent if f.get("type") == "error"]
        rows = stored(sender, so.KIND_VERSE)
        return errs, (rows[0] if len(rows) > before else None)
    finally:
        s.close()


def view(cli, viewer, mid, path_uid=None):
    limiter.reset()
    return cli.get(f"/shared-objects/{path_uid or viewer}/note/{mid}", headers=cookie(viewer))


def is_404(r):
    return r.status_code == 404 and r.json() == NOT_FOUND


def main():
    require_scratch_db()
    cli = TestClient(main_module.app)
    saved = sql("SELECT state, canary_user_ids::text[] FROM feature_flags WHERE name=%s", (FLAG,))
    try:
        alice, bob, carol, dave, erin = (make_user("so") for _ in range(5))
        set_flag(FLAG, "on", alice)
        befriend(alice, bob)
        befriend(alice, dave)
        befriend(bob, dave)
        befriend(alice, erin)
        grp = make_group([alice, bob, carol], creator=alice)   # alice, bob, carol; dave/erin outsiders
        other_grp = make_group([dave, erin], creator=dave)

        a_personal = make_note(alice, "Alice private", "secret private text")
        a_group_priv = make_note(alice, "Alice grp", "grp body", public=False, group_id=grp)
        a_group_edit = make_note(alice, "Whole group", "everyone can edit", public=True, group_id=grp)
        b_personal = make_note(bob, "Bob private", "bob secret")
        b_group_priv = make_note(bob, "Bob grp priv", "bob grp", public=False, group_id=grp)
        b_group_edit = make_note(bob, "Bob editable", "bob editable body", public=True, group_id=grp)
        reply_note = make_note(alice, "reply", "r", is_reply=True)

        # ------------------------------------------------------------ 1 verse
        print("verse shares")
        errs, row = share_verse(alice, [bob], None, {"book": "John", "chapter": 3, "verse": 16,
                                                     "text": "FORGED", "reference": "FORGED"})
        check("DM verse accepted", not errs and row is not None, errs)
        if row:
            meta = row[4]
            check("verse kind stored, no object key", row[2] == so.KIND_VERSE and row[3] is None, row)
            check("verse text from server data, not client", "FORGED" not in str(meta) and meta["text"] and meta["translation"] == "WEB", meta)
            check("reference built server-side", meta["reference"] == "John 3:16", meta)
            check("old-client fallback text is plain quote + reference", row[1].endswith("— John 3:16") and "FORGED" not in row[1], row[1])
        errs, row = share_verse(alice, None, grp, {"book": "John", "chapter": 3, "verse": 16, "verse_end": 18})
        check("group verse range accepted", not errs and row is not None and row[4]["reference"] == "John 3:16-18", (errs, row))
        for label, meta in {
            "unknown book": {"book": "Hezekiah", "chapter": 1, "verse": 1},
            "chapter out of range": {"book": "John", "chapter": 99, "verse": 1},
            "range over cap": {"book": "John", "chapter": 3, "verse": 1, "verse_end": 30},
            "reversed range": {"book": "John", "chapter": 3, "verse": 16, "verse_end": 2},
            "string chapter": {"book": "John", "chapter": "3", "verse": 16},
            "bool verse": {"book": "John", "chapter": 3, "verse": True},
        }.items():
            n = count_kind(alice, so.KIND_VERSE)
            errs, row = share_verse(alice, [bob], None, meta)
            check(f"verse rejected: {label}", errs == [NOT_ALLOWED] and count_kind(alice, so.KIND_VERSE) == n, (errs, row))

        # ------------------------------------------------------------ 2 note send auth
        print("note send authorization")
        errs, mid_personal = share_note(alice, [bob], None, a_personal,
                                        title="FORGED TITLE", preview="FORGED", owner_id=bob)
        check("own personal note -> DM accepted", not errs and mid_personal, errs)
        m = sql("SELECT text, attachment_kind, attachment_key, attachment_meta FROM messages WHERE _id=%s", (mid_personal,))[0]
        check("note payload rebuilt on server (client title/preview/owner ignored)",
              m[3]["title"] == "Alice private" and m[3]["preview"] == "secret private text"
              and m[3]["owner_id"] == alice and "FORGED" not in str(m[3]), m[3])
        check("note fallback text for old clients", m[0] == "Shared a note: Alice private" and m[2] is None, m)
        check("card has is_group_note false for personal", m[3]["is_group_note"] is False, m[3])
        errs, mid_group = share_note(alice, None, grp, a_group_priv)
        check("own non-public group note -> group accepted", not errs and mid_group, errs)
        errs, mid_edit = share_note(bob, None, grp, a_group_edit)
        check("editable (public) group note of someone else, sender live member -> accepted", not errs and mid_edit, errs)

        denied = {
            "someone else's personal note": (bob, [alice], None, a_personal),
            "someone else's non-public group note": (bob, None, grp, a_group_priv),
            "public group note, sender not a member": (dave, [alice], None, a_group_edit),
            "reply note even if own": (alice, [bob], None, reply_note),
            "missing note id": (alice, [bob], None, str(uuid.uuid4())),
            "malformed note id": (alice, [bob], None, "not-a-uuid"),
            "sql-ish note id": (alice, [bob], None, "x' OR '1'='1"),
        }
        bodies = []
        for label, (snd, to, gid, nid) in denied.items():
            n = count_kind(snd, so.KIND_NOTE)
            errs, mid = share_note(snd, to, gid, nid)
            check(f"denied: {label}", errs == [NOT_ALLOWED] and mid is None and count_kind(snd, so.KIND_NOTE) == n, (errs, mid))
            bodies.append(errs)
        check("denial frames are all identical (no oracle)", all(b == bodies[0] for b in bodies), bodies)
        n = count_kind(alice, so.KIND_NOTE)
        s = Sockets(alice)
        send(alice, [bob], None, "x", so.KIND_NOTE, {})
        send(alice, [bob], None, "x", so.KIND_NOTE, {"note_id": a_personal}, attachment_key="attachments/x/y.jpg")
        check("empty meta / client-supplied object key dropped, nothing stored", count_kind(alice, so.KIND_NOTE) == n)
        s.close()
        # sender who left the group cannot share the editable group note any more
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (carol, grp))
        n = count_kind(carol, so.KIND_NOTE)
        errs, mid = share_note(carol, [alice], None, a_group_edit)
        check("denied: sender no longer a group member (editable note)", errs == [NOT_ALLOWED] and mid is None, (errs, mid))
        sql("UPDATE groups SET users = array_append(users, %s) WHERE _id=%s", (carol, grp))

        # flag off refuses everything, nothing stored
        set_flag(FLAG, "off", alice)
        n = count_kind(alice, so.KIND_NOTE) + count_kind(alice, so.KIND_VERSE)
        e1, _ = share_note(alice, [bob], None, a_personal)
        e2, _ = share_verse(alice, [bob], None, {"book": "John", "chapter": 3, "verse": 16})
        check("flag off: note and verse refused, nothing stored",
              e1 == [NOT_ALLOWED] and e2 == [NOT_ALLOWED]
              and count_kind(alice, so.KIND_NOTE) + count_kind(alice, so.KIND_VERSE) == n, (e1, e2))
        set_flag(FLAG, "on", alice)

        # ------------------------------------------------------------ 3 old clients / existing types
        print("existing types unaffected")
        check("new kinds are NOT in ATTACHMENT_KINDS (threads keep rejecting them)",
              so.KIND_VERSE not in ATTACHMENT_KINDS and so.KIND_NOTE not in ATTACHMENT_KINDS, ATTACHMENT_KINDS)
        s = Sockets(alice)
        send(alice, [bob], None, "plain hello")
        send(alice, [bob], None, "gif", "gif", {"url": "https://media.example.com/a.gif"})
        send(alice, [bob], None, "bogus", "shared_other", {"x": 1})
        rows = sql("SELECT text, attachment_kind FROM messages WHERE from_user=%s AND text IN ('plain hello','gif','bogus')", (alice,))
        got = {r[0]: r[1] for r in rows}
        check("plain text message still stored", got.get("plain hello") is None and "plain hello" in got, got)
        check("gif message still stored", got.get("gif") == "gif", got)
        check("unknown kind still dropped", "bogus" not in got, got)
        s.close()
        from backend.interactions.groups import GroupsManager
        gm = GroupsManager(alice, grp)
        try:
            gal = gm.fetch_gallery(limit=50)
        finally:
            gm.close()
        kinds = {i["kind"] for i in gal["items"]}
        check("group media gallery lists the gif but never shared kinds", not (kinds & so.SHARED_KINDS), kinds)
        n = count_kind(alice, so.KIND_VERSE)
        s = Sockets(alice)
        send(alice, [bob], None, "x", so.KIND_VERSE, "John 3:16")
        s.close()
        check("non-dict verse meta stored nothing", count_kind(alice, so.KIND_VERSE) == n)

        # ------------------------------------------------------------ 4 the grant
        print("share grant: recipient read")
        r = view(cli, bob, mid_personal)
        check("DM recipient reads note they could never see", r.status_code == 200, (r.status_code, r.text))
        body = r.json() if r.status_code == 200 else {}
        check("read_only true, replies empty, title/text present",
              body.get("read_only") is True and body.get("replies") == [] and body.get("title") == "Alice private"
              and body.get("text") == "secret private text", body)
        check("response is a single note (no other note content)", "bob secret" not in r.text and "Alice grp" not in r.text, r.text)
        ordinary = cli.get(f"/notes/{bob}/note/{a_personal}", headers=cookie(bob))
        check("grant does not widen ordinary note route (still cannot GET it)",
              "cannot find note" in ordinary.text or ordinary.status_code in (403, 404), (ordinary.status_code, ordinary.text))
        limiter.reset()
        put = cli.put(f"/notes/{bob}?note_id={a_personal}", headers=cookie(bob), json={"title": "pwn", "text": "pwn"})
        check("recipient cannot edit shared personal note", put.status_code in (401, 403, 404), (put.status_code, put.text))
        limiter.reset()
        dele = cli.delete(f"/notes/{bob}?note_id={a_personal}", headers=cookie(bob))
        check("recipient cannot delete shared personal note", dele.status_code in (401, 403, 404), (dele.status_code, dele.text))
        check("note unchanged after attempts", sql("SELECT title FROM notes WHERE _id=%s", (a_personal,))[0][0] == "Alice private")
        check("sender (not just recipient) can open own share", view(cli, alice, mid_personal).status_code == 200)

        r = view(cli, carol, mid_group)
        check("group member reads shared non-public group note", r.status_code == 200 and r.json()["is_group_note"] is True, (r.status_code, r.text))
        r = view(cli, bob, mid_edit)
        check("editable group note share: shared_by shown when sender != owner", view(cli, alice, mid_edit).json().get("shared_by") == sql("SELECT username FROM users WHERE _id=%s", (bob,))[0][0])

        print("share grant: denials (identical 404)")
        denials = {
            "non-participant (outsider of DM)": view(cli, erin, mid_personal),
            "non-participant (other user, group msg)": view(cli, dave, mid_group),
            "malformed message id": view(cli, bob, "not-a-uuid"),
            "sql-ish message id": view(cli, bob, "x'%20OR%201=1"),
            "unknown message id": view(cli, bob, str(uuid.uuid4())),
        }
        verse_mid = stored(alice, so.KIND_VERSE)[0][0]
        denials["verse message"] = view(cli, bob, verse_mid)
        plain_dm = make_msg(alice, None, "plain", group=False)
        sql("INSERT INTO message_recipients (message_id, user_id) VALUES (%s,%s)", (plain_dm, bob))
        denials["plain text message"] = view(cli, bob, plain_dm)
        for label, r in denials.items():
            check(f"404: {label}", is_404(r), (r.status_code, r.text))

        check("another user's path -> not 200", view(cli, bob, mid_personal, path_uid=alice).status_code in (401, 403))
        limiter.reset()
        check("unauthenticated -> 401/403", cli.get(f"/shared-objects/{bob}/note/{mid_personal}").status_code in (401, 403))

        # blocked pair
        block(bob, alice)
        check("404: DM blocked pair (recipient blocked sender)", is_404(view(cli, bob, mid_personal)))
        unblock_all(alice, bob)
        block(alice, bob)
        check("404: DM blocked pair (sender blocked recipient)", is_404(view(cli, bob, mid_personal)))
        unblock_all(alice, bob)
        check("blocks lifted -> readable again", view(cli, bob, mid_personal).status_code == 200)
        block(carol, alice)
        check("404: group message, viewer blocked the sender", is_404(view(cli, carol, mid_group)))
        check("group message still fine for unblocked member", view(cli, bob, mid_group).status_code == 200)
        unblock_all(alice, carol)

        # deleted / restored message
        sql("UPDATE messages SET deleted_at = NOW() WHERE _id=%s", (mid_personal,))
        check("404: deleted message revokes the grant", is_404(view(cli, bob, mid_personal)) and is_404(view(cli, alice, mid_personal)))
        sql("UPDATE messages SET deleted_at = NULL WHERE _id=%s", (mid_personal,))
        check("restored message restores the grant", view(cli, bob, mid_personal).status_code == 200)

        # recipient left the group
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (carol, grp))
        check("404: viewer who left the group", is_404(view(cli, carol, mid_group)))
        sql("UPDATE groups SET users = array_append(users, %s) WHERE _id=%s", (carol, grp))

        # sender left the group (note owned by a different user, editable by whole group)
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (bob, grp))
        errs, mid_bob_edit = (None, None)
        sql("UPDATE groups SET users = array_append(users, %s) WHERE _id=%s", (bob, grp))
        errs, mid_bob_edit = share_note(bob, None, grp, a_group_edit)   # bob shares alice's editable note
        check("setup: bob shares alice's editable group note", not errs and mid_bob_edit, errs)
        check("carol reads it while bob is in the group", view(cli, carol, mid_bob_edit).status_code == 200)
        sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id=%s", (bob, grp))
        check("404: sender left the group (read-time sender re-check)", is_404(view(cli, carol, mid_bob_edit)))
        sql("UPDATE groups SET users = array_append(users, %s) WHERE _id=%s", (bob, grp))
        check("sender back in group -> readable", view(cli, carol, mid_bob_edit).status_code == 200)

        # editable group note flips to non-public after sharing
        sql("UPDATE notes SET public=FALSE WHERE _id=%s", (a_group_edit,))
        check("404: editable note made non-public after a non-owner share", is_404(view(cli, carol, mid_bob_edit)))
        check("owner's own share of a non-public note still readable", view(cli, carol, mid_group).status_code == 200)
        sql("UPDATE notes SET public=TRUE WHERE _id=%s", (a_group_edit,))

        # note gone
        gone = make_note(alice, "Soon gone", "bye")
        errs, mid_gone = share_note(alice, [bob], None, gone)
        check("setup: share a note then delete it", not errs and mid_gone and view(cli, bob, mid_gone).status_code == 200, errs)
        sql("DELETE FROM notes WHERE _id=%s", (gone,))
        check("404: note deleted after share", is_404(view(cli, bob, mid_gone)))

        # live view: edits visible; stored card is the snapshot
        live = make_note(alice, "Before edit", "old text")
        _, mid_live = share_note(alice, [bob], None, live)
        sql("UPDATE notes SET title='After edit', text='new text' WHERE _id=%s", (live,))
        b = view(cli, bob, mid_live).json()
        check("live view shows the current note text", b.get("title") == "After edit" and b.get("text") == "new text", b)
        check("stored card stays a send-time snapshot",
              sql("SELECT attachment_meta->>'title' FROM messages WHERE _id=%s", (mid_live,))[0][0] == "Before edit")

        # grant never reaches the owner's other notes
        other = make_note(alice, "Other note", "should stay hidden")
        txt = view(cli, bob, mid_personal).text
        check("no other note of the author is reachable via the share", "should stay hidden" not in txt)
        check("path takes only a message id; a note id there is a 404", is_404(view(cli, bob, other)))

        # flag off for viewer
        set_flag(FLAG, "off", alice)
        check("404: flag off", is_404(view(cli, bob, mid_personal)))
        set_flag(FLAG, "on", alice)

        # ------------------------------------------------------------ 5 rate limit
        print("rate limit")
        check("view_rate configured", so.view_rate().split("/")[0].isdigit(), so.view_rate())
        limiter.reset()
        limit = int(so.view_rate().split("/")[0])
        codes = [cli.get(f"/shared-objects/{bob}/note/{mid_personal}", headers=cookie(bob)).status_code
                 for _ in range(limit + 3)]
        check("rate limit trips (429) after the configured count", 429 in codes and codes[0] == 200, codes[-5:])
        limiter.reset()
    finally:
        try:
            for nid in NOTES:
                sql("DELETE FROM notes WHERE _id=%s", (nid,))
            for gid in list(GROUPS):
                sql("DELETE FROM message_recipients WHERE message_id IN (SELECT _id FROM messages WHERE group_id=%s)", (gid,))
            if saved:
                sql("UPDATE feature_flags SET state=%s, canary_user_ids=%s::uuid[] WHERE name=%s",
                    (saved[0][0], saved[0][1] or [], FLAG))
            else:
                sql("UPDATE feature_flags SET state='off' WHERE name=%s", (FLAG,))
            flags.invalidate()
        except Exception as e:  # noqa: BLE001
            print("cleanup issue:", type(e).__name__)
        finish(flag_names=())


if __name__ == "__main__":
    main()
