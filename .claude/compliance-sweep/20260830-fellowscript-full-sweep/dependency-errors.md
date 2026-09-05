# Dependency / Third-Party Boundary Error Handling — FellowScript Full Sweep

Task ID: `20260830-fellowscript-full-sweep` — Step 4 of `/compliance-sweep`.

Reviewed surface: manifest/lockfile health across all four project areas
(`requirements.txt`; `frontend/package.json` + `package-lock.json`;
`desktop/package.json` + `package-lock.json`; `desktop/src-tauri/Cargo.toml` +
`Cargo.lock`; `FellowScript/.../Package.resolved`), plus call-site error
handling for every third-party/network/subprocess/DB boundary reachable from
`file-inventory.json`'s reviewable list: Stripe and Apple StoreKit billing,
AWS SES/SNS/STS/CloudWatch, the OpenRouter LLM integration, APNs push, the
CloudWatch MCP subprocess client, the nightly-backup Postgres mirror, iOS
`NetworkService`/`StoreKitManager`/`GoogleAuthSession`, and the fetch/WebSocket
layers of both the legacy vanilla-JS frontend and the React app. `npm audit
--omit=dev` was run against `frontend/package-lock.json` (0 vulnerabilities
at any severity as of the current advisory database).

## Critical

None found.

## High

1. **`api/backend/subscription/stripe_service.py:118-125` (`cancel_subscription`) called from `api/routes/subscription.py:358-373` (`delete_subscription`) — Stripe cancellation failure is swallowed, then the local plan row is deleted anyway.**
   `cancel_subscription` catches every exception, logs a warning, and returns normally ("best-effort" per its own docstring). Its only caller, the `DELETE /subscriptions/{id}` route, does not check the outcome — it unconditionally proceeds to `db.delete_subscription(subscription_id)` right after. If the Stripe API call fails (network blip, Stripe outage, expired API key), the user's plan disappears from FellowScript's own records while the underlying Stripe subscription keeps running and billing them — an orphaned, still-live subscription with no local record and no retry path. This is exactly the "swallow the error and keep going as if it succeeded" pattern the user's Architecture Q27 preference (propagate rather than silently substitute a default) is meant to catch, compounded by a real financial-impact consequence.
   *Fix:* Either surface `cancel_subscription`'s outcome to the caller and refuse (or explicitly warn/retry) if Stripe cancellation didn't succeed before deleting the local row, or persist a "pending cancellation" state so a background job can retry Stripe cancellation until it succeeds before the row is fully removed.

2. **`api/backend/interactions/agent.py:200-241` (`commit_hb_response`) called from `api/routes/agent.py:130-151` (`commit_heartbeat`) — the once-per-day heartbeat claim is committed to the DB *before* the unhandled OpenRouter call, so a network failure permanently burns the day's slot with no note produced.**
   `commit_hb_response` first does an atomic `UPDATE ... RETURNING _id` + `self.conn.commit()` to claim today's fire slot (lines 200-214), then calls `self._call_api(agent_role, ...)` (line 241) with **no try/except** around it. `_call_api` (line 282-293) does a synchronous `requests.post` with a 60s timeout and `resp.raise_for_status()` — if OpenRouter times out, 5xxs, or the connection fails, the exception propagates all the way up through `commit_heartbeat`, which also has no except clause (only `finally: db.close()`), and is caught only by FastAPI's generic 500 handler. The user sees a bare failure and — because the claim was already committed — cannot retry today: `commit_hb_response`'s own idempotency guard will report "already fired today" on any subsequent attempt, and no note or context row was ever saved. Contrast with `connect_agent` (the WebSocket chat path) in the same file, which wraps the identical `_call_api` call in try/except and returns a friendly in-band error (lines 338-355) — this is the established, safer pattern the heartbeat path should also follow.
   *Fix:* Wrap the `_call_api` call in `commit_hb_response` in try/except; on failure, either roll back/unset the `last_fired` claim so the slot isn't lost, or persist enough state to let a retry succeed without re-claiming, and return a typed error the route can turn into a non-500 response.

## Medium

3. **`api/routes/agent.py:217` (`summarize_session`) — direct, unhandled call to `db._call_api(...)` for the OpenRouter session-summary request.**
   No try/except around this network call in the route itself, and `_call_api` has no distinct timeout-vs-HTTP-error handling beyond its blanket `raise_for_status()`. Any OpenRouter hiccup (timeout, 5xx, malformed response) surfaces as a generic unhandled 500 with no user-facing message — inconsistent with `create_checkout`/`donate_checkout` (which both wrap their Stripe calls and return a clean `502` with a friendly detail) and with `connect_agent`'s handling of the same underlying `_call_api` function. Lower impact than finding #2 since no prior DB state is committed before the call, but the same class of gap.
   *Fix:* Wrap in try/except, log, and return `HTTPException(502, ...)` matching the Stripe-checkout pattern already established elsewhere in this codebase.

