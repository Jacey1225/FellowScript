"""Backend coverage for task 20260929-announcement-push-widget (testing step 5).

Real routes, real notifier/scheduler job functions, dev Postgres; only
``send_push`` is faked (capturing) so no APNs call is made.

  A. Migration: create_tables() twice is a no-op; push_sent_at,
     creation_push_sent_at and the due-index exist.
  B. Immediate create: exactly one push per eligible member. Author INCLUDED;
     muted, blocked-with-author and no-token members skipped; a failing
     recipient does not abort the others. Payload is identifiers only, body
     is the title (never the description). A later scheduler tick sends nothing.
  C. Future create: "scheduled" heads-up at creation (creation_push_sent_at
     only), nothing from a tick before publish_at, exactly one publish push
     after publish_at, none on re-tick.
  D. Delete before publish cancels the publish push; reschedule (edit
     publish_at) before it fires defers, then fires exactly once.
  E. Atomic claim: concurrent claimers (create-claim and scheduler-claim)
     yield exactly one winner.
  F. Stale cutoff: row older than the cutoff is claimed but not pushed.
  G. Hourly cap (applies to paid authors): at cap still pushes, over cap
     skips the push but the announcement still posts.
  H. Feature flags: ANNOUNCEMENT_PUSH_ENABLED / ANNOUNCEMENTS_ENABLED off ->
     no push and no claim taken.
  I. GET /announcements/latest: member-only (403/401), 7-day window, newest
     wins, deleted / blocked-author / author's own scheduled excluded, route
     is not captured by {announcement_id}, flag off -> 404.
  J. Scheduler job announcement_push_fire is registered.

Run: cd api && ../.venv/bin/python tests/test_announcement_push.py
"""
import _pathfix  # noqa: F401

import asyncio
import os
import threading
import uuid
from datetime import datetime, timedelta, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import backend.interactions.announcements as ann_module  # noqa: E402
import backend.interactions.announcement_notifier as notifier  # noqa: E402
import backend.interactions.push as push_module  # noqa: E402
import backend.interactions.scheduler as scheduler_module  # noqa: E402
import routes.group_announcements as rt  # noqa: E402
from db import DBManager, create_tables  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def ck(token):
    return {"cookie": f"session={token}"} if token else {}


def signup(client, username):
    fake_ip = f"203.0.113.{uuid.uuid4().int % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def sql(query, params=(), fetch=False):
    db = DBManager()
    try:
        db.cur.execute(query, params)
        out = db.cur.fetchall() if fetch else None
        db.conn.commit()
        return out
    finally:
        db.close()


def cleanup(user_ids, group_ids, sub_ids=()):
    db = DBManager()
    try:
        for gid in group_ids:
            db.cur.execute("DELETE FROM group_announcements WHERE group_id = %s", (gid,))
            db.cur.execute("DELETE FROM group_mutes WHERE group_id = %s", (gid,))
            db.cur.execute("DELETE FROM messages WHERE group_id = %s", (gid,))
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM group_announcements WHERE creator_id = %s", (uid,))
            db.cur.execute("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        for sid in sub_ids:
            db.cur.execute("DELETE FROM subscriptions WHERE _id = %s", (sid,))
        db.conn.commit()
    finally:
        db.close()


def create_group(client, token, owner, members):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner}", json={"group_id": gid, "title": "Push Group", "users": [owner, *members]},
                    headers=ck(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def make_paid(uid):
    sid = str(uuid.uuid4())
    sql("INSERT INTO subscriptions (_id, user_id, plan_type, status, current_period_end) "
        "VALUES (%s,%s,'group','active', now() + interval '20 days')", (sid, uid))
    sql("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, uid))
    return sid


def base(u, g):
    return f"/groups/{u}/{g}/announcements"


def past(minutes=5):
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes)).isoformat()


