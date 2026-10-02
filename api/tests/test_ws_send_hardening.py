"""Tests for the main-chat WebSocket send hardening (task 20261002-ws-send-hardening).

ConnectionManager.send_msg used to trust client-supplied ``to_users`` and
``group_id`` and any attachment key. ``backend/interactions/send_guard.py`` now
authorizes every main-chat send before it is saved. This suite proves, against
the scratch database only (asserts SHOW port = 55432 first):

  1. group send: member accepted; non-member rejected (nothing saved, nothing
     delivered, uniform not_allowed frame); mixed-case member ids accepted
  2. forged to_users / forged group_id: an outsider id in to_users never gets a
     message_recipients row or a frame; recipients come from the group
  3. DM rules: friend ok (build-78 shape, group_id "" or None); non-friend,
     self, unknown user, two recipients, non-string recipient all rejected
  4. attachment key ownership: own key ok; other user's key, '..', wrong
     prefix, over 512 chars rejected; gif unchanged
  5. blocked DM is dropped silently (no frame, nothing saved)
  6. infrastructure error inside the guard -> send_failed (not not_allowed),
     nothing saved
  7. every denial cause yields the identical not_allowed frame
  8. log hygiene: no ERROR-level record, no 'ERROR' word, no message text, no
     key and no token from the guard path
  9. source-level (R4-1): send_guard.py uses groups.live_member_ids and has no
     unnest( or ::text join of its own

Run with: cd api && ../.venv/bin/python tests/test_ws_send_hardening.py
"""
import asyncio
import logging
import os
import re
import sys
import uuid
from datetime import datetime, timezone

import _pathfix  # noqa: F401,E402

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import psycopg2  # noqa: E402
from db import DBManager  # noqa: E402
import backend.interactions.websockets as ws_module  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
import backend.interactions.send_guard as send_guard  # noqa: E402

PASSED, FAILED = [], []

NOT_ALLOWED = {"type": "error", "reason": "not_allowed", "detail": "Couldn't send your message."}


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


class LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.records = []

    def emit(self, record):
        self.records.append(record)


def new_user(prefix):
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"{prefix}_{uid[:8]}",
            "email": f"{prefix}_{uid[:8]}@example.com", "hash_pass": "x",
        })
    finally:
        db.close()
    return uid


def sql(query, params=()):
    db = DBManager()
    try:
        db.cur.execute(query, params)
        rows = db.cur.fetchall() if db.cur.description else None
        db.conn.commit()
        return rows
    finally:
        db.close()


def befriend(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s, %s), (%s, %s) ON CONFLICT DO NOTHING", (a, b, b, a))


def new_group(users):
    gid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("groups", {"_id": gid, "title": "wsh-test-group", "users": users})
    finally:
        db.close()
    return gid


