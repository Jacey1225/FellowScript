// DEPENDENCY: AppState.swift, ContentView.swift

import SwiftUI
import UserNotifications

// ── AppDelegate — handles APNs token and foreground notification display ───────

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .apnsTokenReceived, object: token)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    // Show notification banner even when the app is in the foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound, .badge])
    }

    // Handles a tap on a delivered push (app backgrounded/killed) or a tap on
    // the in-app banner (app foregrounded) — this project previously had no
    // tap-handling at all (only `willPresent` above, which just controls
    // whether a banner shows), so no push type navigated anywhere on tap.
    // Task 20260904-session-push-notifications adds the first case: the two
    // new session pushes (`_notify_session_created` /
    // `_fire_due_session_reminders` in api/routes/devotion.py and
    // scheduler.py) put `devotion_id`/`group_id` in the payload's `data`
    // (merged alongside, not inside, `aps` — see push.py's `send_push`
    // docstring), specifically so a tap can resolve back to that session's
    // chat thread.
    //
    // Task 20260916-call-ring-members adds the second case: a ring push
    // carries the same `devotion_id`/`group_id` pair PLUS an
    // `action: "ring"` discriminator (routes/devotion.py::ring_members) so
    // this handler can tell it apart from the plain session-created/reminder
    // push above and route the tap straight into *joining the live call*
    // rather than just opening the session's chat thread. Checked first
    // (more specific) so a ring push doesn't also fall through to the
    // `.sessionPushTapped` branch. Any other push shape (e.g. heartbeat's
    // `heartbeat_id`/`agent_id`, or the plain friend-activity/no-activity
    // pushes with no `data` at all) still has no matching case here and is
    // left exactly as inert on tap as it already was.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let data = response.notification.request.content.userInfo
        let groupId    = data["group_id"]    as? String
        let devotionId = data["devotion_id"] as? String
        if data["action"] as? String == "ring", let devotionId, let groupId, !groupId.isEmpty {
            NotificationCenter.default.post(name: .ringPushTapped,
                                            object: RingPushTarget(devotionId: devotionId, groupId: groupId))
        } else if data["devotion_id"] != nil, let groupId, !groupId.isEmpty {
            NotificationCenter.default.post(name: .sessionPushTapped, object: groupId)
        }
        completionHandler()
    }
}

// Payload carried by `.ringPushTapped` — both fields are required to resolve
// straight to the live session (see AppState.joinRingedCall(_:)), unlike the
// plain session-created push which only ever needs `group_id`.
struct RingPushTarget {
    let devotionId: String
    let groupId:    String
}

extension Notification.Name {
    static let apnsTokenReceived = Notification.Name("apnsTokenReceived")
    static let sessionPushTapped = Notification.Name("sessionPushTapped")
    static let ringPushTapped    = Notification.Name("ringPushTapped")
}

// ── App ───────────────────────────────────────────────────────────────────────

@main
struct FellowScriptApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // XCUITest launches with the "UI-TESTING" argument (see FellowScriptUITests)
    // so end-to-end tests run deterministically against MockDataService instead
    // of hitting the live backend — never set outside of test schemes, so normal
    // launches (including TestFlight/App Store) are unaffected.
    @StateObject private var appState = AppState(
        service: ProcessInfo.processInfo.arguments.contains("UI-TESTING")
            ? MockDataService.shared
            : NetworkService.shared
    )
    // Task 20260909-push-permission-late-enable: re-checks push authorization
    // every time the app returns to the foreground, not just at the five
    // auth-flow entry points (signIn/signUp/signInWithGoogle/signInWithApple/
    // completeMfaLogin) that already call requestPushNotifications(). Without
    // this, a user who declined at signup and later flips the permission on
    // in iOS Settings never re-triggers registerForRemoteNotifications() --
    // nothing else ever re-checks UNUserNotificationCenter's authorization
    // status after that first decision. Mirrors ChatThreadView.swift's
    // existing scenePhase-driven foreground/background idiom (see its own
    // doc comment on `scenePhase`) rather than adding a second, competing
    // lifecycle-detection mechanism (e.g. a raw
    // UIApplication.willEnterForegroundNotification observer) -- this app
    // already treats scenePhase as its one source of truth for
    // foreground/background transitions.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .apnsTokenReceived)) { note in
                    if let token = note.object as? String {
                        appState.registerDeviceToken(token)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .sessionPushTapped)) { note in
                    if let groupId = note.object as? String {
                        appState.openSession(groupId: groupId)
                    }
                }
                // Task 20260916-call-ring-members: a ring push's tap-through
                // jumps straight into joining the live call rather than just
                // opening the session's chat thread.
                .onReceive(NotificationCenter.default.publisher(for: .ringPushTapped)) { note in
                    if let target = note.object as? RingPushTarget {
                        appState.joinRingedCall(devotionId: target.devotionId, groupId: target.groupId)
                    }
                }
        }
        // Only reacts to .active, not .inactive -- same rationale as
        // ChatThreadView's own scenePhase gate: .inactive also fires for
        // transient states (Control Center, an incoming call/permission
        // overlay, the app-switcher gesture) that never actually left the
        // app, and re-checking on that transient dip would only add
        // redundant work, not new correctness. requestPushNotifications()'s
        // own switch already only ever prompts while genuinely
        // .notDetermined and no-ops on .denied, so repeated .active
        // transitions (locking/unlocking the device, switching apps and
        // back) don't spam a re-prompt -- and registerForRemoteNotifications()
        // is documented by Apple as safe/cheap to call repeatedly, so the
        // .authorized/.provisional/.ephemeral branch re-firing on every
        // foreground isn't observably wasteful either.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                appState.requestPushNotifications()
                // Task 20260916-call-background-persistence: resume local
                // video (if it was on and the call is still actually
                // connected) now that the app is foreground again. No-ops
                // when there's no active call.
                #if canImport(AmazonChimeSDK)
                CallController.shared.manager.handleAppForegrounded()
                #endif
            } else if phase == .background {
                // Task 20260914-dictation-tts: per the intake spec's resolved
                // open question, backgrounding stops dictation rather than
                // continuing to read (no Now Playing/remote-command-center
                // infrastructure is in scope). Lives here rather than in a
                // raw UIApplication.didEnterBackgroundNotification observer
                // inside SpeechController itself, matching this file's own
                // established stance (see AppDelegate section above) that
                // scenePhase is this app's one source of truth for
                // foreground/background transitions.
                SpeechController.shared.stop()

                // Task 20260916-call-background-persistence: deliberately does
                // NOT touch CallController.shared.session or
                // ChimeCallManager's audio session/meetingSession here. The
                // entire point of this task is that an active Chime call
                // (audio + mic) keeps running while backgrounded -- see
                // Info.plist's new `audio` UIBackgroundModes entry -- so this
                // branch must leave the call itself completely alone. Only
                // local video, which iOS forbids capturing while backgrounded
                // regardless, is explicitly paused here (and resumed in the
                // `.active` branch above).
                #if canImport(AmazonChimeSDK)
                CallController.shared.manager.handleAppBackgrounded()
                #endif
            }
        }
    }
}
