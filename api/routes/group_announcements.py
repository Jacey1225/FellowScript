"""Group announcements endpoints (task 20260929-group-announcements).

Own module (not appended to ``group_info.py``) on its own ``/groups`` router.
Every route is authenticated + self-scoped (``require_match``) and
member-only: deny-by-default 403 for non-members, checked first. Creating is
gated for free-plan users via ``check_limit(user, "announcements")`` (same
403 body shape as notes). Edit/delete/restore: announcement creator or group
creator only. Banner: presigned upload mirroring group photos; the key is
attached via create/update and re-validated against this group's prefix.
"""

import logging

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict, StrictBool, StrictInt

from backend.auth.dependencies import require_match
from backend.interactions.announcement_banner import generate_announcement_banner_upload_policy
from backend.interactions.announcements import (
    ANNOUNCEMENTS_ENABLED, AnnouncementForbidden, AnnouncementFull, AnnouncementNotFound,
    AnnouncementsManager, REPEAT_KEYS, parse_publish_at,
)
from backend.interactions.announcement_repeat_rules import RepeatLimitReached
from backend.interactions.announcement_notifier import notify_on_create
from backend.interactions.announcement_polls import PollClosed, PollForbidden, PollNotFound
from backend.interactions.attachments import AttachmentConfigError
from backend.moderation.content_filter import ContentRejected, check_clean, rejection_message
from backend.rate_limiting import limiter
from backend.subscription.limits import check_limit

group_announcements_router = APIRouter(prefix="/groups")
logger = logging.getLogger(__name__)


class LinkIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    url: str
    label: str | None = None


class PaymentHandleIn(BaseModel):
    """Display-only host payment handle. Never processed by the app."""
    model_config = ConfigDict(extra="forbid")
    provider: str
    handle: str


class PollIn(BaseModel):
    """Optional poll attached to an announcement (flag ``announcement_polls``; 422 while off)."""
    model_config = ConfigDict(extra="forbid")
    question: str
    options: list[str]
    multiple: StrictBool = False
    closes_at: str | None = None  # ISO-8601 with offset, in the future, <= 365d ahead


class PollVoteIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    option_ids: list[str]


EXTRA_FIELDS = ("links", "gallery_keys", "is_event", "payment_handles", "capacity", "location")


def _extra_fields(fields: dict) -> dict:
    """Part E fields as plain JSON-shaped values (null/empty clears)."""
    out = {}
    for k in EXTRA_FIELDS:
        if k in fields:
            v = fields[k]
            if k in ("links", "payment_handles") and v is not None:
                v = [i.model_dump() if isinstance(i, BaseModel) else i for i in v]
            out[k] = v
    return out


class AnnouncementCreateRequest(BaseModel):
    title: str
    description: str = ""
    banner_key: str | None = None
    publish_at: str | None = None  # ISO-8601 with offset; None = publish now
    title_color: str | None = None  # strict #RRGGBB; None = default parchment
    title_font: str | None = None  # allowlisted key; flag-gated (422 while off)
    bg_theme: str | None = None  # allowlisted key; flag-gated (422 while off)
    # Part E attachments; each non-empty value is flag-gated (422 while off).
    links: list[LinkIn] | None = None
    gallery_keys: list[str] | None = None
    is_event: StrictBool | None = None
    payment_handles: list[PaymentHandleIn] | None = None
    capacity: StrictInt | None = None
    location: str | None = None  # flag-gated (422 while off); blank/null = none
    poll: PollIn | None = None  # flag-gated (422 while off)
    # Recurring reminder (ANNOUNCEMENT_REPEAT_ENABLED; a non-null interval is 422 while off).
    repeat_interval: str | None = None  # "daily" | "weekly" | "monthly"; null = no repeat
    repeat_until: str | None = None  # ISO-8601 with offset, after publish_at, <= 365d ahead
    repeat_tz: str | None = None  # IANA name the wall-clock time repeats in; null = UTC


