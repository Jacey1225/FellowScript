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

# 2026-08-14 incident structural fix -- self-exclusion.
#
# /fellowscript/app (one of the five scanned log groups) is the same group
# this watchdog's own logging, the debug agent's, and the scheduler job's
# `[ERROR]`/failure lines land in. Without exclusion, any recurring internal
# failure here (not just the two named bugs) logs an [ERROR] line every
# cycle, which the broad `error_level` pattern above then re-detects as a
# *new* error next cycle -- triggering another (also-failing) round of work
# and another [ERROR] line, indefinitely. That's the exact self-amplifying
# feedback loop that produced the production OOM incident (see
# scheduler.py's cloudwatch_watchdog disable comment).
#
# Matched against the structured `[%(name)s]` logger-name field main.py's
# `logging.basicConfig` format emits (e.g. "... [backend.monitoring.watchdog]
# ERROR - ...") -- deliberately NOT against the free-text message. Matching
# on message text is what created the original overly-broad \bERROR\b
# problem in the first place, and would risk excluding real application
# errors that happen to share vocabulary with a watchdog/debug-agent log
# line. `backend.interactions.scheduler.watchdog` is a *child* logger used
# only by scheduler.py's `_run_error_watchdog` (see that module) -- the
# scheduler module's other jobs (notifications, backups, trial reconcile)
# log under the plain `backend.interactions.scheduler` name and are
# intentionally NOT excluded here, so a real failure in one of those still
# gets detected normally.
#
# SECURITY: anchored to the start of the message and requires the excluded
# name to be inside the *first* bracket pair in the line, not searched for
# anywhere in free text. `%(message)s` -- the attacker/user-influenceable
# part of a formatted log line -- always comes after the real `[%(name)s)]`
# field, and callers across this codebase routinely interpolate exception
# text (`logger.error("...: %s", e)`) whose content can echo back
# user-supplied input (e.g. a malformed request body embedded in a
# ValueError/JSONDecodeError message). An unanchored substring search would
# let anyone who can influence logged text -- by triggering an error whose
# message happens to contain the literal string "[backend.monitoring.
# watchdog]" -- get an unrelated, genuine application error line excluded
# from detection (a log-forging / monitoring-bypass vector). Anchoring to
# "first bracket at the start of the line" is immune to this: an attacker's
# message content can never appear before the real name field the logging
# formatter itself always emits first, so a forged bracket embedded deeper
# in the line is never considered.
_SELF_LOGGER_NAMES = (
    "backend.monitoring.watchdog",
    "backend.monitoring.debug_agent",
    "backend.interactions.scheduler.watchdog",
)
_SELF_EXCLUSION_RE = re.compile(
    r"^[^\[\n]*\[(" + "|".join(re.escape(name) for name in _SELF_LOGGER_NAMES) + r")\]"
)

# 2026-08-14 incident structural fix -- per-cycle circuit breaker.
#
# Defense-in-depth alongside the self-exclusion filter above, per explicit
# user instruction: this is the second time an unbounded-growth mechanism
# has surfaced in this subsystem, so the fix must not be scoped only to the
# two named bugs. A hard cap here bounds runaway growth from *any* future
# recurring internal failure -- or even a genuine burst of real application
# errors -- regardless of whether the self-exclusion filter above happens to
# cover that particular case. See `WatchdogManager.run_cycle` /
# `_poll_one_group` for where these are enforced.
MAX_DETECTIONS_PER_CYCLE = 25
MAX_DEBUG_AGENT_CALLS_PER_CYCLE = 25


def _is_self_originated(message: str) -> bool:
    """True if `message` is a log line produced by the watchdog subsystem's
    own logging (identified by the structured `[logger.name]` field --
    see `_SELF_LOGGER_NAMES` above), rather than application/request content
    a real user or upstream dependency caused."""
    return bool(_SELF_EXCLUSION_RE.search(message))


