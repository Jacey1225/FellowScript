import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import json
from api.schemas.users import User, Note



def load_users(user_path="data/users.json"):
    with open(user_path, 'r') as f:
        content = f.read()
        users = json.loads(content)
    return users

def update_users(users: dict, user_path="data/new_users.json"):
    with open(user_path, 'w') as file:
        json.dump(users, file, indent=2)

def update_notes(notes: dict, notes_path="data/notes.json"):
    with open(notes_path, 'w') as file:
        json.dump(notes, file, indent=2)

def pull_notes(users: dict):
    notes: dict = {}
    for user_id, data in users.items():
        user = User(**data)
        del data["notes"]
        user_notes = user.notes

        for note_id, data in user_notes.items():
            new_note = Note(**data)
            new_note.user = user_id
            notes[note_id] = new_note.model_dump()
        
    return notes, users

def update_groups(notes: dict, group_id: str="082efb16-8605-4dbb-81a5-bb2a4bf7cb56"):
    for uid, note in notes.items():
        if note.get("public"):
            note["group_id"] = group_id

    return notes

def main():
    users = load_users()
    old_notes, new_users = pull_notes(users)
    new_notes = update_groups(old_notes)
    
    update_users(new_users)
    update_notes(new_notes)
    
if __name__ == "__main__": 
    main()