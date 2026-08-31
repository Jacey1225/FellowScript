# Backend

The backend is a **FastAPI + Postgres** application in `api/`. All code follows a strict three-layer flow:

```
routes/ (HTTP)  ──▶  backend/interactions/ (logic + DB)  ──▶  Postgres
   ▲                          │
   └── schemas/ (Pydantic) ───┘
```

---

## Entry Point — `main.py`

Registers all routers, configures CORS, and handles the three authentication routes directly (password signup/login, Google OAuth, Apple Sign In). Also starts the background scheduler on startup via `lifespan`.

CORS is restricted to `https://fellowscript.com`, `https://www.fellowscript.com`, and the local dev origin — not a wildcard. `/signup` (5/min) and `/login` (10/min) are rate-limited per-IP via `slowapi` to slow down brute-forcing and mass account creation; production sits behind Cloudflare, so the limiter keys off the `CF-Connecting-IP` header (`get_client_ip()`) rather than `request.client.host`, which would otherwise resolve to a rotating Cloudflare edge IP and never actually limit anything.

Auth routes in `main.py`:

| Route | Method | Description |
|---|---|---|
| `/signup` | POST | Register with username + password; creates free-plan subscription |
| `/login` | POST | Authenticate with username + password |
| `/auth/google` | POST | Validate Google ID token; find-or-create user |
| `/auth/apple` | POST | Verify Apple JWT (JWKS); find-or-create user |
| `/user/{user_id}` | GET / PUT / DELETE | Read, update, or permanently delete a user account |
| `/auth/password-reset/request` | POST | Email a single-use, 30-minute reset link if the address has an account (always returns the same generic response either way) |
| `/auth/password-reset/confirm` | POST | Set a new password from a reset token; invalidates every existing session on the account |
| `/auth/mfa/enable` | POST | Email a confirmation code to start turning on 2FA (authenticated) |
| `/auth/mfa/confirm` | POST | Verify the confirmation code and turn 2FA on (authenticated) |
| `/auth/mfa/disable` | POST | Turn 2FA off; requires re-entering the current password (authenticated) |
| `/auth/mfa/verify-login` | POST | Complete a login paused by `/login` for 2FA: verify the emailed code and issue the session |
| `/user/{user_id}/accept-terms` | POST | Record acceptance of the current Terms version (authenticated) |

Web-only 2FA: if a user has 2FA enabled, `/login` doesn't issue a session — it emails a 6-digit code and returns `{"mfa_required": true, "user_id": ...}`; the frontend then calls `/auth/mfa/verify-login` to finish. Not implemented on iOS yet.

**EULA gate (Guideline 1.2)**: `/signup`, `/auth/google`, and `/auth/apple` all require `terms_accepted: true` on new-account creation (422 otherwise) — enforced on all three since Apple may review via any of them. `CURRENT_TERMS_VERSION` (`schemas/users.py`) is stamped on every new account; if an existing account's stored version doesn't match on login, the response includes `terms_reaccept_required: true` and the client shows a blocking "Updated Terms" screen before calling `/user/{id}/accept-terms`. Accounts with `users.suspended_at` set (via the moderation CLI, see below) get a 403 on every auth path instead of a session.

