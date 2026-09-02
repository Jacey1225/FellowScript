from fastapi import APIRouter, HTTPException, WebSocket, Depends
from backend.interactions.agent import AgentManager
from backend.interactions.groups import GroupsManager
from backend.errors import SaveFailedError
from backend.subscription.limits import check_limit
from backend.auth.dependencies import require_match, authenticate_ws
from schemas.agent import AgentHeartbeats
from schemas.agent import _DEFAULT_ROLE as DEFAULT_ROLE
from datetime import datetime
import asyncio
import functools
import uuid
import logging

agent_router = APIRouter(prefix="/agent")
logger = logging.getLogger(__name__)


def _require_group_membership(user_id: str, group_id: str) -> None:
    """IDOR guard: a client-supplied heartbeat group_id must be one
    ``user_id`` actually belongs to, mirroring notes.py's create_note/
    update_note guard -- without this, any authenticated user could tie a
    scheduled event (and, on fire, the note it generates) to a group they
    were never invited to.
    """
    gm = GroupsManager(user_id, group_id)
    try:
        if not gm.is_member():
            raise HTTPException(status_code=403, detail="Not a member of this group")
    finally:
        gm.close()


# ── WebSocket ─────────────────────────────────────────────────────────────────
# Must be registered before the /{user_id} wildcard so FastAPI does not treat
# the literal "ws" segment as a user_id.

@agent_router.websocket("/ws/{agent_id}/{user_id}")
async def agent_ws_endpoint(agent_id: str, user_id: str, websocket: WebSocket):
    session_user = await authenticate_ws(websocket)
    if session_user is None or session_user != user_id:
        await websocket.close(code=4401)
        return
    db = AgentManager(user_id)
    try:
        await db.connect_agent(agent_id, websocket)
    finally:
        db.close()


# ── Agent CRUD ────────────────────────────────────────────────────────────────

