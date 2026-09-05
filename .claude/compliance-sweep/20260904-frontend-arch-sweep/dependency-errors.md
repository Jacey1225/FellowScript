# Dependency Error Handling — 20260904-frontend-arch-sweep

Scope reviewed: all 161 files in `file-inventory.json` across the iOS SwiftUI app
(`FellowScript/FellowScript/`), the React/Vite SPA (`frontend/src/`), and the
legacy static tree (`frontend/{account,reader,signin}.html`, `frontend/css/`,
`frontend/js/`) — walked systematically by feature folder rather than by keyword
grep, then confirmed at each call site by reading the surrounding function.
Manifests reviewed: `frontend/package.json`, the iOS project's SPM package
references (`FellowScript.xcodeproj/project.pbxproj`) and their resolved pins
(`Package.resolved`); `frontend/package-lock.json` is out of scope per
`compliance-plan.md`.

**Headline observation:** the iOS surface has clearly already been through at
least one remediation pass for this exact category — `NetworkService.swift`,
`StoreKitManager.swift`, `GoogleAuthSession.swift`, and `ChimeCallView.swift` all
carry inline comments literally citing prior `dependency-errors #N` findings
(timeouts added, silent `try?` swallows converted to logged/surfaced failures,
optimistic-mutation-before-confirmation bugs fixed). The React web app and the
legacy static tree have **not** received equivalent treatment — several of the
web app's hooks/pages reproduce the identical failure patterns the iOS
equivalents were already fixed for (see #1 and #4 below, which cross-reference
the specific iOS fix each one is missing).

---

## Critical

### 1. `frontend/src/hooks/useSessions.js` — Chime call join fails completely silently
- **Where:** `joinSession()`, lines 215–332, specifically the meeting-creation
  fetch (`catch { return; }` at line 232) and the attendee-token fetch
  (`catch { return; }` at line 242).
- **What's unhandled:** if either backend call fails (network error, 4xx/5xx),
  the function just returns. No error state is set, no message shown, no
  retry offered — the user taps "Join call" and nothing visibly happens.
  `activeSessionId` is never set, so the UI has no way to distinguish "still
  connecting" from "silently failed."
- **Why it matters:** this is the exact feature (`ChimeCallView.swift` /
  `CallController.start()` on iOS) that already got this fix — iOS's
  `joinError`/`startError` published properties exist specifically so a failed
  join surfaces a retry screen instead of a frozen "Connecting…" state. The web
  implementation of the same call-join flow has no equivalent, so this is a
  regression relative to the sibling platform, not just an isolated gap.
- **Suggested fix:** track a `joinError` (or similar) state value, set it in
  each catch block with a user-facing message, and render a retry affordance
  in the calling component instead of failing invisibly.

---

## High

### 2. `frontend/js/tour.js:5` — onboarding tour imports a third-party library straight from a CDN, no SRI, no fallback
- **Where:** `import { driver } from 'https://cdn.jsdelivr.net/npm/driver.js@1.3.1/+esm';`
  Statically imported (not dynamic `import()`) by `frontend/js/reader.js:19`
  and `frontend/account.html:327`.
- **What's at risk:** this bypasses the project's own dependency-integrity
  mechanism entirely — `driver.js` is *also* a proper `frontend/package.json`
  dependency (`"driver.js": "^1.3.1"`) for the React app, resolved through npm
  with a lockfile, but the legacy tree instead fetches the same library live
  from jsdelivr on every page load, with no subresource-integrity hash. A
  jsdelivr outage, a corporate/ISP block of that CDN, an ad-blocker rule, or a
  supply-chain compromise of the CDN-served bundle all become live risks for
  this surface that the React app isn't exposed to at all.
- **Why it matters:** because it's a *static* ES module import, a load failure
  doesn't just disable the tour — it fails the whole module graph for the
  importing file. `frontend/js/reader.js` (the core Bible-reader page logic)
  statically imports `tour.js`, so a blocked/unreachable CDN request could take
  down reader.js's own module initialization along with it, not just the tour
  feature.
