import requests
from datetime import datetime
from schemas.agent import Agent, AgentMessages
import json
import os
from dotenv import load_dotenv

load_dotenv() 

MODELNAME="deepseek/deepseek-v4-pro"
BASEURL="https://openrouter.ai/api/v1/chat/completions"
HEADERS={
    "Authorization": f"Bearer {os.getenv("OPENROUTER_API_KEY")}",
    "Content-Type": "application/json",
}
REQUEST_SCHEMA={
    "model": MODELNAME,
    "messages": [
        {
          "role": None,
          "content": None
        }
      ],
    "reasoning": {"enabled": True}
}

class AgentManager:
    def __init__(self, user_id: str):
        self.user_id = user_id

    def create_agent(self, Agent: Agent):
        pass