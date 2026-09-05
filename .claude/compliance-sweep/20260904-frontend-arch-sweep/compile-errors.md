# Compile-Time Error Handling — 20260904-frontend-arch-sweep

Scope reviewed: all 46 iOS Swift/config files under `FellowScript/FellowScript/`, all 94 React/JS/CSS files under `frontend/src/`, and all 21 files in the legacy static tree (`frontend/{account,reader,signin}.html`, `frontend/css/`, `frontend/js/`), per `file-inventory.json`.

Context: this codebase has clearly been through prior remediation passes for exactly this class of gap — many files carry inline comments citing prior fixes (e.g. "compile-errors #2", "backend step 8 finding #1", "dependency-errors #9"). The findings below are the gaps that survived those passes or were introduced alongside them. Every finding was confirmed by reading the surrounding code, not just a grep hit; several initial grep hits (documented at the bottom) were ruled out as false positives.

## Critical

None found.

## High

### 1. `AccountView.swift` — 4 of 7 concurrent fetches in `load()` bypass the function's own error-surfacing mechanism
**File:** `FellowScript/FellowScript/Account/AccountView.swift:163-222`
**What's suppressed:** Inside `AccountViewModel.load()`, three of the seven concurrent fetches (`fetchedAgents`, `fetchedNoteCount`, `fetchedHighlights`) are wrapped in `do/catch` that sets a shared `statsFailed = true` flag on failure (lines 166-171), which later renders a real, user-visible "we couldn't load some of your data" banner (line 220-222) — an explicitly documented fix for task `20260903-account-events-not-loading`. But the other four results in the same function — `userResult` (line 163), `usageResult` (line 173), `friendRequestsResult` (line 174), `contactsResult` (line 175) — still use the exact `try? ... ?? default`/`try?` pattern the surrounding comment (lines 177-183) says was the bug: a genuine fetch failure on any of these is indistinguishable from "nothing to show," and none of them flip `statsFailed`. A failed `usageResult` silently keeps the stale usage snapshot (`usage ?? usage`, line 207); a failed `contactsResult` silently leaves `groups` unrefreshed; a failed `friendRequestsResult` silently renders an empty list instead of "couldn't load."
**Why it's risky:** This is the identical bug class the surrounding comments describe fixing for notes/highlights/agents/events, left in place for profile/usage/friend-requests/groups in the very same function — an inconsistent, partial fix that will look exactly like the resolved incident to a future reader who doesn't re-derive it from scratch.
**Suggested fix:** Fold `userResult`, `usageResult`, `friendRequestsResult`, and `contactsResult` into the same `do { ... } catch { ...; statsFailed = true }` pattern already used for `agentsResult`/`noteCountResult`/`highlightCountResult` two lines above them.

### 2. React hooks — bare `catch {}` reproduces the same swallowed-failure bug class already fixed on iOS and in sibling hooks
**Files:**
- `frontend/src/hooks/useBookmarks.js:12,25,36` (`loadBookmarks`, `addBookmark`, `removeBookmark`)
- `frontend/src/hooks/useHighlights.js:15,68,77,97` (`loadHighlights`, `setHighlight`, `clearHighlight`, `loadGroupHighlights`)
- `frontend/src/hooks/useAgentChat.js:30,45` (`loadAgents`, `loadHeartbeats`)

