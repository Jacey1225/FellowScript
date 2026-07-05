import logging
from datetime import datetime
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from db import DBManager
from backend.interactions.push import send_push
from backend.interactions.notifications import NotificationManager

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
            ok = await send_push(token, name or "FellowScript", content)
            logger.info("Push %s → %s (%s)", notif_id, token[:8], "ok" if ok else "fail")
        except Exception as e:
            logger.error("Failed to fire notification %s: %s", notif_id, e)


def start_scheduler() -> None:
    scheduler.add_job(_fire_due_notifications, "cron", minute="*", id="notify_check",
                      replace_existing=True)
    scheduler.start()
    logger.info("Notification scheduler started — checking every minute")
