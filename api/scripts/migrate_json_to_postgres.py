"""One-off JSON-fixture -> Postgres migration script.

Moved out of db.py (readability H18, compliance sweep 20260830-fellowscript-
full-sweep): every function below has exactly one caller -- this file's own
``__main__`` block -- confirmed dead in production (nothing in ``api/``
imports any of them; ``DBManager``, the live query interface used by ~183
call sites across the backend, stayed behind in ``db.py`` untouched). This is
a pure move, not a behavior change -- see H20 for the accompanying rename of
``load_users`` to make its narrow, historical purpose obvious at the call
site, since ``api/main.py`` has its own unrelated, live ``load_users()``.

Run manually from the ``api/`` directory, e.g.:

    python scripts/migrate_json_to_postgres.py              # full migration
    python scripts/migrate_json_to_postgres.py --notes-only

``--notes-only`` upserts groups + notes (and note verses) without touching
users/devotions/messages or truncating anything first.
"""

import sys
import os
import json
import logging
import uuid

# Run as a plain script (`python scripts/migrate_json_to_postgres.py`), not
# via pytest/a package -- Python only puts this file's own directory
# (scripts/) on sys.path, not api/ itself, which would break the `from db
# import ...` below. Mirrors api/tests/_pathfix.py's fix for the same problem.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from db import _connect, create_tables
from schemas.users import User, Note
from schemas.message import Group, Message
from schemas.devotion import DevotionPlan

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# api/scripts/ -> api/ -> repo root (two levels up, one more than db.py's own
# main_path needed since this file lives one directory deeper).
main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")


