from fastapi import APIRouter, HTTPException, Depends, Request
from schemas.devotion import DevotionRequest, DevotionPlan, RingRequest
from backend.interactions.devotion import DevotionManager, is_ring_enabled
from backend.auth.dependencies import get_current_user, require_match
from backend.moderation.content_filter import check_clean, ContentRejected, rejection_message
from backend.rate_limiting import limiter
import boto3
import logging
import uuid
from botocore.exceptions import ClientError

chime = boto3.client("chime-sdk-meetings", region_name="us-east-1")
devo_router = APIRouter(prefix="/devotions")
logger = logging.getLogger(__name__)

_CHIME_ERROR_DETAIL = "Could not start the call. Please try again."


def _check_devotion_clean(devotion) -> None:
    try:
        check_clean(title=devotion.title, prompts=" | ".join(devotion.prompts))
    except ContentRejected as e:
        raise HTTPException(status_code=422, detail=rejection_message(e))


async def _notify_session_created(db: DevotionManager, devotion: DevotionPlan, session_id: str, creator_id: str) -> None:
    """Push the session's other group/DM members that a new session was
    scheduled -- everyone ``resolve_members`` returns except the creator
    themselves. Per-recipient failure (missing/expired token, a transient
    APNs error) is caught and logged, never allowed to fail the create call
    itself -- same isolation posture as every other push send in this
    project (``scheduler.py``'s jobs, ``websockets.py``'s ``send_msg``).
    """
    from backend.interactions.push import send_push

    session = {
        "creator_id": creator_id,
        "participants": devotion.participants,
        "group_id": devotion.group_id,
    }
    members = [uid for uid in db.resolve_members(session) if uid != creator_id]
    if not members:
        return
    tokens = db.device_tokens_bulk(members)
    creator_name = db.get_username(creator_id) or "Someone"
    body = f'{creator_name} scheduled a new session: "{devotion.title}".' if devotion.title \
        else f"{creator_name} scheduled a new session."
    for uid in members:
        token = tokens.get(uid)
        if not token:
            continue
        try:
            await send_push(
                token, "New Session", body,
                data={"devotion_id": session_id, "group_id": devotion.group_id},
            )
        except Exception as e:
            logger.error("Session-created push failed (%s -> %s): %s", session_id, uid, e)


@devo_router.post("/", status_code=201)
async def create_devotion(req: DevotionRequest, current_user: str = Depends(get_current_user)) -> dict:
    if req.user_id != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    _check_devotion_clean(req.devotion)
    db = DevotionManager()
    try:
        session_id = db.save_devotion(req.devotion)
        await _notify_session_created(db, req.devotion, session_id, current_user)
        return {"id": session_id}
    finally:
        db.close()


@devo_router.get("/contact/{contact_id}")
async def get_contact_devotions(contact_id: str, current_user: str = Depends(get_current_user)) -> dict:
    db = DevotionManager()
    try:
        return {"sessions": db.fetch_by_contact(contact_id, viewer_id=current_user)}
    finally:
        db.close()


@devo_router.get("/")
async def fetch_devotion(devotion_id: str, current_user: str = Depends(get_current_user)) -> dict:
    db = DevotionManager()
    try:
        devotion = db.read_devotion(devotion_id)
        if not devotion:
            raise HTTPException(status_code=404, detail="Session not found")
        if not db.is_authorized(devotion.model_dump(), current_user):
            raise HTTPException(status_code=403, detail="Not authorized")
        return devotion.model_dump()
    finally:
        db.close()


