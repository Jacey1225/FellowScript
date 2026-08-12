"""Thin async client for the awslabs `cloudwatch-mcp-server` (read-only).

All CloudWatch access for the error watchdog goes through this already-
registered, read-only MCP server rather than boto3 directly, per explicit
user instruction (intake spec) — the MCP server is the sole source of truth
for log data and its own log-analyzer context tools.

*** INTEGRATION STATUS — READ BEFORE RELYING ON THIS IN PRODUCTION ***
The `cloudwatch-mcp-server` was not registered/callable in the session that
wrote this file (only `codegraph` is registered in this repo/session's MCP
config), so none of the tool calls below have been exercised end-to-end
against a live server. This is implemented against the server's documented
tool interface (awslabs/mcp `cloudwatch-mcp-server` package: log tools
`execute_log_insights_query` / `get_logs_insight_query_results` /
`analyze_log_group`), reasoning from CloudWatch Logs Insights' own
start-query/poll-for-results API shape (which those tools wrap). Verify tool
names and response shapes against the installed server version before
depending on this, and watch the first few scheduler runs' logs closely
after deploy — `_call_tool` logs the raw response shape on unexpected input
specifically to make that first-deploy verification easy.
"""
import asyncio
import json
import logging
import os
import shlex
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger(__name__)

# How the app spawns the MCP server subprocess. Defaults to the standard
# `uvx`-based invocation documented for awslabs.cloudwatch-mcp-server;
# override via env if the deploy target installs/pins it differently.
CLOUDWATCH_MCP_COMMAND = os.getenv(
    "CLOUDWATCH_MCP_COMMAND", "uvx awslabs.cloudwatch-mcp-server@latest"
)

# CloudWatch Logs Insights queries are asynchronous server-side (start, then
# poll for completion) — poll on this cadence up to this many attempts
# before giving up on one query.
_QUERY_POLL_INTERVAL_SECONDS = 1.0
_QUERY_POLL_MAX_ATTEMPTS = 15


class CloudWatchMCPError(Exception):
    """Raised when the MCP server call fails or returns an unexpected shape."""


def _iso(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class CloudWatchMCPClient:
    """Async context manager: spawns the MCP server subprocess once and
    reuses the session for every call made inside the `async with` block, so
    one watchdog poll cycle (many log groups, plus a context query per
    detection) pays the subprocess-startup cost once rather than per call.

        async with CloudWatchMCPClient() as client:
            events = await client.query_log_events(log_group, start, end)
            analysis = await client.analyze_log_group(log_group, start, end)

    A fresh subprocess per cycle (rather than one kept alive for the whole
    scheduler lifetime) is deliberate for v1 — simpler to reason about at a
    60-120s poll interval and avoids a long-lived child process silently
    going stale under systemd. Revisit if subprocess-spawn overhead becomes
    material.
    """

    def __init__(self, command: str | None = None) -> None:
        self._command = command or CLOUDWATCH_MCP_COMMAND
        self._session = None
        self._stdio_ctx = None

    async def __aenter__(self) -> "CloudWatchMCPClient":
        try:
            from mcp import ClientSession
            from mcp.client.stdio import StdioServerParameters, stdio_client
        except ImportError as e:
            raise CloudWatchMCPError(
                "The 'mcp' package is required to talk to cloudwatch-mcp-server "
                "(pip install mcp) — see requirements.txt."
            ) from e

        parts = shlex.split(self._command)
        params = StdioServerParameters(command=parts[0], args=parts[1:], env=dict(os.environ))
        self._stdio_ctx = stdio_client(params)
        read, write = await self._stdio_ctx.__aenter__()
        self._session = ClientSession(read, write)
        await self._session.__aenter__()
        await self._session.initialize()
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        if self._session is not None:
            await self._session.__aexit__(exc_type, exc, tb)
        if self._stdio_ctx is not None:
            await self._stdio_ctx.__aexit__(exc_type, exc, tb)

    async def _call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if self._session is None:
            raise CloudWatchMCPError("CloudWatchMCPClient used outside its `async with` block")
        result = await self._session.call_tool(name, arguments)
        if getattr(result, "isError", False):
            raise CloudWatchMCPError(f"{name} returned an error: {result.content}")
        # MCP tool results are a list of content blocks; the cloudwatch
        # server is documented to return its payload as a single JSON text
        # block, but tolerate a non-JSON block rather than crash the cycle.
        for block in result.content:
            text = getattr(block, "text", None)
            if not text:
                continue
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                logger.warning("%s returned non-JSON content: %r", name, text[:200])
                return {"raw": text}
        return {}

    async def query_log_events(
        self,
        log_group_name: str,
        start_time: datetime,
        end_time: datetime,
        query_string: str = "fields @timestamp, @message, @logStream",
        limit: int = 10000,
    ) -> list[dict[str, Any]]:
        """Run a Logs Insights query over one log group and return its rows,
        oldest first. Used both for the main poll window and for pulling
        nearby-line context around a detection.
        """
        started = await self._call_tool(
            "execute_log_insights_query",
            {
                "log_group_names": [log_group_name],
                "start_time": _iso(start_time),
                "end_time": _iso(end_time),
                "query_string": f"{query_string} | sort @timestamp asc | limit {limit}",
            },
        )
        query_id = started.get("queryId") or started.get("query_id")
        # A fast/small query may come back with inline results instead of a
        # queryId to poll — handle both documented shapes defensively.
        if not query_id:
            return started.get("results") or []

        for _ in range(_QUERY_POLL_MAX_ATTEMPTS):
            polled = await self._call_tool(
                "get_logs_insight_query_results", {"query_id": query_id}
            )
            status = str(polled.get("status", "")).lower()
            if status == "complete":
                return polled.get("results") or []
            if status in ("failed", "cancelled", "timeout"):
                raise CloudWatchMCPError(
                    f"Logs Insights query {query_id} on {log_group_name} ended with status {status}"
                )
            await asyncio.sleep(_QUERY_POLL_INTERVAL_SECONDS)
        raise CloudWatchMCPError(
            f"Logs Insights query {query_id} on {log_group_name} did not complete in time"
        )

    async def analyze_log_group(
        self, log_group_name: str, start_time: datetime, end_time: datetime
    ) -> dict[str, Any]:
        """Pull pattern/anomaly context for a log group over a window via the
        server's log-analyzer tool. Best-effort and never raises — context
        assembly must not fail (or block persisting) a real detection just
        because this supplementary call errors.
        """
        try:
            return await self._call_tool(
                "analyze_log_group",
                {
                    "log_group_name": log_group_name,
                    "start_time": _iso(start_time),
                    "end_time": _iso(end_time),
                },
            )
        except CloudWatchMCPError as e:
            logger.warning("analyze_log_group context call failed for %s: %s", log_group_name, e)
            return {}