**What's suppressed:** All of these `try { fetch(...) } catch {}` blocks are completely empty — no `console.error`, no error state set, no rethrow. `addBookmark`/`removeBookmark`/`setHighlight`/`clearHighlight` all optimistically mutate local state *before* the fetch and never roll it back or signal a failure if the network call fails — the UI shows the bookmark/highlight as saved even if the server rejected or never received it. `loadAgents`/`loadHeartbeats`/`loadHighlights`/`loadGroupHighlights` render a failed fetch identically to "user genuinely has none," with zero diagnostic trail.
**Why it's risky:** This is precisely the failure mode `AccountView.swift`, `DashboardView.swift`, `useMessaging.js`, and `useNotes.js` were each explicitly patched to stop doing (per their own inline comments), on the same features (agents, bookmarks/highlights are the Bible-reader-adjacent counterparts of notes). No compiler/type system exists here to catch it (no TypeScript, see Low finding below), so this class of gap has no safety net beyond code review — and it wasn't caught in these four hooks.
**Suggested fix:** At minimum, `console.error` every caught error (matching `useMessaging.js`'s convention at e.g. line 66-68/111-113). For the optimistic-update call sites (`addBookmark`, `removeBookmark`, `setHighlight`, `clearHighlight`), either roll back the optimistic state on failure or expose a `saveError` the UI surfaces, consistent with this project's stated preference for explicit error propagation over silent defaults.

## Medium

### 3. Stringly-typed `switch` over `attachmentKind` bypasses the compiler exhaustiveness the app's own enum already provides
**Files:** `FellowScript/FellowScript/Chat/MessageAttachments.swift:554-559`, `FellowScript/FellowScript/Chat/MessageGroupRow.swift:268-274`
**What's suppressed:** `FSMessage.attachmentKind` is declared `String?` (`Models/Models.swift:512`, documented as the wire values `"image"|"video"|"file"|"gif"`). Both files `switch` on this raw string with string-literal cases and a `default:` catch-all, rather than the same file's own `AttachmentKind` enum (`.image`/`.video`/`.file`/`.gif`), which is switched exhaustively — with no `default:` — everywhere else in the same file (`MessageAttachments.swift:77`, `:480`) and in `ChatThreadView.swift:752`.
**Why it's risky:** Every other attachment-kind switch in this codebase gets a compiler error the moment a new case is added to `AttachmentKind`, forcing every call site to be updated. These two string-based switches get no such signal — a new server-side attachment kind, or a typo in one of the four string literals, silently falls into `default: EmptyView()` / a generic "\(sender): \(text)" accessibility label, with zero compile-time warning.
**Suggested fix:** Decode `attachmentKind` into `AttachmentKind?` at the model boundary (or add a computed `var kind: AttachmentKind?` on `FSMessage`) and switch on that instead of the raw string, dropping the `default:` case so the compiler enforces exhaustiveness the same way it already does for `StagedAttachment.kind`.

### 4. `default:` instead of `@unknown default:` on a non-frozen system enum
**File:** `FellowScript/FellowScript/Services/AppState.swift:141-157`
**What's suppressed:** `switch settings.authorizationStatus` (a `UNAuthorizationStatus`, a non-frozen system enum Apple can add cases to) uses a plain `default: break` for anything besides `.notDetermined`/`.authorized`/`.provisional`/`.ephemeral` — silently doing nothing for `.denied` and any future case.
**Why it's risky:** `StoreKitManager.swift:121` (`purchase()`) and `:237` (`restore()`'s equivalent) both correctly use `@unknown default:` for the same class of Apple-owned enum in this same codebase, which gives a compiler warning the next time this file is built against a newer SDK that adds a case — nudging a developer to reconsider whether the new case should register for push. The plain `default:` here gets no such warning; a new authorization state is silently treated as "do nothing," forever, with no build-time prompt to revisit it.
**Suggested fix:** Change to `@unknown default: break` to match the established convention in `StoreKitManager.swift`.

