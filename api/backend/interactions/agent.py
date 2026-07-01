import requests
import asyncio
import functools
import logging
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

    def get_user_agents(self) -> dict:
        return self.lookup(self.agent_table, {"user_id": self.user_id})

    def update_agent(self, agent: Agent) -> None:
        self.update(
            self.agent_table,
            {"role": agent.role, "chats": agent.chats},
            {"_id": agent.id}
        )

    def delete_agent(self, agent_id: str) -> None:
        self.delete(self.agent_table, {"_id": agent_id})

    # ── Heartbeat CRUD ────────────────────────────────────────────────────────

    def add_heartbeat(self, heartbeat: AgentHeartbeats) -> None:
        self.insertion(self.hb_table, {
            "agent_id":     heartbeat.agent_id,
            "user_id":      heartbeat.user_id,
            "timestamp":    heartbeat.timestamp,
            "days_per_week": heartbeat.days_per_week,
            "prompt":       heartbeat.prompt,
        })

    def get_heartbeats(self, agent_id: str) -> list[dict]:
        result = self.lookup(self.hb_table, {"agent_id": agent_id})
        return [{"_id": k, **v} for k, v in result.items()]

    def delete_heartbeat(self, heartbeat_id: str) -> None:
        self.delete(self.hb_table, {"_id": heartbeat_id})

    def note_via_hb(self, data: dict):
        note = Note(
            user=self.user_id,
            title=data.get("title", ""),
            text=data.get("text", ""),
            public=data.get("public", False),
            group_id=data.get("group_id", ""),
            verses=data.get("verses", [])
        )
        self.insertion(self.note_table, note.model_dump())

    def commit_hb_response(self, agent_id: str, heartbeat_content: str):
        result     = self.lookup(self.agent_table, {"_id": agent_id})
        agent_role = list(result.values())[0].get("role", "") if result else ""
        response = self._call_api(agent_role, [{"role": "user", "content": heartbeat_content}])
        if "{" in response and "}" in response:
            response_dict = json.loads(response)
            if response_dict.get("__action") == "create_note":
                self.note_via_hb(response_dict)
                return {"success": "saved note"}
            elif response_dict.get("__action") == "create_notification":
                return response_dict
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
        return self.lookup(self.msg_table, {"agent_id": agent_id})

    def delete_message(self, message_id: str) -> None:
        self.delete(self.msg_table, {"_id": message_id})

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
        self.save_agent_message(AgentMessages(
            chat_id="", agent_id=agent_id, user_id=self.user_id,
            content=response_text, title="assistant", timestamp=now
        ))
        return response_text

    async def connect_agent(self, agent_id: str, ws: WebSocket) -> None:
        await ws.accept()
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
