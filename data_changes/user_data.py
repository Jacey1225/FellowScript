import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import json
from api.schemas.users import User

main_path = os.getcwd()

def get_users(filepath) -> dict:
    with open(filepath, 'r') as f:
        content = json.load(f)

    print(f"got users: {content}")
    return content

def write_to_users(filepath, users: dict):
    with open(filepath, 'w') as f:
        json.dump(users, f, indent=4)

def add_bookmarks(infile: str, outfile: str):
    users = get_users(infile)
    for user_id, user in users.items():
        new_user = User(**user)
        users[user_id] = new_user.model_dump(exclude={"user_id"})

    write_to_users(outfile, users)

if __name__ == "__main__":
    infile = os.path.join(main_path, "data/users.json")
    outfile = os.path.join(main_path, "data/new_users.json")
    add_bookmarks(infile, outfile)