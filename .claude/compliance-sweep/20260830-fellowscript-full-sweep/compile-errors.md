# Compile-Time Error Handling Gaps — FellowScript Full Sweep

Task: `20260830-fellowscript-full-sweep` · Step 3 (`compile-error-agent`)

## Scope reviewed

Worked through `file-inventory.json`'s reviewable surface with a stack-adapted lens:

- **Swift (`FellowScript/`)** — the primary target for this category. Searched for `try!`, `try?`, `as!`, non-exhaustive `switch`/missing `@unknown default`, and Xcode build-setting warning suppression across all 43 app source files (`try!`: 0 hits; `as!`: 1, justified; `try?`: 216, triaged file-by-file below). `@unknown default` is used correctly where it appears (StoreKitManager.swift:121) — not a finding.
- **Python (`api/`)** — no `mypy`/`pyright` config anywhere in the repo and no type-checking step in CI, so reviewed for `# type: ignore`/`# noqa` as the closest analog to a suppressed compiler diagnostic.
- **Rust (`desktop/src-tauri/`)** — 3 source files, ~25 lines total; standard Tauri boilerplate, no `unsafe`, no `#[allow(...)]` lint suppressions, one `.expect()` at the top-level `run()` entry point (idiomatic — no sensible recovery exists at that point). No findings here.
- **JS/JSX (`frontend/`)** — no TypeScript anywhere in the repo (confirmed: no `.ts`/`.tsx` files, no `tsconfig.json`), so `any`/`@ts-ignore`/strict-flag findings don't apply. Checked the closest analog — ESLint's `react-hooks/exhaustive-deps` — since several `eslint-disable-line` comments target it.
- **Build configs** — `FellowScript.xcodeproj/project.pbxproj` build settings, `.github/workflows/build-push.yml`, `frontend/package.json`/`vite.config.js`.

A large majority of the 216 Swift `try?` sites are already well-handled: `Models.swift`'s `FSVerseComponent` discriminated-union decode (lines 258–260, ends in a real `throw`), `DiskCache.swift`'s entirely best-effort cache layer, `NetworkService.swift`'s `decode(endpoint:)`/`reportFetchFailure` wrapper (explicitly built to stop swallowing decode/fetch failures per in-repo incident write-ups), `StoreKitManager.swift`'s purchase/entitlement flow, and `StartupCoordinator.swift`'s per-screen readiness race are all deliberate, documented, and correctly scoped uses of `try?`. Those are not repeated as findings below. The findings below are the parts of that same pattern that were **not** brought up to the same standard.

---

## Critical

### 1. `AccountView.swift:592` — account deletion silently no-ops on failure, then signs the user out anyway

```swift
Button("Delete", role: .destructive) {
    let uid = appState.currentUser?.user_id ?? ""
    Task {
        try? await appState.service.deleteUser(userId: uid)
        await MainActor.run { appState.signOut() }
    }
}
```

`try?` discards whatever `deleteUser` throws (network failure, session expiry, server-side rejection), and `signOut()` runs unconditionally regardless of whether the delete actually happened. The confirmation dialog tells the user "This will permanently delete your account and all data. This cannot be undone" — if the request silently fails, the app still behaves as if it succeeded (the user is signed out and returns to the auth screen), so they walk away believing an irreversible, privacy-relevant deletion completed when the account and its data may still exist server-side. This is the single highest-consequence instance of the pattern described in finding 2 below, and directly contradicts Architecture Q27 (propagate errors upward rather than silently succeeding).

**Fix:** `do { try await appState.service.deleteUser(userId: uid) } catch { /* surface an alert, do NOT sign out */ ; return }`; only call `signOut()` on confirmed success.

---

## High

### 2. Systemic: optimistic UI mutation + bare `try?` with no revert and no resync, across trust/safety and social-graph actions

