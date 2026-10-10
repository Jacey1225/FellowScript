"""Shared AWS Chime SDK Meetings helper used by discussion rooms.

Task 20261009-discussion-rooms. One place for: create a meeting, create an
attendee with the one-shot stale-meeting recreate, best-effort delete, and an
existence probe.

Why ``routes/devotion.py`` and ``routes/messaging.py`` are NOT repointed here:
both own a module-level ``chime`` client and ``_create_and_save_meeting`` that
existing tests replace by assigning ``devotion_module.chime`` /
``messaging_module.chime``. Repointing them at this module would silently bypass
those fakes (the tests would hit real AWS or stop exercising the code), so the
two legacy copies are left untouched and rooms are the only caller of this
helper. Folding the legacy paths onto it is a follow-up that must update those
tests in the same change.

Narrow error handling, same rule as the legacy paths: only
``NotFoundException`` means "the meeting was torn down" (safe to recreate);
every other ``ClientError`` propagates to the caller unchanged.

Quotas this module is sized against (AWS "Amazon Chime SDK WebRTC quotas",
docs.aws.amazon.com/general/latest/gr/chime-sdk.html, read 2026-10-09):
concurrent meetings 250 per account/region (adjustable); attendees per meeting
250 (fixed); CreateMeeting / CreateAttendee / GetMeeting / DeleteMeeting 10
requests per second each (adjustable with the meeting limit); video streams
published per meeting 25. The idle-meeting expiry window is NOT stated on those
pages and is not relied on for correctness here: liveness is tracked by our own
member heartbeats plus a ``get_meeting`` probe.
"""
from __future__ import annotations

import logging
import uuid

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

MEDIA_REGION = "us-east-1"
# Bounded network time: callers may hold a row lock across these calls.
_CLIENT_CONFIG = Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 2, "mode": "standard"})

chime = boto3.client("chime-sdk-meetings", region_name=MEDIA_REGION, config=_CLIENT_CONFIG)


def is_meeting_not_found(e: ClientError) -> bool:
    """True only for Chime's "meeting no longer exists" error code."""
    return e.response.get("Error", {}).get("Code") == "NotFoundException"


def create_meeting(external_meeting_id: str) -> dict:
    """Create a fresh meeting and return the ``Meeting`` dict.

    ``external_meeting_id`` is namespaced by the caller (rooms use
    ``room:<room uuid>``) so a room is distinguishable from a main session
    meeting (which uses the bare session uuid). Raises ``ClientError``.
    """
    resp = chime.create_meeting(
        ClientRequestToken=str(uuid.uuid4()),
        MediaRegion=MEDIA_REGION,
        ExternalMeetingId=external_meeting_id,
    )
    return resp["Meeting"]


def create_attendee_with_recreate(
    meeting: dict | None, external_meeting_id: str, external_user_id: str
) -> tuple[dict, dict, bool]:
    """Return ``(meeting, attendee, recreated)``.

    ``meeting`` is the cached ``Meeting`` dict (or empty/None when none exists
    yet, which creates one). If ``create_attendee`` reports the cached meeting
    gone, a new meeting is created and ``create_attendee`` retried exactly once.
    ``recreated`` is True whenever the returned meeting differs from the input,
    so the caller knows to persist it. Any other ``ClientError`` propagates.
    """
    recreated = False
    if not meeting or not meeting.get("MeetingId"):
        meeting = create_meeting(external_meeting_id)
        recreated = True
    just_created = recreated
    try:
        attendee = chime.create_attendee(MeetingId=meeting["MeetingId"], ExternalUserId=external_user_id)
    except ClientError as e:
        # A meeting created moments ago that is already "not found" is not a
        # stale-cache case: surface it instead of looping.
        if just_created or not is_meeting_not_found(e):
            raise
        logger.warning("Chime meeting %s no longer exists; recreating once", meeting.get("MeetingId"))
        meeting = create_meeting(external_meeting_id)
        recreated = True
        attendee = chime.create_attendee(MeetingId=meeting["MeetingId"], ExternalUserId=external_user_id)
    return meeting, attendee["Attendee"], recreated


def meeting_exists(meeting_id: str) -> bool | None:
    """True if Chime still has the meeting, False if confirmed gone, None if unknown.

    None (any other error) means "do not act": callers must fail closed.
    """
    try:
        chime.get_meeting(MeetingId=meeting_id)
        return True
    except ClientError as e:
        if is_meeting_not_found(e):
            return False
        logger.warning("Chime get_meeting failed (non-NotFound) for a room meeting: %s", e)
        return None
    except Exception as e:
        logger.warning("Chime get_meeting failed for a room meeting: %s", e)
        return None


def delete_meeting(meeting_id: str) -> bool:
    """Best-effort delete; True if gone afterwards. Never raises."""
    if not meeting_id:
        return True
    try:
        chime.delete_meeting(MeetingId=meeting_id)
        return True
    except ClientError as e:
        if is_meeting_not_found(e):
            return True
        logger.warning("Chime delete_meeting failed for a room meeting: %s", e)
        return False
    except Exception as e:
        logger.warning("Chime delete_meeting failed for a room meeting: %s", e)
        return False
