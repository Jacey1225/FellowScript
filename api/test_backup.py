"""Tests for the nightly per-user backup feature (timezone-due detection +
BackupManager copying recent data into the separate backup database).

Run with: cd api && ../.venv/bin/python test_backup.py
"""
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone as tzmod

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from db import DBManager, BACKUP_DB_NAME  # noqa: E402
from backend.backup.manager import BackupManager  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
import main as main_module  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def make_user(username_prefix: str, tzname: str) -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {
            "_id": uid, "username": f"{username_prefix}_{uid[:8]}",
            "email": f"{username_prefix}_{uid[:8]}@example.com",
            "hash_pass": "x", "timezone": tzname,
        })
    finally:
        db.close()
    return uid


def add_note(user_id: str, title: str, when: datetime, verses=None) -> str:
    """Insert a note with an explicit timestamp (bypassing the API's NOW() default)."""
    nid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO notes (_id, user_id, title, text, public, is_reply, timestamp, created_at) "
            "VALUES (%s,%s,%s,%s,false,false,%s,%s)",
            (nid, user_id, title, "body", when, when),
        )
        db.conn.commit()
        for i, v in enumerate(verses or []):
            db.cur.execute(
                "INSERT INTO note_verses (note_id, position, book, chapter, verse) "
                "VALUES (%s,%s,%s,%s,%s)",
                (nid, i, v[0], v[1], v[2]),
            )
        db.conn.commit()
    finally:
        db.close()
    return nid


