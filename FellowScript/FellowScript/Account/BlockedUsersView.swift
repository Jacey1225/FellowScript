// Guideline 1.2: lists users the account has blocked, with an unblock action.
// Pushed from AccountView's "Privacy & Safety" section.

import SwiftUI

struct BlockedUsersView: View {
    let userId: String
    let service: DataServiceProtocol

    @State private var blocked: [FSBlockedUser] = []
    @State private var isLoading = true
    @State private var unblockingId: String? = nil

    // Test-only hook, ViewInspector's "Approach #2" (Utils/Inspection.swift)
    // -- added for the testing gate's regression coverage of task
    // 20260905-pull-to-refresh-cache-clobber's fix below: proving a failed
    // refresh leaves `blocked` untouched requires observing this view's
    // @State after two real async load() calls (the initial `.task`, then a
    // driven `.refreshable`), which a plain post-host `.inspect()` can't
    // reliably do (mirrors NoteDetailView's identical `inspection` seam and
    // its own doc comment for why). Inert in production: `.onReceive` below
    // is a no-op unless a test registers a callback via
    // `inspection.inspect(...)`. Gated to Debug, matching
    // Inspection.swift/NoteDetailView's own `#if DEBUG` convention.
    #if DEBUG
    internal let inspection = Inspection<Self>()
    #endif

    var body: some View {
        Group {
            if isLoading {
                VStack { Spacer(); ProgressView().tint(Theme.gold); Spacer() }
            } else if blocked.isEmpty {
                VStack(spacing: Theme.spacingMD) {
                    Spacer()
                    Image(systemName: "hand.raised")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(Theme.gold.opacity(0.30))
                    Text("You haven't blocked anyone.")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                }
                .padding()
            } else {
                List(blocked) { user in
                    HStack {
                        Text(user.username.isEmpty ? user.user_id : user.username)
                            .font(.inter(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                        Spacer()
                        if unblockingId == user.user_id {
                            ProgressView().tint(Theme.gold)
                        } else {
                            Button("Unblock") { Task { await unblock(user) } }
                                .font(.inter(Theme.fontSM))
                                .foregroundColor(Theme.gold)
                        }
                    }
                    .listRowBackground(Theme.cardBg)
                }
                .listStyle(.plain)
                // Pull-to-refresh (task 20260831-interaction-polish-conventions):
                // wired to this screen's existing reload method. Passes
                // `showSpinner: false` so an already-populated list isn't
                // replaced by the full-screen spinner branch above mid-refresh
                // (the "no regressions to existing scroll ... behavior"
                // requirement) — SwiftUI's own native `.refreshable` spinner
                // is the only loading affordance shown during a refresh.
                .refreshable {
                    await load(showSpinner: false)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.bgPage)
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        #if DEBUG
        .onReceive(inspection.notice) { self.inspection.visit(self, $0) }
        #endif
    }

    private func load(showSpinner: Bool = true) async {
        if showSpinner { isLoading = true }
        // Bug fix (cache-clobber sweep, task
        // 20260905-pull-to-refresh-cache-clobber): a failed fetchBlockedUsers
        // used to collapse via `try?` to `[]` and get written over the
        // already-displayed list unconditionally, emptying it on any
        // transient fetch failure. Only overwrite on a proven-successful
        // (non-nil) fetch now -- a genuinely empty result (no blocked users)
        // still writes through, since that comes from a real success, not a
        // failure default. Mirrors DashboardViewModel.load()/
        // NotesViewModel.fetchAndCache's identical pattern.
        if let fetched = try? await service.fetchBlockedUsers(userId: userId) {
            blocked = fetched
        }
        if showSpinner { isLoading = false }
    }

    private func unblock(_ user: FSBlockedUser) async {
        unblockingId = user.user_id
        if (try? await service.unblockUser(userId: userId, blockedId: user.user_id)) != nil {
            blocked.removeAll { $0.user_id == user.user_id }
        }
        unblockingId = nil
    }
}
