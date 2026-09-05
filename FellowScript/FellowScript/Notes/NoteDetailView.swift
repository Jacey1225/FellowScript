// NoteDetailView.swift — the note-detail read sheet (Direction B restyle:
// warm-bloom background, gradient Edit / ghost Close pills), including its
// group-note-only replies section (load, post, edit, card rendering).
// Already an independent view struct inside the former NotesListView.swift
// monolith -- split out into its own file (readability #6, 20260904-
// frontend-arch-sweep) -- same type, same behavior, no interface change.
// See NotesListView.swift's header comment for the full split rationale and
// the list of sibling files.

import SwiftUI

// ── Note detail sheet ─────────────────────────────────────────────────────────
// Direction B ("Elevated CTA, lighter chrome") of the approved restyle —
// see .claude/pipeline/20260813-note-viewer-mockups/design-notes.md. Adopts
// the warm-bloom background for family resemblance with NoteEditorView/
// ChatRootView/Dashboard, but intentionally skips the glass-card body
// wrapper (this is read-only content — a long note's reading column stays
// full width) and promotes Edit to a solid gradient CTA pill against a
// secondary ghost-outline Close, mirroring AccountView's pill hierarchy.
struct NoteDetailView: View {
    let note:   FSNote

    // ── Reply data-layer wiring (task 20260828-note-reply-continuation-ios) ──
    // Defaulted (not required) so every existing call site/test that only
    // supplies note+onSave keeps compiling unchanged — in particular
    // NoteDetailViewDirectionBTests, which hosts this view directly via
    // ViewHosting with no AppState in the environment. Deliberately plain
    // stored properties rather than @EnvironmentObject var appState: AppState
    // for the same reason, mirroring the existing
    // BlockedUsersView(userId:service:) pattern instead. The real call site
    // (NotesListView's `.sheet(item: $detailNote)`) passes all three from its
    // own `appState`. Declared before `onSave` below (not after) so that
    // trailing-closure call sites -- both the pre-existing
    // `NoteDetailView(note: note) { ... }` and the new
    // `NoteDetailView(note:userId:username:service:) { ... }` -- resolve the
    // trailing closure to `onSave` correctly: it stays the last
    // non-defaulted (required) stored property in the synthesized init.
    var userId:   String              = ""
    var username: String              = ""
    var service:  DataServiceProtocol = MockDataService.shared

