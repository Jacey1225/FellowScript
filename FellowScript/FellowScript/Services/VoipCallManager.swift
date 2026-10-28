// VoipCallManager.swift
// Task 20260916-callkit-voip-ring: PKPushRegistry (PushKit) + CXProvider/
// CXCallController (CallKit) integration. Wakes the app from any state
// (including killed) on a VoIP-type push from backend step 1's
// send_voip_push, reports the incoming ring to CallKit's native full-screen
// UI, and hands an answered call off to the EXISTING join path
// (AppState.joinRingedCall -> CallController.start) rather than a new one.
//
// DEPENDENCY: FellowScriptApp.swift (.ringPushTapped/RingPushTarget,
// .voipTokenReceived), Services/AppState.swift (registerVoipDeviceToken),
// Chat/ChimeCallView.swift (CallController.ringDeliveryNotice)
//
// Lives as its own singleton (like CallController.shared), not inside
// AppState/AppDelegate directly: PKPushRegistryDelegate's
// didReceiveIncomingPushWith MUST report a call to CXProvider synchronously
// (before its completion handler runs) regardless of whether SwiftUI/
// AppState has finished launching yet -- a VoIP push can wake this process
// from a fully killed state, and Apple treats a VoIP push that never
// results in a CallKit report as VoIP-push misuse (can get this app's
// ability to receive VoIP pushes revoked). AppState/CallController aren't
// guaranteed to exist yet at that point; this class has no dependency on
// either to do its core job.

import Foundation
import PushKit
import CallKit
import AVFoundation
import UIKit

final class VoipCallManager: NSObject {
    static let shared = VoipCallManager()

    private let registry = PKPushRegistry(queue: .main)
    private let provider: CXProvider
    private let callController = CXCallController()

    // Maps a CallKit-assigned call UUID back to the ring payload that
    // started it -- CXAnswerCallAction/CXEndCallAction only ever carry the
    // UUID, never the original push payload.
    private var activeCalls: [UUID: RingPushTarget] = [:]
    private var ringTimeoutTimers: [UUID: Timer] = [:]

    // Task 20261028-dm-direct-call (ring lifecycle). Calls this class itself
    // is ending (server ring_cancel, local timeout): their CXEndCallAction
    // must NOT be reported to the server as a user decline.
    private var systemEndedCalls: Set<UUID> = []
    // ring_cancel that arrived before its ring push (devotion_id -> when).
    // A late ring for the same devotion is reported (PushKit rule) and then
    // ended at once.
    private var earlyCancels: [String: Date] = [:]
    private static let earlyCancelWindow: TimeInterval = 60
    /// Server ring timeout is the authority and always rides in the push; this
    /// only applies to a push without it (matches RING_TIMEOUT_SECONDS=45).
    private static let defaultRingTimeout: Double = 45

    /// The most recently issued PushKit VoIP token, if any. Cached here
    /// (not solely relayed via the `.voipTokenReceived` NotificationCenter
    /// post below) because PushKit issues this automatically at launch --
    /// often before sign-in, and therefore before AppState even exists to
    /// subscribe to that notification -- unlike the APNs remote-
    /// notification token, which is only requested later, after sign-in
    /// (see AppState.requestPushNotifications()'s call sites). AppState
    /// reads this directly as a catch-up on sign-in / cold-launch-already-
    /// signed-in; the notification post still covers a later refresh while
    /// already signed in and running.
    private(set) var latestVoipToken: String?

    private override init() {
        // CXProviderConfiguration() -- the no-arg initializer is current
        // API (the `init(localizedName:)` overload is deprecated). No
        // custom ringtone/icon shipped yet -- system-default CallKit ring/
        // UI is used as-is, matching the request's own "stock Phone app"
        // framing. Revisit if brand assets for this are ever produced.
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        // Both delegates explicitly queued to `.main` (not `nil`/a private
        // CallKit-managed queue) so PKPushRegistry's and CXProvider's own
        // callbacks share the same queue as each other and as the rest of
        // this class's `activeCalls`/`ringTimeoutTimers` bookkeeping --
        // avoids needing a lock for state only this class touches.
        provider.setDelegate(self, queue: .main)
        registry.delegate = self
        // Eager, at construction (this singleton is touched from
        // AppDelegate.didFinishLaunchingWithOptions -- see
        // FellowScriptApp.swift), not deferred behind the lazy push-
        // permission flow AppState.requestPushNotifications() uses for
        // plain alert notifications (open question resolved): PushKit
        // requires no user-permission prompt at all -- setting
        // `desiredPushTypes` is enough to have the system mint a VoIP
        // token -- and CallKit ring delivery depends on this token being
        // current from app launch (including a killed-state launch, the
        // entire point of this task), so there's no "ask lazily" analog
        // here the way there is for UNUserNotificationCenter authorization.
        registry.desiredPushTypes = [.voIP]
    }
}