**Apple name/email fallback**: Apple only ever supplies `full_name`/`email` to the client on the very first authorization for a given Apple ID + app — a missed or incomplete grant (e.g. the user already authorized this app before, in testing or otherwise) can never be recovered from Apple again. `/auth/apple` sets `users.needs_profile_completion = true` on account creation whenever either is missing, and the response (and every subsequent `/auth/apple`, `/login`, `GET /user/{id}` response, since it's just another user field) includes it so the client can prompt the user to set a real username/email manually. `PUT /user/{id}` clears the flag as soon as a `username` or `email` is supplied.

---

## Layer 1 — `schemas/`

Pydantic models defining request/response shapes and internal records. One file per domain.

| File | Key models |
|---|---|
| `schemas/users.py` | `User`, `SignUp`, `Login`, `UpdateUser`, `Note` |
| `schemas/message.py` | `Message`, `Group` |
| `schemas/devotion.py` | `DevotionPlan`, `DevotionRequest` |
| `schemas/agent.py` | `AgentConfig`, `AgentEvent` |
| `schemas/subscription.py` | `Subscription`, `FREE_LIMITS`, `EXPIRY_GRACE_DAYS` |
| `schemas/filter.py` | `FilterParams` |

---

## Layer 2 — `backend/interactions/`

All business logic lives here in `*Manager` classes that subclass `DBManager`. Routes never touch SQL directly.

| Manager | File | Responsibility |
|---|---|---|
| `GroupsManager` | `groups.py` | Create/join/leave groups, add members |
| `FriendsManager` | `friends.py` | Friend requests, friend list, remove, friend-activity read surface (`get_friend_activity`) |
| `DevotionManager` | `devotion.py` | Devotion plans, participants, progress |
| `AgentManager` | `agent.py` | AI agent config, heartbeat events |
| `FilterManager` | `filtering.py` | Note filtering by book, date, user, title |
| `SortingManager` | `sorting.py` | Note sorting by timestamp |

`DBManager` (in `db.py`) provides four auto-committing helpers: `insertion`, `lookup`, `update`, `delete`. Raw cursor (`self.cur.execute`) is used for JOINs, array ops, and aggregations.

---

## Layer 3 — `routes/`

Thin `APIRouter` handlers. Each handler: instantiates a manager, calls one method, maps `{"error": ...}` → `HTTPException`, closes the connection in `finally`.

| Router | Prefix | Description |
|---|---|---|
| `notes_router` | `/notes` | Notes CRUD, highlights, bookmarks, replies |
| `ws_router` | `/ws` | WebSocket group chat + DMs |
| `chime_router` | `/messages` | REST message history |
| `group_router` | `/groups` | Group management |
| `friend_router` | `/friends` | Friend management |
| `filter_router` | `/filter` | Note filtering |
| `sorting_router` | `/sort` | Note sorting |
| `devo_router` | `/devotions` | Devotion plans |
| `agent_router` | `/agent` | AI agent config + heartbeats |
| `notification_router` | `/notification` | Device-token registration only — the former CRUD/trigger/scheduling endpoints were removed in full (2026-08-26); replacement pending, see `docs/api/overview.md` |
| `subscription_router` | `/subscriptions` | Subscription lookup, Stripe + Apple webhooks |
| `donation_router` | `/donation` | One-time donation flow |
| `report_router` | `/reports` | Guideline 1.2 content/user reporting |
| `block_router` | `/blocks` | Guideline 1.2 user blocking |
| `monitoring_router` | `/monitoring` | Read-only CloudWatch error-detection feed + the debugging agent's reports (see `backend/monitoring/` below) |

---

## `backend/monitoring/`

A sibling package to `interactions/` for the CloudWatch-based error monitoring workflow (poll → detect → assemble context → persist → diagnose → serve).

| File | Responsibility |
|---|---|
| `cloudwatch_mcp_client.py` | `CloudWatchMCPClient` — async wrapper over the read-only `cloudwatch-mcp-server` (Logs Insights query + `analyze_log_group`). |
| `watchdog.py` | `WatchdogManager(DBManager)` — per-log-group cursor bookkeeping, error-signal regex scan, context assembly, and detection persistence (`run_cycle`); also the read methods (`list_detections`, `count_detections`, `get_detection`) backing the `/monitoring` routes. Right after a detection persists, `run_cycle` hands it off to `debug_agent.run_debug_agent_for_detection` (offloaded via `run_in_executor` so the blocking OpenRouter call never stalls the event loop). |
| `debug_agent.py` | `DebugAgentManager(DBManager)` — the error-debugging agent. Given a detection's `message` + `context`, redacts anything shaped like a secret/credential/API key/connection-string password, then calls OpenRouter (reusing `AgentManager`'s `MODELNAME`/`BASEURL`/`HEADERS` wiring — no second isolated credential) for a root-cause + remediation-narrative diagnostic report, persists it to `error_detection_reports` (upsert on `detection_id`), and routes the detection's `status` to `"diagnosed"`. Strictly read-only/reporting: no shell, system, or AWS-write access, and the model is explicitly instructed to describe recommended remediation steps, never narrate one as already taken. |

Detection is application-level (regex scan of pulled log messages against named signal patterns — traceback, critical, error level, nginx severity tags, HTTP 5xx, errno) rather than CloudWatch alarms/metric filters, which aren't configured in this AWS account. Nothing in this package executes or takes any action against the server — the watchdog only reads via the MCP client and writes to this app's own `error_detections`/`log_group_cursors` tables, and the debugging agent only reads those tables plus calls OpenRouter for a text diagnosis it persists to `error_detection_reports`.

