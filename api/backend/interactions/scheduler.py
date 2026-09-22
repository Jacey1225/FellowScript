import logging
from datetime import datetime, timedelta, timezone as tzmod
from zoneinfo import ZoneInfo
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from db import DBManager
from backend.subscription.subscriptions import SubscriptionsManager
from backend.monitoring.watchdog import WATCHDOG_POLL_INTERVAL_SECONDS

logger = logging.getLogger(__name__)
scheduler = AsyncIOScheduler()

# Dedicated child logger for the CloudWatch watchdog's own cycle-failure
# logging (see `_run_error_watchdog` below). `logger` (name
# "backend.interactions.scheduler") is shared by every scheduled job in this
# module -- notifications, nightly backups, trial reconciliation -- so
# watchdog.py's self-exclusion filter can't safely treat the whole module's
# logger name as "the watchdog's own log line" without also hiding a real
# failure in one of those unrelated jobs. This child logger's name
# ("backend.interactions.scheduler.watchdog") lets the self-exclusion filter
# key on exactly this job's failure lines and nothing else logged from this
# file. See backend/monitoring/watchdog.py's `_SELF_LOGGER_NAMES`.
_watchdog_logger = logger.getChild("watchdog")

# Heartbeats are scheduled to the minute ("HH:mm", AgentHeartbeats.timestamps,
# interpreted in the owning user's own local timezone -- see
# _fire_due_heartbeats below), so a 1-minute cadence is the tightest useful
# precision -- matches the existing `_run_nightly_backups` cadence. Named per
# this file's proactive-configuration precedent (WATCHDOG_POLL_INTERVAL_SECONDS)
# rather than an inline magic literal.
HEARTBEAT_POLL_INTERVAL_SECONDS = 60

# A session's time_start is a real-time user-facing moment (unlike the
# coarse daily/24h midday/guilt windows), so this polls at the same tight
# cadence as heartbeats rather than the 15-minute reminder jobs' cadence.
SESSION_REMINDER_POLL_INTERVAL_SECONDS = 60

# A session's time_start is a one-shot absolute moment with no lower bound
# on the due-scan query (`time_start <= NOW() AND reminder_sent_at IS
# NULL`) -- unlike heartbeats, whose candidate selection recomputes
# "scheduled" against the CURRENT local day every cycle and so can only
# ever fire today's slot (see _fire_due_heartbeats' docstring), a session
# has no such structural bound. That gap let a brand-new job's first-ever
# poll cycle treat an arbitrarily old pre-existing row as a live "starting
# now" candidate: the session_reminder_fire job didn't exist until
# 2026-09-04 (task 20260904-session-push-notifications), and on its first
# scan it fired a "starting now" push for a devotions row whose time_start
# had passed 39 days earlier (see this task's root-cause write-up,
# .claude/pipeline/20260905-scheduled-event-trigger-gap/backend.json). A
# candidate claimed past this cutoff is a fail-closed skip, not a fire --
# Security Posture Q14 in that task's intake spec treats "can't confidently
# judge this still meaningful to fire" the same as any other fail-closed
# case. 1 hour is generous enough to ride out a redeploy/brief scheduler
# outage without dropping a genuinely-recent reminder, while still refusing
# to fire a "starting now" push that would read as obviously wrong to the
# recipient. Named per this file's own WATCHDOG_POLL_INTERVAL_SECONDS /
# HEARTBEAT_POLL_INTERVAL_SECONDS precedent rather than an inline literal.
SESSION_REMINDER_STALE_AFTER_SECONDS = 3600

# Task 20260921-session-auto-delete-window: a non-recurring session that's
# never auto-cleaned up otherwise (see _auto_delete_expired_sessions below)
# becomes a candidate once its time_end is this many seconds in the past --
# "groups running long can still finish" per the intake spec, so this is
# deliberately the same order of magnitude as SESSION_REMINDER_STALE_AFTER_
# SECONDS's 1-hour cutoff but a conceptually distinct constant (one gates a
# push send, this one gates a destructive delete). Named per this file's own
# WATCHDOG_POLL_INTERVAL_SECONDS/HEARTBEAT_POLL_INTERVAL_SECONDS precedent
# rather than an inline literal.
SESSION_AUTO_DELETE_GRACE_SECONDS = 3600

# Real-time user-facing cleanup (a session should disappear reasonably soon
# after it's safe to delete), so this polls at the same tight cadence as
# HEARTBEAT_POLL_INTERVAL_SECONDS/SESSION_REMINDER_POLL_INTERVAL_SECONDS
# above rather than the coarser 15-minute/hourly jobs further down this
# file.
SESSION_AUTO_DELETE_POLL_INTERVAL_SECONDS = 60

# Task 20260921-recurring-session-next-occurrence: a `recurring = TRUE`
# session becomes a candidate for advancing to its next weekly occurrence
# once its `time_end` is this many seconds in the past -- same "groups
# running long can still finish" rationale as SESSION_AUTO_DELETE_GRACE_
# SECONDS, and deliberately the same magnitude, but kept as its own named
# constant per this file's own precedent of separately-named same-magnitude
# constants for different actions (advance vs. delete) on the same column.
SESSION_RECURRING_ADVANCE_GRACE_SECONDS = 3600

# Real-time user-facing moment (the same class of problem as
# SESSION_REMINDER_POLL_INTERVAL_SECONDS/SESSION_AUTO_DELETE_POLL_INTERVAL_
# SECONDS above), so this polls at the same tight cadence rather than the
# coarser 15-minute/hourly jobs further down this file.
SESSION_RECURRING_ADVANCE_POLL_INTERVAL_SECONDS = 60


async def _run_nightly_backups() -> None:
    """Mirror each due user's recent data into the separate backup database.

    Runs every minute; a given user is only actually backed up during the one
    minute per day their local clock reads 03:00. The DB work is synchronous
    (psycopg2), so it's offloaded to a thread via run_in_executor to avoid
    blocking the event loop.
    """
    import asyncio, functools
    from backend.backup.manager import BackupManager

    bm = BackupManager()
    try:
        loop = asyncio.get_running_loop()
        due_users = await loop.run_in_executor(None, bm.users_due_now)
        for user_id in due_users:
            try:
                result = await loop.run_in_executor(
                    None, functools.partial(bm.backup_user, user_id)
                )
                logger.info("Nightly backup for %s: %s", user_id, result)
            except Exception as e:
                logger.error("Nightly backup failed for %s: %s", user_id, e)
    except Exception as e:
        logger.error("Backup scheduler error: %s", e)
    finally:
        bm.close()


async def _reconcile_trials() -> None:
    """Advance elapsed trials, and remove subscriptions whose paid period lapsed."""
    sm = SubscriptionsManager()
    try:
        n = sm.reconcile_expired_trials()
        if n:
            logger.info("Reconciled %d expired trial(s) → active", n)
        expired = sm.reconcile_expired_subscriptions()
        if expired:
            logger.info("Removed %d lapsed subscription(s) past grace", expired)
    except Exception as e:
        logger.error("Subscription reconcile error: %s", e)
    finally:
        sm.close()


