import os
import json
from schemas.users import User
from schemas.message import Message
from api.schemas.devotion import DevotionPlan

user_path = "data/users.json"
main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../..")

# MARK:NOTES

notes_path = "data/notes.json"


def load_notes() -> dict:
    """Load all notes from the JSON data store.

    Returns:
        dict: Mapping of note_id -> note data dict. Returns an empty dict
            if the file does not exist or contains invalid JSON.
    """
    path = os.path.join(main_path, notes_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def save_notes(notes: dict) -> None:
    """Persist all notes to the JSON data store.

    Args:
        notes: Mapping of note_id -> note data dict to write.
    """
    with open(os.path.join(main_path, notes_path), 'w') as f:
        json.dump(notes, f, indent=2)

# MARK:MSGS

message_path = "data/messages.json"


def load_messages() -> list:
    """Load all messages from the JSON data store.

    Returns:
        list: List of message dicts. Returns an empty list if the file does
            not exist or contains invalid JSON.
    """
    path = os.path.join(main_path, message_path)
    if not os.path.exists(path):
        return []
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return []


def save_message(message: Message) -> None:
    """Append a single message to the persistent message store.

    Args:
        message: The ``Message`` instance to persist.
    """
    messages = load_messages()
    messages.append(message.model_dump())
    with open(os.path.join(main_path, message_path), 'w') as f:
        json.dump(messages, f, indent=2)


def read_messages(host_user: str, users: list[str], group_id: str = "") -> tuple[list, list]:
    """Retrieve the conversation history between a host user and a set of users.

    Filters messages by the given ``group_id`` context (empty string for DMs).
    Splits results into messages sent by the host and messages sent by the
    other party.

    Args:
        host_user: User ID of the requesting user.
        users: List of user IDs representing the other party (single ID for
            DMs, multiple for group context).
        group_id: Group ID to scope the query to. Defaults to ``""`` for DMs.

    Returns:
        tuple[list, list]: ``(host_msgs, other_msgs)`` where each is a list
            of message dicts sent by the respective side.
    """
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
    """Replace user IDs with usernames in a list of message dicts.

    Looks up each message's ``from_user`` ID and substitutes the corresponding
    username so the client receives human-readable sender names.

    Args:
        messages: List of raw message dicts (``from_user`` is a user ID).

    Returns:
        list[dict]: Messages with ``from_user`` replaced by the username where
            a matching user record is found.
    """
    new_messages = []
    for msg in messages:
        if isinstance(msg.get("from_user"), str):
            new_msg = Message(**msg)
            uid: str = msg.get("from_user")  # type: ignore
            users = fetch_users([uid])
            if users:
                new_msg.from_user = users[-1].username
            new_messages.append(new_msg.model_dump())
    return new_messages

#MARK:USERS

def load_users_data() -> dict:
    """Load all user records from the JSON data store.

    Returns:
        dict: Mapping of user_id -> user data dict. Returns an empty dict
            if the file does not exist or contains invalid JSON.
    """
    path = os.path.join(main_path, user_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def fetch_users(user_ids: list[str]) -> list[User]:
    """Retrieve ``User`` model instances for the given IDs.

    Silently skips any IDs not present in the data store.

    Args:
        user_ids: List of user UUIDs to look up.

    Returns:
        list[User]: Validated ``User`` instances for each found ID, in the
            same order as ``user_ids``.
    """
    user_info = load_users_data()
    return [
        User.model_validate({"user_id": uid, **user_info[uid]})
        for uid in user_ids
        if uid in user_info
    ]


def update_users(users: list[User]) -> None:
    """Write updated ``User`` records back to the data store.

    Args:
        users: List of ``User`` instances whose data should be persisted.
            Existing records for each user_id are overwritten.
    """
    user_info = load_users_data()
    for user in users:
        user_info[user.user_id] = user.model_dump(exclude={"user_id"})
    with open(os.path.join(main_path, user_path), 'w') as f:
        json.dump(user_info, f, indent=2)


def find_by_username(username: str) -> tuple[str, dict] | None:
    """Search the user store for a record matching the given username.

    Args:
        username: The username string to search for (case-sensitive).

    Returns:
        tuple[str, dict] | None: ``(user_id, user_data)`` if found,
            otherwise ``None``.
    """
    for uid, data in load_users_data().items():
        if data.get("username") == username:
            return uid, data
    return None

#MARK:DEVOS
devotion_path = "data/devotions.json"

def save_devotion(devotion: DevotionPlan):
    path = os.path.join(main_path, devotion_path)
    with open(path, 'r') as f:
        devotions = json.load(f)

    devotions[devotion._id] = devotion.model_dump(exclude={"_id"})
    with open(path, 'w') as f:
        json.dump(devotions, f, indent=2)
        

def read_devotion(devotion_id: str):
    path = os.path.join(main_path, devotion_path)
    with open(path, 'r') as f:
        devotions = json.load(f)

    if not devotions[devotion_id]:
        return {"error": "cannot find devotion ID"}
    return DevotionPlan(**devotions[devotion_id])

def remove_devotion(devotion_id: str):
    path = os.path.join(main_path, devotion_path)
    with open(path, 'r') as f:
        devotions = json.load(f)

    if not devotion_id in devotions:
        return
    del devotions[devotion_id]
    with open(path, 'w') as f:
        json.dump(devotions, f, indent=2)