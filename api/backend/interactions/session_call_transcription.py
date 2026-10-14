"""Glue between the call-join endpoints and live-call transcription: starts
transcription (flag-gated, paid starters only), records presence, and builds
the transcription fields every join response carries.

Shared by ``/devotions/join-call`` (iOS) and ``/chime/{session}/{user}/attend``
(web/desktop) so both clients get the same consent and relay signals. Never
raises, never touches transcript text.
"""
from __future__ import annotations

import logging

from backend.interactions import session_relay as relay
from backend.interactions import session_transcript as st
from backend.interactions.session_transcription_config import (
    get_session_transcription_config, is_transcription_enabled)

logger = logging.getLogger(__name__)


def _is_paid(user_id: str) -> bool:
    from backend.subscription.limits import check_paid_only
    return bool(check_paid_only(user_id, "session_summaries")["allowed"])


def is_relay(session_id: str, creator_id: str, user_id: str) -> bool:
    return relay.designated_relay(session_id, creator_id, _is_paid) == user_id


def other_paid_attendees_present(session_id: str, user_id: str) -> bool:
    """True while another paid attendee is still in the call. Only paid users
    can produce a summary, so a free attendee does not hold the summary back.
    Fail closed toward summarizing (False) on any error."""
    try:
        return relay.others_present(session_id, user_id, _is_paid)
    except Exception:
        return False


def maybe_start_transcription(session_id: str, meeting_id: str, user_id: str) -> bool:
    """True iff the call is being transcribed (consent banner signal). Fail
    closed; only a paid user's join may START transcription."""
    try:
        if not is_transcription_enabled():
            return False
        if st.is_active(session_id):
            return True
        if not _is_paid(user_id):
            return False
        from backend.interactions import chime_meetings
        if chime_meetings.start_transcription(meeting_id, get_session_transcription_config().language_code):
            st.mark_active(session_id)
            logger.info("AUDIT transcription started session=%s meeting=%s by_user=%s", session_id, meeting_id, user_id)
            return True
    except Exception as e:
        logger.warning("transcription start skipped for session %s: %s", session_id, type(e).__name__)
    return False


def join_transcription_fields(session_id: str, meeting_id: str, user_id: str, creator_id: str) -> dict:
    """Fields merged into a join response. With the flag off (or any failure)
    everything is false, so clients show no banner and relay nothing."""
    fields = {"transcription_active": False, "transcript_relay": False, "transcript_poll_seconds": 0}
    try:
        if not is_transcription_enabled():
            return fields
        relay.record_join(session_id, user_id)
        active = maybe_start_transcription(session_id, meeting_id, user_id)
        fields["transcription_active"] = active
        if active:
            fields["transcript_relay"] = is_relay(session_id, creator_id, user_id)
            fields["transcript_poll_seconds"] = get_session_transcription_config().relay_poll_interval_seconds
    except Exception as e:
        logger.warning("transcription join fields failed for session %s: %s", session_id, type(e).__name__)
    return fields
