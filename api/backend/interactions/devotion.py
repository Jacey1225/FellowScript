import json
from db import DBManager
from schemas.devotion import DevotionPlan


class DevotionManager(DBManager):
    """Handles all devotion session data operations."""

    def save_devotion(self, devotion: DevotionPlan) -> str:
        self.cur.execute(
            "INSERT INTO devotions (_id, title, time_start, time_end, recurring, "
            "group_id, creator_id, participants, verses, prompts, chime_meeting_id, chime_meeting) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
            (devotion.id, devotion.title,
             devotion.time_start or None, devotion.time_end or None,
             devotion.recurring,
             devotion.group_id or None, devotion.creator_id or None,
             devotion.participants, devotion.verses, devotion.prompts,
             devotion.chime_meeting_id, json.dumps(devotion.chime_meeting))
        )
        self.conn.commit()
        return devotion.id

    def read_devotion(self, devotion_id: str) -> DevotionPlan | None:
        result = self.lookup("devotions", {"_id": devotion_id})
        if not result:
            return None
        _, data = list(result.items())[0]
        return self._to_plan(devotion_id, data)

    def remove_devotion(self, devotion_id: str) -> None:
        self.delete("devotions", {"_id": devotion_id})

    def fetch_by_contact(self, contact_id: str, viewer_id: str | None = None) -> list[dict]:
        result = self.lookup("devotions", {"group_id": contact_id})
        sessions = [{"id": did, **data} for did, data in result.items()]
        if viewer_id:
            # Guideline 1.2: hide devotions created by someone in a blocked
            # relationship with the viewer, either direction.
            self.cur.execute(
                "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
                "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s",
                (viewer_id, viewer_id),
            )
            blocked = {str(r[0]) for r in self.cur.fetchall()}
            sessions = [s for s in sessions if str(s.get("creator_id")) not in blocked]
        return sessions

    def add_participant(self, session_id: str, user_id: str) -> None:
        self.cur.execute(
            "UPDATE devotions SET participants = array_append(participants, %s) "
            "WHERE _id = %s AND NOT (%s = ANY(participants))",
            (user_id, session_id, user_id)
        )
        self.conn.commit()

    def remove_participant(self, session_id: str, user_id: str) -> None:
        self.cur.execute(
            "UPDATE devotions SET participants = array_remove(participants, %s) WHERE _id = %s",
            (user_id, session_id)
        )
        self.conn.commit()

    def update_devotion(self, session_id: str, devotion: DevotionPlan) -> bool:
        existing = self.lookup("devotions", {"_id": session_id})
        if not existing:
            return False
        _, ex = list(existing.items())[0]
        self.cur.execute(
            "UPDATE devotions SET title=%s, time_start=%s, time_end=%s, recurring=%s, "
            "group_id=%s, creator_id=%s, verses=%s, prompts=%s WHERE _id=%s",
            (devotion.title,
             devotion.time_start or None, devotion.time_end or None,
             devotion.recurring,
             devotion.group_id or None, devotion.creator_id or None,
             devotion.verses, devotion.prompts,
             session_id)
        )
        self.conn.commit()
        return True

    def save_chime_meeting(self, session_id: str, meeting_id: str, meeting_data: dict) -> None:
        self.cur.execute(
            "UPDATE devotions SET chime_meeting_id=%s, chime_meeting=%s WHERE _id=%s",
            (meeting_id, json.dumps(meeting_data), session_id)
        )
        self.conn.commit()

    def get_session(self, session_id: str) -> dict:
        result = self.lookup("devotions", {"_id": session_id})
        if not result:
            return {}
        did, data = list(result.items())[0]
        return {"id": did, **data}

    def _to_plan(self, devotion_id: str, data: dict) -> DevotionPlan:
        chime = data.get("chime_meeting")
        if isinstance(chime, str):
            chime = json.loads(chime)
        return DevotionPlan(
            id=devotion_id,
            title=data.get("title", ""),
            time_start=str(data.get("time_start") or ""),
            time_end=str(data.get("time_end") or ""),
            recurring=data.get("recurring", False),
            group_id=str(data.get("group_id") or ""),
            creator_id=str(data.get("creator_id") or ""),
            participants=data.get("participants") or [],
            verses=data.get("verses") or [],
            prompts=data.get("prompts") or [],
            chime_meeting_id=data.get("chime_meeting_id", ""),
            chime_meeting=chime or {},
        )
