"""Schemas for the CloudWatch error-detection watchdog (poll job + persisted records).

Part of the cloudwatch-error-remediation workflow, step 3: poll-based
error-detection + context-assembly only. `ErrorDetection.context` is the
context-handoff payload a future write-capable remediation agent (step 8+,
not built here) would consume — nothing in this file is ever read by a
write-capable action in this step.
"""
import re
import uuid
from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field, field_validator


class LogGroupCursor(BaseModel):
    """Per-log-group watermark so consecutive watchdog runs never re-process
    or skip CloudWatch Logs events (see WatchdogManager.run_cycle for the
    window math this backs)."""

    log_group_name: str
    last_seen_time: datetime
    updated_at: datetime = Field(default_factory=lambda: datetime.now())


class ErrorDetection(BaseModel):
    """One detected error event plus its assembled surrounding context.

    `matched_signal` names which heuristic in cloudwatch_mcp_client's
    _ERROR_SIGNAL_PATTERNS fired (e.g. "traceback", "http_5xx"). `context`
    holds nearby log lines from the same log group and, when available, the
    MCP server's log-analyzer output for the surrounding window — this is
    the packaging step 4's read-only endpoint (and eventually a remediation
    agent) reads, not a signal for any automated action taken here.
    """

    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    log_group_name: str
    log_stream_name: str | None = None
    event_timestamp: datetime
    message: str
    matched_signal: str
    context: dict[str, Any] = Field(default_factory=dict)
    detected_at: datetime = Field(default_factory=lambda: datetime.now())
    status: str = "new"


class ErrorDetectionSummary(BaseModel):
    """List-view row for the (future, step 6) admin feed.

    Deliberately omits `context` -- the assembled nearby-events/log-analyzer
    payload can be large and a list of 50+ rows shouldn't carry it. The
    detail endpoint (`GET /monitoring/detections/{id}`) returns the full
    `ErrorDetection` including `context`.
    """

    id: str
    log_group_name: str
    log_stream_name: str | None = None
    event_timestamp: datetime
    message: str
    matched_signal: str
    detected_at: datetime
    status: str


class ErrorDetectionListResponse(BaseModel):
    """Paginated response for `GET /monitoring/detections`."""

    items: list[ErrorDetectionSummary] = Field(default_factory=list)
    total: int
    limit: int
    offset: int


class DetectionReport(BaseModel):
    """The debugging agent's diagnostic report for one `ErrorDetection`.

    Produced by `backend/monitoring/debug_agent.py::DebugAgentManager` from
    the detection's (secret-scrubbed) `message` + `context`, via an
    OpenRouter call. Strictly a text diagnosis -- `remediation_narrative` is
    a recommended-steps write-up for a human operator, never a record of an
    action actually taken (this agent has no execution capability). One
    report per detection: a rerun (`POST /monitoring/detections/{id}/report`)
    overwrites the prior report in place rather than accumulating history,
    mirroring `log_group_cursors`' upsert-on-unique-key pattern.
    """

    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    detection_id: str
    root_cause: str = ""
    remediation_narrative: str = ""
    model: str
    generated_at: datetime = Field(default_factory=lambda: datetime.now())


class ClientErrorReport(BaseModel):
    """Inbound payload for `POST /monitoring/client-error` (notes-load-
    failure-cloudwatch-gap workflow, step 1).

    A client-observable-only failure beacon: the app calls this when a
    server response it received fails to decode -- a well-formed 200 OK the
    client's own model can't parse, e.g. an out-of-date client build against
    a changed response contract (see this workflow's root-cause incident).
    watchdog.py's detection is entirely server-log-based; a 200 the client
    can't use produces none of its tracked 5xx/ERROR/CRITICAL/traceback/
    errno signal, so it's structurally invisible without a signal reported
    from the client side like this one.

    Deliberately minimal (data minimization, security step 2 of this
    workflow): only enough to correlate/triage an incident, never the raw
    response body or any other request/response content, which could carry
    note text or other user content. `error_summary` is expected to be a
    short, client-truncated description (e.g. a Swift DecodingError's
    `localizedDescription`), not a dump of the payload that failed to
    decode. Field lengths are capped server-side regardless of what the
    client sends.
    """

    endpoint: str = Field(max_length=200, description="Which API call failed to decode, e.g. 'GET /notes/{user_id}'")
    client_app_version: str = Field(default="", max_length=50, description="Client build identifier, e.g. '1.4.2 (37)' -- key signal for distinguishing an out-of-date build from a genuine current-code bug")
    http_status: int | None = Field(default=None, ge=100, le=599)
    error_summary: str = Field(default="", max_length=500, description="Short, client-truncated decode-error description -- never the raw response body")

    # security step 2 of this workflow: these three fields are formatted
    # straight into a single logger.error(...) line in routes/monitoring.py,
    # which watchdog.py then scans *per line* for signal patterns
    # (traceback/critical/error_level/http_5xx/etc, see _ERROR_SIGNAL_PATTERNS)
    # and feeds to the debug-agent LLM as "log context". Left unsanitized, a
    # client-supplied newline/control character here would let any
    # authenticated (non-admin) caller forge what looks like a *second*,
    # independent log line -- e.g. embedding a literal "Traceback (most
    # recent call last)" or "CRITICAL" -- to spoof a higher-severity
    # detection than actually occurred (CWE-117 log injection / ASVS
    # 16.4.1). Stripping all control characters (not just \n/\r) before the
    # value ever reaches the logger closes this off at the trust boundary,
    # matching this codebase's existing pattern of validating/normalizing
    # input in the schema layer (see users.py's `_check_timezone`) rather
    # than at the point of use.
    @field_validator("endpoint", "client_app_version", "error_summary")
    @classmethod
    def _strip_control_chars(cls, v: str) -> str:
        return re.sub(r"[\x00-\x1f\x7f]", " ", v).strip() if v else v
