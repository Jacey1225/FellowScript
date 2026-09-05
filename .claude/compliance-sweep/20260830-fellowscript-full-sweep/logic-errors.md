# Logic Error Review — FellowScript Full Sweep

Task: `20260830-fellowscript-full-sweep`, Step 5 (`logic-error-agent`).

## Scope reviewed

Worked systematically through `file-inventory.json`'s core business-logic surface rather than a keyword sweep: `api/db.py`'s `DBManager` base class and every manager built on it (`auth/sessions.py`, `auth/mfa.py`, `auth/password_reset.py`, `interactions/friends.py`, `interactions/groups.py`, `interactions/activity.py`, `interactions/websockets.py`, `interactions/scheduler.py`, `subscription/subscriptions.py`, `subscription/apple_service.py`, `backup/manager.py`, `moderation/content_filter.py`, `filters/filter_notes.py`), the full `api/routes/notes.py` route file (create/get/update/delete/reply, keyset pagination), `api/schemas/users.py` and `api/schemas/watchdog.py`, and `api/backend/monitoring/watchdog.py`/`routes/monitoring.py`'s cursor/circuit-breaker logic. On the iOS side: `BibleReaderView.swift`'s `BibleViewModel` (chapter/book navigation, verse parsing) and `BibleNavDropdown`, `NotesListView.swift`'s `NotesViewModel` (keyset pagination state machine, optimistic highlight/bookmark writes), `HeartbeatScheduler.swift`, `StoreKitManager.swift`'s purchase/restore/entitlement-sync flow, and `GoogleAuthSession.swift`. On the frontend: the two parallel notes implementations, `frontend/js/notes.js` (legacy vanilla-JS) vs `frontend/src/hooks/useNotes.js` (React), byte-for-byte diffed for copy-paste divergence per the compliance plan's explicit callout, plus `NotesPanel.jsx`.

Used `codegraph_explore` throughout to pull verbatim call-path source and blast-radius data rather than re-discovering call graphs via grep, and traced every finding below to a concrete triggering scenario before including it.

