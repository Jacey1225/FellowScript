// ShareToChatSheet+Threads.swift — the optional "Threads" disclosure under a
// group in the "Send in chat" picker (task 20261030-thread-share-notes-verses).
//
// A minimal secondary list: the group's most recent threads (cap 10, newest
// activity first, from the existing threads list fetch). Shown only when both
// `threads` and `chat_shared_objects` are on. A failed load shows an inline
// retry and never an empty list (throw-not-fabricate).

import SwiftUI
import Combine

@MainActor
final class ShareThreadsViewModel: ObservableObject {
    static let cap = 10

    @Published private(set) var threads: [FSThreadSummary] = []
    @Published private(set) var loaded = false
    @Published private(set) var failed = false
    @Published private(set) var isLoading = false

    private let service: DataServiceProtocol
    private let groupId: String
    private let userId: String

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        self.service = service
        self.groupId = groupId
        self.userId = userId
    }

    /// Newest activity first, capped. Pure, so it is unit-testable.
    static func recent(_ rows: [FSThreadSummary]) -> [FSThreadSummary] {
        Array(rows.sorted { $0.lastActivityAt > $1.lastActivityAt }.prefix(cap))
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.fetchThreads(userId: userId, groupId: groupId, limit: Self.cap,
                                                      cursorTimestamp: nil, cursorId: nil)
            threads = Self.recent(page.threads)
            loaded = true
            failed = false
        } catch {
            print("[ShareThreadsViewModel] load failed: \(error)")
            failed = true   // keep any rows already shown
        }
    }
}

struct ShareGroupThreadsRows: View {
    let group: FSContact
    let service: DataServiceProtocol
    let userId: String
    let onPick: (FSThreadSummary) -> Void

    @StateObject private var vm: ShareThreadsViewModel
    @State private var expanded = false

    init(group: FSContact, service: DataServiceProtocol, userId: String, onPick: @escaping (FSThreadSummary) -> Void) {
        self.group = group
        self.service = service
        self.userId = userId
        self.onPick = onPick
        _vm = StateObject(wrappedValue: ShareThreadsViewModel(service: service, groupId: group.id, userId: userId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
                if expanded && !vm.loaded { Task { await vm.load() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .bold))
                    Text("Threads").font(.system(size: Theme.fontSM, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(Theme.goldLight)
                .padding(.leading, 14)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Threads in \(group.name)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                if vm.failed {
                    HStack {
                        Text(vm.threads.isEmpty ? "Couldn't load threads." : "Couldn't refresh. Showing what we have.")
                            .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
                        Spacer()
                        Button("Retry") { Task { await vm.load() } }
                            .font(.system(size: Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .padding(.leading, 14)
                } else if !vm.loaded {
                    ProgressView().tint(Theme.gold).frame(maxWidth: .infinity, minHeight: 44)
                } else if vm.threads.isEmpty {
                    Text("No threads yet")
                        .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
                        .padding(.leading, 14)
                }
                ForEach(vm.threads) { t in
                    Button { onPick(t) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "text.bubble").foregroundColor(Theme.gold)
                            Text(t.title).font(.system(size: Theme.fontBody, weight: .semibold))
                                .foregroundColor(Theme.parchment).lineLimit(1)
                            Spacer()
                            Image(systemName: "paperplane").foregroundColor(Theme.gold)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(minHeight: 48)
                        .glassCard(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 14)
                    .accessibilityLabel("Send to thread \(t.title) in \(group.name)")
                }
            }
        }
    }
}
