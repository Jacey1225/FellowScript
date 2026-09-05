# Compliance Sweep Report — 20260904-frontend-arch-sweep

**Root:** `/Users/jaceysimpson/Vscode/FellowScript` · **Scope:** frontend only (iOS SwiftUI app, React/Vite SPA, legacy static web tree) · **Files reviewed:** 161 of 161 in inventory

---

## Summary

This sweep covered three independently-deployed frontend surfaces — the iOS SwiftUI app (46 files), the React/Vite SPA (94 files), and a legacy static web tree still served in parallel by nginx (21 files) — against seven categories (compile-time error handling, dependency error handling, logic errors, OWASP compliance, iOS guidelines, optimization, readability), producing 52 findings: 4 Critical, 16 High, 19 Medium, 13 Low. The codebase shows genuine evidence of prior remediation work — multiple files carry inline comments citing specific past fix task IDs for exactly the bug classes this sweep checks — but that work has been uneven: the iOS app is comparatively mature (strong error-surfacing conventions, a well-handled App Store compliance posture with no Critical/High iOS-guideline gaps), while the React web app and the legacy static tree carry the large majority of this sweep's Critical and High findings, including two independent stored-XSS vectors, a cross-account private-message disclosure bug, a call-join flow that fails completely silently, and a billing action that can report false success. **Honestly stated: this is not a clean codebase right now** — it has a demonstrated pattern of fixing a bug in one place without applying the same fix to its sibling implementations or neighboring call sites, which is how several of the most serious findings below came to exist.

## Coverage

`file-inventory.json` lists 161 reviewable files as the authoritative review surface (46 iOS, 94 React/JS/CSS, 21 legacy static). Every category agent explicitly reported reviewing the same 161-file scope, with the sole intentional exception of `ios-guidelines-agent`, which correctly limited itself to the 46 iOS files (an iOS-specific category has no reason to touch `frontend/`). No category reported skipping a surface or file wholesale, and several findings are traced across all three surfaces in the same write-up (e.g. the group-note-delete bug reproduced independently in both `frontend/src/hooks/useNotes.js` and `frontend/js/notes.js`), which is only possible if both trees were actually read. Cross-referencing the seven category files' scope statements against `file-inventory.json` shows no gap — coverage is complete. One clerical note: `owasp-compliance.json`'s `finding_count` says 7, but `owasp-compliance.md` enumerates 6 distinct findings (3 High, 2 Medium, 1 Low) — a minor internal miscount in that step's own summary, not a coverage or scope problem; this report uses the 6 counted directly from the document.

## Findings by severity

### Critical (4)

| # | Category | Finding | Location |
|---|---|---|---|
| C1 | Dependency error handling | `useSessions.js`'s Chime call join (`joinSession`) fails completely silently on a failed meeting-creation or attendee-token fetch — no error state, no retry, no visible signal. Regression relative to the already-fixed iOS `CallController`/`ChimeCallView.swift` equivalent. | `frontend/src/hooks/useSessions.js:215-332` (catches at 232, 242) |
| C2 | Optimization | The full 4.2MB `bible.json` translation blob is decoded synchronously on `BibleViewModel`'s `@MainActor`, blocking UI on every app launch (gates the loading screen) and again on first Bible-tab open. | `FellowScript/FellowScript/Bible/BibleReaderView.swift:56-77` |
| C3 | Readability | Three incompatible error-handling conventions coexist for the same "fetch failed" problem across the React hooks layer; most severe in `useSessions.js` (13 bare `catch {}`) and `useAgentChat.js` (10 bare `catch {}`), against sibling hooks `useMessaging.js`/`useNotes.js` that consistently log and surface failures. | `frontend/src/hooks/useSessions.js`, `useAgentChat.js`, `frontend/src/pages/Account.jsx`, others |
| C4 | Readability | The legacy static tree (`notes.js`, `messaging.js`) repeats the same silent-swallow pattern, on the one surface with zero automated test coverage reaching nginx-served production directly. | `frontend/js/notes.js`, `frontend/js/messaging.js` |

### High (16)

