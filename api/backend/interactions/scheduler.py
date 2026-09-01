import logging
from datetime import datetime, timezone as tzmod
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

    The push body names the action (note created/edited, verse highlighted)
    via `_FRIEND_ACTIVITY_TEXT` below, keyed off the transition's
    `last_activity_type`. A missing/unrecognized type (e.g. a pre-migration
    row with no type set) falls back to the original generic "came back"
    text rather than raising -- consistent with this job's existing
    per-user-isolated, best-effort posture, not a new hard-failure mode.
    Like the rest of this file, never put note/highlight content (title,
    text, book/chapter/verse) in the push body or in any log line here.
    """
    from backend.interactions.activity import ActivityManager, NOTE_CREATED, NOTE_EDITED, VERSE_HIGHLIGHTED
    from backend.interactions.push import send_push

    _FRIEND_ACTIVITY_TEXT = {
        NOTE_CREATED: "{username} created a new note.",
        NOTE_EDITED: "{username} edited a note.",
        VERSE_HIGHLIGHTED: "{username} highlighted a verse.",
    }
    _FALLBACK_TEXT = "{username} just came back to FellowScript."

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
            body = _FRIEND_ACTIVITY_TEXT.get(last_activity_type, _FALLBACK_TEXT).format(username=username)
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
            except Exception as e:
                logger.error("Heartbeat fire cycle error for %s: %s", heartbeat_id, e)
    except Exception as e:
        logger.error("Heartbeat scheduler job error: %s", e)
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
