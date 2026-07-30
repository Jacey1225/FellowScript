// SOURCE: frontend/src/App.jsx, global.css mobile-tab-bar
// KEY STATE: isAuthenticated, hasCompletedOnboarding
// INTERACTIONS: tab selection, onboarding dismiss, auth routing
// DEPENDENCY: AppState.swift, Theme.swift, all tab views

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var call = CallController.shared
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
        // Minimized call bar — floats above the tab bar while a call is running
        // but not expanded, so the user can browse the app during the call.
        .overlay(alignment: .bottom) {
            if call.inCall && !call.isExpanded {
                MinimizedCallBar()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: call.inCall)
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: call.isExpanded)
        // Expanded full-screen call
        .fullScreenCover(isPresented: $call.isExpanded) {
            ChimeCallView().environmentObject(appState)
        }
        .fullScreenCover(isPresented: .constant(!hasCompletedOnboarding)) {
            OnboardingView(onComplete: { hasCompletedOnboarding = true })
        }
        // Guideline 1.2: accounts that predate a material Terms change (e.g.
        // the zero-tolerance policy rewrite) must re-consent before continuing.
        .fullScreenCover(isPresented: $appState.termsReacceptRequired) {
            TermsReacceptView()
        }
        // Apple sign-in created this account without a name/email (only ever
        // supplied on the first-ever authorization) — ask the user to set them.
        .fullScreenCover(isPresented: $appState.needsProfileCompletion) {
            CompleteProfileView()
        }
        .onChange(of: appState.pendingBibleNav) { _, target in
            if target != nil { selectedTab = .bible }
        }
        .onChange(of: appState.pendingChatContact) { _, target in
            if target != nil { selectedTab = .chat }
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
