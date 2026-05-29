import os
import json
from schemas.users import User
from schemas.message import Message
from schemas.devotion import DevotionPlan

user_path = "data/users.json"
main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../..")

# MARK:NOTES

notes_path = "data/notes.json"


def load_notes() -> dict:
    path = os.path.join(main_path, notes_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def save_notes(notes: dict) -> None:
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
    path = os.path.join(main_path, user_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def fetch_users(user_ids: list[str]) -> list[User]:
    user_info = load_users_data()
    return [
        User.model_validate({"user_id": uid, **user_info[uid]})
        for uid in user_ids
        if uid in user_info
    ]


def update_users(users: list[User]) -> None:
    user_info = load_users_data()
    for user in users:
        user_info[user.user_id] = user.model_dump(exclude={"user_id"})
    with open(os.path.join(main_path, user_path), 'w') as f:
        json.dump(user_info, f, indent=2)


def find_by_username(username: str) -> tuple[str, dict] | None:
    for uid, data in load_users_data().items():
        if data.get("username") == username:
            return uid, data
    return None

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
    updated = devotion.model_dump()
    # Preserve live participants — don't wipe them on an edit
    updated["participants"] = devotions[session_id].get("participants", [])
    updated["id"] = session_id
    devotions[session_id] = updated
    _save_devotions(devotions)
    return True
