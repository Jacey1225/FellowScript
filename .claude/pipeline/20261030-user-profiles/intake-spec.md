# Intake Spec: 20261030-user-profiles

## Request
(From Jacey via BALJEET) Design and build a user profile interface for FellowScript on all platforms (iOS, web frontend, Tauri desktop). Users can: (1) view other users' profiles; (2) write and edit a short bio message for themselves; (3) from a profile, add that user as a friend or send them a direct message.

Constraints: Hold the work to the 2026-09-05 restructure principles (throw-not-fabricate, preserve-cache-on-failed-refresh, no oversized NetworkService/View files; split rather than grow). Friends and DMs are new user-generated-content surfaces; the security gate must cover privacy (public vs friends-only profiles), block/report, rate limits and bio moderation, since App Store review will expect report and block. First check what already exists (DMs, contacts, accounts, profile or friend concepts) and reuse it. Flag open questions for Jacey: bio max length, profile visibility, whether DMs are friends-only, whether friend requests need acceptance. Do not deploy or push anything.

## Summary
Add a dedicated profile screen (other users' profiles plus self-edit of a short bio) on iOS, web, and Tauri desktop (which shares the web frontend), with Add Friend, Message, Block, and Report actions. Most plumbing already exists (friends, requests, DMs, blocks, reports, profile photos); the genuinely new pieces are a `bio` field, a profile view/edit UI, and a profile-shaped read endpoint with privacy rules.

## Type
Full (backend + iOS + web/desktop + design; new UGC and privacy surface).

## BRANCH WARNING
Checked-out branch `admin-promo-csv` is 128 commits behind `origin/main` (diverged). The local working tree is stale: e.g. the iOS Swift sources (`FellowScript/FellowScript/Account/BlockedUsersView.swift`, `Chat/ReportUserSheet.swift`, `AccountView+Profile.swift`) and frontend `ContactsPanel.jsx`/`Account.jsx` are only verified on origin/main. Recommend the build branch off up-to-date `origin/main` or a git worktree. Intake did not switch branches. Every downstream gate must re-verify existing code on that base before reusing it.

## Existing code to reuse (found, not yet verified on up-to-date base)
Backend (`api/`):
- `db.py`: tables `users`, `user_friends`, `friend_requests`, `blocked_users`, `friend_nudges`, `content_reports`. No `bio` column exists (grep found none on origin/main). New column goes via the `schema_ddl/` module pattern (one module per concern), not by growing `db.py`.
- `GET /user/{user_id}` in `main.py` already returns a "public profile" to any authenticated caller, strips email/mfa/friend_requests/suspended_at, and substitutes `profile_photo_url` for the raw S3 key. This is the natural base for the profile read; add `bio` plus relationship state (friend / request pending / blocked) without leaking more fields.
- `PUT /user/{user_id}` (main.py) edits username/email; bio edit may extend this or get a small dedicated route. `main.py` is already large: prefer a new route module.
- `routes/community.py` `friend_router`: list friends, requests, activity, `POST /{user_id}/request`, `/add`, `DELETE`, `nudge`, and `GET /{user_id}/{friend_id}/messages` (the DM thread). `routes/messaging.py` also has `/friend-request`, `/add-friend`, `/remove-friend`, websocket DM delivery. `backend/interactions/friends.py` holds `FriendsManager`.
- `routes/blocks.py` + `backend/interactions/blocks.py`: block/unblock/list; block already severs friendship and auto-files a report (Guideline 1.2).
- `routes/reports.py` + `content_reports`: report endpoint, with listing rate limiting via `backend/rate_limiting.py` / listings_config.
- `routes/profile_photo.py` + `backend/interactions/profile_photo.py`: photo upload/display.
- `backend/moderation/content_filter.py`: existing content filter (candidate for bio moderation), `admin_actions.py` (suspend/eject).
- Terms/EULA gate (`terms_accepted_at`, `CURRENT_TERMS_VERSION`) already exists.

iOS (origin/main, `FellowScript/FellowScript/`): `Account/AccountView+Profile.swift`, `Account/BlockedUsersView.swift`, `Chat/ReportUserSheet.swift`, `Chat/ContactSectionCollapse.swift`, `Services/NetworkService+*.swift` extension pattern.
Web/desktop (`frontend/src/`): `components/ContactsPanel.jsx`, `ChatThread.jsx`, `pages/Account.jsx`, `pages/InviteFriends.jsx`. Tauri desktop (`desktop/`) wraps the web frontend, so web work covers it; desktop scope is verifying routing/capabilities and any `DesktopRouteGuard` / desktop-scope rules.

## Scope
In bounds:
- Bio field (storage, validation, edit UI on own profile, moderation, display).
- Profile screen for any user, reachable from contacts list, chat/group member lists, and friend lists; entry points chosen by design gate.
- Actions on profile: Add Friend (reusing request/add flow, with states: none / request sent / request received / friends), Message (opens existing DM thread), Block, Report (reusing existing sheets/endpoints), Unfriend.
- Privacy enforcement server-side per the visibility decision; blocked users cannot view, request, or DM.
- Rate limits on bio edit, friend requests, and profile reads/lookups (enumeration).
- iOS, web, Tauri desktop parity; tests per layer.
Out of bounds:
- Rebuilding friends, DMs, blocks, or reports from scratch; new chat features.
- Profile photo redesign, usernames/handles changes, follower models, activity feeds, public/unauthenticated profile pages or SEO indexing of profiles.
- Deploy, push, merge, TestFlight, DB migration on production (the build produces code and local tests only).
- Android or other platforms.

## Acceptance criteria
1. Authenticated user can open another user's profile on iOS, web, and desktop and sees username, photo, bio, and relationship state; fields respect the visibility rule.
2. User can create/edit/clear own bio; server enforces max length, trimming, and content filter; client mirrors the limit; failed save keeps the user's draft and shows an error (throw-not-fabricate).
3. From a profile the user can send a friend request / accept / see pending, and open a DM; both reuse existing endpoints and DM thread.
4. Block and Report are available on every other-user profile (iOS and web), reuse existing endpoints, and block immediately hides profile and prevents requests/DMs both directions.
5. Server-side authorization for every new/changed route (deny-by-default; caller can only edit own bio; viewer permission checked on read); no email or other private field leaks.
6. Rate limits on bio edits, friend requests, and profile lookups, with tests.
7. A failed profile refresh keeps the cached profile on screen (preserve-cache-on-failed-refresh); no fabricated/default profile data on error.
8. No new file bloats NetworkService, AccountView, or an existing large view; profile code lives in new focused files/extensions (`NetworkService+Profile.swift`, `ProfileView*.swift`, `ProfileViewModel`, web `pages/Profile.jsx` + small components, backend new route/manager module).
9. Existing backend, frontend (vitest), and iOS tests still pass; new tests added; iOS simulator tests run serialized (never concurrently).
10. Accessibility (WCAG AA, reduced motion) and dark mode on the new UI; nothing deployed or pushed.

## Gate
(not applicable; Full)

## Preference profile
From ~/Downloads/ai_preference_survey_tracker.md (Architecture, UI/UX, Security, Configuration modules complete):
- Security Posture: deny-by-default, so new profile/bio/friend routes start authenticated-only and visibility defaults to the more restrictive option until decided; fail-closed under ambiguity.
- Security Posture: mandatory up-front threat modeling and a dedicated security self-review for features touching PII/external input (this feature does).
- Security Posture: authorization is purpose-built explicit permission checks, not a generic framework; input validation is defense-in-depth on sensitive paths (bio text is UGC).
- Security Posture: friction-adding hardening (rate limiting) only where a specific threat justifies it; here the threats are spam friend requests, bio abuse, and profile enumeration, which justify it; keep limits scoped to those.
- Security Posture: hard-stop for approval on changes to the authorization/permission model or security boundary; the visibility rules and any change to who can read `/user/{id}` are such a change, so surface to Jacey before implementing.
- Security Posture: sensitive data redacted from logs (do not log bio text or message bodies).
- Configuration: tunables (bio max length, rate limits) should follow the project's existing config pattern (e.g. `api/config/*.json` with eager startup validation), not scattered constants; secrets stay separate.
- UI/UX: dark mode first-class, spacious layout, mobile-first, genuine small-viewport design, WCAG AA, reduced-motion support, minimal empty/loading/error states with warm on-brand error tone, undo grace period for destructive actions (unfriend/block), shallow persistent navigation, propose alternatives and wait for approval at creative decisions, person-to-person chat styling.
- Architecture: mature-dependency preference; extensibility ahead of time is acceptable, but project-specific restructure principles (project memory) take precedence on file size.
- Per project memory: ask typographic-personality preference per project; FellowScript's existing design system governs (design-kit/), so follow it rather than propose a new brand.

## Open questions (for Jacey; gates should note defaults but not assume)
1. Bio max length? (Proposed default 160 chars, plain text, no links/markup; config-driven.)
2. Profile visibility: public to all signed-in users, friends-only, or user-selectable? Note `GET /user/{id}` already exposes username and photo to any authenticated user. (Proposed deny-by-default default: signed-in users see username+photo; bio visible to friends only unless Jacey decides otherwise.)
3. Are DMs friends-only, or can anyone message anyone (subject to blocks)? Existing DM endpoints appear friend-scoped; verify. This is an authorization-model decision.
4. Do friend requests need acceptance? Existing code has `friend_requests` and an `/add` accept step, which suggests yes (verify there's no auto-accept path such as invite codes); confirm to keep that.
5. Should a user be able to turn off incoming friend requests (the web has an `AcceptRequestsSwitch` component; verify its meaning)?
6. Bio moderation: reuse `content_filter.py` as pre-save reject, plus report-bio via existing report flow and admin removal? Or reactive-only?
7. Entry points to a profile (tap on member in group, chat header, contacts row, friend request list)? Design gate to propose.
8. Do unauthenticated/guest or suspended users appear? Suspended accounts should likely 404 on profile (security gate to confirm).
9. Which origin/main base should the build branch from (see Branch Warning), and are iOS CI/serialization constraints for simulator tests understood.
10. Does Tauri desktop need anything beyond the shared web frontend (routing, capabilities config)? Verify against `desktop/PROGRESS.md`.