def future(hours=48):
    return (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()


def set_token(uid, token):
    sql("INSERT INTO device_tokens (user_id, token) VALUES (%s,%s) "
        "ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token", (uid, token))


def row(aid):
    r = sql("SELECT push_sent_at, creation_push_sent_at, publish_at FROM group_announcements WHERE _id=%s",
            (aid,), fetch=True)
    return r[0] if r else None


def tick():
    asyncio.run(notifier.fire_due_announcement_pushes())


# ── capturing fake send_push ────────────────────────────────────────────────
SENT = []
FAIL_TOKENS = set()
_real_send_push = push_module.send_push


async def fake_send_push(device_token, title, body, data=None):
    if device_token in FAIL_TOKENS:
        raise RuntimeError("simulated APNs failure")
    SENT.append({"token": device_token, "title": title, "body": body, "data": data})
    return True


def pushes_for(gid):
    return [p for p in SENT if p["data"] and p["data"].get("group_id") == gid]


def clear_sent():
    SENT.clear()


class World:
    """author a (paid, token), m1 (token), m2 (token, muted), m3 (token,
    blocked by author), m4 (no token), m5 (token, push fails), outsider o."""

    def __init__(self, client):
        tag = uuid.uuid4().hex[:8]
        self.users = {}
        for name in ("a", "m1", "m2", "m3", "m4", "m5", "o"):
            uid, tok = signup(client, f"ap_{name}_{tag}")
            self.users[name] = (uid, tok)
        self.sids = [make_paid(self.users["a"][0])]
        self.tok = {n: f"tok-{n}-{tag}" for n in ("a", "m1", "m2", "m3", "m5")}
        for n, t in self.tok.items():
            set_token(self.users[n][0], t)
        self.gid = create_group(client, self.users["a"][1], self.users["a"][0],
                                [self.users[n][0] for n in ("m1", "m2", "m3", "m4", "m5")])
        sql("INSERT INTO group_mutes (group_id, user_id) VALUES (%s,%s)", (self.gid, self.users["m2"][0]))
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)",
            (self.users["a"][0], self.users["m3"][0]))
        self.client = client

    @property
    def a(self):
        return self.users["a"]

    def post(self, **body):
        body.setdefault("title", "Big news")
        body.setdefault("description", "SECRET-DESCRIPTION-TEXT")
        r = self.client.post(base(self.a[0], self.gid), json=body, headers=ck(self.a[1]))
        assert r.status_code == 201, f"{r.status_code} {r.text}"
        return r.json()["id"]

    def close(self):
        cleanup([u for u, _ in self.users.values()], [self.gid], self.sids)


# ── A ───────────────────────────────────────────────────────────────────────
def test_migration(client):
    print("\n== A. migration idempotence ==")
    db = DBManager()
    try:
        create_tables(db.cur)
        create_tables(db.cur)
        db.conn.commit()
        ok = True
    except Exception as e:
        db.conn.rollback()
        ok = False
        check("create_tables() twice without error", False, repr(e))
    finally:
        db.close()
    if not ok:
        return
    check("create_tables() twice without error", True)
    cols = {r[0] for r in sql(
        "SELECT column_name FROM information_schema.columns WHERE table_name='group_announcements'", fetch=True)}
    check("push_sent_at + creation_push_sent_at columns exist",
          {"push_sent_at", "creation_push_sent_at"} <= cols, str(cols))
    idx = sql("SELECT indexdef FROM pg_indexes WHERE tablename='group_announcements'", fetch=True)
    check("partial due-index on push_sent_at exists", any("push_sent_at" in r[0] for r in idx), str(idx))


# ── B ───────────────────────────────────────────────────────────────────────
def test_immediate(client):
    print("\n== B. immediate create push ==")
    w = World(client)
    try:
        clear_sent()
        FAIL_TOKENS.add(w.tok["m5"])
        aid = w.post(title="Immediate one")
        got = pushes_for(w.gid)
        tokens = sorted(p["token"] for p in got)
        want = sorted(w.tok[n] for n in ("a", "m1"))
        check("recipients = author + unmuted/unblocked/tokened members (failing m5 isolated)",
              tokens == want, f"{tokens} vs {want}")
        check("author included", w.tok["a"] in tokens)
        check("muted m2 skipped", w.tok["m2"] not in tokens)
        check("blocked m3 skipped", w.tok["m3"] not in tokens)
        check("no-token m4 caused no failure (only tokened attempted)", len(got) == 2)
        p = got[0] if got else {}
        check("payload identifiers only",
              p.get("data") == {"action": "announcement", "group_id": w.gid, "announcement_id": aid}, str(p.get("data")))
        check("title = group name, body = announcement title",
              p.get("title") == "Push Group" and p.get("body") == "Immediate one", str(p))
        check("description never in push", all("SECRET-DESCRIPTION" not in str(x) for x in got))
        r = row(aid)
        check("push_sent_at set for immediate row", r[0] is not None)
        clear_sent()
        tick()
        tick()
        check("scheduler ticks never re-send an immediate row", pushes_for(w.gid) == [], str(pushes_for(w.gid)))

        clear_sent()
        w.post(title="Past dated", publish_at=past(10))
        check("past publish_at behaves as immediate: single push each",
              sorted(p["token"] for p in pushes_for(w.gid)) == want)
        clear_sent()
        tick()
        check("no re-send for past-dated row", pushes_for(w.gid) == [])
        clear_sent()
        w.post(title="L" * 120)
        # title cap is enforced upstream; body is truncated to the push max
        bodies = [p["body"] for p in pushes_for(w.gid)]
        check("body truncated to push max", all(len(b) <= notifier.ANNOUNCEMENT_PUSH_BODY_MAX for b in bodies), str(bodies))
    finally:
        FAIL_TOKENS.clear()
        w.close()


