# Readability & Structure Review — FellowScript Full Sweep

Scope: 374-file inventory from Step 1 (`file-inventory.json`), read via `.claude/compliance-sweep/20260830-fellowscript-full-sweep/compliance-plan.md`. Codegraph (`.codegraph/`) was available and used for call-path/blast-radius checks; `git log`/`diff` on the actual repo (this is a git repo, contrary to the environment header) was used throughout to establish *when* a file was last touched, which is the load-bearing evidence for every dead/dormant-code claim below — findings are staleness-dated, not just "looks unreferenced."

This report carries a dedicated section (first, per the plan's explicit user-relayed instruction) for production-dormant dead code, then the general structure/readability findings, grouped Critical → Low.

---

## Part 1 — Dead / production-dormant code (user-relayed focus)

### Critical

**1. The "legacy" vanilla-JS frontend stack is confirmed dead in production, yet is still being actively, manually kept in sync with the React app — wasted duplicate-maintenance effort, not just unused code.**
- `deploy.sh` only ever ships `frontend/dist/assets/` and `frontend/dist/index.html` (built from `frontend/src/` via `vite build`) to the production host. It never touches `frontend/js/`, `frontend/css/`, `frontend/account.html`, `frontend/reader.html`, or `frontend/signin.html`. Nothing in `Dockerfile`, `docker-compose.yml`, or `.github/workflows/build-push.yml` references those files either — there is no path from them to a running server.
- Despite that, `git log` shows commit `845a7d37` (2026-08-25, 5 days before this sweep) fixed the exact same "fake Untitled rows" bug in **both** `frontend/js/notes.js` and `frontend/src/hooks/useNotes.js` in the same commit, and added parallel test coverage in both `frontend/js/notes.test.js` and `frontend/src/hooks/useNotes.test.js`. A day earlier, `cc75e963` added a *new* jsdom regression test for "the legacy vanilla-JS sidebar" specifically.
- Why this costs a reader time: this is not simple "recently stale, still mid-migration" — it's actively-maintained code that cannot reach a single production user, being fixed and tested in lockstep with the code that actually ships. A future contributor fixing a bug will reasonably assume both implementations matter and spend time keeping them in parity, when only one does anything.
- Suggested fix (flagging only — not applied): confirm with the team whether the legacy stack still needs to exist at all (e.g. for a non-Vite deployment target); if not, delete `frontend/js/`, `frontend/css/`, `frontend/account.html`, `frontend/reader.html`, `frontend/signin.html` rather than continuing to patch both.
- Correction to compliance-plan.md's framing: `frontend/index.html` (root) is **not** part of this legacy stack — it is the actual Vite entry point (`<script type="module" src="/src/main.jsx">`), confirmed byte-structurally identical to `frontend/dist/index.html`'s build output. Only `account.html`, `reader.html`, `signin.html`, `frontend/css/*.css`, and `frontend/js/*.js` are the genuinely separate legacy stack.

**2. Corrupted string literal sitting unnoticed in mock Bible content for ~8 weeks.**
`FellowScript/FellowScript/Bible/BibleReaderView.swift:968`:
```swift
(9,  "The true light, /Users/jaceysimpson/Vscode/FellowScript/frontend/node_modules/@aws-sdk/core/dist-types/ts3.4/submodules/protocols/query/QuerySerializerSettings.d.tswhich gives light to everyone, was coming into the world."),
```
`git log -L` on this line shows it was introduced by commit `2539fd74` ("notifications", 2026-07-05) — a local absolute file path (from an unrelated `node_modules` file on the original author's machine) was accidentally spliced into a Bible verse string, almost certainly by a bad find/replace or scripted edit. It has not been touched since. This is squarely the kind of "hasn't been exercised/reviewed in a long time" signal the plan asked for: `BibleData.johnChapterOne` is static mock content used as a fallback/preview data source, not exercised by any test, so nobody has looked at it closely enough to notice broken text sitting in committed source for two months. Also worth flagging to `logic-error-agent` if not already caught — it is a correctness bug, not just a style issue.

### High

**3. Root-level `messages.json` is a stray, diverged duplicate of `data/messages.json`, dead since initial launch.**
- `messages.json` (repo root, 112 lines) and `data/messages.json` (494 lines) both exist; diffing their heads shows they are **not** identical copies — they contain different message records entirely (different `from_user`, different timestamps, different `group_id` values). `git log` on the root copy shows exactly one commit, `0ef0b629` ("complete launch", 2026-05-14) — untouched for 3.5+ months, the oldest and most clearly abandoned artifact found in this sweep.
- No code reads `messages.json` from the repo root — `api/db.py load_messages()` and `api/backend/interactions/helpers.py` only ever resolve `data/messages.json`. This file has no reachable code path at all.
- Suggested fix (flagging only): delete, once confirmed it isn't a manual backup someone still wants — but note it's a genuinely different dataset than `data/messages.json`, so don't merge/assume it's redundant without a look.

**4. `ios/README_iOS.md` documents a project structure that no longer exists.**
- The doc's own "Project structure" tree describes `ios/FellowScript/FellowScriptApp.swift`, `ios/FellowScript/ContentView.swift`, etc., and instructs the reader to "Open `ios/FellowScript.xcodeproj` (create one via Xcode...)". None of that exists anymore — the real, current project lives at `FellowScript/FellowScript.xcodeproj` with source under `FellowScript/FellowScript/`, reorganized into many more feature folders (Account, Auth, Chat, Dashboard, Notes, Onboarding, Services, Theme, Utils) than the doc's single-tier layout shows.
- The doc also says "The app runs entirely on `MockDataService` by default — no backend needed... To connect to the live server, replace `MockDataService.shared` with `NetworkService.shared` in `AppState.init(service:)`." That manual-swap workflow is gone — `FellowScriptApp.swift` now switches automatically based on the `UI-TESTING` launch argument (see Part 1, item 6 below for confirmation that `MockDataService` itself is *not* dead, just no longer wired the way this doc describes).
- `git log` shows this file's last touch was `2f133f3c`/`2e665b23`/`2539fd74` around 2026-07-05 ("notifications" / "new ios plus agentic features") — roughly 8 weeks stale relative to the current, much-more-developed iOS project. It reads as a first-draft onboarding doc from before the Xcode project was actually created, never updated once the real structure diverged.
- Suggested fix (flagging only): either delete `ios/README_iOS.md` (superseded) or rewrite it to match `FellowScript/`'s current structure and move it there.

**5. `data/bible copy.json` is an untouched, unreferenced literal duplicate.**
- Byte-identical (at minimum, head-matching, same 1375-line count) to `data/bible.json`. `git log` shows exactly one commit, `5c7ae6d2` ("basic platform complete", 2026-05-22) — over 3 months stale, one commit older than `data/bible.json` itself (which was touched again later, `a3314858`, "lingering JSON -> Postgres migration", 2026-07-13).
- Confirmed via codegraph: nothing in the codebase opens `"data/bible copy.json"` — only `data/bible.json` is read, and only by `api/backend/bibleHandling/convertDict.py`'s `ConvertBibleToDict.__init__` default path (a one-off content-generation script, not the running API). This is a plain "someone made a backup copy while editing and forgot to remove it" artifact.

### Medium

**6. `MockDataService.swift` is *not* dead — confirmed live via codegraph, correcting the plan's flagged suspicion.**
`FellowScriptApp.swift` selects the data service at launch: `MockDataService.shared` when the `UI-TESTING` launch argument is present, `NetworkService.shared` otherwise. It's exercised by 6 XCTest files (`AccountViewModelTests`, `DashboardFriendActivityLoadTests`, `EmberGlassChatRegressionTests`, `EmberGlassFidelityPassRegressionTests`, etc.) and by every `FellowScriptUITests` screenshot/UI test, which launch with `UI-TESTING`. This is intentional, actively-used test infrastructure, not a superseded mock left behind after a real implementation shipped — no action needed, noted here only so it isn't chased as a false positive.

**7. `api/backend/bibleHandling/convertDict.ipynb` looks like an abandoned prototype superseded by `convertDict.py`.**
- Both files exist with heavily overlapping logic (PDF → Bible-dict conversion). `git log` shows the notebook's last (and only additional) touch was `5c7ae6d2` (2026-05-22); `convertDict.py` kept being edited through `a3314858` (2026-07-13, the Postgres migration commit) — the `.py` file is the one that kept evolving, the notebook did not. Reads as prototyping scratch work left in the tree after the "real" script was extracted.
- `convertDict.py` itself also hardcodes `main_path = "/Users/jaceysimpson/Vscode/FellowScript/"` (line 8) — a single developer's local machine path. Combined with its `print()`-based logging and the fact it's invoked only via its own `if __name__ == "__main__"` block (1 caller, itself), this is clearly a one-off local content-generation tool that happens to live inside `api/backend/` next to real production modules (`api/backend/auth/`, `api/backend/subscription/`, etc.) — worth relocating or documenting as scratch tooling so a reader browsing `api/backend/` doesn't mistake it for a served feature.

**8. `frontend/vitest.config.js` has no test scoping, so `npm test` silently runs both stacks' tests — and CI never runs it at all.**
- No `include`/`exclude` is set, so Vitest's default glob picks up `frontend/js/*.test.js` (legacy stack) alongside `frontend/src/**/*.test.js` (React stack) under one `npm test` invocation.
- `.github/workflows/build-push.yml` never invokes `npm test` — its only frontend job (`frontend-dist-freshness`) runs `npm run build` and diffs the committed `frontend/dist/` against a fresh build. So the legacy stack's tests (and the React stack's, for that matter) have zero CI enforcement; the only reason the Aug 25 commit above kept both in sync was a developer manually running the full suite. This structurally rewards exactly the wasted-effort pattern in Critical finding #1 — nothing catches it if the two stacks silently diverge instead.

### Low

**9. `FellowScript/File.txt` — a stray 1-line file with no apparent purpose.**
Content is just `jacey@sandbox.xom` (likely a typo of `.com`). Added in commit `eeee59f9` (2026-08-28, "Add font bundle, design assets, and desktop app scaffold...") — recent, not "long-dormant," but it's orphaned clutter sitting directly in the Xcode project tree with no clear reason to exist. Flagging as low-severity hygiene rather than a staleness finding, since the plan cares more about the latter.

**10. `api/schema_tree.md` risks drifting stale relative to the schema it documents.**
Last touched `d5846656` ("postgresql migration", 2026-06-29) — over 2 months before this sweep — while `api/schemas/`, `api/routes/`, and `api/db.py`'s table DDL have all continued to change since (e.g. `api/routes/subscription.py`, `api/schemas/subscription.py` show later activity). Not confirmed stale (didn't diff its content against current schema), but flagged as at-risk given the gap, since this is exactly the kind of standalone doc that's easy to forget after the migration it documents wrapped up.

