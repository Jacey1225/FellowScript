"""Tests for task 20261001-explorer-join-requests, lifecycle hooks, sweeper, notifier, logging.

Properties proved (each would catch a regression of the behaviour it names):
  1. Hooks are registered by registrations.load_all: listing_hidden handler is
     fn(cur, group_id, reason); creator leaving expires pending requests (a plain
     member leaving does not); group delete and last-member leave remove the
     rows (FK cascade); user_delete expires requests for groups the user created
     and the applicant's own rows go with the account; a real listing sweep that
     hides a suspended owner's listing expires its pending requests.
  2. Sweeper: expires aged and ownerless pending rows, purges decided rows past
     max(retention, cooldown) but never inside the window, keeps denied+block_reapply
     rows with the note cleared, runs with join_requests OFF, is a thin async
     wrapper over run_in_executor (loop stays responsive while 0.8 s of blocking
     work runs; no psycopg2/DBManager in the async body), is registered with ONE
     add_job in the scheduler, logs INFO with counts or one WARNING on failure,
     never an ERROR-trap line, never ids/notes.
  3. Notifier: owner push only when join_request_push is on for the OWNER, one per
     group per window with an atomic claim (concurrent requests -> one push), no
     token / flag off never burns the window, generic copy with no applicant data,
     data = action + group_id only, approved push only after an approval that
     appended the member, never on deny/withdraw/expiry, failures isolated and
     logged as WARNING without ERROR.
  4. Logging: no PII (username, note, title, applicant id) in any line; no line the
     watchdog's error-signal regex would flag.

Scratch DB only (asserts SHOW port = 55432 first).
"""
import _pathfix  # noqa: F401

import ast
import asyncio
import inspect
import logging
import os
import re
import threading
import time

import _jrq_common as J
from _jrq_common import check, decide, make_listing, make_user, members, req, req_status, sql
from backend.interactions import (join_request_notifier as N, join_request_sweeper as S, lifecycle, listing_sweeper,
                                  push)
from backend.interactions.groups import GroupsManager
from backend.rate_limiting import limiter
from db import DBManager

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def pending(cli, pid):
    u = make_user("ap")
    r = req(cli, u, pid)
    assert r.status_code == 201, r.text
    return u, r.json()["id"]


def run_hook(kind, *args):
    db = DBManager()
    try:
        out = lifecycle.run(kind, db.cur, *args)
        db.conn.commit()
        return out
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


