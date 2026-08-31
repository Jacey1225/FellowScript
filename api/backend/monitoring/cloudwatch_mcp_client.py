"""Thin async client for the awslabs `cloudwatch-mcp-server` (read-only).

All CloudWatch access for the error watchdog goes through this already-
registered, read-only MCP server rather than boto3 directly, per explicit
user instruction (intake spec) — the MCP server is the sole source of truth
for log data and its own log-analyzer context tools. (The one exception is
`_resolve_account_id` below, which uses `boto3` STS purely to resolve the
account id needed to construct a log group ARN — not to read CloudWatch
data itself, so it doesn't cross that boundary.)

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

*** 2026-08-14 INCIDENT FOLLOW-UP — log_group_arn ***
Production's `analyze_log_group` call was failing on every single detection
(commit a8a22ecc) because this client only ever sent `log_group_name`, and
the tool requires `log_group_arn` too. `analyze_log_group` below now
constructs that ARN client-side from `CLOUDWATCH_REGION` + the caller's AWS
account id (resolved once via `sts:GetCallerIdentity`, which every IAM
principal can call by default — no new IAM grant needed for *that* part).
What is NOT verified: whether `FellowScriptCloudWatchRole` (the read-only
role the MCP server's log-reading calls run under, see the intake spec) also
needs a `logs:DescribeLogGroups`-equivalent grant for `analyze_log_group`
itself to succeed once it receives a well-formed ARN, and whether
`log_group_arn` is even the tool's actual required field name/shape — both
are flagged here explicitly per the workflow's external-dependencies note,
not applied in this repo, and must be confirmed against the live server on
first deploy (see `_call_tool`'s raw-response logging above).
"""
import asyncio
import json
import logging
import os
import shlex
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger(__name__)

# Region the CloudWatch log groups (and thus their ARNs) live in — matches
# the hardcoded "us-east-1" used elsewhere for AWS resources in this repo
# (routes/messaging.py's Chime client, email/ses_client.py's default
# SES_REGION); made overridable via env the same way SES_REGION is, rather
# than hardcoded here too, since this specific value is load-bearing for
# every analyze_log_group call rather than a fallback default.
CLOUDWATCH_REGION = os.getenv("CLOUDWATCH_REGION", "us-east-1")

# Resolved lazily via STS on first use and cached for the process lifetime —
# an AWS account id never changes, so there's no reason to pay a network
# round trip for it on every analyze_log_group call (one per detection).
_account_id_cache: str | None = None

# How the app spawns the MCP server subprocess. Phase 1 of
# docs/architecture/docker-plan.md's Decision 2 resolution: pip-install and
# pin `awslabs.cloudwatch-mcp-server` at build time (see requirements.txt)
# rather than fetching it at runtime via `uvx awslabs.cloudwatch-mcp-server
# @latest` — reproducible (no `@latest` drift), no outbound-PyPI dependency
# at process startup or on every uvx cold-start. The default below is that
# pinned package's own console-script entry point (confirmed from the built
# wheel's entry_points.txt: `awslabs.cloudwatch-mcp-server =
# awslabs.cloudwatch_mcp_server.server:main`), resolvable via $PATH once
# requirements.txt is installed — no args needed, unlike the old `uvx ...`
# form. Override via env if a deploy target ever installs/pins it
# differently.
CLOUDWATCH_MCP_COMMAND = os.getenv(
    "CLOUDWATCH_MCP_COMMAND", "awslabs.cloudwatch-mcp-server"
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


def _log_group_arn(log_group_name: str, account_id: str) -> str:
    """Standard CloudWatch Logs ARN shape for a log group. The trailing
    `:*` matches the ARN CloudWatch itself returns for a log group (it
    includes a wildcard suffix) — included so this matches what the tool
    would receive from a real DescribeLogGroups call, not a guess."""
    return f"arn:aws:logs:{CLOUDWATCH_REGION}:{account_id}:log-group:{log_group_name}:*"


async def _resolve_account_id() -> str:
    """Resolve (and cache) the AWS account id via STS, off the event loop
    since boto3 is synchronous. `sts:GetCallerIdentity` requires no IAM
    grant beyond being *some* authenticated AWS principal — every role
    (including FellowScriptCloudWatchRole as-is) can already call it, so
    this specifically does not require an IAM policy change."""
    global _account_id_cache
    if _account_id_cache is not None:
        return _account_id_cache

    def _get_identity() -> str:
        import boto3

        return boto3.client("sts", region_name=CLOUDWATCH_REGION).get_caller_identity()["Account"]

    loop = asyncio.get_running_loop()
    account_id = await loop.run_in_executor(None, _get_identity)
    _account_id_cache = account_id
    return account_id


# Env vars the spawned cloudwatch-mcp-server subprocess actually needs to
# resolve AWS credentials/region and to find its own interpreter on $PATH.
# Forwarding the *entire* parent environment (the previous behavior) would
# also hand it every other secret this process holds (DB_PASSWORD,
# STRIPE_SECRET_KEY, OPENROUTER_API_KEY, SES_*, ...) -- a bug or supply-chain
# issue in this third-party package would then be able to exfiltrate all of
# them, not just AWS access. HOME is included because boto3's credential
# chain reads `~/.aws/credentials`/`~/.aws/config` when no explicit
# AWS_ACCESS_KEY_ID is set.
_SUBPROCESS_ENV_ALLOWLIST = (
    "PATH", "HOME",
    "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
    "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_PROFILE",
    "CLOUDWATCH_REGION",
)


def _subprocess_env() -> dict[str, str]:
    """Minimal environment for the cloudwatch-mcp-server subprocess -- only
    the AWS-related vars (and PATH/HOME) it actually needs, not the full
    parent environment."""
    return {k: v for k, v in os.environ.items() if k in _SUBPROCESS_ENV_ALLOWLIST}


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
        params = StdioServerParameters(command=parts[0], args=parts[1:], env=_subprocess_env())
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

        2026-08-14 incident fix: this now also resolves and sends
        `log_group_arn` (see module docstring) — previously omitted, which
        made this call fail on every single detection in production.
        """
        try:
            account_id = await _resolve_account_id()
        except Exception as e:
            logger.warning(
                "analyze_log_group: could not resolve AWS account id for %s (%s) — "
                "skipping context call this time. A persistent failure here means "
                "this environment has no usable AWS credentials at all (distinct "
                "from a log-group-specific permission problem, since "
                "sts:GetCallerIdentity needs no grant beyond being an authenticated "
                "principal).",
                log_group_name, e,
            )
            return {}

        log_group_arn = _log_group_arn(log_group_name, account_id)
        try:
            return await self._call_tool(
                "analyze_log_group",
                {
                    "log_group_arn": log_group_arn,
                    "log_group_name": log_group_name,
                    "start_time": _iso(start_time),
                    "end_time": _iso(end_time),
                },
            )
        except CloudWatchMCPError as e:
            logger.warning(
                "analyze_log_group context call failed for %s (arn=%s): %s — if this "
                "is an access-denied/permission error rather than a bad-argument "
                "error, FellowScriptCloudWatchRole likely needs an additional "
                "read-only logs:* grant scoped to this log group ARN (an AWS-side "
                "IAM change this repo cannot apply — flag it out-of-band). If it's "
                "an argument/schema error, `log_group_arn` may not be this tool's "
                "actual expected field name/shape — verify against the live "
                "cloudwatch-mcp-server (see module docstring); this client-side ARN "
                "construction has not been exercised end-to-end yet.",
                log_group_name, log_group_arn, e,
            )
            return {}