async def _run_error_watchdog() -> None:
    """CloudWatch error-detection + context-assembly watchdog (see
    backend/monitoring/watchdog.py). Polls all 5 monitored log groups via
    the read-only cloudwatch-mcp-server on a synchronized per-log-group
    cursor, detects application-level error signal, assembles context for
    each hit, and persists detection+context records. Read-only end-to-end
    — no remediation action is taken here (out of scope for this step).
    """
    from backend.monitoring.watchdog import WatchdogManager

    wm = WatchdogManager()
    try:
        counts = await wm.run_cycle()
        if counts["detections"]:
            logger.info(
                "CloudWatch watchdog: scanned %d event(s), %d new detection(s)",
                counts["events_scanned"], counts["detections"],
            )
    except Exception as e:
        _watchdog_logger.error("CloudWatch watchdog cycle failed: %s", e)
    finally:
        wm.close()


async def _midday_no_activity_reminder() -> None:
    """Gentle reminder once a user's local clock reads midday and they've
    had no tracked activity (note/highlight) yet today.

    Runs every 15 minutes; per-user local-time check (same pattern as
    BackupManager.users_due_now's 03:00 window) plus the
    `midday_reminder_sent_date` dedup marker means each user fires at most
    once per local calendar day, even though the job polls 4x/hour.
    """
    from backend.interactions.activity import ActivityManager
    from backend.interactions.push import send_push

    am = ActivityManager()
    try:
        for user_id, tzname, last_activity, midday_sent, _guilt_sent, token in am.users_with_tokens():
            if not token:
                continue
            try:
                local = datetime.now(tzmod.utc).astimezone(ZoneInfo(tzname or "UTC"))
            except Exception:
                logger.warning("Skipping user %s — invalid timezone %r", user_id, tzname)
                continue
            if local.hour != 12 or midday_sent == local.date():
                continue
            had_activity_today = (
                last_activity is not None
                and last_activity.astimezone(ZoneInfo(tzname or "UTC")).date() == local.date()
            )
            if had_activity_today:
                continue
            ok = await send_push(
                token, "A gentle nudge",
                "You haven't opened FellowScript yet today — a few quiet minutes could go a long way.",
            )
            if ok:
                am.mark_midday_sent(user_id, local.date())
    except Exception as e:
        logger.error("Midday no-activity reminder job error: %s", e)
    finally:
        am.close()


async def _guilt_no_activity_reminder() -> None:
    """More urgent reminder once a user has gone longer than
    ActivityManager.INACTIVITY_THRESHOLD (24h) since their last tracked
    activity. Dedup via `guilt_reminder_sent_at` so it re-fires at most once
    per threshold window, not on every poll. Skips users with no tracked
    activity ever — there's no "you stopped" moment to be guilty about yet.
    """
    from backend.interactions.activity import ActivityManager, INACTIVITY_THRESHOLD
    from backend.interactions.push import send_push

    am = ActivityManager()
    try:
        now = datetime.now(tzmod.utc)
        for user_id, _tz, last_activity, _midday_sent, guilt_sent, token in am.users_with_tokens():
            if not token or last_activity is None:
                continue
            if now - last_activity <= INACTIVITY_THRESHOLD:
                continue
            if guilt_sent is not None and now - guilt_sent <= INACTIVITY_THRESHOLD:
                continue
            ok = await send_push(
                token, "It's been a while",
                "It's been over a day since you last opened FellowScript. Your notes and highlights are waiting.",
            )
            if ok:
                am.mark_guilt_sent(user_id, now)
    except Exception as e:
        logger.error("Guilt no-activity reminder job error: %s", e)
    finally:
        am.close()


async def _friend_went_active_notify() -> None:
    """Notify a user's friends (excluding either direction of a block — see
    ActivityManager.friend_device_tokens) when that user transitions from
    inactive to active.

    ActivityManager.record_activity marks a transition by setting
    `became_active_at` and clearing `friend_notified_at`; this job picks up
    any un-notified transition, sends once per friend, then marks it
    notified — so a user oscillating active/inactive never re-triggers their
    friends more than once per real (>24h-gap) transition.

    The push body names the action via `_FRIEND_ACTIVITY_TEXT` below (note
    created/edited) or one of the two composed branches in `_compose_body`
    just under it (replied, verse highlighted — task
    20260904-friend-activity-push-triggers), keyed off the transition's
    `last_activity_type`. NOTE_REPLIED and VERSE_HIGHLIGHTED each need one
    extra per-user lookup (the reply's parent-note owner; the highlight's
    book/chapter/verse + resolved verse text) — deliberately not batched
    across the whole pending set: that set is already small (bounded by the
    >24h transition gate), so a per-user lookup here costs nothing worth
    batching for. A missing/unrecognized type (e.g. a pre-migration row with
    no type set), or either new lookup coming up empty, falls back to a
    generic/reference-only text rather than raising — consistent with this
    job's existing per-user-isolated, best-effort posture, not a new
    hard-failure mode. Like the rest of this file, never put note/highlight
    content (title, text, book/chapter/verse, verse text) in any log line
    here — the push body is the one deliberately user-facing surface for
    that content now (Security Posture Q13 in the intake spec: redaction
    applies to logs, not to this now-intentionally-user-facing surface).
    """
    from backend.interactions.activity import (
        ActivityManager, NOTE_CREATED, NOTE_EDITED, NOTE_REPLIED, VERSE_HIGHLIGHTED,
    )
    from backend.interactions.bible_text import verse_text
    from backend.interactions.push import send_push

    _FRIEND_ACTIVITY_TEXT = {
        NOTE_CREATED: "{username} created a new note.",
        NOTE_EDITED: "{username} edited a note.",
    }
    _FALLBACK_TEXT = "{username} just came back to FellowScript."
    # Used only when last_activity_type says VERSE_HIGHLIGHTED but the
    # highlight row itself can't be resolved at all (e.g. a race with a
    # since-removed highlight) — distinct from the "resolved but no verse
    # text" case below, which gets a reference-only fallback instead.
    _HIGHLIGHT_FALLBACK_TEXT = "{username} highlighted a verse."

    def _compose_body(am: "ActivityManager", user_id: str, username: str, last_activity_type: str | None) -> str:
        if last_activity_type == NOTE_REPLIED:
            resolved = am.most_recent_reply(user_id)
            if resolved:
                _, owner_username = resolved
                return f"{username} replied to {owner_username}'s note."
            return f"{username} replied to a note."
        if last_activity_type == VERSE_HIGHLIGHTED:
            ref = am.most_recent_highlight(user_id)
            if not ref:
                return _HIGHLIGHT_FALLBACK_TEXT.format(username=username)
            book, chapter, verse = ref
            text = verse_text(book, chapter, verse)
            if text:
                return f'{username} highlighted "{text}" ({book} {chapter}:{verse}).'
            return f"{username} highlighted {book} {chapter}:{verse}."
        return _FRIEND_ACTIVITY_TEXT.get(last_activity_type, _FALLBACK_TEXT).format(username=username)

    am = ActivityManager()
    try:
        pending = am.pending_friend_notifications()
        # Batch the friend/device-token lookup for the whole pending set in
        # one query instead of one per transitioning user — this set is
        # usually small (only users who just became active since the job's
        # last 5-minute run), but batching costs nothing when convenient.
        tokens_by_user: dict[str, list[tuple[str, str]]] = {}
        for user_id, friend_id, token in am.friend_device_tokens_bulk(
            [user_id for user_id, _, _, _ in pending]
        ):
            tokens_by_user.setdefault(str(user_id), []).append((friend_id, token))

        for user_id, username, became_active_at, last_activity_type in pending:
            body = _compose_body(am, user_id, username, last_activity_type)
            for friend_id, token in tokens_by_user.get(str(user_id), []):
                if not token:
                    continue
                try:
                    await send_push(token, "Friend Activity", body)
                except Exception as e:
                    logger.error("Friend-went-active push failed (%s -> %s): %s", user_id, friend_id, e)
            am.mark_friends_notified(user_id, became_active_at)
    except Exception as e:
        logger.error("Friend-went-active job error: %s", e)
    finally:
        am.close()


