# Intake spec: 20261030-chat-announcements

## Request
"send announcements into a chat" (Jacey). New feature: a user can post an announcement into a chat. Check what already exists (pipeline 20261020-announcement-title-position-size; reuse and say how it relates). Platforms: iOS, web, Tauri desktop. Hold to the 2026-09-05 restructure principles (throw-not-fabricate, preserve-cache-on-failed-refresh, no growth of oversized files). No push or deploy.

## Summary
Let a user publish an announcement as a first-class entry in a chat's message timeline, so members see it in the flow of conversation rather than only in the Group Info > Announcements list and the chat-header widget. The feature should reuse the existing group-announcements data model, serializer and card rendering and add only a thin "announcement message" layer (message linkage, timeline row, composer entry point).

## Type
Full (backend + iOS + web; desktop inherits web; touches the authorization model and message model).

## What already exists (findings)
- Group announcements are a complete, shipped feature (tasks 20260929-group-announcements through 20261020-announcement-title-position-size, the latter in /Users/jaceysimpson/Vscode/FellowScript/.claude/pipeline/ and not present in this worktree's pipeline dir). Backend: api/routes/group_announcements.py (CRUD, restore, RSVP, polls, banner upload, `/announcements/latest`), api/backend/interactions/announcements.py (AnnouncementsManager, serializer), announcement_notifier.py (group push on create/publish), announcement_repeat / announcement_reminder, table `group_announcements`. Groups only: scoped by `/groups/{user_id}/{group_id}/...`.
- Current permissions: any group MEMBER may create (free-plan limit via check_limit "announcements"); edit/delete/restore only the announcement creator or the group creator (`can_edit`). Soft delete with undo grace window. Optional publish_at scheduling.
- Current surfaces: iOS Chat/GroupAnnouncements*.swift, GroupAnnouncementWidgetView (chat-header card, latest only), Group Info panel list, detail view; web frontend/src/components/AnnouncementCardFace.jsx, GroupAnnouncementWidget/Viewer/Form, GroupAnnouncements.jsx. Desktop (desktop/src-tauri) has no announcement code of its own and loads the web frontend, so it inherits web work (architecture to confirm).
- What is missing: an announcement is NOT a chat message. It appears nowhere in the message timeline (only the header widget showing the latest one, plus a push). Existing chat-adjacent precedent: pins (api/routes/message_pins.py) write a server-generated system line into `messages` with `system_kind` ('pin'), persisted directly without the websocket send path; replies/mentions/reactions also link to `messages`.
- Relation to 20261020-announcement-title-position-size: that task adds optional per-announcement title position/size fields and extends the shared card face (AnnouncementCardFace.jsx, GroupAnnouncementWidgetView, lib/announcementStyle.js). Chat announcements must render through that same card face so they inherit those styles; do not fork a second visual. Check whether that work is merged into this branch (origin/main c01ab7eb) before building; if not, coordinate so the new row consumes whatever card-face API lands.

## Proposed approach (for architecture to confirm or change)
Add a system-line style message (new `system_kind = 'announcement'`, referencing `announcement_id`) emitted when an announcement is published into a group chat; timeline row renders the existing card face (compact) and taps through to the existing detail/viewer. Reuse AnnouncementsManager for content, validation, content filter, banner, polls, RSVP; no second content store. Scheduled announcements post to the chat at publish time (reuse the publish-due push path). Edits update the one announcement record so the chat row reflects them; delete removes/tombstones the row.

## Scope
In:
- Backend: message linkage for announcements (new system_kind + announcement_id column or link table, DDL following api/db.py and api/schema_ddl/ patterns), emission on create/publish, timeline/history serialization (including pagination and live websocket frame), delete/restore sync, tests as plain scripts, docs (api/schema_tree.md, docs/architecture/backend.md, docs/api/overview.md), capability flag defaulting OFF per precedent (e.g. `chat_announcements` in api/schema_ddl/flags.py).
- iOS: timeline row in the chat thread via a NEW small view file (not inline in ChatThreadView.swift 3966 lines or MessageGroupRow.swift 618 lines), decode-tolerant model fields, composer entry point (likely in the + attach chip row or reuse of GroupAnnouncementFormView), tap-through to GroupAnnouncementDetailView.
- Web: timeline row in a new component (ChatThread.jsx is 1815 lines, do not grow it beyond a thin hook-in), composer entry point, tap-through to GroupAnnouncementViewer.
- Desktop: confirm it inherits web; note "no desktop-specific work" if so (also check any Tauri notification/deep-link handling of the push).
Out:
- DMs (see open question 2), new announcement content fields, redesign of the card face, changes to the announcement push content, any push/deploy/server action, touching /Users/jaceysimpson/Vscode/FellowScript.

## Acceptance criteria
- A permitted user can post an announcement from within a group chat on iOS and web (desktop via web) and it appears in the message timeline for all members, live and on history load, in order, with the existing card face and tap-through to the full announcement.
- Content, scheduling, banner, polls and RSVP behave exactly as today because the same record backs it; no duplicate content store.
- Edit reflects in the chat row; delete removes it from the timeline with the existing undo grace window and restore brings it back.
- Non-permitted users and non-members get 403 (deny-by-default); no row appears for blocked/removed members.
- Failed fetch/post surfaces an error (throw, no fabricated placeholder row); a failed timeline refresh keeps the cached messages (preserve-cache-on-failed-refresh).
- No file grows past its limit: new logic lives in new files; NetworkService additions go in the existing announcements extension only; ChatThreadView.swift, ChatThread.jsx and api/main.py get thin hook-ins at most.
- Capability flag OFF by default; old clients that do not know the new system_kind degrade safely (ignore or render the text fallback).
- iOS unit tests, vitest and api tests pass; xcodebuild runs serialized.

## Preference profile
- Security Q2 (secure defaults, deny-by-default): the new post/emit path is authenticated and permission-checked first; start with the most restrictive poster rule.
- Security Q5 (authorization): purpose-built explicit permission check for this feature, no policy framework. Authorization-model changes are permission-required (Architecture Q10), so any widening of who may post goes through Jacey (see open question 1).
- Security Q14 (failure behavior): fail closed when a permission lookup is ambiguous.
- Architecture Q26/Q27 (explicit error checks, propagate errors upward): matches throw-not-fabricate.
- Architecture Q16/Q34 (maintainability over speed), Q18 (design for testability), Q19 (edge cases and failure paths tested), Q23/24 (extension interface proactively).
- UI/UX Q10 (undo-after-the-fact, minimal feedback) for delete/post; Q14 (accessibility first-class, AA floor); Q17 (warm on-brand error tone, plain spinner); Q19 (person-to-person chat uses conventional chat patterns styled through the visual system); Q9 (eased motion, never linear).

## Open questions for Jacey (proposed defaults)
1. Who may post? Today any group member can create an announcement and only creator/group creator can edit. Default proposed: keep current rule (any member may create, free-plan limit applies) for the first version, since changing it is an authorization change; alternative: restrict chat posting to group owner/admins. (Is there a separate admin role beyond group creator? Architecture to check; if not, "owner only" is the only restriction available.)
2. Groups only or DMs too? Default: groups only (announcements are a group concept, table is group-scoped; DM support needs a new scope and recipient model).
3. How does it look? Default: an in-timeline card using the existing announcement card face (banner, title, date, location, RSVP/poll chips) with a small "Announcement" label and the poster, visually distinct from normal bubbles, tap opens the detail. Pinned to the top of the chat? Default: no extra pinning (the header widget already shows the latest); pinning stays the separate Pins feature.
4. Does it notify everyone? Default: yes, reuse the existing announcement group push exactly once (no second push from the chat message); respects per-user notification preferences and mute. The timeline system line itself triggers no chat push, same as pins.
5. Edit/delete: Default: same as today, poster or group creator may edit/delete; delete has the undo grace window; edits update the card in place with no new message and no re-push. Edited marker shown? Default: show a small "edited".
6. Scheduled announcements: Default: row appears in the chat at publish time, not at creation (only the author sees a "scheduled" state in the list as today).
7. Recurring/reminder announcements (announcement_repeat, reminder push): Default: reminders do not add new chat rows; only the original post appears.
8. Existing announcements (already created): Default: no backfill into old chat histories; only announcements published after the flag turns on appear.
9. Entry point: Default: an "Announcement" chip in the + attach row (iOS) and an equivalent composer menu item (web) that opens the existing announcement form; confirm the 20261020 title position/size work is in this branch first.
10. Free-plan gating: Default: posting counts against the existing `announcements` limit, no new limit.

## Gate
(not Lightweight; N/A)