class AnnouncementUpdateRequest(BaseModel):
    """Only fields present in the body are applied (banner_key: null clears)."""
    title: str | None = None
    description: str | None = None
    banner_key: str | None = None
    publish_at: str | None = None
    title_color: str | None = None  # null resets to default
    title_font: str | None = None  # null resets; non-null needs flag + allowlist
    bg_theme: str | None = None  # null resets; non-null needs flag + allowlist
    links: list[LinkIn] | None = None  # null / [] clears
    gallery_keys: list[str] | None = None
    is_event: StrictBool | None = None
    payment_handles: list[PaymentHandleIn] | None = None
    capacity: StrictInt | None = None  # null clears (drops RSVPs)
    location: str | None = None  # null / blank clears
    poll: PollIn | None = None  # null removes the poll (and its votes); options lock once anyone has voted
    repeat_interval: str | None = None  # null clears the whole repeat; editable after publish
    repeat_until: str | None = None  # null removes the end date
    repeat_tz: str | None = None  # null = UTC


class BannerUploadUrlRequest(BaseModel):
    content_type: str
    size_bytes: int | None = None  # advisory; S3 policy enforces size


def _open(user_id: str, group_id: str) -> AnnouncementsManager:
    """Feature-flag + membership gate. Caller must close on success; closed
    here on failure."""
    if not ANNOUNCEMENTS_ENABLED:
        raise HTTPException(status_code=404, detail="Not found")
    manager = AnnouncementsManager(user_id, group_id)
    try:
        if not manager.is_member():
            raise HTTPException(status_code=403, detail="Not a member of this group")
    except Exception:
        manager.close()
        raise
    return manager


def _clean(**fields: str | None) -> None:
    try:
        check_clean(**fields)
    except ContentRejected as e:
        raise HTTPException(status_code=422, detail=rejection_message(e))


def _poll_text(poll) -> dict:
    """Poll question/options as content-filter fields (empty when no poll)."""
    if isinstance(poll, BaseModel):
        poll = poll.model_dump()
    if not isinstance(poll, dict):
        return {}
    out = {"poll_question": str(poll.get("question") or "")}
    for i, o in enumerate(poll.get("options") or []):
        out[f"poll_option_{i}"] = str(o)
    return out


def _publish_at(value: str | None):
    try:
        return parse_publish_at(value)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))