def test_hooks(cli):
    print("lifecycle hooks")
    names = {k: [f.__name__ for f in lifecycle.hooks(k)] for k in ("member_leave", "user_delete", "listing_hidden")}
    check("load_all registered the JRQ hooks (member_leave, user_delete, listing_hidden)",
          "expire_requests_when_owner_leaves" in names["member_leave"]
          and "expire_requests_of_deleted_owner" in names["user_delete"]
          and "expire_requests_when_listing_hidden" in names["listing_hidden"], names)
    fn = next(f for f in lifecycle.hooks("listing_hidden") if f.__name__ == "expire_requests_when_listing_hidden")
    check("listing_hidden handler is fn(cur, group_id, reason)",
          list(inspect.signature(fn).parameters) == ["cur", "group_id", "reason"], inspect.signature(fn))
    check("the wiring module is imported by registrations.load_all (one line)",
          "join_requests_wiring" in open(os.path.join(API_DIR, "backend/registrations.py")).read())
    check("hooks return no S3 keys", run_hook("listing_hidden", "00000000-0000-0000-0000-000000000000", "x") == [])

    owner, member, member_b = make_user("ow"), make_user("ow"), make_user("ow")
    gid, pid = make_listing(owner, [member, member_b])
    other_g, other_p = make_listing(make_user("ow"))
    J.set_flags(owner)
    a, ra = pending(cli, pid)
    o_u, ro = pending(cli, other_p)
    run_hook("listing_hidden", gid, "reported")
    check("listing_hidden expires that group's pending requests",
          req_status(ra) == "expired" and sql("SELECT decided_at IS NOT NULL FROM group_join_requests WHERE id = %s", (ra,))[0][0])
    check("...and only that group's", req_status(ro) == "pending")

    # plain member leaves: nothing expires; creator leaves: expires
    b, rb = pending(cli, pid)
    G = GroupsManager(member, gid)
    G.leave_group()
    G.close()
    check("a plain member leaving does not expire pending requests", req_status(rb) == "pending")
    G = GroupsManager(owner, gid)
    G.leave_group()
    G.close()
    check("the creator leaving expires pending requests (group survives, nobody can approve)",
          req_status(rb) == "expired" and sql("SELECT count(*) FROM groups WHERE _id = %s", (gid,))[0][0] == 1)

    # group delete cascades
    g2, p2 = make_listing(make_user("ow"))
    o2 = sql("SELECT creator_id::text FROM groups WHERE _id = %s", (g2,))[0][0]
    J.set_flags(o2)
    c, rc = pending(cli, p2)
    G = GroupsManager(o2, g2)
    G.delete_group()
    G.close()
    check("group delete removes its requests (FK cascade)",
          sql("SELECT count(*) FROM group_join_requests WHERE id = %s", (rc,))[0][0] == 0)
    # last-member leave deletes the group and the rows
    o3 = make_user("ow")
    g3, p3 = make_listing(o3)
    J.set_flags(o3)
    d, rd = pending(cli, p3)
    G = GroupsManager(o3, g3)
    G.leave_group()
    G.close()
    check("last-member leave deletes the group and its requests",
          sql("SELECT count(*) FROM groups WHERE _id = %s", (g3,))[0][0] == 0
          and sql("SELECT count(*) FROM group_join_requests WHERE id = %s", (rd,))[0][0] == 0)

    # user delete: owner's groups' pending expire; applicant's own rows cascade
    o4 = make_user("ow")
    g4, p4 = make_listing(o4, [make_user("ow")])
    o5 = make_user("ow")
    g5, p5 = make_listing(o5)
    J.set_flags(o4)
    e, re_ = pending(cli, p4)
    f, rf = pending(cli, p5)
    hook = next(f for f in lifecycle.hooks("user_delete") if f.__name__ == "expire_requests_of_deleted_owner")
    db = DBManager()
    hook(db.cur, o4)  # directly, owner still a member: the JRQ hook alone must expire
    db.conn.commit()
    db.close()
    check("user_delete expires pending requests for groups the user created",
          req_status(re_) == "expired")
    check("user_delete leaves other owners' requests alone", req_status(rf) == "pending")
    sql("DELETE FROM users WHERE _id = %s", (f,))
    check("a deleted applicant's own requests are removed (FK cascade)",
          sql("SELECT count(*) FROM group_join_requests WHERE id = %s", (rf,))[0][0] == 0)

    # end to end: the listing sweeper hides a suspended owner's listing and fires listing_hidden
    o6 = make_user("ow")
    g6, p6 = make_listing(o6)
    J.set_flags(o6)
    h, rh = pending(cli, p6)
    sql("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (o6,))
    listing_sweeper.sweep_once(batch_size=500)
    check("real listing sweep (owner suspended) hides the listing and expires its pending requests",
          sql("SELECT status FROM group_listings WHERE group_id = %s", (g6,))[0][0] != "published"
          and req_status(rh) == "expired")


def aged(rid, days):
    sql("UPDATE group_join_requests SET created_at = NOW() - make_interval(days => %s) WHERE id = %s", (days, rid))


def test_sweeper(cli, cap):
    print("sweeper")
    owner = make_user("ow")
    gid, pid = make_listing(owner)
    J.set_flags(owner, "off", "off")  # the sweeper must run with the flag OFF
    mk = lambda status, created_days=1, decided_days=None, block=False, note=None: _insert(gid, status, created_days, decided_days, block, note)
    old_pending = mk("pending", created_days=40)
    fresh_pending = mk("pending", created_days=5)
    old_denied = mk("denied", 200, 100)
    young_denied = mk("denied", 60, 50)
    old_approved = mk("approved", 200, 100)
    old_withdrawn = mk("withdrawn", 200, 100)
    old_expired = mk("expired", 200, 100)
    blocked = mk("denied", 400, 100, block=True, note="a note")
    young_blocked = mk("denied", 60, 5, block=True, note="young note")
    cap.clear()
    counts = S.sweep_once()
    check("sweep reports no failures", counts["failed"] == 0, counts)
    check("aged pending (40 d > 30 d) expired; fresh pending untouched",
          req_status(old_pending) == "expired" and req_status(fresh_pending) == "pending", counts)
    gone = [req_status(x) for x in (old_denied, old_approved, old_withdrawn, old_expired)]
    check("decided rows past retention (90 d) are purged", gone == [None] * 4, gone)
    check("a decided row inside retention (50 d) is kept", req_status(young_denied) == "denied")
    check("denied + block_reapply past retention is KEPT, its note cleared",
          sql("SELECT status, block_reapply, note FROM group_join_requests WHERE id = %s", (blocked,))[0] == ("denied", True, None))
    check("a young block_reapply row keeps its note",
          sql("SELECT note FROM group_join_requests WHERE id = %s", (young_blocked,))[0][0] == "young note")
    check("counts match what changed", counts["expired_aged"] >= 1 and counts["purged"] >= 4 and counts["cleared"] >= 1, counts)
    check("an active sweep logs one INFO line with counts and no ids/notes",
          any(r.levelname == "INFO" and r.getMessage().startswith("JOIN_REQUEST_SWEEP ") for r in cap.records)
          and not any(gid in ln or "a note" in ln for ln in cap.lines if "JOIN_REQUEST_SWEEP" in ln))
    check("the sweep logged nothing the watchdog flags", not cap.watchdog_hits(), cap.watchdog_hits()[:2])

    # ownerless backstop
    o2 = make_user("ow")
    g2, p2 = make_listing(o2)
    ownerless = _insert(g2, "pending", 1, None, False, None)
    owner_gone = _insert(g2, "pending", 1, None, False, None, user=make_user("ap"))
    sql("UPDATE groups SET creator_id = NULL WHERE _id = %s", (g2,))
    S.sweep_once()
    check("pending rows of an ownerless group are expired by the backstop",
          req_status(ownerless) == "expired" and req_status(owner_gone) == "expired")
    g3o = make_user("ow")
    g3, _ = make_listing(g3o)
    left = _insert(g3, "pending", 1, None, False, None)
    sql("UPDATE groups SET users = array_remove(users, %s) WHERE _id = %s", (g3o, g3))
    S.sweep_once()
    check("pending rows of a group whose creator left the member list are expired", req_status(left) == "expired")
    # cooldown floor: retention shorter than cooldown never purges inside the cooldown window
    young = _insert(g3, "denied", 30, 10, False, None)
    try:
        J.override_cfg(retention_days=5, cooldown_days=14)
        S.sweep_once()
        check("a decided row inside the cooldown window survives", req_status(young) == "denied")
    finally:
        J.restore_cfg()

    # failure path: ONE aggregated WARNING, no ERROR trap, other passes still run
    real = S._run_pass
    calls = []

    def flaky(db, sql_text, params):
        calls.append(sql_text[:30])
        if len(calls) == 1:
            raise RuntimeError("boom with secret-note")
        return real(db, sql_text, params)

    S._run_pass = flaky
    cap.clear()
    try:
        counts = S.sweep_once()
    finally:
        S._run_pass = real
    check("one failing pass is counted and the rest still ran", counts["failed"] == 1 and len(calls) == 4, (counts, calls))
    warns = [r for r in cap.records if r.levelname == "WARNING" and "JOIN_REQUEST_SWEEP" in r.getMessage()]
    check("a failure logs exactly one WARNING, never ERROR; no exception text leaked",
          len(warns) == 1 and "secret-note" not in "\n".join(cap.lines) and not cap.watchdog_hits(), (len(warns), cap.watchdog_hits()))

    # R-SCHED: thin async wrapper
    tree = ast.parse(open(os.path.join(API_DIR, "backend/interactions/join_request_sweeper.py")).read())
    job = next(n for n in tree.body if isinstance(n, ast.AsyncFunctionDef) and n.name == "run_join_request_sweeper_job")
    body_src = ast.unparse(job)
    check("R-SCHED: job is async def and calls loop.run_in_executor",
          "run_in_executor" in body_src and "sweep_once" in body_src)
    check("R-SCHED: no DBManager / psycopg2 / cursor call inside the async body",
          not re.search(r"DBManager|psycopg2|\.cur\b|\.execute\(|\.commit\(", body_src), body_src[:200])
    check("R-SCHED: the async body is thin (<= 12 statements)", sum(1 for _ in ast.walk(job) if isinstance(_, ast.stmt)) <= 12)
    sched = open(os.path.join(API_DIR, "backend/interactions/scheduler.py")).read()
    check("the scheduler registers the job with exactly one add_job",
          sched.count("add_job(run_join_request_sweeper_job") == 1 and "replace_existing=True" in sched)
    lag = []

    async def probe():
        real_sweep = S.sweep_once
        S.sweep_once = lambda: (time.sleep(0.8), {})[1]
        try:
            stop = asyncio.Event()

            async def ticker():
                last = time.perf_counter()
                while not stop.is_set():
                    await asyncio.sleep(0.02)
                    now = time.perf_counter()
                    lag.append(now - last)
                    last = now

            t = asyncio.create_task(ticker())
            await S.run_join_request_sweeper_job()
            stop.set()
            await t
        finally:
            S.sweep_once = real_sweep

    asyncio.run(probe())
    check("event loop stays responsive while 0.8 s of blocking work runs (max lag < 0.5 s)",
          lag and max(lag) < 0.5, max(lag) if lag else None)
    real_sweep = S.sweep_once
    S.sweep_once = lambda: (_ for _ in ()).throw(RuntimeError("db down: secret"))
    cap.clear()
    try:
        asyncio.run(S.run_join_request_sweeper_job())
        ok = True
    except Exception:
        ok = False
    finally:
        S.sweep_once = real_sweep
    check("a crashed run never raises out of the job; it logs one WARNING with the exception type only",
          ok and [r.levelname for r in cap.records if "JOIN_REQUEST_SWEEP" in r.getMessage()] == ["WARNING"]
          and "secret" not in "\n".join(cap.lines) and not cap.watchdog_hits(), cap.lines[-2:])
    from backend.observability import feature_summary
    check("pending_join_requests gauge is the real count (not the placeholder lambda)",
          feature_summary._gauges["pending_join_requests"] is S.pending_count
          and isinstance(S.pending_count(), int))
    J.set_flags(owner)


def _insert(gid, status, created_days, decided_days, block, note, user=None):
    u = user or make_user("ap")
    r = sql("INSERT INTO group_join_requests (group_id, user_id, status, created_at, decided_at, block_reapply, note) "
            "VALUES (%s,%s,%s, NOW() - make_interval(days => %s), "
            "CASE WHEN %s::int IS NULL THEN NULL ELSE NOW() - make_interval(days => %s::int) END, %s, %s) RETURNING id::text",
            (gid, u, status, created_days, decided_days, decided_days, block, note))
    return r[0][0]


class FakePush:
    def __init__(self):
        self.sent = []
        self.mode = "ok"

    async def __call__(self, token, title, body, data=None):
        if self.mode == "raise":
            raise RuntimeError("apns exploded with secret")
        if self.mode == "false":
            return False
        self.sent.append((token, title, body, data))
        return True


def test_notifier(cli, cap):
    print("notifier")
    fake = FakePush()
    real = push.send_push
    push.send_push = fake
    try:
        owner = make_user("ow")
        gid, pid = make_listing(owner, title="Quokka Prayer Circle")
        sql("INSERT INTO device_tokens (user_id, token) VALUES (%s, %s)", (owner, "tok-owner"))
        # push flag OFF: nothing, and the window is not burned
        J.set_flags(owner, push="off")
        a, ra = pending(cli, pid)
        time.sleep(0.3)
        check("join_request_push off: no push", fake.sent == [], fake.sent)
        check("a flag-off run never burns the window (owner_notified_at stays NULL)",
              sql("SELECT owner_notified_at FROM group_join_requests WHERE id = %s", (ra,))[0][0] is None)
        # on, but owner has no token
        no_tok = make_user("ow")
        g2, p2 = make_listing(no_tok)
        J.set_flags(no_tok, push="on")
        b, rb = pending(cli, p2)
        time.sleep(0.3)
        check("no device token: no push and the window is not burned",
              fake.sent == [] and sql("SELECT owner_notified_at FROM group_join_requests WHERE id = %s", (rb,))[0][0] is None)
        # on, with token: one push, generic copy
        J.set_flags(owner, push="on")
        c = make_user("ap")
        sql("UPDATE users SET username = 'visible_applicant_zz' WHERE _id = %s", (c,))
        limiter.reset()
        r = req(cli, c, pid, note="my private note kiwi")
        time.sleep(0.5)
        check("new request after commit pushes the owner once",
              r.status_code == 201 and len(fake.sent) == 1 and fake.sent[0][0] == "tok-owner", fake.sent)
        tok, title, body, data = fake.sent[0]
        check("push data carries only action and group_id", data == {"action": "join_request", "group_id": gid}, data)
        check("push copy is generic: no applicant name, note or request id",
              "visible_applicant_zz" not in body + title and "kiwi" not in body + title and r.json()["id"] not in body + title
              and body == N.OWNER_BODY and title == "Quokka Prayer Circle", (title, body))
        d, rd = pending(cli, pid)
        time.sleep(0.4)
        check("a second request inside the window is not pushed (claim is per group per window)", len(fake.sent) == 1, fake.sent)
        sql("UPDATE group_join_requests SET owner_notified_at = NOW() - interval '31 minutes' WHERE group_id = %s", (gid,))
        e, re_ = pending(cli, pid)
        time.sleep(0.4)
        check("after the window passes the next request pushes again", len(fake.sent) == 2, len(fake.sent))
        # atomic claim under concurrency
        sql("UPDATE group_join_requests SET owner_notified_at = NULL WHERE group_id = %s", (gid,))
        before = len(fake.sent)
        ids = [pending(cli, pid)[1] for _ in range(3)]
        sql("UPDATE group_join_requests SET owner_notified_at = NULL WHERE group_id = %s", (gid,))
        before = len(fake.sent)

        async def burst():
            await asyncio.gather(*(N.notify_owner_of_request(i) for i in ids))

        asyncio.run(burst())
        check("concurrent notifications for one group yield exactly ONE push (atomic claim)",
              len(fake.sent) - before == 1, len(fake.sent) - before)
        # owner suspended / gone -> nothing
        sql("UPDATE group_join_requests SET owner_notified_at = NULL WHERE group_id = %s", (gid,))
        before = len(fake.sent)
        sql("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (owner,))
        asyncio.run(N.notify_owner_of_request(ids[0]))
        sql("UPDATE users SET suspended_at = NULL WHERE _id = %s", (owner,))
        check("suspended owner is not notified", len(fake.sent) == before)
        check("non-pending request id: nothing, no raise",
              asyncio.run(N.notify_owner_of_request("not-a-uuid")) is None
              and asyncio.run(N.notify_owner_of_request("00000000-0000-0000-0000-000000000000")) is None)

        # approved push: only after an approval that appended
        sql("INSERT INTO device_tokens (user_id, token) VALUES (%s, %s)", (c, "tok-applicant"))
        rc = r.json()["id"]
        before = len(fake.sent)
        asyncio.run(N.notify_requester_approved(rc))
        check("approved push is not sent for a request that is still pending", len(fake.sent) == before)
        decide(cli, owner, gid, rc, "approve")
        time.sleep(0.5)
        got = [s for s in fake.sent if s[0] == "tok-applicant"]
        check("approval that appended the member pushes the applicant once, generic copy, action+group_id only",
              len(got) == 1 and got[0][2] == N.APPROVED_BODY and got[0][3] == {"action": "join_request", "group_id": gid}, got)
        decide(cli, owner, gid, rc, "approve")
        time.sleep(0.4)
        check("an idempotent second approve does not push again", len([s for s in fake.sent if s[0] == "tok-applicant"]) == 1)
        # deny / withdraw never push the applicant
        sql("INSERT INTO device_tokens (user_id, token) VALUES (%s, %s)", (d, "tok-d"))
        decide(cli, owner, gid, rd, "deny", json={})
        asyncio.run(N.notify_requester_approved(rd))
        w = make_user("ap")
        sql("INSERT INTO device_tokens (user_id, token) VALUES (%s, %s)", (w, "tok-w"))
        rw = req(cli, w, pid).json()["id"]
        J.call(cli, "post", f"/join-requests/{w}/requests/{rw}/withdraw", w)
        asyncio.run(N.notify_requester_approved(rw))
        time.sleep(0.3)
        check("deny and withdraw never push the applicant", not [s for s in fake.sent if s[0] in ("tok-d", "tok-w")])

        # failures are isolated
        sql("UPDATE group_join_requests SET owner_notified_at = NULL WHERE group_id = %s", (gid,))
        cap.clear()
        fake.mode = "raise"
        x = make_user("ap")
        rx = req(cli, x, pid).json()["id"]
        sql("UPDATE group_join_requests SET owner_notified_at = NULL WHERE group_id = %s", (gid,))
        try:
            asyncio.run(N.notify_owner_of_request(rx))
            raised = False
        except Exception:
            raised = True
        check("push provider exception never propagates", not raised)
        sql("UPDATE group_join_requests SET owner_notified_at = NULL WHERE group_id = %s", (gid,))
        fake.mode = "false"
        asyncio.run(N.notify_owner_of_request(rx))
        notif = [r for r in cap.records if "JOIN_REQUEST_PUSH" in r.getMessage()]
        check("failed sends log WARNING lines only (RuntimeError type name, no message text)",
              notif and all(r.levelname == "WARNING" for r in notif) and "secret" not in "\n".join(cap.lines)
              and "tok-owner" not in "\n".join(cap.lines), [(r.levelname, r.getMessage()) for r in notif])
        check("no watchdog trap line from notifier failures", not cap.watchdog_hits(), cap.watchdog_hits()[:2])
    finally:
        push.send_push = real
        fake.mode = "ok"
    src = open(os.path.join(API_DIR, "backend/interactions/join_request_notifier.py")).read()
    tree = ast.parse(src)
    pubs = [n for n in tree.body if isinstance(n, ast.AsyncFunctionDef)]
    check("R-SCHED: public notifier coroutines run DB work via run_in_executor only",
          {p.name for p in pubs} >= {"notify_owner_of_request", "notify_requester_approved", "_deliver"}
          and "run_in_executor" in src
          and not any(re.search(r"DBManager|\.cur\b|psycopg2", ast.unparse(p)) for p in pubs))


def test_logging_pii(cli, cap):
    print("logging: no PII end to end")
    owner = make_user("ow")
    gid, pid = make_listing(owner, title="Zebra Title Secret")
    J.set_flags(owner)
    a = make_user("ap")
    uname = sql("SELECT username FROM users WHERE _id = %s", (a,))[0][0]
    cap.clear()
    rid = req(cli, a, pid, note="very private note xylophone").json()["id"]
    decide(cli, owner, gid, rid, "deny", json={"block_reapply": True})
    decide(cli, owner, gid, rid, "undo-deny")
    decide(cli, owner, gid, rid, "approve")
    J.call(cli, "put", f"/join-requests/{owner}/groups/{gid}/accepting", owner, json={"accepting": False})
    S.sweep_once()
    text = "\n".join(ln for ln in cap.lines if "HTTP Request" not in ln)
    check("no username, note, group title or applicant id in any application log line",
          uname not in text and "xylophone" not in text and "Zebra Title" not in text and a not in text, [ln for ln in cap.lines if a in ln][:1])
    check("audit lines exist for create/deny/undo_deny/approve/accepting_off",
          all(f"event={e} " in text for e in ("create", "deny", "undo_deny", "approve", "accepting_off")))
    check("no line from the whole flow trips the watchdog error-signal regex", not cap.watchdog_hits(), cap.watchdog_hits()[:3])
    check("only INFO-level records from JOIN_REQUEST audit/busy lines",
          all(r.levelname == "INFO" for r in cap.records if "JOIN_REQUEST" in r.getMessage()))


def test_route_grep():
    print("R-ROUTE / structure grep checks")
    routes = open(os.path.join(API_DIR, "routes/join_requests.py")).read()
    mgr = open(os.path.join(API_DIR, "backend/interactions/join_requests.py")).read()
    check("R-ROUTE: no async def or await in the route module", not re.search(r"async def|await ", routes))
    check("R-ROUTE: routes only call manager methods, no raw SQL or DB imports",
          not re.search(r"cur\.execute|DBManager|import psycopg2", routes))
    check("lock waits are bounded: every locking transaction arms lock_timeout via set_config",
          mgr.count("self._begin()") >= 6 and "set_config('lock_timeout'" in mgr)
    check("55P03 is caught around the module's OWN cur.execute (no DBManager insert/update helper)",
          "LockNotAvailable" in mgr and not re.search(r"\.insert\(|\.update\(|insert_row|update_row", mgr))
    check("the busy path logs at INFO", 'logger.info("JOIN_REQUEST busy' in mgr)
    check("no logger.error/exception/critical in any JRQ module",
          not any(re.search(r"logger\.(error|exception|critical)\(", open(os.path.join(API_DIR, p)).read())
                  for p in ("routes/join_requests.py", "backend/interactions/join_requests.py",
                            "backend/interactions/join_request_sweeper.py",
                            "backend/interactions/join_request_notifier.py", "backend/join_requests_wiring.py")))
    main_src = open(os.path.join(API_DIR, "main.py")).read()
    check("router wired exactly once in main.py", main_src.count("include_router(join_requests_router)") == 1)


def main():
    cli, cap = J.start()
    try:
        test_hooks(cli)
        test_sweeper(cli, cap)
        test_notifier(cli, cap)
        test_logging_pii(cli, cap)
        test_route_grep()
    finally:
        J.finish()


if __name__ == "__main__":
    main()