---

## `backend/subscription/`

A sibling package to `interactions/` dedicated to billing and usage enforcement.

| File | Responsibility |
|---|---|
| `subscriptions.py` | `SubscriptionsManager` — create free plan, get subscription, reconcile expired |
| `limits.py` | `LimitsManager` — `is_subscribed()`, per-resource usage counts, `check()` |
| `stripe_service.py` | Stripe Checkout session creation and webhook handling |
| `apple_service.py` | Apple App Store receipt/notification validation |

Every new user (all three auth paths) gets a `plan_type='free'` subscription row created by `SubscriptionsManager.create_free_plan()`. Free-tier limits (`FREE_LIMITS`: notes 10/week, agent_events 1) are enforced server-side via `check_limit(user_id, resource)` — which returns a 403-able gate dict — at **every** write path that creates a gated resource, so the cap holds for web and iOS alike. The full enforcement surface: notes → `POST /notes/{user_id}` (`create_note`), `POST /notes/reply/{note_id}` (`post_reply`), and `POST /agent/{user_id}/{agent_id}/summarize` (`summarize_session`, whose AI summary is persisted as a note) — all three count against the one weekly notes cap; agent_events → `POST /agent/{user_id}/{agent_id}/heartbeat` (`add_heartbeat`, the only heartbeat-insert path). The former `agent_notifications` gated resource (a cap on user-authored "agentic" notifications) was removed along with that subsystem (2026-08-26). When auditing, the invariant to preserve is: **any new route that inserts into `notes` or `agent_heartbeats` must call `check_limit` first** (a subscribed user is reported `unlimited` and always allowed). That free row is internal bookkeeping only — `GET /subscriptions/user/{id}` (`get_user_subscription`) reports a free-tier user as **`404`/no plan**, never as the free row, so clients render the upgrade UI instead of painting the free tier as an active plan (`LimitsManager.is_subscribed` applies the same `plan_type != 'free'` rule). Returning the free row here is what made the iOS Account screen show an active "Group Plan · $0/mo" with "Unlimited" usage for brand-new accounts.

There is a single paid tier, `'group'`, covering however many people (1-8) the host selects. `schemas/subscription.py`'s `GROUP_PRICE_CENTS` dict is the server-authoritative price-by-member-count lookup (`price_for(member_count)`), replacing the old two-tier `individual`/`group` model — selecting 1 member is priced identically to the old Individual plan. `stripe_service.create_checkout_session` builds the Stripe Checkout line item's price inline from this table for any count (no pre-created Stripe Products needed); `apple_service.APPLE_PRODUCTS` maps 8 fixed-price StoreKit product IDs (`com.fellowscript.access.one`…`com.fellowscript.access.eight`) to their member count, since Apple IAP can't compute an arbitrary price. A host can change their plan's member count later via `PUT /subscriptions/{id}` with `member_count`, which re-derives `price_cents`/`max_members`.

**Apple sync guards** (three layers, spanning both `POST /subscriptions/apple/sync` and `POST /subscriptions/apple/notifications`): iOS reports every currently-active StoreKit entitlement (`Transaction.currentEntitlements`) to `/apple/sync` on each launch — a device/Apple-ID-level API, not scoped to whichever FellowScript account is signed in — and Apple's servers push renewal/refund/cancel events to `/apple/notifications`, which (like the Stripe webhook) has no user session and authenticates purely via the payload's own signature.
1. **Signature verification (primary)**: `apple_service.decode_jws` verifies every JWS's `x5c` certificate chain against a pinned copy of Apple's Root CA - G3 before trusting any claim in the payload, then checks the ES256 signature itself. A JWS that doesn't chain to Apple's real root, or whose signature doesn't match, is rejected with `ValueError` (surfaced as `400`) before its payload is ever read — closing both the authenticated-user-forges-their-own-sync and the unauthenticated-anyone-forges-a-notification paths.
2. **Environment gate**: every StoreKit transaction carries an `environment` (`"Xcode"` = local `.storekit`-file testing, `"Sandbox"` = TestFlight/App Review, `"Production"` = real purchase). The route calls `apple_service.is_accepted_environment(...)` and rejects with `400` before touching the DB unless it's `Production` (always) or `Sandbox` (gated by `APPLE_ALLOW_SANDBOX`, which must be explicitly `"true"` or `"false"` — the process refuses to start if it's unset, no implicit default). This is what stops a dev device's fabricated `"Xcode"` transaction (id `"0"`) from turning every account signed in on that device into a paid plan — the actual cause of the repeated "new accounts show the paid plan" reports.
3. **Ownership guard (defense-in-depth)**: `upsert_from_apple` still returns `None` → `409` if the `apple_original_transaction_id` is already tied to a *different* `user_id`, so one real transaction can't be spread across accounts.

