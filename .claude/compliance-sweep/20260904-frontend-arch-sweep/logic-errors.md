# Logic Error Review — 20260904-frontend-arch-sweep

Scope reviewed: all 161 reviewable files listed in `file-inventory.json` — the iOS SwiftUI app
(`FellowScript/FellowScript/`), the React/Vite SPA (`frontend/src/`), and the legacy static
tree (`frontend/{account,reader,signin}.html`, `frontend/css/`, `frontend/js/`). Concurrency-
heavy areas called out by the compliance plan were traced explicitly: `NetworkService.swift`,
`ChimeCallView.swift`/`CallController`, and the `useMessaging`/`useAgentChat`/`useSessions`
hooks. Backend (`api/`) was read only where needed to confirm a client-side finding against
the actual wire contract (e.g. `GET /notes/{user_id}`'s SQL filter), never as an independent
review target.

Headline finding: a genuine, reproducible state-inconsistency bug in note deletion, present
**independently in both the React app and the legacy static tree** (two separate
implementations of the same flaw, not a shared-code issue) — deleting a note that belongs to
a group never refreshes the group's note list, so the deleted note visibly lingers in the UI.
The legacy implementation compounds this with a second, more serious bug: it doesn't check the
delete request's response status at all, so a *failed* delete (expired session, 403, 500) is
still treated as a successful local delete.

---

## Critical

None.

## High

### 1. Deleting a group note never refreshes the group's note list (stale UI state) — both React and legacy surfaces
- **Files:**
  - `frontend/src/hooks/useNotes.js:167-182` (`deleteNote`)
  - `frontend/js/notes.js:536-545` (`deleteNote`)
- **Confirmed root cause:** `GET /notes/{user_id}` (`api/routes/notes.py:344-388`) explicitly
  filters `WHERE n.user_id = %s AND n.is_reply = false AND n.group_id IS NULL` — i.e. the
  `allNotes`/`notesCache['']` state populated by `loadNotes()` **never contains a group note**,
  by server-side design. Group notes live only in the separate `groupNotes` state, populated by
  `loadGroupNotes(groupId)` / `_loadGroupNotes(groupId)` (`GET /groups/{user_id}/{groupId}/notes`).
- **Concrete failure scenario:** User A opens a study group's Notes tab (loads via
  `selectGroup`/`groupSel` change → `groupNotes` populated). They see one of their own group
  notes from a previous session and delete it. `deleteNote(id)` does:
  ```js
  const deletedGroupId = allNotes[id]?.group_id;   // undefined — this note was never in allNotes
  setAllNotes(prev => { const n = { ...prev }; delete n[id]; return n; });  // no-op, id wasn't there
  if (deletedGroupId) await loadGroupNotes(noteData.group_id);  // never runs
  ```
  The DELETE request to the server succeeds, but the client's `groupNotes` state (and
  `notesCache.current[groupId]`) is never reloaded, so the deleted note keeps rendering in the
  group's note list until the user switches groups (or reloads the page), which is the only
  thing that re-triggers `loadGroupNotes`.
