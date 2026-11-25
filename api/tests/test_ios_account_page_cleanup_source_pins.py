"""Source-pin checks for task 20261125-account-page-cleanup (iOS client).

Plain script (`python api/tests/test_ios_account_page_cleanup_source_pins.py`),
no Swift toolchain, DB or network needed. Pins:
  1. AI assistant card, View-my-profile row and Plan Usage card are gone.
  2. ProfileEntryViews.swift (MyProfileRow) is deleted, nothing references it.
  3. The flag-off legacy agents section is still gated, not newly shown.
  4. Edit Profile card hosts the bio field; bio rules stay single-source.
  5. Usage data plumbing and Ask AI consumers are intact.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "FellowScript" / "FellowScript"
TESTS = ROOT / "FellowScript" / "FellowScriptTests"


def read(*parts):
    return (SRC.joinpath(*parts)).read_text(encoding="utf-8")


ACCOUNT = read("Account", "AccountView.swift")
AGENTS = read("Account", "AccountView+Agents.swift")
PROFILE = read("Account", "AccountView+Profile.swift")
SUB = read("Account", "AccountView+Subscription.swift")
EVENTS = read("Account", "AccountView+Events.swift")
VM = read("Account", "AccountViewModel.swift")
BIOFIELD = read("Account", "AccountBioField.swift")
BIOEDITOR = read("Profile", "ProfileBioEditor.swift")
PVM = read("Profile", "ProfileViewModel.swift")
APPSTATE = read("Services", "AppState.swift")
CONTENT = read("ContentView.swift")
CHATROOM = read("Chat", "ChatRootView.swift")

ALL_SWIFT = {p: p.read_text(encoding="utf-8")
             for p in list(SRC.rglob("*.swift")) + list(TESTS.rglob("*.swift"))}

failures = []


def check(name, cond):
    if not cond:
        failures.append(name)
    print(("ok   " if cond else "FAIL ") + name)


def refs(token):
    return [p.name for p, t in ALL_SWIFT.items() if re.search(r"\b" + token + r"\b", t)]


def body_after(text, marker, span=900):
    i = text.find(marker)
    return "" if i < 0 else text[i:i + span]


# 1. removals
for tok in ("aiAssistantSection", "MyProfileRow", "usageSection", "usageRow"):
    check(f"{tok} has no references anywhere", refs(tok) == [])
check("AccountView has no 'View my profile' row", "View my profile" not in ACCOUNT)
check("no 'Plan Usage' card text in Account sources",
      "Plan Usage" not in ACCOUNT + PROFILE + SUB + AGENTS)
check("no 'AI assistant' card label in Account sources", "AI assistant" not in ACCOUNT + AGENTS)
check("no 'Open Ask AI' button in Account sources", "Open Ask AI" not in AGENTS + ACCOUNT)

# 2. file deleted
check("ProfileEntryViews.swift deleted", not (SRC / "Profile" / "ProfileEntryViews.swift").exists())
check("FSUsageResource.fraction/maxedOut removed (no UI consumer)",
      not re.search(r"\.(fraction|maxedOut)\b", "".join(ALL_SWIFT[p] for p in ALL_SWIFT if p.name in
                    ("AccountView.swift", "AccountView+Profile.swift", "AccountView+Subscription.swift", "PlanBlock.swift"))))

# 3. flag-off agents section unchanged in behavior
check("agentsSection gated on !askAiEnabled",
      re.search(r"if\s+!appState\.capabilities\.askAiEnabled\s*\{\s*agentsSection\s*\}", ACCOUNT) is not None)
check("agentsSection still defined", "var agentsSection" in AGENTS)

# 4. bio moved into Edit Profile card
edit = body_after(PROFILE, "var editProfileSection", 6000)
check("editProfileSection hosts AccountBioField", "AccountBioField(" in edit)
check("editProfileSection still has Save Changes -> saveProfile",
      "saveProfile" in edit and "Save Changes" in edit)
check("AccountBioField reuses ProfileViewModel and ProfileBioEditor",
      "ProfileViewModel(" in BIOFIELD and "ProfileBioEditor(" in BIOFIELD)
check("AccountBioField uses viewer id == target id",
      re.search(r"viewerId:\s*userId,\s*targetId:\s*userId", BIOFIELD) is not None)
check("editor only rendered once a profile is loaded/cached", "if vm.profile != nil" in BIOFIELD)
check("failed/unavailable first load shows Retry", "Retry" in BIOFIELD and "vm.phase == .failed" in BIOFIELD)
check("bio field loads via vm.load()", "await vm.load()" in BIOFIELD)
check("no duplicated bio rules in AccountBioField",
      not re.search(r"\b160\b|precomposedStringWithCanonicalMapping|Couldn't save your bio", BIOFIELD))
check("bioMaxLength defined once", len(re.findall(r"static let bioMaxLength", "".join(ALL_SWIFT.values()))) == 1)
check("bioErrorMessage defined once", len(re.findall(r"static func bioErrorMessage", "".join(ALL_SWIFT.values()))) == 1)
check("bioMaxLength is 160", "bioMaxLength = 160" in PVM)
check("saveBio uses bioErrorMessage and never clears draft on failure",
      "bioError = Self.bioErrorMessage(error)" in PVM and "never cleared on failure" in PVM)
check("saveBio posts accessibility announcement", 'argument: "Bio saved"' in PVM)
check("ProfileBioEditor new params default to old behavior",
      "var autoFocus = true" in BIOEDITOR and "var showsCancel = true" in BIOEDITOR)
check("ProfileView self-mode still uses ProfileBioEditor",
      "ProfileBioEditor(" in "".join(t for p, t in ALL_SWIFT.items() if p.parent.name == "Profile" and p.name != "ProfileBioEditor.swift"))
check("AccountBioField.swift is small (<150 lines)", len(BIOFIELD.splitlines()) < 150)

# 5. data plumbing and Ask AI consumers intact
check("vm.usage still used by subscription card", "vm.usage" in SUB)
check("devotionsLocked still reads vm.usage", "vm.usage" in EVENTS)
check("AccountView still calls refreshUsage on upgrade block",
      "refreshUsage()" in ACCOUNT)
check("refreshUsage still defined in AccountViewModel", "func refreshUsage" in VM)
check("FSUsage model still present", len(refs("FSUsage")) > 0)
check("FreePlanLimitRow still present", len(refs("FreePlanLimitRow")) > 0)
check("pendingAskAiOpen still declared", "var pendingAskAiOpen" in APPSTATE)
check("ContentView still consumes pendingAskAiOpen", "pendingAskAiOpen" in CONTENT)
check("ChatRootView still consumes pendingAskAiOpen", "pendingAskAiOpen" in CHATROOM)

# brace balance of touched Swift files
for p in [SRC / "Account" / n for n in ("AccountView.swift", "AccountView+Agents.swift",
          "AccountView+Profile.swift", "AccountBioField.swift")] + [SRC / "Profile" / "ProfileBioEditor.swift"]:
    t = ALL_SWIFT[p]
    check(f"balanced braces/parens: {p.name}",
          t.count("{") == t.count("}") and t.count("(") == t.count(")"))

if failures:
    print(f"\n{len(failures)} FAILED")
    sys.exit(1)
print("\nall pins passed")
