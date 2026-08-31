import os
import json
from schemas.users import User
from schemas.message import Message
from schemas.devotion import DevotionPlan
import logging
from db import DBManager as DB

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)
user_path = "data/users.json"
main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../..")
# MARK:NOTES

notes_path = "data/notes.json"

class HelpNotes(DB):
    def __init__(self):
        super().__init__()

    def load_notes(self) -> dict:
        table = "notes"
        notes = self.lookup(table)
        return notes

    def save_notes(self, notes: dict) -> None:
        with open(os.path.join(main_path, notes_path), 'w') as f:
            json.dump(notes, f, indent=2)

# MARK:MSGS

message_path = "data/messages.json"


def load_messages() -> list:
    path = os.path.join(main_path, message_path)
    if not os.path.exists(path):
        return []
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return []


def save_message(message: Message) -> None:
    messages = load_messages()
    messages.append(message.model_dump())
    with open(os.path.join(main_path, message_path), 'w') as f:
        json.dump(messages, f, indent=2)


def read_messages(host_user: str, users: list[str], group_id: str = "") -> tuple[list, list]:
    messages = load_messages()
    host_msgs: list = []
    other_msgs: list = []
    for msg in messages:
        from_user = msg.get("from_user")
        to_users  = msg.get("to_users", [])
        if (msg.get("group_id") or "") != group_id:
            continue
        if from_user == host_user and any(u in users for u in to_users):
            host_msgs.append(msg)
        elif from_user in users and host_user in to_users:
            other_msgs.append(msg)
    return host_msgs, other_msgs


def format_messages(messages: list[dict]) -> list[dict]:
    new_messages = []
    for msg in messages:
        from_user = msg.get("from_user")
        if isinstance(from_user, str):
            new_msg = Message(**msg)
            uid: str = from_user
            users = fetch_users([uid])
            if users:
                new_msg.from_user = users[-1].username
            new_messages.append(new_msg.model_dump())
    return new_messages

#MARK:USERS
# All user access is Postgres-backed. The JSON-era shape is reconstructed from
# the relational tables so every existing caller keeps working unchanged:
#   {uid: {username, email, hash_pass, apple_sub?, friends[], friend_requests[],
#          groups[], highlights{}, bookmarks{}}}


def load_users_data() -> dict:
    """Build the full user map from Postgres (base rows + related tables)."""
    db = DB()
    try:
        users: dict = {}
        db.cur.execute(
            "SELECT _id, username, email, hash_pass, apple_sub, google_sub, timezone, mfa_enabled, "
            "terms_accepted_at, terms_version, suspended_at, needs_profile_completion FROM users"
        )
        for (_id, username, email, hash_pass, apple_sub, google_sub, timezone, mfa_enabled,
             terms_accepted_at, terms_version, suspended_at, needs_profile_completion) in db.cur.fetchall():
            uid = str(_id)
            rec = {
                "username": username, "email": email, "hash_pass": hash_pass or "",
                "friends": [], "friend_requests": [], "groups": [],
                "highlights": {}, "bookmarks": {}, "timezone": timezone or "UTC",
                "mfa_enabled": bool(mfa_enabled),
                "terms_accepted_at": str(terms_accepted_at) if terms_accepted_at else None,
                "terms_version": terms_version,
                "suspended_at": str(suspended_at) if suspended_at else None,
                "needs_profile_completion": bool(needs_profile_completion),
            }
            if apple_sub:
                rec["apple_sub"] = apple_sub
            if google_sub:
                rec["google_sub"] = google_sub
            users[uid] = rec

        db.cur.execute("SELECT user_id, friend_id FROM user_friends")
        for u, f in db.cur.fetchall():
            u = str(u)
            if u in users:
                users[u]["friends"].append(str(f))

        db.cur.execute("SELECT to_user_id, from_user_id FROM friend_requests")
        for t, fr in db.cur.fetchall():
            t = str(t)
            if t in users:
                users[t]["friend_requests"].append(str(fr))

        db.cur.execute("SELECT user_id, key, color FROM highlights")
        for u, k, c in db.cur.fetchall():
            u = str(u)
            if u in users:
                users[u]["highlights"][k] = c

        db.cur.execute("SELECT user_id, key, label FROM bookmarks")
        for u, k, l in db.cur.fetchall():
            u = str(u)
            if u in users:
                users[u]["bookmarks"][k] = l

        db.cur.execute("SELECT _id, users FROM groups")
        for gid, members in db.cur.fetchall():
            gid = str(gid)
            for m in (members or []):
                m = str(m)
                if m in users:
                    users[m]["groups"].append(gid)
        return users
    finally:
        db.close()


def _upsert_user_row(db: DB, uid: str, d: dict) -> None:
    # suspended_at is deliberately never written here (mirrors mfa_enabled's
    # exclusion) — only backend/moderation/admin_actions.py may set it, so a
    # routine profile edit can never un-suspend someone.
    db.cur.execute(
        "INSERT INTO users (_id, username, email, hash_pass, apple_sub, google_sub, timezone, "
        "terms_accepted_at, terms_version, needs_profile_completion) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,COALESCE(%s, FALSE)) "
        "ON CONFLICT (_id) DO UPDATE SET username=EXCLUDED.username, "
        "email=EXCLUDED.email, hash_pass=EXCLUDED.hash_pass, "
        "apple_sub=COALESCE(EXCLUDED.apple_sub, users.apple_sub), "
        "google_sub=COALESCE(EXCLUDED.google_sub, users.google_sub), "
        "timezone=COALESCE(EXCLUDED.timezone, users.timezone), "
        "terms_accepted_at=COALESCE(EXCLUDED.terms_accepted_at, users.terms_accepted_at), "
        "terms_version=COALESCE(EXCLUDED.terms_version, users.terms_version), "
        "needs_profile_completion=COALESCE(EXCLUDED.needs_profile_completion, users.needs_profile_completion)",
        (uid, d.get("username", ""), d.get("email", ""),
         d.get("hash_pass", ""), d.get("apple_sub"), d.get("google_sub"),
         d.get("timezone"), d.get("terms_accepted_at"), d.get("terms_version"),
         d.get("needs_profile_completion")),
    )