---

## `backend/email/`

Transactional email delivery via AWS SES, used by the password-reset and 2FA flows.

| File | Responsibility |
|---|---|
| `ses_client.py` | `send_email()` — thin wrapper over `boto3`'s `sesv2` client; raises `EmailSendError` on failure. Uses a separate, narrowly-scoped IAM credential (`SES_ACCESS_KEY_ID`/`SES_SECRET_ACCESS_KEY`) from the Chime SDK user, per least-privilege. |
| `templates.py` | `password_reset_email()`, `mfa_code_email()`, `mfa_setup_code_email()` — each returns `(subject, html_body, text_body)`. CAN-SPAM-compliant: truthful sender identity, a support contact, and a physical mailing address footer (`SENDER_POSTAL_ADDRESS` env var — must be set to a real address before sending real mail). |

`backend/auth/password_reset.py` (`PasswordResetManager`) and `backend/auth/mfa.py` (`MFAManager`) generate the actual tokens/codes — both mirror `SessionManager`'s pattern of storing only a sha256 hash, never the raw secret.

---

## `backend/moderation/` — Guideline 1.2 (User-Generated Content)

| File | Responsibility |
|---|---|
| `content_filter.py` | `check_clean(**fields)` — severity-graded local content filter built on `better_profanity`'s matching engine, raises `ContentRejected(field, matched)` on a match. Hard-rejects submission (422) rather than auto-flagging-and-posting. Wired into note/reply create+update (`routes/notes.py`), group title create+update (`routes/community.py`), devotion title+prompts create+update (`routes/devotion.py`), and the one non-HTTP path, `ConnectionManager.send_msg` (`backend/interactions/websockets.py`), which replies with an error frame to the sender's own socket instead of raising. As of 2026-08, ordinary profanity is allowed — only a curated `_EXPLICIT_TERMS` list (explicit sexual acts, sexual exploitation, hateful slurs) triggers a reject, not `better_profanity`'s much broader default wordlist. Which tier of `_SEVERITY_TIERS` is active is controlled by the `CONTENT_FILTER_SEVERITY` env var (default `"explicit"`; an unrecognized value fails closed to the strictest known tier rather than silently loading an empty list). Every call site builds its 422/error-frame message via `rejection_message(e)`, which names the specific flagged text (`e.matched`) in a warm, on-brand tone instead of a generic "contains language that isn't allowed" message. |
| `admin_actions.py` | CLI for resolving reports: `python -m backend.moderation.admin_actions list` / `resolve <report_id> [--remove-content] [--eject] [--dismiss]`. Removing content deletes/resets the note, message, devotion prompts, or group title by id; ejecting sets `users.suspended_at` and calls `SessionManager.delete_all_for_user()` to kill any active session immediately. No self-service admin UI exists yet — this is the "act within 24 hours" tool the report email points at. |

**Reporting** — `backend/interactions/reports.py` (`ReportsManager`): `create_report(content_type, content_id, reported_user_id, reason, detail)` resolves the *current* author + text server-side (never trusts the client for who/what is reported), inserts a `content_reports` row with a frozen `content_snippet` (survives later edits/deletes), and emails `SUPPORT_EMAIL` via `backend/email/templates.py`'s `content_report_email()` (HTML-escapes the snippet before interpolation). `content_type` is one of `note` / `message` / `devotion_prompt` / `group_title` / `user`.

