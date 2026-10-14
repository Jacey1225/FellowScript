# Agent Chats

Each AI study partner (agent) can have more than one conversation. Instead of a single running thread, you can start a new chat for an agent whenever you want a fresh topic, and come back to older chats later.

Multiple chats are available on iOS, in the iPad Agent Chat dock, and in the desktop and web app. The feature sits behind the `agent_chats` feature flag, which is on in production. With the flag off, every client falls back to the single-chat behaviour.

## What you can do

- **Start a new chat.** A "New chat" action creates an empty chat for that agent and opens it. If creating the chat fails, the chat you were in stays open and an error is shown. No chat is created on the client without the server confirming it.
- **See that agent's chats.** The "Chats" button in the chat header opens the list. Each row shows the chat title and a relative date for its last activity ("Today", "Yesterday", or a date such as "Oct 4"). Chats are listed most recent first, in the order the server returns them.
- **Switch between chats.** Choosing a row opens that chat and loads its own history. The current chat is marked with a checkmark.
- **Pick up where you left off.** The app remembers the last chat you visited for each agent. When you open an agent it reopens that chat, or the most recent chat if the remembered one no longer exists.

## Limits and errors

- Each agent can have up to 50 chats. At the limit, "New chat" does not create anything and a message tells you the limit has been reached.
- If the chat list cannot be loaded, the screen shows "Couldn't load chats". If a refresh fails while a list is already showing, the existing list stays on screen.
- Messages and replies are scoped to the open chat. Replies that belong to a different chat never appear in the one you are viewing, and the "thinking" indicator only reflects the open chat.

## Where it appears

| Client | Where |
|---|---|
| iOS | "Chats" button at the top right of the agent chat, opening a sheet with the list and a "New chat" action |
| iPad | The same agent chat view inside the Agent Chat dock |
| Desktop / web | A "Chats" button and a "New chat" button in the agent chat panel header, with the list in a popover |

## API

The chat routes are gated by the `agent_chats` flag per user; with the flag off they return `404`.

| Method | Path | Notes |
|---|---|---|
| GET | `/agent/{user_id}/{agent_id}/chats` | Chats for the agent, most recent first (`id`, `title`, `created_at`, `last_message_at`) |
| POST | `/agent/{user_id}/{agent_id}/chats` | Create a chat (empty body). `201` with the new chat, `409` with `{"code":"chat_limit"}` at 50 chats, rate-limited |
| GET | `/agent/{user_id}/{agent_id}/messages?chat_id=` | History for one chat. Without `chat_id` (flag on) the default chat is used; an unknown or foreign `chat_id` is `404` |
| WS | `/agent/ws/{agent_id}/{user_id}?chat_id=` | Live chat. Outgoing frames are `{"content": text, "chat_id": id}` |