---

## Part 2 — General structure & readability findings

### High

**11. `api/db.py` (975 lines) mixes three unrelated responsibilities with no internal separation.**
The file interleaves: (a) schema DDL / `create_tables()` (roughly the first ~625 lines), (b) a one-off JSON→Postgres migration script (`load_users`/`load_groups`/`load_notes`/`load_devotions`/`load_messages`, `insert_*`, `migrate_data`, `main`, `main_notes_only` — migration-only, invoked only via this file's own `__main__` block, confirmed via codegraph: `migrate_data` has exactly 1 caller, itself), and (c) the generic `DBManager` class (`insertion`/`lookup`/`update`/`delete`/`close`) that is the query interface used by virtually the entire backend — codegraph shows 183 callers across `api/backend/auth/`, `api/backend/backup/`, `api/backend/interactions/`, `api/backend/monitoring/`, `api/backend/subscription/`, etc.
Why this costs a reader time: anyone opening `db.py` to understand "how does the app talk to Postgres" has to scroll past ~350 lines of one-time migration logic they will never touch to reach the class that's actually load-bearing everywhere else. Suggested fix: split into `db.py` (DBManager + schema, the live surface) and a separate `scripts/migrate_json_to_postgres.py` (or similar) for the one-off migration functions.

**12. `api/main.py` breaks the codebase's own module-boundary convention: every other feature area got extracted into `api/routes/`, but auth/user endpoints didn't.**
`api/main.py` (877 lines) calls `app.include_router(...)` for notes, websockets, chime, groups, friends, filters, sorting, devotions, agent, notifications, subscriptions, donations, reports, blocks, and monitoring — every one of those lives in its own `api/routes/*.py` module. But `signup`, `login`, MFA verify/enable/confirm/disable, password-reset request/confirm, `logout`, `get_user`/`update_user`/`delete_user`, `accept_terms`, and both Google/Apple auth endpoints are all defined directly inline in `main.py`, alongside their own local helper functions (`load_users`, `save_users`, `find_by_email`, `find_by_apple_sub`, `find_by_google_sub`, `issue_session`, `find_by_username`, `persist_new_user`). This is the single largest, most security-sensitive endpoint surface in the app, and it's the one place that doesn't follow the pattern the rest of the codebase established. A reader looking for "where do auth routes live" has to know to check the app entrypoint instead of `api/routes/`, unlike every other feature.
Suggested fix: extract to `api/routes/auth.py` for consistency with the rest of the routing layer.

**13. Naming collision: two functions named `load_users()` with entirely different meanings, one of them dead.**
- `api/db.py:630` `load_users()` reads `data/users.json` from disk — the one-off migration path (dead in production; see Part 1).
- `api/main.py:136` `load_users()` calls Postgres via `backend/interactions/helpers.load_users_data()` — the live path.
Both are named identically, live in files that get opened side-by-side when investigating user-loading behavior, and do fundamentally different things (flat-file read vs. live DB query). Grepping for `load_users` without checking the import source will point a reader at the wrong implementation roughly half the time. Suggested fix: rename the migration-only one (e.g. `_load_users_json_fixture()`) to make its narrow, historical purpose obvious at the call site.

**14. `persist_new_user()`'s docstring describes behavior the code no longer has — a half-finished migration cleanup left stale documentation behind.**
`api/main.py:153-165`:
```python
def persist_new_user(user: User) -> None:
    """Create a new user in BOTH stores — the single account-creation pipeline.

    Every provider (password signup, Google, Apple) must go through here so that:
      • the JSON store gets a *complete* User record (friends, friend_requests,
        groups, highlights, bookmarks — via User.model_dump), and
      • the Postgres ``users`` table gets the row that all DBManager-based
        features (friends, groups, notes, messages) query.

    Without the Postgres insert, an account exists for auth but is invisible to
    every relational feature.
    """
    save_users_data({user.user_id: user.model_dump(exclude={"user_id"})})
```
The docstring's entire framing ("BOTH stores", "the JSON store gets...") describes a pre-migration dual-write that no longer happens — `save_users_data()` (from `backend/interactions/helpers.py`) only writes to Postgres now. This is exactly the "migration that was never fully finished" pattern the plan called out, just in comment form rather than code: a future reader trusting the docstring would believe user records still round-trip through a JSON file, and could go looking for a JSON-store bug that doesn't exist. Suggested fix: update the docstring to describe the current single-store (Postgres-only) behavior.

---

## Summary

10 dead/dormant-code findings (Part 1: 2 Critical, 3 High, 4 Medium, 1 Low — plus one explicit correction of a false positive in the plan's own steer, `MockDataService.swift`) and 4 general structure findings (Part 2: 2 High, 2 more folded into the High items above). Headline: the legacy vanilla-JS frontend isn't just unreferenced, it's actively and unnecessarily double-maintained in parallel with the React app that actually ships (Critical #1), compounded by zero CI coverage forcing the two to diverge unnoticed the moment nobody remembers to run `npm test` by hand (#8). Second-most notable: a corrupted absolute-path string has sat unreviewed in committed Bible mock content for ~8 weeks (Critical #2). `api/main.py` and `api/db.py` both show the same underlying pattern — a live, load-bearing surface (auth routes; `DBManager`) sharing a file with dead or one-off migration-era code, with no boundary between them.