    // Returns nil on success, or an error message on failure (mirrors
    // NoteEditorView.onSave so a content-filter rejection keeps both sheets open).
    let onSave: (FSNote) async -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Not `private` (unlike NoteEditorView's analogous @State vars) so
    // FellowScriptTests can assert on it directly after simulating an Edit
    // tap via ViewInspector — see NoteDetailViewDirectionBTests.swift. No
    // runtime behavior difference; access-control only.
    @State var showEditor = false

    // Toolbar button actions, extracted to named methods (task
    // 20260829-note-detail-toolbar-visual-fix) rather than inline closures.
    // Not `private`, for the same reason `showEditor` above isn't: this
    // toolbar's `ToolbarItem`s now carry `.suppressAutomaticGlassChrome()`
    // (task 20260902-ios-deployment-target-lower's iOS-26-only-gated wrapper
    // around what was `.sharedBackgroundVisibility(.hidden)` directly — the
    // fix for the doubled system/custom pill outline), and ViewInspector
    // 0.10.3 cannot traverse a `ToolbarItem` wrapped in that modifier down to
    // its `Button` (confirmed live — it reports an opaque
    // `ModifiedContent<ToolbarItem, PlatterVisibilityModifier>` it doesn't
    // know how to unwrap, for both `.toolbar().item(_)` and a plain
    // `find(button:)`). Exposing the exact same action closures the buttons
    // call lets tests still exercise the real dismiss()/showEditor wiring
    // without simulating a tap through that now-unreachable wrapper. No
    // runtime behavior difference from the previous inline closures.
    internal func closeAction() { dismiss() }
    internal func editAction()  { showEditor = true }

    // Gates the toolbar Edit pill (task 20260829-notes-edit-author-gate,
    // extended by 20260903-notes-public-repurpose step 5): this view
    // previously showed Edit unconditionally, despite already having both
    // `note.username` (the author, used by NoteRow's showsAuthorChip) and
    // `username` (the viewer, passed in from the call site) available to
    // compare. A group note is editable by its author, OR by any group
    // member (mirroring the server's update_note non-owner branch) when the
    // note's own `public` flag grants group-edit permission; a personal note
    // (no group_id) needs no check — always self-authored already.
    // Deny-by-default: an empty/undecoded `note.username` or `username` for
    // a group note hides Edit rather than assuming authorship, mirroring
    // NoteRow.showsAuthorChip's same fallback -- the public-flag branch below
    // is purely additive on top of that, never a way around it.
    internal var canEdit: Bool {
        guard !note.group_id.isEmpty else { return true }
        if note.public { return true }
        guard !note.username.isEmpty, !username.isEmpty else { return false }
        return note.username == username
    }

    // Task 20260905-profile-photo: mirrors NoteRow.showsAuthorChip's own
    // deny-by-default posture -- an author-less note (empty `username`, the
    // common case: only the single-note-fetch and reply paths ever resolve
    // it) or a note authored by the viewer themself shows no chip at all,
    // never a placeholder or a redundant "you" label.
    internal var showsParentAuthorChip: Bool {
        !note.username.isEmpty && note.username != username
    }

    // Per-reply Edit gate (task 20260904-reply-edit-button), corrected by the
    // security gate's 2026-09-04 review: a reply must always be private for
    // editing purposes, regardless of the parent note's/group's edit
    // permissions -- unlike `canEdit` above (which does have a legitimate
    // owner-or-group-edit-permission branch via `public`), a reply's own
    // `public`/`group_id` must never grant a non-author group member edit
    // access. This is now author-match-only: no group_id fail-open branch,
    // no public-flag exception. Deny-by-default/fail-closed: an
    // empty/undecoded username on either side hides Edit rather than
    // assuming authorship -- unlike the parent note's case, an unresolved
    // group_id/username here is never safe to read as "personal note,
    // always self-authored," since a reply only ever exists on a group note
    // in this app's model.
    private func canEdit(_ reply: FSNote) -> Bool {
        guard !reply.username.isEmpty, !username.isEmpty else { return false }
        return reply.username == username
    }

    // ── Reply section state ───────────────────────────────────────────────
    // Group notes only (mid-task product-intent correction, task
    // 20260828-note-reply-continuation-ios): replies are a group-note-only
    // feature, not a personal-notes one, despite backend step 1 having added
    // a personal-notes GET-replies route and NetworkService.fetchReplies
    // being able to call it -- NoteDetailView itself never invokes that
    // branch (isGroupNote guards both the fetch and the render below).
    private var isGroupNote: Bool { !note.group_id.isEmpty }
    @State private var replies:            [FSNote] = []
    // True once a load attempt has actually completed (success or failure)
    // for a group note -- gates the whole section so it never flashes
    // "REPLIES · 0" or stale content before the fetch resolves. Stays false
    // forever for a personal note, which is fine: isGroupNote already gates
    // the section before repliesLoaded is even consulted.
    @State private var repliesLoaded       = false
    @State private var showAllReplies      = false
    @State private var showReplyComposer   = false
    // Which reply (if any) is currently open in the shared NoteEditorView
    // (task 20260904-reply-edit-button). `.sheet(item:)` rather than a
    // second `showEditor`-style Bool + separately-tracked FSNote? pair --
    // this view already has exactly one thing being edited at a time
    // (either the parent note via `showEditor`, or one reply via this),
    // and `.sheet(item:)` gives that "one reply, or none" invariant for
    // free instead of needing a second bool kept in sync by hand.
    @State private var editingReply:       FSNote?  = nil

    private var displayedReplies: [FSNote] {
        showAllReplies ? replies : Array(replies.prefix(5))
    }

    // Test-only hook (ViewInspector's documented minimal-intrusion pattern
    // for inspecting @State after an interaction — never set outside
    // NoteDetailViewDirectionBTests.swift; inert in production since nothing
    // assigns it). No behavior change: `.onAppear` below is a no-op unless a
    // test supplies a closure.
    internal var didAppear: ((Self) -> Void)?

    // Test-only hook, ViewInspector's "Approach #2" (Inspection.swift) —
    // added for task 20260828-note-reply-continuation-ios, testing step,
    // since `didAppear` above only fires once at `.onAppear`, before the
    // async `.task(id:)` reply fetch below has had a chance to resolve.
    // `sut.inspection.inspect(after:)` lets tests observe the view after a
    // real time gap once `replies`/`repliesLoaded` have actually settled.
    // Inert in production: `.onReceive` below is a no-op unless a test
    // registers a callback via `inspection.inspect(...)`.
    // Gated to Debug (task 20260902-ios-deployment-target-lower), matching
    // Inspection.swift's own `#if DEBUG` — see that file for why (test-only
    // scaffolding that also happens to trigger a Release/WMO compiler crash
    // at the lowered 18.0 deployment target). Tests build against Debug, so
    // this is a no-op change for FellowScriptTests/FellowScriptUITests.
    #if DEBUG
    internal let inspection = Inspection<Self>()
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                // Warm bloom ground (shared visual language with Dashboard/
                // Chat/Notes/NoteEditorView) — identical hex/opacity/anchor/
                // radius to ChatRootView.swift:41-46 / NoteEditorView.swift:82-87.
                RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                               center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                    .ignoresSafeArea()
                RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                               center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                    .ignoresSafeArea()

                ScrollView {
                    // No glassCard wrapper (per Direction B) — body flows
                    // directly on the bloom background, full width, same
                    // structure as before, just re-themed.
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        Text(note.title.isEmpty ? "Untitled" : note.title)
                            .font(.playfair(Theme.fontDisplayMD))
                            .foregroundColor(Theme.parchment)

                        // Task 20260905-profile-photo: author indicator for
                        // a note opened that wasn't authored by the viewer
                        // (today, only reachable via the Friend Activity
                        // note-preview flow -- DashboardView.openFriendNote
                        // -> GET /notes/{user_id}/note/{note_id}, the one
                        // note-fetch path that resolves both `username` and
                        // `profile_photo_url` server-side). A viewer's own
                        // note (the far more common case) never shows this --
                        // same "no chip for yourself" convention as NoteRow's
                        // showsAuthorChip.
                        if showsParentAuthorChip {
                            HStack(spacing: 8) {
                                replyMonogram(note.username, photoURL: note.profile_photo_url)
                                Text(note.username)
                                    .font(.interScaled(Theme.fontSM, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                            }
                        }

                        if !note.formattedTimestamp.isEmpty {
                            sectionLabel(note.formattedTimestamp)
                        }

                        Rectangle()
                            .fill(Theme.goldGradient)
                            .frame(height: 1)

                        NoteHTMLView(html: note.text)

                        // ── Replies (Option A "Continuation" — task
                        // 20260828-note-reply-continuation-ios). Group notes
                        // only, per mid-task product-intent correction: a
                        // personal note (group_id empty) renders exactly as
                        // it did before this task, no fetch, no section.
                        // Also gated on repliesLoaded so a still-in-flight
                        // fetch never flashes "REPLIES · 0" -- an
                        // unresolved/absent state behaves like the empty
                        // state, and neither branch below renders before
                        // repliesLoaded is true. Reply UI is earned by
                        // content, never rendered speculatively.
                        //
                        // Zero-replies empty state (task
                        // 20260829-notes-first-reply-empty-state): the prior
                        // task's own gating made a zero-reply group note
                        // render nothing at all below the note body -- no
                        // way to start the first reply, despite the backend
                        // write path already handling that case fine. The
                        // hairline/label/card-list/"See all" machinery below
                        // stays gated on !replies.isEmpty exactly as before
                        // (still correctly earned-by-content), but the
                        // composer entry point itself is no longer inside
                        // that same gate -- it now always renders once a
                        // group note's replies have loaded, with a minimal
                        // muted line standing in for the earned content when
                        // there isn't any yet. Per the UI/UX preference
                        // profile's empty-state guidance (minimal, not
                        // illustrated), this reuses ghostPill/
                        // showReplyComposer/postReplyDraft verbatim rather
                        // than introducing anything new.
                        if isGroupNote && repliesLoaded {
                            if !replies.isEmpty {
                                Rectangle()
                                    .fill(Theme.goldGradient)
                                    .frame(height: 1)

                                repliesSectionLabel(replies.count)

                                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                                    ForEach(displayedReplies) { reply in
                                        replyCard(reply)
                                    }
                                }

                                if replies.count > 5 && !showAllReplies {
                                    Button { showAllReplies = true } label: {
                                        ghostPill("See all \(replies.count)")
                                            .frame(minHeight: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                Text("No replies yet.")
                                    .font(.inter(Theme.fontSM))
                                    .foregroundColor(Theme.textMuted)
                            }

                            // Composer affordance is likewise group-notes-only
                            // -- POST /notes/reply/{note_id} technically
                            // already accepts replies to personal notes
                            // (pre-existing backend behavior, unrelated to
                            // this task), but this UI never newly exposes
                            // that path. Reachable in both the populated and
                            // zero-reply branches above.
                            Button { showReplyComposer = true } label: {
                                ghostPill("Add a reply")
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Theme.spacingLG)
                }
                // Content-edge feather (task
                // 20260830-note-detail-scroll-fade-toolbar-bg): the user's
                // actual ask, corrected from the prior
                // 20260829-note-detail-toolbar-edge-blur task, which feathered
                // the TOOLBAR's own background instead -- the real hard,
                // ruler-straight cutoff (IMG_3048.png, attached to this
                // request) is the note title/body's own scrolling content
                // disappearing abruptly as it passes under the nav bar.
                // `.mask` is applied to the ScrollView itself (not to content
                // inside it), so the gradient is anchored to the ScrollView's
                // fixed on-screen frame rather than scrolling with the
                // content -- that's what makes text sliding toward the top
                // fade out smoothly instead of hitting a hard clip edge.
                // Fixed 120pt height (nav bar ~44pt + top safe-area/Dynamic
                // Island inset, generously covering both across device
                // sizes) rather than a GeometryReader-derived
                // `safeAreaInsets.top` -- mask content isn't reliably in the
                // same safe-area context as the view it masks, so a
                // hand-picked constant is the more predictable, purpose-fit
                // choice here (Q12 component philosophy: custom over
                // reaching for a generic/derived mechanism whose behavior
                // isn't verified). Fades to fully transparent well before the
                // Close/Edit pills' row, which is also what makes the toolbar
                // background removal below safe: there's no legible text
                // left to visually collide with the pills by the time
                // content is that close to the top, replacing the old
                // toolbar-tint gradient's collision-guard duty without
                // needing a separate non-visible guard.
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.55), location: 0.55),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 120)
                        Color.black
                    }
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // .sharedBackgroundVisibility(.hidden) (task
                // 20260829-note-detail-toolbar-visual-fix): confirmed live
                // (Simulator screenshot) that iOS 26 wraps each ToolbarItem's
                // content in its own automatic Liquid Glass capsule chrome
                // -- including its own border -- layered on top of whatever
                // the item draws, regardless of `.buttonStyle(.plain)`
                // (already applied below). That produced a visibly doubled
                // outline on both pills: the system's automatic glass
                // capsule stroke plus ghostPill/gradientPill's own deliberate
                // stroke. Per this app's established "build custom, don't
                // skin a system primitive" component philosophy, this hides
                // the automatic glass background instead of stripping the
                // app's own pill stroke -- same technique NoteEditorView's
                // analogous cancelChip/doneChip sidestep by simply never
                // living inside a ToolbarItem at all.
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: closeAction) {
                        ghostPill("Close", compact: true)
                    }
                    .buttonStyle(.plain)
                }
                .suppressAutomaticGlassChrome()
                if canEdit {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: editAction) {
                            gradientPill("Edit", compact: true)
                        }
                        .buttonStyle(.plain)
                    }
                    .suppressAutomaticGlassChrome()
                }
            }
            // R1 (critique polish, task 20260828-note-reply-continuation-ios),
            // corrected by task 20260829-note-detail-toolbar-visual-fix,
            // feathered by task 20260829-note-detail-toolbar-edge-blur,
            // removed outright by task
            // 20260830-note-detail-scroll-fade-toolbar-bg: NoteDetailView had
            // no scroll-edge treatment at all before R1, so long-note body
            // text could visibly scroll under/collide with the Close/Edit
            // toolbar pills. Through R1 and the two 08-29 tasks, the fix was
            // always some flavor of a visible tint/gradient painted behind
            // the toolbar via `.toolbarBackground` -- first plain
            // `.ultraThinMaterial` (rejected live for compositing as a flat
            // neutral-gray band against this screen's warm amber-bloom
            // background), then a flat warm tint, then a top-opaque/
            // bottom-clear gradient version of that same tint. All three
            // versions produced a visible, distinct band behind the
            // Close/Edit pills, which is exactly what this task's request
            // asked to remove entirely -- "no distinct visible background
            // band at all," pills reading as sitting directly on the bloom.
            //
            // That's safe now because the anti-scroll-collision duty this
            // background always also carried has moved to a different
            // mechanism: the `.mask` feather on the ScrollView above (see
            // its comment) fades note content to fully transparent well
            // before it reaches the pills' row, so there's no legible text
            // left for the pills to visually collide with by the time
            // content is that close to the top -- no separate non-visible
            // guard (inset, reduced-opacity scrim, etc.) is needed alongside
            // it. Confirmed by direct source read that `.toolbarBackground`
            // and `.sharedBackgroundVisibility(.hidden)` (on both
            // `ToolbarItem`s below) are unrelated, independent modifiers --
            // hiding this background has no bearing on the doubled-outline
            // fix; that fix stays exactly as `20260829-note-detail-toolbar-visual-fix`
            // left it.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // Editor sheet lives here — note is a guaranteed let constant,
            // so NoteEditorView always receives the correct content.
            .sheet(isPresented: $showEditor) {
                NoteEditorView(
                    note:       note,
                    noteId:     note.id,
                    groupId:    note.group_id,
                    isReadOnly: false
                ) { saved in
                    let msg = await onSave(saved)
                    if msg == nil { dismiss() }
                    return msg
                }
                // Root cause of the Save/Cancel overlap regression (task
                // 20260810-note-editor-save-cancel-overlap-v2), confirmed via
                // a screenshot captured mid-investigation: a sheet presented
                // from a view that is itself already inside a sheet (this
                // "sheet-on-a-sheet" path, as opposed to NotesListView's own
                // direct, single-level .sheet) can genuinely — at the real
                // UIKit level, not just a SwiftUI layout-proposal quirk —
                // adopt a small, centered "form sheet" compact-adaptation
                // presentation instead of the normal near-full-screen "page
                // sheet" style, racy across launches. .presentationDetents
                // alone (kept below) did not reliably prevent this — .large
                // only controls which DETENT a resizable sheet rests at, not
                // which ADAPTATION style is used when the presentation
                // context is compact/nested, which is the actual thing
                // going wrong here. .presentationCompactAdaptation(.fullScreenCover)
                // explicitly overrides that adaptation so the nested sheet
                // always renders full-screen, matching the direct
                // (non-nested) sheet's behavior instead of racily falling
                // back to a small form-sheet card.
                .presentationDetents([.large])
                .presentationCompactAdaptation(.fullScreenCover)
            }
            .sheet(isPresented: $showReplyComposer) {
                ReplyComposerSheet(onPost: postReplyDraft)
            }
            // Reply Edit sheet (task 20260904-reply-edit-button): same
            // NoteEditorView/flow the parent note's own Edit uses above --
            // `note`/`noteId` are the tapped reply's, not the parent note's,
            // so NoteEditorView.handleSave stamps `saved.id` with the
            // reply's real row id (surfaced by backend step 1) rather than
            // the parent note's. Deliberately calls `service.saveNote(...)`
            // directly instead of reusing this view's own `onSave` closure:
            // that closure ultimately forwards through
            // NotesViewModel.saveNote, which also writes the saved note into
            // `vm.notes[savedId]` -- correct for the parent-note case (that
            // dict backs the main Notes list this note already belongs to),
            // but wrong for a reply, which would then wrongly appear as a
            // top-level note in that list. Calling the same underlying
            // `PUT /notes/{userId}?note_id=` endpoint directly (no new
            // endpoint) and updating only this view's own `replies` array on
            // success keeps a reply edit confined to reply state, per the
            // "editing a reply never mutates the parent note's row" /
            // no-full-reload acceptance criteria -- and surfaces a
            // save failure as the same inline error NoteEditorView already
            // shows for the parent note's edit flow, per the
            // don't-silently-substitute convention.
            .sheet(item: $editingReply) { reply in
                NoteEditorView(
                    note:       reply,
                    noteId:     reply.id,
                    groupId:    note.group_id,
                    isReadOnly: false
                ) { saved in
                    do {
                        _ = try await service.saveNote(saved, editingId: saved.id, userId: userId)
                        if let idx = replies.firstIndex(where: { $0.id == saved.id }) {
                            replies[idx] = saved
                        }
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
                .presentationDetents([.large])
                .presentationCompactAdaptation(.fullScreenCover)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { didAppear?(self) }
        // Group notes only -- see isGroupNote. `.task(id:)` re-fires if the
        // sheet is ever re-hosted for a different note (item-presented
        // sheets already tear down/rebuild per note, but id: is a cheap,
        // correct guard either way) and is a no-op for a personal note.
        .task(id: note.id) {
            await loadReplies()
        }
        #if DEBUG
        .onReceive(inspection.notice) { self.inspection.visit(self, $0) }
        #endif
    }

    // ── Replies: data ──────────────────────────────────────────────────────
    private func loadReplies() async {
        guard isGroupNote, !userId.isEmpty else { repliesLoaded = false; return }
        let fetched = (try? await service.fetchReplies(
            userId: userId, noteId: note.id, groupId: note.group_id)) ?? []
        replies = fetched
        repliesLoaded = true
    }

    /// Posts via the existing `POST /notes/reply/{note_id}` route (wired in
    /// step 2) and appends the returned id locally rather than refetching --
    /// the same optimistic id-swap pattern `NotesViewModel.saveNote` already
    /// uses for the main note save round-trip. Returns nil on success, or an
    /// error message the composer sheet shows inline (mirrors onSave above).
    private func postReplyDraft(_ text: String) async -> String? {
        guard isGroupNote, !userId.isEmpty else {
            return "Replies aren't available for this note."
        }
        var draft = FSNote()
        draft.user     = userId
        draft.username = username
        draft.text     = text
        draft.group_id = note.group_id
        draft.is_reply = true
        do {
            let id = try await service.postReply(draft, noteId: note.id)
            draft.id = id
            draft.timestamp = ISO8601DateFormatter().string(from: Date())
            replies.append(draft)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // ── Replies: section label ─────────────────────────────────────────────
    // Distinct from the shared top-level `sectionLabel(_:)` (DashboardView.swift)
    // used for the date eyebrow above -- the design spec calls for a heavier
    // weight/larger size/brighter color for this one (SemiBold 12pt, tracking
    // ~1.2, full-opacity textGold) rather than reusing that helper's XXS/
    // tracking-5/textGoldMuted styling verbatim.
    private func repliesSectionLabel(_ count: Int) -> some View {
        Text("REPLIES · \(count)")
            .font(.inter(Theme.fontXS, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundColor(Theme.textGold)
    }

    // ── Replies: card ───────────────────────────────────────────────────────
    private func replyCard(_ reply: FSNote) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            if !reply.username.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    replyMonogram(reply.username, photoURL: reply.profile_photo_url)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(reply.username)
                            .font(.interScaled(Theme.fontSM, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        if !reply.formattedTimestamp.isEmpty {
                            Text("·")
                                .font(.interScaled(Theme.fontXS))
                                .foregroundColor(Theme.textGold.opacity(0.5))
                            Text(reply.formattedTimestamp)
                                .font(.interScaled(Theme.fontXS))
                                .foregroundColor(Theme.textGold)
                        }
                    }
                }
            } else if !reply.formattedTimestamp.isEmpty {
                // Author-less reply (username empty) -- a real, documented
                // state (Models.swift:183-189), not hypothetical: omit the
                // monogram + name entirely and show only the timestamp.
                Text(reply.formattedTimestamp)
                    .font(.interScaled(Theme.fontXS))
                    .foregroundColor(Theme.textGold)
            }

            // R3 (critique polish): real inter-paragraph spacing via
            // Theme.spacingSM between paragraph Text views (this VStack's
            // uniform spacing), rather than one dense block with zero gap
            // between paragraphs.
            ForEach(Array(replyParagraphs(reply.text).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.interScaled(Theme.fontBody))
                    .foregroundColor(Theme.textPrimary)
                    .lineSpacing(7)   // ~1.45 line-height at a 16pt base size
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetCard(padding: Theme.spacingMD)
        // Per-reply Edit pill (task 20260904-reply-edit-button), top-right of
        // the card per spec, reusing the exact gradientPill/editAction idiom
        // already used for the parent note's own toolbar Edit pill above --
        // no new button style. `.overlay(alignment:)` rather than folding
        // this into the header HStack: the header's own layout already
        // branches on whether `reply.username` is empty, and this needs to
        // sit top-right regardless of which of those branches rendered.
        // Deny-by-default: hidden entirely (not shown disabled) when
        // `canEdit(reply)` is false, mirroring the parent toolbar's own
        // `if canEdit` gating just above.
        .overlay(alignment: .topTrailing) {
            if canEdit(reply) {
                Button {
                    editingReply = reply
                } label: {
                    gradientPill("Edit", compact: true)
                }
                .buttonStyle(.plain)
                .padding(Theme.spacingMD)
            }
        }
    }

    // Task 20260905-profile-photo: `photoURL` layers over the existing gold-
    // gradient monogram exactly like MessageGroupRow's/AccountView's own
    // avatar treatments -- a missing/loading/failed photo just shows the
    // monogram underneath, never a broken image. NetworkService.fetchReplies
    // resolves this via the same per-author `fetchUser` call it already
    // makes to resolve `username` (no extra network cost); a personal-notes/
    // group-notes-list author (which never carries a photo on the wire
    // today, unlike a single fetched note or a reply) simply renders nil
    // here and falls back to the monogram, same as it always has.
    private func replyMonogram(_ username: String, photoURL: String? = nil) -> some View {
        ZStack {
            Circle()
                .fill(Theme.goldGradient)
            Text(String(username.prefix(1)).uppercased())
                .font(.inter(Theme.fontSM, weight: .bold))
                .foregroundColor(Color(hex: "#24170A"))
            if let photoURL, !photoURL.isEmpty, let url = URL(string: photoURL) {
                AsyncImage(url: url, transaction: Transaction(animation: reduceMotion ? nil : .easeIn(duration: 0.25))) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(width: 28, height: 28)
    }

    /// Splits reply body text into paragraphs (critique R3). Reply cards use
    /// Inter sans-serif per the design spec, not NoteHTMLView (which forces
    /// serif Lora at 19px), so this does its own light HTML-paragraph-aware
    /// split rather than routing through that view: `</p>`/`<br>`-family tags
    /// (present if a reply was composed with rich formatting elsewhere in the
    /// app) become paragraph breaks, any remaining tags are stripped, and
    /// blank paragraphs are dropped. Plain text with no tags at all just
    /// falls through as a single paragraph, unchanged.
    private func replyParagraphs(_ text: String) -> [String] {
        var normalized = text
        for tag in ["</p>", "<br>", "<br/>", "<br />", "</div>"] {
            normalized = normalized.replacingOccurrences(of: tag, with: "\n\n", options: .caseInsensitive)
        }
        normalized = normalized.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.isEmpty
            ? [text.trimmingCharacters(in: .whitespacesAndNewlines)]
            : paragraphs
    }

    // ── Pill controls (AccountView idiom — AccountView.swift —
    // reused as local view-scoped helpers here since those are `internal`
    // instance methods on AccountView itself, the same pattern NoteEditorView
    // already follows for its own cancelChip/doneChip icon-chip helpers) ────
    private func gradientPill(_ title: String, compact: Bool = false) -> some View {
        Text(title)
            .font(.inter(compact ? Theme.fontXS : Theme.fontSM, weight: .semibold))
            .foregroundColor(Color(hex: "#24170A"))
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? 32 : 36)
            .background(
                LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Capsule())
    }

    private func ghostPill(_ title: String, compact: Bool = false,
                            labelColor: Color = Theme.textSecondary,
                            strokeColor: Color = Theme.parchment.opacity(0.14)) -> some View {
        Text(title)
            .font(.inter(compact ? Theme.fontXS : Theme.fontSM))
            .foregroundColor(labelColor)
            // The leading toolbar slot proposes a very narrow width on iOS
            // 26 (as if sizing for a single icon), which without this wraps
            // "Close" letter-by-letter and truncates it. fixedSize forces
            // the text to report/keep its natural single-line width instead
            // of accepting that narrow proposal.
            .fixedSize()
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 32 : 36)
            // Explicit (near-invisible) fill, not just a stroke overlay —
            // AccountView's original ghostPill is stroke-only, which is fine
            // in normal body content but collapses to a circular icon slot
            // when used as toolbar item content on iOS 26: without an opaque
            // background shape, the toolbar's Liquid Glass layout has no
            // real width to size against and truncates the label.
            .background(Capsule().fill(Theme.parchment.opacity(0.04)))
            .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
    }
}
