"""Read-only endpoints serving persisted CloudWatch error-detection records
(and their assembled context) to the admin page, plus the debugging agent's
per-detection diagnostic report.

Steps 4 and 3 of the cloudwatch-error-remediation / error-debug-agent-admin-
page workflows respectively. The detection-listing endpoints are strictly
read-only; the report endpoints never execute or queue any remediation
action either -- `POST .../report` only (re)runs the read-only debugging
agent (see `backend/monitoring/debug_agent.py`), it does not itself act on
the server. This module reads/writes only `error_detections` and
`error_detection_reports` via WatchdogManager / DebugAgentManager.

Auth: `require_admin` (session auth + `is_admin` lookup; see
`backend/auth/dependencies.py`) gates every endpoint below -- 401 for no/
invalid session, 403 for an authenticated-but-non-admin caller. This replaces
the prior any-authenticated-user `get_current_user` placeholder entirely.

Audit logging: every endpoint below logs `who` (the admin's user_id, from
`require_admin`'s return value), `what` (the action + detection_id), and
`when` (the log record's own timestamp, per `main.py`'s
`logging.basicConfig` format) via `_audit`, on a dedicated `admin_audit`
logger so these lines are greppable/filterable independent of general app
logs -- security step 4 of the error-debug-agent-admin-page workflow calls
this out explicitly for the admin surface (ASVS 5.0 16.3.2: log authorization
decisions/admin actions, not just failures).

Rate limiting: `POST .../report` (on-demand debugging-agent rerun) is
rate-limited -- unlike the read endpoints, each call is a real OpenRouter LLM
call, so it's cost/abuse-bounded the same way brute-forceable auth endpoints
are in `main.py`, via the shared `backend.rate_limiting.limiter`.

Caching: every endpoint below sets `Cache-Control: no-store` -- this surface
returns raw log/exception content and LLM-generated diagnostic narratives
(higher-sensitivity than typical account data, per security step 4's
redaction-gap notes), so responses must not be persisted by the browser's
disk cache or any intermediate cache beyond the request itself (pre-launch
security step 8, general OWASP admin-panel hardening pass).
"""
import asyncio
import logging
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response

from backend.auth.dependencies import require_admin
from backend.monitoring.watchdog import WatchdogManager
from backend.monitoring.debug_agent import DebugAgentManager, run_debug_agent_for_detection
from backend.rate_limiting import limiter
from schemas.watchdog import DetectionReport, ErrorDetection, ErrorDetectionListResponse

logger = logging.getLogger(__name__)
audit_logger = logging.getLogger("admin_audit")

monitoring_router = APIRouter(prefix="/monitoring")

DEFAULT_LIST_LIMIT = 50
MAX_LIST_LIMIT = 200


def _audit(action: str, admin_id: str, detection_id: str | None = None) -> None:
    """One structured admin-audit-trail line per admin action on this
    surface. `admin_id` always comes from `require_admin`'s DB-verified
    return value, never a client-supplied field."""
    audit_logger.info(
        "admin_action action=%s admin_id=%s detection_id=%s", action, admin_id, detection_id
    )


@monitoring_router.get("/detections")
async def list_error_detections(
    response: Response,
    log_group_name: str | None = Query(
        default=None, description="Filter to one CloudWatch log group, e.g. /fellowscript/app"
    ),
    start_time: datetime | None = Query(
        default=None, description="Only detections detected at/after this UTC time"
    ),
    end_time: datetime | None = Query(
        default=None, description="Only detections detected at/before this UTC time"
    ),
    limit: int = Query(default=DEFAULT_LIST_LIMIT, ge=1, le=MAX_LIST_LIMIT),
    offset: int = Query(default=0, ge=0),
    admin_id: str = Depends(require_admin),
) -> ErrorDetectionListResponse:
    """List persisted error detections, most recent first.

    Read-only feed for the (future) admin page -- summary rows only, no
    `context` blob (see `get_error_detection` for the full record with
    context). Filter by log group and/or a `detected_at` time range;
    paginate via `limit`/`offset`.

    Args:
        log_group_name: Optional exact-match filter, e.g. "/fellowscript/app".
        start_time: Optional inclusive lower bound on `detected_at`.
        end_time: Optional inclusive upper bound on `detected_at`.
        limit: Max rows to return (1-200, default 50).
        offset: Rows to skip, for paging.

    Returns:
        ErrorDetectionListResponse: `items` (summaries), `total` (count
            matching the filters, independent of pagination), `limit`, `offset`.
    """
    _audit("list_detections", admin_id)
    response.headers["Cache-Control"] = "no-store"
    manager = WatchdogManager()
    try:
        items = manager.list_detections(
            log_group_name=log_group_name,
            start_time=start_time,
            end_time=end_time,
            limit=limit,
            offset=offset,
        )
        total = manager.count_detections(
            log_group_name=log_group_name, start_time=start_time, end_time=end_time
        )
        return ErrorDetectionListResponse(items=items, total=total, limit=limit, offset=offset)
    finally:
        manager.close()