async def _fire_due_heartbeats() -> None:
    """Server-side heartbeat firing: scan every heartbeat that hasn't fired
    yet today (in its owning user's own local calendar) for an "HH:mm" slot
    (AgentHeartbeats.timestamps, indexed by day-of-month, interpreted as
    local to that user's timezone) that has already passed in that user's
    local time, fire it, and push the owning user a generic notification
    identifying which event fired.

    Runs every HEARTBEAT_POLL_INTERVAL_SECONDS. This replaces the client-only
    trigger (former iOS HeartbeatScheduler.checkAndFire) -- firing now happens
    regardless of whether any device has the app open -- but dedup is NOT
    reinvented here: AgentManager.commit_hb_response's existing atomic
    calendar-day claim (`last_fired` UPDATE-with-WHERE, now itself computed
    in the owning user's local timezone rather than a fixed UTC date) is the
    sole mechanism that makes it safe for this poller to race a client's own
    late call, or a slow previous poll cycle, for the same heartbeat. This
    job's own candidate-selection query below uses the same
    last-fired-in-local-calendar predicate purely as a cheap pre-filter to
    skip obviously-already-fired rows; it is not itself a claim and never
    substitutes for one.

    Heartbeats' stored "HH:mm" strings are unchanged (AgentHeartbeats /
    EventSetupSheet.swift still author them the same way), but per the
    timezone_handling revision they're now interpreted as local to the
    owning user's `users.timezone` (IANA name, via zoneinfo) rather than
    literal UTC -- matching the existing per-user-local-time precedent
    already used for the nightly backup job (BackupManager.users_due_now)
    and the midday/guilt reminder jobs above. A user whose stored timezone
    is missing/invalid is skipped for this cycle (fail-closed) rather than
    guessed at with a UTC fallback, since firing at the wrong local time is
    exactly the bug this revision is fixing.

    Per-heartbeat errors (a bad claim, an LLM failure, a push failure) are
    caught, logged, and skipped so one user's failure can't abort the whole
    cycle -- matching every other job in this file. A candidate we can't
    confidently resolve (e.g. the initial scan query itself fails) is left
    for the next cycle rather than guessed at, per this project's fail-closed
    posture.

    Every sync/psycopg2 call this function makes (the due-scan query, the
    per-candidate `check_limit` call, `commit_hb_response` itself, and the
    post-fire device-token/agent-name lookups) is offloaded via
    `loop.run_in_executor`, matching `_run_nightly_backups`' own offload of
    `bm.users_due_now`/`bm.backup_user` -- this is an `async def` on the
    process's one shared event loop, so an unwrapped sync DB call or (via
    commit_hb_response's internal `_call_api`) a blocking `requests.post` with
    a 60s timeout would otherwise stall every other coroutine on the loop for
    the call's duration. The per-candidate loop stays strictly sequential
    (each offloaded call is awaited before the next begins) rather than
    fanned out with `asyncio.gather`/`create_task`, so the outer `db`
    connection and each candidate's own fresh `AgentManager` connection are
    each only ever touched by one thread at a time -- see the
    thread_safety_boundary decision in this task's architecture.json.
    """
    import asyncio
    import functools
    from backend.interactions.agent import AgentManager
    from backend.interactions.push import send_push
    from backend.subscription.limits import check_limit

    def _scan_candidates():
        db.cur.execute(
            "SELECT ah._id, ah.agent_id, ah.user_id, ah.timestamps, ah.prompt, u.timezone "
            "FROM agent_heartbeats ah "
            "JOIN users u ON u._id = ah.user_id "
            "WHERE ah.last_fired IS NULL "
            "OR (ah.last_fired AT TIME ZONE COALESCE(u.timezone, 'UTC'))::date "
            "< (NOW() AT TIME ZONE COALESCE(u.timezone, 'UTC'))::date"
        )
        return db.cur.fetchall()

    def _post_fire_lookups(agent_id_: str, user_id_: str):
        token_rows = db.lookup("device_tokens", {"user_id": user_id_})
        token = list(token_rows.values())[0].get("token") if token_rows else None
        agent_row = db.lookup("agents", {"_id": agent_id_})
        agent_name = list(agent_row.values())[0].get("name", "") if agent_row else ""
        return token, agent_name

    loop = asyncio.get_running_loop()
    db = DBManager()
    try:
        try:
            candidates = await loop.run_in_executor(None, _scan_candidates)
        except Exception as e:
            logger.error("Heartbeat due-scan query failed: %s", e)
            return

        now_utc = datetime.now(tzmod.utc)
        for heartbeat_id, agent_id, user_id, timestamps, prompt, tzname in candidates:
            heartbeat_id, agent_id, user_id = str(heartbeat_id), str(agent_id), str(user_id)
            try:
                try:
                    local = now_utc.astimezone(ZoneInfo(tzname or "UTC"))
                except Exception:
                    logger.warning(
                        "Skipping heartbeat %s — invalid timezone %r for user %s",
                        heartbeat_id, tzname, user_id,
                    )
                    continue

                day_idx = local.day - 1  # timestamps is 0-indexed: index i == day i+1
                if not timestamps or day_idx >= len(timestamps):
                    continue
                time_str = timestamps[day_idx]
                if not time_str:
                    continue
                try:
                    hour, minute = (int(p) for p in time_str.split(":")[:2])
                    scheduled = local.replace(hour=hour, minute=minute, second=0, microsecond=0)
                except (ValueError, TypeError):
                    logger.warning(
                        "Heartbeat %s has an unparseable time slot for today — skipping.",
                        heartbeat_id,
                    )
                    continue
                if scheduled > local:
                    continue  # today's local slot hasn't arrived yet

                # Same weekly notes-cap gate commit_heartbeat applies before
                # calling commit_hb_response -- firing server-side must not let
                # a free user at their cap mint unlimited notes just because no
                # client ever calls the route anymore. Offloaded: check_limit
                # opens its own sync psycopg2 connection (LimitsManager).
                gate = await loop.run_in_executor(
                    None, functools.partial(check_limit, user_id, "notes")
                )
                if not gate["allowed"]:
                    continue

                am = AgentManager(user_id=user_id)
                try:
                    # The whole call -- ownership check, the atomic claim
                    # query, the internal blocking LLM call, and the
                    # note/context writes -- is offloaded as one executor
                    # unit so this one candidate's own connection/cursor is
                    # only ever touched by the single worker thread running
                    # it, for its full duration (see thread_safety_boundary).
                    result = await loop.run_in_executor(
                        None,
                        functools.partial(am.commit_hb_response, agent_id, heartbeat_id, prompt or "")
                    )
                finally:
                    am.close()

                if "success" not in result:
                    # "skipped" (claim already taken -- a concurrent poll cycle
                    # or a still-running client beat us to it) and "error"
                    # (LLM/parse/claim failure) both mean no push is warranted.
                    continue

                token, agent_name = await loop.run_in_executor(
                    None, functools.partial(_post_fire_lookups, agent_id, user_id)
                )
                if not token:
                    continue

                title = agent_name or "Scheduled Event"
                # No prompt/note content in the alert -- a remote push transits
                # Apple's infrastructure and is composed directly by this
                # backend, a different trust surface than the old per-device
                # local notification (which did truncate the prompt). Identify
                # the event generically in the alert; heartbeat_id/agent_id ride
                # in the payload's data for the client to resolve locally.
                ok = await send_push(
                    token,
                    title,
                    "Your agent responded to a scheduled event. Check your notes.",
                    data={"heartbeat_id": heartbeat_id, "agent_id": agent_id},
                )
                if not ok:
                    logger.warning(
                        "Heartbeat %s fired but push failed for user %s", heartbeat_id, user_id
                    )
                else:
                    # Explicit success-path log -- previously this job only
                    # logged on the failure/warning path, so "did this
                    # heartbeat actually fire, and when" had no answer from
                    # logs alone (see this task's intake spec, acceptance
                    # criteria). No prompt/note content here, matching the
                    # rest of this file's redaction posture -- heartbeat_id/
                    # agent_id/user_id only.
                    logger.info(
                        "Heartbeat fired: heartbeat=%s agent=%s user=%s",
                        heartbeat_id, agent_id, user_id,
                    )
            except Exception as e:
                logger.error("Heartbeat fire cycle error for %s: %s", heartbeat_id, e)
    except Exception as e:
        logger.error("Heartbeat scheduler job error: %s", e)
    finally:
        db.close()