# ── C ───────────────────────────────────────────────────────────────────────
def test_future(client):
    print("\n== C. future-dated: heads-up at creation, one push at publish ==")
    w = World(client)
    try:
        clear_sent()
        aid = w.post(title="Later one", publish_at=future())
        got = pushes_for(w.gid)
        check("creation heads-up sent to eligible members",
              sorted(p["token"] for p in got) == sorted(w.tok[n] for n in ("a", "m1", "m5")), str(len(got)))
        check("heads-up body prefixed 'New announcement scheduled:'",
              all(p["body"].startswith("New announcement scheduled:") for p in got), str([p["body"] for p in got]))
        check("heads-up excludes muted/blocked",
              not ({w.tok["m2"], w.tok["m3"]} & {p["token"] for p in got}))
        r = row(aid)
        check("creation_push_sent_at set, push_sent_at still NULL", r[1] is not None and r[0] is None, str(r))
        clear_sent()
        tick()
        check("tick before publish_at sends nothing", pushes_for(w.gid) == [])
        sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute' WHERE _id=%s", (aid,))
        tick()
        got = pushes_for(w.gid)
        check("exactly one publish push per member after publish_at",
              sorted(p["token"] for p in got) == sorted(w.tok[n] for n in ("a", "m1", "m5")), str(len(got)))
        check("publish push body = plain title", all(p["body"] == "Later one" for p in got))
        check("publish push payload identifiers only",
              all(p["data"] == {"action": "announcement", "group_id": w.gid, "announcement_id": aid} for p in got))
        check("push_sent_at set after publish push", row(aid)[0] is not None)
        clear_sent()
        tick()
        tick()
        check("further ticks never double send", pushes_for(w.gid) == [])
    finally:
        w.close()


# ── D ───────────────────────────────────────────────────────────────────────
def test_delete_reschedule(client):
    print("\n== D. delete / reschedule before publish ==")
    w = World(client)
    try:
        clear_sent()
        aid = w.post(title="Will be deleted", publish_at=future())
        clear_sent()
        r = client.delete(f"{base(w.a[0], w.gid)}/{aid}", headers=ck(w.a[1]))
        check("delete ok", r.status_code in (200, 204), f"{r.status_code} {r.text}")
        sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute' WHERE _id=%s", (aid,))
        tick()
        check("deleted-before-publish row is never pushed", pushes_for(w.gid) == [])
        check("deleted row's push_sent_at stays NULL", row(aid)[0] is None)

        aid2 = w.post(title="Will move", publish_at=future(24))
        clear_sent()
        r = client.patch(f"{base(w.a[0], w.gid)}/{aid2}", json={"publish_at": future(72)}, headers=ck(w.a[1]))
        if r.status_code == 405:
            r = client.put(f"{base(w.a[0], w.gid)}/{aid2}", json={"publish_at": future(72)}, headers=ck(w.a[1]))
        check("reschedule accepted", r.status_code == 200, f"{r.status_code} {r.text}")
        tick()
        check("rescheduled row not pushed early", pushes_for(w.gid) == [])
        sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute' WHERE _id=%s", (aid2,))
        tick()
        tick()
        check("rescheduled row pushed exactly once at its new time",
              len(pushes_for(w.gid)) == 3, str(len(pushes_for(w.gid))))
    finally:
        w.close()


