"""CloudWatch error-detection + context-assembly watchdog.

Step 3 of the cloudwatch-error-remediation workflow: a scheduled job
(registered in backend/interactions/scheduler.py) that polls the five
log groups CloudWatch already receives (see db.py's FellowScriptCloudWatchRole
comment / intake spec) via the read-only cloudwatch-mcp-server, scans pulled
events for error signal, assembles surrounding context for each hit, and
persists detection+context records to `error_detections` for the (later,
not-built-here) read-only admin endpoint to serve.

Explicitly does NOT execute, recommend as an action, or invoke anything
write-capable — that stays out of scope until the write-capable remediation
step is unblocked. This module only reads (via the MCP client) and writes to
this app's own Postgres tables.
"""
import asyncio
import functools
import json
import logging
import re
from datetime import datetime, timedelta, timezone
from typing import Any

from db import DBManager
from schemas.watchdog import ErrorDetection
from backend.monitoring.cloudwatch_mcp_client import (
    CloudWatchMCPClient,
    CloudWatchMCPError,
)
from backend.monitoring.debug_agent import run_debug_agent_for_detection

logger = logging.getLogger(__name__)

# The five log groups the CloudWatch agent ships today (four pre-existing +
# /fellowscript/app added in step 1 of this workflow).
LOG_GROUPS = [
    "/fellowscript/nginx/access",
    "/fellowscript/nginx/error",
    "/fellowscript/syslog",
    "/fellowscript/auth",
    "/fellowscript/app",
]

# Named per explicit user instruction (not a magic number). 90s balances
# near-real-time detection against MCP/CloudWatch Logs Insights call volume
# across 5 log groups every cycle.
WATCHDOG_POLL_INTERVAL_SECONDS = 90

# A log group with no cursor yet (first run, or a brand-new group) starts
# this far back rather than scanning its full retention window.
INITIAL_LOOKBACK_SECONDS = 900  # 15 minutes

# Never query, or advance a cursor, past (now - this). CloudWatch agent ->
# Logs delivery is not instantaneous; querying/advancing right up to "now"
# risks the cursor moving past events still in flight, which would silently
# skip them on the next run instead of catching them a cycle late.
INGESTION_LAG_BUFFER_SECONDS = 30

# +/- window of nearby log lines pulled as context for a detected error, and
# the max number of context lines/rows requested for it.
CONTEXT_WINDOW_SECONDS = 60
CONTEXT_LINE_LIMIT = 50

# Per-window row cap for the main poll query. If a window returns exactly
# this many rows, treat it as truncated: only advance the cursor to the
# last processed row's timestamp (not the full window end), so whatever
# fell past the cap is picked up next cycle instead of silently skipped.
QUERY_RESULT_LIMIT = 1000

# Application-level error signal heuristics, applied to each pulled
# @message. Based on the log-line shapes actually seen across the five
# groups (see intake spec addendum's uvicorn.log tail + FastAPI/uvicorn's
# own "ERROR:    ..." / Traceback output, and nginx's bracketed severity
# tags / combined-log-format status code). CloudWatch alarms/metric filters
# are explicitly out of scope (AWS-side, not in this repo) — this is the
# application-level scan that step 3 is scoped to build instead.
_ERROR_SIGNAL_PATTERNS: list[tuple[str, "re.Pattern[str]"]] = [
    ("traceback", re.compile(r"Traceback \(most recent call last\)")),
    ("critical", re.compile(r"\bCRITICAL\b")),
    ("error_level", re.compile(r"\bERROR\b")),
    ("nginx_severity_tag", re.compile(r"\[(error|crit|emerg|alert)\]")),
    ("http_5xx", re.compile(r'"\s(5\d{2})\s')),  # nginx access log: 5xx status after the quoted request
    ("errno", re.compile(r"\[Errno \d+\]")),  # OS-level failures, e.g. "address already in use"
]


def _match_error_signal(message: str) -> str | None:
    if not message:
        return None
    for name, pattern in _ERROR_SIGNAL_PATTERNS:
        if pattern.search(message):
            return name
    return None


_TIMESTAMP_FORMATS = (
    "%Y-%m-%d %H:%M:%S.%f",  # CloudWatch Logs Insights @timestamp shape
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S.%fZ",
    "%Y-%m-%dT%H:%M:%SZ",
)


def _parse_event_timestamp(event: dict[str, Any]) -> datetime | None:
    raw = event.get("@timestamp") or event.get("timestamp")
    if not raw:
        return None
    for fmt in _TIMESTAMP_FORMATS:
        try:
            return datetime.strptime(raw, fmt).replace(tzinfo=timezone.utc)
        except (ValueError, TypeError):
            continue
    logger.warning("Unrecognized CloudWatch event timestamp format: %r", raw)
    return None