@devo_router.put("/")
async def update_devotion(req: DevotionRequest, current_user: str = Depends(get_current_user)) -> dict:
    if req.user_id != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    _check_devotion_clean(req.devotion)
    db = DevotionManager()
    try:
        session = db.get_session(req.devotion_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")
        if not db.is_authorized(session, current_user):
            raise HTTPException(status_code=403, detail="Not authorized")
        ok = db.update_devotion(req.devotion_id, req.devotion)
        if not ok:
            raise HTTPException(status_code=404, detail="Session not found")
        return {"ok": True}
    finally:
        db.close()


@devo_router.post("/join")
async def join_devotion(user_id: str, session_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DevotionManager()
    try:
        session = db.get_session(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")
        if not db.is_authorized(session, user_id):
            raise HTTPException(status_code=403, detail="Not authorized")
        db.add_participant(session_id, user_id)
        return {"ok": True}
    finally:
        db.close()


@devo_router.post("/leave")
async def leave_devotion(user_id: str, session_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DevotionManager()
    try:
        session = db.get_session(session_id)
        # Missing session: no-op, same as before (idempotent leave).
        if session and not db.is_authorized(session, user_id):
            raise HTTPException(status_code=403, detail="Not authorized")
        db.remove_participant(session_id, user_id)
        return {"ok": True}
    finally:
        db.close()


# Fixed, non-user-authored push copy (task 20260916-call-ring-members) --
# same posture as community.py's _NUDGE_TITLE/_nudge_body: never
# user-composable, per this project's precedent of having fully removed the
# prior open-ended user-authored notification subsystem. A ring is a single
# templated action against a specific target, never free text.
_RING_TITLE = "Join the call"


def _ring_body(caller_username: str, session_title: str) -> str:
    if session_title:
        return f'{caller_username} wants you to join "{session_title}" now'
    return f"{caller_username} wants you to join the call now"


@devo_router.post("/ring")
@limiter.limit("30/minute")
async def ring_members(
    request: Request, req: RingRequest, current_user: str = Depends(get_current_user),
) -> dict:
    """Ring one or more of a live session's own group members with a push
    prompting them to join, carrying enough ``data`` for the client to
    deep-link straight into the join flow (task 20260916-call-ring-members).

    Gated behind ``RING_FEATURE_ENABLED`` (see
    ``backend.interactions.devotion.validate_ring_config``) -- while
    disabled, this 404s exactly as if the route didn't exist, same posture
    as ``community.py``'s nudge route during its own rollout.

    A coarse per-IP ``30/minute`` backstop (``backend.rate_limiting.limiter``,
    the same shared instance already applied to ``friend_router``'s nudge
    route) sits in front of the real per-(sender, recipient, session)
    cooldown below -- it blunts brute-force/enumeration traffic hitting this
    route at all, it doesn't replace the per-recipient cooldown, which stays
    the actual anti-spam/harassment control.

    Every requested target is authorized and rate-limited independently and
    reported back as its own result (deny-by-default / fail-closed, Security
    Posture Q5/Q7/Q14). Post-security-bounce rework (task
    20260916-call-ring-members, see architecture.json's ``revision_note``):
    the caller must be BOTH an authorized session participant
    (``DevotionManager.is_authorized``) AND independently present in
    ``DevotionManager.real_group_roster(group_id)`` -- the real ``groups``
    row (or DM-pair split) behind ``group_id``, never
    ``session.creator_id``/``session.participants``, both of which are
    unvalidated client input at session-creation time. Each target must
    likewise be in that same ``real_group_roster(group_id)`` set (minus the
    caller) -- ``resolve_members(session)`` is no longer consulted at all
    for ring, since it folds those same untrusted fields in. The whole
    request is also denied up front, before any target is evaluated, if
    the session has no live call attached yet (``chime_meeting_id`` empty)
    -- a bare session row is no longer sufficient on its own; there must be
    a real Chime meeting behind it. Each surviving target must have a
    registered device token, and each (caller, target) pair -- independent
    of session_id -- must have cleared its cooldown
    (``DevotionManager.claim_ring_slot``, claimed BEFORE the push is sent,
    released via ``release_ring_claim`` if the send itself then fails --
    same claim/release shape as ``FriendsManager``'s nudge cooldown, now
    keyed the same cross-session way). A per-recipient send failure
    (missing/expired token, a transient APNs error, or a propagated
    ``push.APNsConfigError``) is caught and logged, never allowed to abort
    the rest of the batch -- same per-recipient isolation posture as
    ``_notify_session_created`` above, deliberately NOT the single-target
    re-raise shape ``community.py``'s nudge route uses, since one ring
    request can legitimately target several members at once and one
    target's failure must not silently prevent the others from being
    evaluated or sent.

    Args:
        request: Injected by FastAPI/slowapi for the ``@limiter.limit`` IP
            check above.
        req: ``devotion_id`` (the live session), ``user_id`` (must match the
            session, i.e. the caller), and ``target_ids`` (one or more
            candidate recipients; duplicates are deduped, order-preserving).

    Returns:
        dict: ``{"results": {target_id: {"sent": bool, "reason": str | None}}}``
            -- one entry per unique requested ``target_id``. ``reason`` is
            ``None`` when ``sent`` is ``True``; otherwise one of
            ``"no_active_call"`` (the session has no live Chime meeting
            attached yet -- applied to every requested target at once,
            before any per-target check runs), ``"invalid_target"`` (the
            target is the caller themselves), ``"not_a_member"`` (not in
            this session's own group's real roster), ``"unreachable"``
            (valid member, no registered device token), ``"rate_limited"``
            (cooldown not yet elapsed for this (caller, target) pair,
            regardless of session), or ``"send_failed"`` (APNs send raised
            or reported non-delivery).

    Raises:
        HTTPException 404: The ring feature is disabled, or the session
            doesn't exist.
        HTTPException 403: The caller isn't an authorized participant of
            the session, isn't independently a real member of the
            session's own group, or ``req.user_id`` doesn't match the
            session user.
    """
    if req.user_id != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    if not is_ring_enabled():
        raise HTTPException(status_code=404, detail="Not found")

    db = DevotionManager()
    try:
        session = db.get_session(req.devotion_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")

        group_id = str(session.get("group_id") or "")
        roster = db.real_group_roster(group_id)
        if not db.is_authorized(session, current_user) or current_user not in roster:
            raise HTTPException(status_code=403, detail="Not authorized")

        target_ids = list(dict.fromkeys(req.target_ids))  # dedupe, order-preserving

        if not session.get("chime_meeting_id"):
            # No live call attached to this session yet -- deny the whole
            # batch up front without evaluating any target's membership or
            # cooldown (architecture.json's live_call_gating decision).
            return {
                "results": {
                    target_id: {"sent": False, "reason": "no_active_call"}
                    for target_id in target_ids
                }
            }

        eligible_members = roster - {current_user}
        results: dict[str, dict] = {}
        eligible: list[str] = []
        for target_id in target_ids:
            if target_id == current_user:
                results[target_id] = {"sent": False, "reason": "invalid_target"}
            elif target_id not in eligible_members:
                results[target_id] = {"sent": False, "reason": "not_a_member"}
            else:
                eligible.append(target_id)
        if not eligible:
            return {"results": results}

        tokens = db.device_tokens_bulk(eligible)
        caller_name = db.get_username(current_user) or "Someone"
        body = _ring_body(caller_name, session.get("title") or "")

        from backend.interactions.push import send_push

        for target_id in eligible:
            token = tokens.get(target_id)
            if not token:
                results[target_id] = {"sent": False, "reason": "unreachable"}
                continue
            if not db.claim_ring_slot(current_user, target_id):
                results[target_id] = {"sent": False, "reason": "rate_limited"}
                continue
            try:
                sent = await send_push(
                    token, _RING_TITLE, body,
                    data={"action": "ring", "devotion_id": req.devotion_id, "group_id": group_id},
                )
            except Exception as e:
                logger.error("Ring push failed (%s -> %s, session %s): %s", current_user, target_id, req.devotion_id, e)
                db.release_ring_claim(current_user, target_id)
                results[target_id] = {"sent": False, "reason": "send_failed"}
                continue
            if not sent:
                db.release_ring_claim(current_user, target_id)
                results[target_id] = {"sent": False, "reason": "send_failed"}
                continue
            results[target_id] = {"sent": True, "reason": None}

        return {"results": results}
    finally:
        db.close()


@devo_router.delete("/")
async def delete_devotion(req: DevotionRequest, current_user: str = Depends(get_current_user)) -> dict:
    if req.user_id != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    db = DevotionManager()
    try:
        # Only the session's creator (host) may delete it.
        session = db.read_devotion(req.devotion_id)
        if session is None:
            return {"ok": True}  # already gone — idempotent
        if str(session.creator_id) != str(req.user_id):
            raise HTTPException(status_code=403, detail="Only the session host can delete it.")
        db.remove_devotion(req.devotion_id)
        return {"ok": True}
    finally:
        db.close()


def _create_and_save_meeting(db: DevotionManager, session_id: str) -> dict:
    """Create a fresh Chime meeting for ``session_id`` and persist it --
    shared by the initial lazy-create branch below and the stale-meeting
    recreate path in ``join_call``, so both save through the same call."""
    resp = chime.create_meeting(
        ClientRequestToken=str(uuid.uuid4()),
        MediaRegion="us-east-1",
        ExternalMeetingId=session_id,
    )
    meeting_data = resp["Meeting"]
    db.save_chime_meeting(session_id, meeting_data["MeetingId"], meeting_data)
    return meeting_data


def _is_meeting_not_found(e: ClientError) -> bool:
    """True only for Chime's specific "meeting no longer exists" error.

    Confirmed against botocore's own chime-sdk-meetings service model:
    ``CreateAttendee`` raises ``NotFoundException`` ("One or more of the
    resources in the request does not exist in the system") when the
    ``MeetingId`` has been torn down (e.g. AWS's own idle-meeting expiry).
    This must stay a narrow match on that one error code -- never a blanket
    ``except ClientError`` retry -- so a genuinely different failure (e.g.
    the AccessDeniedException IAM misconfiguration 20260827 fixed) keeps
    falling through to the existing generic-error path unchanged (task
    20260916-chime-stale-meeting-retry; Q14 fail-closed / "don't
    blanket-catch-and-retry").
    """
    return e.response.get("Error", {}).get("Code") == "NotFoundException"


@devo_router.post("/join-call")
async def join_call(session_id: str, user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DevotionManager()
    try:
        session = db.get_session(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found")
        if not db.is_authorized(session, user_id):
            raise HTTPException(status_code=403, detail="Not authorized")

        chime_meeting_id = session.get("chime_meeting_id", "")
        meeting_data     = session.get("chime_meeting") or {}
        if isinstance(meeting_data, str):
            import json
            meeting_data = json.loads(meeting_data)

        if not chime_meeting_id:
            try:
                meeting_data     = _create_and_save_meeting(db, session_id)
                chime_meeting_id = meeting_data["MeetingId"]
            except ClientError as e:
                logger.error("Chime create_meeting failed for session %s: %s", session_id, e)
                raise HTTPException(status_code=500, detail=_CHIME_ERROR_DETAIL)

        try:
            attendee_resp = chime.create_attendee(
                MeetingId=chime_meeting_id,
                ExternalUserId=user_id,
            )
        except ClientError as e:
            if not _is_meeting_not_found(e):
                logger.error(
                    "Chime create_attendee failed for session %s, meeting %s, user %s: %s",
                    session_id, chime_meeting_id, user_id, e,
                )
                raise HTTPException(status_code=500, detail=_CHIME_ERROR_DETAIL)

            # Cached chime_meeting_id refers to a meeting AWS already tore
            # down (idle-meeting expiry) -- transparently recreate it and
            # retry create_attendee once, rather than surfacing a terminal
            # failure for what is really a stale-cache case.
            logger.warning(
                "Chime meeting %s for session %s no longer exists (torn down); "
                "recreating and retrying create_attendee once",
                chime_meeting_id, session_id,
            )
            try:
                meeting_data     = _create_and_save_meeting(db, session_id)
                chime_meeting_id = meeting_data["MeetingId"]
                attendee_resp = chime.create_attendee(
                    MeetingId=chime_meeting_id,
                    ExternalUserId=user_id,
                )
            except ClientError as retry_e:
                # Recreate itself failed, or the retried create_attendee
                # failed for any reason (including a second "not found") --
                # fall back to the generic error rather than looping again.
                logger.error(
                    "Chime create_attendee retry after meeting recreation failed "
                    "for session %s, user %s: %s",
                    session_id, user_id, retry_e,
                )
                raise HTTPException(status_code=500, detail=_CHIME_ERROR_DETAIL)

        return {"Meeting": meeting_data, "Attendee": attendee_resp["Attendee"]}
    finally:
        db.close()
