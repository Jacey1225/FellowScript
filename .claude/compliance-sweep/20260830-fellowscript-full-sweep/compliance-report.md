# FellowScript Compliance Sweep — Final Report

Task: `20260830-fellowscript-full-sweep` · Step 10 (`compliance-report-agent`)

## Summary

This sweep reviewed FellowScript's full monorepo — the FastAPI backend (`api/`), the Swift/SwiftUI iOS app (`FellowScript/`), the dual-stack web frontend (`frontend/`, both a legacy vanilla-JS site and a React/Vite app), and the Tauri desktop shell (`desktop/`), plus supporting `docs/`/`data/` — across seven fixed categories (compile-time error handling, dependency error handling, logic errors, OWASP compliance, iOS guidelines, optimization, readability), producing **62 findings**: **7 Critical, 21 High, 19 Medium, 15 Low**. The honest overall state: the codebase has clearly been through real, documented hardening cycles (the auth/session layer, webhook verification, and much of the trust/safety surface are well-built and covered by a 46-file regression suite), but it currently ships with two live secret-exposure incidents (real user credentials and an SSH key sitting in git), a foundational data-layer bug that lets writes fail silently and get reported as success across ~30+ call sites, three authorization gaps that let any authenticated user read or write data they shouldn't, and an actively-maintained dead code path (the legacy frontend) burning ongoing engineering time for zero production benefit. This is not a codebase in crisis, but it is not currently safe to treat as "compliant" — the Critical findings need same-day attention, starting with the two secrets.

## Coverage

Step 1's inventory (`file-inventory.json`) lists **374 reviewable files** across `api/` (103), `FellowScript/` (103, including test targets), `frontend/` (117, both stacks), `desktop/` (11), and `docs/`/`data/`/root-level infra (the remainder). Every category's "scope reviewed" section demonstrates it worked from this inventory rather than rediscovering scope independently, and cross-checking the seven category files against the inventory shows real coverage of every named area:

- **`api/`** — all four backend surfaces (routes, backend/ managers, schemas, db.py) reviewed by every applicable category; `db.py`'s shared `DBManager` layer specifically was independently flagged by both logic-errors and OWASP.
- **`FellowScript/`** — full 43-file app target triaged for compile-time patterns (all 216 `try?` sites), reviewed for logic (Bible/notes/heartbeat view models), OWASP-relevant client behavior, dedicated iOS-guidelines pass, optimization (Bible reader regex), and readability/dead-code (BibleReaderView corruption, MockDataService verification).
- **`frontend/`** — both stacks (legacy vanilla-JS and React) explicitly diffed against each other by logic-errors (notes normalization) and called out as a live-vs-dead pair by readability; dependency-errors and OWASP both reviewed fetch/WebSocket/sanitizer code in both stacks.
- **`desktop/`** — reviewed by compile-errors (Rust boilerplate, clean), dependency-errors (Cargo manifest/lockfile), and OWASP (Tauri CSP/capabilities misconfiguration, Medium M5). Its 11-file footprint is small enough that light-touch coverage here is proportionate, not a gap.
- **`docs/`/`data/`** — `data/users.json`, `data/notes.json`, `data/messages.json` got dedicated OWASP scrutiny (the Critical PII finding); `data/bible copy.json`, root `messages.json`, `api/schema_tree.md`, and `ios/README_iOS.md` were all individually assessed by readability for staleness.