| # | Category | Finding | Location |
|---|---|---|---|
| H1 | OWASP | Stored XSS: `RichText.jsx`'s note-HTML sanitizer (`cleanNode`) unwraps disallowed tags without re-scanning the promoted children, letting an inline event-handler attribute (e.g. `onclick`) survive into `dangerouslySetInnerHTML`. Reachable via any group-shared or AI-summarized note. | `frontend/src/components/RichText.jsx:63-113` |
| H2 | OWASP | Stored XSS: group-member usernames are interpolated unescaped into `innerHTML` in the legacy notes filter panel — the one lapse in an otherwise-consistent `escHtml()` pattern across the file. | `frontend/js/notes.js:71-78` |
| H3 | OWASP | Cross-account data leak: `DiskCache` key for friend-DM messages omits the signed-in user id, so one account's cached private message history with a mutual friend can surface under a different account signed in later on the same device. | `FellowScript/FellowScript/Chat/ChatThreadView.swift:81,96` |
| H4 | Dependency error handling | Onboarding tour statically imports `driver.js` live from a CDN with no Subresource Integrity hash; a load failure can break `reader.js`'s entire module graph, not just the tour. | `frontend/js/tour.js:5` |
| H5 | Dependency error handling | `cancelPlan()` never checks the DELETE response status — a rejected/failed subscription cancellation still shows "Plan canceled," a billing-integrity bug. | `frontend/src/components/SubscriptionCard.jsx:171-178` |
| H6 | Dependency error handling | Agent toggle/rename apply optimistic local state without checking the write succeeded — the identical bug already fixed on the iOS side (`NetworkService.swift`'s `updateAgent`/`renameAgent`). | `frontend/src/pages/Account.jsx:339-357` |
| H7 | Dependency error handling | `useAgentChat.js` swallows nearly every failure with zero logging or feedback; the scheduled heartbeat monitor marks a heartbeat "fired" before its POST is confirmed to succeed, so a failed check-in silently never happens for the rest of the day. | `frontend/src/hooks/useAgentChat.js` (multiple sites) |
| H8 | Compile-time error handling | 4 of 7 concurrent fetches in `AccountViewModel.load()` bypass the function's own `statsFailed` error-surfacing mechanism — an inconsistent partial fix of the same bug class the surrounding comments describe fixing for the other 3. | `FellowScript/FellowScript/Account/AccountView.swift:163-222` |
| H9 | Compile-time error handling | Bare `catch {}` in `useBookmarks.js`, `useHighlights.js`, `useAgentChat.js` reproduces the swallowed-failure bug already fixed in `AccountView.swift`/`useMessaging.js`/`useNotes.js`; optimistic bookmark/highlight mutations are never rolled back on failure. | `useBookmarks.js:12,25,36`, `useHighlights.js:15,68,77,97`, `useAgentChat.js:30,45` |
| H10 | Logic errors | Deleting a group note never refreshes the group's note list — a confirmed, reproducible bug present independently in both the React app and the legacy tree, root-caused against the backend's own `group_id IS NULL` filter on `GET /notes/{user_id}`. | `frontend/src/hooks/useNotes.js:167-182`, `frontend/js/notes.js:536-545` |
| H11 | Logic errors | Legacy `deleteNote` never checks the delete request's response status — a failed delete (expired session, 403, 500) is treated identically to a successful one. | `frontend/js/notes.js:536-545` |
| H12 | Optimization | Chat message grouping and day-divider computation are unmemoized computed properties, re-run in full on every SwiftUI render — including every composer keystroke — with an O(n²)-worst-case grouping algorithm underneath. | `FellowScript/FellowScript/Chat/ChatThreadView.swift:354-363`, `MessageGroupRow.swift:46-75` |
| H13 | Optimization | An N+1 fetch-per-friend/per-group pattern for contacts/groups is independently duplicated across three surfaces instead of a batched endpoint. | `useMessaging.js:105-171`, `useNotes.js:91-113`, `frontend/js/notes.js` |
| H14 | Readability | Verse-parsing business logic (not just markup) is copy-pasted near-verbatim between the legacy tree and the React app, with no cross-reference in either file to signal the twin exists. | `frontend/js/bible.js:156-226` vs `frontend/src/utils.js:49-105` |
| H15 | Readability | Two functions both named `escHtml` share an apparent contract but differ in actual escaping coverage (legacy version doesn't escape `"`), a landmine for a maintainer reasoning by analogy across surfaces. | `frontend/js/utils.js:1` vs `frontend/src/utils.js:1` |
| H16 | Readability | `NetworkService.swift` (1453 loc) is a well-documented but monolithic single type spanning ~10 unrelated domains (auth, notes, highlights, agents, contacts, messaging, attachments), with no per-domain file split. | `FellowScript/FellowScript/Services/NetworkService.swift` |

**Cross-category note:** OWASP flags `console.log`/`print` of full note content (`frontend/js/notes.js:356,371`, `NotesListView.swift:370`) as **Medium** under this project's explicit Security Q13 policy ("proactively scrub/redact anything potentially sensitive from logs in every environment... this is now an autonomous-fix-worthy finding"). Readability's write-up flags the *same lines* as a **Low** "leftover debug logging" issue and explicitly argues it's "not security-severity." This is a direct severity disagreement on identical code, not merely two lenses on related-but-different issues. Since the project's own stated Security Q13 preference is unambiguous about logging note content specifically, this report treats it as **Medium** per OWASP's assessment — the readability agent's dismissal appears to have missed that the compliance plan explicitly pre-empts a "notes aren't sensitive" judgment call on this exact point.

## Per-category breakdown

| Category | Critical | High | Medium | Low | Total |
|---|---|---|---|---|---|
| Compile-time error handling | 0 | 2 | 3 | 2 | 7 |
| Dependency error handling | 1 | 4 | 4 | 3 | 12 |
| Logic errors | 0 | 2 | 2 | 1 | 5 |
| OWASP compliance | 0 | 3 | 2 | 1 | 6 |
| iOS guidelines | 0 | 0 | 3 | 3 | 6 |
| Optimization | 1 | 2 | 2 | 1 | 6 |
| Readability | 2 | 3 | 3 | 2 | 10 |
| **Total** | **4** | **16** | **19** | **13** | **52** |

### Compile-time error handling (7 findings)
Evidence of a prior remediation pass for this exact category (inline comments cite specific past fix IDs). Remaining gaps are partial/inconsistent applications of an established fix.
- **High** — `AccountView.swift:163-222`: 4 of 7 concurrent fetches in `load()` bypass the function's own `statsFailed` error banner.
- **High** — React hooks (`useBookmarks.js`, `useHighlights.js`, `useAgentChat.js`): bare `catch {}` reproduces a bug already fixed on iOS and in sibling hooks.
- **Medium** — `MessageAttachments.swift:554-559` / `MessageGroupRow.swift:268-274`: string-typed switch over `attachmentKind` bypasses compiler exhaustiveness the app's own enum already provides.

### Dependency error handling (12 findings)
The iOS app shows a clear prior remediation pass; the React app and legacy tree do not, and in two cases reproduce a bug the iOS side was already fixed for.
- **Critical** — `useSessions.js:215-332`: Chime call join fails completely silently.
- **High** — `frontend/js/tour.js:5`: `driver.js` imported live from a CDN, no SRI, can break `reader.js`'s module load.
- **High** — `SubscriptionCard.jsx:171-178`: `cancelPlan()` never checks the DELETE response status (billing action).

### Logic errors (5 findings)
Headline: a confirmed, reproducible state bug independently present on two surfaces.
- **High** — `useNotes.js:167-182` / `frontend/js/notes.js:536-545`: deleting a group note never refreshes the group's note list, root-caused against the backend's own query filter.
- **High** — `frontend/js/notes.js:536-545`: legacy `deleteNote` never checks the delete response status.
- **Medium** — `useMessaging.js:46-65`: WebSocket handler performs a `setMessages` side effect from inside a `setCurrentContact` updater function — impure updater risks duplicated chat bubbles under React 18 StrictMode double-invocation.

### OWASP compliance (6 findings)
No Critical findings; three High findings are all genuine, traced exploit paths, not keyword hits.
- **High** — `RichText.jsx:63-113`: stored XSS via nested-tag sanitizer bypass.
- **High** — `frontend/js/notes.js:71-78`: stored XSS via unescaped usernames in the legacy notes filter.
- **High** — `ChatThreadView.swift:81,96`: cross-account DM cache-key collision leaks private message history between accounts on a shared device.

### iOS guidelines (6 findings) — see dedicated section below
- **Medium** — Reduce Motion support is inconsistent across 10+ animation-heavy files.
- **Medium** — The AmazonChimeSDK privacy-manifest patch build phase warns and continues (doesn't fail the build) if the framework path it patches ever moves.
- **Medium** — `aps-environment` is hardcoded `development` in the shared entitlements file (likely corrected by Xcode's automatic signing at archive time, but unverified in this sweep).

### Optimization (6 findings)
- **Critical** — `BibleReaderView.swift:56-77`: 4.2MB `bible.json` decoded synchronously on the MainActor, on the app's cold-start path.
- **High** — `ChatThreadView.swift:354-363` / `MessageGroupRow.swift:46-75`: unmemoized, O(n²)-worst-case message grouping recomputed on every render.
- **High** — N+1 fetch-per-friend/per-group pattern duplicated across `useMessaging.js`, `useNotes.js`, and legacy `notes.js`.

### Readability (10 findings)
The largest finding count and both Critical-severity items in this sweep are here — both about *inconsistency of convention* rather than a single bad line.
- **Critical** — Three incompatible error-handling conventions coexist for the same operation class across the React hooks layer.
- **Critical** — The legacy tree repeats the silent-swallow pattern with zero test backstop.
- **High** — Verse-parsing logic (not just markup) duplicated between `bible.js` and `utils.js`; two identically-named `escHtml` functions differ in actual behavior; `NetworkService.swift` is a 1453-line monolith spanning ~10 domains.

## iOS guidelines

**This category ran.** `scope.json` confirmed an iOS target (`FellowScript/FellowScript/FellowScript.xcodeproj`), so `ios-guidelines-agent` executed against all 46 reviewable iOS files. Result: **no Critical or High findings** — the target already correctly implements Guideline 1.2 (zero-tolerance re-consent, in-app blocking/reporting), Guideline 4.8 (equal-prominence Sign in with Apple), Guideline 5.1.1(v) (in-app account deletion), Guideline 3.1.2/3.1.3(b) (StoreKit-native trial, no external checkout), and correct export-compliance declarations. 3 Medium and 3 Low findings remain (Reduce Motion coverage, a fail-open privacy-manifest patch build phase, an unverified `aps-environment` value, a hand-built Sign in with Apple button, and two scope-boundary notes). One methodology caveat carried forward from that step: the `appstore` skill (its nominal source for the guideline checklist) is configured for explicit-invocation-only and could not be loaded, so this category applied Apple's public guideline text directly rather than that skill's specific checklist verbatim — worth a follow-up pass with that skill available if a submission is imminent.

## Recommended order of fixes

Ordered by actual risk (security and data-integrity first, then user-facing breakage, then systemic patterns, then structure/performance), not grouped by category:

1. **Fix the two stored-XSS vectors** (H1, H2) — `RichText.jsx`'s sanitizer bypass and the legacy `notes.js` unescaped-username injection. Both are live, traced exploit paths reachable by any group member, not theoretical.
2. **Fix the cross-account DM cache-key collision** (H3) — one-line fix (key by `sessionKey`, not bare `contact.id`), closes a real private-data disclosure on shared devices.
3. **Fix the silent Chime call-join failure** (C1) — the core video/voice call feature currently fails with zero user-visible signal; add error state + retry.
4. **Fix `cancelPlan()`'s missing response check** (H5) and **`Account.jsx`'s optimistic agent toggle/rename** (H6) — both billing/state-integrity bugs that can show false success.
5. **Fix the group-note-delete staleness and missing status check** (H10, H11) — confirmed reproducible bug on both web surfaces; the legacy version additionally treats failed deletes as successful.
6. **Move `bible.json` decoding off the main actor** (C2) — straightforward fix (background `Task`, hop back for the published-property assignment) with an outsized cold-start latency payoff.
7. **Resolve the systemic bare-`catch{}` / inconsistent error-handling pattern** (C3, C4, H7, H8, H9) as one consolidated effort rather than file-by-file: bring `useSessions.js`, `useAgentChat.js`, `useBookmarks.js`, `useHighlights.js`, `Account.jsx`, and the legacy `notes.js`/`messaging.js` up to the standard `useMessaging.js`/`useNotes.js` already establish (log + surface every failure). This single pattern underlies roughly a third of this sweep's Critical/High findings.
8. **Fix `driver.js`'s CDN import** (H4) — bundle from the already-declared npm dependency instead of a live, non-SRI CDN fetch that can break `reader.js`'s module graph.
9. **Memoize chat message grouping and add a batched contacts/groups endpoint** (H12, H13) — the two clearest interactive-latency wins.
10. **Redact note-content logging** (OWASP M1 / cross-category note above) — drop the payload arguments from `console.log`/`print` calls in `notes.js` and `NotesListView.swift`, per the project's own explicit no-exceptions logging policy.
11. **Split `NetworkService.swift`, `AccountView.swift`, and `NotesListView.swift`** by domain/section (H16 and the related Medium readability findings) — no behavior change, pure file-organization work that directly serves this project's own stated #1 maintainability priority (separation of responsibilities).
12. **Deduplicate the `bible.js`/`utils.js` verse-parsing logic and the two divergent `escHtml` implementations** (H14, H15) — at minimum add cross-referencing comments now; consider consolidation if a shared build step is ever introduced for the legacy tree.
13. **Address remaining iOS Medium findings before the next submission**: make the AmazonChimeSDK privacy-manifest patch fail the build instead of warning, verify `aps-environment` reads `production` in an actual archive, and extend Reduce Motion support to the remaining animation-heavy views.
14. **Remaining Medium/Low items** (hardcoded API-base-URL duplication across two config files, `NetworkService.swift`'s hardcoded timeout/no-retry policy, per-call `JSONEncoder`/`JSONDecoder` allocation, `DiskCache.swift`'s silent disk-I/O failures, non-transitive sort comparators, floating SPM version requirements) — lower urgency, address opportunistically alongside the work above.
