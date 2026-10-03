"""Tests for task 20261002-explorer-listing-media, step 2 (testing): the orphan sweeper
(listings_media_sweeper.sweep_once / run_listing_media_sweeper_job), with an injected
list function and a stubbed S3 client (no AWS).

Properties proved:
  1. Grace period: an unreferenced listing key younger than orphan_grace_hours is kept,
     an older one is enqueued.
  2. Referenced keys are kept: a ready media row, a listing's photo_key / banner_key,
     and a key mentioned in description_blocks are never enqueued even when old.
  3. Enqueue only: orphans land in pending_s3_deletes; no delete_object (or any write)
     reaches S3; probe objects, foreign-shaped keys and '..' keys are never candidates.
  4. Cap per run: at most sweep_max_keys_per_run objects are examined per run, the
     in-process continuation token carries the next run on, and a completed walk wraps.
  5. ListBucket AccessDenied is aggregated: ONE WARNING per run with counts, ONE
     S3_DELETE_DENIED ERROR per prefix per 24 h (a second run adds no second ERROR),
     no key in any log line, and no bare word ERROR in non-error lines.
  6. The async job runs its work in an executor: while a 0.8 s blocking sweep runs, a
     real WebSocket echo loop (websockets, in the same event loop) keeps max round-trip
     lag under 500 ms; the async body has no boto3/psycopg2/DB call at call level; the
     job is registered in the scheduler with replace_existing.
  7. Default (non-injected) listing goes through attachments._client().list_objects_v2
     with the listings/ prefix, MaxKeys and ContinuationToken.

Scratch DB only (port 55432 asserted first); stubbed S3 only.
Run with: cd api && ../.venv/bin/python tests/test_listings_media_sweeper.py
"""
import _pathfix  # noqa: F401

import ast
import asyncio
import dataclasses
import os
import time
import uuid
from datetime import datetime, timedelta, timezone

from botocore.exceptions import ClientError

from _lm_common import (
    API_DIR, check, finish, require_scratch_db, install_stub_s3, jpeg_bytes, make_user, make_group, app_client,
    create_listing, outbox_keys, purge_outbox, cleanup, q, catch_logs, snapshot_flags, restore_flags, set_flag_sql,
    stage_upload, confirm,
)
from backend.interactions import listings_media as lm, listings_media_config as lmc, listings_media_sweeper as sw, s3_outbox
from backend.interactions import scheduler  # noqa: F401  (import check)

CFG = lmc.get_media_config()
NOW = datetime.now(timezone.utc)
OLD = NOW - timedelta(hours=CFG.orphan_grace_hours + 1)
YOUNG = NOW - timedelta(hours=CFG.orphan_grace_hours - 1)


def key_for(pid, ext=".jpg"):
    return f"listings/{pid}/{uuid.uuid4()}{ext}"


def pager(objects):
    """list_fn over a fixed list: honours max_keys and an integer continuation token."""
    calls = []

    def fn(prefix, token, max_keys):
        calls.append((prefix, token, max_keys))
        start = int(token or 0)
        page = objects[start:start + max_keys]
        nxt = start + len(page)
        return page, (str(nxt) if nxt < len(objects) else None)
    fn.calls = calls
    return fn


def obj(key, when=OLD):
    return {"Key": key, "LastModified": when}


