"""Schemas for the admin Activity Monitoring panel (task
20260918-admin-activity-monitoring, extended by task
20260919-activity-monitoring-interactive-charts).

Three surfaces share this file:

1. ``VisitCreate`` -- the inbound payload for the public, anonymous
   visit-logging beacon (``POST /activity-monitoring/visits``). This is the
   one write path in the feature reachable without ``require_admin``/
   ``get_current_user`` at all -- it must work for a logged-out visitor
   browsing the public site.
2. The admin-only PNG endpoints (``GET /activity-monitoring/plots/*``) still
   return rendered image bytes directly (``Response(media_type="image/
   png")``), not a JSON schema -- unchanged from the prior task.
3. ``MetricSeriesResponse``/``VisitsSeriesResponse`` -- the JSON payloads for
   the new admin-only ``GET /activity-monitoring/data/*`` endpoints (task
   20260919, step 2). The prior task deliberately kept this feature
   image-only for Cache-Control/PII-adjacent-data reasons (see git history
   on this file / activity_plots.py's docstring); this task's security step
   1 threat-modeled reopening that boundary, and clarification-response.md
   records the user's explicit approval (Security Posture Q16 hard stop) to
   do so. These response models carry *exactly* the same (day, value)
   resolution the PNGs already visually encode -- same fixed
   ``DEFAULT_WINDOW_DAYS`` window, same daily granularity, same
   already-aggregated/per-user-averaged values -- never raw per-row data,
   device IDs, or any join back to ``users``/``sessions`` beyond what the
   existing aggregate queries already compute (security step 1, requirement
   2: the new surface's information disclosure must stay equivalent to
   today's chart despite the transport-format change).

Device-identifier scheme (security step 1, resolving the intake spec's open
question): a client-generated, client-persisted (localStorage, not a cookie)
random UUIDv4, sent explicitly as a JSON body field on each visit call --
never a cookie, never derived from IP/User-Agent. The server treats it as a
fully opaque token and validates it is *shaped* like a UUIDv4 (rejecting
anything else with 422) without attempting to decode any meaning from it or
ever joining it against `users`/`sessions`.
"""
import re
from datetime import date

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


class MetricPoint(BaseModel):
    """One (day, avg-per-user) data point -- the same resolution
    `activity_plots.render_line_chart`'s PNG already plots, exposed as
    structured data for `GET /activity-monitoring/data/{metric}`.
    """

    day: date
    value: float


class MetricSeriesResponse(BaseModel):
    """JSON payload for `GET /activity-monitoring/data/{metric}` (task
    20260919, step 2) -- one of the four average-per-user metrics (notes,
    highlights, logins, messages) for the fixed trailing
    `DEFAULT_WINDOW_DAYS`-day window, same series a client-side chart needs
    to render its own hover/tooltip interactivity instead of a static PNG.
    """

    metric: str
    title: str
    ylabel: str
    series: list[MetricPoint] = Field(default_factory=list)


class VisitPoint(BaseModel):
    """One day's (raw_visits, unique_devices) pair -- the same two series
    `activity_plots.render_visits_chart`'s PNG already plots, kept together
    per day (rather than as two parallel arrays) since they always share the
    same day axis.
    """

    day: date
    raw: int
    unique: int


class VisitsSeriesResponse(BaseModel):
    """JSON payload for `GET /activity-monitoring/data/visits` (task
    20260919, step 2) -- raw-visits-vs-unique-device-visitors for the fixed
    trailing `DEFAULT_WINDOW_DAYS`-day window.
    """

    title: str
    series: list[VisitPoint] = Field(default_factory=list)
