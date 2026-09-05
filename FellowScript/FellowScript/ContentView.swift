// SOURCE: frontend/src/App.jsx, global.css mobile-tab-bar
// KEY STATE: isAuthenticated, hasCompletedOnboarding
// INTERACTIONS: tab selection, onboarding dismiss, auth routing
// DEPENDENCY: AppState.swift, Theme.swift, all tab views

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var call = CallController.shared
    @StateObject private var startup = StartupCoordinator()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: Tab = .home

    enum Tab: Int {
        case home, bible, notes, chat, account
    }

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            if appState.isAuthenticated {
                // Startup loading screen: shown only post-auth (onboarding/
                // sign-in already own the pre-auth period — nothing to fetch
                // yet), and only once per session, until StartupCoordinator
                // reports every startup-critical data source ready (or its
                // timeout fires). Both branches live in this same ZStack
                // over Theme.bgPage so the transition below can crossfade
                // rather than hard-cut.
                if startup.isReady {
                    mainTabView
                        .transition(.opacity)
                } else {
                    LoadingScreenView()
                        .transition(.opacity)
                }
            } else if hasCompletedOnboarding {
                // Signed out AFTER onboarding was already completed once
                // (e.g. a session expiring) — this is the real, reachable
                // sign-in screen for that case.
                AuthView()
                    .transition(.opacity)
            }
            // Bug fix (task: 20260810-note-editor-tests-signin-not-hittable):
            // while onboarding hasn't completed yet, this branch used to
            // unconditionally render AuthView() here too — a SECOND, fully
            // laid-out AuthView instance sitting underneath OnboardingView's
            // .fullScreenCover the entire time onboarding runs (not just once
            // the CTA is reached). Confirmed live via app.debugDescription on
            // a real Simulator (iPhone 17 Pro, iOS 26.5, freshly erased): this
            // buried-but-still-existing instance shares IDENTICAL accessibility
            // labels with the CTA-triggered AuthView (both are the same
            // AuthView struct) — "Username field", "Password field", "Sign In
            // button", even the CTA's own "Sign In" button text collides with
            // this instance's Sign-In/Create-Account tab toggle. Both
            // NoteEditorUITests.swift and AccountUITests.swift query by those
            // same labels; when the query happened to resolve to THIS buried
            // instance instead of the real, topmost, cover-presented one, it
            // correctly reported "exists but never hittable" forever (it's
            // legitimately covered and non-interactive — that part was never
            // a bug). Simply not mounting this competing instance until
            // onboarding has actually completed removes the ambiguity: only
            // one AuthView instance exists at a time now during onboarding.
            // Verified on a freshly-erased Simulator (iPhone 17 Pro, iOS
            // 26.5): onboarding's Sign In CTA now reaches a single,
            // genuinely-hittable AuthView, and NoteEditorUITests.swift /
            // AccountUITests.swift both get past sign-in reliably (combined
            // with those files' own accessibility-label query fixes for
            // .textCase(.uppercase)-styled onboarding buttons — see their
            // signInAndReachDashboard()/signInAndReachAccount() comments).
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
        .motionAwareAnimation(.spring(response: 0.30, dampingFraction: 0.85), value: call.inCall, reduceMotion: reduceMotion)
        .motionAwareAnimation(.spring(response: 0.30, dampingFraction: 0.85), value: call.isExpanded, reduceMotion: reduceMotion)
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
        // Startup-readiness gate: begin the race the moment we're
        // authenticated (cold launch already-signed-in via
        // AppState.restoreSession, or a fresh sign-in from AuthView), and
        // reset it on sign-out so a later sign-in starts fresh rather than
        // reusing the previous account's already-loaded view models.
        .task {
            if appState.isAuthenticated, let uid = appState.currentUser?.user_id {
                startup.start(service: appState.service, userId: uid)
            }
        }
        .onChange(of: appState.isAuthenticated) { _, authenticated in
            if authenticated, let uid = appState.currentUser?.user_id {
                startup.start(service: appState.service, userId: uid)
            } else {
                startup.reset()
            }
        }
        .motionAwareAnimation(.easeInOut(duration: 0.25), value: appState.isAuthenticated, reduceMotion: reduceMotion)
        // Loading screen → mainTabView crossfade — a single ~350ms dissolve
        // at whatever point the video happened to be in its loop, not a
        // hard cut and not a wait for the loop to finish (see
        // LoadingScreenView / StartupCoordinator).
        .motionAwareAnimation(.easeOut(duration: 0.35), value: startup.isReady, reduceMotion: reduceMotion)
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
                // Task 20260901-dashboard-stale-reload-ui: now passes
                // StartupCoordinator's shared `dashboardVM` (mirroring the
                // other three tabs below) instead of DashboardView owning a
                // brand-new `DashboardViewModel()` locally -- so this
                // instance (and whatever it already has loaded) survives
                // ContentView's `if startup.isReady { mainTabView } else {
                // LoadingScreenView() }` structural swap tearing this whole
                // subtree down and rebuilding it, same as its siblings.
                DashboardView(vm: startup.dashboardVM)
                    .tag(Tab.home)
                    .toolbar(.hidden, for: .tabBar)
                // Pass StartupCoordinator's shared view-model instances —
                // already loaded (or still resolving in the background if
                // the readiness gate hit its timeout) — so mounting these
                // screens for the first time doesn't fire a second,
                // duplicate fetch (see NotesViewModel/BibleViewModel/
                // ChatViewModel's hasLoadedOnce guard).
                BibleReaderView(vm: startup.bibleVM)
                    .tag(Tab.bible)
                    .toolbar(.hidden, for: .tabBar)
                NotesListView(vm: startup.notesVM)
                    .tag(Tab.notes)
                    .toolbar(.hidden, for: .tabBar)
                ChatRootView(vm: startup.chatVM)
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