@group_announcements_router.get("/{user_id}/{group_id}/announcements")
async def list_announcements(user_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """List visible announcements plus the caller's usage (for upgrade UI).

    Raises: 403 not a member."""
    manager = _open(user_id, group_id)
    try:
        result = manager.list_announcements()
    finally:
        manager.close()
    result["gate"] = check_limit(user_id, "announcements")
    return result


@group_announcements_router.post("/{user_id}/{group_id}/announcements", status_code=201)
@limiter.limit("30/minute")
async def create_announcement(
    request: Request, user_id: str, group_id: str, body: AnnouncementCreateRequest,
    background_tasks: BackgroundTasks, _: str = Depends(require_match("user_id")),
) -> dict:
    """Create an announcement.

    Raises: 403 not a member / foreign banner key / free limit reached (body
    is the limits dict, as for notes); 409 repeat limit reached; 422 validation
    or content filter.
    """
    manager = _open(user_id, group_id)
    try:
        _clean(title=body.title, description=body.description, location=body.location,
               **{f"link_label_{i}": (l.label or "") for i, l in enumerate(body.links or [])},
               **_poll_text(body.poll))
        publish_at = _publish_at(body.publish_at)
        gate = check_limit(user_id, "announcements")
        if not gate["allowed"]:
            raise HTTPException(status_code=403, detail=gate)
        try:
            created = manager.create_announcement(body.title, body.description, body.banner_key, publish_at,
                                                title_color=body.title_color,
                                                title_font=body.title_font, bg_theme=body.bg_theme,
                                                extra=_extra_fields({k: getattr(body, k) for k in body.model_fields_set}),
                                                poll=body.poll.model_dump() if body.poll else None,
                                                repeat={k: getattr(body, k) for k in REPEAT_KEYS
                                                        if k in body.model_fields_set})
            # Group push runs after the response (off the request path); the
            # notifier claims atomically and never raises.
            background_tasks.add_task(notify_on_create, created["id"])
            return created
        except RepeatLimitReached as e:
            raise HTTPException(status_code=409, detail=str(e))
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
        except AnnouncementForbidden:
            raise HTTPException(status_code=403, detail="Invalid banner reference")
    finally:
        manager.close()


@group_announcements_router.get("/{user_id}/{group_id}/announcements/latest")
async def latest_announcement(user_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Chat-header widget source: ``{"announcement": {...} | null}``. Declared
    before the ``{announcement_id}`` route so "latest" is never captured as an id.

    Raises: 403 not a member; 404 feature disabled."""
    manager = _open(user_id, group_id)
    try:
        return manager.latest_widget_announcement()
    finally:
        manager.close()


@group_announcements_router.get("/{user_id}/{group_id}/announcements/{announcement_id}")
async def get_announcement(
    user_id: str, group_id: str, announcement_id: str, _: str = Depends(require_match("user_id")),
) -> dict:
    """Raises: 403 not a member; 404 missing/not visible."""
    manager = _open(user_id, group_id)
    try:
        return manager.get_announcement(announcement_id)
    except AnnouncementNotFound:
        raise HTTPException(status_code=404, detail="Announcement not found")
    finally:
        manager.close()


@group_announcements_router.put("/{user_id}/{group_id}/announcements/{announcement_id}")
@limiter.limit("30/minute")
async def update_announcement(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    body: AnnouncementUpdateRequest, _: str = Depends(require_match("user_id")),
) -> dict:
    """Edit (creator or group creator). Not counted against the free limit.

    Raises: 403 not a member / not allowed / foreign banner key; 404;
    409 repeat limit reached; 422 validation, content filter, or publish_at
    change after publishing.
    """
    fields = {k: getattr(body, k) for k in body.model_fields_set}
    fields.update(_extra_fields(fields))
    if isinstance(fields.get("poll"), BaseModel):
        fields["poll"] = fields["poll"].model_dump()
    manager = _open(user_id, group_id)
    try:
        _clean(title=fields.get("title"), description=fields.get("description"), location=fields.get("location"),
               **{f"link_label_{i}": (l.get("label") or "") for i, l in enumerate(fields.get("links") or [])},
               **_poll_text(fields.get("poll")))
        if "publish_at" in fields:
            fields["publish_at"] = _publish_at(fields["publish_at"])
        try:
            return manager.update_announcement(announcement_id, fields)
        except AnnouncementNotFound:
            raise HTTPException(status_code=404, detail="Announcement not found")
        except AnnouncementForbidden:
            raise HTTPException(status_code=403, detail="Not allowed to edit this announcement")
        except RepeatLimitReached as e:
            raise HTTPException(status_code=409, detail=str(e))
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
    finally:
        manager.close()


@group_announcements_router.delete("/{user_id}/{group_id}/announcements/{announcement_id}")
@limiter.limit("30/minute")
async def delete_announcement(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Soft delete; undo via ``.../restore`` within the grace window.

    Raises: 403 not a member / not allowed; 404."""
    manager = _open(user_id, group_id)
    try:
        manager.delete_announcement(announcement_id)
        return {"deleted": True, "id": announcement_id}
    except AnnouncementNotFound:
        raise HTTPException(status_code=404, detail="Announcement not found")
    except AnnouncementForbidden:
        raise HTTPException(status_code=403, detail="Not allowed to delete this announcement")
    finally:
        manager.close()


@group_announcements_router.post("/{user_id}/{group_id}/announcements/{announcement_id}/restore")
@limiter.limit("30/minute")
async def restore_announcement(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Undo a delete within the grace window. Raises: 403; 404 if not deleted
    or the grace window has lapsed."""
    manager = _open(user_id, group_id)
    try:
        return manager.restore_announcement(announcement_id)
    except AnnouncementNotFound:
        raise HTTPException(status_code=404, detail="Announcement not found")
    except AnnouncementForbidden:
        raise HTTPException(status_code=403, detail="Not allowed to restore this announcement")
    finally:
        manager.close()


@group_announcements_router.post("/{user_id}/{group_id}/announcements/banner/upload-url")
@limiter.limit("30/minute")
async def request_banner_upload_url(
    request: Request, user_id: str, group_id: str, info: BannerUploadUrlRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Presigned S3 POST policy for a banner. Raises: 400 bad content_type;
    403 not a member; 503 uploads not configured."""
    manager = _open(user_id, group_id)
    manager.close()
    try:
        return generate_announcement_banner_upload_policy(user_id, group_id, info.content_type)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except AttachmentConfigError as e:
        logger.error("Announcement banner upload requested but not configured: %s", e)
        raise HTTPException(status_code=503, detail="Banner uploads are not available right now.")


@group_announcements_router.post("/{user_id}/{group_id}/announcements/{announcement_id}/rsvp")
@limiter.limit("30/minute")
async def rsvp_join(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotent RSVP to a joinable announcement (not a group join). Returns
    the announcement with the updated count.

    Raises: 403 not a member; 404 not joinable / not visible / flag off;
    409 full."""
    manager = _open(user_id, group_id)
    try:
        return manager.rsvp_join(announcement_id)
    except AnnouncementNotFound:
        raise HTTPException(status_code=404, detail="Announcement not found")
    except AnnouncementFull:
        raise HTTPException(status_code=409, detail="This event is full")
    finally:
        manager.close()


@group_announcements_router.delete("/{user_id}/{group_id}/announcements/{announcement_id}/rsvp")
@limiter.limit("30/minute")
async def rsvp_leave(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Idempotent cancel. Raises: 403 not a member; 404."""
    manager = _open(user_id, group_id)
    try:
        return manager.rsvp_leave(announcement_id)
    except AnnouncementNotFound:
        raise HTTPException(status_code=404, detail="Announcement not found")
    finally:
        manager.close()


@group_announcements_router.get("/{user_id}/{group_id}/announcements/{announcement_id}/rsvps")
async def list_rsvps(
    user_id: str, group_id: str, announcement_id: str, _: str = Depends(require_match("user_id")),
) -> dict:
    """Attendee list for the host (announcement creator or group creator).

    Raises: 403 not a member / not the host; 404."""
    manager = _open(user_id, group_id)
    try:
        return manager.list_rsvps(announcement_id)
    except AnnouncementNotFound:
        raise HTTPException(status_code=404, detail="Announcement not found")
    except AnnouncementForbidden:
        raise HTTPException(status_code=403, detail="Only the host can see the attendee list")
    finally:
        manager.close()


@group_announcements_router.post("/{user_id}/{group_id}/announcements/{announcement_id}/poll/vote")
@limiter.limit("30/minute")
async def poll_vote(
    request: Request, user_id: str, group_id: str, announcement_id: str, body: PollVoteIn,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Set the caller's answer(s), replacing any earlier choice (idempotent). Returns the
    announcement with live counts. Votes are anonymous.

    Raises: 403 not a member; 404 no votable poll / flag off; 409 poll closed;
    422 unknown option or more answers than the poll allows."""
    manager = _open(user_id, group_id)
    try:
        manager.poll_vote(announcement_id, body.option_ids)
        return manager.get_announcement(announcement_id)
    except (PollNotFound, AnnouncementNotFound):
        raise HTTPException(status_code=404, detail="Poll not found")
    except PollClosed:
        raise HTTPException(status_code=409, detail="This poll is closed")
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    finally:
        manager.close()


@group_announcements_router.delete("/{user_id}/{group_id}/announcements/{announcement_id}/poll/vote")
@limiter.limit("30/minute")
async def poll_retract(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Clear the caller's answer (idempotent). Raises: 403; 404; 409 closed."""
    manager = _open(user_id, group_id)
    try:
        manager.poll_retract(announcement_id)
        return manager.get_announcement(announcement_id)
    except (PollNotFound, AnnouncementNotFound):
        raise HTTPException(status_code=404, detail="Poll not found")
    except PollClosed:
        raise HTTPException(status_code=409, detail="This poll is closed")
    finally:
        manager.close()


@group_announcements_router.post("/{user_id}/{group_id}/announcements/{announcement_id}/poll/close")
@limiter.limit("30/minute")
async def poll_close(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Close the poll now (announcement creator or group creator; idempotent).
    Raises: 403 not a member / not allowed; 404."""
    manager = _open(user_id, group_id)
    try:
        manager.poll_close(announcement_id)
        return manager.get_announcement(announcement_id)
    except (PollNotFound, AnnouncementNotFound):
        raise HTTPException(status_code=404, detail="Poll not found")
    except PollForbidden:
        raise HTTPException(status_code=403, detail="Not allowed to close this poll")
    finally:
        manager.close()