The same file that fixed this exact pattern for *create/update* flows (see the `agentMsg` comment block at `AccountView.swift:39-43`, and `ChatRootView.swift:437-442`'s "instead of the previous silent `try?` no-op") left it unfixed for the corresponding *delete/remove/leave/report/block* flows. In each case below, the local state is mutated immediately (removed from a list, etc.), the network call is fired via bare `try?`, and nothing reverts the local state or tells the user if that call fails — the UI and the server can now permanently disagree with no signal to the user that anything went wrong:

- `AccountView.swift:148-153` — `removeEvent`: event removed from `events` locally; `Task { try? await service.deleteHeartbeat(...) }`.
- `AccountView.swift:210-215` — `deleteAgent`: agent + its events removed locally; `Task { try? await service.deleteAgent(...) }`.
- `AccountView.swift:231-235` — `acceptRequest(username:)`: friend request removed from the list *before* the accept call; if `acceptFriendRequest` fails, the request vanishes from the UI but the friendship is never established server-side.
- `AccountView.swift:381-385` — `cancelMyRequest(_:)`: removed from `mySubRequests` locally; `try? await service.declineSubRequest(...)`; unlike the sibling methods below, this one never calls `loadSubscription()` afterward either, so there is no self-healing resync at all — a failed decline leaves the client permanently believing the request is gone.
- `ChatRootView.swift:493-496` / `498-501` — `removeFriend` / `leaveGroup`: same optimistic-remove-then-fire-and-forget shape.
- `ChatRootView.swift:280` — `reportUser`: the report sheet's completion handler fires `Task { try? await appState.service.reportUser(...) }` with no error path; a failed report gives the user no indication their abuse report never reached moderation.
- `ChatRootView.swift:294` — `blockUser`: the confirmation dialog tells the user "They won't be able to contact you... We'll be notified so we can review the situation" and removes the contact from `vm.friends` immediately, but the actual block call is `Task { try? await appState.service.blockUser(...) }` — a failure leaves the user believing they're protected from a contact who in fact isn't blocked.
- `NotesListView.swift:235-239` — `deleteNote`: the surrounding comment (`225-234`) documents a *different*, already-fixed bug (non-author delete no-ops via `isOwnNote`) but the actual network call one line later, `try? await service.deleteNote(...)`, still discards the result — contrast with `saveHighlight`/`clearHighlight` in the same class (`241-266`), which correctly `do/catch`, revert the optimistic mutation, and set `saveError` on failure.

**Fix:** apply the same `do { try await ... } catch { revert the local mutation; surface a user-facing message }` shape already used by `toggleAgent`, `renameAgent`, `createAgent`, `updateEvent` (`AccountView.swift`) and `createAgent` (`ChatRootView.swift`) to every method listed above.

### 3. Related, lesser subset: subscription actions resync via reload but surface no error in the interim

`AccountView.swift` — `cancelPlan` (334-339), `leavePlan` (353-358), `removeMember` (360-364), `declineRequest(_ fromUserId:)` (374-379) each use bare `try?` for the mutating call, but (unlike the group above) each does call `await loadSubscription(userId:)` immediately afterward, which re-fetches server truth and self-heals any client/server drift on the next render. The gap here is narrower — no revert bug, just a swallowed error with no `subMsg` shown — but it's directly inconsistent with the two methods right next to them in the same class, `updateSeats` (345-349) and `acceptRequest(_ fromUserId:)` (368-371), which both `do/catch` and set `subMsg` on failure. A user who taps "Cancel Plan" during a transient network blip sees nothing happen and no explanation, rather than a "Could not cancel" message.

---

## Medium

### 4. `Models.swift` — Codable inits blanket-swallow decode failures behind `try? … ?? default`, conflating "field absent" with "field malformed"

Every custom `init(from decoder:)` in this file follows the same shape (`FSUser` 38-51, `FSSubscription` 89-103, `FSNote` 236-249, `FSHeartbeat` 466-478, `FSAgent` 500-506) — e.g.:

```swift
plan_type    = (try? c.decode(String.self, forKey: .plan_type))   ?? "free"
status       = (try? c.decode(String.self, forKey: .status))      ?? "inactive"
```

The comment at line 63 states this is deliberate ("every field is defensive... so a partial server row still loads"), which is a reasonable design for a genuinely *absent* key. But `try?` here also catches `DecodingError.typeMismatch` — i.e., a field that's present but the wrong shape (an API contract change, a server bug, a bad migration) — and silently produces the same plausible-looking default rather than surfacing that something is actually broken. This directly conflicts with Architecture Q27 (propagate malformed-data errors upward rather than substituting a default), and it's riskiest on `FSSubscription`'s billing-relevant fields: if the server ever sent `status`/`plan_type`/`price_cents` in an unexpected shape, this code would silently render the user as `"inactive"`/`"free"`/`$0` with no error trail anywhere, rather than failing loudly on something that should never happen to begin with.

**Fix:** distinguish `.keyNotFound` (acceptable default) from other `DecodingError` cases (should rethrow or at minimum log/beacon, mirroring the pattern `NetworkService.decode(endpoint:)` already established for exactly this class of problem).

### 5. `api/backend/interactions/helpers.py:78` — `# type: ignore` suppresses a real, trivially-avoidable type-checker finding

```python
if isinstance(msg.get("from_user"), str):
    new_msg = Message(**msg)
    uid: str = msg.get("from_user")  # type: ignore
```

`dict.get()` returns `Optional[str]`; the `isinstance` check on the line above narrows the *result of that call*, not a bound variable, so a type checker can't connect the two separate `.get()` invocations and the annotation has to be force-suppressed. Runtime behavior is correct today only because both calls happen to agree — but that agreement isn't checked by anything. Binding the value once (`from_user = msg.get("from_user"); if isinstance(from_user, str): ... uid: str = from_user`) makes the narrowing checker-visible and removes the need for the suppression entirely. Low risk in isolation, but it's the one non-test `# type: ignore`/`# noqa` in the whole `api/` tree (all other `# noqa` hits are legitimate `_pathfix`-style import-order suppressions in test files) — worth fixing since the repo has no `mypy`/`pyright` config at all, so this suppression is currently the *only* place a type-checker's opinion is even recorded in-tree.

---

## Low

### 6. Xcode project never sets `SWIFT_TREAT_WARNINGS_AS_ERRORS`

`FellowScript.xcodeproj/project.pbxproj`'s Debug and Release configurations both enable a long, sensible list of `CLANG_WARN_*`/`GCC_WARN_*` diagnostics (lines 317-357, 380-414) but never set `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in either. Since no CI workflow builds the iOS target at all (`.github/workflows/build-push.yml` only covers the `api/` backend and a `frontend/dist` freshness check), Swift compiler warnings — unused variables, unreachable code, deprecated API use — have no gate anywhere that would ever turn them into a build failure, local or CI.

### 7. `frontend/` has `eslint-disable-line react-hooks/exhaustive-deps` comments with no ESLint installed or configured

15 instances across `frontend/src` (`SessionWidget.jsx:35`, `ContactsPanel.jsx:187`, `NotesSidebar.jsx:119`, `panels/NotesPanel.jsx:111`, `hooks/useParallaxBlobs.js:43`, `panels/BibleReaderPanel.jsx:72,81`, `hooks/useSessions.js:99,412`, `pages/Reader.jsx:160,165,182,190,204,215`) reference the `react-hooks/exhaustive-deps` rule. There is no `.eslintrc*`/`eslint.config.*` anywhere in the repo, and `frontend/package.json` has no `eslint` or `eslint-plugin-react-hooks` in `devDependencies` (confirmed: no `lint` script either). Since this is a plain JS/JSX codebase with no TypeScript, `exhaustive-deps` is the nearest thing to a compiler-enforced exhaustiveness check for stale-closure bugs in `useEffect`/`useCallback` — but the rule was never actually wired up, so these comments record a developer's manual reasoning about a dependency array being intentionally incomplete, not a verified property, and every *other* dependency array in the codebase (including ones without such a comment) has never been checked by anything either.

### 8. CI test loop's undetected-failure gap for two specific test files (already self-documented in-repo)

`.github/workflows/build-push.yml:145-154` explicitly documents that `tests/test_cancel_reflect.py` and `tests/test_expiry_reflect.py` print a pass/fail line but never call `sys.exit()`/raise on failure, so a broken assertion in either file currently can't flip the exit code of the loop that gates the whole `test` job (every other `tests/test_*.py` file does propagate correctly). Included here for completeness since it's a literal "a failure gets silently downgraded to non-blocking" instance in the build/test gate, but flagged at Low severity specifically because it's already transparently tracked in the workflow's own comments as a known, deliberately-scoped-out gap rather than a hidden one.

---

## Summary

Reviewed the full Swift app target (43 files, 216 `try?` / 0 `try!` / 1 justified `as!` sites triaged), the Rust desktop shell (trivial, clean), Python's `api/` tree for type-checker suppressions (no `mypy`/`pyright` config at all; one real `# type: ignore`), and the frontend's build/lint tooling gaps. The codebase shows clear evidence of a prior remediation pass that fixed silent-`try?`-swallowing on create/update/toggle flows (with in-repo comments citing specific incidents) — but that pass systematically missed the equivalent delete/remove/leave/block/report flows, including one Critical-severity instance on account deletion. 8 findings total: 1 Critical, 2 High, 2 Medium, 3 Low.
