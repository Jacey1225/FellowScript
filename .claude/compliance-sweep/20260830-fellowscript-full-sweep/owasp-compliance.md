# OWASP Compliance Review — FellowScript Full Sweep

Task: `20260830-fellowscript-full-sweep` · Step 6 (OWASP Top 10:2025 / ASVS 5.0 / LLM Top 10 / Agentic AI Security)

## Scope reviewed

Systematically walked the file-inventory's reviewable surface with a security lens, concentrating on every trust boundary: `api/backend/auth/*` (session/MFA/password-reset), `api/main.py` (signup/login/OAuth/session issuance), `api/db.py` (the shared query layer every route uses), `api/routes/*` (all 13 routers) and their backing `api/backend/interactions/*` / `api/backend/subscription/*` / `api/backend/moderation/*` / `api/backend/monitoring/*` managers, the Stripe/Apple payment webhooks, the OpenRouter-backed agentic chat/heartbeat system and its system prompt, the CloudWatch-MCP agentic tool client, the frontend's HTML sanitizer and API/session config (both the legacy vanilla-JS stack and the React app), the desktop Tauri shell's config/capabilities, and the `data/` fixture files flagged by Step 2's plan. Confirmed every finding below against the actual code path (call sites, contrasting routes, and — where present — existing tests), not just a keyword match; `.codegraph/` was available but the fastest path for this file set was direct reads through the layered call chains (route → manager → `DBManager`), so codegraph was used opportunistically for cross-file symbol lookups rather than as the primary tool.

The backend's fundamentals are unusually strong for an app this size: session tokens and MFA/reset codes are opaque, CSPRNG-generated, and stored only as SHA-256 hashes (never replayable from a DB leak); Apple/Stripe webhooks are properly signature-verified (Apple via a hand-rolled, correctly-implemented x5c chain pinned to Apple's real Root CA, not a `if True` stub); the CloudWatch debugging agent has real prompt-injection defenses (explicit "untrusted data, never instructions" framing, delimiter-injection neutralization, secret-shaped redaction before any log content reaches the LLM); and several security-conscious fixes are already landed and covered by dedicated regression tests (`test_websocket_from_user_spoofing.py`, `test_idor_agent_notification_devotion.py`, `test_apple_jws_verification.py`, `test_security_hardening.py`). The findings below are what stood out against that baseline, not evidence of a generally weak codebase.

---

## Critical

### C1. Real user PII and password hashes committed to git (`data/users.json`)
**File:** `data/users.json` (tracked in git — confirmed via `git ls-files`, last touched in commit `d5846656`)
**Category:** OWASP A02 Security Misconfiguration / cryptographic-adjacent exposure (bcrypt hashes at rest in an unintended store); also a hard-stop per the project's own Security Posture Q12 note ("collect what's reasonably useful now" does not extend to committing real PII to a git-tracked fixture).

