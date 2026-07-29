"""
Validates GroupsManager, FriendsManager, and ConnectionManager against the
live PostgreSQL database. All test rows are inserted inside a transaction
that is rolled back at the end, so the database is left unchanged.
"""
import uuid
import sys
from datetime import datetime

import psycopg2 as sql
import os
from dotenv import load_dotenv

import _pathfix  # noqa: F401

load_dotenv()

# ── seed IDs ──────────────────────────────────────────────────────────────────
USER_A_ID    = str(uuid.uuid4())
USER_B_ID    = str(uuid.uuid4())
GROUP_ID     = str(uuid.uuid4())
NOTE_ID      = str(uuid.uuid4())
REPLY_ID     = str(uuid.uuid4())

PASS = "hashed_pass_placeholder"

def seed(cur):
    cur.execute(
        "INSERT INTO users (_id, username, email, hash_pass) VALUES (%s,%s,%s,%s)",
        (USER_A_ID, "test_user_a", "a@test.com", PASS)
    )
    cur.execute(
        "INSERT INTO users (_id, username, email, hash_pass) VALUES (%s,%s,%s,%s)",
        (USER_B_ID, "test_user_b", "b@test.com", PASS)
    )
    cur.execute(
        "INSERT INTO groups (_id, title, users) VALUES (%s,%s,%s)",
        (GROUP_ID, "Test Group", [USER_A_ID, USER_B_ID])
    )
    cur.execute(
        "INSERT INTO notes (_id, user_id, title, text, public, group_id, is_reply) VALUES (%s,%s,%s,%s,%s,%s,%s)",
        (NOTE_ID, USER_A_ID, "Test Note", "Hello world", True, GROUP_ID, False)
    )
    cur.execute(
        "INSERT INTO notes (_id, user_id, title, text, public, is_reply, parent_note_id) VALUES (%s,%s,%s,%s,%s,%s,%s)",
        (REPLY_ID, USER_B_ID, "Reply", "Reply text", False, True, NOTE_ID)
    )
    cur.execute(
        "INSERT INTO highlights (user_id, key, color) VALUES (%s,%s,%s)",
        (USER_A_ID, "Genesis-1-1", "#ff0000")
    )
    cur.execute(
        "INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s)",
        (USER_A_ID, USER_B_ID, USER_B_ID, USER_A_ID)
    )
    cur.execute(
        "INSERT INTO friend_requests (to_user_id, from_user_id) VALUES (%s,%s)",
        (USER_B_ID, USER_A_ID)
    )

# ── test helpers ──────────────────────────────────────────────────────────────
passed = 0
failed = 0

def check(label: str, condition: bool, detail: str = ""):
    global passed, failed
    if condition:
        print(f"  PASS  {label}")
        passed += 1
    else:
        print(f"  FAIL  {label}{f'  →  {detail}' if detail else ''}")
        failed += 1

# ── tests ─────────────────────────────────────────────────────────────────────
def test_groups_manager():
    from backend.interactions.groups import GroupsManager
    print("\n── GroupsManager ────────────────────────────────────")

    gm = GroupsManager(user_id=USER_A_ID, group_id=GROUP_ID)
    check("__init__ loads user", gm.user.username == "test_user_a",
          f"got '{gm.user.username}'")

    group = gm.fetch_group()
    check("fetch_group returns group data",  "group" in group, str(group))
    check("fetch_group finds member username", "test_user_b" in group.get("members", []),
          str(group.get("members")))

    notes = gm.fetch_notes()
    check("fetch_notes keys by username", "test_user_a" in notes, str(list(notes.keys())))
    check("fetch_notes contains note", NOTE_ID in notes.get("test_user_a", {}),
          str(notes.get("test_user_a", {}).keys()))

    replies = gm.fetch_replies(NOTE_ID)
    check("fetch_replies returns list",   isinstance(replies, list))
    check("fetch_replies finds reply",    any(r.get("text") == "Reply text" for r in replies),
          str(replies))

    highlights = gm.fetch_highlights()
    check("fetch_highlights has user A",  USER_A_ID in highlights, str(list(highlights.keys())))
    check("fetch_highlights has key",     "Genesis-1-1" in highlights.get(USER_A_ID, {}),
          str(highlights.get(USER_A_ID)))

    gm.close()


