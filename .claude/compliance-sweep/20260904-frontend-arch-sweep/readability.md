# Readability & Structure Review — 20260904-frontend-arch-sweep

Scope: all 161 reviewable files across the iOS SwiftUI app (`FellowScript/FellowScript/`), the React/Vite SPA (`frontend/src/`), and the legacy static tree (`frontend/{account,reader,signin}.html`, `frontend/css/`, `frontend/js/`), per `file-inventory.json`. Reviewed via direct reads of every hook, the largest/flagged files named in `compliance-plan.md` (NetworkService.swift, AccountView.swift, NotesListView.swift, AppState.swift), the full legacy JS tree, both `config.js`/`utils.js` pairs, and codebase-wide greps for empty catch blocks, TODO/dead-code markers, and debug logging, cross-checked against codegraph's call-path data for `NetworkService`, `AppState`, `NotesListView`/`AccountView`, and the messaging/session/notes/chat hooks.

Findings are ordered by how much they obscure understanding or invite bugs, per the maintainability ranking in the preference profile (separation of responsibilities > extensibility > error handling > ...).

---

## Critical

### 1. Three incompatible error-handling conventions for the same operation class (fetch calls), most severely in `useSessions.js` and `useAgentChat.js`
**Where:** `frontend/src/hooks/useSessions.js` (13 bare `catch {}` sites, e.g. lines 62, 71, 91, 224, 255, 331, 344-345, 350, 358, 380, 420), `frontend/src/hooks/useAgentChat.js` (10 bare `catch {}` sites, e.g. lines 30, 45, 91, 114, 140, 178, 191, 203, 219, 232), `frontend/src/pages/Account.jsx` (9 sites, e.g. lines 253, 287, 295, 304, 336, 345, 356, 366, 451, 458, 560), plus `AuthContext.jsx:12`, `useBible.js:23`, `useHighlights.js` (4 sites), `useBookmarks.js` (3 sites), `SubscriptionCard.jsx` (2 sites), `SessionWidget.jsx:33`, `readerDockLayout.js:87`, `Reader.jsx` (3 sites).

**What's unclear/inconsistent:** Every network call in these files is wrapped in `try { ... } catch {}` — no `console.error`, no `message.error`, no rethrow, nothing. Compare this to `useMessaging.js` and `useNotes.js` (both in the same `hooks/` directory, solving the identical "fetch failed" problem) which consistently `console.error` the failure *and* surface a `message.error`/`message.warning` toast to the user. A third convention (`try? await ...` degrade-to-empty, explicitly commented) appears in `NetworkService.swift`'s older call sites before this task's own fixes. A reader moving between `useMessaging.js` and `useSessions.js` has to relearn, per file, whether a failed fetch is visible anywhere at all.