- **Suggested fix:** bundle `driver.js` from the already-declared npm
  dependency (or vendor a local copy) instead of a live CDN import; if a CDN
  import is kept, add a Subresource Integrity hash and switch to a dynamic
  `import()` wrapped in try/catch so a failure degrades to "no tour" instead of
  breaking the importing module.

### 3. `frontend/src/components/SubscriptionCard.jsx:171-178` — `cancelPlan()` never checks the DELETE response status
```js
const cancelPlan = async () => {
  setBusy('cancel');
  try {
    await fetch(`${API}/subscriptions/${plan.id}`, { method: 'DELETE' });
    await load(); onPlanChange?.(); flash('success', 'Plan canceled.');
  } catch { flash('error', 'Could not cancel plan.'); }
  finally { setBusy(''); }
};
```
- **What's unhandled:** `fetch()` only rejects (hits the `catch`) on a network
  failure — a 4xx/5xx response from the server resolves normally. This
  function never inspects `res.ok` at all, so a rejected/failed cancellation
  (auth expired, backend validation error, transient 500) still shows "Plan
  canceled" and calls `onPlanChange?.()` as if it had succeeded. Every sibling
  action in the same file (`startCheckout`, `updateSeats`) does check
  `res.ok`/parse an error `detail` — this is the one write path that doesn't.
- **Why it matters:** this is a billing action. A user could believe their
  subscription was canceled (and stop expecting further charges) when the
  server-side cancellation actually failed.
- **Suggested fix:** check `res.ok` before flashing success; on failure parse
  and surface the error detail the same way `updateSeats` does.

### 4. `frontend/src/pages/Account.jsx` — agent toggle/rename apply optimistic UI state without checking the write succeeded
- **Where:** `handleToggleAgent` (lines 339–346) and `handleRenameAgent`
  (lines 348–357).
```js
const handleToggleAgent = async (agentId, enabled) => {
  try {
    await fetch(`${API}/agent/${user.user_id}/${agentId}`, { method: 'PUT', ... });
    setAgents(prev => prev.map(a => a.id === agentId ? { ...a, enabled } : a));
  } catch {}
};
```
- **What's unhandled:** neither function checks `res.ok` (network failures are
  swallowed by an empty `catch {}` too), so a rejected PUT still applies the
  local optimistic mutation — the UI shows the agent as enabled/renamed while
  the server never accepted the change, and nothing reconciles this until the
  next full reload.
- **Why it matters:** this is the *identical* bug `NetworkService.swift`'s
  `updateAgent`/`renameAgent` already had fixed for the iOS app — those
  methods' doc comments explicitly say they were switched to
  `checkedRequestRaw` "so a backend rejection throws instead of leaving the
  caller's optimistic local mutation silently drifted from server state." The
  React implementation of the same two actions still has the bug the iOS side
  was patched for.
- **Suggested fix:** gate the `setAgents(...)` mutation on `res.ok`; on failure,
  surface an error (`message.error`, consistent with `useMessaging.js`'s
  pattern) and leave state unchanged, or roll back if applied optimistically.

### 5. `frontend/src/hooks/useAgentChat.js` — every write/read path swallows failures with zero logging or user feedback
- **Where:** `loadAgents` (23-31), `loadHeartbeats` (33-46, including the
  per-agent `.catch(() => [])` at line 41), the heartbeat monitor's
  `commit_heartbeat` call (78-91), `connectAgentWS.onmessage` (104-115),
  `openAgentChat` (128-140), `createAgent`/`updateAgent`/`deleteAgent`/
  `addHeartbeat`/`summarizeSession` (163-234) — all wrapped in bare `catch {}`.
- **What's unhandled:** unlike the sibling `useMessaging.js` hook (same file
  layout, same app, reviewed side by side), which consistently does
  `console.error(...)` plus a `message.error(...)` toast on every failure path,
  every one of `useAgentChat.js`'s handlers does neither. A failed
  `createAgent`/`deleteAgent`/`addHeartbeat` call just silently no-ops — the
  user clicks "Create agent" and it doesn't appear, with no explanation and no
  console trail to diagnose it later.