def test_grace_and_references(cli, stub):
    print("grace period, referenced keys, enqueue-only")
    sw.reset_for_tests()
    uid = make_user()
    gid = make_group(uid)
    pid = create_listing(cli, uid, gid)
    purge_outbox(f"listings/{pid}/")
    # referenced: ready media row + photo_key (via the real confirm), banner, key text inside description_blocks
    k = stage_upload(stub, pid, jpeg_bytes(), "image/jpeg")
    r = confirm(cli, uid, gid, "photo", k)
    assert r.status_code == 200, r.text
    photo_key = q("SELECT photo_key FROM group_listings WHERE group_id = %s", (gid,))[0][0]
    banner_key = key_for(pid)
    q("UPDATE group_listings SET banner_key = %s WHERE group_id = %s", (banner_key, gid), fetch=False)
    in_blocks = key_for(pid, ".png")
    q("UPDATE group_listings SET description_blocks = %s::jsonb WHERE group_id = %s",
      ('[{"type": "text", "text": "x"}, {"type": "legacy", "src": "%s"}]' % in_blocks, gid), fetch=False)
    media_only = key_for(pid, ".webp")
    q("INSERT INTO group_listing_media (listing_id, object_key, kind, size_bytes, width, height, alt_text, status) "
      "SELECT _id, %s, 'image', 10, 1, 1, 'a', 'ready' FROM group_listings WHERE group_id = %s", (media_only, gid), fetch=False)
    orphan_old = key_for(pid)
    orphan_young = key_for(pid)
    orphan_old_png = key_for(pid, ".png")
    probe = f"listings/_probe/{uuid.uuid4()}.png"
    foreign_shape = f"listings/{pid}/sub/{uuid.uuid4()}.jpg"
    bad_ext = f"listings/{pid}/{uuid.uuid4()}.gif"
    dotdot = f"listings/{pid}/../x/{uuid.uuid4()}.jpg"
    other_prefix = f"group-photos/{uuid.uuid4()}/{uuid.uuid4()}.jpg"
    objects = [obj(photo_key), obj(banner_key), obj(in_blocks), obj(media_only), obj(orphan_old), obj(orphan_young, YOUNG),
               obj(orphan_old_png), obj(probe), obj(foreign_shape), obj(bad_ext), obj(dotdot), obj(other_prefix)]
    n_calls = len(stub.calls)
    counts = sw.sweep_once(list_fn=pager(objects))
    queued = outbox_keys()
    check("counts: examined all 12, 2 orphans, 2 enqueued", counts["examined"] == 12 and counts["orphans"] == 2 and counts["enqueued"] == 2 and counts["failed"] == 0 and counts["list_denied"] == 0, counts)
    check("old unreferenced keys are enqueued", orphan_old in queued and orphan_old_png in queued)
    check("a key younger than the grace period is kept", orphan_young not in queued)
    check("the live photo (media row + photo_key) is kept even though old", photo_key not in queued)
    check("a banner_key reference is kept", banner_key not in queued)
    check("a key present only in description_blocks is kept", in_blocks not in queued)
    check("a key present only as a ready media row is kept", media_only not in queued)
    for label, key in (("a _probe object", probe), ("a nested/foreign-shaped key", foreign_shape), ("an odd-extension key", bad_ext),
                       ("a '..' key", dotdot), ("a key under another prefix", other_prefix)):
        check(f"{label} is never a candidate", key not in queued)
    check("enqueue only: the sweeper made no S3 call at all (injected list)", len(stub.calls) == n_calls, stub.calls[n_calls:])
    counts = sw.sweep_once(list_fn=pager(objects))
    check("a second run re-examines but enqueues nothing new (ON CONFLICT DO NOTHING)", counts["enqueued"] == 0 and counts["orphans"] == 2, counts)
    # referenced once an orphan becomes referenced: removing the row makes it an orphan again
    q("DELETE FROM group_listing_media WHERE object_key = %s", (media_only,), fetch=False)
    counts = sw.sweep_once(list_fn=pager([obj(media_only)]))
    check("a key that lost its reference becomes an orphan", counts["enqueued"] == 1 and media_only in outbox_keys(), counts)
    purge_outbox(f"listings/{pid}/")
    purge_outbox("listings/_probe/")


def test_cap_per_run(stub):
    print("cap per run and continuation")
    sw.reset_for_tests()
    pid = "CapRunTest1"[:10]
    keys = [key_for(pid) for _ in range(12)]
    purge_outbox(f"listings/{pid}/")
    lmc._cached = dataclasses.replace(CFG, sweep_max_keys_per_run=5)
    try:
        lister = pager([obj(k) for k in keys])
        c1 = sw.sweep_once(list_fn=lister)
        check("run 1 examines at most the cap (5)", c1["examined"] == 5 and c1["enqueued"] == 5, c1)
        check("the page size asked of S3 never exceeds the remaining budget", all(mk <= 5 for _p, _t, mk in lister.calls), lister.calls)
        c2 = sw.sweep_once(list_fn=lister)
        check("run 2 continues where run 1 stopped (next 5)", c2["examined"] == 5 and c2["enqueued"] == 5 and lister.calls[-1][1] == "5", (c2, lister.calls[-1]))
        c3 = sw.sweep_once(list_fn=lister)
        check("run 3 finishes the walk (last 2)", c3["examined"] == 2 and c3["enqueued"] == 2, c3)
        check("every key was enqueued exactly once across the three runs", all(k in outbox_keys() for k in keys))
        c4 = sw.sweep_once(list_fn=lister)
        check("after a completed walk the next run starts over from the beginning", lister.calls[-1][1] is None and c4["examined"] == 5, lister.calls[-1])
    finally:
        lmc._cached = CFG
        sw.reset_for_tests()
        purge_outbox(f"listings/{pid}/")


def denied(*a, **k):
    raise ClientError({"Error": {"Code": "AccessDenied", "Message": "nope"}}, "ListObjectsV2")