// MARK: - PKPushRegistryDelegate

extension VoipCallManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        // Same hex-encoding recipe as AppDelegate's
        // didRegisterForRemoteNotificationsWithDeviceToken, for the same
        // reason -- token log-redaction convention (Security Posture Q13)
        // applies equally here, so this value is never printed/logged.
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        latestVoipToken = token
        NotificationCenter.default.post(name: .voipTokenReceived, object: token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        latestVoipToken = nil
    }

    // Apple's hard contract: every VoIP push MUST result in exactly one
    // reportNewIncomingCall call before `completion` runs, even for a
    // payload this app can't make sense of -- failing to report is treated
    // by iOS as VoIP-push misuse. Security Posture Q3 (fail closed on a
    // malformed/unauthorized payload -- present nothing exploitable, never
    // crash or execute arbitrary handling): a payload missing the fields a
    // real ring push always carries (devotion_id/group_id, per
    // routes/devotion.py::ring_members) reports a placeholder call and
    // immediately ends it, rather than letting any of the payload's own
    // claims (caller name, etc.) drive what CallKit displays or what
    // answering it would do.
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }

        let data = payload.dictionaryPayload
        let devotionId = data["devotion_id"] as? String
        let groupId    = data["group_id"]    as? String
        let rawName    = data["caller_username"] as? String
        let callerName = (rawName?.isEmpty == false) ? rawName! : "Someone"
        let ringTimeout = (data["ring_timeout_seconds"] as? NSNumber)?.doubleValue ?? Self.defaultRingTimeout

        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = true
        update.supportsHolding   = false
        update.supportsGrouping  = false
        update.supportsUngrouping = false
        update.supportsDTMF      = false

        // Server cancelled the ring (caller hung up, or the ring timed out).
        // PushKit still demands a reportNewIncomingCall for THIS push, so a
        // placeholder is reported and ended at once; the real ringing call
        // for that devotion (if any) is ended without a decline report.
        if (data["action"] as? String) == "ring_cancel" {
            if let devotionId, !devotionId.isEmpty { endRingingCalls(devotionId: devotionId) }
            reportPlaceholderAndEnd(uuid: uuid, update: update, completion: completion)
            return
        }

        guard let devotionId, let groupId, !devotionId.isEmpty, !groupId.isEmpty else {
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
                self?.provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                completion()
            }
            return
        }

        // The cancel beat the ring here: report (required) and end at once.
        pruneEarlyCancels()
        if earlyCancels[devotionId] != nil {
            earlyCancels[devotionId] = nil
            reportPlaceholderAndEnd(uuid: uuid, update: update, completion: completion)
            return
        }

        activeCalls[uuid] = RingPushTarget(devotionId: devotionId, groupId: groupId)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let self else { completion(); return }
            if let error {
                // CallKit itself couldn't present the incoming-call UI
                // (e.g. filtered, unentitled, a duplicate UUID). This is
                // the "CallKit reporting itself fails" case the spec calls
                // out for a custom fallback -- surfaced via
                // CallController's own warm-toast mechanism (not
                // system-provided, per UI/UX Q12.1/Q12.3) so a user who
                // happens to already have the app foreground at least sees
                // something rather than a ring that silently never
                // appeared.
                print("CallKit reportNewIncomingCall failed: \(error.localizedDescription)")
                self.activeCalls[uuid] = nil
                Task { @MainActor in
                    CallController.shared.showRingDeliveryNotice(
                        "Someone tried to ring you, but the call screen couldn't be shown. Open the chat to join."
                    )
                }
                completion()
                return
            }
            self.scheduleRingTimeout(uuid: uuid, seconds: ringTimeout)
            completion()
        }
    }
}

// MARK: - CXProviderDelegate

