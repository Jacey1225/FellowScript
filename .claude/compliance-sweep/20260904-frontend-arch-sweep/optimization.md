# Optimization Review — 20260904-frontend-arch-sweep

Scope reviewed: the three in-scope surfaces per `compliance-plan.md` / `file-inventory.json` (iOS SwiftUI app, React/Vite SPA, legacy static tree), traced via `codegraph_explore` through the hot paths the plan calls out — `NetworkService.swift`, `BibleReaderView.swift`/`bible.json`, `NotesListView.swift`, `ChatThreadView.swift`/`MessageGroupRow.swift`, `DiskCache.swift`, and the React `useMessaging`/`useNotes`/`useSessions`/`useAgentChat` hooks — plus the parallel legacy-tree implementations (`frontend/js/notes.js`, `frontend/js/bible.js`) called out as a maintenance hotspot. Findings below are scoped to concrete, currently-real costs on paths that are actually exercised in a loop, on every render, or on every network round-trip — not speculative micro-optimizations.

## Critical

### 1. Full 4.2MB `bible.json` decoded synchronously on the main actor
**File:** `FellowScript/FellowScript/Bible/BibleReaderView.swift:56-77` (`BibleViewModel.load`)

`BibleViewModel` is `@MainActor`, and `load(service:userId:)` does `Data(contentsOf: url)` + `JSONDecoder().decode([String: [String]].self, from: data)` directly in that MainActor-isolated `async` function — there's no `Task.detached`/background-queue hop around the read+decode. This method is called both by `StartupCoordinator` (gating the app's own loading screen) and by `BibleReaderView`'s `.task` the first time the Bible tab is opened. Decoding a 4.2MB JSON blob (the full translation text, per `compliance-plan.md`'s note on `bible.json`) synchronously on the main actor blocks UI updates for however long that decode takes — directly on the app's cold-start critical path and again on first Bible-tab open.

**Why it's hot:** this runs unconditionally on every app launch (`StartupCoordinator`) and is on the direct path to the app's own loading screen resolving — not a rare/cold code path.

**Suggested fix:** move the `Data(contentsOf:)` + `JSONDecoder().decode` off the main actor (e.g. a `nonisolated` helper run via `Task.detached(priority: .userInitiated)`, or decode on a background executor and hop back to `@MainActor` only to assign `bibleData`/`books`). `hasLoadedOnce` already guards against duplicate work, so this only needs the actual I/O+decode relocated, not a logic change.

## High

### 2. Chat message grouping recomputed, unmemoized, on every SwiftUI render
**File:** `FellowScript/FellowScript/Chat/ChatThreadView.swift:354-363` (`messageGroups` / `threadRows`), algorithm in `FellowScript/FellowScript/Chat/MessageGroupRow.swift:46-75` (`MessageDisplayGroup.grouped`)

```swift
private var messageGroups: [MessageDisplayGroup] {
    MessageDisplayGroup.grouped(from: vm.messages, me: user)
}
private var threadRows: [ChatThreadRow] {
    messageGroups.withDayDividers()
}
```

Both are plain computed `var`s, so SwiftUI re-evaluates the full grouping pass **and** the full day-divider pass from scratch every time `ChatThreadView.body` runs — which happens on every `@Published`/`@State` change in the view: every incoming WS frame appended to `vm.messages`, every character typed into the composer (`text` is `@State`), and every unrelated UI toggle (`showMembers`, attachment sheets, etc.). `grouped(from:me:)` is itself worse than linear in the realistic case: appending a message to an existing sender-streak does `groups[lastIndex].messages + [message]` (`MessageGroupRow.swift:59`), which copies the whole accumulated streak array on every append, making a long same-sender run of length k cost O(k²) — and this whole thing reruns per keystroke on top of that.

**Why it's hot:** this is the busiest interactive screen in the app (live chat + calls), and the recompute is keyed to `text` state churn (every keystroke), not just to actual message-list changes.

**Suggested fix:** cache `messageGroups`/`threadRows` in `@State`/`@Published` on the view model, recomputed only when `vm.messages` actually changes (e.g. in `didSet` on `messages`, or incrementally — appending one message only needs to extend/replace the last group, not re-run the whole pass). At minimum, hoist the two computed properties so a keystroke in the composer doesn't retrigger them.

### 3. N+1 fetch pattern for friends/groups, duplicated across three surfaces
**Files:**
- `frontend/src/hooks/useMessaging.js:105-171` (`loadContacts`)
- `frontend/src/hooks/useNotes.js:91-113` (`loadGroups`)
- `frontend/js/notes.js:318-337` (`populateGroupSelector`), `:376-392` (`_loadGroupHighlights`)

`loadContacts` issues one `GET /user/{fid}` **and** one `GET /message/messages/{user}/?guest_user={fid}` per friend, plus one `GET /groups/{user}/{gid}` per group — all via `Promise.all`, so latency is bounded by the slowest single call, but request *count* still scales linearly with friend/group count on every panel load (and again after every add-friend/remove-friend/create-group/update-group/leave-group action, since each of those calls `onLoadContacts()` again). `useNotes.js`'s `loadGroups` and the legacy tree's `populateGroupSelector`/`_loadGroupHighlights` repeat the identical one-request-per-group (and, for highlights, one-request-per-unique-highlighter) shape independently.