def test_access_denied():
    print("ListBucket AccessDenied is aggregated")
    sw.reset_for_tests()
    s3_outbox.reset_for_tests()
    with catch_logs() as logs:
        c1 = sw.sweep_once(list_fn=denied)
    levels = [(lv, m) for lv, m in logs.records if "LISTING_MEDIA_SWEEP" in m or "S3_DELETE_DENIED" in m]
    warns = [m for lv, m in levels if lv == "WARNING"]
    errs = [m for lv, m in levels if lv == "ERROR"]
    check("counts report list_denied=1, no examined, no crash", c1["list_denied"] == 1 and c1["examined"] == 0 and c1["failed"] == 0, c1)
    check("exactly ONE aggregated WARNING for the run with counts", len(warns) == 1 and "list_denied=1" in warns[0] and "examined=0" in warns[0], warns)
    check("exactly ONE S3_DELETE_DENIED ERROR for the listings prefix", errs == ["S3_DELETE_DENIED prefix=listings"], errs)
    with catch_logs() as logs:
        sw.sweep_once(list_fn=denied)
        sw.sweep_once(list_fn=denied)
    errs2 = [m for lv, m in logs.records if lv == "ERROR" and "S3_DELETE_DENIED" in m]
    warns2 = [m for lv, m in logs.records if lv == "WARNING" and "LISTING_MEDIA_SWEEP" in m]
    check("repeat runs within 24 h raise NO further S3_DELETE_DENIED ERROR", not errs2, errs2)
    check("each run still logs one aggregated WARNING (not one per page or key)", len(warns2) == 2, warns2)
    check("a denied listing resets the continuation (starts over next time)", sw._continuation is None)
    check("no non-error line contains the bare word ERROR (watchdog would treat it as a detection)",
          not [m for lv, m in logs.records if lv in ("WARNING", "INFO") and "ERROR" in m and "LISTING_MEDIA" in m])
    # other S3 failures: counted as failed, still one WARNING, no ERROR line
    def boom(*a, **k):
        raise ClientError({"Error": {"Code": "InternalError", "Message": "x"}}, "ListObjectsV2")
    with catch_logs() as logs:
        c = sw.sweep_once(list_fn=boom)
    check("a non-denied S3 error counts as failed with one WARNING and no S3_DELETE_DENIED", c["failed"] == 1 and c["list_denied"] == 0
          and not [1 for lv, m in logs.records if "S3_DELETE_DENIED" in m] and len([1 for lv, m in logs.records if lv == "WARNING" and "LISTING_MEDIA_SWEEP" in m]) == 1, (c, logs.records[-3:]))
    # no keys in logs
    pid = "LogKeyTest1"[:10]
    secret_key = key_for(pid)
    purge_outbox(f"listings/{pid}/")
    with catch_logs() as logs:
        sw.reset_for_tests()
        sw.sweep_once(list_fn=pager([obj(secret_key)]))
    check("a sweep that enqueued a key logs counts only, never the key or its public id", not [m for _lv, m in logs.records if secret_key in m or pid in m], [m for _l, m in logs.records if pid in m])
    check("... and logs one INFO summary line", [m for lv, m in logs.records if lv == "INFO" and m.startswith("LISTING_MEDIA_SWEEP examined=1 enqueued=1")] != [])
    purge_outbox(f"listings/{pid}/")


def test_default_listing(stub):
    print("default list function uses the stubbed S3 client")
    sw.reset_for_tests()
    seen = []

    def list_objects_v2(**kw):
        seen.append(kw)
        return {"Contents": [], "NextContinuationToken": "tok-1"} if "ContinuationToken" not in kw else {"Contents": []}
    stub.list_objects_v2 = list_objects_v2
    lmc._cached = dataclasses.replace(CFG, sweep_max_keys_per_run=1)
    n_calls = len(stub.calls)
    c = sw.sweep_once()
    check("default path lists the listings/ prefix on the configured bucket with a bounded MaxKeys",
          seen and seen[0]["Prefix"] == "listings/" and seen[0]["Bucket"] and seen[0]["MaxKeys"] <= CFG.sweep_max_keys_per_run, seen)
    check("the continuation token is kept for the next run and then sent to S3", sw._continuation == "tok-1")
    sw.sweep_once()
    check("... next run passes ContinuationToken", len(seen) == 2 and seen[1].get("ContinuationToken") == "tok-1", seen)
    lmc._cached = CFG
    check("no delete_object / copy_object / put_object on S3 from the sweeper", not [m for m, _k in stub.calls[n_calls:] if m in ("delete_object", "put_object", "copy_object")])
    saved, attachments_bucket = None, None
    from backend.interactions import attachments
    saved = attachments.S3_BUCKET_NAME
    attachments.S3_BUCKET_NAME = ""
    try:
        seen.clear()
        c = sw.sweep_once()
        check("with S3 unconfigured the sweep is a no-op (no S3 call, zero counts)", not seen and c["examined"] == 0 and c["failed"] == 0, c)
    finally:
        attachments.S3_BUCKET_NAME = saved
    sw.reset_for_tests()