This file is described everywhere else in the codebase as a legacy migration seed (`db.py::migrate_data`, `insert_users`), but it currently contains **real production data**, not synthetic fixtures: 8 real user records with real email addresses (including the project owner's own `jaceysimps@gmail.com`) and real bcrypt password hashes (`$2b$12$...`), e.g.:

```
60aa9553-...  jaceysimpson       jaceysimps@gmail.com     $2b$12$M0bJPwSeP0o2kH/j0AL/5eLx...
3abbfaad-...  timjkim            timjkim210@gmail.com     $2b$12$ienJfAFn9nOeEwo3dlMBOO...
```

`data/messages.json` (50 entries) and `data/notes.json` (34 entries) reference the same real user UUIDs and almost certainly carry the same real people's private message/note content.

**Exploit scenario:** Anyone with read access to the repository (any collaborator, CI runner, or a future public/leaked clone) can read every listed user's real email address outright, and can run an offline bcrypt-cracking attempt against the hashes — bcrypt is slow but not infeasible against a weak/reused password, and a hit yields a working login for the live app (same DB, same credentials, since this looks like the actual production seed rather than a synthetic one). This is independent of any application-level vulnerability; it bypasses every control above.

**Fix:** Remove `data/users.json`/`data/messages.json`/`data/notes.json` from the working tree and replace with synthetic fixtures (or drop the migration path entirely if it's no longer used — `db.py`'s own inventory notes suggest it may be dead code). Because these are already committed, force the affected users to rotate their passwords (or invalidate the current hashes) and purge the blobs from git history (`git filter-repo`/BFG), not just delete-and-recommit — otherwise the hashes remain trivially recoverable from history exactly like the finding in C2 below.

### C2. SSH private key committed to git history, never purged (`fellowscript-ec2-key.pem`)
**File:** repo root, added in commit `0ef0b629` ("complete launch"), removed from tracking in commit `10b4d466` ("Remove EC2 key from tracking") — but never removed from history.
**Category:** OWASP A02 Security Misconfiguration / secrets-in-source-control.

`git log --all --diff-filter=A -- fellowscript-ec2-key.pem` shows the key was committed; `git ls-files` confirms it is no longer in the current tree, and `.gitignore`'s own comment corroborates the pattern ("*.pem ... these should never be newly added to git" — added defensively *after* the fact). Removing a file from tracking does not remove it from history: `git show 0ef0b629:fellowscript-ec2-key.pem` (or a full clone/`git log -p`) still recovers the raw private key today, for anyone with read access to the repository or any of its remotes/branches (`remotes/origin/main`, etc.).

**Exploit scenario:** Any party with clone/fetch access to the repo (a contractor, a leaked clone, a compromised CI cache, a public fork if this is ever open-sourced) can extract the key from history and use it to SSH into whatever EC2 instance it authorizes, independent of whether the key still "looks" removed from `HEAD`.

**Fix:** Treat the key as already compromised — rotate/replace it on the EC2 side and revoke the old public key from `authorized_keys` regardless of whether history is rewritten. Then purge it from git history (`git filter-repo --path fellowscript-ec2-key.pem --invert-paths`, or BFG), force-push, and have every clone re-fetch. The `.gitignore` comment for `AuthKey_4SRZ3YTAAN.p8` documents this exact class of prior incident already having happened once (a `.p8` Apple key), suggesting this is a recurring process gap worth a pre-commit secret scanner rather than relying on `.gitignore` after the fact.

---

## High

### H1. Broken access control: notes can be posted into any group without membership (`api/routes/notes.py`)
**File:** `api/routes/notes.py:191-249` (`create_note`) and `:357-395` (`update_note`)
**Category:** OWASP A01 Broken Access Control (IDOR). This is one of the plan's designated hard-stop categories (authorization/permission-model issues).

`POST /notes/{user_id}` and `PUT /notes/{user_id}` both accept a raw `note_dict: dict` from the client and write whatever `group_id` it contains straight into the `notes` table (`note.group_id or None`), gated only by `require_match("user_id")` — i.e. the caller must *be* `user_id`, but nothing checks that `user_id` is actually a member of the target `group_id`. Contrast this with the properly-guarded read path one file over: `api/routes/community.py::fetch_group_notes` calls `GroupsManager(user_id, group_id).is_member()` and 403s non-members before returning a group's notes — the same check simply doesn't exist on the write path.

**Exploit scenario:** Any authenticated user can `POST /notes/{their-own-id}` with `{"group_id": "<any other group's UUID>", "public": true, "title": ..., "text": ...}` and have that note appear in a Bible-study group they were never invited to and have no membership row for — spam, harassment, or moderation-filter-bypass content injected into a group's shared feed the poster can't otherwise see or post to legitimately. `update_note` has the identical gap for re-targeting an existing owned note at an arbitrary group.

**Fix:** Before inserting/updating a note with a non-empty `group_id`, verify `GroupsManager(user_id, group_id).is_member()` (mirroring `fetch_group_notes`) and 403 otherwise.

### H2. Broken access control: joining a private video call without membership (`api/routes/messaging.py`)
**File:** `api/routes/messaging.py:28-59` (`_get_or_create_meeting` / `POST /chime/{session_id}`) and `:62-68`/`:111-124` (`_create_attendee` / `POST /chime/{session_id}/{user_id}/attend`)
**Category:** OWASP A01 Broken Access Control (IDOR) — also a hard-stop category per the plan.

Both endpoints operate on an arbitrary `session_id` (a devotion/study-session UUID) with only `get_current_user`/`require_match("user_id")` — i.e., "is the caller logged in as themselves" — and never call `DevotionManager.is_authorized(session, user_id)`. Compare this to the parallel, correctly-guarded endpoint that exists in a *different* router for the same underlying feature: `api/routes/devotion.py::join_call` (`POST /devotions/join-call`) fetches the session and explicitly checks `db.is_authorized(session, user_id)` — creator, existing participant, or same group/DM — before creating a Chime meeting or attendee. `messaging.py`'s `chime_router` endpoints appear to be an older/parallel implementation of the same feature that never received that fix, and both routers are registered in `main.py` (`app.include_router(chime_router)` alongside `devo_router`), so both are live.

`api/tests/test_chime_error_handling.py` confirms these endpoints are exercised and expected to work (`test_messaging_start_meeting_happy_path`, `test_messaging_join_meeting_create_attendee_error`) but only asserts on Chime-API-failure/happy-path status codes — no test asserts that a non-participant is rejected, unlike the `is_authorized`-covered `/devotions/join-call` tests in the same file.

**Exploit scenario:** Any authenticated user who learns or guesses a devotion session's UUID (shared in a chat link, visible in a URL, or brute-forced since these are otherwise-unauthenticated-lookup-shaped calls) can call `POST /chime/{session_id}` then `POST /chime/{session_id}/{their_own_id}/attend` to obtain a valid Chime attendee token and join a private Bible-study group's live video call they were never invited to.

**Fix:** Add the same `DevotionManager.is_authorized(session, user_id)` check `devotion.py::join_call` already uses to both `messaging.py` endpoints, or — better — delete the duplicate `chime_router` implementation entirely and have callers use the already-hardened `/devotions/join-call` (this also resolves the dead-code duplication readability flagged this pass separately).

### H3. Excessive data exposure: any authenticated user can read any other user's email and account metadata (`api/main.py`)
**File:** `api/main.py:531-551` (`GET /user/{user_id}`)
**Category:** OWASP A01 Broken Access Control / excessive data exposure. Docstring explicitly documents this as intentional ("only login is required, not ownership"), but the response shape goes well beyond what that stated purpose (looking up a friend's/group member's *username*) needs.

`load_users_data()` (`api/backend/interactions/helpers.py:92-153`) reconstructs each user record with `username, email, apple_sub, google_sub, timezone, mfa_enabled, terms_accepted_at, terms_version, suspended_at, needs_profile_completion, friends[], friend_requests[], groups[], highlights{}, bookmarks{}` — `GET /user/{user_id}` returns all of that (minus `hash_pass`) to *any* logged-in caller for *any* `user_id`, not just the fields a friends/groups UI needs.

**Exploit scenario:** Any authenticated user can enumerate other users' real email addresses (PII), whether they have MFA enabled (useful account-takeover recon), their pending friend requests from third parties (private social-graph data about people who aren't even the caller), and their suspension status — none of which is needed to "display friends' and group members' usernames," the stated purpose.

