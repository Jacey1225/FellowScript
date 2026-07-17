import logging
from datetime import datetime
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from db import DBManager
from backend.interactions.push import send_push
from backend.interactions.notifications import NotificationManager
from backend.interactions.agent import AgentManager
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


async def _fire_due_heartbeats() -> None:
    now          = datetime.now()
    slot_idx     = str(now.day - 1)
    current_time = now.strftime("%H:%M")

    db = DBManager()
    try:
        db.cur.execute(
            """
            SELECT _id, agent_id, user_id, prompt
            FROM   agent_heartbeats
            WHERE  timestamps->>%s = %s
            """,
            (slot_idx, current_time),
        )
        rows = db.cur.fetchall()
    except Exception as e:
        logger.error("Heartbeat scheduler DB error: %s", e)
        return
    finally:
        db.close()

    for hb_id, agent_id, user_id, prompt in rows:
        try:
            import asyncio, functools
            am     = AgentManager(user_id)
            loop   = asyncio.get_running_loop()
            result = await loop.run_in_executor(
                None, functools.partial(am.commit_hb_response, agent_id, hb_id, prompt)
            )
            am.close()
            logger.info("Heartbeat %s fired → %s", hb_id, result)
        except Exception as e:
            logger.error("Failed to fire heartbeat %s: %s", hb_id, e)


async def _reconcile_trials() -> None:
    """Flip subscriptions whose free trial has elapsed from trialing → active."""
    sm = SubscriptionsManager()
    try:
        n = sm.reconcile_expired_trials()
        if n:
            logger.info("Reconciled %d expired trial(s) → active", n)
    except Exception as e:
        logger.error("Trial reconcile error: %s", e)
    finally:
        sm.close()


def start_scheduler() -> None:
    scheduler.add_job(_fire_due_notifications, "cron", minute="*", id="notify_check",
                      replace_existing=True)
    scheduler.add_job(_fire_due_heartbeats, "cron", minute="*", id="heartbeat_check",
                      replace_existing=True)
    # Trials only change on a monthly boundary; an hourly sweep is ample and
    # cheap. Lazy reconcile on read covers the gap between sweeps.
    scheduler.add_job(_reconcile_trials, "cron", minute="5", id="trial_reconcile",
                      replace_existing=True)
    scheduler.start()
    logger.info("Notification scheduler started — checking every minute")