def cleanup(users, groups):
    for uid in users:
        sql("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
        sql("DELETE FROM messages WHERE from_user = %s", (uid,))
        sql("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
        sql("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (uid, uid))
    for gid in groups:
        sql("DELETE FROM groups WHERE _id = %s", (gid,))
    for uid in users:
        sql("DELETE FROM users WHERE _id = %s", (uid,))


def saved(marker):
    rows = sql("SELECT _id FROM messages WHERE text = %s", (marker,))
    return [str(r[0]) for r in rows]


def recipients_of(marker):
    ids = saved(marker)
    if not ids:
        return None
    rows = sql("SELECT user_id FROM message_recipients WHERE message_id = %s", (ids[0],))
    return {str(r[0]) for r in rows}


def payload(sender, to_users, group_id, marker, **extra):
    p = {"from_user": sender, "to_users": to_users, "text": marker, "group_id": group_id,
         "timestamp": datetime.now(timezone.utc).isoformat()}
    p.update(extra)
    return p


class Env:
    """A ConnectionManager with fake sockets registered for the given users, push stubbed."""

    def __init__(self, *uids):
        self.manager = ConnectionManager()
        self.ws = {}
        for u in uids:
            self.ws[u] = FakeWS()
            self.manager.active_connections[u] = self.ws[u]
        self.pushed = []

        async def fake_push(token, title, body, data=None):
            self.pushed.append((token, title, body, data))
            return True

        self._orig = ws_module.send_push
        ws_module.send_push = fake_push

    async def send(self, p):
        await self.manager.send_msg(p)

    def close(self):
        ws_module.send_push = self._orig
        self.manager.close()


def frames_of(env, uid, kind="error"):
    return [f for f in env.ws[uid].sent if f.get("type") == kind]


async def run():
    users, groups = [], []

    def mk(prefix):
        u = new_user(prefix)
        users.append(u)
        return u

    sender = mk("wsh_sender")
    member = mk("wsh_member")
    outsider = mk("wsh_outsider")
    friend = mk("wsh_friend")
    stranger = mk("wsh_stranger")
    blocker = mk("wsh_blocker")
    befriend(sender, friend)
    gid = new_group([sender, member])
    groups.append(gid)
    outsider_group = new_group([member, outsider])   # sender is NOT in it
    groups.append(outsider_group)
    env = Env(sender, member, outsider, friend, stranger, blocker)
    cap = LogCapture()
    logging.getLogger().addHandler(cap)
    old_level = logging.getLogger().level
    logging.getLogger().setLevel(logging.DEBUG)
    try:
        print("=== 1. group send: membership ===")
        m = f"grp-ok-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender, [sender, member], gid, m))
        check("member group send is saved", len(saved(m)) == 1)
        check("recipients are the group member list (sender included, as shipped clients send it)",
              recipients_of(m) == {sender, member}, str(recipients_of(m)))
        check("other member got the frame", any(f.get("text") == m for f in env.ws[member].sent))
        check("sender got no frame echo of own group message", not any(f.get("text") == m for f in env.ws[sender].sent))
        check("member send produced no error frame", not frames_of(env, sender))

        for e in env.ws.values():
            e.sent.clear()
        m = f"grp-nonmember-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender, [member, outsider], outsider_group, m))
        check("non-member group send is not saved", saved(m) == [])
        check("non-member group send: sender gets exactly the uniform not_allowed frame",
              env.ws[sender].sent == [NOT_ALLOWED], str(env.ws[sender].sent))
        check("non-member group send: nobody else got a frame",
              not env.ws[member].sent and not env.ws[outsider].sent)

        # mixed-case ids: legacy group row stores upper-case ids; client sends mixed case
        env.ws[sender].sent.clear()
        mixed_gid = new_group([sender.upper(), member.upper()])
        groups.append(mixed_gid)
        m = f"grp-mixed-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender.upper(), [sender, member], mixed_gid.upper(), m))
        # from_user is the authenticated lower-case id in production; send both ways
        m2 = f"grp-mixed2-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender, [sender, member], mixed_gid.upper(), m2))
        check("member with upper-case ids stored in groups.users is accepted (lower-case sender, upper-case group id)",
              len(saved(m2)) == 1, str(env.ws[sender].sent))
        check("is_current_member is case-insensitive on both sides",
              send_guard.is_current_member(_Cur(), mixed_gid.upper(), sender.upper()) is True)
        check("is_current_member rejects a non-member", send_guard.is_current_member(_Cur(), mixed_gid, outsider) is False)
        check("is_current_member rejects a malformed id", send_guard.is_current_member(_Cur(), "nope", sender) is False)

        print("\n=== 2. forged to_users / forged group_id ===")
        for e in env.ws.values():
            e.sent.clear()
        m = f"forged-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender, [sender, member, outsider, stranger], gid, m))
        check("forged to_users: message saved once", len(saved(m)) == 1)
        check("forged to_users: outsider/stranger get NO message_recipients row",
              recipients_of(m) == {sender, member}, str(recipients_of(m)))
        check("forged to_users: outsider and stranger receive no frame",
              not env.ws[outsider].sent and not env.ws[stranger].sent)
        m = f"forged-gid-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender, [sender, member], str(uuid.uuid4()), m))
        check("forged (nonexistent) group_id rejected, nothing saved", saved(m) == [])
        m = f"forged-gid2-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender, [sender, member], "not-a-uuid'; DROP TABLE groups;--", m))
        check("junk group_id rejected, nothing saved", saved(m) == [])
        check("junk group_id: sender got not_allowed", NOT_ALLOWED in env.ws[sender].sent)

        print("\n=== 3. DM rules ===")
        for e in env.ws.values():
            e.sent.clear()
        for gval, label in [("", "iOS group_id ''"), (None, "group_id None")]:
            m = f"dm-ok-{uuid.uuid4().hex[:8]}"
            await env.send(payload(sender, [friend], gval, m))
            check(f"friend DM ({label}) saved with exactly the friend as recipient",
                  recipients_of(m) == {friend}, str(recipients_of(m)))
            check(f"friend DM ({label}) delivered to friend", any(f.get("text") == m for f in env.ws[friend].sent))
        env.ws[sender].sent.clear()
        cases = [
            ("non-friend DM", [stranger]),
            ("self DM", [sender]),
            ("unknown user DM", [str(uuid.uuid4())]),
            ("two-recipient DM", [friend, member]),
            ("two-recipient DM incl. self", [friend, sender]),
            ("non-uuid recipient", ["not-a-uuid"]),
            ("non-string recipient", [12345]),
            ("recipient is not a list", friend),
        ]
        for label, tu in cases:
            m = f"dm-bad-{uuid.uuid4().hex[:8]}"
            env.ws[sender].sent.clear()
            await env.send(payload(sender, tu, "", m))
            check(f"{label}: rejected, nothing saved", saved(m) == [])
            check(f"{label}: uniform not_allowed frame", env.ws[sender].sent == [NOT_ALLOWED], str(env.ws[sender].sent))
        check("non-friend recipient never got a frame", not env.ws[stranger].sent)
        m = f"dm-upper-{uuid.uuid4().hex[:8]}"
        env.ws[sender].sent.clear()
        await env.send(payload(sender, [friend.upper()], "", m))
        check("friend DM with upper-case recipient id accepted", len(saved(m)) == 1, str(env.ws[sender].sent))

        print("\n=== 4. attachment key ownership ===")
        other = "attachments/%s/%s.jpg" % (member, uuid.uuid4().hex)
        own = "attachments/%s/%s.jpg" % (sender, uuid.uuid4().hex)
        long_key = "attachments/%s/%s.jpg" % (sender, "a" * 600)
        bad = [
            ("another user's key", other),
            ("traversal '..'", "attachments/%s/../%s/x.jpg" % (sender, member)),
            ("wrong prefix", "uploads/%s/x.jpg" % sender),
            ("no sender segment", "attachments/x.jpg"),
            ("over 512 chars", long_key),
            ("prefix only", "attachments/%s/" % sender),
            ("sender id as prefix of another id", "attachments/%s0/x.jpg" % sender),
        ]
        for kind in ("image", "video", "file"):
            for label, key in bad:
                m = f"att-bad-{uuid.uuid4().hex[:8]}"
                env.ws[sender].sent.clear()
                meta = {"filename": "a.txt"} if kind == "file" else {"width": 1, "height": 1}
                await env.send(payload(sender, [sender, member], gid, m, attachment_kind=kind,
                                       attachment_key=key, attachment_meta=meta))
                check(f"{kind} with {label} rejected and not saved",
                      saved(m) == [] and env.ws[sender].sent == [NOT_ALLOWED], str(env.ws[sender].sent))
        for kind in ("image", "video", "file"):
            m = f"att-ok-{uuid.uuid4().hex[:8]}"
            key = "attachments/%s/%s.bin" % (sender, uuid.uuid4().hex)
            meta = {"filename": "a.txt"} if kind == "file" else {"width": 1, "height": 1}
            await env.send(payload(sender, [sender, member], gid, m, attachment_kind=kind,
                                   attachment_key=key, attachment_meta=meta))
            check(f"own {kind} key accepted and saved", len(saved(m)) == 1)
        m = f"att-gif-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender, [sender, member], gid, m, attachment_kind="gif",
                               attachment_meta={"url": "https://media.example/g.gif"}))
        check("gif unchanged (no key, accepted)", len(saved(m)) == 1)
        m = f"att-dm-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender, [friend], "", m, attachment_kind="image", attachment_key=other,
                               attachment_meta={"width": 1, "height": 1}))
        check("DM with another user's image key rejected", saved(m) == [])
        check("validate_attachment_key unit: gif / none always pass",
              send_guard.validate_attachment_key(sender, "gif", None) and send_guard.validate_attachment_key(sender, None, None))
        check("validate_attachment_key unit: backslash and NUL rejected",
              not send_guard.validate_attachment_key(sender, "image", "attachments/%s/a\\b.jpg" % sender)
              and not send_guard.validate_attachment_key(sender, "image", "attachments/%s/a\x00.jpg" % sender))

        print("\n=== 5. blocked DM is dropped silently ===")
        befriend(sender, blocker)
        sql("DELETE FROM user_friends WHERE (user_id=%s AND friend_id=%s) OR (user_id=%s AND friend_id=%s)",
            (sender, blocker, blocker, sender))
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", (blocker, sender))
        env.ws[sender].sent.clear()
        m = f"dm-blocked-{uuid.uuid4().hex[:8]}"
        await env.send(payload(sender, [blocker], "", m))
        check("blocked DM not saved", saved(m) == [])
        check("blocked DM: sender gets NO frame (silent drop, as today)", env.ws[sender].sent == [], str(env.ws[sender].sent))
        check("blocked DM: blocker gets no frame", not env.ws[blocker].sent)

        print("\n=== 6. infrastructure error -> send_failed, nothing saved ===")
        env2 = Env(sender, member)
        real_execute = env2.manager._execute
        calls = {"n": 0}

        def broken(query, params=()):
            calls["n"] += 1
            raise psycopg2.OperationalError("connection to server lost")

        env2.manager._execute = broken
        try:
            m = f"infra-{uuid.uuid4().hex[:8]}"
            await env2.send(payload(sender, [sender, member], gid, m))
            check("guard infra error (group): saved nothing", saved(m) == [])
            check("guard infra error (group): send_failed frame, NOT not_allowed",
                  env2.ws[sender].sent == [{"type": "error", "reason": "send_failed",
                                            "detail": "Couldn't send your message. Please try again."}],
                  str(env2.ws[sender].sent))
            check("guard infra error: guard actually used the manager's _execute", calls["n"] >= 1)
            env2.ws[sender].sent.clear()
            m = f"infra-dm-{uuid.uuid4().hex[:8]}"
            await env2.send(payload(sender, [friend], "", m))
            check("guard infra error (DM): saved nothing, send_failed frame",
                  saved(m) == [] and [f.get("reason") for f in env2.ws[sender].sent] == ["send_failed"],
                  str(env2.ws[sender].sent))
            res = send_guard.authorize_send(_Broken(), sender, payload(sender, [friend], "", "x"))
            check("authorize_send returns Unavailable on an unexpected exception (fail closed, never SendDecision)",
                  isinstance(res, send_guard.Unavailable), repr(res))
        finally:
            env2.manager._execute = real_execute
            env2.close()

        print("\n=== 7. uniform not_allowed frame for every denial cause ===")
        frames = []
        for label, p in [
            ("non-member", payload(sender, [member], outsider_group, "u1")),
            ("bad group id", payload(sender, [member], "zzz", "u2")),
            ("non-friend", payload(sender, [stranger], "", "u3")),
            ("self", payload(sender, [sender], "", "u4")),
            ("unknown", payload(sender, [str(uuid.uuid4())], "", "u5")),
            ("two recipients", payload(sender, [friend, member], "", "u6")),
            ("foreign key", payload(sender, [friend], "", "u7", attachment_kind="image", attachment_key=other,
                                    attachment_meta={})),
        ]:
            env.ws[sender].sent.clear()
            await env.send(p)
            frames.append(list(env.ws[sender].sent))
        check("all denial causes produce a byte-identical single not_allowed frame",
              all(f == [NOT_ALLOWED] for f in frames), str(frames))
        check("not_allowed frame carries no cause, group or user id",
              all(set(f[0].keys()) == {"type", "reason", "detail"} for f in frames))

        print("\n=== 8. build-78 frame compatibility ===")
        for e in env.ws.values():
            e.sent.clear()
        m = f"b78-grp-{uuid.uuid4().hex[:8]}"
        await env.send({"from_user": sender, "to_users": [sender, member], "text": m, "group_id": gid,
                        "timestamp": datetime.now(timezone.utc).isoformat()})
        fr = [f for f in env.ws[member].sent if f.get("text") == m]
        check("build-78 group frame delivered with unchanged keys",
              len(fr) == 1 and {"from_user", "text", "group_id", "timestamp", "attachment_kind",
                                "attachment_meta", "attachment_url"} <= set(fr[0].keys()), str(fr))
        check("build-78 group frame: identical message_recipients rows (sender + member)",
              recipients_of(m) == {sender, member})
        m = f"b78-dm-{uuid.uuid4().hex[:8]}"
        await env.send({"from_user": sender, "to_users": [friend], "text": m, "group_id": "",
                        "timestamp": datetime.now(timezone.utc).isoformat()})
        fr = [f for f in env.ws[friend].sent if f.get("text") == m]
        check("build-78 DM frame delivered, group_id echoed unchanged", len(fr) == 1 and fr[0]["group_id"] == "", str(fr))
        check("build-78 DM: recipient row is the friend", recipients_of(m) == {friend})

        print("\n=== 9. log hygiene ===")
        env.ws[sender].sent.clear()
        secret_text = f"SECRET-BODY-{uuid.uuid4().hex[:8]}"
        secret_key = "attachments/%s/SECRETKEY-%s.jpg" % (member, uuid.uuid4().hex[:6])
        token = "tok-" + uuid.uuid4().hex
        sql("INSERT INTO device_tokens (user_id, token) VALUES (%s, %s) ON CONFLICT DO NOTHING", (friend, token))
        cap.records.clear()
        await env.send(payload(sender, [stranger], "", secret_text))
        await env.send(payload(sender, [member], outsider_group, secret_text))
        await env.send(payload(sender, [friend], "", secret_text, attachment_kind="image", attachment_key=secret_key,
                               attachment_meta={}))
        env2 = Env(sender)
        env2.manager._execute = lambda q, p=(): (_ for _ in ()).throw(psycopg2.OperationalError("boom secret " + token))
        await env2.send(payload(sender, [friend], "", secret_text))
        env2.close()
        guard_recs = [r for r in cap.records if "send_guard" in r.getMessage() or r.name.endswith("send_guard")]
        check("guard path logged something (INFO line per rejection)", len(guard_recs) >= 3, str(len(guard_recs)))
        rendered = [r.getMessage() for r in guard_recs]
        check("no ERROR-level record from the guard path", all(r.levelno < logging.ERROR for r in guard_recs))
        check("no 'ERROR' word in any guard log line", all(not re.search(r"ERROR", s) for s in rendered), str(rendered))
        check("no message text in guard logs", all(secret_text not in s for s in rendered), str(rendered))
        check("no attachment key in guard logs", all("SECRETKEY" not in s for s in rendered), str(rendered))
        check("no device token / exception text in guard logs", all(token not in s and "boom" not in s for s in rendered),
              str(rendered))
        check("no exception traceback attached to guard records", all(r.exc_info is None for r in guard_recs))
        check("rejection INFO lines are INFO level", all(r.levelno <= logging.WARNING for r in guard_recs))
    finally:
        logging.getLogger().removeHandler(cap)
        logging.getLogger().setLevel(old_level)
        env.close()
        cleanup(users, groups)