@monitoring_router.get("/detections/{detection_id}")
async def get_error_detection(
    detection_id: str, response: Response, admin_id: str = Depends(require_admin)
) -> ErrorDetection:
    """Fetch one detection's full record, including its assembled context
    (nearby log lines + MCP log-analyzer output) for the admin detail drill-in.

    Raises:
        HTTPException 404: If no detection exists with that ID.
    """
    _audit("get_detection", admin_id, detection_id)
    response.headers["Cache-Control"] = "no-store"
    manager = WatchdogManager()
    try:
        detection = manager.get_detection(detection_id)
        if detection is None:
            raise HTTPException(status_code=404, detail="Detection not found")
        return detection
    finally:
        manager.close()


@monitoring_router.get("/detections/{detection_id}/report")
async def get_detection_report(
    detection_id: str, response: Response, admin_id: str = Depends(require_admin)
) -> DetectionReport:
    """Fetch the debugging agent's persisted diagnostic report for one
    detection (root cause + remediation narrative).

    Raises:
        HTTPException 404: If the detection doesn't exist, or exists but has
            no report yet (e.g. the automatic watchdog-cycle generation
            failed and no rerun has happened) -- both are indistinguishable
            "nothing to show" cases to the caller today; the admin page can
            offer the rerun action in either case.
    """
    _audit("get_report", admin_id, detection_id)
    response.headers["Cache-Control"] = "no-store"
    manager = DebugAgentManager()
    try:
        report = manager.get_report(detection_id)
        if report is None:
            raise HTTPException(status_code=404, detail="No report generated yet for this detection")
        return report
    finally:
        manager.close()


@monitoring_router.post("/detections/{detection_id}/report")
@limiter.limit("5/minute")
async def rerun_detection_report(
    request: Request, detection_id: str, response: Response, admin_id: str = Depends(require_admin)
) -> DetectionReport:
    """On-demand (re)generate the debugging agent's report for one
    detection, e.g. from the admin page after an automatic-generation
    failure, or to refresh a report. Overwrites any existing report for this
    detection in place (upsert on `detection_id`) rather than accumulating a
    report history row per rerun.

    The debugging agent's OpenRouter call is blocking (`requests.post`), so
    it's offloaded via `asyncio.to_thread` rather than stalling this
    coroutine (and the shared event loop) for its duration.

    Rate-limited to 5 reruns/minute per client IP -- each call is a real,
    billed OpenRouter LLM call, so an unbounded rate here is a cost/DoS
    vector even behind admin auth (a compromised or careless admin session
    could otherwise spam it).

    Args:
        request: FastAPI request object (required by the rate limiter).

    Raises:
        HTTPException 404: If no detection exists with that ID.
        HTTPException 502: If the debugging agent's OpenRouter call fails.
    """
    _audit("rerun_report", admin_id, detection_id)
    response.headers["Cache-Control"] = "no-store"
    manager = WatchdogManager()
    try:
        detection = manager.get_detection(detection_id)
    finally:
        manager.close()
    if detection is None:
        raise HTTPException(status_code=404, detail="Detection not found")

    result = await asyncio.to_thread(run_debug_agent_for_detection, detection_id)
    if "error" in result:
        raise HTTPException(status_code=502, detail=result["error"])
    return result


@monitoring_router.post("/detections/{detection_id}/report/download-audit")
async def log_remediation_download(
    detection_id: str, response: Response, admin_id: str = Depends(require_admin)
) -> dict:
    """Record that an admin downloaded the client-assembled remediation
    Markdown handoff file for one detection.

    The `.md` file itself (error record + report, formatted for pasting into
    a separate desktop coding-agent workflow) is assembled entirely
    client-side from `ErrorDetection`/`DetectionReport` data the admin page
    already has in state -- this endpoint serves no detection/report content
    and does no formatting. Its sole purpose is closing the one audit gap
    this would otherwise leave on this surface: admin_action="download" here
    is an admin exporting diagnostic/log content off-platform, and every
    other endpoint on this router logs its action via `_audit` (see module
    docstring, ASVS 5.0 16.3.2). The frontend calls this right before/at the
    point of triggering the local Blob download.

    Raises:
        HTTPException 404: If no detection exists with that ID.
    """
    response.headers["Cache-Control"] = "no-store"
    manager = WatchdogManager()
    try:
        detection = manager.get_detection(detection_id)
    finally:
        manager.close()
    if detection is None:
        raise HTTPException(status_code=404, detail="Detection not found")

    _audit("download_remediation_md", admin_id, detection_id)
    return {"logged": True}