class WatchdogManager(DBManager):
    """Cursor bookkeeping + detection persistence, plus the poll-cycle
    orchestration that ties them to CloudWatchMCPClient. The scheduler job
    (`_run_error_watchdog` in scheduler.py) is a one-line delegate to
    `run_cycle()`, matching the BackupManager/SubscriptionsManager pattern
    already used for the other scheduled jobs there.
    """

    def get_cursor(self, log_group_name: str) -> datetime | None:
        result = self.lookup("log_group_cursors", {"log_group_name": log_group_name})
        if not result:
            return None
        _, data = list(result.items())[0]
        last_seen = data["last_seen_time"]
        if last_seen.tzinfo is None:
            last_seen = last_seen.replace(tzinfo=timezone.utc)
        return last_seen

    def set_cursor(self, log_group_name: str, last_seen_time: datetime) -> None:
        self.insertion(
            "log_group_cursors",
            {
                "log_group_name": log_group_name,
                "last_seen_time": last_seen_time,
                "updated_at": datetime.now(timezone.utc),
            },
            conflict="(log_group_name) DO UPDATE SET "
            "last_seen_time = EXCLUDED.last_seen_time, "
            "updated_at = EXCLUDED.updated_at",
        )

    def save_detection(self, detection: ErrorDetection) -> None:
        self.insertion(
            "error_detections",
            {
                "_id": detection.id,
                "log_group_name": detection.log_group_name,
                "log_stream_name": detection.log_stream_name,
                "event_timestamp": detection.event_timestamp,
                "message": detection.message,
                "matched_signal": detection.matched_signal,
                "context": json.dumps(detection.context),
                "detected_at": detection.detected_at,
                "status": detection.status,
            },
        )

    # ── Read-only queries (step 4: served to the future admin page) ────────
    #
    # These never mutate anything -- no caller of list_detections/
    # get_detection can trigger, queue, or reference a remediation action.
    # `lookup`/`insertion` can't express the WHERE/ORDER BY/LIMIT combination
    # a filtered, paginated feed needs, so this drops to the raw cursor per
    # the "ordering / aggregation" case in the backend-architecture skill.

    @staticmethod
    def _build_detection_filters(
        log_group_name: str | None,
        start_time: datetime | None,
        end_time: datetime | None,
    ) -> tuple[str, list[Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if log_group_name:
            clauses.append("log_group_name = %s")
            params.append(log_group_name)
        if start_time:
            clauses.append("detected_at >= %s")
            params.append(start_time)
        if end_time:
            clauses.append("detected_at <= %s")
            params.append(end_time)
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        return where, params

    def list_detections(
        self,
        *,
        log_group_name: str | None = None,
        start_time: datetime | None = None,
        end_time: datetime | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> list[dict[str, Any]]:
        """Paginated, filterable summary rows, most recent first.

        Matches `idx_error_detections_detected_at` / `idx_error_detections_log_group`
        so the ORDER BY + optional log_group_name filter stay index-backed.
        Omits `context` (see ErrorDetectionSummary) -- use `get_detection`
        for the full record.
        """
        where, params = self._build_detection_filters(log_group_name, start_time, end_time)
        try:
            self.cur.execute(
                "SELECT _id AS id, log_group_name, log_stream_name, event_timestamp, "
                "message, matched_signal, detected_at, status "
                f"FROM error_detections{where} "
                "ORDER BY detected_at DESC LIMIT %s OFFSET %s",
                params + [limit, offset],
            )
            cols = [desc[0] for desc in self.cur.description]
            return [dict(zip(cols, row)) for row in self.cur.fetchall()]
        except Exception as e:
            logger.error("Error listing error_detections: %s", e)
            self.conn.rollback()
            return []

    def count_detections(
        self,
        *,
        log_group_name: str | None = None,
        start_time: datetime | None = None,
        end_time: datetime | None = None,
    ) -> int:
        """Total row count matching the same filters as `list_detections`,
        for the list response's `total` (independent of `limit`/`offset`)."""
        where, params = self._build_detection_filters(log_group_name, start_time, end_time)
        try:
            self.cur.execute(f"SELECT COUNT(*) FROM error_detections{where}", params)
            row = self.cur.fetchone()
            return int(row[0]) if row else 0
        except Exception as e:
            logger.error("Error counting error_detections: %s", e)
            self.conn.rollback()
            return 0

    def get_detection(self, detection_id: str) -> dict[str, Any] | None:
        """Full record (including `context`) for the admin detail drill-in."""
        try:
            self.cur.execute(
                "SELECT _id AS id, log_group_name, log_stream_name, event_timestamp, "
                "message, matched_signal, context, detected_at, status "
                "FROM error_detections WHERE _id = %s",
                (detection_id,),
            )
            row = self.cur.fetchone()
            if not row:
                return None
            cols = [desc[0] for desc in self.cur.description]
            return dict(zip(cols, row))
        except Exception as e:
            logger.error("Error fetching error_detections/%s: %s", detection_id, e)
            self.conn.rollback()
            return None

    async def run_cycle(self) -> dict[str, int]:
        """One full watchdog pass across every monitored log group.

        Groups are processed independently: one group's MCP/query failure is
        caught and logged, and simply leaves that group's cursor unmoved for
        a retry next interval — it never blocks or desyncs another group's
        cursor (the "no cross-log-group drift" requirement from the spec).
        """
        now = datetime.now(timezone.utc)
        window_end = now - timedelta(seconds=INGESTION_LAG_BUFFER_SECONDS)
        totals = {"events_scanned": 0, "detections": 0}

        async with CloudWatchMCPClient() as client:
            for log_group in LOG_GROUPS:
                try:
                    delta = await self._poll_one_group(client, log_group, window_end)
                except Exception as e:
                    logger.error("Watchdog poll failed for %s: %s", log_group, e)
                    continue
                totals["events_scanned"] += delta["events_scanned"]
                totals["detections"] += delta["detections"]
        return totals

    async def _poll_one_group(
        self, client: CloudWatchMCPClient, log_group: str, window_end: datetime
    ) -> dict[str, int]:
        cursor = self.get_cursor(log_group)
        window_start = cursor if cursor else window_end - timedelta(seconds=INITIAL_LOOKBACK_SECONDS)
        if window_start >= window_end:
            # Nothing new since the last run caught up to the lag buffer —
            # leave the cursor exactly where it is rather than advancing it,
            # so a burst of events that lands a moment later isn't skipped.
            return {"events_scanned": 0, "detections": 0}

        events = await client.query_log_events(
            log_group, window_start, window_end, limit=QUERY_RESULT_LIMIT
        )

        detections = 0
        latest_seen = window_start
        for event in events:
            ts = _parse_event_timestamp(event) or window_end
            if ts > latest_seen:
                latest_seen = ts

            message = event.get("@message") or event.get("message") or ""
            signal = _match_error_signal(message)
            if not signal:
                continue

            context = await self._assemble_context(client, log_group, ts)
            detection_record = ErrorDetection(
                log_group_name=log_group,
                log_stream_name=event.get("@logStream") or event.get("logStreamName"),
                event_timestamp=ts,
                message=message,
                matched_signal=signal,
                context=context,
            )
            self.save_detection(detection_record)
            detections += 1

            # Debugging-agent trigger (error-debug-agent-admin-page workflow,
            # step 3): one OpenRouter call per actual detected error, right
            # after it persists -- not per poll cycle. The agent's HTTP call
            # is blocking (requests.post), so it's offloaded to a thread via
            # run_in_executor rather than stalling this coroutine (and, on
            # this same event loop, the minute-interval notification/backup/
            # trial jobs) for the call's duration -- same pattern already
            # used for the sync DB work in scheduler.py's nightly-backup job.
            # A failure here never drops the already-persisted detection --
            # it just stays status='new' for a later on-demand re-run from
            # the admin page (POST /monitoring/detections/{id}/report).
            try:
                loop = asyncio.get_running_loop()
                await loop.run_in_executor(
                    None, functools.partial(run_debug_agent_for_detection, detection_record.id)
                )
            except Exception as e:
                logger.error(
                    "Debug agent failed for detection %s: %s", detection_record.id, e
                )

        new_cursor = latest_seen if len(events) >= QUERY_RESULT_LIMIT else window_end
        self.set_cursor(log_group, new_cursor)
        return {"events_scanned": len(events), "detections": detections}

    async def _assemble_context(
        self, client: CloudWatchMCPClient, log_group: str, event_ts: datetime
    ) -> dict[str, Any]:
        context_start = event_ts - timedelta(seconds=CONTEXT_WINDOW_SECONDS)
        context_end = event_ts + timedelta(seconds=CONTEXT_WINDOW_SECONDS)

        nearby: list[dict[str, Any]] = []
        try:
            nearby = await client.query_log_events(
                log_group, context_start, context_end, limit=CONTEXT_LINE_LIMIT
            )
        except CloudWatchMCPError as e:
            logger.warning("Context query failed for %s around %s: %s", log_group, event_ts, e)

        analysis = await client.analyze_log_group(log_group, context_start, context_end)

        return {
            "nearby_events": nearby,
            "analysis": analysis,
            "window": {
                "start": context_start.isoformat(),
                "end": context_end.isoformat(),
            },
        }
