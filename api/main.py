from fastapi import FastAPI, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from routes.notes import notes_router
from routes.messaging import ws_router, chime_router
from routes.community import group_router, friend_router
from routes.filtering import filter_router, sorting_router
from routes.devotion import devo_router
from routes.agent import agent_router
from routes.notifications import notification_router
from routes.subscription import subscription_router
from schemas.users import SignUp, Login, UpdateUser, User
from pydantic import BaseModel
import uvicorn
import bcrypt
import os
import json
import uuid
import logging
import httpx
import jwt
from jwt import PyJWKClient
from db import DBManager
from backend.interactions.helpers import load_users_data, save_users_data


class GoogleAuth(BaseModel):
    credential: str


class AppleAuth(BaseModel):
    identity_token: str
    full_name: str | None = None
    email: str | None = None

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI):
    from backend.interactions.scheduler import start_scheduler
    start_scheduler()
    yield


app = FastAPI(lifespan=lifespan)

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
app.include_router(notification_router)
app.include_router(subscription_router)

main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
user_path = "data/users.json"

# ── Helpers ───────────────────────────────────────────────────────────────────

def load_users() -> dict:
    """Load all user records from Postgres (reconstructed to the legacy shape)."""
    return load_users_data()


def save_users(users: dict) -> None:
    """Upsert user base rows into Postgres."""
    save_users_data(users)


def find_by_email(users: dict, email: str) -> tuple[str, dict] | None:
    for uid, data in users.items():
        if data.get("email") == email:
            return uid, data
    return None


def persist_new_user(user: User) -> None:
    """Create a new user in BOTH stores — the single account-creation pipeline.

    Every provider (password signup, Google, Apple) must go through here so that:
      • the JSON store gets a *complete* User record (friends, friend_requests,
        groups, highlights, bookmarks — via User.model_dump), and
      • the Postgres ``users`` table gets the row that all DBManager-based
        features (friends, groups, notes, messages) query.

    Without the Postgres insert, an account exists for auth but is invisible to
    every relational feature.
    """
    save_users_data({user.user_id: user.model_dump(exclude={"user_id"})})


def find_by_apple_sub(users: dict, sub: str) -> tuple[str, dict] | None:
    """Locate a user by the stable Apple subject identifier stored at signup.

    Apple only returns the user's email/name on the *first* authorization, so
    subsequent sign-ins must be matched on the token's ``sub`` claim rather than
    on email.
    """
    for uid, data in users.items():
        if data.get("apple_sub") == sub:
            return uid, data
    return None


def find_by_google_sub(users: dict, sub: str) -> tuple[str, dict] | None:
    """Locate a user by the stable Google subject identifier.

    Mirrors the Apple flow: match returning Google users on the token's ``sub``
    (which never changes) rather than email, which a user could change.
    """
    for uid, data in users.items():
        if data.get("google_sub") == sub:
            return uid, data
    return None


# Apple issues identity tokens signed with rotating RSA keys published at this
# JWKS endpoint. PyJWKClient caches the fetched keys between requests.
_APPLE_ISSUER   = "https://appleid.apple.com"
_APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
_apple_jwk_client = PyJWKClient(_APPLE_JWKS_URL)


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
    persist_new_user(user)
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
    db = DBManager()
    try:
        db.cur.execute("DELETE FROM users WHERE _id = %s", (user_id,))
        deleted = db.cur.rowcount
        db.conn.commit()
    finally:
        db.close()
    if not deleted:
        raise HTTPException(status_code=404, detail="User not found")


