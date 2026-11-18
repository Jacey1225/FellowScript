"""Scheduled devotions are paid-only (task 20261117-scheduled-devotions-paid-only).

Plain script, no DB: ``python tests/test_scheduled_devotions_paid_only.py``.
Stubs the plan lookup on LimitsManager; checks the gate decision, the usage
payload's locked state, fail-closed behavior, and that every write/fire path
consults the gate in source.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from backend.subscription.limits import LimitsManager  # noqa: E402
from schemas.subscription import FREE_LIMITS  # noqa: E402

failures = []


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        failures.append(name)


class Fake(LimitsManager):
    def __init__(self, subscribed=None, boom=False):
        self._sub, self._boom = subscribed, boom

    def is_subscribed(self, user_id):
        if self._boom:
            raise RuntimeError("plan lookup failed")
        return self._sub

    def _count(self, resource, user_id):
        return 3 if resource == "agent_events" else 0  # existing grandfathered rows

    class cur:  # usage_summary plan_type lookup for subscribed users
        @staticmethod
        def execute(*a, **k): pass

        @staticmethod
        def fetchone(): return ("monthly",)


check("config: free agent_events limit is 0", FREE_LIMITS["agent_events"] == 0)

free = Fake(False).check("u", "agent_events")
check("free user denied even with existing rows", free["allowed"] is False and free["resource"] == "agent_events")
check("free user remaining is 0", free["remaining"] == 0)

paid = Fake(True).check("u", "agent_events")
check("paid user allowed", paid["allowed"] is True and paid["unlimited"] is True)

try:
    Fake(boom=True).check("u", "agent_events")
    check("plan lookup error propagates (fail closed)", False)
except RuntimeError:
    check("plan lookup error propagates (fail closed)", True)

pf = Fake(False).usage_summary("u")["paid_only"]["scheduled_devotions"]
check("usage: free sees locked scheduled_devotions", pf == {"allowed": False, "free_allowed": False})
pp = Fake(True).usage_summary("u")["paid_only"]["scheduled_devotions"]
check("usage: paid sees unlocked scheduled_devotions", pp["allowed"] is True)

agent_src = open(os.path.join(ROOT, "routes/agent.py")).read()
check("add + update + commit routes gate agent_events", agent_src.count('"agent_events"') >= 3)
sched_src = open(os.path.join(ROOT, "backend/interactions/scheduler.py")).read()
fire = sched_src[sched_src.index("async def _fire_due_heartbeats"):sched_src.index("async def _fire_due_session_reminders")]
check("scheduler gates agent_events before firing",
      0 < fire.index('"agent_events"') < fire.index("commit_hb_response, agent_id"))
check("scheduler never deletes heartbeats", "DELETE FROM agent_heartbeats" not in fire)

sys.exit(1 if failures else 0)
