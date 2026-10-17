"""Mutation checks for test_announcement_repeat.py (task 20261016-announcement-recurring-reminder).

Breaks one guard at a time in the source, runs the test file against the
scratch DB the caller configured (same env as the test itself) and requires
that it FAILS, naming the check(s) that caught the mutation. The original
source is always restored (also on Ctrl-C).

Run: cd api && <same env as test_announcement_repeat.py> ../.venv/bin/python tests/check_mutations_announcement_repeat.py
"""
import _pathfix  # noqa: F401

import os
import subprocess
import sys

API = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULES = "backend/interactions/announcement_repeat_rules.py"
JOB = "backend/interactions/announcement_repeat.py"
MGR = "backend/interactions/announcements.py"
NOTIFIER = "backend/interactions/announcement_notifier.py"

# (name, file, old, new, substring expected in a FAIL line)
MUTATIONS = [
    ("flag guard on job removed", JOB,
     "return bool(rules.ANNOUNCEMENT_REPEAT_ENABLED and notifier._enabled())",
     "return bool(notifier._enabled())", "flag off: job"),
    ("flag guard in create/update validation removed", MGR,
     "        if not repeat_rules.ANNOUNCEMENT_REPEAT_ENABLED:\n            raise ValueError(\"Repeating reminders are not available\")\n",
     "", "flag off: non-null repeat_interval"),
    ("serializer ignores the flag (keys always present)", MGR,
     "        if repeat_rules.ANNOUNCEMENT_REPEAT_ENABLED:\n            end = ",
     "        if True:\n            end = ", "flag off: response has no repeat_"),
    ("repeat_tz leaked to members", MGR,
     "            if out[\"can_edit\"]:\n                out[\"repeat_tz\"] = repeat_tz",
     "            out[\"repeat_tz\"] = repeat_tz", "member does NOT see repeat_tz"),
    ("claim does not advance the occurrence (no dedup)", JOB,
     "        \"next_repeat_at\": rules.next_armed(publish_at, interval, tz, now, end, new_count),",
     "        \"next_repeat_at\": due,", "re-tick of the same occurrence"),
    ("claim guard + FOR UPDATE SKIP LOCKED removed (no atomic single winner)", JOB,
     (("AND next_repeat_at = %s\",\n                    (*updates.values(), aid, row[9]),",
       "AND %s IS NOT NULL\",\n                    (*updates.values(), aid, row[9]),"),
      ("ORDER BY next_repeat_at LIMIT %s FOR UPDATE SKIP LOCKED", "ORDER BY next_repeat_at LIMIT %s")),
     None, "concurrent claimers"),
    ("stale/no-back-fill check removed", JOB,
     "    if age > rules.ANNOUNCEMENT_REPEAT_STALE_AFTER_SECONDS:",
     "    if False:", "stale occurrence"),
    ("deleted rows selected", JOB,
     "AND deleted_at IS NULL AND publish_at <= now() ", "AND publish_at <= now() ", "deleted row never fires"),
    ("unpublished rows selected", JOB,
     "AND deleted_at IS NULL AND publish_at <= now() ", "AND deleted_at IS NULL ", "not yet published"),
    ("author-left check removed", JOB,
     "    if not _author_eligible(db, group_id, creator_id):", "    if False:", "author no longer a member"),
    ("52-occurrence stop removed from job", JOB,
     "or count >= rules.ANNOUNCEMENT_REPEAT_MAX_OCCURRENCES:", ":", "52 pushes done"),
    ("end-date stop removed from job", JOB,
     "if end is None or due > end or", "if end is None or", "past repeat_until: no push"),
    ("group push budget ignored", JOB,
     "    elif _group_over_cap(db, group_id, aid):", "    elif False:", "at the group cap"),
    ("per-tick row cap ignored", JOB,
     "(rules.ANNOUNCEMENT_REPEAT_MAX_ROWS_PER_TICK,)", "(10000,)", "per-tick row cap"),
    ("opt-out toggle type changed", JOB,
     'PUSH_TYPE = "announcement_reminder"', 'PUSH_TYPE = "announcement_push"', "opt-out"),
    ("alert body loses 'Reminder:' prefix", JOB,
     'notifier._truncate(f"Reminder: {title}")', "notifier._truncate(f\"{title}\")", "Reminder: {title}"),
    ("restore no longer re-arms forward", MGR,
     "        if row[19]:\n            # Restore re-arms", "        if False:\n            # Restore re-arms", "restore re-arms forward only"),
    ("max 3 repeating per group not enforced", MGR,
     "        if self._other_active_repeaters(exclude_id) >= repeat_rules.ANNOUNCEMENT_REPEAT_MAX_ACTIVE_PER_GROUP:",
     "        if False:", "4th active repeating"),
    ("lifetime 52 cap not enforced on edit", MGR,
     "        if current[\"push_count\"] >= repeat_rules.ANNOUNCEMENT_REPEAT_MAX_OCCURRENCES:\n            raise",
     "        if False:\n            raise", "lifetime cap"),
    ("until may be in the past / unbounded horizon", RULES,
     "    if parsed <= publish_at or parsed <= now:", "    if parsed <= publish_at:", "until past rejected"),
    ("365-day horizon not enforced", RULES,
     "    if parsed > now + timedelta(days=ANNOUNCEMENT_REPEAT_HORIZON_DAYS):", "    if False:", "366 days ahead rejected"),
    ("naive until accepted", RULES,
     "    if parsed.tzinfo is None:\n        raise ValueError(\"repeat_until must include a timezone offset\")\n", "", "until naive rejected"),
    ("tz allowlist removed", RULES,
     "or value not in _known_zones()):", "):", "tz 'Mars/Phobos' rejected"),
    ("interval allowlist loosened", RULES,
     "if not isinstance(value, str) or value not in REPEAT_INTERVALS:", "if not isinstance(value, str):", "interval 'hourly' rejected"),
    ("month-end clamp removed (drift/crash)", RULES,
     "    day = min(naive.day, calendar.monthrange(year, month)[1])", "    day = naive.day", "monthly Jan31"),
    ("occurrences computed in UTC, ignoring repeat_tz (DST drift)", RULES,
     "    zone = ZoneInfo(tz) if tz else timezone.utc\n", "    zone = timezone.utc\n", "daily across spring-forward"),
    ("hourly cap ignores repeat pushes", NOTIFIER,
     " OR last_repeat_push_at > now() - make_interval(secs => %s))\",\n        (group_id, ANNOUNCEMENT_PUSH_CAP_WINDOW_SECONDS, ANNOUNCEMENT_PUSH_CAP_WINDOW_SECONDS,\n         ANNOUNCEMENT_PUSH_CAP_WINDOW_SECONDS),",
     ")\",\n        (group_id, ANNOUNCEMENT_PUSH_CAP_WINDOW_SECONDS, ANNOUNCEMENT_PUSH_CAP_WINDOW_SECONDS),",
     "_over_cap counts last_repeat_push_at"),
]