4. **Widespread empty/near-empty `catch {}` blocks on `fetch()` calls across both frontend stacks, e.g. `frontend/js/messaging.js:145-148,160-163,169-179,209-215,245-261,263-272,312-342,344-365` and `frontend/src/hooks/useMessaging.js:60-63,68-73,76-86,94-111,122-140,166-178,180-190,194-203,205-218,222-234,236-251,253-259`, `frontend/src/hooks/useNotes.js:67,83,104,153,163,178,187,273` — network failures are silently discarded rather than surfaced.**
   The great majority of `fetch()` call sites in both the legacy vanilla-JS frontend and the newer React app catch every failure (timeout, DNS failure, CORS, 5xx after `res.ok` check, JSON parse failure) with an empty or comment-only `catch {}` and either leave UI state unchanged or fall back to a placeholder (`fid.slice(0, 8)` as a display name, an empty preview string, etc.) with **no logging, no user-facing indicator, and no retry**. This directly contradicts the user's established Architecture Q27 preference (propagate the error upward rather than silently substituting a default) and Q26 preference for explicit checks/clear error returns. Because this pattern spans essentially every write path in the legacy messaging/notes/friends/groups flows (add friend, remove friend, create/update/leave group, post reply, delete note, apply filter/sort) as well as their React-hook counterparts, a user action can silently no-op with zero feedback whenever the backend is briefly unreachable — indistinguishable, from the user's perspective, from the action simply not being registered by the UI. `NetworkService.swift` on iOS was hardened against this exact class of bug (see its documented `decode()`/`reportFetchFailure()` machinery, added after two named production incidents — notes-load-failure-cloudwatch-gap and checkin-row-investigation); neither frontend stack has received the equivalent treatment.
   *Fix:* At minimum, log every caught network/parse failure (even if the UI still degrades gracefully), and surface a visible retry/error state for write actions (add/remove friend, group CRUD, note CRUD) rather than a silent no-op.

5. **No backoff or retry cap on WebSocket reconnect — `frontend/js/messaging.js:135-137` (`msgWs.onclose`) and `frontend/src/hooks/useMessaging.js:41-44` (`wsRef.current.onclose`).**
   Both the legacy and React messaging layers reconnect on a fixed 3-second timer indefinitely for as long as the sidebar/hook is mounted, with no exponential backoff and no maximum retry count. During an extended backend outage this produces an unbounded, unthrottled reconnect loop from every open client tab, adding load exactly when the backend is least able to absorb it, and never gives up or informs the user the connection is down.
   *Fix:* Add exponential backoff with a sane cap (e.g. 3s → 30s) and surface a "reconnecting…"/"offline" indicator after a few failed attempts, in both stacks.