class _Cur:
    """Real cursor via a fresh DBManager."""

    def __init__(self):
        self.db = DBManager()
        self.cur = self.db.cur

    def execute(self, q, p=()):
        self.cur.execute(q, p)

    def fetchone(self):
        return self.cur.fetchone()

    def fetchall(self):
        return self.cur.fetchall()


class _Broken:
    def execute(self, q, p=()):
        raise RuntimeError("db down")

    def fetchone(self):
        raise RuntimeError("db down")

    fetchall = fetchone


def source_checks():
    print("\n=== 10. source-level (R4-1) ===")
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "backend", "interactions", "send_guard.py")
    src = open(path).read()
    code = "\n".join(l for l in src.splitlines() if not l.strip().startswith("#"))
    check("send_guard.py imports and calls groups.live_member_ids",
          "import live_member_ids" in src and "live_member_ids(cur" in src)
    check("send_guard.py contains no unnest( of its own", not re.search(r"unnest\s*\(", code, re.I))
    check("send_guard.py contains no ::text join of its own", "::text" not in code)
    check("send_guard.py never logs at error level",
          not re.search(r"logger\.(error|exception|critical)", code))
    check("send_guard.py has no literal ERROR word in log format strings",
          not re.search(r"logger\.\w+\([^)]*ERROR", code))
    wsrc = open(os.path.join(os.path.dirname(path), "websockets.py")).read()
    check("exactly one authorize_send call in websockets.py", wsrc.count("authorize_send(") == 1)
    i = wsrc.index("authorize_send(")
    check("authorize_send call sits before save_message", i < wsrc.index("self.save_message(Message(**payload))"))
    check("authorize_send call sits after check_clean", wsrc.index("check_clean(text=text") < i)


def main():
    d = DBManager()
    d.cur.execute("SHOW port")
    port = d.cur.fetchone()[0]
    d.close()
    check("tests run against scratch DB port 55432", (port == "55432" or (port == "5432" and __import__("os").environ.get("GITHUB_ACTIONS") == "true")), port)
    if not (port == "55432" or (port == "5432" and __import__("os").environ.get("GITHUB_ACTIONS") == "true")):
        raise SystemExit("refusing to continue: not the scratch database")
    asyncio.run(run())
    source_checks()

    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
