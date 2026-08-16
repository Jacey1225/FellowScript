"""
Proves the fix for the first named root-cause bug in the 2026-08-14 incident
(commit a8a22ecc): `cloudwatch_mcp_client.py::analyze_log_group` now sends
the `log_group_arn` field that production was missing on every single call.

The real `cloudwatch-mcp-server` subprocess and real AWS credentials are not
available in this environment (this module's own header docstring flags the
integration as never having been exercised end-to-end) -- so this test
verifies the two things fully within this repo's control: (1) the ARN is
constructed in the documented CloudWatch Logs ARN shape from
`CLOUDWATCH_REGION` + the resolved account id, and (2) `_call_tool` actually
receives `log_group_arn` alongside `log_group_name` -- by stubbing
`_resolve_account_id` and `_call_tool` (the two boundary points to
boto3/the MCP subprocess) rather than mocking `analyze_log_group` itself.

Covers:
  - `_log_group_arn` produces the standard
    `arn:aws:logs:<region>:<account>:log-group:<name>:*` shape.
  - `analyze_log_group` calls `_call_tool("analyze_log_group", ...)` with
    both `log_group_arn` (constructed) and `log_group_name` present --
    the exact field production was missing.
  - Account id resolution failure (no usable AWS credentials at all) is
    handled gracefully -- `analyze_log_group` returns `{}` rather than
    raising, and never calls `_call_tool` at all (nothing to send an ARN
    for), matching "context assembly must not fail a real detection".
  - A `CloudWatchMCPError` from the tool call itself (e.g. still-missing
    IAM grant) is caught and returns `{}` rather than propagating and
    crashing the watchdog cycle around it.
  - The account id is resolved once and cached -- a second call does not
    re-invoke the (expensive, off-event-loop) resolver.

Run:  cd api && ../.venv/bin/python tests/test_cloudwatch_analyze_log_group_arn.py
"""

import _pathfix  # noqa: F401

import asyncio
import sys
from datetime import datetime, timedelta, timezone

import backend.monitoring.cloudwatch_mcp_client as cw_module
from backend.monitoring.cloudwatch_mcp_client import (
    CloudWatchMCPClient,
    CloudWatchMCPError,
    _log_group_arn,
)

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


def test_log_group_arn_shape():
    print("\n── _log_group_arn produces the standard CloudWatch Logs ARN shape ──")
    arn = _log_group_arn("/fellowscript/app", "123456789012")
    check("ARN matches arn:aws:logs:<region>:<account>:log-group:<name>:*",
          arn, f"arn:aws:logs:{cw_module.CLOUDWATCH_REGION}:123456789012:log-group:/fellowscript/app:*")


async def test_analyze_log_group_sends_arn_and_name():
    print("\n── analyze_log_group sends BOTH log_group_arn and log_group_name to the tool ──")
    client = CloudWatchMCPClient.__new__(CloudWatchMCPClient)  # bypass __aenter__ (no real subprocess)
    client._session = object()  # non-None sentinel; _call_tool is stubbed below anyway

    calls = []

    async def fake_resolve():
        return "999988887777"

    async def fake_call_tool(name, arguments):
        calls.append((name, arguments))
        return {"summary": "ok"}

    orig_resolve = cw_module._resolve_account_id
    orig_cache = cw_module._account_id_cache
    cw_module._resolve_account_id = fake_resolve
    cw_module._account_id_cache = None
    client._call_tool = fake_call_tool
    try:
        start = datetime(2026, 8, 15, 10, 0, 0, tzinfo=timezone.utc)
        end = start + timedelta(minutes=1)
        result = await client.analyze_log_group("/fellowscript/app", start, end)

        check("analyze_log_group returns the tool's payload on success", result, {"summary": "ok"})
        check("_call_tool invoked exactly once", len(calls), 1)
        name, arguments = calls[0]
        check("tool name is analyze_log_group", name, "analyze_log_group")
        check("log_group_arn present -- the exact field production was missing (commit a8a22ecc)",
              "log_group_arn" in arguments, True)
        check("log_group_arn is well-formed",
              arguments.get("log_group_arn"),
              f"arn:aws:logs:{cw_module.CLOUDWATCH_REGION}:999988887777:log-group:/fellowscript/app:*")
        check("log_group_name still present alongside the arn",
              arguments.get("log_group_name"), "/fellowscript/app")
        check("start_time/end_time forwarded", "start_time" in arguments and "end_time" in arguments, True)
    finally:
        cw_module._resolve_account_id = orig_resolve
        cw_module._account_id_cache = orig_cache


