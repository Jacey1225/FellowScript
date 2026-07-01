from fastapi import FastAPI, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from routes.notes import notes_router
from routes.messaging import ws_router, chime_router
from routes.community import group_router, friend_router
from routes.filtering import filter_router, sorting_router
from routes.devotion import devo_router
from routes.agent import agent_router
from schemas.users import SignUp, Login, UpdateUser, User
import uvicorn
import bcrypt
import os
import json
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s - %(message)s")


app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(notes_router)
app.include_router(ws_router)
app.include_router(chime_router)
app.include_router(group_router)
app.include_router(friend_router)
app.include_router(filter_router)
app.include_router(sorting_router)
app.include_router(devo_router)
app.include_router(agent_router)

main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
user_path = "data/users.json"

# ── Helpers ───────────────────────────────────────────────────────────────────

def load_users() -> dict:
    """Load all user records from the JSON data store.

    Returns:
        dict: Mapping of user_id -> user data dict. Returns an empty dict
            if the file does not exist or contains invalid JSON.
    """
    path = os.path.join(main_path, user_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}


def save_users(users: dict) -> None:
    """Persist all user records to the JSON data store.

    Creates the parent directory if it does not already exist.

    Args:
        users: Mapping of user_id -> user data dict to write.
    """
    path = os.path.join(main_path, user_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(users, f, indent=2)


def find_by_username(users: dict, username: str) -> tuple[str, dict] | None:
    """Search the user store for a record matching the given username.

    Args:
        users: Full user mapping as returned by ``load_users()``.
        username: The username string to search for (case-sensitive).

    Returns:
        A ``(user_id, user_data)`` tuple if a match is found, otherwise ``None``.
    """
    for uid, data in users.items():
        if data.get("username") == username:
            return uid, data
    return None


# ── Routes ────────────────────────────────────────────────────────────────────

@app.post("/signup", status_code=201)
async def signup(info: SignUp, response: Response) -> dict:
    """Register a new user account.

    Hashes the provided plain-text password with bcrypt and writes the new
    user to the data store. Sets a 30-day ``user_id`` cookie on the response.

    Args:
        info: Sign-up payload containing username, email, and plain_pass.
        response: FastAPI response object used to attach the session cookie.

    Returns:
        dict: The new user record (excludes hash_pass).

    Raises:
        HTTPException 409: If the username is already registered.
    """
    users = load_users()
    if find_by_username(users, info.username):
        raise HTTPException(status_code=409, detail="username already registered")
    user = User(
        user_id=info.user_id,
        username=info.username,
        email=info.email,
        hash_pass=bcrypt.hashpw(info.plain_pass.encode(), bcrypt.gensalt()).decode()
    )
    users[user.user_id] = user.model_dump(exclude={"user_id"})
    save_users(users)
    response.set_cookie(key="user_id", value=user.user_id, httponly=False, secure=True, max_age=60 * 60 * 24 * 30, samesite="lax")
    return user.model_dump(exclude={"hash_pass"})


@app.post("/login")
async def login(info: Login, response: Response) -> dict:
    """Authenticate a user and issue a session cookie.

    Verifies the plain-text password against the stored bcrypt hash.
    Sets a 30-day ``user_id`` cookie on success.

    Args:
        info: Login payload containing username and plain_pass.
        response: FastAPI response object used to attach the session cookie.

    Returns:
        dict: The authenticated user's data (excludes hash_pass).

    Raises:
        HTTPException 404: If no user with the given username exists.
        HTTPException 401: If the password does not match.
    """
    users = load_users()
    result = find_by_username(users, info.username)
    if not result:
        raise HTTPException(status_code=404, detail="User not found")
    uid, data = result
    if not bcrypt.checkpw(info.plain_pass.encode(), data["hash_pass"].encode()):
        raise HTTPException(status_code=401, detail="Incorrect password")

    response.set_cookie(key="user_id", value=uid, httponly=False, secure=True, max_age=60 * 60 * 24 * 30, samesite="lax")
    return {"user_id": uid, **{k: v for k, v in data.items() if k != "hash_pass"}}


@app.get("/user/{user_id}")
async def get_user(user_id: str) -> dict:
    """Retrieve a single user's public profile.

    Args:
        user_id: UUID of the user to look up.

    Returns:
        dict: The user's data (excludes hash_pass).

    Raises:
        HTTPException 404: If no user with the given ID exists.
    """
    users = load_users()
    if user_id not in users:
        raise HTTPException(status_code=404, detail="User not found")
    data = users[user_id]
    return {"user_id": user_id, **{k: v for k, v in data.items() if k != "hash_pass"}}


@app.put("/user/{user_id}")
async def update_user(user_id: str, info: UpdateUser) -> dict:
    """Update mutable fields on a user account.

    Only fields provided (non-None) in ``info`` are updated. Passwords are
    re-hashed with bcrypt before storage.

    Args:
        user_id: UUID of the user to update.
        info: Partial update payload; any combination of username, email,
            and plain_pass may be supplied.

    Returns:
        dict: The updated user record (excludes hash_pass).

    Raises:
        HTTPException 404: If no user with the given ID exists.
    """
    users = load_users()
    if user_id not in users:
        raise HTTPException(status_code=404, detail="User not found")
    if info.username:
        users[user_id]["username"] = info.username
    if info.email:
        users[user_id]["email"] = info.email
    if info.plain_pass:
        users[user_id]["hash_pass"] = bcrypt.hashpw(
            info.plain_pass.encode(), bcrypt.gensalt()
        ).decode()
    save_users(users)
    return {"user_id": user_id, **{k: v for k, v in users[user_id].items() if k != "hash_pass"}}


@app.delete("/user/{user_id}", status_code=204)
async def delete_user(user_id: str) -> None:
    """Permanently remove a user account from the data store.

    Args:
        user_id: UUID of the user to delete.

    Raises:
        HTTPException 404: If no user with the given ID exists.
    """
    users = load_users()
    if user_id not in users:
        raise HTTPException(status_code=404, detail="User not found")
    del users[user_id]
    save_users(users)


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True, log_level="info")