**Fix:** Return a minimal public-profile projection (e.g. `user_id`, `username` only, plus whatever the actual UI consumers need) from this endpoint, and move anything more sensitive (email, mfa_enabled, friend_requests, suspended_at) behind an ownership check (`require_match`) the same way `PUT /user/{user_id}` already is.

---

## Medium

### M1. Silent write failures can produce false "success" responses (`api/db.py`, `api/backend/interactions/helpers.py::save_users_data`)
**File:** `api/db.py:910-921` (`DBManager.insertion`), `:952-964` (`DBManager.update`)
**Category:** OWASP A10 Mishandling of Exceptional Conditions / A08 Data Integrity Failures. Directly matches the project's own stated preference (Architecture Q27: propagate errors upward rather than silently substituting a default) — and the codebase's own comments document this exact failure mode having already caused a real bug (`db.py`'s comment on the `agents` table: "create_agent's route still returned 201 even though the row never persisted").

`insertion`/`update` catch `sql.Error`, log, and roll back — but never re-raise or return a failure signal. Most call sites don't check a return value (there isn't one to check), so a transient DB error becomes indistinguishable from success everywhere except the two paths (`save_user_row`, `update_user`) that were explicitly fixed to re-raise. `main.py`'s signup/Google/Apple flows all call `persist_new_user`/`save_users_data`/`save_users` (the *unfixed* bulk-and-swallow helper) — a transient DB error there can complete signup/OAuth with a session cookie issued for a user row that was never actually written to Postgres.

