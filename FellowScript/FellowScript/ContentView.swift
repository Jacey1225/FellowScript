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

    // ── Five destinations behind a floating pill tab bar ─────────────────────
    // Keeps TabView (so each screen retains its state and lazy-mounts, and its
    // .task runs once — the same behavior the native bar gave) but hides the
    // native chrome and overlays FloatingTabBar. The custom bar floats over the
    // content on purpose (mini-player style); DashboardView adds bottom padding
    // to clear it.
    private var mainTabView: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                DashboardView()
                    .tag(Tab.home)
                    .toolbar(.hidden, for: .tabBar)
                BibleReaderView()
                    .tag(Tab.bible)
                    .toolbar(.hidden, for: .tabBar)
                NotesListView()
                    .tag(Tab.notes)
                    .toolbar(.hidden, for: .tabBar)
                ChatRootView()
                    .tag(Tab.chat)
                    .toolbar(.hidden, for: .tabBar)
                AccountView()
                    .tag(Tab.account)
                    .toolbar(.hidden, for: .tabBar)
            }
            .accentColor(Theme.accentColor)

            FloatingTabBar(selection: $selectedTab,
                           inCallBarVisible: call.inCall && !call.isExpanded)
        }
    }
}
