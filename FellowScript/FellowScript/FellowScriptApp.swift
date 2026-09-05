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
    // chat thread. Any other push shape (e.g. heartbeat's
    // `heartbeat_id`/`agent_id`, or the plain friend-activity/no-activity
    // pushes with no `data` at all) has no matching case here and is left
    // exactly as inert on tap as it already was — this deliberately does not
    // generalize into a new dispatch mechanism for every push type, only the
    // two this task adds.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let data = response.notification.request.content.userInfo
        if data["devotion_id"] != nil, let groupId = data["group_id"] as? String, !groupId.isEmpty {
            NotificationCenter.default.post(name: .sessionPushTapped, object: groupId)
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let apnsTokenReceived = Notification.Name("apnsTokenReceived")
    static let sessionPushTapped = Notification.Name("sessionPushTapped")
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
        }
    }
}