def test_event_loop():
    print("async job: executor only, WebSocket echo loop stays responsive")
    src = open(os.path.join(API_DIR, "backend", "interactions", "listings_media_sweeper.py")).read()
    tree = ast.parse(src)
    bad = []
    for node in ast.walk(tree):
        if isinstance(node, ast.AsyncFunctionDef):
            for sub in ast.walk(node):
                if isinstance(sub, ast.Call):
                    name = ast.unparse(sub.func)
                    if any(t in name for t in ("psycopg2", "boto3", "DBManager", ".execute", ".commit", ".cursor", "_client", "list_objects", "sleep")):
                        bad.append(name)
                    if name in ("sweep_once", "_referenced", "_list_page"):
                        bad.append(name)
    check("async job body has no boto3/psycopg2/DB/sync-sweep call at call level", not bad, bad)
    check("async job hands sweep_once to run_in_executor", "run_in_executor(None, sweep_once)" in src)
    check("the only async function in the module is the thin job", [n.name for n in ast.walk(tree) if isinstance(n, ast.AsyncFunctionDef)] == ["run_listing_media_sweeper_job"])
    for name in ("boto3.client(", "boto3.resource(", "psycopg2.connect("):
        check(f"module does not call {name} directly", name not in src)
    sched = open(os.path.join(API_DIR, "backend", "interactions", "scheduler.py")).read()
    i = sched.find("run_listing_media_sweeper_job", sched.find("scheduler.add_job(run_listing_media_sweeper_job") if "scheduler.add_job(run_listing_media_sweeper_job" in sched else 0)
    j = sched.find("scheduler.add_job(run_listing_media_sweeper_job")
    check("scheduler registers the media sweeper job", j != -1)
    check("... as an interval job with replace_existing=True and the stable JOB_ID", j != -1 and "replace_existing=True" in sched[j:j + 500] and "LISTING_MEDIA_SWEEP_JOB_ID" in sched[j:j + 500] and '"interval"' in sched[j:j + 200], sched[j:j + 400])
    check("... with minutes from config (sweep_interval_minutes)", "sweep_interval_minutes" in sched[j - 400:j + 500])

    import websockets
    real = sw.sweep_once

    def slow(*a, **k):
        time.sleep(0.8)
        return {"examined": 0, "orphans": 0, "enqueued": 0, "list_denied": 0, "failed": 0}
    sw.sweep_once = slow

    async def run():
        async def echo(ws):
            async for msg in ws:
                await ws.send(msg)
        async with websockets.serve(echo, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            worst, rounds, stop = 0.0, 0, False

            async def client():
                nonlocal worst, rounds
                async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
                    while not stop:
                        t0 = time.monotonic()
                        await ws.send("ping")
                        await ws.recv()
                        worst = max(worst, time.monotonic() - t0)
                        rounds += 1
                        await asyncio.sleep(0.01)
            ct = asyncio.create_task(client())
            await asyncio.sleep(0.2)
            t0 = time.monotonic()
            await sw.run_listing_media_sweeper_job()
            took = time.monotonic() - t0
            stop = True
            await ct
            return worst, rounds, took

    try:
        worst, rounds, took = asyncio.run(run())
    finally:
        sw.sweep_once = real
    check("the blocking sweep really ran (>= 0.8 s)", took >= 0.75, took)
    check("WebSocket echo kept going during the sweep (many round trips)", rounds > 20, rounds)
    check("max echo round-trip lag < 500 ms while the sweep blocked a worker thread", worst < 0.5, f"{worst * 1000:.0f} ms")

    async def failing():
        def boom(*a, **k):
            raise RuntimeError("secret-detail")
        sw.sweep_once = boom
        try:
            with catch_logs() as logs:
                await sw.run_listing_media_sweeper_job()
            return logs.records
        finally:
            sw.sweep_once = real
    recs = asyncio.run(failing())
    check("a crashing run is caught: one WARNING with the exception type only", [m for lv, m in recs if "run failed: RuntimeError" in m] and not [m for lv, m in recs if "secret-detail" in m], recs[-2:])


def main():
    require_scratch_db()
    stub = install_stub_s3()
    saved = snapshot_flags()
    cli = app_client()
    try:
        set_flag_sql("explorer_publish", "on")
        test_grace_and_references(cli, stub)
        test_cap_per_run(stub)
        test_access_denied()
        test_default_listing(stub)
        test_event_loop()
    finally:
        lmc._cached = CFG
        sw.reset_for_tests()
        restore_flags(saved)
        cleanup()
    finish()


if __name__ == "__main__":
    main()