def _match_error_signal(message: str) -> str | None:
    if not message or _is_self_originated(message):
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

    def __init__(self) -> None:
        super().__init__()
        # Per-cycle circuit-breaker counters (see MAX_DETECTIONS_PER_CYCLE /
        # MAX_DEBUG_AGENT_CALLS_PER_CYCLE above) -- reset at the top of every
        # `run_cycle()` call, initialized here too since a fresh
        # WatchdogManager is what scheduler.py's `_run_error_watchdog`
        # constructs per cycle.
        self._cycle_detection_count = 0
        self._cycle_debug_agent_count = 0
        self._cap_tripped = False

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

    # Status a detection is flagged with when it's known incident noise
    # (see db.py's INCIDENT_NOISE_WINDOW_* backfill) rather than a real,
    # actionable error -- excluded from the default triage feed below but
    # never deleted, so the 2026-08-14 incident stays inspectable for
    # postmortem purposes (get_detection / include_noise=True both still
    # return it in full).
    STATUS_NOISE = "noise"

    @staticmethod
    def _build_detection_filters(
        log_group_name: str | None,
        start_time: datetime | None,
        end_time: datetime | None,
        include_noise: bool,
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
        if not include_noise:
            clauses.append("status != %s")
            params.append(WatchdogManager.STATUS_NOISE)
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
        include_noise: bool = False,
    ) -> list[dict[str, Any]]:
        """Paginated, filterable summary rows, most recent first.

        Matches `idx_error_detections_detected_at` / `idx_error_detections_log_group`
        so the ORDER BY + optional log_group_name filter stay index-backed.
        Omits `context` (see ErrorDetectionSummary) -- use `get_detection`
        for the full record.

        `include_noise` defaults to False -- rows flagged `status='noise'`
        (the 2026-08-14 incident-window backfill, see db.py) are excluded
        from the default triage feed so they don't clutter it, but pass
        `include_noise=True` to see them for postmortem review; they are
        never deleted.
        """
        where, params = self._build_detection_filters(
            log_group_name, start_time, end_time, include_noise
        )
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
        include_noise: bool = False,
    ) -> int:
        """Total row count matching the same filters as `list_detections`,
        for the list response's `total` (independent of `limit`/`offset`)."""
        where, params = self._build_detection_filters(
            log_group_name, start_time, end_time, include_noise
        )
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

        Also enforces the per-cycle circuit breaker (MAX_DETECTIONS_PER_CYCLE
        / MAX_DEBUG_AGENT_CALLS_PER_CYCLE) across *all* groups in this cycle
        combined, not per-group -- a spike concentrated in one log group
        should trip the breaker the same as one spread across several.
        """
        # Reset every cycle rather than relying solely on __init__, in case
        # a caller (e.g. a test) reuses one WatchdogManager across multiple
        # run_cycle() calls -- the cap must never carry over between cycles.
        self._cycle_detection_count = 0
        self._cycle_debug_agent_count = 0
        self._cap_tripped = False

        now = datetime.now(timezone.utc)
        window_end = now - timedelta(seconds=INGESTION_LAG_BUFFER_SECONDS)
        totals = {"events_scanned": 0, "detections": 0}

        async with CloudWatchMCPClient() as client:
            for log_group in LOG_GROUPS:
                if self._cap_tripped:
                    # Breaker already tripped earlier this cycle -- stop
                    # opening new MCP queries for the remaining groups too.
                    # Every untouched group's cursor is left exactly where
                    # it was, so nothing is lost, only deferred to the next
                    # cycle.
                    logger.warning(
                        "CloudWatch watchdog: per-cycle cap already tripped, "
                        "skipping remaining log group(s) starting with %s this cycle",
                        log_group,
                    )
                    break
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

            message = event.get("@message") or event.get("message") or ""
            signal = _match_error_signal(message)

            if signal and self._cycle_detection_count >= MAX_DETECTIONS_PER_CYCLE:
                # Circuit breaker: stop here rather than advancing
                # latest_seen/the cursor past this event -- it (and
                # anything after it in this window) is retried next cycle
                # instead of being silently dropped. Non-matching events
                # earlier in this same loop already advanced latest_seen
                # normally; only a genuine new detection beyond the cap
                # trips this.
                self._cap_tripped = True
                logger.warning(
                    "CloudWatch watchdog: per-cycle detection cap (%d) reached "
                    "in %s -- stopping early as a circuit breaker; remainder of "
                    "this window retried next cycle",
                    MAX_DETECTIONS_PER_CYCLE, log_group,
                )
                break

            if ts > latest_seen:
                latest_seen = ts

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
            self._cycle_detection_count += 1

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
            #
            # Also circuit-broken independently of the detection cap above:
            # a detection can still be recorded even once debug-agent calls
            # for this cycle are capped, it just doesn't get an automatic
            # report -- a later on-demand rerun covers it.
            if self._cycle_debug_agent_count < MAX_DEBUG_AGENT_CALLS_PER_CYCLE:
                self._cycle_debug_agent_count += 1
                try:
                    loop = asyncio.get_running_loop()
                    await loop.run_in_executor(
                        None, functools.partial(run_debug_agent_for_detection, detection_record.id)
                    )
                except Exception as e:
                    logger.error(
                        "Debug agent failed for detection %s: %s", detection_record.id, e
                    )
            else:
                logger.warning(
                    "CloudWatch watchdog: per-cycle debug-agent cap (%d) reached -- "
                    "skipping automatic report generation for detection %s; it "
                    "stays status='new' for a later on-demand rerun",
                    MAX_DEBUG_AGENT_CALLS_PER_CYCLE, detection_record.id,
                )

        new_cursor = latest_seen if (len(events) >= QUERY_RESULT_LIMIT or self._cap_tripped) else window_end
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