def test_friends_manager():
    from backend.interactions.friends import FriendsManager
    print("\n── FriendsManager ───────────────────────────────────")

    fm = FriendsManager(user_id=USER_A_ID)
    check("__init__ loads user", fm.user.username == "test_user_a",
          f"got '{fm.user.username}'")

    friends = fm.get_friends()
    check("get_friends returns list", isinstance(friends, list))
    check("get_friends finds user B", any(f["username"] == "test_user_b" for f in friends),
          str(friends))

    read = fm.read_friend(USER_B_ID)
    check("read_friend returns dict",         isinstance(read, dict))
    check("read_friend has friend data",      read.get("friend", {}).get("username") == "test_user_b",
          str(read.get("friend")))
    check("read_friend has host_msgs key",    "host_msgs" in read)
    check("read_friend has other_msgs key",   "other_msgs" in read)
    check("read_friend excludes hash_pass",   "hash_pass" not in read.get("friend", {}))

    fm.close()


def test_send_add_request():
    from backend.interactions.friends import FriendsManager
    print("\n── FriendsManager.send_add_request ──────────────────")

    USER_C_ID = str(uuid.uuid4())
    conn = sql.connect(host="localhost", dbname="fellowscript",
                       user="fellowscript", password=os.getenv("DB_PASSWORD"), port=5432)
    cur = conn.cursor()
    cur.execute("INSERT INTO users (_id, username, email, hash_pass) VALUES (%s,%s,%s,%s)",
                (USER_C_ID, "test_user_c", "c@test.com", PASS))
    conn.commit()

    fm = FriendsManager(user_id=USER_A_ID)
    err = fm.send_add_request("test_user_c")
    check("send_add_request returns None on success", err is None, str(err))

    cur.execute("SELECT 1 FROM friend_requests WHERE to_user_id=%s AND from_user_id=%s",
                (USER_C_ID, USER_A_ID))
    check("friend_request row inserted", cur.fetchone() is not None)

    cur.execute("DELETE FROM friend_requests WHERE to_user_id=%s AND from_user_id=%s",
                (USER_C_ID, USER_A_ID))
    cur.execute("DELETE FROM users WHERE _id=%s", (USER_C_ID,))
    conn.commit()
    cur.close()
    conn.close()
    fm.close()


def test_connection_manager():
    import asyncio
    from backend.interactions.websockets import ConnectionManager
    print("\n── ConnectionManager.save_message ───────────────────")

    cm = ConnectionManager()
    from schemas.message import Message
    msg = Message(
        from_user=USER_A_ID,
        to_users=[USER_B_ID],
        group_id=None,
        text="test message",
        timestamp=str(datetime.now())
    )
    cm.save_message(msg)

    cm.cur.execute(
        "SELECT _id FROM messages WHERE from_user=%s AND text='test message'",
        (USER_A_ID,)
    )
    row = cm.cur.fetchone()
    check("save_message inserts into messages", row is not None)
    if row:
        cm.cur.execute("SELECT 1 FROM message_recipients WHERE message_id=%s AND user_id=%s",
                       (row[0], USER_B_ID))
        check("save_message inserts into message_recipients", cm.cur.fetchone() is not None)
        cm.cur.execute("DELETE FROM message_recipients WHERE message_id=%s", (row[0],))
        cm.cur.execute("DELETE FROM messages WHERE _id=%s", (row[0],))
        cm.conn.commit()

    cm.close()

# ── main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    conn = sql.connect(
        host="localhost", dbname="fellowscript",
        user="fellowscript", password=os.getenv("DB_PASSWORD"), port=5432
    )
    conn.autocommit = False
    cur = conn.cursor()

    print("Seeding test data...")
    seed(cur)
    conn.commit()

    try:
        test_groups_manager()
        test_friends_manager()
        test_send_add_request()
        test_connection_manager()
    finally:
        print("\nRolling back test data...")
        cur.execute("DELETE FROM notes WHERE _id IN (%s,%s)", (NOTE_ID, REPLY_ID))
        cur.execute("DELETE FROM highlights WHERE user_id=%s", (USER_A_ID,))
        cur.execute("DELETE FROM user_friends WHERE user_id IN (%s,%s)", (USER_A_ID, USER_B_ID))
        cur.execute("DELETE FROM friend_requests WHERE to_user_id=%s", (USER_B_ID,))
        cur.execute("DELETE FROM groups WHERE _id=%s", (GROUP_ID,))
        cur.execute("DELETE FROM users WHERE _id IN (%s,%s)", (USER_A_ID, USER_B_ID))
        conn.commit()
        cur.close()
        conn.close()
        print("Database restored.")

    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
