"""Scheduled-devotions rename (20261002): backend contract + wording guard.

Plain script: ``python tests/test_scheduled_devotions_wording.py``.
User-facing copy says "scheduled devotions"; the public identifiers
(``agent_events`` limit key, /agent routes, agent_heartbeats table) must stay.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from schemas.subscription import FREE_LIMITS  # noqa: E402

failures = []


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        failures.append(name)


# Public identifier + limit semantics unchanged (older app builds rely on them).
check("FREE_LIMITS keeps 'agent_events' key", "agent_events" in FREE_LIMITS)
check("free plan allows 0 scheduled devotions (paid-only)", FREE_LIMITS.get("agent_events") == 0)
from schemas.subscription import PAID_ONLY_RESOURCES  # noqa: E402
check("scheduled_devotions flagged paid-only", PAID_ONLY_RESOURCES.get("scheduled_devotions") is True)

# Push notification titles/bodies must not expose the old feature terms.
forbidden = re.compile(r"agent event|heartbeat|automation", re.I)
src = open(os.path.join(ROOT, "backend/interactions/scheduler.py")).read()
alerts = re.findall(r"send_push\(\s*token,\s*(\"[^\"]*\"),\s*(?:\n\s*)?(\"[^\"]*\")", src)
check("scheduler push strings found", len(alerts) >= 2)
for t, b in alerts:
    check(f"push copy clean: {t}", not forbidden.search(t + b))

# Limit gate responses are structured data, no free-text feature name.
limits_src = open(os.path.join(ROOT, "backend/subscription/limits.py")).read()
check("limits.py has no detail= prose strings", "detail=" not in limits_src)

sys.exit(1 if failures else 0)