def _load_users_json_fixture() -> dict:
    """Read the migration-only ``data/users.json`` fixture (dead in production).

    Renamed from the original ``load_users()`` (H20): ``api/main.py`` has its
    own, entirely different, live ``load_users()`` that queries Postgres via
    ``backend/interactions/helpers.load_users_data()`` -- an identical name
    for two unrelated implementations made it easy to grep your way to the
    wrong one.
    """
    path = os.path.join(main_path, "data/users.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def load_groups() -> dict:
    path = os.path.join(main_path, "data/groups.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def load_notes() -> dict:
    path = os.path.join(main_path, "data/notes.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def load_devotions() -> dict:
    path = os.path.join(main_path, "data/devotions.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def load_messages() -> list:
    path = os.path.join(main_path, "data/messages.json")
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return []


def insert_users(cur, users: dict):
    logger.info("Inserting %d users...", len(users))
    # Pass 1: insert all user rows so every user_id exists before FK references
    parsed = {}
    for uid, data in users.items():
        user = User(**data)
        user.user_id = uid
        cur.execute(
            "INSERT INTO users (_id, username, email, hash_pass)"
            "VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING",
            (user.user_id, user.username, user.email, user.hash_pass)
        )
        logger.info("%s added", user.user_id)
        parsed[uid] = user

    # Pass 2: insert relational data now that all users exist
    for uid, user in parsed.items():
        for friend_id in user.friends:
            cur.execute(
                "INSERT INTO user_friends (user_id, friend_id)"
                "VALUES (%s, %s) ON CONFLICT DO NOTHING",
                (user.user_id, friend_id)
            )
        for from_id in user.friend_requests:
            cur.execute(
                "INSERT INTO friend_requests (to_user_id, from_user_id)"
                "VALUES (%s, %s) ON CONFLICT DO NOTHING",
                (user.user_id, from_id)
            )
        for key, color in user.highlights.items():
            cur.execute(
                "INSERT INTO highlights (user_id, key, color)"
                "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                (user.user_id, key, color)
            )
        for key, label in user.bookmarks.items():
            cur.execute(
                "INSERT INTO bookmarks (user_id, key, label)"
                "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                (user.user_id, key, label)
            )
        logger.debug("Inserted relations for user %s (%s)", uid, user.username)
    logger.info("Done inserting users.")


def insert_groups(cur, groups: dict):
    logger.info("Inserting %d groups...", len(groups))
    for gid, data in groups.items():
        group = Group(group_id=gid, title=data["title"], users=data.get("users", []))
        cur.execute(
            "INSERT INTO groups (_id, title, users)"
            "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
            (group.group_id, group.title, group.users)
        )
    logger.info("Done inserting groups.")


def insert_notes(cur, notes: dict):
    logger.info("Inserting %d notes...", len(notes))
    # Build a reply→parent map so each reply knows its parent_note_id
    parent_map = {}
    for note_id, data in notes.items():
        for reply_id in data.get("replies", []):
            parent_map[reply_id] = note_id

    for note_id, data in notes.items():
        note = Note(**data)
        group_id = note.group_id if note.group_id else None
        parent_note_id = parent_map.get(note_id)
        cur.execute(
            "INSERT INTO notes (_id, user_id, title, text, public, group_id, is_reply, parent_note_id, timestamp)"
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
            (note_id, note.user, note.title, note.text, note.public,
             group_id, note.is_reply, parent_note_id, note.timestamp)
        )
        for position, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                cur.execute(
                    "INSERT INTO note_verses (note_id, position, book, chapter, verse)"
                    "VALUES (%s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
                    (note_id, position, verse[0], verse[1], verse[2])
                )
    logger.info("Done inserting notes.")


def _valid_uuid(value: str | None) -> str | None:
    if not value:
        return None
    try:
        uuid.UUID(value)
        return value
    except (ValueError, AttributeError):
        logger.warning("Skipping invalid UUID value: %r", value)
        return None


def insert_devotions(cur, devotions: dict, valid_group_ids: set, valid_user_ids: set):
    logger.info("Inserting %d devotions...", len(devotions))
    for devo_id, data in devotions.items():
        devo = DevotionPlan(**data)
        group_id = _valid_uuid(devo.group_id)
        if group_id and group_id not in valid_group_ids:
            logger.warning("Devotion %s: group_id %s not found, setting NULL", devo_id, group_id)
            group_id = None
        creator_id = _valid_uuid(devo.creator_id)
        if creator_id and creator_id not in valid_user_ids:
            logger.warning("Devotion %s: creator_id %s not found, setting NULL", devo_id, creator_id)
            creator_id = None
        cur.execute(
            "INSERT INTO devotions (_id, title, time_start, time_end, recurring,"
            "group_id, creator_id, participants, verses, prompts, chime_meeting_id, chime_meeting)"
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
            (devo_id, devo.title, devo.time_start or None, devo.time_end or None,
             devo.recurring, group_id, creator_id,
             devo.participants, devo.verses, devo.prompts,
             devo.chime_meeting_id, json.dumps(devo.chime_meeting))
        )
    logger.info("Done inserting devotions.")


def insert_messages(cur, messages: list, valid_group_ids: set, valid_user_ids: set):
    logger.info("Inserting %d messages...", len(messages))
    for data in messages:
        msg = Message(**data)
        group_id = _valid_uuid(msg.group_id)
        if group_id and group_id not in valid_group_ids:
            logger.warning("Message from %s: group_id %s not found, setting NULL", msg.from_user, group_id)
            group_id = None
        from_user = _valid_uuid(msg.from_user)
        if from_user and from_user not in valid_user_ids:
            logger.warning("Message: from_user %s not found, skipping", msg.from_user)
            continue
        cur.execute(
            "INSERT INTO messages (from_user, group_id, text, timestamp)"
            "VALUES (%s, %s, %s, %s) RETURNING _id",
            (from_user, group_id, msg.text, msg.timestamp)
        )
        row = cur.fetchone()
        if row:
            message_id = row[0]
            for recipient_id in msg.to_users:
                if _valid_uuid(recipient_id) and recipient_id in valid_user_ids:
                    cur.execute(
                        "INSERT INTO message_recipients (message_id, user_id)"
                        "VALUES (%s, %s) ON CONFLICT DO NOTHING",
                        (message_id, recipient_id)
                    )
    logger.info("Done inserting messages.")


def clear_tables(cur):
    logger.info("Clearing all tables...")
    cur.execute(
        "TRUNCATE TABLE "
        "device_tokens, subscription_request, subscriptions, "
        "agent_messages, agent_heartbeats, message_recipients, note_verses, "
        "agents, devotions, messages, notes, "
        "bookmarks, highlights, friend_requests, user_friends, "
        "groups, users "
        "CASCADE"
    )
    logger.info("All tables cleared.")


def migrate_data(cur):
    logger.info("Loading data from JSON files...")
    users = _load_users_json_fixture()
    groups = load_groups()
    notes = load_notes()
    devotions = load_devotions()
    messages = load_messages()
    logger.info("Loaded: %d users, %d groups, %d notes, %d devotions, %d messages",
                len(users), len(groups), len(notes), len(devotions), len(messages))

    insert_users(cur, users)
    insert_groups(cur, groups)
    insert_notes(cur, notes)
    insert_devotions(cur, devotions, valid_group_ids=set(groups.keys()), valid_user_ids=set(users.keys()))
    insert_messages(cur, messages, valid_group_ids=set(groups.keys()), valid_user_ids=set(users.keys()))
    logger.info("Migration complete.")


def main():
    logger.info("Connecting to PostgreSQL...")
    conn = _connect()
    logger.info("Connected.")
    cur = conn.cursor()
    create_tables(cur)
    clear_tables(cur)
    migrate_data(cur)
    conn.commit()
    logger.info("Changes committed.")
    cur.close()
    conn.close()
    logger.info("Connection closed.")


def main_notes_only():
    """Insert any notes (and their verses) missing from the DB without touching other tables.
    Groups are also upserted first so FK constraints on notes.group_id are satisfied."""
    logger.info("Notes-only migration: connecting...")
    conn = _connect()
    logger.info("Connected.")
    cur = conn.cursor()
    groups = load_groups()
    notes  = load_notes()
    logger.info("Loaded %d groups and %d notes from JSON.", len(groups), len(notes))
    insert_groups(cur, groups)
    insert_notes(cur, notes)
    conn.commit()
    logger.info("Notes committed.")
    cur.close()
    conn.close()
    logger.info("Done.")


if __name__ == "__main__":
    if "--notes-only" in sys.argv:
        main_notes_only()
    else:
        main()
