import psycopg2 as sql
import os
import sys
import json
import logging
import uuid
from typing import Any
from dotenv import load_dotenv
from schemas.users import User, Note
from schemas.message import Group, Message
from schemas.devotion import DevotionPlan

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

def create_tables(cur):
    logger.info("Creating tables...")
    # ── Level 0: no foreign keys ───────────────────────────────────────────────
    cur.execute(
        "CREATE TABLE IF NOT EXISTS users"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "username VARCHAR(64) UNIQUE NOT NULL,"
        "email VARCHAR(255) UNIQUE NOT NULL,"
        "hash_pass VARCHAR(255) NOT NULL,"
        # Stable provider identifiers for social sign-in (nullable — password
        # accounts have neither; each is backfilled on that provider's sign-in).
        "apple_sub TEXT,"
        "google_sub TEXT)"
    )
    # Migrations for databases created before the social-sign-in columns existed.
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_sub TEXT")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS google_sub TEXT")

    cur.execute(
        "CREATE TABLE IF NOT EXISTS groups"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "title VARCHAR(255) NOT NULL,"
        "users TEXT[])"
    )

    # ── Level 1: depend on users / groups ──────────────────────────────────────
    cur.execute(
        "CREATE TABLE IF NOT EXISTS user_friends"
        "(user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "friend_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "PRIMARY KEY (user_id, friend_id))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS friend_requests"
        "(to_user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "from_user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "PRIMARY KEY (to_user_id, from_user_id))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS highlights"
        "(user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "key VARCHAR(128) NOT NULL,"
        "color VARCHAR(16) NOT NULL,"
        "PRIMARY KEY (user_id, key))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS bookmarks"
        "(user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "key VARCHAR(128) NOT NULL,"
        "label VARCHAR(255) DEFAULT '',"
        "PRIMARY KEY (user_id, key))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS notes"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "user_id UUID REFERENCES users(_id),"
        "title VARCHAR(255) DEFAULT '',"
        "text TEXT DEFAULT '',"
        "public BOOLEAN DEFAULT FALSE,"
        "group_id UUID REFERENCES groups(_id) ON DELETE SET NULL,"
        "is_reply BOOLEAN DEFAULT FALSE,"
        "parent_note_id UUID REFERENCES notes(_id) ON DELETE CASCADE,"
        "timestamp TIMESTAMPTZ DEFAULT NOW())"
    )
    cur.execute("ALTER TABLE notes ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW()")
    # Speeds up the free-tier weekly note count (LimitsManager).
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_notes_user_timestamp "
        "ON notes(user_id, timestamp)"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS messages"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "from_user UUID REFERENCES users(_id),"
        "group_id UUID REFERENCES groups(_id) ON DELETE SET NULL,"
        "text TEXT NOT NULL,"
        "timestamp TIMESTAMPTZ DEFAULT NOW())"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS devotions"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "title VARCHAR(255) DEFAULT '',"
        "time_start TIMESTAMPTZ,"
        "time_end TIMESTAMPTZ,"
        "recurring BOOLEAN DEFAULT FALSE,"
        # A session's room id: a group id OR a DM room key (userA|userB), so it
        # is free-form text, not an FK to groups.
        "group_id TEXT,"
        "creator_id UUID REFERENCES users(_id),"
        "participants TEXT[],"
        "verses TEXT[],"
        "prompts TEXT[],"
        "chime_meeting_id VARCHAR(255) DEFAULT '',"
        "chime_meeting JSONB DEFAULT '{}')"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS agents"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "role VARCHAR(128) DEFAULT '',"
        "chats TEXT[])"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS subscriptions"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        # The host who owns and pays for the plan.
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "plan_type TEXT NOT NULL DEFAULT 'individual',"       # 'individual' | 'group'
        "provider TEXT NOT NULL DEFAULT 'stripe',"            # 'stripe' | 'apple'
        # Opaque processor references — never raw card data.
        "stripe_customer_id TEXT DEFAULT '',"
        "stripe_subscription_id TEXT DEFAULT '',"
        "apple_original_transaction_id TEXT DEFAULT '',"
        "default_payment_method_id TEXT DEFAULT '',"
        # Display-only, PCI-safe card metadata.
        "card_brand TEXT DEFAULT '',"
        "card_last4 TEXT DEFAULT '',"
        "card_exp_month TEXT DEFAULT '',"
        "card_exp_year TEXT DEFAULT '',"
        "status TEXT NOT NULL DEFAULT 'inactive',"
        "price_cents INTEGER NOT NULL DEFAULT 1000,"          # derived from plan_type
        "max_members INTEGER NOT NULL DEFAULT 1,"             # derived from plan_type
        # trial_end = first billing date (created_at + trial); current_period_end
        # is the rolling next-billing date, monitored by the scheduler.
        "trial_end TIMESTAMPTZ,"
        "current_period_end TIMESTAMPTZ,"
        "created_at TIMESTAMPTZ DEFAULT NOW())"
    )
    # Migrations for a subscriptions table created before these plan columns
    # existed (no-op on a fresh DB where CREATE TABLE already added them).
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(_id) ON DELETE CASCADE")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS plan_type TEXT NOT NULL DEFAULT 'individual'")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS price_cents INTEGER NOT NULL DEFAULT 1000")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS max_members INTEGER NOT NULL DEFAULT 1")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS card_exp_month TEXT DEFAULT ''")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS card_exp_year TEXT DEFAULT ''")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS trial_end TIMESTAMPTZ")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT DEFAULT ''")
    cur.execute("ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS apple_original_transaction_id TEXT DEFAULT ''")
    # A user's plan membership is a pointer on the users row (single source of
    # truth): a plan's members are the users pointing at it, the host is
    # subscriptions.user_id. Added here (after subscriptions exists) to avoid a
    # circular create-time FK. ON DELETE SET NULL detaches members if the plan
    # is removed.
    cur.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS subscription_id UUID "
        "REFERENCES subscriptions(_id) ON DELETE SET NULL"
    )

    # ── Level 2: depend on Level 1 ─────────────────────────────────────────────
    cur.execute(
        "CREATE TABLE IF NOT EXISTS note_verses"
        "(note_id UUID REFERENCES notes(_id) ON DELETE CASCADE,"
        "position INTEGER NOT NULL,"
        "book VARCHAR(64),"
        "chapter INTEGER,"
        "verse INTEGER,"
        "PRIMARY KEY (note_id, position))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS message_recipients"
        "(message_id UUID REFERENCES messages(_id) ON DELETE CASCADE,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "PRIMARY KEY (message_id, user_id))"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS agent_heartbeats"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "agent_id UUID REFERENCES agents(_id) ON DELETE CASCADE,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "timestamps JSONB DEFAULT '[]',"
        "prompt TEXT DEFAULT '',"
        # Timestamp of the most recent fire. Used to make commit_hb_response
        # idempotent so the server cron and the iOS client can't both create a
        # note for the same scheduled slot (they fire within the same minute).
        "last_fired TIMESTAMPTZ)"
    )
    # Migration for databases created before last_fired existed.
    cur.execute(
        "ALTER TABLE agent_heartbeats ADD COLUMN IF NOT EXISTS last_fired TIMESTAMPTZ"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS agent_messages"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "title VARCHAR(255) DEFAULT '',"
        "agent_id UUID REFERENCES agents(_id) ON DELETE CASCADE,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "timestamp TIMESTAMPTZ DEFAULT NOW(),"
        "content TEXT DEFAULT '')"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS notifications"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "name VARCHAR(255) NOT NULL DEFAULT '',"
        "prompt TEXT DEFAULT '',"
        "timestamps JSONB DEFAULT '[]')"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS device_tokens"
        "(user_id UUID PRIMARY KEY REFERENCES users(_id) ON DELETE CASCADE,"
        "token TEXT NOT NULL,"
        "updated_at TIMESTAMP DEFAULT NOW())"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS agentic_context"
        "(_id UUID PRIMARY KEY NOT NULL,"
        "heartbeat_id UUID REFERENCES agent_heartbeats(_id) ON DELETE CASCADE,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "context TEXT[] DEFAULT '{}')"
    )

    cur.execute(
        "CREATE TABLE IF NOT EXISTS subscription_request"
        "(subscription_id UUID REFERENCES subscriptions(_id) ON DELETE CASCADE,"
        "from_user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "created_at TIMESTAMPTZ DEFAULT NOW(),"
        "PRIMARY KEY (subscription_id, from_user_id))"
    )

    # Server-side session store backing the login cookie. The cookie holds an
    # opaque random token; only its sha256 hash is stored, mirroring hash_pass.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS sessions"
        "(token_hash VARCHAR(64) PRIMARY KEY,"
        "user_id UUID REFERENCES users(_id) ON DELETE CASCADE,"
        "created_at TIMESTAMPTZ DEFAULT NOW(),"
        "expires_at TIMESTAMPTZ NOT NULL)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)"
    )
    logger.info("All tables created.")