No significant portion of the inventory was skipped by every category. The one soft spot: no category ran static analysis tooling (no `mypy`/`pyright`, no ESLint actually installed) — this is itself a compile-error finding (#6/#7), not a gap in the sweep's own coverage, since the agents correctly identified and reported the absence of those gates rather than silently working around it.

## Findings by severity — Critical

| # | Category | Location | Finding |
|---|---|---|---|
| C1 | OWASP | `data/users.json`, `data/messages.json`, `data/notes.json` | Real user PII and bcrypt password hashes (confirmed real, including the project owner's own email) committed to git as a "fixture" |
| C2 | OWASP | `fellowscript-ec2-key.pem` (git history, commit `0ef0b629`) | SSH private key committed to git history; removed from tracking later but never purged from history — still recoverable today |
| C3 | Logic errors | `api/db.py:910-964` (`DBManager.insertion`/`.update`/`.delete`) | Every DB write silently swallows SQL errors and returns the same value as success; ~30+ call sites (session creation, note CRUD, friend/subscription multi-step ops) report success to the end user even when nothing was written |
| C4 | Compile-time errors | `FellowScript/FellowScript/Account/AccountView.swift:592` | Account deletion `try?`-swallows failure, then unconditionally signs the user out — user believes an irreversible deletion succeeded when it may not have |
| C5 | iOS guidelines | Missing `PrivacyInfo.xcprivacy` (app-wide) | No privacy manifest exists despite confirmed production `UserDefaults` usage (a "required reason" API) in `BibleReaderView.swift`, `HeartbeatScheduler.swift`, `AppState.swift` — App Store submission risk |
| C6 | Readability | `frontend/js/`, `frontend/css/`, `account.html`/`reader.html`/`signin.html` | Legacy vanilla-JS frontend confirmed dead in production (`deploy.sh` never ships it) yet was actively bug-fixed in lockstep with the React app 5 days before this sweep, with zero CI enforcement to catch divergence |
| C7 | Readability | `FellowScript/FellowScript/Bible/BibleReaderView.swift:968` | A local absolute file path (`/Users/.../node_modules/...`) was accidentally spliced into a Bible verse string ~8 weeks ago and never noticed — also a live content-correctness bug |

## Findings by severity — High

| # | Category | Location | Finding |
|---|---|---|---|
| H1 | OWASP | `api/routes/notes.py:191-249,357-395` | Any user can post/retarget a note into a group they aren't a member of (IDOR) — the write path lacks the membership check the read path (`community.py`) already has |
| H2 | OWASP | `api/routes/messaging.py:28-59,62-68,111-124` | A duplicate, unguarded Chime call-join path lets any authenticated user join a private group's live video call (IDOR) — the parallel `devotion.py::join_call` route already has the missing `is_authorized` check |
| H3 | OWASP | `api/main.py:531-551` | `GET /user/{user_id}` returns any user's email, MFA status, friend requests, and suspension status to any authenticated caller — far beyond the endpoint's stated "look up a username" purpose |
| H4 | Dependency errors | `api/backend/subscription/stripe_service.py:118-125` → `api/routes/subscription.py:358-373` | Stripe cancellation failure is swallowed; the local plan row is deleted anyway, orphaning a still-live, still-billing Stripe subscription with no local record |
| H5 | Dependency errors | `api/backend/interactions/agent.py:200-241` → `api/routes/agent.py:130-151` | The once-per-day heartbeat DB claim commits before an unhandled OpenRouter call; a network failure burns the day's slot with no note produced and no retry possible |
| H6 | Compile-time errors | `AccountView.swift` (multiple), `ChatRootView.swift:280,294,493-501`, `NotesListView.swift:235-239` | Systemic: delete/remove/leave/block/report actions use bare `try?` with no revert/resync — a failed block or abuse report leaves the user believing they're protected when they aren't |
| H7 | Compile-time errors | `AccountView.swift:334-379` | Subscription cancel/leave/remove/decline actions swallow errors with no user-facing feedback, inconsistent with sibling methods in the same class |
| H8 | Optimization | `api/backend/interactions/groups.py:81-92` (`fetch_group`) | N+1 queries (2 per group member) on the primary group-open path |
| H9 | Optimization | `api/backend/interactions/groups.py:39-48` (`format_messages`) | N+1 username resolution per message, compounding H8 on the same call path |
| H10 | Optimization | `api/backend/interactions/groups.py:154-166` (`fetch_notes`) | N+1 username resolution per page on the infinite-scroll notes feed |
| H11 | Optimization | `api/backend/interactions/groups.py:200-202` (`fetch_highlights`) | N+1 query per group member on the shared-highlights view |
| H12 | Optimization | `api/backend/interactions/websockets.py:142-153` (`ConnectionManager.send_msg`) | N+1 device-token lookup for offline recipients on every chat message send — one of the highest-frequency paths in the app |
| H13 | iOS guidelines | `Package.resolved` / `ChimeCallView.swift` | AmazonChimeSDK 0.27.3 is the one third-party SDK that actually ships in the binary; its own privacy-manifest coverage is unverified and can't be authored on its behalf |
| H14 | iOS guidelines | `AccountView.swift` (subscription purchase flow, ~699-985) | Privacy Policy / Terms of Use links exist elsewhere in the same screen but not on the purchase surface itself — a common real-world Guideline 3.1.2 rejection reason |
| H15 | Readability | root `messages.json` | Stray, diverged duplicate of `data/messages.json`; unreachable by any code path; untouched since the initial launch commit (3.5+ months) |
| H16 | Readability | `ios/README_iOS.md` | Documents a project structure (`ios/FellowScript.xcodeproj`, manual `MockDataService` swap) that no longer exists; ~8 weeks stale relative to the current app |
| H17 | Readability | `data/bible copy.json` | Untouched, unreferenced literal duplicate of `data/bible.json`, 3+ months stale |
| H18 | Readability | `api/db.py` (975 lines) | Mixes the live `DBManager` class (183 callers across the backend) with a dead one-off JSON→Postgres migration script, no internal separation |
| H19 | Readability | `api/main.py` | Auth/user endpoints are defined inline instead of extracted to `api/routes/`, breaking the module-boundary convention every other feature area follows — the single most security-sensitive endpoint surface is also the one exception |
| H20 | Readability | `api/db.py:630` vs `api/main.py:136` | Two functions both named `load_users()` with entirely different meanings (dead JSON-fixture read vs. live Postgres query) |
| H21 | Readability | `api/main.py:153-165` (`persist_new_user`) | Docstring describes a dual JSON+Postgres write that no longer happens post-migration — stale documentation that would mislead a future debugger |

## Per-category breakdown

### 1. Compile-time error handling — 8 findings (1 Critical, 2 High, 2 Medium, 3 Low)
Reviewed all 216 Swift `try?` sites, Rust boilerplate, Python type-suppression, and frontend lint config. Top findings: C4 (account deletion), H6/H7 (systemic swallowed errors on delete/leave/block/report flows across `AccountView.swift`, `ChatRootView.swift`, `NotesListView.swift:235-239`). Notable pattern: a prior remediation pass clearly fixed this exact issue for create/update flows but missed the corresponding delete/remove flows.

### 2. Dependency error handling — 9 findings (0 Critical, 2 High, 4 Medium, 3 Low)
Reviewed every manifest/lockfile and third-party/network boundary. Top findings: H4 (Stripe cancellation swallowed, orphaned billing), H5 (heartbeat claim burned on OpenRouter failure), and a Medium finding covering pervasive empty `catch {}` blocks on `fetch()` across both frontend stacks (`frontend/js/messaging.js`, `frontend/src/hooks/useMessaging.js`, `useNotes.js`). `requirements.txt` and `Package.resolved` are exemplary (fully pinned); npm audit is clean.

### 3. Logic errors — 2 findings (1 Critical, 0 High, 0 Medium, 1 Low)
Small finding count but the Critical (C3, `DBManager.insertion`/`.update`/`.delete`) is foundational — it underlies the auth session and note-CRUD paths and is traced to concrete scenarios (a "successful" login that issues a cookie for a session row that was never written; a note create/edit/delete that returns success with no row persisted). The rest of the reviewed surface (session/MFA managers, subscription state machines, watchdog cursor logic) held up well.

### 4. OWASP compliance — 13 findings (2 Critical, 3 High, 6 Medium, 2 Low)
*(Note: the category's own `owasp-compliance.json` reports `finding_count: 14`, but the document itself enumerates 13 distinct findings — C1-C2, H1-H3, M1-M6, L1-L2. This is a minor metadata discrepancy in that step's own summary, not a coverage gap; all 13 findings are captured above.)* Top findings: C1/C2 (secrets in git — see above), H1/H2 (IDOR on notes and video-call join). Backend fundamentals (session hashing, webhook signature verification, prompt-injection defenses) were confirmed sound and explicitly not flagged.

### 5. iOS guidelines — 7 findings (1 Critical, 2 High, 2 Medium, 2 Low)
**This category ran** (`scope.json.has_ios: true`, confirmed via `FellowScript.xcodeproj` + `Info.plist`). Top findings: C5 (missing privacy manifest — the clearest App Store submission blocker in this entire sweep), H13 (unverified third-party SDK privacy manifest), H14 (Terms/Privacy links missing from the purchase screen). Several guideline requirements (UGC report/block, Sign in with Apple parity, in-app account deletion, subscription restore) were confirmed already correctly implemented.

### 6. Optimization — 9 findings (0 Critical, 5 High, 2 Medium, 2 Low)
All 5 High findings are the same root cause — per-loop-iteration `DBManager.lookup()` calls instead of one batched query — concentrated in `GroupsManager` and `ConnectionManager.send_msg`, all on live, frequently-hit user paths (group open, chat send, notes scroll). The fix shape is already modeled correctly elsewhere in the same package (`FriendsManager`, `ActivityManager`), making this a scoped cleanup rather than a redesign.

### 7. Readability — 14 findings (2 Critical, 7 High, 3 Medium, 2 Low)
Carried a dedicated dead/production-dormant-code focus per the compliance plan's user-relayed instruction. Headline: C6 (actively double-maintained dead frontend) and C7 (corrupted Bible verse content). The general-structure findings (H18-H21) all point at the same underlying issue — `api/db.py` and `api/main.py` both mix live, load-bearing code with dead or one-off migration-era code in the same file, with no boundary between them.

## iOS guidelines — ran

`scope.json` confirmed `has_ios: true` (iOS project found at `FellowScript/FellowScript.xcodeproj`), so Step 7 (`ios-guidelines-agent`) executed and produced `ios-guidelines.md`/`ios-guidelines.json` — its findings are folded into this report above. This category was not skipped.

## Recommended order of fixes

This list is prioritized by real-world consequence across all categories, not grouped by category — a few Critical items (the two secrets) need attention today; the rest of the Criticals and the authorization-boundary Highs should follow before anything else on this list.

1. **Rotate the two exposed secrets immediately** (C1, C2): force password resets or hash invalidation for the users in `data/users.json`, and rotate/revoke the EC2 key authorized by `fellowscript-ec2-key.pem`. Then purge both from git history (`git filter-repo`/BFG) — deleting the files from `HEAD` alone does not remove them from history, as C2 itself demonstrates.
2. **Fix the silent-write-failure bug in `api/db.py`** (C3): make `insertion`/`update`/`delete` signal failure instead of returning the same value as success. This is the highest-leverage fix in the sweep — it underlies both the session-creation and note-CRUD failure modes, and likely several of the "why did this silently not work" reports users may already be filing.
3. **Fix account deletion** (C4) so a failed `deleteUser` call blocks sign-out and surfaces an error, rather than letting the user believe an irreversible action succeeded.
4. **Close the three authorization gaps** (H1 notes IDOR, H2 Chime call-join IDOR, H3 excessive user-data exposure) — these are the "hard stop" category the user's own security posture flags as non-negotiable regardless of review context.
5. **Add the iOS privacy manifest** (C5) before the next App Store submission attempt — this alone will block or flag a build today.
6. **Fix the financial/trust-safety error-handling gaps**: Stripe cancellation-then-delete (H4), the heartbeat claim-burn (H5), and the systemic swallowed try? on block/report/leave flows (H6, H7) — these directly affect billing correctness and user safety/trust features.
7. **Batch the five N+1 query patterns** in `GroupsManager`/`ConnectionManager` (H8-H12) — straightforward, low-risk fixes already modeled correctly elsewhere in the same file tree, and they sit on the app's highest-traffic paths.
8. **Close the remaining iOS submission risks** (H13 third-party SDK manifest check, H14 purchase-screen Terms/Privacy links) alongside the privacy manifest work in step 5.
9. **Decide the fate of the legacy frontend** (C6): either retire `frontend/js/`/`frontend/css/`/`account.html`/`reader.html`/`signin.html` for good, or make deployment actually use them — the current state (actively maintained, never shipped) is pure waste and a divergence risk.
10. **Fix the corrupted Bible verse string** (C7) — a one-line, zero-risk fix.
11. **Clean up the remaining dead artifacts** (H15 root `messages.json`, H16 `ios/README_iOS.md`, H17 `data/bible copy.json`) and the **`api/main.py`/`api/db.py` structural issues** (H18-H21) — lower urgency, but each one currently costs a future contributor real time (a misleading docstring, a naming collision, an 877-line file that hides the auth surface).
12. Address the remaining Medium and Low findings in each category file opportunistically — none block a release on their own, but several (the pervasive empty `catch {}` blocks in both frontends, the missing `DB_PASSWORD` fail-fast check, the MFA rate-limiting gap, the full-environment handoff to the CloudWatch MCP subprocess) are worth batching into the next hardening pass rather than deferring indefinitely.