async def _fire_due_session_reminders() -> None:
    """Send exactly one reminder push per session, once its ``time_start``
    arrives.

    Runs every SESSION_REMINDER_POLL_INTERVAL_SECONDS. ``time_start`` is an
    absolute TIMESTAMPTZ (not a per-user-local recurring "HH:mm" slot like
    heartbeats), so a session becomes a candidate the instant
    ``time_start <= NOW()`` and — because a session's reminder is a one-shot
    "fires once, ever" event, not a daily recurrence (the `recurring` flag
    doesn't currently drive any actual recurrence-computation; see this
    task's intake spec) — stays a candidate on every later poll cycle until
    it's actually claimed. Per the explicit precedent in
    .claude/pipeline/20260825-scheduled-event-duplicate-fire (a rolling
    time-window guard was *not* sufficient to prevent a duplicate fire for
    this same family of "fires once when a scheduled moment arrives" jobs),
    dedup here is a single atomic claim
    (``UPDATE ... WHERE reminder_sent_at IS NULL``), not a window check.
    Postgres row locking guarantees at most one concurrent ``UPDATE`` can
    match ``reminder_sent_at IS NULL`` for a given row, so this poller
    safely races itself across cycles and any concurrent poll.

    Member resolution reuses ``DevotionManager.resolve_members`` (the same
    creator/participants/group-or-DM-roster membership concept
    ``is_authorized`` already encodes) rather than a new definition, and
    device-token lookup is batched via ``device_tokens_bulk`` for the whole
    resolved set. Per-recipient push failures (no token, a transient APNs
    error) are caught and logged, never aborting the rest of the batch --
    matching every other job in this file. No session content beyond the
    title (the deliberately user-facing push-body surface, same posture as
    ``_friend_went_active_notify``) is put in a log line.

    A candidate whose ``time_start`` is older than
    ``SESSION_REMINDER_STALE_AFTER_SECONDS`` (see that constant's docstring)
    is still claimed -- the atomic claim is what makes "fired" vs
    "skipped-as-stale" mutually exclusive and permanent, exactly like the
    "fired" case -- but no push is sent for it, and a distinct INFO log
    line records the skip. A push is only ever sent for a candidate that's
    both claimed *and* within the freshness cutoff, logged with its own
    distinct INFO line on send -- so "fired" / "skipped-stale" /
    "not-yet-due" (the last simply never becoming a candidate at all) are
    each independently answerable from logs, not just correct in behavior.
    """
    import asyncio
    import functools
    from backend.interactions.devotion import DevotionManager
    from backend.interactions.push import send_push

    def _scan_candidates():
        db.cur.execute(
            "SELECT _id, time_start FROM devotions "
            "WHERE time_start IS NOT NULL AND time_start <= NOW() "
            "AND reminder_sent_at IS NULL"
        )
        return [(str(r[0]), r[1]) for r in db.cur.fetchall()]

    def _claim(session_id: str) -> bool:
        # The atomic claim itself -- this, not the scan above, is what makes
        # double-fire across repeated poll cycles/concurrent polls
        # impossible (see docstring).
        db.cur.execute(
            "UPDATE devotions SET reminder_sent_at = NOW() "
            "WHERE _id = %s AND reminder_sent_at IS NULL",
            (session_id,),
        )
        claimed = db.cur.rowcount == 1
        db.conn.commit()
        return claimed

    loop = asyncio.get_running_loop()
    db = DevotionManager()
    try:
        try:
            candidates = await loop.run_in_executor(None, _scan_candidates)
        except Exception as e:
            logger.error("Session-reminder due-scan query failed: %s", e)
            return

        for session_id, time_start in candidates:
            try:
                claimed = await loop.run_in_executor(None, functools.partial(_claim, session_id))
                if not claimed:
                    continue  # a concurrent poll cycle (or this same cycle, re-entrant) already claimed it

                staleness_seconds = (datetime.now(tzmod.utc) - time_start).total_seconds() if time_start else 0.0
                if staleness_seconds > SESSION_REMINDER_STALE_AFTER_SECONDS:
                    # Fail-closed: claimed (so it never gets rescanned), but
                    # deliberately not pushed -- an arbitrarily stale
                    # "starting now" push is worse than no push. See
                    # SESSION_REMINDER_STALE_AFTER_SECONDS's docstring for
                    # the confirmed case this guards against.
                    logger.info(
                        "Session-reminder skipped as stale: session=%s scheduled %.0fs ago (cutoff %ds)",
                        session_id, staleness_seconds, SESSION_REMINDER_STALE_AFTER_SECONDS,
                    )
                    continue

                session = await loop.run_in_executor(None, functools.partial(db.get_session, session_id))
                if not session:
                    continue
                members = await loop.run_in_executor(
                    None, functools.partial(db.resolve_members, session)
                )
                if not members:
                    continue
                tokens = await loop.run_in_executor(
                    None, functools.partial(db.device_tokens_bulk, members)
                )

                session_title = session.get("title") or ""
                body = f'"{session_title}" is starting now.' if session_title \
                    else "Your scheduled session is starting now."
                for uid in members:
                    token = tokens.get(uid)
                    if not token:
                        continue
                    try:
                        await send_push(
                            token, "Session Starting", body,
                            data={"devotion_id": session_id, "group_id": str(session.get("group_id") or "")},
                        )
                        # Explicit success-path log -- previously this job
                        # only logged on the failure path, so "did this
                        # session's reminder actually fire" had no answer
                        # from logs alone. No session title/content here,
                        # matching this file's existing redaction posture.
                        logger.info("Session-reminder fired: session=%s user=%s", session_id, uid)
                    except Exception as e:
                        logger.error("Session-reminder push failed (%s -> %s): %s", session_id, uid, e)
            except Exception as e:
                logger.error("Session-reminder fire cycle error for %s: %s", session_id, e)
    except Exception as e:
        logger.error("Session-reminder scheduler job error: %s", e)
    finally:
        db.close()


