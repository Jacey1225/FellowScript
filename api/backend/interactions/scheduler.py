import logging
from datetime import datetime
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from db import DBManager
from backend.interactions.push import send_push
from backend.interactions.notifications import NotificationManager
from backend.subscription.subscriptions import SubscriptionsManager

logger = logging.getLogger(__name__)
scheduler = AsyncIOScheduler()


async def _fire_due_notifications() -> None:
    now          = datetime.now()
    slot_idx     = str(now.day - 1)          # 0-indexed slot for today (0 = day 1)
    current_time = now.strftime("%H:%M")

    db = DBManager()
    try:
        db.cur.execute(
            """
            SELECT n._id, n.user_id, n.name, n.prompt, d.token
            FROM   notifications n
            JOIN   device_tokens d ON d.user_id = n.user_id
            WHERE  n.timestamps->>%s = %s
            """,
            (slot_idx, current_time),
        )
        rows = db.cur.fetchall()
    except Exception as e:
        logger.error("Scheduler DB error: %s", e)
        return
    finally:
        db.close()

    for notif_id, user_id, name, prompt, token in rows:
        try:
            nm      = NotificationManager(user_id)
            content = nm.get_content(prompt)
            nm.close()
            # Never push the raw prompt or the "error" sentinel — use a neutral
            # user-facing fallback if AI content couldn't be generated.
            if not content or content == "error":
                content = f"{name} — open FellowScript to view." if name else "Open FellowScript for your reminder."
            ok = await send_push(token, name or "FellowScript", content)
            logger.info("Push %s → %s (%s)", notif_id, token[:8], "ok" if ok else "fail")
        except Exception as e:
            logger.error("Failed to fire notification %s: %s", notif_id, e)


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


def start_scheduler() -> None:
    scheduler.add_job(_fire_due_notifications, "cron", minute="*", id="notify_check",
                      replace_existing=True)
    # Heartbeats are fired client-side only (iOS HeartbeatScheduler.checkAndFire
    # on app foreground) — no server-side cron job for them.
    scheduler.add_job(_run_nightly_backups, "cron", minute="*", id="backup_check",
                      replace_existing=True)
    # Trials only change on a monthly boundary; an hourly sweep is ample and
    # cheap. Lazy reconcile on read covers the gap between sweeps.
    scheduler.add_job(_reconcile_trials, "cron", minute="5", id="trial_reconcile",
                      replace_existing=True)
    scheduler.start()
    logger.info("Notification scheduler started — checking every minute")
