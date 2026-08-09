from fastapi import FastAPI, HTTPException, Response, Depends, Request
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
from routes.donation import donation_router
from routes.reports import report_router
from routes.blocks import block_router
from schemas.users import SignUp, Login, UpdateUser, User, CURRENT_TERMS_VERSION
from datetime import datetime, timezone
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
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware
from db import DBManager, BACKUP_DB_NAME
from backend.interactions.helpers import load_users_data, save_users_data, save_user_row
from backend.subscription.subscriptions import SubscriptionsManager
from backend.auth.sessions import SessionManager
from backend.auth.password_reset import PasswordResetManager
from backend.auth.mfa import MFAManager
from backend.auth.dependencies import get_current_user, require_match, SESSION_COOKIE
from backend.email.ses_client import send_email, EmailSendError
from backend.email.templates import password_reset_email, mfa_code_email, mfa_setup_code_email


def get_client_ip(request: Request) -> str:
    """Resolve the true visitor IP behind Cloudflare + nginx.

    Production sits behind Cloudflare, which terminates the client's real
    connection and reconnects to our nginx box from one of its own rotating
    edge IPs. uvicorn only trusts the single nginx hop (127.0.0.1), so
    ``request.client.host`` / slowapi's default ``get_remote_address``
    resolves to that rotating Cloudflare edge IP, not the actual visitor —
    which defeats per-IP rate limiting entirely (every request looks like a
    different client). Cloudflare's own ``CF-Connecting-IP`` header carries
    the real visitor IP directly, so prefer it; fall back to the standard
    resolution for local/non-Cloudflare requests (tests, direct access).
    """
    return request.headers.get("cf-connecting-ip") or get_remote_address(request)


class GoogleAuth(BaseModel):
    credential: str
    # Only enforced on the new-account branch below — these classes also serve
    # existing-user sign-ins, where the field is irrelevant.
    terms_accepted: bool = False


class AppleAuth(BaseModel):
    identity_token: str
    full_name: str | None = None
    email: str | None = None
    terms_accepted: bool = False


class PasswordResetRequest(BaseModel):
    email: str


class PasswordResetConfirm(BaseModel):
    token: str
    new_password: str


class MFACode(BaseModel):
    code: str


class MFAVerifyLogin(BaseModel):
    user_id: str
    code: str


class MFADisable(BaseModel):
    plain_pass: str

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI):
    from backend.interactions.scheduler import start_scheduler
    start_scheduler()
    yield


app = FastAPI(lifespan=lifespan)

# Rate-limits brute-force-able unauthenticated endpoints (signup/login) by
# client IP. Authenticated routes (e.g. PUT /user/{id}) already require a
# valid session and aren't guessable, so they're out of scope for this.
limiter = Limiter(key_func=get_client_ip)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
app.add_middleware(SlowAPIMiddleware)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://fellowscript.com",
        "https://www.fellowscript.com",
        "http://localhost:5173",
    ],
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
app.include_router(donation_router)
app.include_router(report_router)
app.include_router(block_router)

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


