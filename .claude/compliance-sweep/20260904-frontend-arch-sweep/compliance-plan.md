# Compliance Plan — 20260904-frontend-arch-sweep

## Scope

Three independent frontend surfaces, all under `/Users/jaceysimpson/Vscode/FellowScript`, as enumerated authoritatively in `file-tree.md` / `file-inventory.json` (161 reviewable files total):

1. **iOS app** — `FellowScript/FellowScript/` (SwiftUI target), 46 reviewable files. `FellowScriptTests/` and `FellowScriptUITests/` are explicitly excluded (per the original request), as are 44 binary/generated/data files (asset-catalog metadata, PNGs, fonts, the `.mov` loading screen, license docs, and the 4.2MB `bible.json` translation blob + its backup).
2. **React/Vite web app** — `frontend/src/`, 94 reviewable files (components, panels, pages, hooks, context, lib, styles, colocated tests).
3. **Legacy static web tree** — `frontend/{account,reader,signin}.html`, `frontend/css/`, `frontend/js/`, 21 reviewable files. Confirmed actively maintained and served directly by nginx in parallel with (not superseded by) the React app — this was wrongly excluded in an earlier pass of `file-tree.md` and has since been corrected in.

**Explicitly out of scope:** `api/` (backend — this is a frontend-only sweep per the user's request), `frontend/node_modules/`, `frontend/dist/`, `frontend/package-lock.json`, `frontend/index.html` (Vite entry shell — flagged by file-tree-agent as an open scope question; ruled here as **out of scope**, since it's a near-empty bootstrap shell, not application logic — downstream agents should not treat its omission as an oversight), top-level `ios/` (empty), and repo-root noise (`.git/`, `.venv/`, `data/`, `docs/`, secrets, etc.).

`file-tree.md` is the authoritative file list for every category agent below — work through it directly rather than re-discovering scope.

## Stack

