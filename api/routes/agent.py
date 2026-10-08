from fastapi import APIRouter, HTTPException, Request, Response, WebSocket, Depends
from backend.interactions.agent import AgentManager, detect_leaked_action_json
from backend.interactions.groups import GroupsManager
from backend.interactions import flags
from backend.interactions.agent_chats import AgentChatStore, ChatLimitError
from backend.interactions.agent_chats_config import get_agent_chats_config
from backend.interactions import session_summary_fanout as fanout
from backend.interactions.session_summary_fanout_config import is_fanout_enabled
from backend.rate_limiting import limiter
from backend.errors import SaveFailedError, NoSummarizableContentError
from backend.subscription.limits import check_limit, check_paid_only
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
    # Optional ?chat_id= (flag agent_chats). Validated inside connect_agent.
    session_user = await authenticate_ws(websocket)
    if session_user is None or session_user != user_id:
        await websocket.close(code=4401)
        return
    db = AgentManager(user_id)
    try:
        await db.connect_agent(agent_id, websocket, websocket.query_params.get("chat_id"))
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

def _chat_not_found() -> HTTPException:
    return HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})


def _create_chat_rate() -> str:
    return get_agent_chats_config().create_rate


def _chat_user_key(request: Request) -> str:
    return f"agent-chats-user:{request.path_params.get('user_id')}"