@agent_router.get("/{user_id}")
async def get_agents(user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = AgentManager(user_id)
    try:
        return db.get_user_agents()
    finally:
        db.close()


@agent_router.post("/{user_id}", status_code=201)
async def create_agent(user_id: str, body: dict, _: str = Depends(require_match("user_id"))) -> dict:
    db = AgentManager(user_id)
    try:
        agent_id = str(uuid.uuid4())
        if not db.insertion("agents", {
            "_id":     agent_id,
            "name":    body.get("name") or "Spiritual Guide",
            "user_id": user_id,
            "role":    body.get("role") or DEFAULT_ROLE,
            "chats":   body.get("chats", []),
            "enabled": body.get("enabled", True),
        }):
            raise SaveFailedError()
        return {"id": agent_id}
    finally:
        db.close()


@agent_router.put("/{user_id}/{agent_id}")
async def update_agent(user_id: str, agent_id: str, body: dict, _: str = Depends(require_match("user_id"))) -> dict:
    db = AgentManager(user_id)
    try:
        if not db.owns_agent(agent_id):
            raise HTTPException(status_code=404, detail="Agent not found")
        updates = {k: body[k] for k in ("role", "chats", "enabled", "name") if k in body}
        if updates:
            # owns_agent() above already confirmed the row exists, so a
            # False return here is a real write failure, not an expected
            # no-op.
            if not db.update("agents", updates, {"_id": agent_id, "user_id": user_id}):
                raise SaveFailedError()
        return {"ok": True}
    finally:
        db.close()


@agent_router.delete("/{user_id}/{agent_id}", status_code=204)
async def delete_agent(user_id: str, agent_id: str, _: str = Depends(require_match("user_id"))) -> None:
    db = AgentManager(user_id)
    try:
        db.delete_agent(agent_id)
    finally:
        db.close()


# ── Messages ──────────────────────────────────────────────────────────────────

@agent_router.get("/{user_id}/{agent_id}/messages")
async def get_messages(user_id: str, agent_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = AgentManager(user_id)
    try:
        return db.get_messages(agent_id)
    finally:
        db.close()


@agent_router.delete("/{user_id}/{agent_id}/messages/{message_id}", status_code=204)
async def delete_message(user_id: str, agent_id: str, message_id: str, _: str = Depends(require_match("user_id"))) -> None:
    db = AgentManager(user_id)
    try:
        db.delete_message(message_id)
    finally:
        db.close()


# ── Heartbeats ────────────────────────────────────────────────────────────────

@agent_router.get("/{user_id}/{agent_id}/heartbeats")
async def get_heartbeats(user_id: str, agent_id: str, _: str = Depends(require_match("user_id"))) -> list:
    db = AgentManager(user_id)
    try:
        return db.get_heartbeats(agent_id)
    finally:
        db.close()

@agent_router.put("/{user_id}/{heartbeat_id}/update_heartbeats")
async def update_heartbeat(user_id: str, heartbeat_id: str, body: dict, _: str = Depends(require_match("user_id"))) -> dict:
    group_id = body.get("group_id") or None
    if group_id:
        _require_group_membership(user_id, group_id)
    db = AgentManager(user_id)
    try:
        heartbeat = AgentHeartbeats(
            agent_id=body.get("agent_id", ""),
            user_id=user_id,
            timestamps=body.get("timestamps", [None] * 31),
            prompt=body.get("prompt", ""),
            group_id=group_id,
        )
        db.update_heartbeat(heartbeat_id, heartbeat)
        return {"ok": True}
    finally:
        db.close()


@agent_router.post("/{user_id}/{agent_id}/{heartbeat_id}/commit_heartbeat")
async def commit_heartbeat(user_id: str, agent_id: str, heartbeat_id: str, body: dict, _: str = Depends(require_match("user_id"))):
    # A fired heartbeat persists its generated content as a note, so it counts
    # against the same weekly notes cap as create_note/summarize_session —
    # otherwise a free user at their cap could keep minting notes every time a
    # scheduled event fires. Checked here, before commit_hb_response's
    # once-per-day claim, so a denied request doesn't burn today's fire slot:
    # claiming first and denying after would soft-throttle the user to zero
    # notes for the rest of the day even if their cap frees up later. This
    # gate applies identically to a forced/manual fire (see `force` below) --
    # forced fires are not exempt from the weekly notes cap, only from the
    # once-per-day claim.
    #
    # Both check_limit and commit_hb_response are sync/psycopg2 calls on this
    # route's `async def` handler, which shares the process's one event loop
    # with every other request and the scheduler.py heartbeat-firing job --
    # commit_hb_response's internal LLM call in particular can block for up
    # to 60s (its `requests.post(..., timeout=60)`). Offloaded via
    # loop.run_in_executor, matching connect_agent's existing offload of the
    # identical `_call_api` call and scheduler.py's `_fire_due_heartbeats`
    # offload of this same client-triggerable defect's server-triggered
    # twin.
    loop = asyncio.get_running_loop()
    gate = await loop.run_in_executor(None, functools.partial(check_limit, user_id, "notes"))
    if not gate["allowed"]:
        raise HTTPException(status_code=403, detail=gate)

    db = AgentManager(user_id=user_id)
    try:
        content = body.get("prompt", None)
        if not content:
            return {"error": "heartbeat prompt not found"}
        # `force`: a manual/UI-triggered fire that must succeed even if this
        # heartbeat already fired today (by schedule or an earlier manual
        # force-fire) -- see commit_hb_response's forced branch. Defaults to
        # False so the scheduler's own call into this same manager method
        # (scheduler.py::_fire_due_heartbeats, which never sends a body at
        # all) and any not-yet-updated caller keep today's unforced,
        # once-per-day-claimed behavior unchanged.
        force = bool(body.get("force", False))
        result = await loop.run_in_executor(
            None, functools.partial(db.commit_hb_response, agent_id, heartbeat_id, content, force=force)
        )
        return result
    finally:
        db.close()


@agent_router.post("/{user_id}/{agent_id}/heartbeat", status_code=201)
async def add_heartbeat(user_id: str, agent_id: str, body: dict, _: str = Depends(require_match("user_id"))) -> dict:
    gate = check_limit(user_id, "agent_events")
    if not gate["allowed"]:
        raise HTTPException(status_code=403, detail=gate)
    group_id = body.get("group_id") or None
    if group_id:
        _require_group_membership(user_id, group_id)
    db = AgentManager(user_id)
    try:
        heartbeat = AgentHeartbeats(
            agent_id=agent_id,
            user_id=user_id,
            timestamps=body.get("timestamps", [None] * 31),
            prompt=body.get("prompt", ""),
            group_id=group_id,
        )
        db.add_heartbeat(heartbeat)
        return {"ok": True}
    finally:
        db.close()


@agent_router.delete("/{user_id}/{agent_id}/heartbeat/{heartbeat_id}", status_code=204)
async def delete_heartbeat(user_id: str, agent_id: str, heartbeat_id: str, _: str = Depends(require_match("user_id"))) -> None:
    db = AgentManager(user_id)
    try:
        db.delete_heartbeat(heartbeat_id)
    finally:
        db.close()



# ── Session summarization ─────────────────────────────────────────────────────

@agent_router.post("/{user_id}/{agent_id}/summarize", status_code=201)
async def summarize_session(user_id: str, agent_id: str, body: dict, _: str = Depends(require_match("user_id"))) -> dict:
    # The summary is persisted as a note, so it counts against the same weekly
    # notes cap as create_note/post_reply — otherwise a free user at their cap
    # could keep minting notes through this endpoint.
    gate = check_limit(user_id, "notes")
    if not gate["allowed"]:
        raise HTTPException(status_code=403, detail=gate)

    session  = body.get("session", {})
    group_id = body.get("group_id", "")

    title   = session.get("title", "Untitled Session")
    prompts = session.get("prompts", [])
    verses  = session.get("verses", [])

    prompt_lines = [f'Summarize the following Bible study session: "{title}".', ""]
    if verses:
        prompt_lines.append(f"Scripture references: {', '.join(verses)}")
    if prompts:
        prompt_lines.append("Discussion prompts covered:")
        prompt_lines.extend(f"  - {p}" for p in prompts)
    prompt_lines += [
        "",
        "Write a concise summary covering key scriptural insights, main takeaways, "
        "and actionable next steps for the group. Format it as a readable study note.",
    ]

    db = AgentManager(user_id)
    try:
        result     = db.lookup("agents", {"_id": agent_id})
        agent_role = list(result.values())[0].get("role", "") if result else ""
        try:
            summary = db._call_api(agent_role, [{"role": "user", "content": "\n".join(prompt_lines)}])
        except Exception as e:
            logger.error("OpenRouter session-summary error for agent %s: %s", agent_id, e)
            raise HTTPException(status_code=502, detail="Could not generate session summary.")

        note_id = str(uuid.uuid4())
        db.cur.execute(
            "INSERT INTO notes (_id, user_id, title, text, public, group_id, is_reply, timestamp) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
            (note_id, user_id, f"Session Summary — {title}", summary,
             True, group_id or None, False, datetime.now())
        )
        db.conn.commit()
        return {"ok": True, "note_id": note_id}
    finally:
        db.close()
