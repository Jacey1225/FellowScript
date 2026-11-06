// Multi-chat helpers for the Agent Chat dock (flag `agent_chats`). Mirrors the
// iOS AgentChatViewModel / AgentChatDateLabel rules; iOS is the source of truth.

export const DEFAULT_MAX_CHATS = 50;

// Ask AI (flag `ask_ai_default_agent`): one server-owned assistant. The client
// never learns a real agent id; this constant is only a local handle so the
// shared chat code has something to hang an "active assistant" on. Every
// request in Ask AI mode goes to the agent-id-free /ask-ai routes.
export const ASK_AI_ID = 'ask-ai';
export const ASK_AI_LABEL = 'Ask AI';
export const ASK_AI_AGENT = Object.freeze({ id: ASK_AI_ID, name: ASK_AI_LABEL });
export const ASK_AI_CHAT_LIMIT_MESSAGE = "You've reached the chat limit for Ask AI.";

// Last successful Ask AI chat list, so a failed refresh (or a cold start with
// the network down) can still show saved chats instead of a blank or invented
// list. Best-effort localStorage; never read as authoritative.
export function askAiCacheKey(userId) { return `askAiChats.${userId}`; }

export function readAskAiCache(userId) {
  try {
    const raw = window.localStorage.getItem(askAiCacheKey(userId));
    const list = raw ? JSON.parse(raw) : null;
    return Array.isArray(list) ? list : [];
  } catch { return []; }
}

export function writeAskAiCache(userId, chats) {
  try { window.localStorage.setItem(askAiCacheKey(userId), JSON.stringify(chats)); }
  catch { /* storage unavailable: cache is best-effort */ }
}

export function lastChatKey(userId, agentId) {
  return `agentLastChat.${userId}.${agentId}`;
}

export function readLastChat(userId, agentId) {
  try { return window.localStorage.getItem(lastChatKey(userId, agentId)) || null; } catch { return null; }
}

export function writeLastChat(userId, agentId, chatId) {
  try {
    if (chatId) window.localStorage.setItem(lastChatKey(userId, agentId), chatId);
  } catch { /* storage unavailable: restore is best-effort */ }
}

// Last-visited chat when it is still in the fetched list, else the most recent
// (server order, most recent first). Null when the list is empty.
export function pickInitialChatId(chats, lastVisited) {
  if (!chats?.length) return null;
  if (lastVisited && chats.some(c => c.id === lastVisited)) return lastVisited;
  return chats[0].id;
}

export function chatDisplayTitle(chat) {
  const t = (chat?.title || '').trim();
  return t || 'New chat';
}

// "Today" / "Yesterday" / "Oct 4"; empty string when unparseable.
export function chatDateLabel(iso, now = new Date()) {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diffDays = Math.round((day(now) - day(d)) / 86_400_000);
  if (diffDays === 0) return 'Today';
  if (diffDays === 1) return 'Yesterday';
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

export function chatActivityIso(chat) {
  return chat?.last_message_at || chat?.created_at || '';
}

// Error type thrown by the chat-list calls so callers can map status to copy.
export class AgentChatHttpError extends Error {
  constructor(status, code) {
    super(`Agent chat request failed with status ${status}`);
    this.status = status;
    this.code = code || null;
  }
}

export function createChatErrorMessage(err, agentName, max = DEFAULT_MAX_CHATS, askAi = false) {
  if (err?.status === 409 && err?.code === 'chat_limit') {
    if (askAi) return ASK_AI_CHAT_LIMIT_MESSAGE;
    return `You've reached the limit of ${max} chats with ${agentName}.`;
  }
  if (err?.status === 429) return 'Slow down a moment, then try again.';
  if (err?.status === 404) return 'That chat is no longer available.';
  return "Couldn't start a new chat. Try again.";
}
