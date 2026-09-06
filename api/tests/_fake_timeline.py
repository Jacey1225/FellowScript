"""Shared test stub for the timeline-planning agent's own LLM call, task
20260906-heartbeat-timeline-instructions.

Import this (after ``_pathfix``) in any test file whose ``AgentManager`` --
or a ``FakeManager``/subclass of it that only stubs ``_call_api`` -- can
reach ``add_heartbeat`` (directly, or via the real
``POST /agent/{user_id}/{agent_id}/heartbeat`` route) or
``ensure_current_timeline`` (invoked internally by both
``commit_hb_response`` and ``_commit_hb_response_forced``). All three call
``AgentManager._generate_timeline_days``, which by default calls out to the
REAL OpenRouter API (``_call_timeline_api``).

Any test that builds a heartbeat row via a raw SQL INSERT (bypassing
``add_heartbeat``, which always leaves ``timeline_instruction`` NULL on a
row created any other way) or that calls ``add_heartbeat``/the real
add-heartbeat route directly hits this on its very first fire/creation --
BEFORE that test's own ``_call_api`` note-generation stub is ever reached --
making the test slow, non-deterministic, network-dependent, and liable to
fail outright with no network access or a missing/invalid API key.

Patched at the ``_generate_timeline_days`` level (above the retry/parse-
validation logic inside it, not at the lower-level ``_call_timeline_api``
network call) since these tests exist to exercise ``commit_hb_response`` /
``add_heartbeat``'s OWN behavior, not the timeline-planning agent's own
parsing/retry behavior -- that is covered directly, and in isolation (with
its own per-scenario ``_call_timeline_api`` stubs), by
test_agent_context.py's timeline-focused suite, which does not import this
module.

Importing this module monkeypatches ``AgentManager._generate_timeline_days``
at the class level for the remaining lifetime of the current process. Since
every test file in this directory runs as its own standalone
``python tests/test_x.py`` process (see tests/_pathfix.py's own docstring
for why), this never leaks across test files.
"""
from backend.interactions.agent import AgentManager


def _stub_generate_timeline_days(self, heartbeat_prompt, firing_offsets, prior_coverage_summary):
    return {
        "days": {offset: f"stub timeline instruction for day-offset {offset}" for offset in firing_offsets},
        "coverage_summary": "stub coverage summary",
    }


AgentManager._generate_timeline_days = _stub_generate_timeline_days