- **Why it's wrong:** `deleteNote` only receives the note `id`, so its only way to know "was
  this a group note?" is `allNotes[id]?.group_id` — but `allNotes` is structurally guaranteed
  (by the backend's own `group_id IS NULL` filter) to never hold a note with a `group_id`. The
  check can never fire for the exact case it exists to handle. (`postReply` in the same file,
  by contrast, correctly uses the `currentGroupId` state variable instead of trying to look the
  group up from the note.)
  - In the legacy tree, this bug is *partially* masked: `_saveNote` (line 527) unconditionally
    writes every saved note — including group notes — into `allNotes`, so a note deleted in the
    *same browser session it was created/edited in* happens to have its `group_id` available.
    But any group note loaded via `_loadGroupNotes` alone (the common case — a pre-existing note
    from an earlier session, or another member's note) was never written into `allNotes`, so the
    same stale-list bug reproduces there too.
  - In the React version there is no such masking: `saveNote` (`useNotes.js:131-165`)
    explicitly *removes* the note from `allNotes` when `noteData.group_id` is set (`delete
    n[savedId]`), so `allNotes[id]` is deterministically always `undefined` for a group note,
    every time.
- **Suggested fix:** Have `deleteNote` accept (or look up via `getNoteRef`/a `groupNotes` scan)
  the note's actual `group_id` instead of trusting `allNotes[id]`, or simply reload
  `loadGroupNotes(currentGroupId)` whenever `currentGroupId` is set at call time (mirroring
  `postReply`'s existing pattern) rather than trying to infer group membership from a note
  object it may never have seen.

### 2. Legacy `deleteNote` never checks the delete request's response status
- **File:** `frontend/js/notes.js:536-545`
- **Concrete failure scenario:** Session expires mid-visit (or the server returns a 403/500 for
  any reason). User clicks delete on a note.
  ```js
  export async function deleteNote(id) {
    if (!user || !confirm('Delete this note?')) return;
    try {
      await fetch(`${API}/notes/${user.user_id}?note_id=${encodeURIComponent(id)}`, { method: 'DELETE' });
      const deletedGroupId = allNotes[id]?.group_id;
      delete allNotes[id];
      if (deletedGroupId) await _loadGroupNotes(deletedGroupId);
      renderAllLists();
    } catch { /* server error */ }
  }
  ```
  The `fetch(...)` result is discarded entirely — there's no `if (!res.ok)` branch at all. Any
  non-2xx response (401/403/404/500) is treated identically to success: the note vanishes from
  the local `allNotes` and the list re-renders as if the delete succeeded, even though the note
  still exists server-side. The note will silently reappear the next time `loadNotes()` runs (a
  fresh page load), which is confusing and, per the compliance plan's explicit Q26/27 preference
  ("propagate errors upward rather than silently substituting defaults... flag any swallowed
  exception... that doesn't surface the failure"), a direct violation.
  - Compare to the React equivalent (`useNotes.js:167-182`), which does check `if (!res.ok) {
    message.error(...); return; }` before mutating local state — the legacy tree is the
    outlier here, and per the compliance plan's explicit note this is the one surface with *no*
    automated test coverage backstopping it, so this deserves extra weight.
- **Suggested fix:** Check `res.ok` (or at minimum `res.status`) before mutating `allNotes` /
  calling `renderAllLists()`; surface a visible error (matching the pattern already used
  elsewhere in this same file, e.g. `_submitAddFriend`'s 404 handling) on failure instead of
  silently proceeding as if the delete succeeded.

## Medium

### 3. `useMessaging.js`'s WebSocket message handler performs a side effect (`setMessages`) from inside a `setCurrentContact` updater function
- **File:** `frontend/src/hooks/useMessaging.js:46-65`
- **Code:**
  ```js
  wsRef.current.onmessage = e => {
    ...
    setCurrentContact(cc => {
      if (cc && data.from_user !== user.user_id &&
          (data.group_id || '') === (cc.group_id || '')) {
        setMessages(prev => [...prev, { ... }]);   // side effect inside an updater fn
      }
      return cc;
    });
  ```
- **Why it's wrong:** React state updater functions passed to a setter (`setCurrentContact(cc
  => ...)`) are required to be pure — React is explicitly permitted to invoke them more than
  once for the same update (this is exactly what React 18 `StrictMode` does in development, to
  help surface impure updaters, and is also a precondition for future concurrent-mode
  re-rendering). Here the updater's only reason to exist is to read `cc` and, as a side effect,
  call `setMessages` — if React invokes this updater twice (which `StrictMode` does today, in
  dev), an incoming WebSocket message gets appended to `messages` twice, producing a visibly
  duplicated chat bubble for a single inbound frame. This is a live chat/messaging path
  explicitly called out in the compliance plan for concurrency scrutiny.
- **Suggested fix:** Read `currentContact` from a ref (the codebase already uses this exact
  pattern elsewhere, e.g. `useSessions.js`'s `currentContactRef`) instead of trying to read
  current state from inside another setter's updater, then call `setMessages` unconditionally
  outside of any updater function.

### 4. Heartbeat monitor requires an exact-minute match with no catch-up for a missed/delayed tick
- **File:** `frontend/src/hooks/useAgentChat.js:55-97`
- **Code:**
  ```js
  const timeMatch = scheduled.getHours() === curH && scheduled.getMinutes() === curM;
  if (!dayMatch || !timeMatch) continue;
  firedTodayRef.current.add(fireKey);
  ...
  const id = setInterval(checkHeartbeats, 60_000);
  ```
- **Concrete failure scenario:** A user has a heartbeat scheduled for 9:00 AM today. Browser
  tabs are commonly throttled by the browser when backgrounded (timers can be deferred well
  beyond their nominal interval, and `setInterval(..., 60_000)` provides no guarantee the
  callback fires exactly once per real-world minute, only that it won't fire *more* often than
  that). If `checkHeartbeats` happens to run at 8:59:58 and then not again until 9:01:04 (a
  perfectly ordinary drift/throttle outcome, not a contrived edge case), `curH`/`curM` never
  equals `9:00` on any invocation that day — `timeMatch` is false at both checks, `fireKey` is
  never added to `firedTodayRef`, and the heartbeat is silently skipped for the entire day with
  no visible error, no retry, and no log line distinguishing "skipped" from "not due yet."
- **Why it's wrong:** The compliance plan explicitly flags this file for concurrency/timing
  scrutiny given the chat/call-heavy, heartbeat-driven nature of the app, and the project's
  stated preference (Q26/27) is to surface failures rather than silently drop expected actions.
  A once-per-minute poll checking for an *exact* single-minute window is inherently fragile to
  any tick drift, and there is no fallback path (e.g. "has more than N minutes passed since the
  scheduled time and it hasn't fired yet today") to catch a missed window.
- **Suggested fix:** Widen the match to a tolerance window (e.g. "scheduled time has passed and
  is within the last 5 minutes, and hasn't fired today") rather than requiring exact
  hour/minute equality on a specific poll tick.

## Low

### 5. Non-transitive sort comparators (`a.timestamp > b.timestamp ? 1 : -1`) used for message ordering in several places
- **Files:**
  - `frontend/src/hooks/useMessaging.js:191` (`openChat`)
  - `frontend/src/hooks/useAgentChat.js:137` (`openAgentChat`)
  - `frontend/js/messaging.js:175, 204, 406` (`loadContactList` previews, `_openChat`)
- **Why it's wrong:** A valid `Array.prototype.sort` comparator must return `0` when two
  elements are equal; these comparators never do (`a > b ? 1 : -1` collapses the equal case
  into `-1`), which is technically undefined behavior per the comparator contract and can
  produce inconsistent ordering for two messages with identical timestamps (e.g. two messages
  sent in the same synchronous batch, or two backend-stamped rows created in the same
  microsecond) depending on engine/array-size-dependent sort algorithm internals. In practice
  this is unlikely to cause a *visible* misorder on small message lists, but it's a real,
  reproducible comparator-contract violation, not merely a style nit, since equal-timestamp
  inputs are a realistic occurrence in a chat feature (e.g. `sendMessage`'s optimistic echo and
  a near-simultaneous history reload).
- **Suggested fix:** Use a comparator that returns `0` for equal values, e.g.
  `(a, b) => (a.timestamp > b.timestamp ? 1 : a.timestamp < b.timestamp ? -1 : 0)`, or compare
  parsed `Date` numeric values via subtraction.

---

## Areas checked with no logic-error findings worth reporting

- **`ChatThreadViewModel` (iOS, `ChatThreadView.swift`)** — WebSocket reconnect/backoff logic,
  self-echo dedup guard, and app-lifecycle (`handleAppBackgrounded`/`handleAppForegrounded`)
  wiring were traced end-to-end; the `isDisconnecting` guard correctly distinguishes an
  intentional close from a real drop, and `reconnectAttempt` reset timing (only on a genuinely
  successful frame receipt, not on every `connectWebSocket` call) is correct and well-commented
  as an intentional non-obvious choice.
- **`CallController`/`ChimeCallManager` (iOS)** — `CallController.start()` correctly no-ops a
  double-join attempt for the same session (`self.session?.id == session.id`); `end()`/`leave()`
  correctly reset all `@Published` state.
- **`NetworkService.swift`** — the shared `get`/`request`/`checkedRequestRaw` helpers correctly
  validate HTTP status via `throwIfError` (per the file's own fidelity-pass comment fixing a
  prior silent-swallow bug in `get()`); no un-validated write path was found in the portions
  reviewed.
- **`useHostRect.js` / `useFocusTrap.js`** — rAF-loop lifecycle and focus-trap Tab-cycling logic
  are both correctly bounded and cleaned up.
- **`AdminGate.jsx` / `AdminDetectionDetail.jsx` / `AdminDetections.jsx`** — deny-by-default
  posture is correctly deferred to each route's own first authenticated fetch, matching the
  file's own documented rationale; 401/403/404 branches are each handled distinctly.
- **`DiskCache.swift` + `AppState.signOut()`** — cache keys are not namespaced by user id inside
  `DiskCache` itself, but `signOut()` calls `DiskCache.shared.clear()` unconditionally, so the
  cross-account staleness this might otherwise cause is mitigated in practice; not reported as a
  finding.
