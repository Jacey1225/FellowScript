"""Schemas for the CloudWatch error-detection watchdog (poll job + persisted records).

Part of the cloudwatch-error-remediation workflow, step 3: poll-based
error-detection + context-assembly only. `ErrorDetection.context` is the
context-handoff payload a future write-capable remediation agent (step 8+,
not built here) would consume — nothing in this file is ever read by a
write-capable action in this step.
"""
import uuid
from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field


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
