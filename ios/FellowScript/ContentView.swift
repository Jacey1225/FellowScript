// SOURCE: frontend/src/App.jsx, global.css mobile-tab-bar
// KEY STATE: isAuthenticated, hasCompletedOnboarding
// INTERACTIONS: tab selection, onboarding dismiss, auth routing
// DEPENDENCY: AppState.swift, Theme.swift, all tab views

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var selectedTab: Tab = .home

    enum Tab: Int {
        case home, bible, notes, chat, account
    }

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            if appState.isAuthenticated {
                mainTabView
            } else {
                AuthView()
                    .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: .constant(!hasCompletedOnboarding)) {
            OnboardingView(onComplete: { hasCompletedOnboarding = true })
        }
        .animation(.easeInOut(duration: 0.25), value: appState.isAuthenticated)
        .tint(Theme.gold)
    }

    // ── Five-tab bar — mirrors mobile-tab-bar in global.css ──────────────────
    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(Tab.home)

            BibleReaderView()
                .tabItem {
                    Label("Bible", systemImage: "book.fill")
                }
                .tag(Tab.bible)

            NotesListView()
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
                .tag(Tab.notes)

            ChatRootView()
                .tabItem {
                    Label("Chat", systemImage: "message.fill")
                }
                .tag(Tab.chat)

            AccountView()
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }
                .tag(Tab.account)
        }
        .accentColor(Theme.accentColor)
    }
}