**Why it costs a reader/maintainer:** This directly violates the project's own stated preference (Implementation Q26-27: propagate errors upward, never silently substitute defaults; flag any bare `catch` that doesn't re-throw or surface the failure). In `useSessions.js` specifically, `joinSession`/`leaveSession`/`createSession`/`updateSession`/`deleteSession` — the entire video-call and devotion-session lifecycle — fail completely invisibly: a user who taps "Join" during a network blip sees nothing happen, and a future engineer debugging a "sessions sometimes don't create" report has zero log trail to start from. Because two sibling hooks in the same directory already show the "right" pattern, this isn't a case of the codebase lacking a convention — it's a case of the convention not being applied consistently, which is worse for a future reader than no convention at all (they can't safely assume either behavior).

**Suggested fix:** Adopt `useMessaging.js`/`useNotes.js`'s pattern (log via `console.error` + surface via antd `message.error`/`message.warning`) as the house style for every fetch-based hook, starting with `useSessions.js` and `useAgentChat.js`, which currently have zero user-facing or console signal on any failure path.

### 2. Legacy static tree repeats the same silent-swallow pattern with zero test backstop
**Where:** `frontend/js/notes.js` — `_saveNote()` (`catch { /* server error */ }`, ~line 533), `deleteNote()` (~line 544), `_loadDetailReplies`'s reply-submit handler (~line 605); `frontend/js/messaging.js` — `_submitAddFriend`, `_removeFriend`, `_submitGroup`, `_leaveGroup`, `connectWS`'s `onmessage` (all `catch { /* ... */ }` with only a comment, no logging, no user feedback).

**Why it costs a reader/maintainer:** Per `compliance-plan.md`'s own notes, this surface has *no automated test coverage* backstopping it and reaches nginx-served production directly — making this exact pattern (a failed note save or friend request that silently does nothing) the single riskiest spot in the codebase for a regression to go unnoticed. `_saveNote()` in particular: if the `fetch` throws (offline, timeout, CORS), the note form simply stays open with no error shown — indistinguishable, from the user's perspective, between "still saving" and "silently failed." The inline comments (`/* server error */`, `/* offline */`) show the author was aware these were failure paths, but stopped short of the one line (`alert(...)` or an on-page error banner, matching this file's own `_openFilterPanel`-adjacent UI conventions) that would make the failure visible.

**Suggested fix:** At minimum, `_saveNote` and `deleteNote` should show a lightweight inline error message on catch (there's already a `.note-empty` styling convention this tree uses elsewhere for empty/error states it could reuse).

---

## High

### 3. Verse-parsing business logic is copy-pasted between the legacy tree and the React app, not just markup
**Where:** `frontend/js/bible.js` lines 156-226 (`_extractVerseNums`, `_buildHTML`, `_versesToHTML`) vs. `frontend/src/utils.js` lines 49-105 (`extractVerseNums`, `buildChapterHTML`, `versesToHTML`).

**What's unclear:** These are near-verbatim duplicates of the same regex-based tokenizer that turns a raw `bible.json` chapter string into verse-span HTML (same lookaheads, same `[[V$1]]` placeholder scheme, same section-head splitting on `HEAD::`). `compliance-plan.md` already flags `frontend/js/reader.js` + `reader.css` vs. `Reader.jsx` as a parallel-implementation hotspot for markup/CSS — this shows the duplication goes one level deeper, into the actual parsing algorithm itself.

**Why it costs a reader:** A bug in verse-number extraction (e.g. an edge case in the "digit immediately followed by a letter" heuristic) must be found and fixed twice, in two files that don't reference each other, or the two readers will silently diverge on how they tokenize the exact same `bible.json` data. Nothing in either file cross-references the other, so a maintainer fixing one has no signal that a twin exists.

**Suggested fix:** No shared runtime module is possible today (no bundler on the legacy side), but a code comment in both files pointing at the other ("mirrors `frontend/src/utils.js`'s `buildChapterHTML` — keep in sync") would at least turn silent drift into a known, deliberate constraint, consistent with how `compliance-plan.md` already treats the reader.js/Reader.jsx pairing.

Related, smaller instance of the same pattern: `_normalizeNote` in `frontend/js/notes.js:44` is a line-for-line copy of `normalizeNote` in `frontend/src/hooks/useNotes.js:23`, and `_applyFiltersAndSort` (`notes.js`) / `applyFilter` (`useNotes.js`) reimplement the identical filter/sort request-shaping algorithm independently.

### 4. Two functions named `escHtml` exist with the same apparent contract but different actual behavior
**Where:** `frontend/js/utils.js:1` vs. `frontend/src/utils.js:1`.

**What's unclear:** Both are called `escHtml`, both take a string and return HTML-escaped output, and both are used to sanitize user content before `innerHTML` insertion — but the legacy version escapes only `&`, `<`, `>`, while the React version also escapes `"`. `compliance-plan.md` already warns that this project's naming collisions (`utils.js` at two paths) are a landmine for basename-only searches; this is a sharper version of that risk, because the two functions don't just share a name, they share an apparent purpose too.

**Why it costs a reader:** A maintainer who has verified `escHtml` is "safe" against one string in one surface (e.g. because it's used inside a `title="..."` or other attribute context) and then reasons by analogy about the other surface's identically-named function would be carrying an incorrect assumption about quote-escaping coverage across the boundary.

**Suggested fix:** Rename one (e.g. the legacy tree's to `escHtmlText` or similar) to make the behavioral difference visible at the call site, or bring the legacy version's escaping up to parity with the React version's.

### 5. `NetworkService.swift` (1453 loc) is a single monolithic type spanning ~10 unrelated domains
**Where:** `FellowScript/FellowScript/Services/NetworkService.swift`.

**What's unclear:** Auth, MFA, password reset, user profile, notes (read/write/search/replies), highlights, bookmarks, agents/heartbeats, contacts/friends, DM/group messaging fetch, and attachment upload/GIF search all live in one `final class NetworkService` with only `// ── Section ──` comment banners separating them — no per-domain extension files. The in-file documentation itself is genuinely good (thorough why-comments on nearly every non-trivial method, consistent with this project's Q13-15 preference), so this isn't a "badly written" file — it's a "too much in one place" file.

**Why it costs a reader:** Anyone touching one domain (say, bookmarks) has to load and scroll past the other nine to get there, and the file's size means Xcode's own symbol navigator becomes the primary way to find anything, rather than the file structure itself.

**Suggested fix:** Split into `NetworkService+Notes.swift`, `NetworkService+Agents.swift`, `NetworkService+Contacts.swift`, `NetworkService+Attachments.swift`, etc. — same type via `extension NetworkService`, same single conformance to `DataServiceProtocol`, just distributed across files by domain. This is "missing structure where it would clearly help," not new abstraction for its own sake — no interfaces or behavior change needed, only a file split, which also directly serves the maintainability ranking's #1 priority (separation of responsibilities).

---

## Medium

### 6. `AccountView.swift` (2174 loc) and `NotesListView.swift` (2024 loc) each combine a view model and many unrelated sub-sections in one file
**Where:** `FellowScript/FellowScript/Account/AccountView.swift`, `FellowScript/FellowScript/Notes/NotesListView.swift`.

**What's unclear:** `AccountView.swift` alone contains the profile section, subscription/StoreKit section, agents section, events/heartbeats section, and blocked-users entry point, each as private computed `some View` properties (`subscriptionSection`, `agentsSection`, `eventsSection`, `usageRow(...)`, etc.) on one giant `struct AccountView`. Comments are good throughout (e.g. the `agentEnabledBinding` dangling-index-crash note at line ~1573), which keeps any one section locally understandable — but the file as a whole has no navigable seams beyond in-body `// ──` banners.

**Why it costs a reader:** Per the maintainability ranking's #1 priority (clear separation of responsibilities), a change scoped to, say, only the subscription section still requires holding a 2000+ line file in an editor/mental model to be confident nothing else is affected.

**Suggested fix:** Split each major section into its own file as a `View` extension or a dedicated child view struct (`AccountView+Subscription.swift`, `AccountView+Agents.swift`, `AccountView+Events.swift`), mirroring the split already suggested for `NetworkService.swift`.

### 7. `NetworkService.swift` applies its own hardening convention (checked writes, tagged decode failures) inconsistently among structurally similar sibling calls
**Where:** `fetchBookmarks` (line 710) vs. `fetchNotesCount`/`fetchHighlights`/`fetchAgents`/`fetchHeartbeats` (lines 429, 683, 730, 754).

**What's unclear:** The file's own comments document a deliberate, recent effort (task-tagged: `20260903-account-stats-not-loading`, `20260903-account-events-not-loading`) to retrofit `decode(..., endpoint:)` tagging onto every read that previously degraded silently to an empty/zero default, specifically so a decode failure is distinguishable from "genuinely zero items." `fetchBookmarks` — sitting directly beside `fetchHighlights`, its closest sibling in both shape and the adjacent section header — was not included in that pass, and still uses the untagged `decode(...) ?? [:]` form.

**Why it costs a reader:** A maintainer who reads the surrounding comments and reasonably concludes "every read in this file now beacons its decode failures" would be wrong about this one call, and a future missing-bookmarks bug report would hit exactly the same invisible-failure gap the surrounding comments describe fixing everywhere else.

**Suggested fix:** Apply the same `endpoint:` tag to `fetchBookmarks`'s `decode(...)` call for symmetry with its neighbors.

### 8. `useSessions.js` manually mirrors nearly all of its own state into refs; sibling hooks solving the same stale-closure problem don't
**Where:** `frontend/src/hooks/useSessions.js` lines 37-40 (four separate `useEffect`s syncing `sessionsRef`, `activeIdRef`, `currentContactRef`, `videoEnabledRef` off their state counterparts).

**What's unclear:** This ref-mirroring exists to let long-lived WebSocket/Chime callbacks read current values without stale closures — a legitimate pattern — but `useMessaging.js` and `useNotes.js` solve the identical "read latest value from inside an async/WS callback" problem differently (fetching fresh data inline, or accepting slightly-stale reads where it's safe), without any comparable ref-shadowing setup.

**Why it costs a reader:** A newcomer has to discover and learn this ref-mirroring convention from scratch in `useSessions.js` specifically, rather than being able to assume a house style for "how this codebase keeps async callbacks fresh" from having read a sibling hook first.

**Suggested fix:** Not necessarily wrong to keep (Chime's observer-pattern callbacks arguably need it more than a plain `fetch` does), but a short top-of-file comment on `useSessions.js` explaining why this hook needs ref-mirroring where its siblings don't would close the gap for a future reader jumping between hooks.

---

## Low

### 9. Leftover debug-style `console.log` calls in shipped legacy code
**Where:** `frontend/js/notes.js` — roughly 8 call sites (`_applyFiltersAndSort` lines 152-203, `loadNotes` line 356, `_loadGroupNotes` line 371), several of which dump full data objects (e.g. `console.log('[notes] personal notes loaded:', ..., allNotes)`).

**Why it costs a reader:** These read as leftover instrumentation from debugging a specific issue (the filter/sort pipeline) rather than intentional, permanent logging — no other file in the legacy tree logs happy-path data this verbosely, and the React equivalent (`useNotes.js`) has no matching `console.log` trail at all. Not security-severity (notes text isn't a sensitive-tier field here per the plan's consequence-scoped validation stance), just console noise for anyone inspecting production.

**Suggested fix:** Remove, or gate behind an explicit debug flag if they're still useful for diagnosing the filter/sort feature.

### 10. `NotesPanel.jsx` (834 loc) bundles five distinct components with heavily duplicated inline hover-style handlers
**Where:** `frontend/src/components/panels/NotesPanel.jsx` — `FmtBtn`, `NoteEditor`, `NoteCard`, `NoteDetail` (plus the outer `NotesPanel`/`FilterPanel`, per codegraph's symbol map) all live in one file. The `onMouseEnter`/`onMouseLeave` gold-highlight hover treatment (e.g. lines 70-81, 328-329, 420-421, 483-484) is repeated near-verbatim across the formatting toolbar, the color swatches, and the verse-reference chips in both `NoteCard` and `NoteDetail`.

**Why it costs a reader:** This is markup-level, not logic-level, duplication, and the project's stated preference (UI/UX Q12) is fine with components emerging without up-front reuse mandates — so this is a minor note, not a violation. Still, a future visual tweak to the shared hover treatment (e.g. a new gold shade) means finding and editing the same handful of lines in 4+ places by hand rather than one shared helper.

**Suggested fix:** Optional — a small `useHoverStyle`-style helper or a shared inline-style constant would remove the duplication if this treatment needs to change again, but this is a "nice to have," not a maintenance risk on its own today.

---

## Not flagged (reviewed, found acceptable)

- `NetworkService.swift`'s per-call documentation (why, not just what) is consistently strong and exceeds the bar this project's own preference profile (Q13-15) asks for — the file's problem is size/organization, not documentation quality.
- No TODO/FIXME/HACK markers or large commented-out code blocks were found anywhere in `frontend/src`, `frontend/js`, or `FellowScript/FellowScript` via a full-tree grep.
- `frontend/src/config.js` (2 loc) and `frontend/js/config.js` (11 loc) both correctly limit themselves to deployment-value injection (API base URL / WS base derivation), per Configuration Q2 — no behavior-tunable config smuggled in here.
- Naming throughout both platforms is generally clear and contextually appropriate (per Implementation Q25's "clarity beats rigid convention" — not flagging minor scheme inconsistencies that don't obscure meaning).
