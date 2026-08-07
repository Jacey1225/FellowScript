import requests
import asyncio
import functools
import logging
import uuid
from datetime import datetime
from schemas.agent import Agent, AgentMessages, AgentHeartbeats
from schemas.users import Note
import os
from pathlib import Path
from dotenv import load_dotenv
from db import DBManager
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
        self.insertion(self.agent_table, {
            "_id":     agent.id,
            "user_id": agent.user_id,
            "role":    agent.role,
            "chats":   agent.chats,
        })
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
        self.update(
            self.agent_table,
            {"role": agent.role, "chats": agent.chats},
            {"_id": agent.id, "user_id": self.user_id}
        )

    def delete_agent(self, agent_id: str) -> None:
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
        note_id = str(uuid.uuid4())
        self.insertion(self.note_table, {
            "_id":      note_id,
            "user_id":  note.user,
            "title":    note.title,
            "text":     note.text,
            "public":   note.public,
            "group_id": note.group_id or None,
            "is_reply": note.is_reply,
            "timestamp": note.timestamp,
        })
        for i, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                self.insertion("note_verses", {
                    "note_id":  note_id,
                    "position": i,
                    "book":     verse[0],
                    "chapter":  verse[1],
                    "verse":    verse[2],
                })
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

        # Idempotency guard. Both the server-side cron scheduler and the iOS
        # client's foreground checkAndFire converge here, and both fire within the
        # same minute for a given scheduled slot — which would create two notes.
        # Atomically claim the fire: the UPDATE only matches (and returns a row)
        # if this heartbeat has not fired in the last 2 minutes. Postgres row
        # locking guarantees exactly one concurrent caller wins the claim; any
        # other caller gets no row and skips. Heartbeats fire at most once per
        # day, so a 2-minute window never suppresses a legitimate fire.
        try:
            self.cur.execute(
                "UPDATE agent_heartbeats SET last_fired = NOW() "
                "WHERE _id = %s "
                "AND (last_fired IS NULL OR last_fired < NOW() - INTERVAL '2 minutes') "
                "RETURNING _id",
                (heartbeat_id,),
            )
            claimed = self.cur.fetchone()
            self.conn.commit()
        except Exception as e:
            logger.error("Heartbeat claim failed for %s: %s", heartbeat_id, e)
            self.conn.rollback()
            return {"error": "claim failed"}
        if not claimed:
            logger.info("Heartbeat %s already fired recently — skipping duplicate.", heartbeat_id)
            return {"skipped": "already fired recently"}

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
        response = self._call_api(agent_role, [{"role": "user", "content": note_prompt}])
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
        self.insertion(self.msg_table, {
            "title":     msg.title,
            "agent_id":  msg.agent_id,
            "user_id":   msg.user_id,
            "timestamp": msg.timestamp,
            "content":   msg.content,
        })

    def get_messages(self, agent_id: str) -> dict:
        return self.lookup(self.msg_table, {"agent_id": agent_id, "user_id": self.user_id})

    def delete_message(self, message_id: str) -> None:
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
        try:
            while True:
                payload      = await ws.receive_json()
                user_content = payload.get("content", "").strip()
                if not user_content:
                    continue

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