# ── E ───────────────────────────────────────────────────────────────────────
def test_atomic_claim(client):
    print("\n== E. atomic claim, no double send ==")
    w = World(client)
    try:
        # Create-claim race on an immediate row that never had its push claimed.
        flag = notifier.ANNOUNCEMENT_PUSH_ENABLED
        notifier.ANNOUNCEMENT_PUSH_ENABLED = False
        try:
            aid = w.post(title="Race create")
        finally:
            notifier.ANNOUNCEMENT_PUSH_ENABLED = flag
        results = []
        barrier = threading.Barrier(6)

        def worker():
            db = DBManager()
            try:
                barrier.wait()
                results.append(notifier._claim_on_create(db, aid))
            finally:
                db.close()

        ts = [threading.Thread(target=worker) for _ in range(6)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        winners = [r for r in results if r]
        check("6 concurrent create-claims -> exactly one winner", len(winners) == 1, str(len(winners)))

        # Scheduler-claim race on a due future row.
        aid2 = w.post(title="Race tick", publish_at=future())
        sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute' WHERE _id=%s", (aid2,))
        results2 = []
        barrier2 = threading.Barrier(6)

        def worker2():
            db = DBManager()
            try:
                barrier2.wait()
                results2.append([str(r[0]) for r in notifier._claim_due(db)])
            finally:
                db.close()

        ts = [threading.Thread(target=worker2) for _ in range(6)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        n = sum(1 for lst in results2 if aid2 in lst)
        check("6 concurrent scheduler claims -> row claimed exactly once", n == 1, str(n))

        # Concurrent full job runs => still one push per member.
        aid3 = w.post(title="Race full", publish_at=future())
        sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute' WHERE _id=%s", (aid3,))
        clear_sent()
        ts = [threading.Thread(target=tick) for _ in range(4)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        mine = [p for p in pushes_for(w.gid) if p["data"]["announcement_id"] == aid3]
        check("4 concurrent job runs -> one push per member (3)", len(mine) == 3, str(len(mine)))
    finally:
        w.close()


# ── F ───────────────────────────────────────────────────────────────────────
def test_stale(client):
    print("\n== F. stale cutoff ==")
    w = World(client)
    try:
        aid = w.post(title="Old", publish_at=future())
        clear_sent()
        cutoff = notifier.ANNOUNCEMENT_PUSH_STALE_AFTER_SECONDS
        sql("UPDATE group_announcements SET publish_at = now() - make_interval(secs => %s) WHERE _id=%s",
            (cutoff + 600, aid))
        tick()
        check("stale row claimed but not pushed", row(aid)[0] is not None and pushes_for(w.gid) == [])
        aid2 = w.post(title="Fresh enough", publish_at=future())
        clear_sent()
        sql("UPDATE group_announcements SET publish_at = now() - make_interval(secs => %s) WHERE _id=%s",
            (max(cutoff - 600, 60), aid2))
        tick()
        check("row just inside cutoff still pushes", len(pushes_for(w.gid)) == 3, str(len(pushes_for(w.gid))))
    finally:
        w.close()


# ── G ───────────────────────────────────────────────────────────────────────
def test_cap(client):
    print("\n== G. per-group hourly cap ==")
    w = World(client)
    try:
        cap = notifier.ANNOUNCEMENT_PUSH_GROUP_HOURLY_CAP
        for i in range(cap - 1):
            sql("INSERT INTO group_announcements (group_id, creator_id, title, description, publish_at, push_sent_at) "
                "VALUES (%s,%s,%s,'',now(), now())", (w.gid, w.a[0], f"prior {i}"))
        clear_sent()
        w.post(title="At cap")
        check("announcement number == cap still pushes", len(pushes_for(w.gid)) == 3, str(len(pushes_for(w.gid))))
        clear_sent()
        aid = w.post(title="Over cap")
        check("announcement over cap: push skipped", pushes_for(w.gid) == [], str(len(pushes_for(w.gid))))
        check("over-cap announcement still posted (paid author)",
              sql("SELECT count(*) FROM group_announcements WHERE _id=%s AND deleted_at IS NULL", (aid,),
                  fetch=True)[0][0] == 1)
    finally:
        w.close()


# ── H ───────────────────────────────────────────────────────────────────────
def test_flags(client):
    print("\n== H. feature flags ==")
    w = World(client)
    try:
        for name, mod, attr in (("ANNOUNCEMENT_PUSH_ENABLED", notifier, "ANNOUNCEMENT_PUSH_ENABLED"),
                                ("ANNOUNCEMENTS_ENABLED", ann_module, "ANNOUNCEMENTS_ENABLED")):
            old = getattr(mod, attr)
            setattr(mod, attr, False)
            try:
                clear_sent()
                aid = w.post(title=f"flag {name}")
                tick()
                check(f"{name}=False -> no push", pushes_for(w.gid) == [])
                check(f"{name}=False -> no claim taken", row(aid)[0] is None and row(aid)[1] is None, str(row(aid)))
            finally:
                setattr(mod, attr, old)
        # flags restored: the pending immediate rows are recent, so a tick delivers them once
        clear_sent()
        tick()
        check("re-enabled: pending rows deliver on next tick", len(pushes_for(w.gid)) >= 2)
    finally:
        w.close()


# ── I ───────────────────────────────────────────────────────────────────────
def test_latest(client):
    print("\n== I. GET /announcements/latest ==")
    w = World(client)
    try:
        notifier_flag = notifier.ANNOUNCEMENT_PUSH_ENABLED
        notifier.ANNOUNCEMENT_PUSH_ENABLED = False  # keep this section push-free
        a, ta = w.a
        m1, t1 = w.users["m1"]
        o, to = w.users["o"]
        url = base(m1, w.gid) + "/latest"
        r = client.get(url, headers=ck(t1))
        check("no announcements -> 200 {announcement: null}", r.status_code == 200 and r.json() == {"announcement": None},
              f"{r.status_code} {r.text}")
        check("non-member -> 403", client.get(base(o, w.gid) + "/latest", headers=ck(to)).status_code == 403)
        check("unauthenticated -> 401", client.get(url).status_code == 401)
        check("spoofed user_id -> 403", client.get(base(a, w.gid) + "/latest", headers=ck(t1)).status_code == 403)

        def ins(title, publish_sql, creator=a, deleted=False):
            return str(sql(
                "INSERT INTO group_announcements (group_id, creator_id, title, description, publish_at, deleted_at) "
                f"VALUES (%s,%s,%s,'', {publish_sql}, {'now()' if deleted else 'NULL'}) RETURNING _id",
                (w.gid, creator, title), fetch=True)[0][0])

        ins("eight days old", "now() - interval '8 days'")
        r = client.get(url, headers=ck(t1))
        check("8-day-old announcement outside window -> null", r.json()["announcement"] is None, r.text)
        old6 = ins("six days old", "now() - interval '6 days'")
        r = client.get(url, headers=ck(t1))
        check("6-day-old announcement inside window", (r.json()["announcement"] or {}).get("id") == old6, r.text)
        new1 = ins("newer", "now() - interval '1 hour'")
        r = client.get(url, headers=ck(t1))
        check("newest published wins", r.json()["announcement"]["id"] == new1, r.text)
        ins("deleted newest", "now() - interval '5 minutes'", deleted=True)
        ins("future", "now() + interval '1 day'")
        r = client.get(url, headers=ck(t1))
        check("deleted and future-dated rows excluded", r.json()["announcement"]["id"] == new1, r.text)
        r = client.get(base(a, w.gid) + "/latest", headers=ck(ta))
        check("author's own still-scheduled row not returned", r.json()["announcement"]["id"] == new1, r.text)
        check("'latest' not captured by {announcement_id} route (no 404/422)", r.status_code == 200)
        # blocked author
        bid = ins("from m2", "now() - interval '2 minutes'", creator=w.users["m2"][0])
        r = client.get(url, headers=ck(t1))
        check("m2's newest visible to m1 before block", r.json()["announcement"]["id"] == bid, r.text)
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (m1, w.users["m2"][0]))
        r = client.get(url, headers=ck(t1))
        check("blocked author's announcement excluded (falls back)", r.json()["announcement"]["id"] == new1, r.text)
        # feature flag
        rt.ANNOUNCEMENTS_ENABLED = False
        try:
            check("flag off -> 404", client.get(url, headers=ck(t1)).status_code == 404)
        finally:
            rt.ANNOUNCEMENTS_ENABLED = True
        # regular id route still works
        r = client.get(f"{base(m1, w.gid)}/{new1}", headers=ck(t1))
        check("{announcement_id} route still resolves ids", r.status_code == 200 and r.json()["id"] == new1, r.text)
        notifier.ANNOUNCEMENT_PUSH_ENABLED = notifier_flag
    finally:
        notifier.ANNOUNCEMENT_PUSH_ENABLED = True
        w.close()


# ── J ───────────────────────────────────────────────────────────────────────
def test_scheduler_registered(client):
    print("\n== J. scheduler registration ==")
    jobs = {j.id: j for j in scheduler_module.scheduler.get_jobs()}
    check("announcement_push_fire registered", "announcement_push_fire" in jobs, str(list(jobs)))
    j = jobs.get("announcement_push_fire")
    if j:
        check("interval = ANNOUNCEMENT_PUSH_POLL_INTERVAL_SECONDS",
              j.trigger.interval.total_seconds() == notifier.ANNOUNCEMENT_PUSH_POLL_INTERVAL_SECONDS,
              str(j.trigger))


def main():
    push_module.send_push = fake_send_push
    try:
        with TestClient(main_module.app) as client:
            test_migration(client)
            test_immediate(client)
            test_future(client)
            test_delete_reschedule(client)
            test_atomic_claim(client)
            test_stale(client)
            test_cap(client)
            test_flags(client)
            test_latest(client)
            test_scheduler_registered(client)
    finally:
        push_module.send_push = _real_send_push

    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