def issue_session(response: Response, user_id: str) -> None:
    """Create a server-side session for ``user_id`` and set its cookie.

    The cookie carries only an opaque random token (never the user_id itself)
    and is httponly so it can't be read or exfiltrated by injected JS.
    """
    db = SessionManager()
    try:
        token = db.create_session(user_id)
    finally:
        db.close()
    response.set_cookie(
        key=SESSION_COOKIE, value=token, httponly=True, secure=True,
        max_age=60 * 60 * 24 * 30, samesite="lax",
    )


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
@limiter.limit("5/minute")
async def signup(request: Request, info: SignUp, response: Response) -> dict:
    """Register a new user account.

    Hashes the provided plain-text password with bcrypt and writes the new
    user to the data store. Sets a 30-day ``user_id`` cookie on the response.

    Rate-limited to 5 attempts/minute per IP to slow down mass account
    creation and username-enumeration probing.

    Args:
        request: FastAPI request object (required by the rate limiter).
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
        hash_pass=bcrypt.hashpw(info.plain_pass.encode(), bcrypt.gensalt()).decode(),
        # Server-stamped, never client-supplied — SignUp.terms_accepted is
        # validated True-only by schemas/users.py, this just records when/what.
        terms_accepted_at=str(datetime.now(timezone.utc)),
        terms_version=CURRENT_TERMS_VERSION,
    )
    persist_new_user(user)
    sm = SubscriptionsManager()
    try:
        sm.create_free_plan(user.user_id)
    finally:
        sm.close()
    issue_session(response, user.user_id)
    return user.model_dump(exclude={"hash_pass"})


@app.post("/login")
@limiter.limit("10/minute")
async def login(request: Request, info: Login, response: Response) -> dict:
    """Authenticate a user and issue a session cookie — or, if 2FA is enabled
    on the account, pause and email a login code instead.

    Verifies the plain-text password against the stored bcrypt hash. If the
    account has ``mfa_enabled``, no session is issued yet: a 6-digit code is
    emailed and the response signals the caller to collect it and call
    ``/auth/mfa/verify-login`` to finish. Otherwise sets a 30-day session
    cookie immediately, as before.

    Rate-limited to 10 attempts/minute per IP to slow down password
    brute-forcing and credential stuffing.

    Args:
        request: FastAPI request object (required by the rate limiter).
        info: Login payload containing username and plain_pass.
        response: FastAPI response object used to attach the session cookie.

    Returns:
        dict: Either the authenticated user's data (excludes hash_pass), or
            ``{"mfa_required": True, "user_id": ...}`` if a code was emailed.

    Raises:
        HTTPException 404: If no user with the given username exists.
        HTTPException 401: If the password does not match.
        HTTPException 403: If the account has been suspended for a Terms violation.
        HTTPException 503: If the account has 2FA enabled but the code email
            could not be sent.
    """
    users = load_users()
    result = find_by_username(users, info.username)
    if not result:
        raise HTTPException(status_code=404, detail="User not found")
    uid, data = result
    if not bcrypt.checkpw(info.plain_pass.encode(), data["hash_pass"].encode()):
        raise HTTPException(status_code=401, detail="Incorrect password")
    if data.get("suspended_at"):
        raise HTTPException(status_code=403, detail="This account has been suspended for violating our Terms of Service.")

    if data.get("mfa_enabled"):
        mfa = MFAManager()
        try:
            code = mfa.create_code(uid)
        finally:
            mfa.close()
        subject, html_body, text_body = mfa_code_email(code)
        try:
            send_email(data["email"], subject, html_body, text_body)
        except EmailSendError:
            logger.error("Failed to send MFA login code to user %s", uid)
            raise HTTPException(
                status_code=503,
                detail="Unable to send verification code — please try again shortly",
            )
        return {"mfa_required": True, "user_id": uid}

    issue_session(response, uid)
    result_data = {"user_id": uid, **{k: v for k, v in data.items() if k != "hash_pass"}}
    if data.get("terms_version") != CURRENT_TERMS_VERSION:
        result_data["terms_reaccept_required"] = True
    return result_data


@app.post("/auth/mfa/verify-login")
@limiter.limit("10/minute")
async def mfa_verify_login(request: Request, info: MFAVerifyLogin, response: Response) -> dict:
    """Complete a login that was paused for 2FA.

    Verifies the emailed 6-digit code and, on success, issues the session
    cookie exactly as a normal password-only login would have.

    Raises:
        HTTPException 401: If the code is wrong, expired, or already used.
        HTTPException 404: If the user no longer exists.
    """
    mfa = MFAManager()
    try:
        ok = mfa.verify(info.user_id, info.code)
    finally:
        mfa.close()
    if not ok:
        raise HTTPException(status_code=401, detail="Invalid or expired code")

    users = load_users()
    data = users.get(info.user_id)
    if not data:
        raise HTTPException(status_code=404, detail="User not found")
    if data.get("suspended_at"):
        raise HTTPException(status_code=403, detail="This account has been suspended for violating our Terms of Service.")
    issue_session(response, info.user_id)
    result_data = {"user_id": info.user_id, **{k: v for k, v in data.items() if k != "hash_pass"}}
    if data.get("terms_version") != CURRENT_TERMS_VERSION:
        result_data["terms_reaccept_required"] = True
    return result_data


@app.post("/auth/mfa/enable")
async def mfa_enable(user_id: str = Depends(get_current_user)) -> dict:
    """Start turning on 2FA: email a confirmation code to the account's address.

    Does not enable 2FA yet — call ``/auth/mfa/confirm`` with the code to
    finish. Sending the code first (rather than flipping the flag directly)
    ensures the account's email address is actually reachable before it
    becomes required for every future login.

    Raises:
        HTTPException 503: If the confirmation code email could not be sent.
    """
    users = load_users()
    data = users.get(user_id)
    if not data:
        raise HTTPException(status_code=404, detail="User not found")
    mfa = MFAManager()
    try:
        code = mfa.create_code(user_id)
    finally:
        mfa.close()
    subject, html_body, text_body = mfa_setup_code_email(code)
    try:
        send_email(data["email"], subject, html_body, text_body)
    except EmailSendError:
        raise HTTPException(
            status_code=503,
            detail="Unable to send confirmation code — please try again shortly",
        )
    return {"sent": True}


@app.post("/auth/mfa/confirm")
async def mfa_confirm(info: MFACode, user_id: str = Depends(get_current_user)) -> dict:
    """Finish turning on 2FA by verifying the code sent by ``/auth/mfa/enable``.

    Raises:
        HTTPException 400: If the code is wrong, expired, or already used.
    """
    mfa = MFAManager()
    try:
        if not mfa.verify(user_id, info.code):
            raise HTTPException(status_code=400, detail="Invalid or expired code")
        mfa.set_enabled(user_id, True)
    finally:
        mfa.close()
    return {"mfa_enabled": True}


@app.post("/auth/mfa/disable")
async def mfa_disable(info: MFADisable, user_id: str = Depends(get_current_user)) -> dict:
    """Turn 2FA off. Requires re-entering the current password so a hijacked
    or unattended session can't silently remove the account's second factor.

    Raises:
        HTTPException 401: If the supplied password is wrong.
        HTTPException 404: If the user no longer exists.
    """
    users = load_users()
    data = users.get(user_id)
    if not data:
        raise HTTPException(status_code=404, detail="User not found")
    if not bcrypt.checkpw(info.plain_pass.encode(), data["hash_pass"].encode()):
        raise HTTPException(status_code=401, detail="Incorrect password")
    mfa = MFAManager()
    try:
        mfa.set_enabled(user_id, False)
    finally:
        mfa.close()
    return {"mfa_enabled": False}


@app.post("/auth/password-reset/request", status_code=202)
@limiter.limit("5/minute")
async def password_reset_request(request: Request, info: PasswordResetRequest) -> dict:
    """Request a password-reset email.

    Always returns the same generic response regardless of whether the email
    belongs to an account — the response and its timing must never reveal
    account existence. If a match is found, a single-use reset link (30-minute
    expiry) is emailed; on any send failure this is logged, not surfaced, for
    the same reason.
    """
    users = load_users()
    result = find_by_email(users, info.email)
    if result:
        uid, data = result
        pr = PasswordResetManager()
        try:
            token = pr.create_token(uid)
        finally:
            pr.close()
        # The frontend is a HashRouter SPA — the router only reads the
        # fragment, so the path/query must live after the '#' or this link
        # would load the app at "/" and silently drop ?token=... entirely.
        reset_link = f"https://fellowscript.com/#/reset-password?token={token}"
        subject, html_body, text_body = password_reset_email(reset_link)
        try:
            send_email(data["email"], subject, html_body, text_body)
        except EmailSendError:
            logger.error("Failed to send password reset email to user %s", uid)
    return {"detail": "If an account with that email exists, a password reset link has been sent."}


@app.post("/auth/password-reset/confirm")
@limiter.limit("10/minute")
async def password_reset_confirm(request: Request, info: PasswordResetConfirm) -> dict:
    """Complete a password reset with a token from the emailed link.

    On success, every existing session for the account is invalidated (the
    user must log in again everywhere) since a reset is often needed because
    of a suspected compromise.

    Raises:
        HTTPException 400: If the token is invalid, expired, or already used.
    """
    pr = PasswordResetManager()
    try:
        uid = pr.resolve(info.token)
        if not uid:
            raise HTTPException(status_code=400, detail="Invalid or expired reset link")
        pr.consume(info.token)
    finally:
        pr.close()

    new_hash = bcrypt.hashpw(info.new_password.encode(), bcrypt.gensalt()).decode()
    db = DBManager()
    try:
        db.update("users", {"hash_pass": new_hash}, {"_id": uid})
    finally:
        db.close()

    sm = SessionManager()
    try:
        sm.delete_all_for_user(uid)
    finally:
        sm.close()
    return {"detail": "Password updated. Please log in with your new password."}


@app.post("/logout", status_code=204)
async def logout(request: Request, response: Response) -> None:
    """End the caller's session and clear the cookie."""
    token = request.cookies.get(SESSION_COOKIE)
    if token:
        db = SessionManager()
        try:
            db.delete_session(token)
        finally:
            db.close()
    response.delete_cookie(SESSION_COOKIE)


