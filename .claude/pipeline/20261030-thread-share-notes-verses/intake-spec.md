# Intake spec: 20261030-thread-share-notes-verses

## Request
"let users send notes/Bible verses in threads as well" (Jacey). Users can already send notes and Bible verses in chat. Extend so they can also be sent inside threads. Reuse the existing share/attachment path; match the thread composer's current behavior. Platforms: iOS, web and Tauri desktop unless iOS-only today. Hold to the 2026-09-05 restructure principles (throw-not-fabricate, preserve-cache-on-failed-refresh, no growth of oversized files; split instead). No push or deploy.

## Summary
Verse/note sharing ("shared_verse" / "shared_note", flag `chat_shared_objects`, task 20261012-share-verses-notes-in-chat) works today in DMs and group main chat on all three clients but is hard-blocked in threads: the server thread send path rejects the two kinds and the note read endpoint only understands `messages` rows. Extend the server (thread send, thread history, note read grant) and the three clients so a share can land in a thread, reusing the same payload builder, widgets and flag.

## Type
Full (backend + iOS + web/desktop, touches the share-grant/authorization surface).

## Findings on this base (verified)
How sharing works today (it is NOT a composer attach option; it is a "Send in chat" flow):
- Entry points: iOS Bible reader verse menu (`Bible/BibleReaderView.swift` `sendVerseInChat`) and Notes (`Notes/NotesListView+List.swift`); web/desktop Bible reader panel `onShareVerse` and Notes panel `onShareNote`, wired in `frontend/src/pages/Reader.jsx` (`requestVerseShare`, `requestNoteShare`, `performShare`).
- A recipient picker lists friends and groups only (iOS `ShareToChatSheet` in `Chat/SharedObjectViews.swift`; web `components/ShareToChatModal.jsx`). Picking one opens that chat, then sends once history has loaded (iOS `AppState.pendingChatShare` + `consumePendingChatShare()`; web `pendingShareRef` effect in Reader.jsx).
- Wire: the normal chat frame carries `attachment_kind: shared_verse|shared_note` + a minimal request meta (`{book,chapter,verse}` or `{note_id}`), no key. Server (`api/backend/interactions/websockets.py` ~485-625, `api/backend/interactions/shared_objects.py`) validates, rebuilds `attachment_meta` and fallback `text` itself, flag-gated.
- Rendering: iOS `SharedObjectContentView`/`SharedVerseWidget`/`SharedNoteCard` (via `MessageAttachments.swift`); web `components/SharedObjects.jsx` + `lib/sharedObjects.js`. Note open = read-only fetch `GET /shared-objects/{user_id}/note/{message_id}` (`api/routes/shared_objects.py`), whose grant is the row in `messages`.
- Desktop is the same React bundle as web (Tauri `frontendDist ../dist`); no separate desktop code. Not iOS-only.

Why threads fail today:
1. Server: `api/backend/interactions/thread_send.py::_parse_frame` accepts only `schemas.message.ATTACHMENT_KINDS` (image, video, file, gif); shared kinds are rejected as bad_frame -> `not_allowed`. It also requires a key for non-gif kinds, and passes `attachment_meta` through unvalidated (shared meta must be server-built).
2. Server: note read grant (`SharedNoteReader.open_note`) only looks up `messages`; a `thread_messages` row has no grant, so a shared note in a thread would show "unavailable".
3. Server: thread history serialization (`api/backend/interactions/threads.py` ~313-353) does not apply `clean_shared_note_meta` (DM/group history does). Mentions validation (`message_mentions.validate`) already treats shared kinds specially.
4. iOS: `consumePendingChatShare()` explicitly requires `!vm.isThreadOpen`; the picker has no thread destinations. The thread send frame in `sendMessage` (`activeThread != nil`) already carries attachment kind/meta, `shared` payload and local echo, so the iOS send plumbing is mostly reusable.
5. Web: picker/`performShare` only target contacts; `sendMessage` with `threadViewRef` set already forwards attachment kind/meta in the `thread_message` frame (`useMessaging.js` ~603-620, 907+). Rendering in threads uses the same `ChatThread.jsx` bubble code (`isSharedKind`), so display likely works once the server delivers it. Note-open in a thread needs the thread-aware grant (item 2).

