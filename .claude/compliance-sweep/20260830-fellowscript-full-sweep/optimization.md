# Optimization Review — FellowScript Full Sweep

Scope reviewed per `compliance-plan.md` / `file-inventory.json`: `api/` backend (FastAPI, focused on `api/db.py`'s `DBManager` base, `api/backend/interactions/*` managers, `api/backend/monitoring/*`, `api/backend/filters/filter_notes.py`, `api/backend/moderation/content_filter.py`, `api/routes/*`), the iOS Swift app (`BibleReaderView.swift`, `NotesListView.swift`, `NetworkService.swift`, `DiskCache.swift`), and the two `frontend/` stacks (`frontend/js/bible.js`, React hooks). Traced hot call paths with `codegraph_explore` (blast-radius/caller counts below are from the index) rather than a keyword sweep, so N+1 patterns sharing the same generic `DBManager.lookup()` helper across multiple files were caught even though each individual call site looks innocuous in isolation.

Headline finding: the codebase is inconsistent on this axis. `FriendsManager.read_friend()` / `get_friend_activity()` (`api/backend/interactions/friends.py`) and `ActivityManager.users_with_tokens()` (`api/backend/interactions/activity.py`) do this correctly — single joined queries, no per-row round trips. `GroupsManager` (`api/backend/interactions/groups.py`) and `ConnectionManager.send_msg()` (`api/backend/interactions/websockets.py`) do not, despite sitting right next to the well-written examples in the same package. That makes this a genuinely fixable, scoped problem rather than a systemic rewrite.

## Critical

None. No finding here rises to correctness-affecting or availability-affecting territory — everything below is a latency/cost problem under load, not a crash or data-loss risk.

## High

### 1. `GroupsManager.fetch_group()` — N+1 queries per group open (`api/backend/interactions/groups.py:81-92`)
```python
for uid in member_ids:
    user = self.lookup("users", {"_id": uid})          # line 82 — one query per member
    ...
    msgs = self.lookup("messages", {"from_user": uid, "group_id": self.group_id})  # line 90 — one query per member
    other_msgs.update(msgs)
```
**Cost:** for a group with M members this issues 2M separate round trips to Postgres (plus the `format_messages` N+1 below, compounding it further) instead of 2 batched queries.
**Why it's hot:** `fetch_group` (via `GroupsManager`, 11 callers from `api/routes/notes.py` and `api/routes/community.py`) is the primary read path every time a user opens a group's chat/notes view — a normal, frequent, user-facing action, not an admin/cold path.
**Fix:** collect `member_ids` up front, do one `SELECT * FROM users WHERE _id = ANY(%s)` and one `SELECT * FROM messages WHERE from_user = ANY(%s) AND group_id = %s`, then build in-memory dicts keyed by id for O(1) lookups inside the loop — the same shape `FriendsManager`/`ActivityManager` already use elsewhere in this package.

### 2. `GroupsManager.format_messages()` — N+1 username resolution per message (`api/backend/interactions/groups.py:39-48`)
```python
for _, data in messages.items():
    from_uid = data.get("from_user", "")
    user_result = self.lookup("users", {"_id": from_uid})   # one query per message
```
**Cost:** O(number of messages) extra queries, executed for both `host_msgs` and `other_msgs` on every `fetch_group()` call — this is the same call path as Finding 1, so the two compound (a group with M members and N total messages costs roughly 2M + N queries where 3 would do).
**Why it's hot:** same call path as #1 — every group view load.
**Fix:** batch-resolve all distinct `from_user` ids referenced in `messages` with one `IN (...)`/`ANY(...)` query before the loop, then look usernames up from the resulting dict.

### 3. `GroupsManager.fetch_notes()` — N+1 username resolution per page (`api/backend/interactions/groups.py:154-166`)
```python
for row in rows:
    ...
    user = self.lookup("users", {"_id": uid})   # line 159 — one query per note row
```
**Cost:** up to `limit` (default 15) extra queries per page.
**Why it's hot:** this is the keyset-paginated notes endpoint used for infinite-scroll — called repeatedly as a user scrolls a group's notes feed, not a one-off. 15 extra round trips per scroll-page-load adds up quickly under real usage.
**Fix:** collect the distinct `uid`s from `rows` first, one batched `users` lookup, then assign usernames from the resulting map while building `group_notes`.

### 4. `GroupsManager.fetch_highlights()` — N+1 per group member (`api/backend/interactions/groups.py:200-202`)
```python
for uid in group_data.get("users", []):
    self.cur.execute("SELECT key, color FROM highlights WHERE user_id = %s", (uid,))
    result[uid] = {row[0]: row[1] for row in self.cur.fetchall()}
```
**Cost:** one query per group member instead of one query total.
**Why it's hot:** called whenever a group's shared highlights view loads — same frequency class as the Bible reader / group notes screens.
**Fix:** `SELECT user_id, key, color FROM highlights WHERE user_id = ANY(%s)`, then bucket the rows by `user_id` in Python.

### 5. `ConnectionManager.send_msg()` — N+1 device-token lookup for offline recipients (`api/backend/interactions/websockets.py:142-153`)
```python
for uid in to_users:
    ...
    if not ws and uid != from_user_id:
        self.cur.execute("SELECT token FROM device_tokens WHERE user_id = %s", (uid,))  # line 146
```
**Cost:** one query per offline recipient on every message send that has any offline recipient (typical for group chat — members aren't all online simultaneously).
**Why it's hot:** this runs on the live message-send path for every chat message, which is one of the highest-frequency actions in the app.
**Fix:** before the loop, batch-fetch `SELECT user_id, token FROM device_tokens WHERE user_id = ANY(%s)` for the full `to_users` set once, build a dict, and look tokens up from it inside the per-recipient loop (the delivery/eviction logic itself still needs to stay per-recipient — only the token fetch needs batching).

## Medium

### 6. Hand-rolled recursive quicksort instead of Python's built-in sort (`api/backend/filters/filter_notes.py:138-197`, `Sorting.quicksort`/`sort_date`)
`POST /sort/` (`api/routes/filtering.py:54`) calls `Sorting(req.notes).sort_date(...)`, which runs a custom recursive quicksort (`notes_arr[len(notes_arr)//2]` as pivot — not randomized or median-of-three) over the user's full note set on every request.
**Cost:** Python's built-in `sorted()`/`list.sort()` (Timsort, implemented in C) is both algorithmically safer (guaranteed O(n log n), stable) and constant-factor faster than a pure-Python recursive quicksort that allocates three new lists (`left`/`middle`/`right`) at every level of recursion. The middle-element pivot also degrades toward O(n²) on already-sorted or adversarial timestamp orderings, which is a plausible real input shape (notes are usually inserted in roughly chronological order).
**Why it's worth fixing:** this runs synchronously on the request path for every sort request, over the full note collection the client sent — not a background job.
**Fix:** replace `quicksort`/`sort_date` with `sorted(self.notes.items(), key=lambda kv: _parsed_ts(kv[1]), reverse=descending)`.

### 7. Per-note `logger.info` calls inside the filter hot loop (`api/backend/filters/filter_notes.py:41-58`, `Filters._collect`)
```python
for uid, nid, note, data in self.filter_note():
    logger.info("note title=%r user=%r verses=%s", note.title, note.user, note.verses)
    ...
```
**Cost:** two `logger.info` calls (one here, one for "matched"/"filtered out") per note, on every `POST /filter/` request, regardless of collection size. Each call does string formatting plus a logging-handler write; for a note collection of any real size this multiplies per-request work linearly with data that a single aggregate log line (already present at the end, line 59) would cover.
**Why it's worth fixing:** runs on the request path for every filter call, not just under a debug flag — this looks like debug instrumentation from an earlier hardening cycle (task naming elsewhere in the sweep suggests a lot of debugging cycles) that was never gated behind `DEBUG`/removed.
**Fix:** drop the per-item `logger.info` calls (or gate them behind `logger.isEnabledFor(logging.DEBUG)` / `logger.debug`), keep only the pre/post aggregate counts.

## Low

### 8. `BibleViewModel.parseVerses` recompiles regexes on every chapter change (`FellowScript/FellowScript/Bible/BibleReaderView.swift:226-262`)
```swift
if let rx = try? NSRegularExpression(pattern: #"^\s*\d+:(\d+)\s*"#), ... }
if let rx = try? NSRegularExpression(pattern: #"(?<!\d)(\d+)(?=[A-Za-z])"#) { ... }
```
Both `NSRegularExpression` instances (plus the two `replacingOccurrences(..., options: .regularExpression)` calls above them) are compiled fresh every call, but the patterns are compile-time constants.
**Cost:** regex compilation is meaningfully more expensive than matching for short strings like a single Bible chapter; this function runs on every `setChapter` (next/prev chapter, book switch, initial load) — a normal, frequent navigation action in the Bible reader, one of the app's primary screens.
**Why it's Low, not Medium:** chapter text is short (a few KB at most) and navigation isn't rapid-fire (human-paced taps), so the absolute cost per call is small — but it's a trivial, zero-risk fix.
**Fix:** hoist the two `NSRegularExpression` instances (and the two replacement patterns) to `static let` constants on `BibleViewModel` (or a private enum), compiled once.

### 9. `_friend_went_active_notify` — N+1 friend-token lookup per transitioning user (`api/backend/interactions/scheduler.py:184-192`, `ActivityManager.friend_device_tokens`)
```python
for user_id, username, became_active_at in am.pending_friend_notifications():
    for friend_id, token in am.friend_device_tokens(user_id):   # one query per pending user
```
**Cost:** one extra query per user who just transitioned inactive→active since the job's last 5-minute run.
**Why it's Low:** this is a background scheduled job (runs every 5 minutes, not on a request path), and `pending_friend_notifications()` is typically a small set (only users who just became active in the last window) — real cost is bounded and infrequent, unlike Findings 1-5 which sit on live user-facing request paths.
**Fix (optional, low priority):** if this job's `pending_friend_notifications()` set ever grows large, batch with one `friend_id ... WHERE uf.user_id = ANY(%s)` query keyed on all pending `user_id`s at once instead of per-user.

## Not flagged (reviewed, found acceptable)

- `api/backend/interactions/friends.py` (`FriendsManager.read_friend`, `get_friend_activity`) and `api/backend/interactions/activity.py` (`ActivityManager.users_with_tokens`, `pending_friend_notifications`) — these already use single joined/lateral queries instead of per-row lookups; cited above as the pattern the Medium/High findings should follow.
- `api/backend/moderation/content_filter.py` — `profanity.load_censor_words(...)` runs once at module import time, not per-request; no hot-path cost.
- `api/backend/monitoring/cloudwatch_mcp_client.py` / `watchdog.py` polling loop (`_QUERY_POLL_INTERVAL_SECONDS`/`_QUERY_POLL_MAX_ATTEMPTS`) — intentional bounded async polling for an inherently async external API, not a busy-wait or redundant-work pattern.
- `api/db.py`'s `DBManager.lookup()` itself pushes its `WHERE` clause down to SQL (not a client-side full-table-scan-then-filter) — the problem is exclusively call sites that invoke it once per loop iteration (Findings 1-5), not the helper's own implementation.

## Summary

9 findings: 5 High (all N+1 database query patterns sharing the same root cause — per-iteration calls to `DBManager.lookup()`/raw per-row `cur.execute()` instead of batching — across `GroupsManager` and `ConnectionManager.send_msg`, all on live user-facing request paths), 2 Medium (a hand-rolled quicksort that should be `sorted()`, and per-item debug-style logging left in a request-path hot loop), 2 Low (uncached regex compilation on a frequent-but-cheap navigation path in the iOS Bible reader, and a low-volume N+1 in a 5-minute background job). No critical/availability-risk findings. The fix shape for the five High findings is uniform and already modeled correctly elsewhere in the same package (`friends.py`, `activity.py`), so this is a scoped, low-risk cleanup rather than a redesign.
