// FloatingTabBar.swift
// Replaces the default TabView chrome with a floating, rounded pill-style bar
// (dark ground, gold accents), matching the FellowScript Dashboard mockup. Same
// 5 destinations / SF Symbols as ContentView's mainTabView — this re-skins the
// chrome only; screen content and routing are unchanged.
//
// SOURCE MAPPING: ContentView.swift (Tab enum + mainTabView), Theme/Theme.swift

import SwiftUI

struct FloatingTabBar: View {
    @Binding var selection: ContentView.Tab
    var inCallBarVisible: Bool = false   // shift up when MinimizedCallBar is showing

    private let items: [(tab: ContentView.Tab, label: String, symbol: String)] = [
        (.home,    "Home",    "house.fill"),
        (.bible,   "Bible",   "book.fill"),
        (.notes,   "Notes",   "note.text"),
        (.chat,    "Chat",    "message.fill"),
        (.account, "Account", "person.crop.circle"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.tab) { item in
                let isSelected = selection == item.tab
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = item.tab
                    }
                } label: {
                    if isSelected {
                        // Active tab: gold pill with label (the "Home" pill in the mock).
                        HStack(spacing: 7) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15, weight: .semibold))
                            Text(item.label)
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(Color(hex: "#24170A"))
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .clipShape(Capsule())
                    } else {
                        Image(systemName: item.symbol)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundColor(Theme.tabInactive)
                            .frame(width: 50, height: 46)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(7)
        .background(
            Capsule()
                .fill(Color(hex: "#120D08").opacity(0.94))
                .overlay(
                    Capsule().stroke(Color(hex: "#D4922A").opacity(0.24), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.8), radius: 18, x: 0, y: 8)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, inCallBarVisible ? 60 : 26)
    }
}