## Scope
In:
- Backend: allow `shared_verse`/`shared_note` in `thread_send` by reusing `shared_objects.resolve_share` (server rebuilds meta and fallback text, same `chat_shared_objects` flag, same uniform `not_allowed`/`send_failed` denials, fail-closed). Apply `clean_shared_note_meta` on thread history. Thread-aware note read grant (viewer must be a live member of the thread's group, no block pair with sender, thread message not soft-deleted, sender still allowed to share the note; one uniform 404). Push/live frame use the fallback text like chat.
- iOS: thread destination for "Send in chat"; allow the pending share to be consumed inside an open thread; existing retry/failed-send/local-echo flow reused; render shared cards in thread bubbles; note open from a thread bubble.
- Web + Tauri desktop (same bundle): same destination choice and send path; render and note-open in thread view.
- Tests per layer (pytest for server incl. denial matrix; Swift unit tests; vitest) and docs update where the share feature is documented.
- File-size hygiene: ChatThreadView.swift (3966 lines), ChatThread.jsx (1815), useMessaging.js (1508), Reader.jsx (598) must not grow; put new logic in new files (e.g. `ChatThreadView+Share.swift`, `lib/threadShare.js`, a new `api/backend/interactions/thread_shared_objects.py` for the thread read grant) and leave only thin call sites.
Out:
- Any new composer "+" attach chip for notes/verses in either chat or thread (not how sharing works today); new share entry points; reactions/pins/replies/mentions on shares in threads (threads have none of those today and shares never carry mentions); sharing other object types; schema migration (columns already exist on `thread_messages`); push, deploy, server pull/restart; anything in /Users/jaceysimpson/Vscode/FellowScript.

## Acceptance criteria
- With `threads` and `chat_shared_objects` both on for the sender, a verse or note chosen via "Send in chat" can be delivered into a chosen existing thread on iOS, web and desktop; recipients (live, and on history load) see the same verse widget / note card as in chat; offline followers get push with the fallback line.
- Server never trusts client meta: stored thread `attachment_meta` and `text` are built by `resolve_share`; a forged meta, unowned/private note, invalid reference, non-member, suspended user, block pair, flag off, or unknown thread each yields the uniform denial and stores nothing. Message with a shared kind and an `attachment_key` is rejected.
- Tapping a shared note in a thread opens it read-only for a current group member; fails with the single "unavailable" outcome for non-members, deleted thread messages, removed/now-private notes (grant re-checked at read time).
- Failed send in a thread: pending bubble marked failed, retry works, nothing fabricated (throw-not-fabricate). A failed history/refresh keeps the existing cached thread messages (preserve-cache-on-failed-refresh).
- Plain-text and existing attachment sends in threads and all chat-level shares behave unchanged; old clients see the fallback text line in a thread.
- No oversized file gains lines; all new tests pass; backend, Swift (serialized simulator run), and vitest suites green. Nothing pushed or deployed.

## Preference profile
- Security Posture Q2/Q3/Q5/Q14/Q15: deny-by-default, fail-closed, explicit threat model, purpose-built explicit permission checks (no generic framework). This change widens a note read grant to a new table and is a sensitive-area feature: dedicated security self-review pass is mandatory. It does NOT change the permission model rules (same `sender_may_share_note` + membership rule), so no hard stop is expected; if a gate finds it must alter the rule itself, stop and ask (Security Q16 hard-stop list: authorization/permission model changes).
- Security Q7: validation is defense-in-depth for sensitive paths (server rebuild of meta, not boundary-only).
- Security Q13: logs carry ids only, no note text.
- Architecture/Implementation: prefer reuse of the proven shared path over a parallel mechanism; extensibility is welcome but do not invent a new share framework.
- UI/UX: no new visual design; reuse approved widget/card styling (design-approval from the original task). Any new thread-destination row in the picker is minimal/unfussy per Q17, on-brand, WCAG AA, reduced-motion respected. Propose rather than silently build a larger picker redesign (Creative-process answers).
- Project-level (memory): hold the 2026-09-05 restructure principles; iOS simulator test runs must serialize across tasks.

## Open questions (proposed defaults)
1. Destination UX. Today sharing is a picker of friends/groups, not an in-composer attach. Proposed default: keep the picker, and under each group that has threads add an expandable/secondary "Threads" list (reusing the existing threads list fetch) so the user can pick a thread; additionally, when the user is already inside an open thread, "Send in chat" from Bible/Notes is NOT possible (those screens are separate), so no composer entry is added. Alternative if Jacey actually wants a "+ Verse / + Note" option inside the thread composer: that is a new in-composer picker on all three clients and a materially larger scope. Which does he mean?
2. Which threads appear in the picker: all threads in groups the user is in, or only ones the user follows / recent? Default: recent threads (cap, e.g. 10 by last_activity_at) per group, same ordering as the group threads list.
3. Thread messages have no reply/mention/reaction support; shares in threads follow that. Default: no mention data on a share (same as chat).
4. Note-grant for thread shares: viewer must be a live member of the thread's group (same visibility as the thread itself). Default confirmed unless Jacey wants thread shares of group notes limited further.
5. Feature flag: reuse `chat_shared_objects` + `threads` (both must be on) rather than a new flag. Default: reuse; no new capability key, old clients simply do not show the thread destination and show fallback text.
6. Sending while the target thread is currently open vs. not: default is open the thread, wait for its first page, then send once (mirrors the chat pending-share rule so history load cannot wipe the optimistic bubble).