6. **`FellowScript/FellowScript/Auth/GoogleAuthSession.swift:80-87` (`exchangeCodeForIDToken`) — the OAuth token exchange's failure path is silently discarded with zero logging.**
   `catch { return nil }` on the `URLSession.shared.data(for:)` call and subsequent JSON parse: unlike `NetworkService.swift` elsewhere in the same codebase (which explicitly logs and beacons every decode/fetch failure after two named production incidents caused by exactly this kind of silent client-side failure), a Google sign-in failure here — network error, Google API error, or a response missing `id_token` — produces no log line at all. A user reporting "Google sign-in doesn't work" leaves no diagnostic trail on the client side. Also no explicit HTTP status check (only whether `id_token` parses out of the body), so a 400/401 from Google with a clear error payload is treated identically to a network failure.
   *Fix:* At minimum add a `print`/logger line (mirroring `NetworkService.decode`'s pattern) before returning `nil`, and consider checking the HTTP status explicitly to distinguish a Google-side rejection from a transport failure.

## Low

7. **`desktop/src-tauri/Cargo.toml:25` — `tauri-plugin-log = "2"` is an unusually wide floating range compared to its sibling dependencies.**
   Cargo's default caret behavior means `"2"` accepts any `2.x.y`, materially wider than `tauri = "2.11.3"` and `tauri-build = "2.6.3"` in the same file (which float only within their minor version). `Cargo.lock` currently pins an exact resolved version, so this isn't an active break, but a future `cargo update` could pull in an unexpectedly large jump within the 2.x line for the one dependency that also touches logging output (a category the user's Security Posture Q13 treats as sensitive — logs should never accidentally start including more than intended after an unreviewed version bump).
   *Fix:* Tighten to a minor-version pin (e.g. `"2.x"` matching the others) the next time this file is touched.

8. **`frontend/package.json` — every direct dependency uses a caret range (`^`), including `amazon-chime-sdk-js` (`^3.31.0`), a large, frequently-updated SDK powering live audio/video calls.**
   `package-lock.json` is committed and `npm audit` currently reports zero vulnerabilities, so this is not an active break, but a fresh `npm install` without the lockfile (or an explicit `npm update`) could pull in a new minor/patch release of a call-critical third-party SDK with no version-bump review. Low severity given the lockfile mitigates the common case, but worth noting since `amazon-chime-sdk-js` sits on the same versioning cadence as the pinned `amazon-chime-sdk-ios-spm` (0.27.3, exact-pinned via `Package.resolved`) — the two platforms' Chime SDKs are not kept in version lockstep by anything in this repo.

9. **`FellowScript/FellowScript/Services/StoreKitManager.swift:136,208` — `try? await AppStore.sync()` and `try? await AppStore.showManageSubscriptions(in: scene)` silently discard failure.**
   Both are `try?`-swallowed with no logging and no user-facing feedback. Low impact: `restore()` still calls `syncEntitlements()` afterward regardless (which does propagate its own failures per-entitlement, per that function's much more careful handling), and a failed `showManageSubscriptions` just means the sheet silently fails to present — a confusing but non-destructive UX gap rather than a data-integrity risk.

## Package health — manifests reviewed, no other findings

- **`requirements.txt`** — every dependency is exact-pinned (`==`), including several (`psycopg2-binary`, `python-dotenv`, `apscheduler`, `h2`, `mcp`, `awslabs.cloudwatch-mcp-server`, `tzdata`) that the file's own inline comments document as previously-undeclared production gaps that have since been fixed and confirmed present on the deploy target — no currently-open gap found. `CLOUDWATCH_MCP_COMMAND`'s runtime default (`awslabs.cloudwatch-mcp-server`, a pinned console-script entry point) replaced an earlier `uvx ...@latest` floating-version subprocess target per that module's own comments — also resolved, not a live finding.
- **`FellowScript/.../Package.resolved`** — both SwiftPM dependencies (`amazon-chime-sdk-ios-spm` 0.27.3, `ViewInspector` 0.10.3) are pinned to an exact revision + version. No finding.
- **`desktop/src-tauri/Cargo.lock`** — present and current; resolves every `Cargo.toml` range (see Low #7 above for the one wide range in the manifest itself) to an exact version.
- **`frontend/package-lock.json`, `desktop/package-lock.json`** — both present; `npm audit --omit=dev` on `frontend/` returned 0 vulnerabilities (info/low/moderate/high/critical) across 260 production dependencies.
- Per `compliance-plan.md`'s forwarded note from Step 2/3: `frontend/node_modules/` (28,969 files) and `desktop/node_modules/` (17 files) are committed to git with no covering `.gitignore` entry, and `api/__pycache__/` (59 files) is likewise committed — flagging forward again here as instructed, since this is squarely a dependency/package-hygiene issue even though the files themselves are excluded from the reviewable set. Recommend adding `node_modules/`, `__pycache__/`, and `*.pyc` to the root `.gitignore` (and `frontend/.gitignore`, which does not currently exist) and removing the already-committed copies from version control.

## Positive notes (context, not findings)

Several third-party boundaries in this codebase are already handled to a high standard and were reviewed as a check on consistency rather than to file findings against:
- `api/backend/subscription/apple_service.py` (Apple JWS/x5c chain verification) — fail-closed throughout, exactly matching the user's Security Posture Q14 preference.
- `api/backend/interactions/push.py` (APNs) — explicit timeout, environment-fallback retry, and full exception handling.
- `api/backend/monitoring/watchdog.py` / `cloudwatch_mcp_client.py` — per-log-group isolation, a documented circuit breaker, and graceful degradation on `analyze_log_group` failure (confirmed via `api/tests/test_cloudwatch_analyze_log_group_arn.py`).
- `api/backend/email/ses_client.py` and the Stripe/Apple webhook handlers in `api/routes/subscription.py` — typed errors, explicit propagation instead of silent 200-acking.
- `FellowScript/FellowScript/Services/NetworkService.swift` — explicit timeouts, status validation, and documented decode/fetch-failure logging added after two named past incidents.
