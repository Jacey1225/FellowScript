import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import json
from api.schemas.users import User, Note
from datetime import datetime, timedelta



def load_users(user_path="data/users.json"):
    with open(user_path, 'r') as f:
        content = f.read()
        users = json.loads(content)
    return users

def load_notes(notes_path = "data/notes.json"):
    with open(notes_path, 'r') as f:
        notes = json.load(f)
    return notes

def update_users(users: dict, user_path="data/new_users.json"):
    with open(user_path, 'w') as file:
        json.dump(users, file, indent=2)

def update_notes(notes: dict, notes_path="data/new_notes.json"):
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


def give_timestamps(notes: dict):
    notes_copy = dict(notes)
    for note_id, data in notes_copy.items():
        print(f"note: {data}")
        notes_copy[note_id]["timestamp"] = str(datetime.now() - timedelta(days=7))
    
    return notes_copy

def main():
    notes = load_notes()
    new_notes = give_timestamps(notes)
    update_notes(new_notes)
    
if __name__ == "__main__": 
    main()