def _session_auto_delete_confirmed_call_empty(chime, chime_meeting_id: str) -> bool:
    """True only when AWS Chime confirms ``chime_meeting_id`` no longer
    exists -- i.e. Chime's own idle-meeting expiry has already reaped it,
    which only happens once every attendee has left. This is the exact
    AWS-side signal task 20260916-chime-stale-meeting-retry established
    (``routes/devotion.py``'s ``_is_meeting_not_found``), reused here rather
    than reinvented per this task's architecture decision -- this codebase
    has no attendee-roster/join-leave tracking of its own, and building one
    would be new infrastructure disproportionate to this task's scope.

    The check is duplicated (not imported) from ``routes/devotion.py``
    because this module lives in ``backend/interactions/``, and
    ``routes/`` sits *above* that layer in this codebase's one-directional
    ``routes -> backend/interactions -> Postgres`` flow (see
    ``backend-architecture`` skill) -- importing from ``routes/`` here would
    invert that direction. ``routes/messaging.py`` already carries this
    same narrow duplicate independently, so this is a third copy of an
    already-duplicated check, not a new pattern.

    Any outcome other than a confirmed ``NotFoundException`` -- the meeting
    still exists (still possibly occupied), the Chime call itself errors, or
    it times out -- is NOT confirmed empty: this fails closed to "might
    still be in call" (Security Posture Q2/Q14), mirroring
    ``DevotionManager.is_join_window_open``'s own fail-closed precedent
    exactly. A user actively joining or already connected at the exact poll
    moment is never deleted out from under them, since the only way this
    returns True is Chime itself having already torn the meeting down --
    which Chime only does once it's genuinely idle.
    """
    from botocore.exceptions import ClientError

    try:
        chime.get_meeting(MeetingId=chime_meeting_id)
        return False  # meeting still exists -- not confirmed empty
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "NotFoundException":
            return True
        logger.warning(
            "Session auto-delete presence check errored (non-NotFound) for "
            "meeting %s: %s -- failing closed (treating as possibly occupied)",
            chime_meeting_id, e,
        )
        return False
    except Exception as e:
        logger.warning(
            "Session auto-delete presence check failed for meeting %s: %s "
            "-- failing closed (treating as possibly occupied)",
            chime_meeting_id, e,
        )
        return False


def _delete_session_if_still_candidate(db, session_id: str, chime_meeting_id: str) -> bool:
    """Delete ``session_id`` ONLY if it still matches every condition that
    made it a candidate at scan/check time -- closes the TOCTOU race
    between ``_scan_candidates``/``_session_auto_delete_confirmed_call_
    empty`` (a snapshot read, moments earlier) and this delete.

    Without this re-check, a concurrent ``join-call``/``chime/.../attend``
    request racing the same poll cycle can transparently recreate a
    torn-down meeting (``_is_meeting_not_found``'s own stale-meeting-retry
    path in ``routes/devotion.py``/``routes/messaging.py``) -- exactly the
    "meeting already reaped" state this job's own presence check treats as
    confirmed-empty -- giving the row a brand-new, live ``chime_meeting_id``
    between this job's check and its delete. An unconditional
    ``DELETE ... WHERE _id = %s`` would still remove that row even though
    someone is now actively on a freshly recreated call for it, which is
    exactly the "deleted out from under them" outcome Security Posture
    Q2/Q3/Q14 and Architecture Q28 rule out. Re-verifying every candidate
    condition (recurring/time_end/grace/``chime_meeting_id``) in the same
    statement as the DELETE closes that gap the same way
    ``claim_ring_slot``'s atomic check-and-claim ``WHERE`` clause already
    does elsewhere in this codebase -- Postgres's own row lock makes the
    check-and-delete indivisible instead of two separate round trips a
    concurrent write can land between.

    Returns True only if a row was actually deleted. False means the row's
    state changed since it was checked (most importantly: a new call was
    started/recreated in the interim) or the row is already gone -- either
    way NOT an error, just a sign the row is no longer a valid candidate;
    the caller must not log this as a successful deletion.
    """
    db.cur.execute(
        "DELETE FROM devotions WHERE _id = %s "
        "AND recurring = FALSE "
        "AND time_end IS NOT NULL "
        "AND time_end <= NOW() - (%s * INTERVAL '1 second') "
        "AND chime_meeting_id = %s",
        (session_id, SESSION_AUTO_DELETE_GRACE_SECONDS, chime_meeting_id),
    )
    deleted = db.cur.rowcount > 0
    db.conn.commit()
    return deleted