**Fix:** Apply the same pattern already used for `save_user_row` (raise on failure, let the caller 500 instead of returning a fabricated success) to `persist_new_user`'s call path, or at minimum to every account-creation route.

### M2. No rate limiting on MFA confirmation/disable (`api/main.py`)
**File:** `api/main.py:410-447` (`mfa_confirm`, `mfa_disable`)
**Category:** OWASP A07 Identification and Authentication Failures / ASVS 5.0 6.3.1 (anti-automation against brute force).

Every other auth-adjacent endpoint in `main.py` carries a `@limiter.limit(...)` (signup 5/min, login 10/min, `mfa_verify_login` 10/min, password-reset request/confirm 5–10/min) — `mfa_enable`, `mfa_confirm`, and `mfa_disable` carry none. `mfa_confirm` checks a 6-digit code (1,000,000 possibilities) against a 10-minute-TTL, single-use value with no per-account/IP throttle; `mfa_disable` checks the account password with no throttle either. Both require an existing valid session, so the practical exposure is a hijacked/shared session rather than a cold attacker, but that's exactly the scenario 2FA and re-authentication-on-disable exist to defend against.

**Fix:** Add the same `@limiter.limit(...)` pattern used on `mfa_verify_login` to `mfa_confirm` and `mfa_disable`.

### M3. No cost/consumption bound on the agent chat WebSocket (`api/routes/agent.py`)
**File:** `api/routes/agent.py:19-29` (`agent_ws_endpoint`) → `api/backend/interactions/agent.py:313-377` (`connect_agent`)
**Category:** LLM10 Unbounded Consumption.

Every HTTP write on `agent_router` is protected by `check_limit(user_id, ...)` free-tier gating (notes cap, agent_events cap), but the WebSocket chat loop (`connect_agent`) has no equivalent: once connected, a client can send unlimited `{"content": ...}` frames, each triggering a full, billed OpenRouter `deepseek/deepseek-chat` call (`max_tokens: 2048`) with no per-message, per-minute, or per-session cap.

**Fix:** Apply a message-rate or per-session call-count limit inside the WebSocket loop (e.g. a token-bucket keyed on `user_id`), consistent with the caps already enforced on the HTTP heartbeat/summarize endpoints for the same underlying LLM cost.

### M4. Full process environment (all secrets) handed to a third-party MCP subprocess (`api/backend/monitoring/cloudwatch_mcp_client.py`)
**File:** `api/backend/monitoring/cloudwatch_mcp_client.py:158-159`
**Category:** OWASP A02 Security Misconfiguration (least privilege) / ASI04 Agentic Supply Chain Vulnerabilities. Relevant to Security Posture Q9 (supply-chain trust should be vetted for every dependency).

`StdioServerParameters(command=parts[0], args=parts[1:], env=dict(os.environ))` passes the **entire** parent process environment to the spawned `awslabs.cloudwatch-mcp-server` subprocess — including `DB_PASSWORD`, `STRIPE_SECRET_KEY`, `OPENROUTER_API_KEY`, `SES_ACCESS_KEY_ID`/`SES_SECRET_ACCESS_KEY`, and every other secret this codebase's config loading treats as an ordinary env var (see also Configuration-philosophy note under M5). That subprocess only needs AWS credentials/region to do its job.