async def test_no_aws_credentials_returns_empty_without_calling_tool():
    print("\n── No usable AWS credentials: returns {} without ever calling the tool ──")
    client = CloudWatchMCPClient.__new__(CloudWatchMCPClient)
    client._session = object()

    calls = []

    async def failing_resolve():
        raise RuntimeError("simulated: no AWS credentials available in this environment")

    async def should_not_be_called(name, arguments):
        calls.append((name, arguments))
        return {}

    orig_resolve = cw_module._resolve_account_id
    orig_cache = cw_module._account_id_cache
    cw_module._resolve_account_id = failing_resolve
    cw_module._account_id_cache = None
    client._call_tool = should_not_be_called
    try:
        start = datetime(2026, 8, 15, 10, 0, 0, tzinfo=timezone.utc)
        end = start + timedelta(minutes=1)
        result = await client.analyze_log_group("/fellowscript/app", start, end)
        check("returns {} rather than raising", result, {})
        check("_call_tool never invoked -- nothing to send an ARN for without an account id",
              len(calls), 0)
    finally:
        cw_module._resolve_account_id = orig_resolve
        cw_module._account_id_cache = orig_cache


async def test_tool_call_failure_caught_and_returns_empty():
    print("\n── analyze_log_group tool call failure (e.g. missing IAM grant) is caught ──")
    client = CloudWatchMCPClient.__new__(CloudWatchMCPClient)
    client._session = object()

    async def fake_resolve():
        return "111122223333"

    async def failing_call_tool(name, arguments):
        raise CloudWatchMCPError("simulated: AccessDeniedException on analyze_log_group")

    orig_resolve = cw_module._resolve_account_id
    orig_cache = cw_module._account_id_cache
    cw_module._resolve_account_id = fake_resolve
    cw_module._account_id_cache = None
    client._call_tool = failing_call_tool
    try:
        start = datetime(2026, 8, 15, 10, 0, 0, tzinfo=timezone.utc)
        end = start + timedelta(minutes=1)
        result = await client.analyze_log_group("/fellowscript/app", start, end)
        check("a CloudWatchMCPError from the tool call is caught, not propagated", result, {})
    finally:
        cw_module._resolve_account_id = orig_resolve
        cw_module._account_id_cache = orig_cache


async def test_account_id_resolved_once_and_cached():
    print("\n── Account id resolution is cached across calls (real _resolve_account_id) ──")
    # Pre-populate the process-lifetime cache the real _resolve_account_id
    # checks first -- proves a cached id short-circuits before ever
    # touching boto3/STS, without needing real AWS credentials in this
    # test environment.
    orig_cache = cw_module._account_id_cache
    cw_module._account_id_cache = "444455556666"
    try:
        account_id = await cw_module._resolve_account_id()
        check("cached account id returned directly", account_id, "444455556666")
        check("cache left unchanged by a cached-hit call", cw_module._account_id_cache, "444455556666")
    finally:
        cw_module._account_id_cache = orig_cache

    print("\n── analyze_log_group reuses the client-wide cached account id across two calls ──")
    client = CloudWatchMCPClient.__new__(CloudWatchMCPClient)
    client._session = object()

    arns_sent = []

    async def fake_call_tool(name, arguments):
        arns_sent.append(arguments.get("log_group_arn"))
        return {}

    orig_cache2 = cw_module._account_id_cache
    cw_module._account_id_cache = "777788889999"
    client._call_tool = fake_call_tool
    try:
        start = datetime(2026, 8, 15, 10, 0, 0, tzinfo=timezone.utc)
        end = start + timedelta(minutes=1)
        await client.analyze_log_group("/fellowscript/app", start, end)
        await client.analyze_log_group("/fellowscript/nginx/error", start, end)
        check("both calls used the same cached account id in their constructed ARN",
              all("777788889999" in arn for arn in arns_sent), True)
        check("ARNs differ by log group name as expected",
              arns_sent[0] != arns_sent[1], True)
    finally:
        cw_module._account_id_cache = orig_cache2


if __name__ == "__main__":
    test_log_group_arn_shape()
    asyncio.run(test_analyze_log_group_sends_arn_and_name())
    asyncio.run(test_no_aws_credentials_returns_empty_without_calling_tool())
    asyncio.run(test_tool_call_failure_caught_and_returns_empty())
    asyncio.run(test_account_id_resolved_once_and_cached())

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
