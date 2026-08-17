"""
Proves the concrete resolution of Phase 1's Decision 2 open item (docs/
architecture/docker-plan.md, executed in this task's backend step): the
`uvx awslabs.cloudwatch-mcp-server@latest` runtime-fetch default in
`cloudwatch_mcp_client.py::CLOUDWATCH_MCP_COMMAND` was replaced with the
pip-pinned package's own console-script entry point,
`awslabs.cloudwatch-mcp-server` (no `uvx`, no `@latest`, no args) --
installed at build time via `awslabs.cloudwatch-mcp-server==0.1.8` in
requirements.txt.

Before this change, `CLOUDWATCH_MCP_COMMAND` defaulted to a two-token command
(`uvx awslabs.cloudwatch-mcp-server@latest`) that `shlex.split` broke into a
program (`uvx`) plus one arg. After this change it must be a single-token
command with the pip-installed console script as the program and NO args --
if `__aenter__` ever regresses to spawning that command with args, or a
future edit reintroduces `uvx`/`@latest`, the CloudWatch watchdog job (live
today per .claude/pipeline/20260815-cloudwatch-watchdog-memory-leak/) would
either hang waiting on a network-fetched subprocess it doesn't need anymore,
or fail outright once `uvx` isn't installed in the container.

Neither the real `cloudwatch-mcp-server` subprocess nor a live AWS/EC2
environment is available here (same constraint the module's own docstring
and test_cloudwatch_analyze_log_group_arn.py already document), so this
verifies the two boundary points fully within this repo's control:
  1. What command string a fresh `CloudWatchMCPClient()` resolves to and how
     it tokenizes (the actual `shlex.split` the container's `uvicorn`
     process performs to spawn the subprocess).
  2. That `__aenter__` builds `StdioServerParameters` from that exact
     command/args pair -- by stubbing the two boundary points to the real
     `mcp` package (`stdio_client`, `ClientSession`) rather than mocking
     `CloudWatchMCPClient.__aenter__` itself, so the real `shlex.split` +
     `StdioServerParameters(...)` construction in the module runs for real.
  3. That the env override mechanism (`CLOUDWATCH_MCP_COMMAND`) documented
     in the Dockerfile/compose comments as the escape hatch for a future
     deploy target still works, in a clean subprocess (avoids reload/global-
     state ordering issues with the already-imported module in this
     process).
  4. That `WatchdogManager.run_cycle` (backend/monitoring/watchdog.py) spawns
     its `CloudWatchMCPClient()` with zero explicit command argument --
     i.e. the live watchdog job really does pick up the module-level pinned
     default with no per-call override, confirming the watchdog subsystem
     still resolves the pinned command correctly post-containerization.

Run:  cd api && ../.venv/bin/python tests/test_cloudwatch_mcp_command_pinning.py
"""

import _pathfix  # noqa: F401

import asyncio
import inspect
import shlex
import subprocess
import sys

import backend.monitoring.cloudwatch_mcp_client as cw_module
import backend.monitoring.watchdog as watchdog_module
from backend.monitoring.cloudwatch_mcp_client import CloudWatchMCPClient

PASS, FAIL = "\033[92mPASS\033[0m", "\033[91mFAIL\033[0m"
results = []


def check(label, got, want):
    ok = got == want
    results.append(ok)
    print(f"  [{PASS if ok else FAIL}] {label}: got {got!r}, want {want!r}")


def test_default_command_is_the_pinned_console_script():
    print("\n── CLOUDWATCH_MCP_COMMAND defaults to the pinned pip console script ──")
    check(
        "default is the pip-installed console-script name, not a uvx invocation",
        cw_module.CLOUDWATCH_MCP_COMMAND,
        "awslabs.cloudwatch-mcp-server",
    )
    check(
        "default no longer contains 'uvx' (the pre-Phase-1 runtime-fetch form)",
        "uvx" in cw_module.CLOUDWATCH_MCP_COMMAND,
        False,
    )
    check(
        "default no longer pins via '@latest' (that's requirements.txt's job now)",
        "@latest" in cw_module.CLOUDWATCH_MCP_COMMAND,
        False,
    )


def test_default_command_tokenizes_to_a_single_arg_free_program():
    print("\n── shlex.split of the pinned default is one token, no args ──")
    client = CloudWatchMCPClient()
    check("client._command picks up the module-level pinned default",
          client._command, cw_module.CLOUDWATCH_MCP_COMMAND)

    parts = shlex.split(client._command)
    check("exactly one token (program only)", len(parts), 1)
    check("program is the pinned console-script entry point",
          parts[0], "awslabs.cloudwatch-mcp-server")


