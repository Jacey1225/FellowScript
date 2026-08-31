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
    """
    from backend.interactions.activity import ActivityManager
    from backend.interactions.push import send_push

    am = ActivityManager()
    try:
        pending = am.pending_friend_notifications()
        # Batch the friend/device-token lookup for the whole pending set in
        # one query instead of one per transitioning user — this set is
        # usually small (only users who just became active since the job's
        # last 5-minute run), but batching costs nothing when convenient.
        tokens_by_user: dict[str, list[tuple[str, str]]] = {}
        for user_id, friend_id, token in am.friend_device_tokens_bulk(
            [user_id for user_id, _, _ in pending]
        ):
            tokens_by_user.setdefault(str(user_id), []).append((friend_id, token))

        for user_id, username, became_active_at in pending:
            for friend_id, token in tokens_by_user.get(str(user_id), []):
                if not token:
                    continue
                try:
                    await send_push(token, "Friend Activity", f"{username} just came back to FellowScript.")
                except Exception as e:
                    logger.error("Friend-went-active push failed (%s -> %s): %s", user_id, friend_id, e)
            am.mark_friends_notified(user_id, became_active_at)
    except Exception as e:
        logger.error("Friend-went-active job error: %s", e)
    finally:
        am.close()


def start_scheduler() -> None:
    # The former `notify_check` cron job (agentic/custom notification firing)
    # was removed in full along with that subsystem — see
    # .claude/pipeline/20260826-activity-based-notifications. Its
    # replacement is the three activity-tracked/fixed-notification jobs
    # below (midday, guilt, friend-went-active), all delivered via the same
    # send_push/device_tokens pipeline the old subsystem used.
    #
    # Heartbeats are fired client-side only (iOS HeartbeatScheduler.checkAndFire
    # on app foreground) — no server-side cron job for them.
    scheduler.add_job(_run_nightly_backups, "cron", minute="*", id="backup_check",
                      replace_existing=True)
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