def run_tests() -> tuple[int, list[str]]:
    p = subprocess.run([sys.executable, "-B", os.path.join(API, "tests", "test_announcement_repeat.py")],
                       cwd=API, capture_output=True, text=True, env=os.environ.copy(), timeout=600)
    fails = [ln.strip() for ln in (p.stdout + p.stderr).splitlines() if ln.strip().startswith("FAIL")]
    tb = "Traceback" in p.stderr
    return p.returncode, fails + (["<crash>"] if tb else [])


def main() -> int:
    survivors, caught = [], []
    for name, rel, old, new, expect in MUTATIONS:
        path = os.path.join(API, rel)
        src = open(path).read()
        edits = old if isinstance(old, tuple) else ((old, new),)
        if any(src.count(o) != 1 for o, _ in edits):
            print(f"BAD MUTATION (pattern not found exactly once): {name}")
            survivors.append(name + " [pattern not found once]")
            continue
        mutated = src
        for o, n in edits:
            mutated = mutated.replace(o, n)
        try:
            open(path, "w").write(mutated)
            code, fails = run_tests()
        finally:
            open(path, "w").write(src)
        hit = [f for f in fails if expect.lower() in f.lower()]
        if code != 0 and (hit or "<crash>" in fails):
            caught.append(name)
            print(f"KILLED   {name}  ({len(fails)} failing; e.g. {(hit or fails)[0][:90]})")
        elif code != 0:
            caught.append(name)
            print(f"KILLED*  {name}  (failed, but not the expected check '{expect}': {fails[:1]})")
        else:
            survivors.append(name)
            print(f"SURVIVED {name}")
    print(f"\n{len(caught)} killed, {len(survivors)} survived of {len(MUTATIONS)}")
    for s in survivors:
        print("  survivor:", s)
    return 1 if survivors else 0


if __name__ == "__main__":
    raise SystemExit(main())