def cleanup(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM highlights WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM bookmarks WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()

    backup_db = DBManager(dbname=BACKUP_DB_NAME)
    try:
        for uid in user_ids:
            backup_db.cur.execute("DELETE FROM note_verses WHERE note_id IN "
                                   "(SELECT _id FROM notes WHERE user_id = %s)", (uid,))
            backup_db.cur.execute("DELETE FROM notes WHERE user_id = %s", (uid,))
            backup_db.cur.execute("DELETE FROM highlights WHERE user_id = %s", (uid,))
            backup_db.cur.execute("DELETE FROM bookmarks WHERE user_id = %s", (uid,))
            backup_db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        backup_db.conn.commit()
    finally:
        backup_db.close()


def main():
    uid_la = make_user("backup_la", "America/Los_Angeles")
    uid_tokyo = make_user("backup_tokyo", "Asia/Tokyo")
    uid_bad = make_user("backup_badtz", "Not/A_Real_Zone")

    try:
        print("=== 1. users_due_now: timezone-due detection ===")
        bm = BackupManager()
        try:
            # 11:00 UTC == 03:00 in America/Los_Angeles (UTC-8, standard time in Jan).
            fixed_now = datetime(2026, 1, 15, 11, 0, tzinfo=tzmod.utc)
            due = bm.users_due_now(now_utc=fixed_now)
            check("LA user is due at 11:00 UTC (their local 3am)", uid_la in due, str(due))
            check("Tokyo user is NOT due at that instant", uid_tokyo not in due, str(due))

            # 18:00 UTC == 03:00 in Asia/Tokyo (UTC+9).
            fixed_now2 = datetime(2026, 1, 15, 18, 0, tzinfo=tzmod.utc)
            due2 = bm.users_due_now(now_utc=fixed_now2)
            check("Tokyo user is due at 18:00 UTC (their local 3am)", uid_tokyo in due2, str(due2))
            check("LA user is NOT due at that instant", uid_la not in due2, str(due2))

            # A minute later, nobody should still be "due" (one-minute window).
            fixed_now3 = datetime(2026, 1, 15, 11, 1, tzinfo=tzmod.utc)
            due3 = bm.users_due_now(now_utc=fixed_now3)
            check("LA user is NOT due one minute later", uid_la not in due3, str(due3))

            # Invalid timezone must be skipped, not crash the whole check.
            due4 = bm.users_due_now(now_utc=fixed_now)
            check("invalid-timezone user never appears, and check doesn't crash",
                  uid_bad not in due4, str(due4))
        finally:
            bm.close()

        print("\n=== 2. backup_user: happy path (recent note + verses) ===")
        now = datetime.now(tzmod.utc)
        recent_note_id = add_note(uid_la, "Recent note", now - timedelta(hours=2),
                                   verses=[["Genesis", 1, 1]])
        old_note_id = add_note(uid_la, "Old note", now - timedelta(days=5))

        db = DBManager()
        try:
            db.insertion("highlights", {"user_id": uid_la, "key": "Genesis-1-1", "color": "#ff0000"})
            db.insertion("bookmarks", {"user_id": uid_la, "key": "Genesis-1", "label": "start"})
        finally:
            db.close()

        bm = BackupManager()
        try:
            result = bm.backup_user(uid_la)
            check("backup_user returns counts, not an error", "error" not in result, str(result))
            check("exactly the recent note was counted", result.get("notes") == 1, str(result))
            check("its verse was counted", result.get("note_verses") == 1, str(result))
            check("highlight was counted", result.get("highlights") == 1, str(result))
            check("bookmark was counted", result.get("bookmarks") == 1, str(result))
        finally:
            bm.close()

        backup_db = DBManager(dbname=BACKUP_DB_NAME)
        try:
            backup_db.cur.execute("SELECT _id FROM notes WHERE _id = %s", (recent_note_id,))
            check("recent note IS present in the backup DB", backup_db.cur.fetchone() is not None)

            backup_db.cur.execute("SELECT _id FROM notes WHERE _id = %s", (old_note_id,))
            check("note older than 24h is NOT present in the backup DB",
                  backup_db.cur.fetchone() is None)

            backup_db.cur.execute(
                "SELECT book, chapter, verse FROM note_verses WHERE note_id = %s", (recent_note_id,)
            )
            check("verse row mirrored correctly", backup_db.cur.fetchone() == ("Genesis", 1, 1))

            backup_db.cur.execute(
                "SELECT color FROM highlights WHERE user_id = %s AND key = %s", (uid_la, "Genesis-1-1")
            )
            check("highlight mirrored correctly", backup_db.cur.fetchone() == ("#ff0000",))

            backup_db.cur.execute("SELECT username FROM users WHERE _id = %s", (uid_la,))
            row = backup_db.cur.fetchone()
            check("user profile row mirrored", row is not None and row[0] is not None, str(row))
        finally:
            backup_db.close()

        print("\n=== 3. backup_user: idempotent re-run (upsert, not duplicate/crash) ===")
        bm = BackupManager()
        try:
            result2 = bm.backup_user(uid_la)
            check("re-running backup_user succeeds without error", "error" not in result2, str(result2))
        finally:
            bm.close()
        backup_db = DBManager(dbname=BACKUP_DB_NAME)
        try:
            backup_db.cur.execute("SELECT count(*) FROM notes WHERE _id = %s", (recent_note_id,))
            check("re-run does not duplicate the note row", backup_db.cur.fetchone()[0] == 1)
        finally:
            backup_db.close()

        print("\n=== 4. backup_user: unknown user is an error, not a crash ===")
        bm = BackupManager()
        try:
            result3 = bm.backup_user(str(uuid.uuid4()))
            check("unknown user returns {'error': ...}", "error" in result3, str(result3))
        finally:
            bm.close()

        print("\n=== 5. DELETE /user/{id} purges the backup DB too (Privacy Policy compliance) ===")
        with TestClient(main_module.app) as client:
            uname = f"backup_del_{uuid.uuid4().hex[:8]}"
            r = client.post("/signup", json={
                "username": uname, "email": f"{uname}@example.com", "plain_pass": "TestPass123!",
            })
            uid_del = r.json()["user_id"]
            token = r.cookies.get("session")
            add_note(uid_del, "To be deleted", datetime.now(tzmod.utc), verses=[["Genesis", 1, 1]])

            bm = BackupManager()
            try:
                bm.backup_user(uid_del)
            finally:
                bm.close()

            backup_db = DBManager(dbname=BACKUP_DB_NAME)
            try:
                backup_db.cur.execute("SELECT count(*) FROM notes WHERE user_id = %s", (uid_del,))
                check("setup: note exists in backup DB before deletion",
                      backup_db.cur.fetchone()[0] == 1)
            finally:
                backup_db.close()

            r = client.delete(f"/user/{uid_del}", headers={"cookie": f"session={token}"})
            check("account deletion -> 204", r.status_code == 204, str(r.status_code))

            backup_db = DBManager(dbname=BACKUP_DB_NAME)
            try:
                backup_db.cur.execute("SELECT count(*) FROM users WHERE _id = %s", (uid_del,))
                check("backup DB user row purged after account deletion",
                      backup_db.cur.fetchone()[0] == 0)
                backup_db.cur.execute("SELECT count(*) FROM notes WHERE user_id = %s", (uid_del,))
                check("backup DB note purged after account deletion",
                      backup_db.cur.fetchone()[0] == 0)
                backup_db.cur.execute(
                    "SELECT count(*) FROM note_verses WHERE note_id IN "
                    "(SELECT _id FROM notes WHERE user_id = %s)", (uid_del,)
                )
                check("backup DB note_verses purged after account deletion",
                      backup_db.cur.fetchone()[0] == 0)
            finally:
                backup_db.close()

    finally:
        print("\n=== cleanup ===")
        cleanup(uid_la, uid_tokyo, uid_bad)

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