The `api/` backend is unusually well-hardened already (extensive in-repo documentation citing specific prior incidents, a 46-file regression/hardening test suite, and evidence of multiple completed remediation passes) — most candidate issues surveyed here turned out to already be correctly handled (e.g. `SessionManager.resolve`/`MFAManager.verify`'s expiry checks, `GroupsManager`/`FriendsManager`'s block-enforcement, `ConnectionManager.send_msg`'s stale-socket eviction, `SubscriptionsManager`'s Apple-transaction double-claim guard, `HeartbeatScheduler`'s per-event persist-after-each-fire design). The one finding below is the significant exception: a systemic issue in the shared low-level DB write path that the rest of the backend is built on top of.

---

## Critical

### 1. `api/db.py:910-964` (`DBManager.insertion` / `.update` / `.delete`) — every write silently no-ops on a SQL error, and ~30+ call sites across the codebase treat that as success

**The bug:** `insertion()`, `update()`, and `delete()` each wrap their `cur.execute()` in `try/except sql.Error`, log the error, `rollback()`, and **return `None`** — the exact same return value as on success (none of the three ever returns anything meaningful on the happy path either, so a caller has no way to distinguish "wrote 1 row" from "wrote 0 rows because the write failed"). This is the base write path for essentially every manager class in `api/backend/` (`SessionManager`, `FriendsManager`, `GroupsManager`, `SubscriptionsManager`, `MFAManager`, `ConnectionManager`, `BackupManager`, `ActivityManager`, etc.) — 30+ call sites call `self.insertion(...)` and none of them check a return value, because there is nothing useful to check.

This directly contradicts the user's established preference recorded in this task's `compliance-plan.md` (Architecture Q27): "on missing or malformed data, propagate the error upward rather than silently substituting a default" — here the DB layer doesn't even substitute a default, it just pretends the write happened.

**Concrete triggering scenario #1 — a login that "succeeds" but leaves the user permanently logged out:**
`api/backend/auth/sessions.py:21-30` (`SessionManager.create_session`):
```python
def create_session(self, user_id: str) -> str:
    token = secrets.token_urlsafe(32)
    expires_at = datetime.now(timezone.utc) + timedelta(days=SESSION_TTL_DAYS)
    self.insertion("sessions", {"token_hash": _hash_token(token), "user_id": user_id, "expires_at": expires_at})
    return token
```
`token` is generated and returned **unconditionally**, whether or not the `INSERT INTO sessions` actually committed. `api/main.py:200-214` (`issue_session`, called from every login/signup/OAuth path) takes that token and unconditionally does `response.set_cookie(key=SESSION_COOKIE, value=token, ...)`. If the INSERT fails for any reason a Postgres write can fail transiently (connection blip, pool exhaustion, a deadlock retry, a constraint violation from a concurrent duplicate) — which is exactly the class of failure `except sql.Error` is written to catch — the client receives a `200`, a valid-looking session cookie, and every UI affordance of a successful login, but `SessionManager.resolve(token)` (`sessions.py:32-47`) will return `None` for that token on the very next request because the row was never written, silently 401ing a user who believes they just logged in successfully.

**Concrete triggering scenario #2 — a note create/edit/delete that reports success with no row ever written:**
`api/routes/notes.py:191-249` (`create_note`) calls `db.insertion("notes", {...})`, then several more `db.insertion("note_verses", ...)` calls in a loop, then unconditionally returns `{"id": note_id}` (`201 Created`). If the notes insert fails, the client is told the note was created and gets back an id that resolves to nothing — a subsequent `GET`/edit/delete against that id 404s ("Note not found"), which is the exact confusing failure mode the in-repo comment at `notes.py:225-245` was written to describe for a *different*, already-fixed bug (a decode mismatch), except this path reintroduces the same user-visible symptom from the server side. `update_note` (`notes.py:357-395`) and `delete_note` (`notes.py:398-411`) have the identical shape: the `db.update(...)` / `db.delete(...)` call's outcome is never checked before the handler returns success.

**Concrete triggering scenario #3 — multi-statement "transactions" that aren't atomic, compounding the swallow:**
Because each of `insertion`/`update`/`delete` calls `self.conn.commit()` **individually** rather than the caller wrapping a multi-step operation in one transaction, a logical operation made of several DB calls has no atomicity *and* no failure signal if a later step fails:
- `FriendsManager.add_friend` (`friends.py:48-71`) does two `insertion()` calls (`user_friends` both directions) then a `delete()` (clearing the pending request). If the second `insertion` fails, the friendship is one-directional (A has B as a friend, B does not have A) — silently, since the method still returns `None` (success) — and the request row is deleted regardless, so there's no way to retry or detect the mismatch.
- `SubscriptionsManager.accept_request` (`subscriptions.py:529-556`) does `self.update("users", {"subscription_id": subscription_id}, ...)` then `self.delete("subscription_request", {...})`. If the `update` silently fails, the request is deleted anyway and the method returns `None` — the requester's join request vanishes with no membership ever granted, and no error surfaced to the host who "accepted" it.

**Why this is inconsistent, not just missing:** `SubscriptionsManager.remove_member` (`subscriptions.py:443-462`) and a few other spots bypass the wrapper and issue `self.cur.execute(...)` / `self.conn.commit()` directly with no `try/except` at all — meaning a SQL error there *does* propagate as an unhandled exception (surfacing as a 500, which is at least honest about failure, if not gracefully handled). The presence of both patterns side by side confirms the swallow-on-write behavior is an artifact of the shared helper, not a deliberate "we've decided fire-and-forget is fine here" design choice repeated intentionally.

**Fix:** Have `insertion`/`update`/`delete` return a success/failure signal (e.g. `bool`, or re-raise after logging+rollback so callers can `try/except` per the codebase's own stated preference for explicit error propagation) and update call sites that currently assume success — at minimum the auth (`create_session`, `create_code`, `create_reset_token`) and note-CRUD paths, which are the two highest-consequence categories (auth state and user-authored content silently failing to persist).

---

## Low

### 2. `frontend/src/hooks/useNotes.js:23-35` vs `frontend/js/notes.js:44-56` — copy-paste divergence in the two frontends' note-normalization defaults

Both files implement the identical `normalizeNote`/`_normalizeNote` helper (used to build the payload sent to `POST /filter/` and `POST /sort/`), and every field default matches between the two **except** `verses`:
- React (`useNotes.js:30`): `verses: n.verses ?? []`
- Legacy (`notes.js:51`): `verses: n.verses ?? [[], []]`

Traced through to `Filters.filter_book`'s predicate (`api/backend/filters/filter_notes.py:105-109`, `any(v and book.lower() in str(v[0]).lower() for v in (note.verses or []))`), both an empty list and `[[], []]` currently produce the same (no-match) result for the book filter, since `[]` is falsy in the `v and ...` short-circuit — so this specific divergence is not currently observable as a behavioral difference. It's flagged as a real copy-paste risk rather than a live bug: the two implementations were clearly derived from one another (identical comments, identical variable names, identical surrounding structure), and the next person to touch verse-shape logic in either file has no signal that the other file's default silently disagrees, until a future change (e.g. a `note.verses[0]` access added to either normalizer) turns this into a live crash/wrong-filter bug in only one of the two stacks.

**Fix:** Pick one default (`[[], []]`, matching the `Note` schema's documented "list of [book, chapter, verse] references" pair-of-ranges shape used elsewhere in both files, e.g. `notes.js:477` destructures `note.verses` as `[s, e]`) and use it in both normalizers, or better, extract the shared normalization logic into one place `useNotes.js` and `notes.js` both import from, since `frontend/js/utils.js`/`frontend/src/utils.js` already play that role for `verseRefLabel`/`unwrapNotesEnvelope`.

---

## Summary

Reviewed the backend's core DB/manager layer, the notes CRUD + pagination route, the auth/session/MFA managers, the subscription and Apple/Stripe billing state machines, the watchdog/monitoring cursor logic, the activity-tracking notification state machine, and the iOS Bible-navigation, notes-pagination, and heartbeat-scheduling view models, plus a targeted diff of the two parallel (legacy vanilla-JS vs React) frontend note implementations. 2 findings: **1 Critical** — `DBManager.insertion`/`.update`/`.delete` (`api/db.py`) swallow every SQL error and return the same value as success, so ~30+ call sites across session creation, note CRUD, friend/subscription multi-step operations, etc. report success to callers (and ultimately to end users) even when the underlying write never happened, with concrete traced scenarios for login-that-doesn't-persist and note-create-that-doesn't-persist — and **1 Low** — a copy-paste divergence in the two frontends' note-normalization default for `verses` that is currently behaviorally inert but a latent risk. The rest of the reviewed surface (which is extensive, well-documented, and backed by a heavy regression-test suite) held up well against off-by-one, inverted-conditional, unhandled-edge-case, and partial-failure-state-machine scrutiny.
