// NotesListView+Toolbar.swift — header (filter/sort menu, title, new note),
// Notes/Highlights segmented toggle, and group filter chips. Split out of
// NotesListView.swift (readability #6, 20260904-frontend-arch-sweep) -- same
// type, same behavior, just this section's own file. See NotesListView.swift's
// header comment for the full split rationale and the list of sibling
// section files.

import SwiftUI

extension NotesListView {

    // ── Header: filter/sort menu · title · new note ───────────────────────────
    // The reference's hamburger opens the (already-built) sort/visibility menu
    // rather than a non-existent side menu, so no functionality is lost.
    var header: some View {
        HStack {
            Menu {
                Section("Sort") {
                    ForEach(NotesViewModel.SortOrder.allCases, id: \.self) { order in
                        Button(action: { vm.sortOrder = order }) {
                            Label(order.rawValue, systemImage: vm.sortOrder == order ? "checkmark" : "arrow.up.arrow.down")
                        }
                    }
                }
                if vm.isFiltered {
                    Divider()
                    Button(role: .destructive, action: { vm.resetFilters() }) {
                        Label("Clear Filters", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Circle()
                    .strokeBorder(Theme.parchment.opacity(0.18), lineWidth: 1)
                    .background(Circle().fill(Theme.parchment.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundColor(vm.isFiltered ? Theme.goldLight : Theme.parchment.opacity(0.8))
                    )
            }
            .accessibilityLabel("Filter and sort notes")

            Spacer()
            Text("Notes")
                .font(.system(size: 27, weight: .heavy))
                .foregroundColor(Theme.parchment)
            Spacer()

            Button(action: startNewNote) {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundColor(Color(hex: "#24170A")))
                    .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 6)
            }
            .accessibilityLabel("Create new note")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // ── Notes / Highlights gold segmented toggle ──────────────────────────────
    var notesHighlightsToggle: some View {
        HStack(spacing: 4) {
            toggleSegment(.notes, "Notes")
            toggleSegment(.highlights, "Highlights")
        }
        .padding(5)
        .background(
            Capsule().fill(Theme.parchment.opacity(0.07))
                .overlay(Capsule().stroke(Theme.parchment.opacity(0.13), lineWidth: 1))
        )
    }

    func toggleSegment(_ tab: NotesViewModel.NoteTab, _ label: String) -> some View {
        let isActive = vm.activeTab == tab
        return Button(action: { withMotionAwareAnimation(.spring(response: 0.28, dampingFraction: 0.85), reduceMotion: reduceMotion) { vm.activeTab = tab } }) {
            Text(label)
                .font(.system(size: 14.5, weight: .heavy))
                .foregroundColor(isActive ? Color(hex: "#24170A") : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    isActive
                        ? LinearGradient(colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // ── Group filter chips (Personal + each group) ────────────────────────────
    var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Personal", id: nil)
                ForEach(vm.groups) { group in
                    chip(title: group.title, id: group.id)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    func chip(title: String, id: String?) -> some View {
        let selected = vm.currentGroupId == id
        Button(action: { withMotionAwareAnimation(.easeOut(duration: 0.18), reduceMotion: reduceMotion) { vm.currentGroupId = id } }) {
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(selected ? Color(hex: "#24170A") : Theme.parchment.opacity(0.7))
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(
                    selected
                        ? LinearGradient(colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [Theme.parchment.opacity(0.07), Theme.parchment.opacity(0.07)], startPoint: .leading, endPoint: .trailing)
                )
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.parchment.opacity(0.14), lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