extension VoipCallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        // System-level reset (e.g. underlying telephony/call state wiped
        // out from under us) -- clear all local bookkeeping so nothing
        // orphaned survives it, matching this step's "no orphaned
        // CXProvider call state left behind" bar.
        ringTimeoutTimers.values.forEach { $0.invalidate() }
        ringTimeoutTimers.removeAll()
        activeCalls.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        ringTimeoutTimers[action.callUUID]?.invalidate()
        ringTimeoutTimers[action.callUUID] = nil
        if let target = activeCalls[action.callUUID] {
            // Hands off to the EXACT same join path a tapped plain-push
            // ring already uses -- AppState.joinRingedCall(_:), reached via
            // the same `.ringPushTapped`/RingPushTarget notification
            // FellowScriptApp.swift already wires up -- no new/parallel
            // join logic, per this step's own requirement.
            NotificationCenter.default.post(name: .ringPushTapped, object: target)
        }
        activeCalls[action.callUUID] = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // Covers BOTH an explicit decline (tapping "Decline" on CallKit's
        // own UI) and the ring-timeout path below (which issues this same
        // CXEndCallAction via CXCallController) -- both converge here, so
        // there is exactly one place that clears bookkeeping and ends the
        // call, which is what keeps every outcome (answer/decline/timeout)
        // from ever leaving orphaned CXProvider state.
        ringTimeoutTimers[action.callUUID]?.invalidate()
        ringTimeoutTimers[action.callUUID] = nil
        let target = activeCalls[action.callUUID]
        activeCalls[action.callUUID] = nil
        let endedBySystem = systemEndedCalls.remove(action.callUUID) != nil
        // A genuine decline by the user (not our own timeout/cancel end) is
        // told to the server so the caller sees "declined" right away.
        if let target, !endedBySystem { reportDecline(target) }
        action.fulfill()
    }

    // No audio-session handling needed in either of these: unlike a literal
    // VoIP call, this app's actual call audio is owned entirely by
    // ChimeCallManager (see its own "do NOT touch AVAudioSession directly"
    // note) once CallController.start(...) joins -- which only begins
    // after the user answers, well after CXProvider's brief ring-
    // announcement audio session here has already been activated and torn
    // back down. Confirmed non-conflicting with the `audio` background
    // mode from 20260916-call-background-persistence -- see this task's own
    // Info.plist UIBackgroundModes comment for the full reasoning.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}

    private func scheduleRingTimeout(uuid: UUID, seconds: Double) {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.ringTimeoutTimers[uuid] = nil
            // The server expires the ring itself; this only dismisses the
            // local UI, so it is not reported as a decline.
            self.systemEndedCalls.insert(uuid)
            let endAction = CXEndCallAction(call: uuid)
            self.callController.request(CXTransaction(action: endAction)) { error in
                if let error {
                    print("CallKit timeout end-call failed: \(error.localizedDescription)")
                    self.systemEndedCalls.remove(uuid)
                    self.activeCalls[uuid] = nil
                }
            }
        }
        ringTimeoutTimers[uuid] = timer
    }

    // MARK: ring lifecycle helpers (task 20261028-dm-direct-call)

    /// Reports `uuid` as a call and ends it immediately (PushKit rule for a
    /// push that carries no real ring).
    private func reportPlaceholderAndEnd(uuid: UUID, update: CXCallUpdate, completion: @escaping () -> Void) {
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
            self?.provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
            completion()
        }
    }

    /// Ends every still-ringing CallKit call for `devotionId` with no
    /// decline report. If none exists yet, remembers the cancel briefly in
    /// case its ring push arrives after it.
    private func endRingingCalls(devotionId: String) {
        let matches = activeCalls.filter { $0.value.devotionId == devotionId }.map(\.key)
        if matches.isEmpty {
            pruneEarlyCancels()
            earlyCancels[devotionId] = Date()
            return
        }
        for uuid in matches {
            ringTimeoutTimers[uuid]?.invalidate()
            ringTimeoutTimers[uuid] = nil
            activeCalls[uuid] = nil
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
    }

    private func pruneEarlyCancels() {
        let cutoff = Date().addingTimeInterval(-Self.earlyCancelWindow)
        earlyCancels = earlyCancels.filter { $0.value > cutoff }
    }

    /// POST /devotions/ring/respond declined, as the signed-in user (the
    /// ringed target is always the user themself). Fire and forget; the
    /// server's ring timeout covers a failure. Works without AppState (a
    /// decline from the lock screen of a killed app).
    private func reportDecline(_ target: RingPushTarget) {
        let uid = UserDefaults.standard.string(forKey: "fs_user_id") ?? ""
        guard !uid.isEmpty else { return }
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "ring-decline") {
            UIApplication.shared.endBackgroundTask(bg)
        }
        Task {
            try? await NetworkService.shared.respondToRing(
                devotionId: target.devotionId, userId: uid, targetId: uid, outcome: .declined)
            if bg != .invalid { await MainActor.run { UIApplication.shared.endBackgroundTask(bg) } }
        }
    }
}