async def _auto_delete_expired_sessions() -> None:
    """Delete a non-recurring session once its ``time_end`` is more than
    ``SESSION_AUTO_DELETE_GRACE_SECONDS`` in the past AND its call is
    confirmed not currently occupied -- task
    20260921-session-auto-delete-window.

    Runs every ``SESSION_AUTO_DELETE_POLL_INTERVAL_SECONDS``. Candidate
    selection (mirrors ``_fire_due_session_reminders``' own
    ``time_start <= NOW()`` DB-side clock source, never a Python-side
    ``datetime.now()``):

    - ``recurring = FALSE`` -- a recurring session is never a candidate,
      regardless of its ``time_end``; this job has no opinion on recurring
      lifecycle at all (out of this task's scope).
    - ``time_end IS NOT NULL`` -- a session with no resolvable ``time_end``
      is never a candidate. This is an explicit decision (Architecture
      Q26/Q27), not a silent fallback: unlike
      ``is_join_window_open``'s point-4 "missing time_end -> open-ended for
      joining" (a *lower*-risk direction for that gate), guessing a
      duration from ``time_start`` here would risk auto-deleting a session
      whose real end was never actually determined -- the higher-risk
      direction for a destructive delete. Skipped every cycle rather than
      guessed at; the session simply persists until it either gets a real
      ``time_end`` or is removed some other way.
    - ``time_end <= NOW() - SESSION_AUTO_DELETE_GRACE_SECONDS`` -- the
      1-hour grace period from the intake spec ("groups running long can
      still finish"), evaluated by Postgres's own ``NOW()``, not the
      calling process's clock.

    A candidate that never started a call at all (``chime_meeting_id`` is
    empty) is confirmed not-occupied without any AWS call -- there is no
    call to still be in. A candidate whose call *was* started only proceeds
    to deletion once ``_session_auto_delete_confirmed_call_empty`` confirms
    Chime has already reaped that meeting (fail-closed on any ambiguous/
    errored/timed-out check -- see that function's docstring); otherwise
    deletion is skipped this cycle and the session remains a candidate on
    the next poll, exactly like ``_fire_due_session_reminders``' own
    re-scan-until-claimed shape (there is no separate "claim" step here
    since a successful delete is itself the terminal, idempotent-enough
    action -- once deleted, the row can never reappear as a candidate).

    The actual delete is performed by ``_delete_session_if_still_candidate``,
    which re-verifies every candidate condition -- including
    ``chime_meeting_id`` still matching what was just checked -- atomically
    in the same statement as the DELETE. This closes the race window
    between this presence check and the delete itself: a concurrent
    ``join-call``/``chime/.../attend`` request that recreates a torn-down
    meeting in that window changes the row's ``chime_meeting_id``, so the
    conditional delete simply matches zero rows and the session survives to
    be re-evaluated (now genuinely occupied) on the next poll, rather than
    being removed out from under the user who just (re)joined -- see that
    function's own docstring.

    Per-session errors (a presence-check failure that isn't itself already
    handled fail-closed inside the check, or a delete-query error) are
    caught, logged, and skipped so one session's failure can't abort the
    rest of the cycle -- matching every other job in this file. Every
    deletion (and every skip because the row changed underneath the check)
    is logged with its cause (Security Posture Q11), matching
    ``_reconcile_trials``/``_run_nightly_backups``' existing logging
    conventions.
    """
    import asyncio
    import functools
    import boto3
    from backend.interactions.devotion import DevotionManager

    loop = asyncio.get_running_loop()
    db = DevotionManager()
    # A fresh client per cycle, matching this job's own fresh-manager-per-cycle
    # shape (every other job here constructs its manager inside the function,
    # not as a shared module-level singleton); boto3.client() itself makes no
    # network call, so this costs nothing per poll.
    chime = boto3.client("chime-sdk-meetings", region_name="us-east-1")

    def _scan_candidates():
        db.cur.execute(
            "SELECT _id, chime_meeting_id FROM devotions "
            "WHERE recurring = FALSE "
            "AND time_end IS NOT NULL "
            "AND time_end <= NOW() - (%s * INTERVAL '1 second')",
            (SESSION_AUTO_DELETE_GRACE_SECONDS,),
        )
        return [(str(r[0]), r[1] or "") for r in db.cur.fetchall()]

    try:
        try:
            candidates = await loop.run_in_executor(None, _scan_candidates)
        except Exception as e:
            logger.error("Session-auto-delete due-scan query failed: %s", e)
            return

        for session_id, chime_meeting_id in candidates:
            try:
                if chime_meeting_id:
                    confirmed_empty = await loop.run_in_executor(
                        None,
                        functools.partial(
                            _session_auto_delete_confirmed_call_empty, chime, chime_meeting_id
                        ),
                    )
                    if not confirmed_empty:
                        logger.info(
                            "Session-auto-delete deferred: session=%s call not "
                            "confirmed empty (meeting=%s) -- re-checking next cycle",
                            session_id, chime_meeting_id,
                        )
                        continue

                deleted = await loop.run_in_executor(
                    None,
                    functools.partial(
                        _delete_session_if_still_candidate, db, session_id, chime_meeting_id
                    ),
                )
                if not deleted:
                    # Row no longer matches what was just checked -- most
                    # likely a concurrent join recreated the meeting (new
                    # chime_meeting_id) in the gap between the presence
                    # check and this delete. Not an error: the session
                    # simply survives to be re-evaluated next cycle, now
                    # genuinely reflecting whatever changed.
                    logger.info(
                        "Session-auto-delete skipped: session=%s state changed "
                        "since check (e.g. call rejoined/recreated) -- "
                        "re-checking next cycle",
                        session_id,
                    )
                    continue
                logger.info(
                    "Session auto-deleted: session=%s reason=grace_period_elapsed"
                    "%s",
                    session_id,
                    "_call_confirmed_empty" if chime_meeting_id else "_no_call_ever_started",
                )
            except Exception as e:
                logger.error("Session-auto-delete cycle error for %s: %s", session_id, e)
    except Exception as e:
        logger.error("Session-auto-delete scheduler job error: %s", e)
    finally:
        db.close()


def _advance_time_by_one_local_week(
    session_id: str, time_start, time_end, tzname: str
) -> tuple[datetime, datetime] | None:
    """Roll ``time_start``/``time_end`` (both UTC-aware ``TIMESTAMPTZ``
    instants) forward by exactly one calendar week, computed in ``tzname``'s
    local wall-clock time -- not a raw ``timedelta(days=7)`` added directly
    to the UTC instant, which would be off by exactly the DST offset delta
    across a spring-forward/fall-back transition in that zone. The original
    duration (``time_end - time_start``) is preserved by construction:
    ``new_time_end`` is derived by adding that same duration to
    ``new_time_start`` rather than independently recomputing it, so duration
    can never drift.

    Returns ``None`` -- a fail-closed skip, never a guessed value (Security
    Posture Q2/Q14, Architecture Q27) -- if ``tzname`` doesn't resolve to a
    real IANA zone or the conversion otherwise raises. Logs via
    ``logger.exception`` on that path (matching ``is_join_window_open``'s
    own pattern) so the failure is surfaced, never silently defaulted.
    """
    try:
        zone = ZoneInfo(tzname or "UTC")
        duration = time_end - time_start
        local_start = time_start.astimezone(zone)
        # zoneinfo-aware arithmetic on the local wall-clock components:
        # advancing the naive (year, month, day, hour, minute, second,
        # microsecond) tuple by 7 days and re-attaching the same IANA zone
        # lets Python/zoneinfo resolve the correct UTC offset for the new
        # date (which may differ from the original date's offset across a
        # DST transition), rather than shifting the already-resolved UTC
        # instant by a fixed 7*86400 seconds.
        naive_next = local_start.replace(tzinfo=None) + timedelta(days=7)
        new_local_start = naive_next.replace(tzinfo=zone)
        new_time_start = new_local_start.astimezone(tzmod.utc)
        new_time_end = new_time_start + duration
        return new_time_start, new_time_end
    except Exception:
        logger.exception(
            "Session-recurring-advance failed to resolve next weekly "
            "occurrence: session=%s timezone=%r -- failing closed",
            session_id, tzname,
        )
        return None


def _recurring_advance_resolve_candidate(db, session_id: str):
    """Look up the current ``time_start``/``time_end`` and the creator's
    ``users.timezone`` for one candidate, at the moment it's about to be
    advanced -- a fresh read immediately before computing the next
    occurrence, distinct from (and always at least as recent as) the batch
    scan that found it a candidate.
    """
    db.cur.execute(
        "SELECT d.time_start, d.time_end, u.timezone "
        "FROM devotions d LEFT JOIN users u ON u._id = d.creator_id "
        "WHERE d._id = %s AND d.recurring = TRUE",
        (session_id,),
    )
    row = db.cur.fetchone()
    if not row:
        return None
    return row[0], row[1], row[2]


def _advance_recurring_session_if_still_candidate(
    db, session_id: str, expected_time_end, expected_chime_meeting_id: str,
    new_time_start: datetime, new_time_end: datetime
) -> bool:
    """Atomically advance ``session_id`` to its next weekly occurrence AND
    reset its per-occurrence state in one statement, re-verifying both
    ``time_end`` AND ``chime_meeting_id`` still match what was just read
    (``expected_time_end``/``expected_chime_meeting_id``) -- the same
    TOCTOU close ``_delete_session_if_still_candidate`` performs for the
    sibling auto-delete job, on the same table. Re-checking
    ``chime_meeting_id`` here (not just ``time_end``) is what actually makes
    the presence gate in ``_advance_recurring_sessions`` binding: without
    it, a call that gets (re)started in the window between that presence
    check and this UPDATE would still have its ``chime_meeting_id``/
    ``chime_meeting`` cleared and its session advanced out from under an
    actively-occupied call -- the exact outcome the presence gate exists to
    prevent, and the same reasoning ``_delete_session_if_still_candidate``
    already applies to its own DELETE. A ``rowcount == 0`` means another
    poll cycle already advanced this row, or a call was (re)started, since
    it was last read -- a log-and-skip for the caller, not an error.

    ``reminder_sent_at`` resets to ``NULL`` so the advanced occurrence's own
    start-time reminder push re-arms (it's otherwise a one-shot claim column
    that would never fire again for this row). ``chime_meeting_id``/
    ``chime_meeting`` reset to their own column DEFAULT values from
    ``db.py`` (``''``/``'{}'``), not NULL, so the new occurrence never
    inherits a finished call's meeting state.
    """
    db.cur.execute(
        "UPDATE devotions SET time_start = %s, time_end = %s, "
        "reminder_sent_at = NULL, chime_meeting_id = '', chime_meeting = '{}' "
        "WHERE _id = %s AND recurring = TRUE AND time_end = %s AND chime_meeting_id = %s",
        (new_time_start, new_time_end, session_id, expected_time_end, expected_chime_meeting_id),
    )
    advanced = db.cur.rowcount > 0
    db.conn.commit()
    return advanced