**Blocking** — `backend/interactions/blocks.py` (`BlockManager`): `block_user()` severs any existing friendship/pending request both directions and auto-creates a `content_reports` row (`reason='blocked'`) — one unified developer queue rather than a parallel notification system. `is_blocked()` checks both directions. Enforced at every read path a blocked relationship could otherwise leak through: `friends.py`'s `send_add_request`/`add_friend`/`read_friend`/`get_friend_activity` (friend-activity dashboard feed — re-checks `blocked_users` both directions rather than trusting `user_friends` alone, same defense-in-depth as `ActivityManager.friend_device_tokens`), `groups.py`'s `fetch_notes`/`fetch_replies`/`fetch_group` (member roster stays visible for transparency; only their content is hidden), `websockets.py`'s `send_msg` (drops DMs entirely between blocked parties; skips delivery-only for group messages so other members still see them), and `devotion.py`'s `fetch_by_contact`. Retroactively removing a blocked user from an already-joined live Chime call is a known, accepted gap.

---

## `backend/backup/`

A sibling package to `interactions/` for the nightly per-user data backup (see [Data → Nightly Backup Database](data.md) for the schema/scope).

| File | Responsibility |
|---|---|
| `manager.py` | `BackupManager` — holds two DB connections at once (`source`: primary `fellowscript` DB, `dest`: separate `fellowscript_backup` DB). `users_due_now()` finds users whose local time is currently 03:00; `backup_user()` copies that user's recent notes/verses and full highlights/bookmarks into the backup DB via upsert. |

Unlike other managers, `BackupManager` doesn't subclass `DBManager` directly — it composes two `DBManager` instances (constructed via `DBManager(dbname=...)`) since it reads from one database and writes to another.

---

## `db.py` — Schema and `DBManager`

`create_tables()` defines the full Postgres schema in FK-dependency order (Level 0 → Level 2). Additive `ALTER TABLE … ADD COLUMN IF NOT EXISTS` statements at the top of `create_tables()` handle live migrations without dropping data.

### Schema summary (Level 0 → 2)

**Level 0 (no FK)**
- `users` — `_id`, `username`, `email`, `hash_pass`, `apple_sub`, `google_sub`, `subscription_id`, `timezone`
- `groups` — `_id`, `title`, `members UUID[]`, `highlights JSONB`
- `subscriptions` — `_id`, `user_id`, `plan_type`, `provider`, `status`, `price_cents`, `current_period_end`, Stripe/Apple identifiers

**Level 1 (FK → Level 0)**
- `notes` — `_id`, `user_id`, `title`, `text`, `public`, `group_id`, `timestamp`, `created_at`
- `messages` — `_id`, `from_user`, `group_id`, `content`, `is_dm`, `timestamp`
- `highlights` — `(user_id, key)` composite PK, `color`
- `bookmarks` — `(user_id, key)` composite PK, `label`
- `notifications` — `_id`, `user_id`, `type`, `message`, `read`
- `agents` — `_id`, `user_id`, `config JSONB`
- `devotions` — `_id`, `creator_id`, `title`, `participants UUID[]`
- `friend_requests` — `from_user_id`, `to_user_id`
- `friend_list` — `user_id`, `friend_id`

**Level 2 (FK → Level 1)**
- `note_verses` — `note_id`, `position`, `book`, `chapter`, `verse`
- `agent_heartbeats` — `_id`, `user_id`, `last_fired`
- `message_recipients` — `message_id`, `recipient_id`

---

## Background Scheduler

`backend/interactions/scheduler.py` runs on startup (via `lifespan`), using APScheduler. Current jobs:

The former `_fire_due_notifications` job (fired user-authored "agentic" notifications on their scheduled time-of-day) was removed in full (2026-08-26) along with that subsystem. A replacement set of fixed-notification jobs (activity-tracked reminders + friend-went-active) is pending as a follow-up step in the same task.

| Job | Cadence | Does |
|---|---|---|
| `_run_nightly_backups` | every minute | Copies any user whose *local* time is currently 03:00 into the backup database (see `backend/backup/`) |
| `_reconcile_trials` | every hour | Advances elapsed trials to active, and removes subscriptions whose paid period lapsed past the grace window |
| `_run_error_watchdog` | every 90s | Polls the 5 CloudWatch log groups the agent ships (`nginx access/error`, `syslog`, `auth`, `app`) via `WatchdogManager.run_cycle`, detects errors, assembles context, persists to `error_detections`, and triggers the debugging agent once per new detection (see `backend/monitoring/` above) |

Heartbeat (AI agent event) firing is **not** scheduled server-side — it's driven entirely client-side by iOS's `HeartbeatScheduler.checkAndFire`, which calls the same `commit_heartbeat` endpoint on app foreground.
