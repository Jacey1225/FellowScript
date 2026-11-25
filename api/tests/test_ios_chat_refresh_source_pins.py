"""Source-pin checks for task 20261124-chat-lags-new-messages (iOS client).

Runs as a plain script (`python tests/test_ios_chat_refresh_source_pins.py`),
no Swift toolchain, DB or network needed. Pins that the catch-up refresh is
wired on every path that used to leave the open chat/thread stale:
  1. scenePhase .active refreshes the open conversation.
  2. socket reconnect after a drop refreshes it.
  3. a same-id thread open (push tap on the open thread) refetches, not no-op.
  4. a message/thread push tap (AppState.openSession) bumps the refresh signal,
     and ChatThreadView force-refreshes on it.
  5. a failed fetch cannot clear the list (fetch is `try?` + early return).
  6. the background disconnect (APNs fall-through) is untouched.
  7. pending thread open is restored if cancelled instead of silently lost.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "FellowScript" / "FellowScript"
VIEW = (SRC / "Chat" / "ChatThreadView.swift").read_text(encoding="utf-8")
APPSTATE = (SRC / "Services" / "AppState.swift").read_text(encoding="utf-8")
SOCKET = (SRC / "Chat" / "ChatSocketOwner.swift").read_text(encoding="utf-8")

failures = []


def check(name, cond):
    if not cond:
        failures.append(name)
    print(("ok   " if cond else "FAIL ") + name)


def body_after(text, marker, span=1800):
    i = text.find(marker)
    return "" if i < 0 else text[i:i + span]


# 1. foreground
active = body_after(VIEW, "} else if phase == .active {", 500)
check("scenePhase .active calls handleAppForegrounded", "vm.handleAppForegrounded()" in active)
check("scenePhase .active refreshes open conversation", "refreshFromStoredContext()" in active)

# 2. reconnect after drop
init = body_after(VIEW, "socket.onConnectionChange = { [weak self] connected in", 900)
check("connection drop is remembered", "wasDropped = true" in init)
check("reconnect after drop refreshes", "refreshFromStoredContext()" in init)

# 3. same-id openThread refetches
ot = body_after(VIEW, "func openThread(_ summary: FSThreadSummary", 900)
same = body_after(ot, "if activeThread?.id == summary.id {", 600)
check("same-id openThread force-refreshes", "refreshOpenConversation(" in same and "force: true" in same)
check("same-id openThread retries first page after failed load", "loadThreadFirstPage(" in same)
check("same-id openThread no longer a bare early return",
      not re.search(r"if activeThread\?\.id == summary\.id \{\s*return\s*\}", ot))

# 4. push tap signal
sess = body_after(APPSTATE, "func openSession(groupId: String)", 900)
check("openSession bumps conversationRefreshSignal", "conversationRefreshSignal += 1" in sess)
check("AppState declares conversationRefreshSignal", "@Published var conversationRefreshSignal" in APPSTATE)
sig = body_after(VIEW, "ConversationRefreshWatcher(signal: appState.conversationRefreshSignal)", 300)
check("view force-refreshes on conversationRefreshSignal", "refreshFromStoredContext(force: true)" in sig)

# 5. failure preserves list
roc = body_after(VIEW, "func refreshOpenConversation(", 2600)
check("thread refresh fetch is try? with early return", re.search(r"try\? await service\.fetchThreadMessages[\s\S]{0,200}else \{ return \}", roc) is not None)
check("history refresh fetch is try? with early return", re.search(r"try\? await service\.fetchMessageHistory[\s\S]{0,200}else \{ return \}", roc) is not None)
check("refresh never assigns empty messages", "messages = []" not in roc)
check("stale generation discarded", "generation == loadGeneration" in roc)

# 6. background disconnect untouched
check("handleAppBackgrounded still delegates to socket", "func handleAppBackgrounded() { socket.handleAppBackgrounded() }" in VIEW)
check("socket owner still closes on background", "func handleAppBackgrounded" in SOCKET)

# 7. pending thread open not lost
cons = body_after(VIEW, "private func consumePendingThreadOpen() async {", 1800)
check("pending thread open restored when cancelled", "appState.pendingThreadOpen = pending" in cons)
check("capabilities re-requested while waiting", "refreshCapabilities(force: true)" in cons)

# merge keeps local/optimistic rows
check("mergeRefreshed exists and keeps local ids", "static func mergeRefreshed(" in VIEW and "localIds" in VIEW)

if failures:
    print("\n%d failed: %s" % (len(failures), failures))
    sys.exit(1)
print("\nall source pins passed")