main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

def load_users() -> dict:
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
        "device_tokens, notifications, subscription_request, subscriptions, "
        "agent_messages, agent_heartbeats, message_recipients, note_verses, "
        "agents, devotions, messages, notes, "
        "bookmarks, highlights, friend_requests, user_friends, "
        "groups, users "
        "CASCADE"
    )
    logger.info("All tables cleared.")

def migrate_data(cur):
    logger.info("Loading data from JSON files...")
    users = load_users()
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

def _connect():
    return sql.connect(
        host="localhost",
        dbname="fellowscript",
        user="fellowscript",
        password=os.getenv("DB_PASSWORD"),
        port=5432,
    )

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


class DBManager:
    def __init__(self):
        self.conn = sql.connect(
            host="localhost",
            dbname="fellowscript",
            user="fellowscript",
            password=os.getenv("DB_PASSWORD"),
            port=5432
        )
        logger.info("Connected.")
        self.cur = self.conn.cursor()
        self.db_name = "fellowscript"

    def insertion(self, table: str, values: dict[str, Any], conflict: str = "DO NOTHING"):
        cols = ", ".join(values.keys())
        placeholders = ", ".join(["%s"] * len(values))
        try:
            self.cur.execute(
                f"INSERT INTO {table} ({cols}) VALUES ({placeholders}) ON CONFLICT {conflict}",
                list(values.values())
            )
            self.conn.commit()
        except sql.Error as e:
            logger.error("Error inserting into %s: %s", table, e)
            self.conn.rollback()

    def lookup(self, table: str, conditions: dict[str, Any] = {}) -> dict:
        params = list(conditions.values())
        where = ""
        if conditions:
            clauses = " AND ".join(f"{col} = %s" for col in conditions.keys())
            where = f" WHERE {clauses}"
        try:
            self.cur.execute(f"SELECT * FROM {table}{where}", params)
            if not self.cur.description:
                return {}
            cols = [desc[0] for desc in self.cur.description]
            return {
                row[0]: dict(zip(cols[1:], row[1:]))
                for row in self.cur.fetchall()
            }
        except sql.Error as e:
            logger.error("Error looking up %s: %s", table, e)
            self.conn.rollback()
            return {}

    def delete(self, table: str, conditions: dict[str, Any]):
        clauses = " AND ".join(f"{col} = %s" for col in conditions.keys())
        try:
            self.cur.execute(f"DELETE FROM {table} WHERE {clauses}", list(conditions.values()))
            self.conn.commit()
        except sql.Error as e:
            logger.error("Error deleting from %s: %s", table, e)
            self.conn.rollback()

    def update(self, table: str, values: dict[str, Any], conditions: dict[str, Any]):
        set_clause = ", ".join(f"{col} = %s" for col in values.keys())
        where_clause = " AND ".join(f"{col} = %s" for col in conditions.keys())
        params = list(values.values()) + list(conditions.values())
        try:
            self.cur.execute(
                f"UPDATE {table} SET {set_clause} WHERE {where_clause}",
                params
            )
            self.conn.commit()
        except sql.Error as e:
            logger.error("Error updating %s: %s", table, e)
            self.conn.rollback()

    def close(self):
        self.cur.close()
        self.conn.close()
        logger.info("Connection closed.")

if __name__ == "__main__":
    if "--notes-only" in sys.argv:
        main_notes_only()
    else:
        main()