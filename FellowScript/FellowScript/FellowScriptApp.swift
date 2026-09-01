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
}

extension Notification.Name {
    static let apnsTokenReceived = Notification.Name("apnsTokenReceived")
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
        }
    }
}
