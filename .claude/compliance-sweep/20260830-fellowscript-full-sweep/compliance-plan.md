# Compliance Plan -- FellowScript Full Sweep

- **Task ID:** 20260830-fellowscript-full-sweep
- **Prior step:** `file-tree.md` / `file-inventory.json` (374 reviewable files, `result: pass`). Inventory is complete and well-formed -- no bounce needed.

## Scope

**Root:** `/Users/jaceysimpson/Vscode/FellowScript` (single git monorepo).

Authoritative file list: `.claude/compliance-sweep/20260830-fellowscript-full-sweep/file-tree.md` (374 reviewable files) and its companion `file-inventory.json`. Downstream category agents work through that list rather than re-discovering scope.

**In scope, all four project areas:**
- `api/` -- FastAPI/Python backend (103 reviewable files)
- `FellowScript/` -- iOS Swift/SwiftUI app + test targets (103 reviewable files)
- `frontend/` -- web frontend, dual-stack (117 reviewable files)
- `desktop/` -- Tauri/Rust desktop packaging app (11 reviewable files)
- `docs/`, `data/`, `data_changes/`, and root-level misc (Dockerfile, docker-compose.yml, CI workflow, deploy script, requirements.txt) -- included as supporting surface

**Explicit call on `desktop/`: IN SCOPE.** The original request named three review surfaces explicitly (`api/`, `FellowScript/`, `frontend/`); Step 1 flagged `desktop/` as a fourth, unnamed project area and left the in/out call to this step. Reasoning for including it:
- This is a whole-codebase compliance sweep, not a scoped diff review -- the pipeline's purpose is breadth across everything in the repo, and the three named surfaces read as the user's headline concerns rather than an exclusive allowlist.
- `desktop/`'s reviewable footprint is small (11 files: 3 Rust source files, Tauri config, capabilities manifest, package manifests, a progress doc) -- low marginal cost to include.
- Per prior session notes, `desktop/` is an actively-developed project (Tauri wrapper around the reader page), currently blocked on notarization -- live, not abandoned, code that the user would plausibly want covered by a compliance pass.

If this call is wrong, it's cheap to course-correct later: `optimization-review-agent` and `readability-agent` etc. can simply skip `desktop/`'s findings in the final report if the user says it was out of scope.