- **Why it matters:** the scheduled heartbeat monitor (`checkHeartbeats`,
  60s interval) is the most consequential instance — a failed
  `commit_heartbeat` POST (the mechanism that fires an AI agent's scheduled
  check-in and saves its note) is marked as fired (`firedTodayRef.current.add`)
  *before* the network call even starts, so a failure here means that
  scheduled check-in silently never happens for the rest of the day, with zero
  signal anywhere that it didn't.
- **Suggested fix:** bring this hook up to `useMessaging.js`'s existing
  standard — log every catch and surface a `message.error` (or equivalent) on
  user-initiated actions; for the heartbeat monitor specifically, only mark a
  heartbeat as "fired today" after `commit_heartbeat` succeeds, or add a retry.

---

## Medium

### 6. `FellowScript/FellowScript/Chat/MessageAttachments.swift` — picker failures vanish with no user-facing error
- **Where:** `PhotoVideoPicker.Coordinator.picker(_:didFinishPicking:)` (video
  branch line 159-178, image branch 179-189) and
  `DocumentPicker.Coordinator.documentPicker(_:didPickDocumentsAt:)` (line
  227-236) — every failure path calls `onPicked(nil)` with no accompanying
  error message.
- **What's unhandled:** a file-copy failure, a `Data(contentsOf:)` read
  failure, or a security-scoped-resource access failure (e.g. iCloud file not
  yet downloaded) all resolve to the composer just... not staging anything,
  with no indication to the user of what happened or that it failed at all.
- **Why it matters:** this contrasts with the same file's GIF-search path
  (`errorMessage = "Couldn't load GIFs right now — try again in a moment."`,
  line 290), which does the right thing for the same category of failure.
  Note this file is explicitly called out in `compliance-plan.md` as an
  untracked, in-flight feature — treat this as a gap to close before shipping
  rather than a regression.
- **Suggested fix:** thread an error string through `onPicked`/a companion
  callback (or a shared `@Published errorMessage`) so a failed pick shows the
  same kind of on-brand error copy the GIF path already does.

### 7. `frontend/js/messaging.js` — legacy group create/update/leave fail with a code comment instead of any UI signal
- **Where:** `_submitGroup()` (lines 312-341, both the update and create
  branches end in `catch { /* server unreachable */ }`) and `_leaveGroup()`
  (lines 344-365, `catch { /* offline */ }`).
- **What's unhandled:** on a network failure the group form simply doesn't
  close/reset (create/update) or the row simply doesn't disappear (leave) —
  there's no toast, no inline error, nothing distinguishing "the server
  rejected this" from "the button hasn't been clicked yet."
- **Why it matters:** per `compliance-plan.md`'s explicit note, the legacy tree
  has zero test coverage backstopping `frontend/js/*` beyond `notes.js`/
  `utils.js`, so this class of gap is more likely to reach nginx-served
  production unnoticed than the equivalent React code would be.