async def _advance_recurring_sessions() -> None:
    """Roll a ``recurring = TRUE`` session's ``time_start``/``time_end``
    forward by exactly one week, in place on the same ``devotions`` row,
    once its current occurrence has ended -- task
    20260921-recurring-session-next-occurrence. This is the natural
    counterpart to ``_auto_delete_expired_sessions``: that job explicitly
    excludes ``recurring = TRUE`` rows (they're never a delete candidate),
    and this job explicitly excludes ``recurring = FALSE`` rows (they're
    never an advance candidate) -- the two candidate queries are mutually
    exclusive by construction on the same ``recurring`` column, so the two
    jobs can never race destructively on the same row.

    Advance-in-place, not a new representation: there is no per-occurrence
    history table today, and none of this codebase's existing consumers
    (notes/transcripts/``summarize``) key off a past occurrence, so this
    overwrites the existing row's ``time_start``/``time_end`` rather than
    adding new infrastructure disproportionate to this task's scope.

    Runs every ``SESSION_RECURRING_ADVANCE_POLL_INTERVAL_SECONDS``.
    Candidate selection mirrors ``_auto_delete_expired_sessions``' own
    shape on this same table, but the opposite ``recurring`` value:
    ``recurring = TRUE AND time_end IS NOT NULL AND time_end <= NOW() -
    SESSION_RECURRING_ADVANCE_GRACE_SECONDS`` -- a NULL/unresolvable
    ``time_end`` is never a candidate (explicit fail-closed decision,
    Security Posture Q2/Q14, identical to the sibling delete job's own
    decision on the same column), not a silent duration-guess.

    Presence gate: reuses ``_session_auto_delete_confirmed_call_empty``
    exactly as-is when ``chime_meeting_id`` is set -- advancing
    ``time_start``/``time_end`` and clearing ``chime_meeting_id``/
    ``chime_meeting`` out from under an actively-occupied call would break
    that live call's session reference the same way deleting it would, so
    this job needs the identical AWS-confirmed-empty gate the sibling
    delete job established. Any ambiguous/errored/still-occupied outcome
    fails closed: skip advancing this cycle, re-check next poll.

    Weekly computation resolves the session's ``creator_id -> users.
    timezone`` (IANA name via ``zoneinfo``) -- the same per-user-local-
    timezone pattern already established by ``_fire_due_heartbeats``/
    ``_midday_no_activity_reminder``/``BackupManager.users_due_now`` for
    this exact class of problem -- and adds 7 calendar days to the local
    wall-clock date/time (see ``_advance_time_by_one_local_week``), not a
    raw ``timedelta(days=7)`` added directly to the UTC instant. A missing/
    invalid creator timezone, or any exception during that conversion, is
    an explicit fail-closed skip (``logger.exception``, matching
    ``is_join_window_open``'s own pattern -- Architecture Q27: surface the
    failure, never guess a default next-occurrence time) -- leave the row
    for the next poll cycle.

    The actual advance is performed by
    ``_advance_recurring_session_if_still_candidate``, which re-verifies
    ``time_end`` AND ``chime_meeting_id`` still match what was just read,
    atomically in the same statement as the ``UPDATE`` -- closing the same
    TOCTOU race ``_delete_session_if_still_candidate`` closes for the
    sibling job. The ``chime_meeting_id`` re-check is what makes the
    presence gate above actually binding: without it, a call (re)started
    in the window between that gate and this UPDATE would still get
    advanced-and-cleared out from under an active call. Its ``rowcount ==
    0`` case (another cycle already advanced it, or a call was (re)started
    since the check) is a log-and-skip, not an error.

    No live push/websocket notification of the advanced time is sent to an
    open client -- identical decision to
    ``20260921-session-auto-delete-window``'s equivalent open question for
    deletion: the existing session-fetch routes already return the
    freshly-advanced row on the client's next fetch.

    Per-session errors are caught, logged, and skipped so one session's
    failure can't abort the rest of the cycle -- matching every other job
    in this file. Every advance (session id, old/new ``time_start``) and
    every skip-with-cause is logged at INFO/WARNING (Security Posture Q11).
    """
    import asyncio
    import functools
    import boto3
    from backend.interactions.devotion import DevotionManager

    loop = asyncio.get_running_loop()
    db = DevotionManager()
    chime = boto3.client("chime-sdk-meetings", region_name="us-east-1")

    def _scan_candidates():
        db.cur.execute(
            "SELECT _id, chime_meeting_id FROM devotions "
            "WHERE recurring = TRUE "
            "AND time_end IS NOT NULL "
            "AND time_end <= NOW() - (%s * INTERVAL '1 second')",
            (SESSION_RECURRING_ADVANCE_GRACE_SECONDS,),
        )
        return [(str(r[0]), r[1] or "") for r in db.cur.fetchall()]

    try:
        try:
            candidates = await loop.run_in_executor(None, _scan_candidates)
        except Exception as e:
            logger.error("Session-recurring-advance due-scan query failed: %s", e)
            return

        for session_id, chime_meeting_id in candidates:
            try:
                if chime_meeting_id:
                    confirmed_empty = await loop.run_in_executor(
                        None,
                        functools.partial(
                            _session_auto_delete_confirmed_call_empty, chime, chime_meeting_id
                        ),
                    )
                    if not confirmed_empty:
                        logger.info(
                            "Session-recurring-advance deferred: session=%s call not "
                            "confirmed empty (meeting=%s) -- re-checking next cycle",
                            session_id, chime_meeting_id,
                        )
                        continue

                resolved = await loop.run_in_executor(
                    None, functools.partial(_recurring_advance_resolve_candidate, db, session_id)
                )
                if not resolved:
                    # Row is gone, or no longer recurring -- nothing to advance.
                    continue
                time_start, time_end, tzname = resolved
                if time_start is None or time_end is None:
                    logger.warning(
                        "Session-recurring-advance skipped: session=%s has an "
                        "unresolvable time_start/time_end -- failing closed",
                        session_id,
                    )
                    continue
                # A NULL tzname here means the join to `users` on
                # `creator_id` itself came back empty (no matching/live
                # creator row) -- unlike `users.timezone`'s own NOT NULL
                # DEFAULT 'UTC' constraint (which guarantees a *resolved*
                # user always has a value), this is a genuinely missing
                # creator timezone, so it's an explicit fail-closed skip
                # rather than silently defaulting to UTC.
                if not tzname:
                    logger.warning(
                        "Session-recurring-advance skipped: session=%s has no "
                        "resolvable creator timezone -- failing closed",
                        session_id,
                    )
                    continue

                # Pure in-memory computation (no I/O) -- unlike the DB/AWS
                # calls elsewhere in this loop, no run_in_executor offload
                # is needed here.
                next_occurrence = _advance_time_by_one_local_week(
                    session_id, time_start, time_end, tzname
                )
                if next_occurrence is None:
                    continue  # already logged via logger.exception above
                new_time_start, new_time_end = next_occurrence

                advanced = await loop.run_in_executor(
                    None,
                    functools.partial(
                        _advance_recurring_session_if_still_candidate,
                        db, session_id, time_end, chime_meeting_id, new_time_start, new_time_end,
                    ),
                )
                if not advanced:
                    logger.info(
                        "Session-recurring-advance skipped: session=%s state changed "
                        "since check (already advanced elsewhere) -- re-checking next cycle",
                        session_id,
                    )
                    continue
                logger.info(
                    "Session recurring-advanced: session=%s old_time_start=%s new_time_start=%s",
                    session_id, time_start, new_time_start,
                )
            except Exception as e:
                logger.error("Session-recurring-advance cycle error for %s: %s", session_id, e)
    except Exception as e:
        logger.error("Session-recurring-advance scheduler job error: %s", e)
    finally:
        db.close()