- **iOS**: Swift / SwiftUI, Xcode project at `FellowScript/FellowScript/FellowScript.xcodeproj`. StoreKit (`FellowScript.storekit`, `StoreKitManager.swift`), Apple/Google Sign-In, Amazon Chime (voice/video calls, mirrored by `amazon-chime-sdk-js` on web), custom networking (`Services/NetworkService.swift`, 1453 loc — largest Services file), disk caching, app-state management.
- **React web app**: React 18.3 + Vite 6, React Router 7, Vitest 4 / Testing Library (React 16, DOM 10, jest-dom 7) for the test suite, Ant Design 5 (+ `@ant-design/icons`) as a component base, `dockview-react` (panel/dock layout — the Reader feature's dockable UI), `driver.js` (onboarding tour), `react-markdown`, `dayjs`, `amazon-chime-sdk-js`. Package manifest: `frontend/package.json`.
- **Legacy static tree**: vanilla JS (ES modules, no bundler/build step), hand-authored CSS, static HTML — pre-React-migration architecture, no framework, no test runner config beyond two ad hoc `*.test.js` files.
- **Shared backend dependency**: all three surfaces talk to the same `api/` service (out of scope for this sweep, but relevant context for any cross-surface data-contract or auth-flow observations).

## iOS target

**Present.** `FellowScript/FellowScript/FellowScript.xcodeproj`, app source under `FellowScript/FellowScript/` (SwiftUI, feature-folder organization: Account, Auth, Bible, Chat, Dashboard, Notes, Onboarding, plus Services/ and Theme/ layers). `Info.plist` at `FellowScript/FellowScript/Info.plist`. This gates Step 7 (`ios-guidelines-agent`) — it should run.

## Review categories

The fixed list this pipeline always runs, applied across all three in-scope surfaces:

1. Compile-time error handling
2. Dependency error handling
3. Logic errors
4. OWASP compliance
5. iOS guidelines compliance (applicable — see above)
6. Optimization
7. Code structure & readability

## Preference profile

Established answers from `~/Downloads/ai_preference_survey_tracker.md` (all four consulted modules — Proposed Architecture/Implementation Philosophy, UI/UX Design Philosophy, Security Posture, Configuration Philosophy — are marked **Complete** in the status table) relevant to this sweep's categories:

### Readability / maintainability / error-handling (feeds compile-error, dependency-error, logic-error, readability)

- **Implementation Q12 (readability):** Always prefer explicit/verbose step-by-step code over concise/idiomatic-but-denser equivalents. Flag dense one-liners or clever idioms in the React/legacy JS or Swift code that trade clarity for brevity.
- **Implementation Q13-15 (comments/docs):** Thorough documentation of important logic — both *what* and *why* — expected for non-trivial functions; significant architectural decisions should have both inline/module-level docs and be discoverable at a "centralized" level. Flag complex functions (e.g. `NetworkService.swift` 1453 loc, `NotesListView.swift` 2024 loc, `AccountView.swift` 2174 loc, `NotesPanel.jsx` 834 loc, `reader.css` 2283 loc) that lack any why-level explanation.
- **Implementation Q17 (maintainability ranking):** Priority order — clear separation of responsibilities > easy to extend > good error handling > clear configuration > easy debugging > strong tests > easy to modify > good documentation > stable dependencies > minimal technical debt > consistent conventions > easy-to-understand code. Use this ranking when triaging which readability/logic findings matter most.
- **Implementation Q26-27 (error handling):** Explicit checks and clear error returns; propagate errors upward rather than silently substituting defaults on missing/malformed data. Flag any swallowed exception, silently-defaulted null/undefined, or bare `catch` block that doesn't re-throw or surface the failure — this applies equally to Swift `try?`/`catch` blocks, JS `.catch()` handlers, and the legacy vanilla-JS `fetch` error paths.
- **Implementation Q25 (naming):** Clarity beats rigid convention — don't flag reasonable, contextually-clear names purely for inconsistency with a strict scheme.
- **Implementation Q29 (dependencies):** Mature libraries are preferred even if the dependency tree grows — don't flag React app's use of Ant Design, dockview-react, driver.js, amazon-chime-sdk-js etc. as bloat; that's the established preference, not a violation.
- **Implementation Q23-24 (extensibility):** Comfortable with proactive, fairly-complete extensibility architecture ahead of need — don't flag deliberate up-front abstraction/interfaces as premature, but do flag arbitrary layering that isn't coherent.
- **Implementation Q28 (concurrency):** Architecture should account for concurrency early where relevant — worth checking iOS `async`/`await`/Task usage in `NetworkService.swift`, `ChimeCallView.swift`, and the React `useMessaging`/`useAgentChat`/`useSessions` hooks for race conditions or missing cancellation handling, given this is a chat/call-heavy app.
- **Implementation Q34:** When forced to choose, maintainability beats delivery speed — weight findings accordingly rather than excusing shortcuts as "shipped fast."

### Security posture / severity handling (feeds owasp-compliance)

- **Security Q2 (secure defaults):** Deny-by-default — new endpoints/resources should start maximally locked-down. On the client side, check that auth-gated views/routes (React Router routes, SwiftUI navigation) don't render or fetch privileged data before an auth check resolves.
- **Security Q7 (input validation):** Consequence-scoped — defense-in-depth for sensitive/high-stakes data paths (auth, payments/StoreKit, PII-bearing forms), boundary-only validation acceptable elsewhere. Don't demand redundant validation everywhere uniformly.
- **Security Q13 (sensitive info in logs):** Proactively scrub/redact anything potentially sensitive (tokens, PII, request/response bodies) from logs in *every* environment, not just pre-production. Flag any `console.log`/`print`/`NSLog` that could leak a token, session id, or user PII — this is now an **autonomous-fix-worthy finding**, not something requiring escalation, per Security Q16's narrowing.
- **Security Q14 (fail-closed):** Fail closed by default — flag any ambiguous-failure security-relevant check (auth/session validity check, signature/token verification, permission gate) that doesn't deny/block on an unresolved or errored state.
- **Security Q16 (hard-stop list, narrowed):** SQL injection, XSS, known-vulnerable dependencies, and sensitive-info-in-logs are now autonomous findings (fix-worthy, not escalation-worthy) — but authorization/permission-model changes, network/firewall exposure, and anything changing the app's security boundary remain flag-and-escalate, not auto-fix (moot for a review-only pipeline, but relevant to how `owasp-compliance-agent` should frame severity/urgency language).
- **Security Q1 (convenience vs. security):** Risk-scoped, not blanket — session/token longevity and similar trade-offs should be judged by what's actually protected (financial/PII-adjacent leans secure; low-stakes/cosmetic leans convenient). Relevant to reviewing `AuthContext.jsx`, `AppState.swift` token persistence, and `DiskCache.swift`.
- **Security Q6 (secrets):** Env vars/`.env` are the accepted default mechanism (not itself a finding) — but check that no secret/API key is hardcoded directly into client-shipped source (`frontend/js/config.js`, `frontend/src/config.js`, Swift `Services/`) rather than injected via build-time env var, since anything in client-shipped JS/Swift is inherently public regardless of the "acceptable secrets mechanism" answer.

### Configuration / secrets-handling (feeds dependency-error and owasp-compliance)

- **Configuration Q1 (config vs. hardcoded):** Tunables (timeouts, retry counts, page sizes) should be exposed as configuration by default, not hardcoded — flag hardcoded magic numbers for things like API timeouts/retry counts if found inline in `NetworkService.swift`, `useMessaging.js`, etc.
- **Configuration Q2 (env vars):** Env vars are reserved strictly for deployment-specific values (e.g. API base URL) — application-behavior tunables belong in structured config, not scattered `.env` entries. Relevant when reviewing `frontend/src/config.js` (2 loc) and `frontend/js/config.js` (11 loc) — check these are doing deployment-value injection, not smuggling behavior config.
- **Configuration Q4 (defaults):** No implicit defaults anywhere — every value should be explicitly set and validated eagerly (fail fast), not silently defaulted. Flag any `?? someDefault` / `|| fallbackValue` pattern masking a genuinely required config value rather than a legitimate optional one.
- **Configuration Q9 (secrets vs. config):** Secrets need a completely separate mechanism from ordinary config — never appearing in any dump, log, or the example config file. Cross-check against Security Q13's log-redaction requirement.
- **Configuration Q12 (backward compatibility):** Config/schema changes should maintain backward compatibility by default (deprecation path, not a breaking rename) — relevant if reviewing any local-storage/cache schema versioning in `DiskCache.swift` or browser `localStorage` usage in the hooks layer.

### UI/UX-specific (feeds readability and, secondarily, optimization — this project's client-heaviest category)

- **UI/UX Q14 (accessibility):** WCAG AA is the hard floor everywhere (AAA where practical); accessibility wins over visual mood by default. Check both web surfaces for keyboard nav, focus management (`useFocusTrap.js` exists — verify it's actually used where modals/overlays need it), semantic HTML/ARIA in the legacy static tree (no framework to provide this for free), and color-contrast in `global.css`/`reader-dock.css`/legacy `css/*`. Also check `prefers-reduced-motion` support is first-class (Q14.3) given the animation-heavy vaunted style.
- **UI/UX Q12 (components):** Custom-built components, reuse allowed to emerge rather than being mandated up front — don't flag near-duplicate small components across React `components/` as a violation unless they've clearly crossed into copy-pasted business logic (which would instead be a logic-error/duplication finding, see Notes below).
- **UI/UX Q17 (error/empty/loading states):** Expect minimal, unfussy treatments (plain spinner, minimal empty-state note, warm on-brand error copy) — flag both overly elaborate *and* overly bare/technical-looking states as deviations from this stated preference.
- **UI/UX Q10.3:** No keyboard-shortcut support expected by default — don't flag its absence as a gap unless a specific feature calls for it.

## Notes

- **Three independently-deployed surfaces, zero shared code.** The iOS app, the React SPA, and the legacy static tree all talk to the same `api/` backend but do not share any client-side code. Duplication/drift findings should be scoped *within* a surface (e.g. repeated logic inside `frontend/src/`) as well as *across* surfaces where the same feature is reimplemented twice — see the Reader case below — but cross-surface differences are not automatically bugs; they may simply be two independent, intentionally-separate implementations.
- **`frontend/js/reader.js` + `frontend/css/reader.css` vs. `frontend/src/pages/Reader.jsx`** are parallel, independently-maintained implementations of the same Bible-reader feature. `reader.css` alone is 2,283 lines — the largest CSS file in the project by a wide margin. Flag this pairing explicitly to the logic-error and optimization agents as a maintenance-burden hotspot: two implementations of core functionality that must be kept in sync by hand, with no shared source of truth.
- **The legacy tree has no automated test coverage worth relying on** — only `notes.js` and `utils.js` have any tests at all; the 3 HTML pages and 6 CSS files have zero coverage. This is the one surface where a regression reaches nginx-served production with no automated check catching it first. Weight logic-error and readability findings in `frontend/js/` and `frontend/css/` accordingly — treat this surface with more scrutiny, not less, precisely because nothing else is backstopping it.
- **Two untracked, in-progress "attachments" feature files** exist on both platforms: `FellowScript/FellowScript/Chat/MessageAttachments.swift` (682 loc, untracked) and `frontend/src/components/ChatThread.attachments.test.jsx` (330 loc, untracked) + `frontend/src/hooks/useMessaging.attachments.test.js` (188 loc, untracked). Review these as first-class inventory members, but note they're pre-commit/WIP — findings here may reflect work still in flight rather than a shipped regression.
- **Naming collisions across surfaces are a landmine for basename-only searches**: `notes.js` (legacy) vs. `NotesListView.swift`/`NoteEditorView.swift` (iOS) vs. `NotesPanel.jsx` (React); two distinct `utils.js` files (legacy, 42 loc vs. React, 105 loc) at different paths. Always disambiguate by full path.
- **`Bible/bible.json` (4.2MB, excluded from line-by-line review)** is loaded at runtime by `BibleReaderView.swift` — worth the optimization agent's attention for bundle size / load strategy even though the data file itself isn't reviewed.
- **`frontend/index.html` is deliberately left out of scope** (see Scope section) — this is a considered decision by this step, not an inherited gap from Step 1; no downstream agent should treat it as something to pull in.
- Category agents review only — none carry `Edit` on the target codebase. Findings here are for the compliance report, not live fixes.