@agent_router.get("/{user_id}/{agent_id}/chats")
def list_chats(user_id: str, agent_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Every chat between the caller and this agent, most recent first:
    ``{"chats": [{id, title, created_at, last_message_at}]}``."""
    if not flags.is_enabled("agent_chats", user_id):
        raise _chat_not_found()
    db = AgentManager(user_id)
    try:
        if not db.owns_agent(agent_id):
            raise _chat_not_found()
        return {"chats": AgentChatStore(db).list_chats(agent_id)}
    finally:
        db.close()


@agent_router.post("/{user_id}/{agent_id}/chats", status_code=201)
@limiter.shared_limit(_create_chat_rate, scope="agent_chat_create", key_func=_chat_user_key)
def create_chat(request: Request, response: Response, user_id: str, agent_id: str,
                _: str = Depends(require_match("user_id"))) -> dict:
    """Start a new, empty chat with this agent. 409 ``chat_limit`` at the cap."""
    if not flags.is_enabled("agent_chats", user_id):
        raise _chat_not_found()
    db = AgentManager(user_id)
    try:
        if not db.owns_agent(agent_id):
            raise _chat_not_found()
        try:
            chat = AgentChatStore(db).create_chat(agent_id)
        except ChatLimitError:
            raise HTTPException(status_code=409, detail={"code": "chat_limit"})
    finally:
        db.close()
    logger.info("AGENT_CHAT_CREATE user=%s agent=%s chat=%s", user_id, agent_id, chat["id"])
    return chat


@agent_router.get("/{user_id}/{agent_id}/messages")
async def get_messages(user_id: str, agent_id: str, chat_id: str | None = None,
                       _: str = Depends(require_match("user_id"))) -> dict:
    """Flag off and no chat_id: legacy flat history, unchanged. Flag on:
    absent chat_id -> the default chat; a chat_id must belong to (caller,
    agent) or 404 (never a fallback). A chat_id with the flag off is 404."""
    db = AgentManager(user_id)
    try:
        if not flags.is_enabled("agent_chats", user_id):
            if chat_id:
                raise _chat_not_found()
            return db.get_messages(agent_id)
        if not db.owns_agent(agent_id):
            raise _chat_not_found()
        store = AgentChatStore(db)
        resolved = store.resolve(agent_id, chat_id)
        if resolved is None:
            raise _chat_not_found()
        return store.get_messages(agent_id, resolved)
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
            # Deny-by-default: an omitted/falsy body value keeps the note
            # this event generates owner-only-editable, matching
            # AgentHeartbeats.notes_public's own default.
            notes_public=bool(body.get("notes_public", False)),
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
    db = AgentManager(user_id)
    try:
        # `idempotency_key`: optional client-generated token (task
        # 20260905-heartbeat-timezone-duplicate-bugs, step 4) identifying
        # this Save attempt -- a double-submit reusing the same key must
        # return the FIRST attempt's row id instead of creating a second
        # row (see AgentManager.add_heartbeat's docstring). Omitted
        # entirely for a not-yet-updated client, which still works, just
        # without dedup protection.
        idempotency_key = body.get("idempotency_key")

        # Bounce fix (testing gate, step 5): a dedup hit must short-circuit
        # BEFORE check_limit is ever consulted. check_limit's agent_events
        # count is a plain COUNT(*) over agent_heartbeats -- a repeat POST
        # carrying the same idempotency_key as an already-persisted row
        # creates no new resource, so it must never be charged against the
        # free-tier cap. Checking the gate first (the pre-bounce ordering)
        # meant a free user's very first successful save (limit=1) made
        # their own legitimate retry/double-tap of that same save 403,
        # defeating this task's own "return the existing row" design for
        # exactly the scenario it exists to protect. This lookup runs on
        # every request that carries a key (a cheap indexed point lookup
        # against the new UNIQUE index), not just after a 403, so it also
        # covers the case where the user is already over their limit for
        # an unrelated reason.
        if idempotency_key:
            existing = db.lookup(db.hb_table, {
                "user_id": user_id, "agent_id": agent_id,
                "idempotency_key": idempotency_key,
            })
            if existing:
                return {"ok": True, "id": list(existing.keys())[0]}

        gate = check_limit(user_id, "agent_events")
        if not gate["allowed"]:
            raise HTTPException(status_code=403, detail=gate)
        group_id = body.get("group_id") or None
        if group_id:
            _require_group_membership(user_id, group_id)
        heartbeat = AgentHeartbeats(
            agent_id=agent_id,
            user_id=user_id,
            timestamps=body.get("timestamps", [None] * 31),
            prompt=body.get("prompt", ""),
            group_id=group_id,
            # Deny-by-default: an omitted/falsy body value keeps the note
            # this event generates owner-only-editable, matching
            # AgentHeartbeats.notes_public's own default.
            notes_public=bool(body.get("notes_public", False)),
        )
        # A genuinely concurrent repeat (two requests with the same key
        # racing each other, neither yet committed when the lookup above
        # ran) is still made safe here, not by this route-level lookup:
        # AgentManager.add_heartbeat's own UniqueViolation handling is what
        # makes the dedup race-safe (Q28), since Postgres's constraint --
        # not a check-then-insert race in application code -- decides the
        # winner. The lookup above only shortcuts the *already-settled*
        # case so it doesn't have to pay the quota gate.
        hb_id = db.add_heartbeat(heartbeat, idempotency_key=idempotency_key)
        if hb_id is None:
            raise SaveFailedError()
        return {"ok": True, "id": hb_id}
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
    # could keep minting notes through this endpoint. Kept ahead of the
    # no-content check below (existing behavior, see
    # test_free_limits.py::"summarize blocked when notes cap reached (403)",
    # which submits an empty-content session against an already-exhausted
    # cap and expects 403) -- a capped user is rejected the same way
    # regardless of what their session contains, without the model ever
    # being invoked either way.
    # Session summaries are a paid-only feature (task 20261002-free-plan-limits-ui):
    # checked first, fail closed, so a free user never reaches the model.
    paid_gate = check_paid_only(user_id, "session_summaries")
    if not paid_gate["allowed"]:
        raise HTTPException(status_code=403, detail=paid_gate)
    gate = check_limit(user_id, "notes")
    if not gate["allowed"]:
        raise HTTPException(status_code=403, detail=gate)

    session  = body.get("session", {})
    prompts  = session.get("prompts", [])
    verses   = session.get("verses", [])

    # Bug fix (task 20260915-session-summary-note-fixes): a scheduled call
    # session (FSSession, wired from ChimeCallView.swift/ChatThreadView.swift)
    # can legitimately reach this endpoint with `summarize: true` but only a
    # title -- empty `prompts` AND empty `verses` -- when nothing was
    # actually discussed. Previously this endpoint called the LLM anyway
    # with nothing real to summarize and persisted whatever confused
    # non-answer came back (e.g. "I don't have information about this
    # session") as if it were a genuine summary. Security Posture Q2/Q7 +
    # Error Handling Q26/Q27: fail closed and explicit at this boundary --
    # before spending an LLM call on a request that can't produce a real
    # summary -- rather than silently substituting the model's own
    # fabricated non-answer. Having just one of prompts/verses is still real
    # content worth summarizing (e.g. a session with only scripture
    # references logged, no discussion prompts).
    if not prompts and not verses:
        raise NoSummarizableContentError()

    group_id = body.get("group_id") or None

    # Bug fix (task 20260911-session-summary-group-id-crash): `group_id`
    # here is whatever ChatThreadViewModel.roomKey(...) computed client-side
    # for the session's thread, which is NOT always a real `groups._id` --
    # for a friend DM it's the synthetic "<uidA>|<uidB>" composite room key
    # (same pattern AppState.openSession(groupId:) already checks for via
    # `.contains("|")`), not a group UUID. Blindly writing that string into
    # `notes.group_id` (a FK-constrained uuid column) throws
    # psycopg2.errors.InvalidTextRepresentation and 500s the whole request --
    # this was the reported crash.
    #
    # Fail-closed per Security Posture Q14, but deliberately (Q26/Q27) rather
    # than by letting a malformed value fall through to the DB layer:
    #   - A friend-DM composite key is a legitimate, *expected* value here
    #     (this is literally the reported use case), not a malformed one --
    #     it deliberately resolves to group_id=None so the summary still
    #     saves, just as a private note. Silently dropping the summary
    #     entirely would violate the DM case being a real intended use of
    #     this feature.
    #   - Anything else is checked against real group membership the same
    #     defense-in-depth way create_heartbeat/update_heartbeat already do
    #     in this file (`_require_group_membership`) -- a group_id the
    #     caller isn't a member of is rejected (403), not guessed/passed
    #     through, consistent with this route family's existing IDOR guard.
    dm_key = group_id if (group_id and "|" in group_id) else None
    if group_id and "|" in group_id:
        group_id = None
    elif group_id:
        _require_group_membership(user_id, group_id)

    # Personal fan-out (task 20260908-session-summary-personal-fanout): behind
    # a config flag (default off). Only for a non-group session; a real-group
    # session keeps its single group note untouched. Recipients are resolved
    # server-side before the model call (403 for a non-participant of a
    # persisted session); any doubt resolves to the caller only.
    fan_recipients = None
    fan_session_id = None
    if group_id is None and is_fanout_enabled():
        if not isinstance(session, dict):
            session = {}
        fan_session_id = fanout.valid_session_id(session.get("id"))
        fan_recipients = fanout.resolve_recipients(user_id, dm_key, session)
        if fan_session_id:
            idem = AgentManager(user_id)
            try:
                have = fanout.existing_summary_notes(idem, fan_session_id, fan_recipients)
            finally:
                idem.close()
            if all(r in have for r in fan_recipients):
                # Retry of a fully-completed request: no model call, no new writes.
                return {"ok": True, "note_id": have[user_id], "fanout": {"written": 0, "skipped": len(fan_recipients) - 1}}
        else:
            # No valid session id to key on: no dedupe for the caller and no
            # fan-out to anyone else (fail closed).
            fan_recipients = [user_id]

    title = session.get("title", "Untitled Session")

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
        "",
        # Bug fix (task 20260915-session-summary-note-fixes): agent_prompt.txt's
        # shared system prompt instructs the model to respond with a
        # create_note JSON action block whenever it interprets the request as
        # "create/save a note" -- and the "Format it as a readable study
        # note" line just above is enough to trigger that interpretation on
        # its own. This call handles saving the note itself, so an action
        # block in the response would previously get saved into notes.text
        # verbatim instead of being executed. detect_leaked_action_json below
        # is the defensive backstop; this is the first line of defense.
        "Respond with plain prose only -- do NOT include a create_note or "
        "create_notification JSON action block. This response will be saved "
        "directly as the note's text exactly as written, not executed as an "
        "action.",
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

        # Bug fix (task 20260915-session-summary-note-fixes): defensive
        # backstop for the prompt instruction above -- never trust `summary`
        # as clean prose unconditionally. If the model leaked a create_note/
        # create_notification action block anyway, salvage its own intended
        # "text" field (the model did the real work, it just wrapped the
        # response in the wrong shape for this call) rather than saving the
        # raw JSON verbatim. If there's nothing salvageable (e.g. a
        # create_notification block, or a create_note block with no text),
        # propagate the failure upward per Error Handling Q27 rather than
        # saving the raw JSON or inventing placeholder prose -- same posture
        # as the connection-error branch just above.
        leaked_action = detect_leaked_action_json(summary)
        if leaked_action is not None:
            salvaged = str(leaked_action.get("text") or "").strip()
            if salvaged:
                summary = salvaged
            else:
                logger.error(
                    "summarize_session got an unsalvageable leaked action block for agent %s: %.200s",
                    agent_id, summary,
                )
                raise HTTPException(status_code=502, detail="Could not generate session summary.")

        # `public` here means group-edit permission (task
        # 20260903-notes-public-repurpose), not visibility -- visibility of
        # this note is already group_id-only. Unlike a heartbeat-fired note
        # (note_via_hb/_generate_and_save_note), a session summary has no
        # `agent_heartbeats` row to read a configured value from -- a study
        # session is a live, one-off flow, not a scheduled event -- so this
        # was previously hardcoded True (every summary group-editable).
        # Deny-by-default per Security Posture Q2/Q14: default closed unless
        # the caller explicitly opts a summary into group-editing.
        notes_public = bool(body.get("notes_public", False))
        # Deliberately EXEMPT from the per-note character cap
        # (FREE_NOTE_CHAR_LIMIT, task 20260929-free-note-char-cap): this is
        # server-generated text, bounded by the LLM's own generation limits,
        # and is never truncated (throw-not-fabricate). The notes-count gate
        # above still applies; a later USER edit that grows it past the cap
        # falls under update_note's grandfather rule.
        if fan_recipients is not None and fan_session_id:
            note_title = f"Session Summary — {title}"
            note_id, _ = fanout.insert_deduped_note(
                db, fan_session_id, user_id, note_title, summary, notes_public, None)
            counts = fanout.fan_out_to_others(db, fan_session_id, user_id, fan_recipients, note_title, summary)
            logger.info("summarize fan-out session=%s written=%d skipped=%d",
                        fan_session_id, counts["written"], counts["skipped"])
            return {"ok": True, "note_id": note_id, "fanout": counts}
        note_id = str(uuid.uuid4())
        db.cur.execute(
            "INSERT INTO notes (_id, user_id, title, text, public, group_id, is_reply, timestamp) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
            (note_id, user_id, f"Session Summary — {title}", summary,
             notes_public, group_id or None, False, datetime.now())
        )
        db.conn.commit()
        return {"ok": True, "note_id": note_id}
    finally:
        db.close()
