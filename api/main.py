from fastapi import FastAPI, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from routes.notes import notes_router
from routes.messaging import ws_router
from routes.community import group_router, friend_router
from routes.filtering import filter_router, sorting_router
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
app.include_router(group_router)
app.include_router(friend_router)
app.include_router(filter_router)
app.include_router(sorting_router)

main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
user_path = "data/users.json"

# ── Helpers ───────────────────────────────────────────────────────────────────

def load_users() -> dict:
    path = os.path.join(main_path, user_path)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}

def save_users(users: dict) -> None:
    path = os.path.join(main_path, user_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(users, f, indent=2)

def find_by_username(users: dict, username: str) -> tuple[str, dict] | None:
    for uid, data in users.items():
        if data.get("username") == username:
            return uid, data
    return None


# ── Routes ────────────────────────────────────────────────────────────────────

@app.post("/signup", status_code=201)
async def signup(info: SignUp, response: Response):
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
async def login(info: Login, response: Response):
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
async def get_user(user_id: str):
    users = load_users()
    if user_id not in users:
        raise HTTPException(status_code=404, detail="User not found")
    data = users[user_id]
    return {"user_id": user_id, **{k: v for k, v in data.items() if k != "hash_pass"}}


@app.put("/user/{user_id}")
async def update_user(user_id: str, info: UpdateUser):
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
async def delete_user(user_id: str):
    users = load_users()
    if user_id not in users:
        raise HTTPException(status_code=404, detail="User not found")
    del users[user_id]
    save_users(users)


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True, log_level="info")