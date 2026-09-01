import requests
import asyncio
import functools
import logging
import time
import uuid
from collections import deque
from datetime import datetime
from schemas.agent import Agent, AgentMessages, AgentHeartbeats
from schemas.users import Note
import os
from pathlib import Path
from dotenv import load_dotenv
from db import DBManager
from backend.errors import SaveFailedError
from fastapi import WebSocket
from starlette.websockets import WebSocketDisconnect
import json

load_dotenv()

logger = logging.getLogger(__name__)

MODELNAME = "deepseek/deepseek-chat"
BASEURL   = "https://openrouter.ai/api/v1/chat/completions"
HEADERS   = {
    "Authorization": f"Bearer {os.getenv('OPENROUTER_API_KEY')}",
    "Content-Type":  "application/json",
}

PROMPT = (Path(__file__).parent / "agent_prompt.txt").read_text(encoding="utf-8").strip()

# Per-connection cap on the agent chat WebSocket: every HTTP write on
# agent_router is gated by check_limit's free-tier caps, but connect_agent's
# loop had no equivalent, so a connected client could otherwise trigger
# unlimited billed OpenRouter calls (LLM10 Unbounded Consumption).
_CHAT_RATE_LIMIT_MESSAGES = 20
_CHAT_RATE_LIMIT_WINDOW_SECONDS = 60.0


