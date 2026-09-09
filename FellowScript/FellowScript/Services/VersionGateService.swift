// Launch-time "is a newer version available" check against Apple's public
// iTunes/App Store Lookup API (architecture step 1's chosen source of
// truth — no new backend endpoint). This is an availability nudge, not a
// security control (Preference profile: Security Q14 scoping), so it is
// designed to fail OPEN: every failure mode below (offline, DNS/connect
// failure, timeout, non-2xx, empty `results`, malformed JSON, an
// unparseable version string) returns `nil` — "no confirmed update" —
// rather than throwing. Callers never need a do/catch; nothing here can
// crash or block launch.
//
// DEPENDENCY: StartupCoordinator.swift (the only caller — runs this
// independently of the startup readiness race so a stalled/slow lookup can
// never delay `isReady` or extend LoadingScreenView's own timeout).

import Foundation

/// A confirmed-available newer version, plus where "Update Now" should go.
/// `storeURL` comes straight from the Lookup API response's own
/// `trackViewUrl` — no separately-configured/hardcoded App Store numeric id
/// to keep in sync (Configuration Philosophy Q1/Q2: nothing here is a
/// deployment-specific tunable the way `NetworkService.apiBase` is, so it
/// isn't routed through build config).
struct AppUpdateInfo: Identifiable {
    let id = UUID()
    let latestVersion: String
    let storeURL: URL
}

enum VersionGateService {
    /// Generous enough not to false-positive on a slow-but-alive connection
    /// (mirrors the reasoning behind NetworkService.requestTimeout), short
    /// enough that this never becomes the long pole on launch even though
    /// it isn't part of the readiness race at all.
    private static let lookupTimeout: TimeInterval = 6

    /// Compares the installed CFBundleShortVersionString (MARKETING_VERSION)
    /// against the version Apple currently reports live for this app's
    /// bundle id. Returns `nil` whenever a newer version isn't *confirmed*
    /// available — that covers "already current" and every failure mode
    /// alike, by design (see file header).
    static func checkForUpdate(
        session: URLSession = .shared,
        bundle: Bundle = .main
    ) async -> AppUpdateInfo? {
        guard let bundleId = bundle.bundleIdentifier,
              let installed = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              !installed.isEmpty,
              var components = URLComponents(string: "https://itunes.apple.com/lookup")
        else { return nil }

        components.queryItems = [URLQueryItem(name: "bundleId", value: bundleId)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = lookupTimeout

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
            guard let result = decoded.results.first,
                  let storeURL = URL(string: result.trackViewUrl),
                  isTrustedStoreURL(storeURL),
                  isNewer(result.version, than: installed)
            else { return nil }

            return AppUpdateInfo(latestVersion: result.version, storeURL: storeURL)
        } catch {
            // Network error, cancellation, non-JSON body, decode failure —
            // all fail open. Deliberately not logged as a warning/error:
            // "App Store lookup didn't resolve this launch" is expected and
            // unremarkable (offline devices, App Store rate limiting, a
            // transient Apple-side outage), not an ops signal worth noise
            // for (contrast NetworkService's own decode-failure logging,
            // which covers *our* backend, not a third-party dependency).
            return nil
        }
    }

    /// Dotted-numeric version compare (e.g. "2.10.0" > "2.9.1"). Pads the
    /// shorter side with zeros so component counts don't have to match, and
    /// treats any non-numeric component as `0` rather than throwing —
    /// consistent with the whole service's fail-open posture.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// `trackViewUrl` is externally-supplied response data — it's TLS-
    /// verified in transit (no ATS exception covers itunes.apple.com, see
    /// Info.plist), but this app also hands it straight to `openURL` in
    /// UpdateNudgeView on a tap, so it's still worth pinning to Apple's own
    /// domains before that happens (security threat-model, task
    /// 20260909-ios-version-gate-popup) rather than trusting the field's
    /// shape implicitly. Guards against a malformed/unexpected response
    /// ever causing this app to open an arbitrary attacker-influenced
    /// URL/custom scheme — belt-and-suspenders alongside TLS, not a
    /// replacement for it. Fails open like the rest of this service: an
    /// untrusted host just means "no confirmed update" for that launch.
    private static let trustedStoreHosts: Set<String> = ["apps.apple.com", "itunes.apple.com"]

    private static func isTrustedStoreURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        return trustedStoreHosts.contains(host) || host.hasSuffix(".apple.com")
    }

    private struct LookupResponse: Decodable {
        let results: [LookupResult]
    }

    private struct LookupResult: Decodable {
        let version: String
        let trackViewUrl: String
    }
}
