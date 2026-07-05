// Displays all notifications for the user with edit/delete actions.
// Reached via the "View All" button in the notifications section of AccountView.

import SwiftUI

struct NotificationsListView: View {
    @ObservedObject var vm: AccountViewModel
    @State private var editingNotif: FSNotification? = nil

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            if vm.notifications.isEmpty {
                VStack(spacing: Theme.spacingMD) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 40))
                        .foregroundColor(Theme.textMuted)
                    Text("No notifications yet.")
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.textMuted)
                }
            } else {
                List {
                    ForEach(vm.notifications) { notif in
                        NotificationRow(notif: notif) {
                            editingNotif = notif
                        } onDelete: {
                            vm.deleteNotification(notifId: notif.id)
                        }
                        .listRowBackground(Theme.cardBg)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $editingNotif) { notif in
            NotificationSetupSheet(existing: notif) { name, prompt, timestamps in
                Task { await vm.updateNotification(notif: notif, name: name, prompt: prompt, timestamps: timestamps) }
            }
        }
    }
}

// ── Notification row ──────────────────────────────────────────────────────────

struct NotificationRow: View {
    let notif:    FSNotification
    let onEdit:   () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.spacingMD) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.12)).frame(width: 36, height: 36)
                Image(systemName: "bell").foregroundColor(Theme.gold).font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(notif.name.isEmpty ? "Unnamed Notification" : notif.name)
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment)

                HStack(spacing: 4) {
                    Text(notif.recurrenceSummary)
                        .font(.lora(Theme.fontXS))
                        .foregroundColor(Theme.gold.opacity(0.70))
                    if let t = notif.scheduledTime {
                        Text("·").foregroundColor(Theme.textMuted).font(.lora(Theme.fontXS))
                        Text(t).font(.lora(Theme.fontXS)).foregroundColor(Theme.textMuted)
                    }
                }

                if !notif.prompt.isEmpty {
                    Text(notif.prompt.prefix(60) + (notif.prompt.count > 60 ? "…" : ""))
                        .font(.lora(Theme.fontXS))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundColor(Theme.gold.opacity(0.60))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit notification")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(Theme.error.opacity(0.70))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete notification")
        }
        .padding(.vertical, 4)
    }
}