**Why it's hot:** this fires on every Messaging-panel and Notes-panel mount/reload, not just once per session — a user with a modest number of friends/groups multiplies out to a real, visible burst of requests each time.

**Suggested fix:** add a batched backend endpoint (e.g. `GET /users/batch?ids=...` and a groups-with-preview endpoint) so contact/group list population is O(1) requests instead of O(n). Short of a backend change, at minimum share one cache across the three independent per-surface implementations isn't possible (no shared client code per the plan's scope notes), but each surface could still collapse its own per-item fetches into a single batched call to the same backend once one exists.

## Medium

### 4. Filter/sort of already-in-memory data round-tripped through the backend
**Files:** `frontend/src/hooks/useNotes.js:222-306` (`applyFilter`), `frontend/js/notes.js:98-220` (`_applyFiltersAndSort`)

Both implementations build a normalized copy of notes that are already fully loaded client-side (`allNotes`/`groupNotes`, or the legacy tree's module-level equivalents), then `POST` that same data to `/filter/` and — separately — `/sort/` purely to filter/sort it, awaiting each round-trip in sequence before rendering. This is two full request/response cycles (with full JSON serialization of the note set both ways) for a pure computation over data the client already holds in memory, on every filter/sort interaction (which, per the UI, is user-interactive — every panel open/keystroke-adjacent filter change re-triggers this).

**Why it's hot:** triggered directly by user interaction with the filter panel, and doubles as both the React and legacy implementations independently pay this cost.

**Suggested fix:** perform the filter (simple field-match) and sort (single comparator, already used identically for the unfiltered path in both `NotesViewModel.filteredNotes`/`useNotes`'s own unfiltered rendering) locally in JS against the already-loaded `allNotes`/`groupNotes`, and drop the `/filter/`/`/sort/` network calls entirely for this path.

### 5. Notes list filter+sort recomputed on every render instead of cached
**File:** `FellowScript/FellowScript/Notes/NotesListView.swift:80-93` (`NotesViewModel.filteredNotes`)

```swift
var filteredNotes: [(String, FSNote)] {
    let result = notes.filter { ... }
    return result.sorted { ... }
}
```

This is a plain computed property, re-run (full `.filter` + `.sorted` over the entire `notes` dictionary) every time it's accessed from `NotesListView`'s body — which SwiftUI does on every re-render of the list, not just when `notes`/`sortOrder`/`currentGroupId` actually change. `notes` only grows over a session (`loadMoreIfNeeded` keeps appending additional 15-item pages across Personal + every group), so this cost grows with session length even though each individual page is small.

**Why it's hot:** it backs the `ForEach` driving the primary Notes screen's visible list, so it runs on every scroll-triggered re-render, not just on data changes.

**Suggested fix:** cache the filtered/sorted result in a `@Published` property, recomputed only in response to actual changes to `notes`, `sortOrder`, or `currentGroupId` (e.g. via `didSet` on those, mirroring the pattern already used for `scheduleSearch()` on `searchText`/`currentGroupId`).

## Low

### 6. Fresh `JSONEncoder`/`JSONDecoder` allocated per call in the app's single busiest service
**File:** `FellowScript/FellowScript/Services/NetworkService.swift:51, 117, 1347`

`request(_:method:body:)` (line 51) and the shared write path at line 1347 each call `JSONEncoder().encode(...)`, and the shared `decode<T>` helper (line 115-117) calls `JSONDecoder().decode(...)` — a fresh encoder/decoder instance on every single invocation, rather than a shared instance. `NetworkService` has 75 callers across the app (every feature's read/write path), so this repeats avoidable setup cost on every network call. Contrast with this same codebase's `DiskCache.swift:22-23`, which correctly hoists a single `encoder`/`decoder` to actor-level `let` properties reused across all calls — the fix pattern already exists in-repo.

**Why it's worth fixing (Low, not higher):** the per-call cost of instantiating `JSONEncoder`/`JSONDecoder` is small, so this is a minor, not major, allocation overhead — but it's trivial to fix given the precedent already in `DiskCache.swift`, and it's on literally every network call in the app.

**Suggested fix:** hoist a single `private static let encoder = JSONEncoder()` / `private static let decoder = JSONDecoder()` (or instance `let`s) on `NetworkService` and reuse them in `request`, `decode`, and the line-1347 write path.

## Notes on what was checked and not flagged

- `BibleViewModel.parseVerses`'s two regexes are already hoisted to `static let` with an explicit comment noting this was a prior optimization (compile-time-constant patterns, not recompiled per chapter navigation) — correctly not a finding.
- `DiskCache.swift` itself is well-optimized: single shared encoder/decoder, actor-isolated so file I/O never blocks the main thread, deterministic filesystem-safe key derivation. No findings there.
- `useMessaging.js`'s WebSocket reconnect backoff (3s→30s, capped) and `NotesViewModel`'s search debounce (300ms) are both reasonable, already-present mitigations against request storms — not flagged.
- `frontend/css/reader.css` (2,283 lines) and `frontend/src/styles/global.css`/`reader-dock.css` are large but CSS parse/selector cost at these sizes is not a real, measurable runtime cost for this app's page-load profile — this is a readability/maintainability concern (already called out to the readability agent per the plan), not an optimization finding.