@app.get("/user/{user_id}")
async def get_user(user_id: str, _: str = Depends(get_current_user)) -> dict:
    """Retrieve a single user's public profile.

    Any authenticated caller may look up any user (used to display friends'
    and group members' usernames) — only login is required, not ownership.

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
async def update_user(user_id: str, info: UpdateUser, _: str = Depends(require_match("user_id"))) -> dict:
    """Update mutable fields on a user account. Only the account owner may call this.

    Only fields provided (non-None) in ``info`` are updated. Passwords are
    re-hashed with bcrypt before storage.

    Args:
        user_id: UUID of the user to update.
        info: Partial update payload; any combination of username, email,
            plain_pass, and timezone may be supplied.

    Returns:
        dict: The updated user record (excludes hash_pass).

    Raises:
        HTTPException 404: If no user with the given ID exists.
        HTTPException 500: If the write to Postgres fails — the row is left
            unchanged, and the caller must not be told it succeeded.
    """
    users = load_users()
    if user_id not in users:
        raise HTTPException(status_code=404, detail="User not found")
    if info.username:
        users[user_id]["username"] = info.username
    if info.email:
        users[user_id]["email"] = info.email
    # Any explicit username/email update resolves the "Apple never resupplies
    # this" prompt — the user has now set real values themselves.
    if (info.username or info.email) and users[user_id].get("needs_profile_completion"):
        users[user_id]["needs_profile_completion"] = False
    if info.plain_pass:
        users[user_id]["hash_pass"] = bcrypt.hashpw(
            info.plain_pass.encode(), bcrypt.gensalt()
        ).decode()
    if info.timezone:
        users[user_id]["timezone"] = info.timezone
    # A single targeted-row write, not save_users_data()'s bulk re-upsert of
    # every loaded user — and one that raises on failure instead of logging
    # and swallowing it, so a persistence failure can never fall through to
    # the "success" response built below from the in-memory mutation above.
    try:
        save_user_row(user_id, users[user_id])
    except Exception as e:
        logger.error("update_user: failed to persist %s: %s", user_id, e)
        raise HTTPException(status_code=500, detail="Failed to save profile changes") from e
    return {"user_id": user_id, **{k: v for k, v in users[user_id].items() if k != "hash_pass"}}


@app.post("/user/{user_id}/accept-terms")
async def accept_terms(user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Record acceptance of the current Terms of Service version.

    Called when a logged-in user is shown the "Updated Terms" gate after
    ``login``/``mfa_verify_login`` returned ``terms_reaccept_required`` (their
    account predates a material Terms change, e.g. the zero-tolerance policy).
    """
    db = DBManager()
    try:
        db.update(
            "users",
            {"terms_accepted_at": datetime.now(timezone.utc), "terms_version": CURRENT_TERMS_VERSION},
            {"_id": user_id},
        )
    finally:
        db.close()
    return {"terms_version": CURRENT_TERMS_VERSION}


