from fastapi import WebSocket
from schemas.message import Message, Group
from schemas.users import User, Note
import os
import json

main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../..")

# MARK:Messages ───────────────────────────────────────────────────────────────────

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

def read_messages(host_user: str, users: list[str], group_id: str="") -> tuple[list, list]:
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

def format_messages(messages: list[dict]):
        new_messages = []
        for msg in messages:
            if isinstance(msg.get("from_user"), str):
                new_msg = Message(**msg)
                uid: str = msg.get("from_user") #type: ignore
                users = fetch_users([uid])
                if users:
                    new_msg.from_user = users[-1].username
                new_messages.append(new_msg.model_dump())
        return new_messages

# MARK:Users ──────────────────────────────────────────────────────────────────────

user_path = "data/users.json"

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

# MARK:Groups ─────────────────────────────────────────────────────────────────────

groups_path = "data/groups.json"

def load_groups() -> dict:
    path = os.path.join(main_path, groups_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}

def save_groups(groups: dict) -> None:
    with open(os.path.join(main_path, groups_path), 'w') as f:
        json.dump(groups, f, indent=2)


# MARK:Notes ─────────────────────────────────────────────────────────────────────
notes_path = "data/notes.json"

def load_notes():
    path = os.path.join(main_path, notes_path)
    if not os.path.exists(path):
        return {}
    
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}
    
def save_notes(notes: dict):
    with open(os.path.join(main_path, notes_path), 'w') as f:
        json.dump(notes, f, indent=2)

class ConnectionManager:
    def __init__(self):
        self.active_connections: dict[str, WebSocket] = {}

    async def connect(self, user_id: str, ws: WebSocket):
        await ws.accept()
        self.active_connections[user_id] = ws

    async def disconnect(self, user_id: str):
        self.active_connections.pop(user_id, None)

    async def send_msg(self, payload: dict):
        to_users = payload.get("to_users")
        if not to_users:
            return
        save_message(Message(**payload))
        frame = {
            "from_user": payload.get("from_user"),
            "text":      payload.get("text"),
            "group_id": payload.get("group_id"),
            "timestamp": payload.get("timestamp"),
        }
        for uid in to_users:
            ws = self.active_connections.get(uid)
            if ws:
                await ws.send_json(frame)

    async def broadcast(self, message: dict):
        for ws in self.active_connections.values():
            await ws.send_json(message)


class GroupsManager:
    def __init__(self, user_id: str, group_id: str = ""):
        self.user_id  = user_id
        self.group_id = group_id
        result = fetch_users([user_id])
        self.user: User = result[-1] if result else User()

    def create_group(self, users: list[str], group: Group):
        groups = load_groups()
        groups[group.group_id] = {"title": group.title, "users": group.users}
        save_groups(groups)

        members = fetch_users(users)
        for member in members:
            if group.group_id not in member.groups:
                member.groups.append(group.group_id)
        update_users(members)       

    def fetch_group(self) -> dict:
        groups = load_groups()
        group  = groups.get(self.group_id)
        if not group:
            return {"error": "Group not found"}
        other_users = [u for u in group["users"] if u != self.user_id]
        usernames = fetch_users(other_users)
        host_msgs, other_msgs = read_messages(self.user_id, other_users, self.group_id)

        return {
            "group":      group,
            "members":    usernames,
            "host_msgs":  format_messages(host_msgs),
            "other_msgs": format_messages(other_msgs),
        }

    def fetch_notes(self) -> dict:
        notes = load_notes()
        group_notes = {}

        for note_id, data in notes.items():
            note = Note(**data)
            if note.group_id != self.group_id or note.is_reply:
                continue
            user = fetch_users([note.user])
            if not user:
                continue
            username = user[-1].username
            if username not in group_notes:
                group_notes[username] = {}
            group_notes[username][note_id] = note.model_dump(exclude={"user"})

        return group_notes
    
    def fetch_replies(self, note_id: str):
        notes = load_notes()
        note_info = notes.get(note_id)
        note_replies = []

        if not note_info:
            return {"error": "cannot find note"}
        note = Note(**note_info)
        reply_ids = note.replies
        for _id in reply_ids:
            reply_info = notes.get(_id)
            if not reply_info:
                continue
            reply = Note(**reply_info)
            reply_uid = reply.user
            user_info = fetch_users([reply_uid])
            if not user_info:
                continue
            user = user_info[-1]
            username = user.username
            reply.user = username
            note_replies.append(reply.model_dump())

        return note_replies

    def fetch_highlights(self) -> dict:
        groups  = load_groups()
        group   = groups.get(self.group_id, {})
        members = fetch_users(group.get("users", []))
        return {u.user_id: u.highlights for u in members}

    def remove_group(self):
        if not self.group_id:
            return
        groups = load_groups()
        group  = groups.pop(self.group_id, None)
        if not group:
            return
        save_groups(groups)
        members = fetch_users(group.get("users", []))
        for member in members:
            if self.group_id in member.groups:
                member.groups.remove(self.group_id)
        update_users(members)

    def update_group(self, group: Group):
        if not self.group_id:
            return
        groups = load_groups()
        if self.group_id not in groups:
            return
        groups[self.group_id] = {"title": group.title, "users": group.users}
        users = fetch_users(group.users)
        for user in users:
            if self.group_id not in user.groups:
                user.groups.append(self.group_id)
        save_groups(groups)
        update_users(users)
class FriendsManager:
    def __init__(self, user_id: str):
        self.user_id = user_id
        result = fetch_users([user_id])
        self.user = User()
        if result:
            self.user: User = result[-1]
        

    def send_add_request(self, friend_username: str):
        result = find_by_username(friend_username)
        if result is None:
            return {"error": "User not found"}
        friend_id, friend_data = result
        if friend_id == self.user_id:
            return {"error": "Cannot add yourself"}
        friend = User.model_validate({"user_id": friend_id, **friend_data})
        if self.user_id not in friend.friend_requests:
            friend.friend_requests.append(self.user_id)
        update_users([friend])

    def add_friend(self, friend_username: str):
        result = find_by_username(friend_username)
        if result is None:
            return {"error": "User not found"}
        friend_id, friend_data = result
        friend = User.model_validate({"user_id": friend_id, **friend_data})
        if friend_id not in self.user.friends:
            self.user.friends.append(friend_id)
        if friend_id in self.user.friend_requests:
            self.user.friend_requests.remove(friend_id)
        if self.user_id not in friend.friends:
            friend.friends.append(self.user_id)
        update_users([self.user, friend])

    def get_friends(self) -> list[dict]:
        friends = fetch_users(self.user.friends)
        return [f.model_dump(exclude={"hash_pass"}) for f in friends]

    def read_friend(self, friend_id: str) -> dict:
        friends = fetch_users([friend_id])
        if not friends:
            return {"error": "Friend not found"}
        host_msgs, other_msgs = read_messages(self.user_id, [friend_id])
        return {
            "friend":     friends[0].model_dump(exclude={"hash_pass"}),
            "host_msgs":  format_messages(host_msgs),
            "other_msgs": format_messages(other_msgs),
        }

    def remove_friend(self, friend_id: str):
        if friend_id in self.user.friends:
            self.user.friends.remove(friend_id)
        friends = fetch_users([friend_id])
        if friends:
            other = friends[0]
            if self.user_id in other.friends:
                other.friends.remove(self.user_id)
            update_users([self.user, other])
        else:
            update_users([self.user])
