"""Admin Activity Monitoring panel (task 20260918-admin-activity-monitoring,
extended by task 20260919-activity-monitoring-interactive-charts).

A new, separate panel/feature from the existing CloudWatch error-detection
console (`routes/monitoring.py`) -- out of scope to touch that file or its
router, per the intake spec's explicit scope boundary. This module owns its
own `visits` table, its own manager (`backend.interactions.
activity_monitoring.ActivityMonitoringManager`), and its own router, wired
into `main.py` independently.

Three trust boundaries share this one file:

- `POST /activity-monitoring/visits` -- the *one* public, anonymous write
  surface in this feature (no `require_admin`/`get_current_user` at all --
  it must work for a logged-out visitor). Insert-only, rate-limited,
  strictly validated (`schemas.activity_monitoring.VisitCreate`), and never
  reflects any stored/aggregate data back to the caller (204 No Content).
- `GET /activity-monitoring/plots/*` -- admin-only (`require_admin`: 401
  unauthenticated, 403 non-admin), read-only, `Cache-Control: no-store`
  aggregation endpoints that render a matplotlib PNG per call and return the
  raw image bytes directly (`Content-Type: image/png`). This was the prior
  task's deliberate image-only delivery decision (opaque pixels, not a JSON
  payload carrying the aggregate per-user activity numbers themselves,
  PII-adjacent). Kept as-is here -- retiring them is a frontend/design-time
  call per architecture step 2's own note, not this step's to make
  unilaterally, and nothing else in this task depends on removing them.
- `GET /activity-monitoring/data/*` -- admin-only, same `require_admin` +
  `Cache-Control: no-store` + audit-log posture as the PNG endpoints above,
  new for task 20260919 step 2: JSON versions of the exact same aggregate
  series the PNGs already plot, for the client-side interactive charts step
  4 builds. This reopens the prior task's image-only boundary decision --
  done here only because task 20260919's security step 1 threat-modeled it
  and `clarification-response.md` records the user's explicit approval
  (Security Posture Q16 hard stop on security-boundary changes). The JSON
  payload is scoped to carry *no more* information than the PNG it
  parallels -- see `schemas.activity_monitoring`'s response models and
  `ActivityMonitoringManager`'s existing aggregate queries, which both
  delivery mechanisms call into unchanged.

Audit logging: every plot/data view logs one `admin_action` line via
`_audit` below, extending the exact `admin_audit` logger
`routes/monitoring.py` already established (security step 1: reuse the
existing mechanism, don't invent a new one) -- `admin_id` always comes from
`require_admin`'s DB-verified return value, never a client-supplied field.
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, Request, Response

from backend.auth.dependencies import require_admin
from backend.interactions.activity_monitoring import (
    ActivityMonitoringManager,
    DEFAULT_WINDOW_DAYS,
)
from backend.interactions.activity_plots import render_line_chart, render_visits_chart
from backend.rate_limiting import limiter
from schemas.activity_monitoring import (
    MetricPoint,
    MetricSeriesResponse,
    VisitCreate,
    VisitPoint,
    VisitsSeriesResponse,
)

logger = logging.getLogger(__name__)
# Same logger name (not a new one) as routes/monitoring.py's own
# `admin_audit` -- see module docstring.
audit_logger = logging.getLogger("admin_audit")

activity_monitoring_router = APIRouter(prefix="/activity-monitoring")

# Human-readable title/axis labels for each `ActivityMonitoringManager.
# PER_USER_METRICS` key -- kept here (route/presentation layer) rather than
# on the manager, which stays presentation-agnostic.
_METRIC_LABELS = {
    "notes": "Average notes per user",
    "highlights": "Average highlights per user",
    "logins": "Average logins per user",
    "messages": "Average messages per user",
}


def _audit(action: str, admin_id: str, metric: str | None = None) -> None:
    """One structured admin-audit-trail line per admin view of this panel."""
    audit_logger.info(
        "admin_action action=%s admin_id=%s metric=%s", action, admin_id, metric
    )


@activity_monitoring_router.post("/visits", status_code=204)
@limiter.limit("30/minute")
async def log_visit(request: Request, visit: VisitCreate) -> None:
    """Public, anonymous visit-logging beacon.

    Called by the web frontend on page navigation (see the step 4 frontend
    instrumentation) with a client-generated, localStorage-persisted
    UUIDv4 `device_id` and the visited `path`. No auth is required or
    possible here -- a logged-out visitor's pageviews are exactly what this
    is meant to count -- so this is deliberately the one write endpoint in
    this feature outside `require_admin`/`get_current_user`.

    Rate-limited to 30/minute per client IP: higher than the 10/minute
    `routes/monitoring.py::report_client_error` beacon since ordinary
    navigation fires this far more often, but still bounded against a
    caller flooding the table to pollute the aggregate metrics (security
    step 1's threat-modeling concern for this new anonymous surface).

    Never reflects stored or aggregate data back to the caller (204, no
    body) -- an anonymous caller learns nothing about visit volume from
    this endpoint.

    Args:
        request: FastAPI request object (required by the rate limiter).
        visit: device_id (UUIDv4) + path, both validated/length-capped by
            `VisitCreate` before this handler ever sees them.

    Returns:
        None (204).
    """
    manager = ActivityMonitoringManager()
    try:
        if not manager.record_visit(visit.device_id, visit.path):
            # Logged (via DBManager.insertion's own DB_WRITE_FAILURE line)
            # but not surfaced to the caller -- same fail-soft posture as
            # any other best-effort telemetry beacon in this codebase (e.g.
            # attachments.delete_object). A dropped visit-count row is not
            # worth turning into a visible error for an anonymous visitor.
            logger.warning("Failed to record visit for device_id=%s", visit.device_id[:8])
    finally:
        manager.close()


@activity_monitoring_router.get("/plots/visits")
async def get_visits_plot(response: Response, admin_id: str = Depends(require_admin)) -> Response:
    """Render the raw-visits-vs-unique-device-visitors PNG for the trailing
    `DEFAULT_WINDOW_DAYS`-day window.

    Registered before `GET /plots/{metric}` (literal segment before the
    wildcard capture, per this codebase's route-ordering convention) so
    `/plots/visits` never falls through to the generic per-user-metric
    handler and 404s on an unrecognized "visits" metric.
    """
    _audit("view_activity_monitoring", admin_id, "visits")
    response.headers["Cache-Control"] = "no-store"
    manager = ActivityMonitoringManager()
    try:
        raw, unique = manager.daily_visits(DEFAULT_WINDOW_DAYS)
    finally:
        manager.close()
    png = render_visits_chart(raw, unique, title="Website visits (raw vs. unique devices)")
    return Response(content=png, media_type="image/png", headers={"Cache-Control": "no-store"})


@activity_monitoring_router.get("/plots/{metric}")
async def get_metric_plot(
    metric: str, response: Response, admin_id: str = Depends(require_admin)
) -> Response:
    """Render one average-per-user metric's PNG (notes / highlights / logins
    / messages) for the trailing `DEFAULT_WINDOW_DAYS`-day window.

    Args:
        metric: One of `ActivityMonitoringManager.PER_USER_METRICS`'s keys.

    Raises:
        HTTPException 404: If `metric` isn't a recognized metric name --
            this is the only user-controlled string that reaches the
            manager's query, and it's checked against the fixed, server-
            defined mapping before that call, never interpolated from the
            path directly into SQL (see that mapping's own comment).
    """
    if metric not in ActivityMonitoringManager.PER_USER_METRICS:
        raise HTTPException(status_code=404, detail="Unknown activity-monitoring metric")
    _audit("view_activity_monitoring", admin_id, metric)
    response.headers["Cache-Control"] = "no-store"
    manager = ActivityMonitoringManager()
    try:
        series = manager.daily_average_per_user(metric, DEFAULT_WINDOW_DAYS)
    finally:
        manager.close()
    png = render_line_chart(series, title=_METRIC_LABELS[metric], ylabel="Avg per user")
    return Response(content=png, media_type="image/png", headers={"Cache-Control": "no-store"})


@activity_monitoring_router.get("/data/visits")
async def get_visits_data(
    response: Response, admin_id: str = Depends(require_admin)
) -> VisitsSeriesResponse:
    """JSON version of `get_visits_plot`'s data, for the client-side
    interactive chart (task 20260919, step 2) -- same aggregate query, same
    fixed `DEFAULT_WINDOW_DAYS` window, same `require_admin`/audit-log/
    `Cache-Control: no-store` posture as the PNG endpoint it parallels.

    Registered before `GET /data/{metric}` (literal segment before the
    wildcard capture) for the same route-ordering reason as
    `/plots/visits` vs. `/plots/{metric}` above.
    """
    _audit("view_activity_monitoring", admin_id, "visits")
    response.headers["Cache-Control"] = "no-store"
    manager = ActivityMonitoringManager()
    try:
        raw, unique = manager.daily_visits(DEFAULT_WINDOW_DAYS)
    finally:
        manager.close()
    points = [
        VisitPoint(day=raw_day, raw=raw_count, unique=unique_count)
        for (raw_day, raw_count), (_, unique_count) in zip(raw, unique)
    ]
    return VisitsSeriesResponse(
        title="Website visits (raw vs. unique devices)", series=points
    )


@activity_monitoring_router.get("/data/{metric}")
async def get_metric_data(
    metric: str, response: Response, admin_id: str = Depends(require_admin)
) -> MetricSeriesResponse:
    """JSON version of `get_metric_plot`'s data, for the client-side
    interactive chart (task 20260919, step 2) -- same aggregate query, same
    fixed `DEFAULT_WINDOW_DAYS` window, same `require_admin`/audit-log/
    `Cache-Control: no-store` posture, and the same `metric`-name validation
    against the fixed `PER_USER_METRICS` mapping (never request-controlled
    SQL) as the PNG endpoint it parallels.

    Raises:
        HTTPException 404: If `metric` isn't a recognized metric name.
    """
    if metric not in ActivityMonitoringManager.PER_USER_METRICS:
        raise HTTPException(status_code=404, detail="Unknown activity-monitoring metric")
    _audit("view_activity_monitoring", admin_id, metric)
    response.headers["Cache-Control"] = "no-store"
    manager = ActivityMonitoringManager()
    try:
        series = manager.daily_average_per_user(metric, DEFAULT_WINDOW_DAYS)
    finally:
        manager.close()
    points = [MetricPoint(day=day, value=value) for day, value in series]
    return MetricSeriesResponse(
        metric=metric,
        title=_METRIC_LABELS[metric],
        ylabel="Avg per user",
        series=points,
    )