def test_explicit_command_override_still_works():
    print("\n── An explicit command= override at construction time still works ──")
    client = CloudWatchMCPClient(command="/custom/path/cloudwatch-mcp-server --flag")
    check("explicit command overrides the module default",
          client._command, "/custom/path/cloudwatch-mcp-server --flag")
    parts = shlex.split(client._command)
    check("override still shlex-splits into program + args as before",
          parts, ["/custom/path/cloudwatch-mcp-server", "--flag"])


async def test_aenter_builds_stdio_params_from_pinned_command():
    print("\n── __aenter__ spawns StdioServerParameters with the pinned command/args/env ──")
    from mcp.client.stdio import StdioServerParameters

    captured = {}

    class FakeSession:
        def __init__(self, read, write):
            captured["session_read_write"] = (read, write)

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def initialize(self):
            captured["initialized"] = True

    class FakeStdioCtx:
        def __init__(self, params: StdioServerParameters):
            captured["params"] = params

        async def __aenter__(self):
            return ("fake-read", "fake-write")

        async def __aexit__(self, *a):
            return False

    def fake_stdio_client(params):
        return FakeStdioCtx(params)

    # Patch the *actual* attributes __aenter__ looks up via its local
    # `from mcp import ClientSession` / `from mcp.client.stdio import
    # stdio_client` -- those are plain module-attribute lookups performed
    # at call time, so patching the real mcp package/submodule here is
    # enough; nothing about cloudwatch_mcp_client.py itself needs patching.
    import mcp
    import mcp.client.stdio as stdio_mod

    orig_client_session = mcp.ClientSession
    orig_stdio_client = stdio_mod.stdio_client
    mcp.ClientSession = FakeSession
    stdio_mod.stdio_client = fake_stdio_client
    try:
        client = CloudWatchMCPClient()
        result = await client.__aenter__()
        try:
            check("__aenter__ returns the client itself", result is client, True)
            check("session was initialized", captured.get("initialized"), True)

            params = captured["params"]
            check("StdioServerParameters.command is the pinned console script",
                  params.command, "awslabs.cloudwatch-mcp-server")
            check("StdioServerParameters.args is empty (no @latest/version arg needed)",
                  params.args, [])
            check("StdioServerParameters.env passes the process environment through "
                  "(preserves AWS creds/IMDSv2 metadata-service reachability under "
                  "--network=host, per Decision 3's 'do nothing' guidance)",
                  isinstance(params.env, dict) and len(params.env) > 0, True)
        finally:
            await client.__aexit__(None, None, None)
    finally:
        mcp.ClientSession = orig_client_session
        stdio_mod.stdio_client = orig_stdio_client


def test_watchdog_spawns_client_with_zero_args_using_module_default():
    print("\n── WatchdogManager.run_cycle spawns CloudWatchMCPClient() with no override ──")
    src = inspect.getsource(watchdog_module.WatchdogManager.run_cycle)
    check(
        "run_cycle constructs CloudWatchMCPClient() with no explicit command arg "
        "-- the live watchdog job really does rely on the pinned module default, "
        "not some other resolution path",
        "CloudWatchMCPClient()" in src,
        True,
    )


def test_pinned_default_survives_a_fresh_process_with_no_env_override():
    print("\n── A fresh process (no CLOUDWATCH_MCP_COMMAND env set) resolves the pinned default ──")
    out = subprocess.run(
        [sys.executable, "-c",
         "import backend.monitoring.cloudwatch_mcp_client as m; print(m.CLOUDWATCH_MCP_COMMAND)"],
        cwd=".", capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"},
    )
    check("subprocess exited cleanly", out.returncode, 0)
    check("fresh-process default matches the pinned console script",
          out.stdout.strip(), "awslabs.cloudwatch-mcp-server")


def test_env_override_mechanism_still_works():
    print("\n── CLOUDWATCH_MCP_COMMAND env var still overrides the default (deploy escape hatch) ──")
    out = subprocess.run(
        [sys.executable, "-c",
         "import backend.monitoring.cloudwatch_mcp_client as m; print(m.CLOUDWATCH_MCP_COMMAND)"],
        cwd=".", capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "CLOUDWATCH_MCP_COMMAND": "some-other-installed-name"},
    )
    check("subprocess exited cleanly", out.returncode, 0)
    check("env override wins over the pinned default",
          out.stdout.strip(), "some-other-installed-name")


if __name__ == "__main__":
    test_default_command_is_the_pinned_console_script()
    test_default_command_tokenizes_to_a_single_arg_free_program()
    test_explicit_command_override_still_works()
    asyncio.run(test_aenter_builds_stdio_params_from_pinned_command())
    test_watchdog_spawns_client_with_zero_args_using_module_default()
    test_pinned_default_survives_a_fresh_process_with_no_env_override()
    test_env_override_mechanism_still_works()

    passed = sum(results)
    failed = len(results) - passed
    print(f"\n{'─'*40}")
    print(f"Results: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)