def start_scheduler() -> None:
    # The former `notify_check` cron job (agentic/custom notification firing)
    # was removed in full along with that subsystem — see
    # .claude/pipeline/20260826-activity-based-notifications. Its
    # replacement is the three activity-tracked/fixed-notification jobs
    # below (midday, guilt, friend-went-active), all delivered via the same
    # send_push/device_tokens pipeline the old subsystem used.
    #
    # Heartbeats now fire server-side too (see _fire_due_heartbeats below) --
    # the former iOS-only trigger (HeartbeatScheduler.checkAndFire on app
    # foreground) was removed; a heartbeat fires on time whether or not any
    # client ever has the app open. Fire time is resolved per-user-local
    # (users.timezone), not a fixed UTC slot -- see _fire_due_heartbeats'
    # docstring. commit_hb_response's existing calendar-day claim remains the
    # sole dedup mechanism; its day boundary is likewise now computed in the
    # owning user's local timezone rather than a fixed UTC date.
    scheduler.add_job(_run_nightly_backups, "cron", minute="*", id="backup_check",
                      replace_existing=True)
    scheduler.add_job(_fire_due_heartbeats, "interval", seconds=HEARTBEAT_POLL_INTERVAL_SECONDS,
                      id="heartbeat_fire", replace_existing=True)
    # Session time_start reminder push (task 20260904-session-push-notifications)
    # -- a real-time user-facing moment, so this polls at the same tight
    # cadence as heartbeats rather than the coarser midday/guilt cadence.
    # reminder_sent_at's atomic claim (not job frequency) is what caps each
    # session to exactly one reminder ever, regardless of poll rate.
    scheduler.add_job(_fire_due_session_reminders, "interval", seconds=SESSION_REMINDER_POLL_INTERVAL_SECONDS,
                      id="session_reminder_fire", replace_existing=True)
    # Non-recurring session auto-delete (task 20260921-session-auto-delete-
    # window): 1-hour grace period past time_end (SESSION_AUTO_DELETE_GRACE_
    # SECONDS), then a fail-closed Chime-presence gate before the actual
    # delete -- see _auto_delete_expired_sessions' own docstring.
    scheduler.add_job(_auto_delete_expired_sessions, "interval", seconds=SESSION_AUTO_DELETE_POLL_INTERVAL_SECONDS,
                      id="session_auto_delete", replace_existing=True)
    # Recurring ("Repeat weekly") session next-occurrence advance (task
    # 20260921-recurring-session-next-occurrence): the natural counterpart
    # to session_auto_delete above -- that job only ever touches
    # `recurring = FALSE` rows, this one only ever touches `recurring =
    # TRUE` rows, so the two candidate queries are mutually exclusive by
    # construction on the same `recurring` column and can never race
    # destructively on the same row. Same 1-hour grace period past
    # time_end (SESSION_RECURRING_ADVANCE_GRACE_SECONDS) and the same
    # fail-closed Chime-presence gate before advancing -- see
    # _advance_recurring_sessions' own docstring.
    scheduler.add_job(_advance_recurring_sessions, "interval", seconds=SESSION_RECURRING_ADVANCE_POLL_INTERVAL_SECONDS,
                      id="session_recurring_advance", replace_existing=True)
    # Midday/guilt reminders: a 15-minute poll is coarse enough to be cheap
    # but fine enough that the local-noon / >24h windows are never missed by
    # more than 15 minutes — each job's own dedup marker (not job frequency)
    # is what actually caps it to once per window.
    scheduler.add_job(_midday_no_activity_reminder, "cron", minute="*/15",
                      id="midday_no_activity_reminder", replace_existing=True)
    scheduler.add_job(_guilt_no_activity_reminder, "cron", minute="*/15",
                      id="guilt_no_activity_reminder", replace_existing=True)
    # Friend-went-active isn't time-of-day sensitive (it reacts to a write,
    # not a clock), so a short fixed interval is enough to make the
    # notification feel prompt without polling as tightly as the
    # once-a-minute backup job.
    scheduler.add_job(_friend_went_active_notify, "interval", minutes=5,
                      id="friend_went_active_notify", replace_existing=True)
    # Trials only change on a monthly boundary; an hourly sweep is ample and
    # cheap. Lazy reconcile on read covers the gap between sweeps.
    scheduler.add_job(_reconcile_trials, "cron", minute="5", id="trial_reconcile",
                      replace_existing=True)
    # CloudWatch error watchdog — re-enabled 2026-08-15 after the 2026-08-14
    # production incident (a8a22ecc temporarily disabled this job). Root
    # causes fixed: (1) cloudwatch_mcp_client.py::analyze_log_group now sends
    # the required log_group_arn instead of omitting it; (2) debug_agent.py
    # treats OpenRouter 401/403 as a distinct terminal DebugAgentAuthError
    # logged at WARNING, not ERROR, so an auth failure can no longer alias
    # into the watchdog's own error-signal pattern; (3) watchdog.py now
    # self-excludes log lines it and the debug agent emit about their own
    # failures (see `_watchdog_logger` above and watchdog.py's
    # `_SELF_LOGGER_NAMES`), plus a hard per-cycle circuit breaker
    # (MAX_DETECTIONS_PER_CYCLE / MAX_DEBUG_AGENT_CALLS_PER_CYCLE) caps any
    # future recurring internal failure regardless of cause. See
    # backend/monitoring/watchdog.py, cloudwatch_mcp_client.py, and
    # debug_agent.py for the fixes, and step 5's security review
    # (.claude/pipeline/20260815-cloudwatch-watchdog-memory-leak/security.json)
    # for verification that the self-exclusion filter and circuit breaker
    # can't be bypassed.
    scheduler.add_job(_run_error_watchdog, "interval", seconds=WATCHDOG_POLL_INTERVAL_SECONDS,
                      id="cloudwatch_watchdog", replace_existing=True)
    scheduler.start()
    logger.info("Notification scheduler started — checking every minute")
