"""
Proves `db.py::create_tables`'s 2026-08-14 incident-window noise backfill
(cloudwatch-watchdog-memory-leak workflow, step 4): `error_detections` rows
written during the ~5-hour production OOM incident are flagged
`status='noise'` -- excluded from the default admin triage feed but never
deleted -- so the incident stays inspectable for postmortem review, per the
intake spec's resolved open question.

Runs the real migration-on-boot step (`db._connect()` + `create_tables(cur)`
+ commit) exactly as deploy does, matching test_admin_seed_migration.py's
established pattern for this repeatable-migration style of test.

Covers:
  - A row `detected_at` inside the incident window
    (2026-08-14 00:00:00-07:00 .. 2026-08-14 15:54:16-07:00) with
    status='new' is flipped to status='noise'.
  - A row inside the window with status='diagnosed' is also flipped (the
    migration's `status IN ('new', 'diagnosed')` guard covers both
    pre-backfill statuses a real incident-window row could have had).
  - A row just OUTSIDE the window (one second after the end boundary, and
    one day before the window) is left untouched.
  - Re-running create_tables() (idempotent by design, per the module's own
    "re-applied idempotently every create_tables() run" comment) does not
    re-touch a row a human has since manually set to some other status
    (e.g. 'reviewed') -- the guard means a later manual status is never
    silently overwritten by a subsequent boot.
  - Flagged rows are never deleted -- the row count for the window is
    unchanged before/after, only `status` changes.
  - `WatchdogManager.list_detections()` (the admin feed) excludes a
    noise-flagged row by default, but includes it with
    `include_noise=True`, and `get_detection()` always returns it
    regardless -- proving the "excluded from feed, not deleted, still
    inspectable" contract end-to-end, not just at the DB-column level.

Run:  cd api && ../.venv/bin/python tests/test_incident_noise_backfill.py
"""

import _pathfix  # noqa: F401

import sys
import uuid
from datetime import datetime, timedelta, timezone

import db as db_module
from db import DBManager
from backend.monitoring.watchdog import WatchdogManager

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


LOG_GROUP = f"/test/incident-noise-{uuid.uuid4()}"

# Matches db.py's own window constants exactly.
WINDOW_START = datetime.fromisoformat("2026-08-14 00:00:00-07:00")
WINDOW_END = datetime.fromisoformat("2026-08-14 15:54:16-07:00")


def run_create_tables():
    conn = db_module._connect()
    cur = conn.cursor()
    try:
        db_module.create_tables(cur)
        conn.commit()
    finally:
        cur.close()
        conn.close()


def insert_detection(detected_at: datetime, status: str) -> str:
    detection_id = str(uuid.uuid4())
    dbm = DBManager()
    try:
        dbm.cur.execute(
            "INSERT INTO error_detections "
            "(_id, log_group_name, event_timestamp, message, matched_signal, "
            "context, detected_at, status) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
            (detection_id, LOG_GROUP, detected_at, "ERROR - incident window test row",
             "error_level", "{}", detected_at, status),
        )
        dbm.conn.commit()
    finally:
        dbm.close()
    return detection_id


def get_status(detection_id: str) -> str | None:
    dbm = DBManager()
    try:
        dbm.cur.execute("SELECT status FROM error_detections WHERE _id = %s", (detection_id,))
        row = dbm.cur.fetchone()
        return row[0] if row else None
    finally:
        dbm.close()


def row_exists(detection_id: str) -> bool:
    dbm = DBManager()
    try:
        dbm.cur.execute("SELECT 1 FROM error_detections WHERE _id = %s", (detection_id,))
        return dbm.cur.fetchone() is not None
    finally:
        dbm.close()


def cleanup():
    wm = WatchdogManager()
    try:
        wm.cur.execute("DELETE FROM error_detections WHERE log_group_name = %s", (LOG_GROUP,))
        wm.conn.commit()
    finally:
        wm.close()


def test_rows_inside_window_flagged_new_and_diagnosed():
    print("\n── Rows inside the incident window (status new/diagnosed) get flagged noise ──")
    mid_window = WINDOW_START + (WINDOW_END - WINDOW_START) / 2
    id_new = insert_detection(mid_window, "new")
    id_diagnosed = insert_detection(mid_window, "diagnosed")

    run_create_tables()

    check("status='new' row inside window flipped to 'noise'", get_status(id_new), "noise")
    check("status='diagnosed' row inside window also flipped to 'noise'",
          get_status(id_diagnosed), "noise")
    check("row still exists -- flagged, not deleted", row_exists(id_new), True)
    check("row still exists -- flagged, not deleted (diagnosed case)", row_exists(id_diagnosed), True)


def test_rows_outside_window_untouched():
    print("\n── Rows just outside the incident window are left untouched ──")
    just_after = WINDOW_END + timedelta(seconds=1)
    day_before = WINDOW_START - timedelta(days=1)
    id_after = insert_detection(just_after, "new")
    id_before = insert_detection(day_before, "new")

    run_create_tables()

    check("row one second after the window end is untouched", get_status(id_after), "new")
    check("row a day before the window start is untouched", get_status(id_before), "new")


def test_idempotent_rerun_does_not_clobber_manual_status():
    print("\n── Re-running create_tables() does not overwrite a later manual status ──")
    mid_window = WINDOW_START + timedelta(hours=1)
    detection_id = insert_detection(mid_window, "new")

    run_create_tables()
    check("first run flags it noise", get_status(detection_id), "noise")

    # Simulate a human operator manually reviewing and re-classifying it.
    dbm = DBManager()
    try:
        dbm.cur.execute("UPDATE error_detections SET status = 'reviewed' WHERE _id = %s", (detection_id,))
        dbm.conn.commit()
    finally:
        dbm.close()

    run_create_tables()
    check("a second create_tables() run does not silently revert the manual status",
          get_status(detection_id), "reviewed")


def test_admin_feed_excludes_noise_by_default_but_stays_inspectable():
    print("\n── list_detections excludes noise by default; include_noise/get_detection still see it ──")
    mid_window = WINDOW_START + timedelta(hours=2)
    real_ts = datetime.now(timezone.utc) - timedelta(minutes=5)
    noise_id = insert_detection(mid_window, "new")
    real_id = insert_detection(real_ts, "new")

    run_create_tables()
    check("noise row flagged", get_status(noise_id), "noise")

    wm = WatchdogManager()
    try:
        default_feed_ids = {row["id"] for row in wm.list_detections(log_group_name=LOG_GROUP, limit=50)}
        check("default admin feed excludes the noise-flagged row", noise_id in default_feed_ids, False)
        check("default admin feed still includes the real (non-noise) row", real_id in default_feed_ids, True)

        full_feed_ids = {row["id"] for row in wm.list_detections(
            log_group_name=LOG_GROUP, limit=50, include_noise=True)}
        check("include_noise=True surfaces the flagged row for postmortem review",
              noise_id in full_feed_ids, True)

        detail = wm.get_detection(noise_id)
        check("get_detection always returns a noise-flagged row (never filtered)",
              detail is not None, True)
        if detail:
            check("detail record's status is 'noise'", detail.get("status"), "noise")
    finally:
        wm.close()


if __name__ == "__main__":
    try:
        test_rows_inside_window_flagged_new_and_diagnosed()
        test_rows_outside_window_untouched()
        test_idempotent_rerun_does_not_clobber_manual_status()
        test_admin_feed_excludes_noise_by_default_but_stays_inspectable()
    finally:
        cleanup()

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