class AgentManager(DBManager):
    def __init__(self, user_id: str):
        super().__init__()
        self.user_id       = user_id
        self.agent_table   = "agents"
        self.hb_table      = "agent_heartbeats"
        self.msg_table     = "agent_messages"
        self.note_table    = "notes"
        self.context_table = "agentic_context"

    # ── Agent CRUD ────────────────────────────────────────────────────────────

    def create_agent(self, agent: Agent) -> str:
        if not self.insertion(self.agent_table, {
            "_id":     agent.id,
            "user_id": agent.user_id,
            "role":    agent.role,
            "chats":   agent.chats,
        }):
            raise SaveFailedError()
        return agent.id

    def get_agent(self, agent_id: str) -> dict | None:
        result = self.lookup(self.agent_table, {"_id": agent_id})
        if not result:
            return None
        return result

    def owns_agent(self, agent_id: str) -> bool:
        """True if ``agent_id`` belongs to ``self.user_id``. Callers that take
        a bare agent_id from the URL/body must check this before reading or
        acting on it — the id alone is not proof of ownership."""
        return bool(self.lookup(self.agent_table, {"_id": agent_id, "user_id": self.user_id}))

    def get_user_agents(self) -> dict:
        return self.lookup(self.agent_table, {"user_id": self.user_id})

    def update_agent(self, agent: Agent) -> None:
        if not self.update(
            self.agent_table,
            {"role": agent.role, "chats": agent.chats},
            {"_id": agent.id, "user_id": self.user_id}
        ):
            raise SaveFailedError()

    def delete_agent(self, agent_id: str) -> None:
        # The WHERE clause enforces ownership itself (unlike other deletes
        # in this file, no separate owns_agent()/lookup precedes this) --
        # a caller-not-owner and an already-deleted agent both come back as
        # a zero-rows False, and neither should raise: the route intends a
        # 204 either way rather than leaking which case it was. A real DB
        # error is still visible via db.py's DB_WRITE_FAILURE log line.
        self.delete(self.agent_table, {"_id": agent_id, "user_id": self.user_id})

    # ── Heartbeat CRUD ────────────────────────────────────────────────────────

    def add_heartbeat(self, heartbeat: AgentHeartbeats) -> None:
        hb_id = str(uuid.uuid4())
        try:
            self.cur.execute(
                "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) "
                "VALUES (%s, %s, %s, %s::jsonb, %s)",
                (hb_id, heartbeat.agent_id, heartbeat.user_id,
                 json.dumps(heartbeat.timestamps), heartbeat.prompt)
            )
            self.conn.commit()
        except Exception as e:
            logger.error("Error adding heartbeat: %s", e)
            self.conn.rollback()

    def get_heartbeats(self, agent_id: str) -> list[dict]:
        result = self.lookup(self.hb_table, {"agent_id": agent_id, "user_id": self.user_id})
        return [{"_id": k, **v} for k, v in result.items()]

    def update_heartbeat(self, heartbeat_id: str, heartbeat: AgentHeartbeats) -> None:
        try:
            self.cur.execute(
                "UPDATE agent_heartbeats SET timestamps = %s::jsonb, prompt = %s "
                "WHERE _id = %s AND user_id = %s",
                (json.dumps(heartbeat.timestamps), heartbeat.prompt, heartbeat_id, self.user_id)
            )
            self.conn.commit()
        except Exception as e:
            logger.error("Error updating heartbeat %s: %s", heartbeat_id, e)
            self.conn.rollback()

    def delete_heartbeat(self, heartbeat_id: str) -> None:
        # Same idempotent/ownership-via-WHERE reasoning as delete_agent above.
        self.delete(self.hb_table, {"_id": heartbeat_id, "user_id": self.user_id})

    def note_via_hb(self, data: dict) -> str:
        note = Note(
            user=self.user_id,
            title=data.get("title", ""),
            text=data.get("text", ""),
            public=data.get("public", False),
            group_id=data.get("group_id", ""),
            verses=data.get("verses", [])
        )
        # Historically the exact silent-fake-success case this workflow
        # exists to remove: db.py's create_tables() comment on the
        # `agents` table records a prior incident where a missing column
        # made this INSERT fail, insertion() swallowed it, and the caller
        # (commit_hb_response, via routes/agent.py's commit_heartbeat)
        # still reported success with a generated id even though no note
        # was ever persisted.
        note_id = str(uuid.uuid4())
        if not self.insertion(self.note_table, {
            "_id":      note_id,
            "user_id":  note.user,
            "title":    note.title,
            "text":     note.text,
            "public":   note.public,
            "group_id": note.group_id or None,
            "is_reply": note.is_reply,
            "timestamp": note.timestamp,
        }):
            raise SaveFailedError()
        for i, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                if not self.insertion("note_verses", {
                    "note_id":  note_id,
                    "position": i,
                    "book":     verse[0],
                    "chapter":  verse[1],
                    "verse":    verse[2],
                }):
                    raise SaveFailedError()
        return note_id

    def save_context(self, heartbeat_id: str, context_text: str, note_id: str | None = None) -> None:
        try:
            self.cur.execute(
                "INSERT INTO agentic_context (_id, heartbeat_id, user_id, note_id, context) "
                "VALUES (%s, %s, %s, %s, %s)",
                (str(uuid.uuid4()), heartbeat_id, self.user_id, note_id, [context_text])
            )
            self.conn.commit()
        except Exception as e:
            logger.error("Error saving context: %s", e)
            self.conn.rollback()

    def get_context(self, heartbeat_id: str) -> list[str]:
        try:
            self.cur.execute(
                "SELECT context FROM agentic_context "
                "WHERE heartbeat_id = %s AND user_id = %s ORDER BY ctid",
                (heartbeat_id, self.user_id)
            )
            rows = self.cur.fetchall()
            result = []
            for (ctx_array,) in rows:
                if ctx_array:
                    result.extend(ctx_array)
            return result
        except Exception as e:
            logger.error("Error getting context: %s", e)
            self.conn.rollback()
            return []

    def commit_hb_response(self, agent_id: str, heartbeat_id: str, heartbeat_content: str):
        # Ownership guard: heartbeat_id/agent_id come straight off the URL, so
        # confirm both belong to self.user_id before claiming the fire or
        # spending an LLM call on someone else's heartbeat.
        owned = self.lookup(self.hb_table, {"_id": heartbeat_id, "agent_id": agent_id, "user_id": self.user_id})
        if not owned:
            return {"error": "heartbeat not found"}

        # Idempotency guard. Heartbeats can now fire from either the
        # server-side poller (scheduler.py::_fire_due_heartbeats) or a
        # still-running/older client's own call to this route, so more than
        # one caller for the same heartbeat on the same day is an expected
        # case to guard against, not just a stubborn single client
        # foregrounding repeatedly.
        #
        # A rolling time window (previously 2 minutes) cannot enforce "at
        # most once per day": once more time than the window has elapsed
        # since the first fire, a same-day reopen claims again and produces
        # a second note. The durable invariant is a calendar-day boundary,
        # not a rolling duration, so claim atomically based on whether
        # last_fired already falls on today's date.
        #
        # That calendar-day boundary is computed in the owning user's own
        # local timezone (users.timezone — the same IANA field the nightly
        # backup job already reads via BackupManager.users_due_now), not a
        # fixed UTC date: heartbeats are meant to fire against each user's
        # own clock (per the timezone_handling revision), so "today" for the
        # purpose of this claim must mean the same "today" the poller used
        # to decide the heartbeat was due. Falls back to 'UTC' via COALESCE
        # if a user row somehow has no timezone set, matching every other
        # per-user-timezone job's default. Postgres row locking still
        # guarantees exactly one concurrent caller wins the claim; any other
        # caller (same instant or same local day) gets no row and skips.
        try:
            self.cur.execute(
                "UPDATE agent_heartbeats SET last_fired = NOW() "
                "FROM users "
                "WHERE agent_heartbeats._id = %s "
                "AND users._id = %s "
                "AND (agent_heartbeats.last_fired IS NULL "
                "OR (agent_heartbeats.last_fired AT TIME ZONE COALESCE(users.timezone, 'UTC'))::date "
                "< (NOW() AT TIME ZONE COALESCE(users.timezone, 'UTC'))::date) "
                "RETURNING agent_heartbeats._id",
                (heartbeat_id, self.user_id),
            )
            claimed = self.cur.fetchone()
            self.conn.commit()
        except Exception as e:
            logger.error("Heartbeat claim failed for %s: %s", heartbeat_id, e)
            self.conn.rollback()
            return {"error": "claim failed"}
        if not claimed:
            logger.info("Heartbeat %s already fired today — skipping duplicate.", heartbeat_id)
            return {"skipped": "already fired today"}

        result     = self.lookup(self.agent_table, {"_id": agent_id})
        agent_role = list(result.values())[0].get("role", "") if result else ""
        context    = self.get_context(heartbeat_id)
        if context:
            context_str = "\n".join(f"- {c}" for c in context)
            dedup_instruction = (
                "IMPORTANT: Every item above is a note you already wrote for this exact "
                "recurring event. Your new note must be clearly different from all of them — "
                "do not reuse the same title, opening line, scripture reference, or central "
                "theme as any note listed above. Choose a fresh angle, passage, or "
                "reflection point this time.\n\n"
            )
        else:
            context_str = "No previous context — this is the first response for this event."
            dedup_instruction = ""
        note_prompt = (
            f"{heartbeat_content}\n\n"
            f"Previous notes you already wrote for this event:\n{context_str}\n\n"
            f"{dedup_instruction}"
            "Respond with a create_note JSON block as specified in your instructions. "
            "Output only the JSON block and nothing else."
        )
        try:
            response = self._call_api(agent_role, [{"role": "user", "content": note_prompt}])
        except Exception as e:
            # Mirror connect_agent's handling of the same call: the claim
            # above already committed, so an unhandled failure here would
            # permanently burn today's fire slot with no note produced and
            # no way to retry (commit_hb_response's own idempotency guard
            # would report "already fired today" on any later attempt).
            # Unset the claim so a retry can go through.
            logger.error("OpenRouter API error in commit_hb_response for heartbeat %s: %s", heartbeat_id, e)
            try:
                self.cur.execute(
                    "UPDATE agent_heartbeats SET last_fired = NULL WHERE _id = %s",
                    (heartbeat_id,),
                )
                self.conn.commit()
            except Exception as rollback_err:
                logger.error("Failed to unset heartbeat claim for %s: %s", heartbeat_id, rollback_err)
                self.conn.rollback()
            return {"error": "I'm having trouble connecting right now. Please try again in a moment."}
        if "{" in response and "}" in response:
            start = response.find("{")
            end   = response.rfind("}") + 1
            json_str = response[start:end]
            try:
                response_dict = json.loads(json_str)
            except (json.JSONDecodeError, ValueError) as e:
                logger.error("JSON parse error in commit_hb_response: %s | raw: %.200s", e, json_str)
                return {"error": "invalid response"}
            if response_dict.get("__action", "") == "create_note":
                new_note_id = self.note_via_hb(response_dict)
                note_summary = f"{response_dict.get('title', '')}: {response_dict.get('text', '')[:300]}"
                # Linking context to note_id means deleting the note (from any
                # path) cascades this context row away too — see the FK on
                # agentic_context in db.py.
                self.save_context(heartbeat_id, note_summary, new_note_id)
                return {"success": "saved note"}
            else:
                return {"error": "cannot find action"}
        else:
            return {"error": "invalid response"}
    # ── Messages CRUD ─────────────────────────────────────────────────────────

    def save_agent_message(self, msg: AgentMessages) -> None:
        """Raises:
            SaveFailedError: If the write fails. ``connect_agent``'s WS loop
                (the only live caller) already wraps its whole message-
                handling loop in a broad ``except Exception`` that logs and
                closes the socket -- this propagates into that existing
                handler rather than needing its own.
        """
        if not self.insertion(self.msg_table, {
            "title":     msg.title,
            "agent_id":  msg.agent_id,
            "user_id":   msg.user_id,
            "timestamp": msg.timestamp,
            "content":   msg.content,
        }):
            raise SaveFailedError()

    def get_messages(self, agent_id: str) -> dict:
        return self.lookup(self.msg_table, {"agent_id": agent_id, "user_id": self.user_id})

    def delete_message(self, message_id: str) -> None:
        # Same idempotent/ownership-via-WHERE reasoning as delete_agent above.
        self.delete(self.msg_table, {"_id": message_id, "user_id": self.user_id})

    # ── AI Chat ───────────────────────────────────────────────────────────────

    def _call_api(self, agent_role: str, messages: list[dict]) -> str:
        system_content = PROMPT
        if agent_role:
            system_content += f"\n\nADDITIONAL AGENT INSTRUCTIONS:\n{agent_role}"
        body = {
            "model":      MODELNAME,
            "messages":   [{"role": "system", "content": system_content}] + messages,
            "max_tokens": 2048,
        }
        resp = requests.post(BASEURL, headers=HEADERS, json=body, timeout=60)
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]

    def chat(self, agent_id: str, user_content: str) -> str:
        result     = self.lookup(self.agent_table, {"_id": agent_id})
        agent_role = list(result.values())[0].get("role", "") if result else ""
        now = datetime.now()
        self.save_agent_message(AgentMessages(
            chat_id="", agent_id=agent_id, user_id=self.user_id,
            content=user_content, title="user", timestamp=now
        ))
        response_text = self._call_api(agent_role, [{"role": "user", "content": user_content}])
        if "{" in response_text:
            end = response_text.find("{")
            response_text = response_text[:end]
        self.save_agent_message(AgentMessages(
            chat_id="", agent_id=agent_id, user_id=self.user_id,
            content=response_text, title="assistant", timestamp=now
        ))
        return response_text

    async def connect_agent(self, agent_id: str, ws: WebSocket) -> None:
        await ws.accept()
        if not self.owns_agent(agent_id):
            # agent_id is caller-supplied in the URL; without this, any
            # authenticated user could chat through (and read the private
            # persona/role prompt of) an agent they don't own.
            await ws.close(code=4403)
            return
        loop = asyncio.get_running_loop()
        agent_data = self.get_agent(agent_id) or {}
        agent_role = list(agent_data.values())[0].get("role", "") if agent_data else ""
        # Sliding window of recent message timestamps, scoped to this one
        # connection (one per user_id/agent_id pair -- see agent_ws_endpoint).
        message_times: deque[float] = deque()
        try:
            while True:
                payload      = await ws.receive_json()
                user_content = payload.get("content", "").strip()
                if not user_content:
                    continue

                now_monotonic = time.monotonic()
                while message_times and now_monotonic - message_times[0] > _CHAT_RATE_LIMIT_WINDOW_SECONDS:
                    message_times.popleft()
                if len(message_times) >= _CHAT_RATE_LIMIT_MESSAGES:
                    await ws.send_json({
                        "role":      "error",
                        "content":   "You're sending messages too quickly. Please wait a moment and try again.",
                        "agent_id":  agent_id,
                        "timestamp": str(datetime.now()),
                    })
                    continue
                message_times.append(now_monotonic)

                user_ts = datetime.now()
                # Persist user turn immediately so it survives even if the API call fails
                self.save_agent_message(AgentMessages(
                    chat_id="", agent_id=agent_id, user_id=self.user_id,
                    content=user_content, title="user", timestamp=user_ts
                ))

                try:
                    response_text = await loop.run_in_executor(
                        None,
                        functools.partial(
                            self._call_api,
                            agent_role,
                            [{"role": "user", "content": user_content}]
                        )
                    )
                except Exception as api_err:
                    logger.error("OpenRouter API error for agent %s: %s", agent_id, api_err)
                    await ws.send_json({
                        "role":      "error",
                        "content":   "I'm having trouble connecting right now. Please try again in a moment.",
                        "agent_id":  agent_id,
                        "timestamp": str(user_ts),
                    })
                    continue

                assistant_ts = datetime.now()
                self.save_agent_message(AgentMessages(
                    chat_id="", agent_id=agent_id, user_id=self.user_id,
                    content=response_text, title="assistant", timestamp=assistant_ts
                ))

                await ws.send_json({
                    "role":      "assistant",
                    "content":   response_text,
                    "agent_id":  agent_id,
                    "timestamp": str(assistant_ts),
                })

        except WebSocketDisconnect:
            logger.info("Agent WS disconnected: agent=%s user=%s", agent_id, self.user_id)
        except Exception as e:
            logger.error("Agent WS error: agent=%s user=%s error=%s", agent_id, self.user_id, e)
            try:
                await ws.close()
            except Exception:
                pass