@app.post("/auth/google")
async def google_auth(info: GoogleAuth, response: Response) -> dict:
    async with httpx.AsyncClient() as client:
        r = await client.get(
            "https://oauth2.googleapis.com/tokeninfo",
            params={"id_token": info.credential},
            timeout=10.0,
        )
    if r.status_code != 200:
        raise HTTPException(status_code=401, detail="Invalid Google token")

    token_data = r.json()
    client_id = os.getenv("CLIENT_ID", "")
    if token_data.get("aud") != client_id:
        raise HTTPException(status_code=401, detail="Token audience mismatch")

    email = token_data.get("email", "")
    if not email:
        raise HTTPException(status_code=401, detail="No email in Google token")

    sub = token_data.get("sub", "")
    given_name = token_data.get("given_name") or token_data.get("name") or email.split("@")[0]

    users = load_users()

    # Match on the stable Google identifier first, then fall back to email so an
    # existing password/Apple account with the same address is linked, not duped.
    result = find_by_google_sub(users, sub) if sub else None
    if not result and email:
        result = find_by_email(users, email)

    if result:
        uid, data = result
        # Backfill google_sub on accounts first created via another provider.
        if sub and data.get("google_sub") != sub:
            users[uid]["google_sub"] = sub
            save_users(users)
            data = users[uid]
    else:
        uid = str(uuid.uuid4())
        base = given_name.replace(" ", "_").lower()[:16]
        username = base
        existing = {d.get("username") for d in users.values()}
        counter = 1
        while username in existing:
            username = f"{base}{counter}"
            counter += 1
        # Same creation pipeline as password signup — writes to both stores.
        user = User(user_id=uid, username=username, email=email, hash_pass="")
        persist_new_user(user)
        # google_sub isn't a User schema field; record it so returning Google
        # sign-ins match on the stable identifier.
        if sub:
            users = load_users()
            users[uid]["google_sub"] = sub
            save_users(users)
            data = users[uid]
        else:
            data = user.model_dump(exclude={"user_id"})

    response.set_cookie(
        key="user_id", value=uid, httponly=False, secure=True,
        max_age=60 * 60 * 24 * 30, samesite="lax",
    )
    return {"user_id": uid, **{k: v for k, v in data.items() if k != "hash_pass"}}


@app.post("/auth/apple")
async def apple_auth(info: AppleAuth, response: Response) -> dict:
    """Authenticate a Sign in with Apple identity token.

    Verifies the token's RSA signature against Apple's published JWKS, plus its
    issuer and audience, then finds or creates a user keyed on the stable ``sub``
    claim. ``full_name`` / ``email`` are only supplied by the client on the very
    first authorization, so they are used only when creating a new account.
    """
    audience = os.getenv("APPLE_CLIENT_ID", "com.fellowscript.app")

    # Verify signature + standard claims against Apple's public keys.
    try:
        signing_key = _apple_jwk_client.get_signing_key_from_jwt(info.identity_token)
        claims = jwt.decode(
            info.identity_token,
            signing_key.key,
            algorithms=["RS256"],
            audience=audience,
            issuer=_APPLE_ISSUER,
        )
    except Exception as e:
        logger.warning("Apple token verification failed: %s", e)
        raise HTTPException(status_code=401, detail="Invalid Apple token")

    sub = claims.get("sub")
    if not sub:
        raise HTTPException(status_code=401, detail="No subject in Apple token")

    # Email may come from the token (preferred) or the first-auth request body.
    email = claims.get("email") or info.email or ""

    users = load_users()

    # Match on the stable Apple identifier first, then fall back to email so an
    # existing password/Google account with the same address is linked, not duped.
    result = find_by_apple_sub(users, sub)
    if not result and email:
        result = find_by_email(users, email)

    if result:
        uid, data = result
        # Backfill apple_sub on accounts first created via another provider.
        if data.get("apple_sub") != sub:
            users[uid]["apple_sub"] = sub
            save_users(users)
            data = users[uid]
    else:
        uid = str(uuid.uuid4())
        base = (info.full_name or (email.split("@")[0] if email else "") or "apple_user")
        base = base.replace(" ", "_").lower()[:16] or "apple_user"
        username = base
        existing = {d.get("username") for d in users.values()}
        counter = 1
        while username in existing:
            username = f"{base}{counter}"
            counter += 1
        # Same creation pipeline as password signup — writes to both stores.
        user = User(user_id=uid, username=username, email=email, hash_pass="")
        persist_new_user(user)
        # apple_sub isn't a User schema field; record it in the JSON store so a
        # returning Apple sign-in matches on the stable identifier.
        users = load_users()
        users[uid]["apple_sub"] = sub
        save_users(users)
        data = users[uid]

    response.set_cookie(
        key="user_id", value=uid, httponly=False, secure=True,
        max_age=60 * 60 * 24 * 30, samesite="lax",
    )
    return {"user_id": uid, **{k: v for k, v in data.items() if k != "hash_pass"}}


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True, log_level="info")
