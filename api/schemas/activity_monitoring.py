"""Schemas for the admin Activity Monitoring panel (task
20260918-admin-activity-monitoring).

Two surfaces share this file:

1. ``VisitCreate`` -- the inbound payload for the public, anonymous
   visit-logging beacon (``POST /activity-monitoring/visits``). This is the
   one write path in the feature reachable without ``require_admin``/
   ``get_current_user`` at all -- it must work for a logged-out visitor
   browsing the public site.
2. The admin-only aggregation endpoints (``GET /activity-monitoring/plots/*``)
   return rendered PNG image bytes directly (``Response(media_type="image/
   png")``), not a JSON schema -- see routes/activity_monitoring.py for why
   (security step 1's decision on plot delivery: embedded images, not a JSON
   payload carrying aggregate PII-adjacent numbers).

Device-identifier scheme (security step 1, resolving the intake spec's open
question): a client-generated, client-persisted (localStorage, not a cookie)
random UUIDv4, sent explicitly as a JSON body field on each visit call --
never a cookie, never derived from IP/User-Agent. The server treats it as a
fully opaque token and validates it is *shaped* like a UUIDv4 (rejecting
anything else with 422) without attempting to decode any meaning from it or
ever joining it against `users`/`sessions`.
"""
import re

from pydantic import BaseModel, Field, field_validator

# Matches only a version-4 UUID (the `4` version nibble and one of the
# `8`/`9`/`a`/`b` variant nibbles are checked explicitly, not just "any UUID
# shape") -- security step 1: never persist a client-controlled value that
# hasn't been validated against this exact shape, so a caller can't smuggle
# arbitrary text (or an oversized string) into the `visits` table through
# this field.
_UUID_V4_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)

# No query string, no path traversal weirdness -- this is logged/aggregated
# as a coarse "which route was visited" label, never parsed or executed, but
# capping it defends against someone using this open, unauthenticated
# endpoint to stuff arbitrary long strings into the table (security step 1's
# metrics-pollution concern).
_MAX_PATH_LENGTH = 200


class VisitCreate(BaseModel):
    """Inbound payload for ``POST /activity-monitoring/visits``.

    Exactly two client-controlled fields, per security step 1's explicit
    scoping of this new public write surface -- no free-form metadata field,
    no IP/User-Agent capture (the server derives nothing else from the
    request to persist alongside these).
    """

    device_id: str = Field(
        description="Client-generated, localStorage-persisted UUIDv4 -- opaque to the server."
    )
    path: str = Field(
        max_length=_MAX_PATH_LENGTH,
        description="The route the client is reporting a visit to, e.g. '/notes'.",
    )

    @field_validator("device_id")
    @classmethod
    def _validate_device_id(cls, v: str) -> str:
        if not _UUID_V4_RE.match(v or ""):
            raise ValueError("device_id must be a UUIDv4 string")
        return v.lower()

    @field_validator("path")
    @classmethod
    def _validate_path(cls, v: str) -> str:
        v = (v or "").strip()
        if not v:
            raise ValueError("path must not be empty")
        if "?" in v or "\n" in v or "\r" in v:
            # No query string (could carry arbitrary key/value junk into the
            # aggregate data) and no control characters (log-injection
            # precedent -- see schemas/watchdog.py's ClientErrorReport).
            raise ValueError("path must not contain a query string or control characters")
        return v