- **Suggested fix:** add a minimal inline error message element (matching this
  surface's existing "warm on-brand error copy" pattern used elsewhere) shown
  on catch, so a failed group action is visibly distinguishable from a slow
  one.

### 8. `frontend/src/hooks/useMessaging.js:356-371` — `blockUser()` is the one action in the file with no user-facing failure feedback
- **Where:** `blockUser()`'s catch block does only `console.error('Failed to
  block user:', err);` and returns `false` — no `message.error(...)`.
- **What's unhandled:** every sibling action in the same hook
  (`removeFriend`, `reportUser`, `createGroup`, `updateGroup`, `leaveGroup`)
  calls `message.error(...)` on failure; `blockUser` alone stays silent from
  the user's perspective, even though the caller does receive the `false`
  return value (worth checking the caller actually surfaces it — if it
  doesn't, a failed block attempt looks identical to a successful one).
- **Suggested fix:** add the same `message.error('Could not block that
  user...')` pattern used by the rest of this hook for consistency.

### 9. Hardcoded API base URL duplicated across two config files instead of build-time env injection
- **Where:** `frontend/src/config.js:1` and `frontend/js/config.js:1` — both:
  `export const API = 'https://fellowscript.com/api';`
- **What's at risk:** per this sweep's Configuration Q2 preference, env vars
  are the expected mechanism specifically for deployment-specific values like
  an API base URL — these are instead literal strings baked into two
  independent source files that must be hand-kept in sync (they already are
  identical today, but nothing enforces that). Switching environments (a
  staging/local backend) requires editing and redeploying source in two
  places rather than a single env-level override, and there's no fail-fast
  validation that the intended value is actually set.
- **Suggested fix:** source both from a single build-time env var (Vite's
  `import.meta.env.VITE_API_URL` for the React app; a small injected
  `<script>`/meta-tag value for the no-build legacy pages), with one canonical
  definition rather than two files that happen to agree.

---

## Low

### 10. `FellowScript/FellowScript/Services/NetworkService.swift:26` — request timeout is a hardcoded constant, and no call has a retry policy
- **Where:** `private static let requestTimeout: TimeInterval = 30` — applied
  uniformly to every `get`/`request`/`requestRaw`/`checkedRequestRaw` call in
  the file; no call site retries a transient failure.
- **Why it matters:** this is well-documented (the comment explains the 30s
  choice and its provenance), and error surfacing here is otherwise excellent
  — but per this sweep's Configuration Q1 preference, a timeout is exactly the
  kind of tunable expected to be exposed as configuration rather than a
  hardcoded magic number, and a chat/call-heavy app with zero retry logic
  means any single transient blip (not just a true failure) surfaces as a
  user-visible error rather than transparently recovering.
- **Suggested fix:** low priority given the strong existing error-surfacing in
  this file — consider making the timeout a build-config value and adding a
  bounded retry (1-2 attempts) for idempotent GETs specifically.

### 11. iOS SPM package references use floating `upToNextMajorVersion` requirements
- **Where:** `FellowScript.xcodeproj/project.pbxproj` —
  `amazon-chime-sdk-ios-spm` pinned `>= 0.27.0` (`upToNextMajorVersion`),
  `ViewInspector` pinned `>= 0.10.0` (`upToNextMajorVersion`).
- **Why it matters:** in principle a floating range risks pulling in an
  unreviewed transitive update on a clean checkout before `Package.resolved`
  exists — but the checked-in
  `FellowScript.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  currently pins both to specific resolved revisions (0.27.3 / 0.10.3
  respectively), which is committed and functions like a lockfile, so the
  practical risk today is low. Flagging only because the manifest-level
  requirement itself is unpinned, not because of any observed drift.
- **Suggested fix:** no action needed while `Package.resolved` stays committed
  and up to date; if it's ever gitignored, that removes the one thing
  currently bounding this.

### 12. `FellowScript/FellowScript/Services/DiskCache.swift:44-56` — every disk I/O operation swallows failure via bare `try?`, no logging
- **Where:** `load()`, `save()`, `remove()`, `clear()` — all four use `try?`
  with no error path at all.
- **Why it matters:** the file's own doc comment explains this is an
  intentional best-effort stale-while-revalidate cache (the OS may purge it,
  and that's fine), so the impact of a single miss is genuinely low — but a
  systematic failure (disk full, sandbox permissions change) would leave
  literally zero diagnostic trail anywhere, unlike this same codebase's
  `NetworkService.swift`, which now logs and beacons its own best-effort
  failures (`reportDecodeFailure`) rather than staying fully silent.
- **Suggested fix:** optional — a single `print`/log line per failure (no need
  to beacon, given the low stakes) would bring this file in line with the
  logging standard the rest of the Services layer has already adopted.

---

## Summary

12 findings: 1 Critical, 4 High, 4 Medium, 3 Low. The iOS app shows clear
evidence of a prior remediation pass for this exact category (multiple files
cite specific prior `dependency-errors #N` fixes); the React web app and the
legacy static JS tree have not had equivalent treatment, and in two cases
(#1, #4) reproduce the identical bug their already-fixed iOS counterpart
explicitly documents having had. Package/manifest health is otherwise solid —
`frontend/package.json` uses conventional caret ranges (npm's own lockfile,
out of scope here, provides the actual pin), and the iOS SPM dependencies are
effectively pinned via a committed `Package.resolved` despite floating
manifest-level requirements.