def save_users_data(user_info: dict) -> None:
    """Upsert each user's base row into Postgres.

    Relations (friends, requests, highlights, bookmarks, group membership) are
    owned by their dedicated tables and written by the respective managers, so
    only the base ``users`` row is persisted here.

    Bulk, per-row-best-effort: a failure on one row is logged and rolled back
    but does not stop the rest of the batch. This is intentional for the
    multi-user callers this is meant for (e.g. auth backfills that touch the
    whole loaded table incidentally) but makes it the wrong helper for a
    single targeted edit — use ``save_user_row`` for that instead, since a
    caller returning a "saved" response can't tell here whether its one row
    was among the ones that actually landed.
    """
    db = DB()
    try:
        for uid, d in user_info.items():
            try:
                _upsert_user_row(db, uid, d)
                db.conn.commit()
            except Exception as e:
                db.conn.rollback()
                logger.error("save_users_data: failed to upsert %s: %s", uid, e)
    finally:
        db.close()


def save_user_row(uid: str, d: dict) -> None:
    """Upsert exactly one user's base row into Postgres.

    Unlike ``save_users_data`` (bulk, best-effort), this writes only the one
    row a caller actually intends to change and re-raises on failure instead
    of swallowing it into a log line — so a route like ``PUT /user/{id}`` can
    never build a "success" response from an in-memory mutation that didn't
    actually persist.
    """
    db = DB()
    try:
        _upsert_user_row(db, uid, d)
        db.conn.commit()
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


def fetch_users(user_ids: list[str]) -> list[User]:
    if not user_ids:
        return []
    db = DB()
    try:
        db.cur.execute(
            "SELECT _id, username, email, hash_pass FROM users WHERE _id = ANY(%s)",
            ([str(u) for u in user_ids],),
        )
        return [
            User(user_id=str(_id), username=username, email=email, hash_pass=hash_pass or "")
            for _id, username, email, hash_pass in db.cur.fetchall()
        ]
    finally:
        db.close()


def update_users(users: list[User]) -> None:
    """Upsert the given users' base rows into Postgres."""
    save_users_data({u.user_id: u.model_dump(exclude={"user_id"}) for u in users})


def find_by_username(username: str) -> tuple[str, dict] | None:
    db = DB()
    try:
        db.cur.execute("SELECT _id FROM users WHERE username = %s", (username,))
        row = db.cur.fetchone()
    finally:
        db.close()
    if not row:
        return None
    uid = str(row[0])
    return uid, load_users_data().get(uid, {})

#MARK:DEVOS

devotion_path = "data/devotions.json"


def _load_devotions() -> dict:
    path = os.path.join(main_path, devotion_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def _save_devotions(devotions: dict) -> None:
    path = os.path.join(main_path, devotion_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(devotions, f, indent=2)


def save_devotion(devotion: DevotionPlan) -> str:
    devotions = _load_devotions()
    devotions[devotion.id] = devotion.model_dump()
    _save_devotions(devotions)
    return devotion.id


def read_devotion(devotion_id: str) -> DevotionPlan | None:
    devotions = _load_devotions()
    data = devotions.get(devotion_id)
    if not data:
        return None
    return DevotionPlan(**data)


def remove_devotion(devotion_id: str) -> None:
    devotions = _load_devotions()
    if devotion_id not in devotions:
        return
    del devotions[devotion_id]
    _save_devotions(devotions)


def fetch_devotions_by_contact(contact_id: str) -> list[dict]:
    devotions = _load_devotions()
    return [
        data for data in devotions.values()
        if data.get("group_id") == contact_id
    ]


def add_session_participant(session_id: str, user_id: str) -> None:
    devotions = _load_devotions()
    session = devotions.get(session_id)
    if not session:
        return
    participants = session.get("participants", [])
    if user_id not in participants:
        participants.append(user_id)
    session["participants"] = participants
    devotions[session_id] = session
    _save_devotions(devotions)


def remove_session_participant(session_id: str, user_id: str) -> None:
    devotions = _load_devotions()
    session = devotions.get(session_id)
    if not session:
        return
    session["participants"] = [p for p in session.get("participants", []) if p != user_id]
    devotions[session_id] = session
    _save_devotions(devotions)


def update_devotion_data(session_id: str, devotion: DevotionPlan) -> bool:
    devotions = _load_devotions()
    if session_id not in devotions:
        return False
    existing = devotions[session_id]
    updated = devotion.model_dump()
    # Preserve fields that live updates manage — don't wipe them on an edit
    updated["participants"]     = existing.get("participants", [])
    updated["chime_meeting_id"] = existing.get("chime_meeting_id", "")
    updated["chime_meeting"]    = existing.get("chime_meeting", {})
    updated["id"] = session_id
    devotions[session_id] = updated
    _save_devotions(devotions)
    return True


def save_chime_meeting(session_id: str, meeting_id: str, meeting_data: dict) -> None:
    devotions = _load_devotions()
    session = devotions.get(session_id)
    if not session:
        return
    session["chime_meeting_id"] = meeting_id
    session["chime_meeting"]    = meeting_data
    devotions[session_id] = session
    _save_devotions(devotions)


# Expose internals so routes can batch-update sessions without extra round-trips
load_devotions = _load_devotions
save_devotions = _save_devotions

#MARK:AGENTS
