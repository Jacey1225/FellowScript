from fastapi import WebSocket
from schemas.message import Message
import os
from helpers import save_message

main_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../..")
class ConnectionManager:
    """Manages active WebSocket connections keyed by user ID.

    Provides targeted message delivery and signaling relay for real-time
    chat and WebRTC call flows.
    """

    def __init__(self) -> None:
        """Initialise with an empty active-connections registry."""
        self.active_connections: dict[str, WebSocket] = {}

    async def connect(self, user_id: str, ws: WebSocket) -> None:
        """Accept a new WebSocket connection and register it.

        Args:
            user_id: UUID of the connecting user.
            ws: The accepted WebSocket instance.
        """
        await ws.accept()
        self.active_connections[user_id] = ws

    async def disconnect(self, user_id: str) -> None:
        """Remove a user's WebSocket from the active registry on disconnect.

        Args:
            user_id: UUID of the disconnecting user.
        """
        self.active_connections.pop(user_id, None)

    async def send_msg(self, payload: dict) -> None:
        """Persist a chat message and deliver it to all online recipients.

        Args:
            payload: Message dict with at minimum ``to_users`` (list[str]),
                ``from_user`` (str), ``text`` (str), ``group_id`` (str|None),
                and ``timestamp`` (str).
        """
        to_users = payload.get("to_users")
        if not to_users:
            return
        save_message(Message(**payload))
        frame = {
            "from_user": payload.get("from_user"),
            "text":      payload.get("text"),
            "group_id":  payload.get("group_id"),
            "timestamp": payload.get("timestamp"),
        }
        for uid in to_users:
            ws = self.active_connections.get(uid)
            if ws:
                await ws.send_json(frame)

    async def send_sig(self, payload: dict) -> None:
        """Relay a WebRTC signaling frame without persisting it.

        Used for call-invite, call-accept, call-reject, offer, answer,
        ice-candidate, and call-end message types. The payload is forwarded
        as-is to each online recipient.

        Args:
            payload: Signaling dict with at minimum ``to_users`` (list[str]).
                Remaining keys are specific to the signaling message type.
        """
        to_users = payload.get("to_users", [])
        for uid in to_users:
            ws = self.active_connections.get(uid)
            if ws:
                await ws.send_json(payload)

    async def broadcast(self, message: dict) -> None:
        """Send a message to every currently connected user.

        Args:
            message: Arbitrary JSON-serialisable payload to broadcast.
        """
        for ws in self.active_connections.values():
            await ws.send_json(message)