**Excluded** (per Step 1's inventory, not re-litigated here): vendored dependencies (`frontend/node_modules/`, `desktop/node_modules/`), build outputs (`frontend/dist/`, `desktop/dist/`, `desktop/src-tauri/target/`, `desktop/src-tauri/gen/`, `site/`), generated caches (`__pycache__/`, `.pytest_cache/`), `.claude/` tooling artifacts, `.codegraph/`, binary assets, IDE-local state, stray `.bak` files, `.venv/`, `.git/`, and three gitignored secret files at the repo root (`.env`, `AuthKey_22G3F2KMHS.p8`, `fellowscript-ec2-key.pem` -- contents not read, presence only).

## Stack

- **Backend (`api/`):** Python / FastAPI. `api/main.py` + `api/db.py` as entrypoint/DB layer; `api/routes/` (HTTP handlers), `api/schemas/` (Pydantic models), `api/backend/` (domain-grouped business logic: auth, subscription, interactions, moderation, monitoring, email, backup, filters, bibleHandling), `api/tests/` (46 pytest files, heavy regression/hardening naming -- SSRF, IDOR, spoofing, watchdog, webhook-failure). Dependency manifest: `requirements.txt` (root).
- **iOS (`FellowScript/`):** Swift / SwiftUI, Xcode project (`FellowScript.xcodeproj`), SwiftPM (`Package.resolved`). Three targets: app (43 source files, feature-organized: Account, Auth, Bible, Chat, Dashboard, LoadingScreen, Models, Notes, Onboarding, Services, Theme, Utils), `FellowScriptTests` (37 unit tests), `FellowScriptUITests` (9 UI/screenshot tests).
- **Web frontend (`frontend/`):** Two coexisting stacks (see Notes below) -- legacy vanilla JS/CSS/HTML (`frontend/js/`, `frontend/css/`, root `.html` pages) and a React/Vite app (`frontend/src/`, `vite.config.js`, `vitest.config.js`). Package manifest: `frontend/package.json`.
- **Desktop (`desktop/`):** Tauri (Rust backend + web frontend shell) wrapping the reader page. `desktop/src-tauri/` (Cargo.toml/Cargo.lock, `src/lib.rs`, `src/main.rs`, `build.rs`, `tauri.conf.json`, capabilities manifest). `desktop/package.json` for the Tauri CLI/JS tooling side.
- **Data/docs:** JSON/CSV data fixtures (`data/`), standalone Python migration scripts (`data_changes/`), markdown architecture/design docs (`docs/`), mkdocs config (`mkdocs.yml`).
- **Infra/CI:** `Dockerfile`, `docker-compose.yml`, `.github/workflows/build-push.yml`, `deploy.sh`, `.dockerignore`.

## iOS target

**Present.** `FellowScript/FellowScript.xcodeproj/project.pbxproj` (Xcode project, largely machine-managed) with `Info.plist` at `FellowScript/FellowScript/Info.plist`. App target source lives under `FellowScript/FellowScript/`; test targets under `FellowScript/FellowScriptTests/` and `FellowScript/FellowScriptUITests/`. `scope.json` sets `has_ios: true` -- Step 7 (`ios-guidelines-agent`) runs.

## Review categories

Fixed list this pipeline always runs:

1. Compile-time error handling
2. Dependency error handling
3. Logic errors
4. OWASP compliance
5. iOS guidelines compliance (applicable -- see above)
6. Optimization
7. Code structure & readability

## Preference profile

Established answers from `~/Downloads/ai_preference_survey_tracker.md` (Proposed Architecture / Implementation Philosophy, Security Posture, and Configuration Philosophy modules -- all three **Complete**) that bear on this sweep. Cited by module/question so category agents inherit them without re-reading the tracker.

**Error handling / logic errors (compile-error-agent, dependency-error-agent, logic-error-agent):**
- Architecture Q26: explicit checks and clear error returns are the preferred style -- flag implicit/silent control-flow patterns as a readability/logic finding, not just a stylistic nit.
- Architecture Q27: on missing or malformed data, the established preference is to propagate the error upward rather than silently substituting a default -- flag any place that swallows an error and invents a fallback value instead of surfacing it.
- Architecture Q17 (maintainability ranking): "good error handling" ranks just below separation-of-responsibilities and ease-of-extension in what makes code maintainable -- weight error-handling gaps accordingly in severity.
- Architecture Q1 (what makes code "good," ranked): Architecture > Performance > Security > Readability > Maintainability > Testability > Extensibility > Simplicity > Modularity > Naming > Minimal dependencies > Explicitness > Type safety -- useful as a tie-breaker when multiple findings compete for attention in the same file.

**OWASP compliance (owasp-compliance-agent):**
- Security Posture Q2: deny-by-default -- new resources/endpoints should start at the most locked-down configuration (private/authenticated-only, minimal permissions); flag any endpoint that appears to start from a permissive/conventional-framework default and get tightened only reactively.
- Security Posture Q14: fail closed by default, everywhere -- flag any ambiguous-failure security check (auth lookup timeout, signature verification edge case, etc.) that doesn't deny/block on doubt.
- Security Posture Q7: input validation is consequence-dependent -- defense-in-depth (validate at every layer) expected for sensitive/high-stakes data paths (auth, payments, PII); boundary-only validation is acceptable elsewhere. Don't flag boundary-only validation as a finding unless the data path is sensitive.
- Security Posture Q8: dependency vulnerabilities are severity-triaged -- critical/high findings should be treated as real, actionable findings; low/medium findings are legitimately deferrable and shouldn't be over-weighted.
- Security Posture Q9: supply-chain trust should be vetted as a matter of course for every dependency, not just obscure/sensitive ones -- relevant context if any newly-added or unusual dependency turns up.
- Security Posture Q13: sensitive information in logs should be proactively scrubbed/redacted by default in every environment, not just pre-production or a fixed known-fields list -- flag any log statement that could leak tokens/PII/request bodies even if it's not in an obviously "sensitive" module.
- Security Posture Q16 (supersedes Architecture Q10): SQL injection, XSS, known-vulnerable dependencies, and sensitive-info-in-logs are the user's own hard-stop-for-approval items when *the AI is making changes* -- but for a review/audit context, all four should still be reported as findings, just understood as things the user has backstopped with strong defaults elsewhere (validation, dependency triage, redaction) rather than items requiring separate escalation language. Authorization/permission-model issues, network/firewall exposure, and anything touching the security boundary are the items that remain genuinely hard-stop -- flag these with the highest severity.
- Data fixtures worth explicit attention per Step 1's inventory: `data/users.json`, `data/notes.json`, `data/messages.json`, `data/groups.json`, `data/devotions.json` -- assess whether they contain real vs. synthetic user data (Security Posture Q12: the user's data-privacy default is "collect what's reasonably useful now," not strict minimization, but that doesn't extend to committing real user PII to a git-tracked fixture file).
- Secrets sitting in the working tree root (`.env`, `AuthKey_22G3F2KMHS.p8`, `fellowscript-ec2-key.pem`) are correctly gitignored -- assess handling/rotation practices only, not contents (contents were not read at Step 1 and should not be read here either).

**Configuration / secrets handling (feeds dependency-error-agent and owasp-compliance-agent):**
- Configuration Philosophy Q9: secrets must go through a **completely separate mechanism** from ordinary configuration -- different loading path, excluded from any example/config file entirely, never appearing in a dump or log. This is stronger than mere redaction. If `api/`'s config loading treats secrets and ordinary tunables the same way (same env-var namespace, same example file, same dump path), that's a finding against the user's established standard, not just a generic best practice nit.
- Configuration Philosophy Q2: environment variables are reserved strictly for deployment-specific values; application-behavior tunables belong in a structured config file, not scattered env vars or in-code constants.
- Configuration Philosophy Q4 & Q6: fail-fast, no implicit defaults anywhere, with full eager validation at startup (type/range/required checks, specific errors). Flag any configuration value that silently falls back to a built-in default when unset, rather than refusing to start.
- Configuration Philosophy module summary: the config surface itself should be actively minimized (unused/rarely-exercised knobs are a legitimate finding, not just unused code) -- relevant to `readability-agent`'s dead-code emphasis below as well.

**Readability / dead-code emphasis (readability-agent, Step 9) -- see explicit callout below.**

## Dead/unused code emphasis for readability-agent (Step 9)

**User-relayed mid-sweep instruction, beyond the standard dead-code check:** the user specifically wants dead/unused code paths highlighted -- particularly code that has not been active in production for a long time, not just generically unreferenced code. `readability-agent` should treat this as its own explicit sub-focus, distinct from ordinary "this function is never called" observations:

- Prioritize evidence of *staleness*, not just non-reference: look for feature flags/branches that appear permanently on or off, commented-out blocks, functions/components superseded by a newer implementation still sitting alongside it (e.g. the two near-duplicate frontends noted below, or `data/bible.json` vs. `data/bible copy.json` vs. the iOS-bundled `FellowScript/FellowScript/Bible/bible.json` plus its stray `.bak` copy), mock/legacy services left in place after a real implementation exists (e.g. check whether `FellowScript/FellowScript/Services/MockDataService.swift` is still wired into any live path), and modules whose naming/comments suggest a migration or deprecation that was never finished.
- Where a file or function looks unreferenced, say explicitly whether it looks *recently* stale (plausibly still mid-migration) versus *long-dormant* (naming, comments, or surrounding context suggesting it hasn't been touched or exercised in a long time) -- the user cares more about the latter.
- This is a review category, not a fix -- flag candidates with the reasoning for why they look production-dormant, don't delete or edit anything.

## Notes

- **`frontend/` is two stacks, not one.** `frontend/js/*.js` + `frontend/css/*.css` + the four root HTML pages (`index.html`, `account.html`, `reader.html`, `signin.html`) are a legacy vanilla-JS static site; `frontend/src/` (components/pages/hooks, `App.jsx`, `main.jsx`, Vite config) is a separate, newer React app. Every downstream reviewer touching `frontend/` should treat these as two distinct code paths with potentially duplicated logic (e.g. `frontend/js/notes.js` vs. `frontend/src/hooks/useNotes.js`) rather than assuming one framework throughout -- and the dead-code emphasis above should specifically consider whether the legacy stack is still live in production or has been fully superseded by the React app.
- **`frontend/node_modules/` is accidentally committed to git** -- 28,969 files, no `frontend/.gitignore` exists and the root `.gitignore` has no `node_modules` entry (`desktop/node_modules/`, 17 files, has the same gap). This is a repo-hygiene/dependency-management issue independent of any single file's code quality; flagging forward explicitly for `dependency-error-agent` (Step 4) to record as a finding, and for `compliance-report-agent` to surface prominently -- it's the kind of issue that's easy to miss when working file-by-file through the inventory since the files themselves are excluded from the reviewable set.
- `api/__pycache__/` (59 files across 13 subdirectories) is also committed to git -- same root-cause category (missing/incomplete `.gitignore` coverage), also for `dependency-error-agent`.
- `site/` (63 files) is a fully generated mkdocs build of `docs/`, also committed -- treat `docs/` as the source of truth; `site/` being stale/out of sync with `docs/` would itself be a kind of "dead" derived content worth a passing mention, not a primary focus.
- Two stray timestamped `.bak` files exist alongside real files (`FellowScript/FellowScript/Bible/bible.json.bak-20260712-232858`, `FellowScript/FellowScript.xcodeproj/project.pbxproj.bak-20260713-123004`) -- hygiene cruft, already excluded from the reviewable set by Step 1, mentioned here only so reviewers aren't surprised if they notice the pattern.
- `api/tests/` naming leans heavily toward regression/hardening tests (SSRF, IDOR, spoofing, watchdog cascade, webhook-failure) -- useful signal for `owasp-compliance-agent` that some of these attack surfaces have already had dedicated attention; findings should note whether an issue is already covered by an existing test versus genuinely unaddressed.
- `FellowScript.xcodeproj/project.pbxproj` (661 lines) is Xcode-managed/machine-generated, not hand-authored -- `ios-guidelines-agent` and `readability-agent` should not flag its internal structure as a readability issue.
