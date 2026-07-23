import logging
from datetime import datetime, timedelta, timezone as tzmod
from zoneinfo import ZoneInfo
from db import DBManager, BACKUP_DB_NAME

logger = logging.getLogger(__name__)


class BackupManager:
    """Mirrors one user's data from the primary DB into the separate backup DB.

    Holds two connections at once: ``source`` (the live "fellowscript" DB, read
    only here) and ``dest`` (the standalone backup DB, write only here). Kept
    deliberately simple — tables with a real last-modified timestamp (notes)
    are filtered to the last 24h; tables with no timestamp at all (highlights,
    bookmarks) are fully re-synced each run since there's no way to tell what's
    "new" in them, and they're small enough that this is cheap.
    """

    def __init__(self) -> None:
        self.source = DBManager()
        self.dest = DBManager(dbname=BACKUP_DB_NAME)

    def close(self) -> None:
        self.source.close()
        self.dest.close()

    def users_due_now(self, now_utc: datetime | None = None) -> list[str]:
        """user_ids whose local time is currently in the 03:00 minute.

        Called once per minute by the scheduler; a user is "due" for exactly
        one of these calls per day (their timezone's 03:00-03:00:59 window).
        ``now_utc`` is injectable so tests can assert against a fixed instant
        instead of the real wall clock.
        """
        self.source.cur.execute("SELECT _id, timezone FROM users")
        now_utc = now_utc or datetime.now(tzmod.utc)
        due = []
        for uid, tzname in self.source.cur.fetchall():
            try:
                local = now_utc.astimezone(ZoneInfo(tzname or "UTC"))
            except Exception:
                logger.warning("Skipping user %s — invalid timezone %r", uid, tzname)
                continue
            if local.hour == 3 and local.minute == 0:
                due.append(str(uid))
        return due

    def backup_user(self, user_id: str) -> dict:
        """Copy user_id's profile row, last-24h notes/verses, and full
        highlights/bookmarks into the backup DB. Returns row counts per table.
        """
        since = datetime.now(tzmod.utc) - timedelta(days=1)
        now = datetime.now(tzmod.utc)
        counts = {"notes": 0, "note_verses": 0, "highlights": 0, "bookmarks": 0}

        self.source.cur.execute(
            "SELECT username, email, timezone FROM users WHERE _id = %s", (user_id,)
        )
        row = self.source.cur.fetchone()
        if not row:
            return {"error": "user not found"}
        username, email, tzname = row
        self.dest.insertion(
            "users",
            {"_id": user_id, "username": username, "email": email,
             "timezone": tzname, "backed_up_at": now},
            conflict="(_id) DO UPDATE SET username=EXCLUDED.username, "
                     "email=EXCLUDED.email, timezone=EXCLUDED.timezone, "
                     "backed_up_at=EXCLUDED.backed_up_at",
        )

        # Notes created or edited in the last day (timestamp bumps on both).
        self.source.cur.execute(
            "SELECT _id, user_id, title, text, public, group_id, is_reply, "
            "parent_note_id, timestamp, created_at FROM notes "
            "WHERE user_id = %s AND timestamp >= %s",
            (user_id, since),
        )
        note_rows = self.source.cur.fetchall()
        note_ids = []
        for (nid, uid, title, text, public, group_id, is_reply,
             parent_note_id, ts, created_at) in note_rows:
            note_ids.append(nid)
            self.dest.insertion(
                "notes",
                {"_id": nid, "user_id": uid, "title": title, "text": text,
                 "public": public, "group_id": group_id, "is_reply": is_reply,
                 "parent_note_id": parent_note_id, "timestamp": ts,
                 "created_at": created_at, "backed_up_at": now},
                conflict="(_id) DO UPDATE SET title=EXCLUDED.title, "
                         "text=EXCLUDED.text, public=EXCLUDED.public, "
                         "group_id=EXCLUDED.group_id, is_reply=EXCLUDED.is_reply, "
                         "parent_note_id=EXCLUDED.parent_note_id, "
                         "timestamp=EXCLUDED.timestamp, created_at=EXCLUDED.created_at, "
                         "backed_up_at=EXCLUDED.backed_up_at",
            )
        counts["notes"] = len(note_ids)

        for nid in note_ids:
            self.source.cur.execute(
                "SELECT note_id, position, book, chapter, verse "
                "FROM note_verses WHERE note_id = %s",
                (nid,),
            )
            for (note_id, position, book, chapter, verse) in self.source.cur.fetchall():
                self.dest.insertion(
                    "note_verses",
                    {"note_id": note_id, "position": position, "book": book,
                     "chapter": chapter, "verse": verse},
                    conflict="(note_id, position) DO UPDATE SET book=EXCLUDED.book, "
                             "chapter=EXCLUDED.chapter, verse=EXCLUDED.verse",
                )
                counts["note_verses"] += 1

        # No modification timestamp exists on these tables at all, so mirror
        # the user's full current set rather than a "changed since" filter.
        self.source.cur.execute(
            "SELECT key, color FROM highlights WHERE user_id = %s", (user_id,)
        )
        for key, color in self.source.cur.fetchall():
            self.dest.insertion(
                "highlights",
                {"user_id": user_id, "key": key, "color": color, "backed_up_at": now},
                conflict="(user_id, key) DO UPDATE SET color=EXCLUDED.color, "
                         "backed_up_at=EXCLUDED.backed_up_at",
            )
            counts["highlights"] += 1

        self.source.cur.execute(
            "SELECT key, label FROM bookmarks WHERE user_id = %s", (user_id,)
        )
        for key, label in self.source.cur.fetchall():
            self.dest.insertion(
                "bookmarks",
                {"user_id": user_id, "key": key, "label": label, "backed_up_at": now},
                conflict="(user_id, key) DO UPDATE SET label=EXCLUDED.label, "
                         "backed_up_at=EXCLUDED.backed_up_at",
            )
            counts["bookmarks"] += 1

        return counts