@app.delete("/user/{user_id}", status_code=204)
async def delete_user(user_id: str, _: str = Depends(require_match("user_id"))) -> None:
    """Permanently remove a user account and all owned data. Only the owner may call this.

    Notes owned by the user are deleted. Messages and devotions the user created
    have their author field nulled so group content survives. All other related
    rows (highlights, bookmarks, friends, agents, subscriptions, notifications)
    cascade automatically via FK constraints. The separate nightly-backup
    database (no FK relationship to the primary DB) is purged explicitly.

    Args:
        user_id: UUID of the user to delete.

    Raises:
        HTTPException 404: If no user with the given ID exists.
    """
    db = DBManager()
    try:
        db.cur.execute("SELECT 1 FROM users WHERE _id = %s", (user_id,))
        if not db.cur.fetchone():
            raise HTTPException(status_code=404, detail="User not found")
        # Tables whose FK to users has no ON DELETE rule must be handled manually.
        db.cur.execute("DELETE FROM notes    WHERE user_id   = %s", (user_id,))
        db.cur.execute("UPDATE messages   SET from_user   = NULL WHERE from_user   = %s", (user_id,))
        db.cur.execute("UPDATE devotions  SET creator_id  = NULL WHERE creator_id  = %s", (user_id,))
        db.cur.execute("DELETE FROM users WHERE _id = %s", (user_id,))
        db.conn.commit()
    finally:
        db.close()

    # The nightly-backup database is a separate, FK-less mirror (see
    # backend/backup/manager.py) — deleting the primary row above does not
    # touch it, so it must be purged explicitly to honor the Privacy Policy's
    # promise that account deletion removes data from all of our systems.
    backup_db = DBManager(dbname=BACKUP_DB_NAME)
    try:
        backup_db.cur.execute(
            "DELETE FROM note_verses WHERE note_id IN "
            "(SELECT _id FROM notes WHERE user_id = %s)", (user_id,)
        )
        backup_db.cur.execute("DELETE FROM notes      WHERE user_id = %s", (user_id,))
        backup_db.cur.execute("DELETE FROM highlights  WHERE user_id = %s", (user_id,))
        backup_db.cur.execute("DELETE FROM bookmarks   WHERE user_id = %s", (user_id,))
        backup_db.cur.execute("DELETE FROM users       WHERE _id = %s", (user_id,))
        backup_db.conn.commit()
    except Exception as e:
        logger.error("Failed to purge backup DB for deleted user %s: %s", user_id, e)
        backup_db.conn.rollback()
    finally:
        backup_db.close()


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
    # Accept tokens from BOTH the web client (website) and the iOS client (app).
    # Google client IDs are public identifiers, so a default is safe; override
    # via env if the iOS client ever changes.
    valid_auds = {
        os.getenv("CLIENT_ID", ""),
        os.getenv("GOOGLE_IOS_CLIENT_ID",
                  "667477247503-1hgf50kh24a3gi121u1eps5cptjjufds.apps.googleusercontent.com"),
    }
    valid_auds.discard("")
    if token_data.get("aud") not in valid_auds:
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
        if data.get("suspended_at"):
            raise HTTPException(status_code=403, detail="This account has been suspended for violating our Terms of Service.")
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
        # Guideline 4.8: never block account creation on terms_accepted here.
        # Google only supplies name/email on this exact call — a rejected
        # signup means a retry gets a blank name (Apple's Sign in with Apple
        # is stricter still: it supplies the name/email exactly once, ever,
        # per Apple ID + app, so losing this attempt loses it permanently).
        # Create the account regardless, and let terms_reaccept_required
        # (below) prompt for consent immediately after, instead of discarding
        # the name/email that was just supplied.
        if info.terms_accepted:
            user = User(
                user_id=uid, username=username, email=email, hash_pass="",
                terms_accepted_at=str(datetime.now(timezone.utc)), terms_version=CURRENT_TERMS_VERSION,
            )
        else:
            user = User(user_id=uid, username=username, email=email, hash_pass="")
        persist_new_user(user)
        sm = SubscriptionsManager()
        try:
            sm.create_free_plan(uid)
        finally:
            sm.close()
        # google_sub isn't a User schema field; record it so returning Google
        # sign-ins match on the stable identifier.
        if sub:
            users = load_users()
            users[uid]["google_sub"] = sub
            save_users(users)
            data = users[uid]
        else:
            data = user.model_dump(exclude={"user_id"})

    issue_session(response, uid)
    result_data = {"user_id": uid, **{k: v for k, v in data.items() if k != "hash_pass"}}
    if data.get("terms_version") != CURRENT_TERMS_VERSION:
        result_data["terms_reaccept_required"] = True
    return result_data


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
        if data.get("suspended_at"):
            raise HTTPException(status_code=403, detail="This account has been suspended for violating our Terms of Service.")
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
        # Guideline 4.8: never block account creation on terms_accepted here.
        # Apple supplies full_name/email exactly once, ever, per Apple ID +
        # app — rejecting this call means that name is gone permanently, with
        # no way to recover it short of asking the user to type it manually
        # (exactly the complaint this fixes). Create the account regardless,
        # and let terms_reaccept_required (below) prompt for consent
        # immediately after, instead of discarding what Apple just supplied.
        #
        # If Apple didn't supply a real name and/or email on this (first-ever)
        # authorization, there is no way to ever ask Apple for it again — flag
        # the account so the client prompts the user to set them manually.
        needs_profile_completion = not (info.full_name and email)
        if info.terms_accepted:
            user = User(
                user_id=uid, username=username, email=email, hash_pass="",
                terms_accepted_at=str(datetime.now(timezone.utc)), terms_version=CURRENT_TERMS_VERSION,
                needs_profile_completion=needs_profile_completion,
            )
        else:
            user = User(
                user_id=uid, username=username, email=email, hash_pass="",
                needs_profile_completion=needs_profile_completion,
            )
        persist_new_user(user)
        # apple_sub isn't a User schema field, so it's recorded in a separate
        # step — done immediately after the row is created (before anything
        # else that could fail) so a retried sign-in with the same Apple ID
        # (e.g. the client times out and the user taps "Sign in with Apple"
        # again before profile completion) always matches this same account
        # via find_by_apple_sub instead of creating an orphaned duplicate.
        users = load_users()
        users[uid]["apple_sub"] = sub
        save_users(users)
        sm = SubscriptionsManager()
        try:
            sm.create_free_plan(uid)
        finally:
            sm.close()
        data = users[uid]

    issue_session(response, uid)
    result_data = {"user_id": uid, **{k: v for k, v in data.items() if k != "hash_pass"}}
    if data.get("terms_version") != CURRENT_TERMS_VERSION:
        result_data["terms_reaccept_required"] = True
    return result_data


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True, log_level="info")