**Exploit scenario:** A bug, misconfiguration, or supply-chain compromise in this third-party pip package (a dependency this repo doesn't control the release process of) that leaks its own environment (e.g. an error page, a debug/telemetry call, a crash dump) would exfiltrate every secret the main API process holds, not just AWS access.

**Fix:** Construct a minimal `env` for the subprocess containing only the AWS-related variables it actually needs (region, and whatever credential-resolution chain it uses), rather than forwarding the full parent environment.

### M5. Tauri desktop shell disables CSP and loads live remote content as its production window (`desktop/src-tauri/tauri.conf.json`)
**File:** `desktop/src-tauri/tauri.conf.json:8,14,21-23`
**Category:** OWASP A02 Security Misconfiguration.

`app.windows[0].url` is set to the live production site (`https://fellowscript.com/reader`) for the shipped app itself — not just `build.devUrl` for local development — and `app.security.csp` is explicitly `null`. Tauri's own security guidance treats loading remote content directly (rather than bundled `frontendDist` assets) as an elevated-risk pattern precisely because the webview retains access to Tauri's native IPC bridge and whatever permissions are granted (here, `capabilities/default.json` grants `core:default`). Any XSS reachable on the live website — including a bypass of the frontend's own note-HTML sanitizer, a compromised third-party script, or a CDN/DNS-level MITM — would execute with access to the desktop app's native capabilities and with no CSP mitigating it.

**Fix:** At minimum, set an explicit restrictive CSP (`app.security.csp`) rather than `null`. Longer-term, prefer bundling a local shell (`frontendDist`) that only reaches out to the API origin via `fetch`, rather than loading the entire live site as the top-level window content with Tauri's IPC surface attached.

### M6. `DB_PASSWORD` has no fail-fast validation at startup (`api/db.py`)
**File:** `api/db.py:855-862`, `:898-906`
**Category:** Configuration Philosophy Q4/Q6 (fail-fast, no implicit defaults) — the project's own stated standard, already correctly applied elsewhere (`apple_service.py`'s `APPLE_ALLOW_SANDBOX` raises `RuntimeError` if unset).

`_connect()`/`DBManager.__init__` read `password=os.getenv("DB_PASSWORD")` with no presence check — an unset `DB_PASSWORD` silently passes `None` to `psycopg2.connect(...)` rather than refusing to start with a clear error, unlike `APPLE_ALLOW_SANDBOX`'s explicit "no implicit default" pattern in the same codebase.

**Fix:** Validate `DB_PASSWORD` (and similarly-load-bearing secrets) is present at process startup and raise a clear, specific error if not, matching the `APPLE_ALLOW_SANDBOX` precedent already in this codebase.

---

## Low

### L1. Hardcoded admin-seed email in source (`api/db.py`)
**File:** `api/db.py:75` (`_ADMIN_SEED_EMAIL = "jaceysimps@gmail.com"`)
**Category:** Configuration Philosophy (deployment-specific values belong in config/env, not in-code constants) — low severity since this value is already exposed via C1's `data/users.json` regardless.

Move to an environment variable or deploy-time config value so a future deployment/environment (staging, a second admin) doesn't require an in-code edit.

### L2. `allow_credentials` not set explicitly on CORS middleware (`api/main.py`)
**File:** `api/main.py:104-113`
**Category:** OWASP A02 Security Misconfiguration (minor / defense-in-depth documentation gap).

`CORSMiddleware` is configured with an explicit `allow_origins` list (good — deny-by-default) but no `allow_credentials`, which defaults to `False`. This currently works because the frontend calls the API same-origin (`https://fellowscript.com/api`, reverse-proxied), so the session cookie never needs cross-origin credentialing — but the `http://localhost:5173` dev origin is in the allowlist, and a developer testing against the deployed API cross-origin with `credentials: 'include'` would find the cookie silently dropped rather than getting an explicit, documented reason why. Not exploitable as-is; worth an explicit `allow_credentials=False` with a comment (or `True` if the dev-origin case needs it) so the reviewer doesn't have to reconstruct the reasoning above.

---

## Summary by category

| Category | Findings |
|---|---|
| A01 Broken Access Control | H1, H2, H3 |
| A02 Security Misconfiguration | C1, C2, M4, M5, L1, L2 |
| A07 Authentication Failures | M2 |
| A08 / A10 Data Integrity & Exceptional Conditions | M1 |
| Configuration Philosophy (fail-fast/secrets separation) | M6, L1 |
| LLM10 Unbounded Consumption | M3 |
| ASI04 Agentic Supply Chain | M4 |

**Not flagged (checked, found sound):** Stripe/Apple webhook signature verification (`stripe_service.construct_event`, `apple_service.decode_jws` with pinned Apple Root CA), session/MFA/password-reset token handling (opaque + SHA-256-hashed + TTL + single-use), WebSocket sender-identity spoofing (already fixed, `payload["from_user"] = session_user`), content-moderation fail-closed severity tier selection, the CloudWatch debug agent's prompt-injection/secret-redaction defenses, and the React frontend's allowlist-based note-HTML sanitizer (agent/LLM-authored note content is safely constrained before rendering).