### 5. `currentRenewal()`'s `try?` collapses failure and success identically, inconsistent with the rest of the file
**File:** `FellowScript/FellowScript/Services/StoreKitManager.swift:167-169`
**What's suppressed:** `guard let sub = ..., let statuses = try? await sub.status else { return nil }` — a thrown `sub.status` failure returns `nil` exactly like "no active entitlement," with no logging.
**Why it's risky:** Every other failure path in this same file has been deliberately instrumented (`restore()` logs via `print` at line 143; `syncEntitlements()` sets `lastError` and tracks `allSucceeded`; `purchase()` sets `lastError` per branch) — this is the one remaining silent-swallow in a file that otherwise treats StoreKit failures as first-class. A user whose renewal-status fetch genuinely fails (not "no subscription") sees the same "no active renewal" UI as someone who was never subscribed, with no diagnostic trail, on a payments-adjacent path (Security Q7's "defense-in-depth for sensitive/high-stakes data paths" applies here).
**Suggested fix:** At minimum log the thrown error (matching `restore()`'s `print("[StoreKitManager] ...")` convention) before returning `nil`.

## Low

### 6. Legacy static JS tree — pervasive bare/comment-only `catch` blocks
**Files:** `frontend/js/session.js:24,37`, `frontend/js/highlights.js:31,113,128`, `frontend/js/bible.js:52`, `frontend/js/notes.js:334,336,358,373,391,533,544,605`, `frontend/js/messaging.js:133,148,163,179,209,260,271,330,340,364,409`, `frontend/js/dashboard.js:119,137,143`
**What's suppressed:** The large majority of `catch` blocks in this tree are either fully empty (`catch {}`) or contain only a comment (`/* offline */`, `/* server error */`, `/* skip */`) — no logging, and in most cases no distinguishable user-facing signal between "request failed" and "there's nothing here." A handful (`notes.js:213`, `messaging.js:409`) do log or show a message and are fine as-is.
**Why it's risky:** `compliance-plan.md` explicitly notes this is the one surface with zero automated test coverage reaching nginx-served production — the same silent-failure pattern flagged as High above for the React hooks, but here with no `try?`/typed-error convention anywhere in the file to point at as the established "right way." Several of these do carry a short rationale comment (e.g. `session.js:37`'s `undefined = offline, don't log out`), which is better than nothing but still falls short of the stated preference for explicit propagated errors over silent defaults.
**Suggested fix:** Lower priority than the High-severity findings above given the read-mostly, offline-tolerant intent behind most of these — but at minimum a `console.error` in each would give this surface the same diagnostic floor the React app already has via `useMessaging.js`/`useNotes.js`.

### 7. No compile-time type checking exists anywhere on either JS/JSX surface
**Scope:** all of `frontend/src/` and `frontend/js/`
**What's suppressed:** There is no `tsconfig.json`/`jsconfig.json` (with or without `checkJs`), no PropTypes usage anywhere in `frontend/src/`, and no `.eslintrc*` — confirmed by search, not just absence of an obvious file. `frontend/package.json` has no `lint` script. This isn't a suppressed check (nothing here disables an existing one) — it's simply that no compile-time or build-time type/shape checking exists at all for either web surface, so every finding above in this file class had to be found by manual read-through rather than any tool the codebase itself runs.
**Why it's risky:** Purely structural/informational — flagging because the gate's brief is compile-time error handling and this is the most basic fact about that category for this stack. Not treating as a line-level defect since introducing TypeScript/PropTypes/ESLint is an architectural decision outside this review's remit, not a suppressed check to restore.
**Suggested fix:** N/A for this pass — worth a forward note to `compliance-report-agent`/an architecture discussion, not a fix item.

## Reviewed and ruled out (false positives — confirmed safe, not findings)

- `FellowScript/FellowScript/Bible/BibleReaderView.swift:38-39` — `try! NSRegularExpression(pattern: ...)` against two hardcoded, compile-time-constant regex patterns. A `try!` here only ever crashes at first use if the literal pattern itself is malformed, which would surface immediately in any manual test pass — functionally a fail-fast assertion on a constant, not a runtime data-dependent risk.
- `FellowScript/FellowScript/LoadingScreen/LoadingScreenView.swift:100` — `layer as! AVPlayerLayer`. `PlayerContainerView` overrides `class var layerClass: AnyClass { AVPlayerLayer.self }` two lines above (line 99), which is exactly the UIKit contract that guarantees this cast always succeeds.
- `FellowScript/FellowScript/Services/NetworkService.swift:993-1004` — `"...".data(using: .utf8)!` on string-interpolation literals. Swift `String` → UTF-8 `Data` conversion cannot fail for any well-formed Swift `String`; this is a standard, safe idiom.
- Every `switch` over an app-owned enum outside the two cited above (`Models.swift` JSONValue, `EventSetupSheet.swift` recurrence, `AccountView.swift` AccountSheet, `ChatThreadView.swift` uploadState/attachment.kind, `StoreKitManager.swift` purchase result, etc.) is exhaustive with no `default:`, correctly leveraging compiler enforcement — no gap.
- `Dashboard/DashboardComponents.swift:318-333`'s `switch entry.activity_type` uses `default:` deliberately, with an explicit inline comment explaining the fallback mirrors the backend's own missing-type handling — a documented design decision, not a silent gap (contrast with Medium finding #3 above, which has no such rationale).
