// Amazon Chime audio/video call screen.
//
// The Amazon Chime SDK Swift Package is already added to the project:
//   https://github.com/aws/amazon-chime-sdk-ios-spm.git  (product: AmazonChimeSDK)
// The `#if canImport(AmazonChimeSDK)` block below is the live implementation;
// the #else stub only renders if the package is ever removed.

import SwiftUI
import AVFoundation
import Combine

// ── Response types live in ChimeModels.swift (no SDK dependency) ─────────────

// MARK: - Call Controller ──────────────────────────────────────────────────────
// App-wide, persistent call state. Because it lives here (not inside the call
// screen), the user can minimize/dismiss the call UI and keep talking while they
// use the rest of the app. Only `end()` actually leaves the meeting.

@MainActor
final class CallController: ObservableObject {
    static let shared = CallController()
    private init() {}

    @Published var session:     FSSession? = nil   // non-nil ⇒ currently in a call
    @Published var isExpanded   = false            // full-screen vs minimized bar
    @Published var joinError:   String? = nil
    // Task 20260907-session-summary-wireup: a warm, self-dismissing notice for
    // a post-call summarize failure. Deliberately separate from joinError
    // (which gates the still-open call screen while joining) -- by the time a
    // summarize failure can occur the call has already ended and the call
    // screen/minimized bar are both gone, so nothing renders joinError.
    // Styled and self-cleared the same way as AccountViewModel.eventFireMsg's
    // toast, per UI/UX Q17.3 (recoverable/background errors get a warm,
    // on-brand tone, not a raw technical message).
    @Published var summarizeNotice: String? = nil
    // Task 20260916-call-ring-members: which targets have already been
    // successfully rung during THIS call. Read by RingMembersSheet so a
    // `sent` row stays `sent` across the sheet being dismissed and
    // reopened (design-notes.md §5) -- re-showing a rung member as plain
    // `default` would invite an accidental re-ring inside the same
    // cooldown window. Scoped to the call, not persisted -- cleared in
    // end() below, same lifetime as the call itself.
    @Published var sentRingTargets: Set<String> = []

    // Task 20260916-callkit-voip-ring: a warm, self-dismissing notice for
    // the case where CallKit ITSELF fails to report an incoming ring (e.g.
    // VoipCallManager's reportNewIncomingCall completion handler receiving
    // an error) -- kept separate from summarizeNotice/joinError above for
    // the same reason those two are separate from each other: this can fire
    // with no call screen/session in play at all, including from a killed-
    // state launch, and it's about a ring the user never even saw the
    // system UI for, not a post-call or in-progress-join failure. Per the
    // project's custom-UI convention (UI/UX Q12.1/Q12.3): CallKit's own
    // ring UI is system-provided and intentionally not reimplemented here,
    // but this *fallback* -- shown only when that system UI itself
    // couldn't be presented -- is custom-built, same warm-toast recipe as
    // summarizeNotice/AccountViewModel.eventFireMsg.
    @Published var ringDeliveryNotice: String? = nil

    // Task 20261009-discussion-rooms: room-switch state + heartbeat. Never
    // touches `session` (the MAIN session) or the CallKit call.
    let rooms = CallRoomController()

    // Task 20261028-dm-direct-call: caller-side ringing/declined/no-answer
    // state for DM and group rings (see CallRingTracker.swift).
    let ring = CallRingTracker()

    #if canImport(AmazonChimeSDK)
    let manager = ChimeCallManager()
    #endif

    var inCall: Bool { session != nil }

    // Stashed at start() so end() -- invoked from 4 call sites across
    // ChimeCallView.swift, none of which have an AppState/EnvironmentObject
    // reference -- can still fire the summarize request without threading
    // service/userId through every call site. Read-only outside this class
    // (task 20260916-call-ring-members: RingMembersSheet, presented from
    // ChimeCallView, needs both to call service.ringMembers(...) without a
    // third call site threading its own copies through).
    private(set) var service: DataServiceProtocol?
    private(set) var userId:  String = ""

    func start(session: FSSession, service: DataServiceProtocol, userId: String) {
        if self.session?.id == session.id { isExpanded = true; return }  // already joined
        self.session    = session
        self.service    = service
        self.userId     = userId
        self.joinError  = nil
        self.isExpanded = true
        rooms.configure(service: service, userId: userId, sessionId: session.id)
        rooms.onMainEnded = { [weak self] in self?.end() }
        #if canImport(AmazonChimeSDK)
        manager.configureTranscript(service: service as? TranscriptRelayServiceProtocol,
                                    userId: userId, sessionId: session.id)
        rooms.switchMeeting = { [weak self] response in self?.manager.switchMeeting(response: response) }
        Task { @MainActor in
            do {
                let resp = try await service.joinCall(userId: userId, sessionId: session.id)
                manager.join(response: resp)
            } catch {
                joinError = error.localizedDescription
            }
        }
        #else
        joinError = "Live calls require the Amazon Chime SDK."
        #endif
    }

    func minimize() { isExpanded = false }
    func expand()   { isExpanded = true }

    func end() {
        // Snapshot what a summarize call needs before teardown below clears it.
        let endingSession = session
        let endingService = service
        let endingUserId  = userId

        // Caller hang-up while someone is still ringing: cancel those rings so
        // their CallKit UI is dismissed. Best effort, never blocks ending.
        ring.cancelOutstandingAndReset()
        // Best-effort room leave + heartbeat stop before teardown; never blocks ending.
        rooms.callEnded()
        // Detach the transcript relay BEFORE leaving so its buffered tail can
        // still be sent (below) ahead of the summarize request.
        #if canImport(AmazonChimeSDK)
        let finishingRelay = manager.detachTranscriptRelay()
        let managerDiagnostics = manager.transcriptDiagnostics
        manager.leave()
        #else
        let finishingRelay: TranscriptRelay? = nil
        let managerDiagnostics = TranscriptDiagnostics()
        #endif
        session = nil; isExpanded = false; joinError = nil
        service = nil; userId = ""
        sentRingTargets = []

        // Task 20261013-session-call-live-transcript-summary: ONE trigger rule
        // on every client: whoever ends the call asks for a summary. The
        // server dedupes (sessionsum:<session>:<user>) and the first request
        // consumes the transcript, so extra triggers cost no extra LLM call.
        Task { @MainActor in
            await finishingRelay?.stop(flushRemaining: true)
            let diagnostics = managerDiagnostics.merged(with: finishingRelay?.diagnostics)
            Self.reportTranscriptionSummary(diagnostics, service: endingService)
            maybeSummarize(session: endingSession, service: endingService, userId: endingUserId,
                           diagnostics: diagnostics)
        }
    }

    // One end-of-call transcription summary (log + beacon) when transcription
    // was on for the call. Counts and fixed words only (see TranscriptDiagnostics).
    private static func reportTranscriptionSummary(_ diagnostics: TranscriptDiagnostics, service: DataServiceProtocol?) {
        guard diagnostics.wasActive else { return }
        let summary = diagnostics.summaryString
        RefreshDiagnostics.transcriptionOutcome(stage: "call-end", summary: summary)
        (service as? NetworkService)?.reportTranscriptionDiagnostic(stage: "call-end", summary: summary)
    }

    // Fire-and-forget: kicked off only after the synchronous teardown above
    // has already completed, so a slow or failing summarize call can never
    // block/delay leaving the call. Every participant whose session has
    // summaries enabled asks for one (same rule as web); the server dedupes
    // per (session, user) so a repeated request never re-calls the model or
    // double-writes a note.
    private static let summarizeDeferMaxRetries = 2
    private static let summarizeDeferRetryNanos: UInt64 = 50_000_000_000   // ~50 s > 45 s stale window

    private func maybeSummarize(session: FSSession?, service: DataServiceProtocol?, userId: String,
                                diagnostics: TranscriptDiagnostics = TranscriptDiagnostics()) {
        guard let session, session.summarize, let service, !userId.isEmpty else { return }
        Task { @MainActor in
            // Task 20260923-session-summary-call-failure: `stage` records
            // which of the two awaits below was in flight when/if the catch
            // fires, so a local resolveAgentId failure (fetchAgents/
            // createAgent under real account/network conditions, candidate
            // #2 from that task's investigation) is distinguishable from the
            // summarize endpoint itself rejecting or failing -- previously
            // both collapsed into the same silent, undiagnosable toast.
            var stage = "resolve-agent"
            do {
                let agentId = try await Self.resolveAgentId(userId: userId, service: service)
                stage = "summarize-request"
                let deferred = try await service.summarizeSessionReportingDeferral(
                    userId: userId, agentId: agentId, session: session, groupId: session.group_id)
                if deferred {
                    // Bounce 2: another (possibly ghost) attendee still counted
                    // present server-side. Retry the same request, silently,
                    // just past the 45 s stale window. Owned by this
                    // app-level controller's unstructured Task, so it outlives
                    // the call view; lost if the app is backgrounded/killed.
                    // No transcript re-flush happens here.
                    // Retries are fully silent: any error or cancellation just stops.
                    do {
                        for _ in 0..<Self.summarizeDeferMaxRetries {
                            try await Task.sleep(nanoseconds: Self.summarizeDeferRetryNanos)
                            let again = try await service.summarizeSessionReportingDeferral(
                                userId: userId, agentId: agentId, session: session, groupId: session.group_id)
                            if !again { break }
                        }
                    } catch {
                        // Build 122 swallowed every error here, so a deferred
                        // call whose retry hit the 422/502 produced no beacon
                        // and no toast (the missing 2026-10-15 22:13 beacon).
                        // Cancellation stays silent; anything else is reported.
                        stage = "summarize-retry"
                        if !RefreshDiagnostics.isCancellation(error) {
                            self.handleSummarizeFailure(error, stage: stage, service: service, diagnostics: diagnostics)
                        }
                    }
                }
            } catch {
                self.handleSummarizeFailure(error, stage: stage, service: service, diagnostics: diagnostics)
            }
        }
    }

    private func handleSummarizeFailure(_ error: Error, stage: String, service: DataServiceProtocol,
                                        diagnostics: TranscriptDiagnostics) {
        // Free plan: session summaries are subscribers-only. The shared
        // upgrade prompt replaces the generic "couldn't put together" toast.
        if UpgradePromptCenter.shared.present(for: error) { return }
        let errorClass = Self.summarizeErrorClass(error)
        RefreshDiagnostics.summarizeOutcome(stage: stage, errorClass: errorClass)
        // Best-effort server-side signal (fire-and-forget; a cancelled
        // call/task is not a failure worth reporting). Fixed strings only.
        if !RefreshDiagnostics.isCancellation(error) {
            (service as? NetworkService)?.reportSummarizeFailure(stage: stage, errorClass: errorClass)
        }
        self.showSummarizeNotice(SummarizeNoticeCopy.text(errorClass: errorClass, diagnostics: diagnostics))
    }

    // Refines RefreshDiagnostics.errorClass(_:) for this one call site only,
    // for the two summarize-specific failure modes that otherwise both
    // collapse into the same generic "AppError.networkError" label: a 403
    // rejection from `_require_group_membership` (real, non-DM group_id the
    // caller isn't a verified member of) and a 502 from the LLM call.
    // Matches on summarize_session's own two fixed, non-PII detail strings
    // (api/routes/agent.py) only -- never on message text from any other
    // endpoint, and never on anything that could carry user-supplied
    // content, so this stays within RefreshDiagnostics' own "never log
    // server-provided detail text" posture (Security Posture Q13) while
    // still being specific enough to end the guesswork this feature area
    // has needed twice now. The 403 notes-cap case is already distinguished
    // upstream via AppError.limitReached, no extra matching needed there.
    private static func summarizeErrorClass(_ error: Error) -> String {
        if case AppError.networkError(let detail) = error {
            if detail == "Not a member of this group" { return "not-group-member-403" }
            if detail == "Could not generate session summary." { return "llm-generation-502" }
            if detail == "This session doesn't have any content to summarize." { return "no-summarizable-content-422" }
        }
        if case AppError.limitReached = error { return "notes-cap-403" }
        return RefreshDiagnostics.errorClass(error)
    }

    // A study session carries no agent reference of its own -- FSSession
    // never modeled one (open question, task 20260907-session-summary-
    // wireup). Silently reuses the user's first agent rather than surfacing a
    // picker: an agent's `role` only tints the LLM prompt server-side (see
    // api/routes/agent.py's summarize route), so there's nothing session-
    // summary-specific to choose between. Auto-creates one on the fly for a
    // user who has never made an agent before this feature existed.
    private static func resolveAgentId(userId: String, service: DataServiceProtocol) async throws -> String {
        let agents = try await service.fetchAgents(userId: userId)
        if let agent = agents.first(where: { $0.enabled }) ?? agents.first { return agent.id }
        let created = try await service.createAgent(userId: userId, role: "")
        return created.id
    }

    // Mirrors AccountViewModel.showEventFireMsg's self-dismissing toast: only
    // clears if it's still the same message by the time the delay elapses, so
    // a fast second notice isn't clobbered by the first one's timer.
    private func showSummarizeNotice(_ text: String) {
        summarizeNotice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if summarizeNotice == text { summarizeNotice = nil }
        }
    }

    // Task 20260916-callkit-voip-ring: not `private` -- called from
    // VoipCallManager (Services/VoipCallManager.swift), a plain NSObject
    // singleton outside this @MainActor class, via `Task { @MainActor in
    // ... }`. Same self-dismissing-toast shape as showSummarizeNotice above.
    func showRingDeliveryNotice(_ text: String) {
        ringDeliveryNotice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if ringDeliveryNotice == text { ringDeliveryNotice = nil }
        }
    }
}

// MARK: - Minimized call bar (shown while in a call but not expanded) ───────────

struct MinimizedCallBar: View {
    // Task 20260916-call-bar-nav-overlap: single source of truth for this
    // bar's own footprint, so FloatingTabBar (Dashboard/FloatingTabBar.swift)
    // can derive its in-call bottom clearance from these instead of an
    // independent guess that silently drifts out of sync with this view's
    // actual layout (which is exactly how the two ended up overlapping).
    // Height = the 34pt circle (the tallest element in the HStack below)
    // plus the 8pt vertical padding applied on both edges.
    static let height: CGFloat = 34 + 8 * 2
    // Distance from the safe-area bottom edge to this bar's own bottom edge —
    // set by ContentView's `.overlay(alignment: .bottom)` padding. Kept here
    // as the source of truth for that same value instead of a second
    // independent literal in ContentView.
    static let bottomInset: CGFloat = 56

    @ObservedObject private var call = CallController.shared
    @ObservedObject private var rooms = CallController.shared.rooms

    private var subtitle: String {
        if let name = rooms.state.currentRoomName ?? rooms.state.roomName, rooms.state.showsBackToMain {
            return "In \(name) \u{00B7} tap to return"
        }
        return "Tap to return to call"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { call.expand() } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.green.opacity(0.90)).frame(width: 34, height: 34)
                        Image(systemName: "phone.fill").font(.system(size: 13)).foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.session?.title ?? "In call")
                            .font(.inter(Theme.fontSM, weight: .semibold))
                            .foregroundColor(.white).lineLimit(1)
                        Text(subtitle)
                            .font(.inter(Theme.fontXXS)).foregroundColor(.white.opacity(0.60))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rooms.state.showsBackToMain
                ? "Return to call \(call.session?.title ?? ""), in room \(rooms.state.currentRoomName ?? rooms.state.roomName ?? "")"
                : "Return to call \(call.session?.title ?? "")")

            Spacer(minLength: 8)

            #if canImport(AmazonChimeSDK)
            // Step 5: the "you are sharing" indicator + one-tap stop stays
            // visible while the call UI is minimized.
            MinimizedShareStopButton(manager: call.manager)
            #endif

            Button { call.end() } label: {
                ZStack {
                    Circle().fill(Color.red).frame(width: 34, height: 34)
                    Image(systemName: "phone.down.fill").font(.system(size: 13)).foregroundColor(.white)
                }
            }
            .accessibilityLabel("End call")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.gold.opacity(0.30), lineWidth: 1))
        .shadow(color: .black.opacity(0.40), radius: 8, y: 3)
    }
}

#if canImport(AmazonChimeSDK)
import AmazonChimeSDK

// MARK: - Call Manager ────────────────────────────────────────────────────────
// @Published mutations dispatched to main queue — SDK callbacks arrive on
// background threads.

final class ChimeCallManager: NSObject, ObservableObject {
    @Published var isConnected    = false
    @Published var isMuted        = false
    @Published var isCameraOn     = false
    @Published var localTileId:   Int? = nil
    @Published var remoteTileIds: [Int] = []
    @Published var remoteAttendeeIds: [String] = []   // other participants (audio or video)
    @Published var startError:    String? = nil
    // Task 20261009-session-ui-redesign: names + content-share (receive side).
    @Published var tileAttendeeIds:   [Int: String] = [:]   // remote tileId -> attendeeId
    @Published var externalUserIds:   [String: String] = [:] // attendeeId -> FellowScript user_id
    @Published private(set) var contentShare = ContentShareState()
    var contentShareTileId: Int? { contentShare.tileId }
    /// True when the active content tile is MY OWN share (never render it back
    /// at myself: hall of mirrors; see design-notes.md section 4).
    var sharerIsSelf: Bool {
        guard let sharer = contentShare.sharerAttendeeId, !myAttendeeId.isEmpty else { return false }
        return sharer == myAttendeeId
    }
    // Task 20261009-session-ui-redesign step 5: whole-screen sharing (sending).
    @Published private(set) var screenShare = ScreenShareState()
    /// Warm, self-dismissing fail-soft notice (never raw technical text).
    @Published var screenShareNotice: String? = nil
    private var shareCoordinator: ChimeScreenShareCoordinator?
    private var shareAwaitTimeout: DispatchWorkItem?

    private var meetingSession: DefaultMeetingSession?
    private var myAttendeeId:   String = ""
    // Task 20261013-session-call-live-transcript-summary: true while the server
    // is transcribing the MAIN call (consent banner for every participant).
    @Published var transcriptionActive = false
    private var transcriptService: TranscriptRelayServiceProtocol?
    private var transcriptUserId = ""
    private var transcriptSessionId = ""
    private var transcriptRelay: TranscriptRelay?
    /// Observer-side transcription counters for the current call (reset by
    /// `configureTranscript`); relay-side counters live on the relay.
    private(set) var transcriptDiagnostics = TranscriptDiagnostics()
    private var transcriptStatusBeacons = 0
    private static let maxStatusBeaconsPerCall = 4   // /monitoring/client-error is 10/min
    // Task 20261009-discussion-rooms: mute / camera INTENT carried across a
    // meeting swap, re-applied once the new audio session is up.
    private var pendingCameraRestore = false

    func join(response: ChimeJoinResponse) {
        // Rebuild the SDK's meeting/attendee models from our Codable response,
        // then use the high-level configuration initializer.
        let mediaPlacement = MediaPlacement(
            audioFallbackUrl:  response.Meeting.MediaPlacement.AudioFallbackUrl,
            audioHostUrl:      response.Meeting.MediaPlacement.AudioHostUrl,
            signalingUrl:      response.Meeting.MediaPlacement.SignalingUrl,
            turnControlUrl:    response.Meeting.MediaPlacement.TurnControlUrl,
            eventIngestionUrl: response.Meeting.MediaPlacement.EventIngestionUrl
        )
        let meeting = Meeting(
            externalMeetingId: response.Meeting.ExternalMeetingId,
            mediaPlacement:    mediaPlacement,
            mediaRegion:       response.Meeting.MediaRegion,
            meetingId:         response.Meeting.MeetingId
        )
        let attendee = Attendee(
            attendeeId:     response.Attendee.AttendeeId,
            externalUserId: response.Attendee.ExternalUserId,
            joinToken:      response.Attendee.JoinToken
        )
        myAttendeeId = response.Attendee.AttendeeId
        let config = MeetingSessionConfiguration(
            createMeetingResponse:  CreateMeetingResponse(meeting: meeting),
            createAttendeeResponse: CreateAttendeeResponse(attendee: attendee),
            urlRewriter: { $0 }
        )
        meetingSession = DefaultMeetingSession(
            configuration: config,
            logger: ConsoleLogger(name: "ChimeCall")
        )
        meetingSession?.audioVideo.addAudioVideoObserver(observer: self)
        meetingSession?.audioVideo.addVideoTileObserver(observer: self)
        // RealtimeObserver tracks the roster — without it, audio-only participants
        // are invisible and the UI wrongly shows "no one has joined".
        meetingSession?.audioVideo.addRealtimeObserver(observer: self)
        startTranscriptRelay(for: response)

        // audioVideo.start() throws PermissionError.audioPermissionError unless
        // microphone access is already granted — which would leave the call stuck
        // at "Connecting…". Request the mic first, then start.
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.startError = "Microphone access is required to join the call. Enable it in Settings → FellowScript."
                    return
                }
                do {
                    try self.meetingSession?.audioVideo.start()
                    self.meetingSession?.audioVideo.startRemoteVideo()
                    // NOTE: do NOT touch AVAudioSession directly here — Chime owns the
                    // audio session, and overriding it races with the audio-unit
                    // startup and silences the outgoing mic. Speaker routing is done
                    // via the SDK in audioSessionDidStart(reconnecting:) below.
                } catch {
                    self.startError = "Couldn't start the call: \(error.localizedDescription)"
                    print("Chime start error: \(error)")
                }
            }
        }
    }

    /// Task 20261009-discussion-rooms: swaps the Chime meeting (main <-> room)
    /// WITHOUT ending the call. Unlike `leave()` it keeps `isMuted` and camera
    /// intent (mute must never silently flip to unmuted in a new room), and it
    /// never touches AVAudioSession (Chime owns it; speaker routing is redone
    /// by `audioSessionDidStart`). CallKit is not involved: the CXCall belongs
    /// to the main session. The caller has ALREADY obtained `response` from the
    /// backend, so a join failure can never reach this point.
    func switchMeeting(response: ChimeJoinResponse) {
        let wasSharing = screenShare.isActive
        let cameraWasOn = isCameraOn
        stopScreenShare(notify: false)
        if wasSharing { showScreenShareNotice(RoomCopy.screenShareStopped) }
        if let old = meetingSession {
            // Silence the outgoing session's callbacks so its late stop events
            // can't flip state while the new session connects.
            old.audioVideo.removeAudioVideoObserver(observer: self)
            old.audioVideo.removeVideoTileObserver(observer: self)
            old.audioVideo.removeRealtimeObserver(observer: self)
            old.audioVideo.removeRealtimeTranscriptEventObserver?(observer: self)
            old.audioVideo.stop()
        }
        // Flush-and-stop the relay of the meeting being left (a room is not transcribed).
        if let relay = detachTranscriptRelay() {
            Task { @MainActor in
                await relay.stop(flushRemaining: true)
                // Keep this meeting's relay counters for the end-of-call summary.
                self.transcriptDiagnostics = self.transcriptDiagnostics.merged(with: relay.diagnostics)
            }
        }
        meetingSession = nil
        isConnected = false; isCameraOn = false
        localTileId = nil; remoteTileIds = []; remoteAttendeeIds = []
        tileAttendeeIds = [:]; externalUserIds = [:]; contentShare.reset()
        pendingCameraRestore = cameraWasOn
        join(response: response)
    }

    func toggleMute() {
        guard let av = meetingSession?.audioVideo else { return }
        if isMuted { _ = av.realtimeLocalUnmute(); isMuted = false }
        else        { _ = av.realtimeLocalMute();   isMuted = true  }
    }

    func toggleCamera() {
        guard let av = meetingSession?.audioVideo else { return }
        if isCameraOn {
            av.stopLocalVideo(); isCameraOn = false
        } else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, granted else { return }
                    do { try av.startLocalVideo(); self.isCameraOn = true }
                    catch { print("Camera start error: \(error)") }
                }
            }
        }
    }

    func leave() {
        // Tear the share down first, while the meeting session can still stop the
        // content share; also closes the socket so the extension ends its broadcast.
        stopScreenShare(notify: false)
        // Normally CallController.end() already detached the relay to flush it;
        // this covers any other leave path (no flush, just stop).
        if let relay = detachTranscriptRelay() { Task { @MainActor in await relay.stop() } }
        meetingSession?.audioVideo.stop()
        meetingSession = nil
        isConnected = false; isMuted = false; isCameraOn = false
        localTileId = nil;   remoteTileIds = []; remoteAttendeeIds = []
        tileAttendeeIds = [:]; externalUserIds = [:]; contentShare.reset()
    }

    // MARK: - Live transcript relay --------------------------------------------

    func configureTranscript(service: TranscriptRelayServiceProtocol?, userId: String, sessionId: String) {
        transcriptService = service; transcriptUserId = userId; transcriptSessionId = sessionId
        transcriptDiagnostics = TranscriptDiagnostics()
        transcriptStatusBeacons = 0
    }

    /// Main-call join only: a response without transcription fields (a room's
    /// meeting, an older server) or a service that cannot relay means no banner
    /// and no relay (fail closed; the summary falls back to the prompts).
    private func startTranscriptRelay(for response: ChimeJoinResponse) {
        guard let state = TranscriptJoinState(response), let service = transcriptService,
              !transcriptUserId.isEmpty, !transcriptSessionId.isEmpty else {
            transcriptionActive = false
            return
        }
        let relay = TranscriptRelay(service: service, userId: transcriptUserId,
                                    sessionId: transcriptSessionId, initial: state)
        relay.onStatus = { [weak self] active, _ in self?.transcriptionActive = active }
        transcriptRelay = relay
        // The call is optional-chained on the SDK protocol: nil means the SDK did
        // not accept the observer, which would explain a call with no events.
        let registered: Void? = meetingSession?.audioVideo.addRealtimeTranscriptEventObserver?(observer: self)
        transcriptDiagnostics.observerRegistered = registered != nil
        transcriptDiagnostics.joinActive = transcriptDiagnostics.joinActive || state.active
        transcriptDiagnostics.joinRelay = transcriptDiagnostics.joinRelay || state.relay
        relay.start()
    }

    /// Hands the relay to the caller (to flush and stop) and unhooks the SDK observer.
    /// Counts a Transcript event (main actor). `inputs` carry no text beyond what
    /// the relay itself needs; only counts are kept here.
    func recordTranscriptEvent(_ inputs: [TranscriptResultInput]) {
        transcriptDiagnostics.eventsReceived += 1
        transcriptDiagnostics.finalResults += inputs.filter { !$0.isPartial }.count
        if transcriptRelay?.isRelay != true { transcriptDiagnostics.eventsWhileNotRelay += 1 }
    }

    /// Counts a TranscriptionStatus event (main actor), logs it and sends a
    /// bounded number of beacons. Only the kind and a fixed reason class leave
    /// the device; the SDK's message text is never stored or sent.
    func recordTranscriptionStatus(_ kind: TranscriptionStatusKind, reason: String) {
        transcriptDiagnostics.record(status: kind, reason: reason)
        let name: String
        switch kind {
        case .started: name = "started"
        case .stopped: name = "stopped"
        case .failed: name = "failed"
        case .interrupted: name = "interrupted"
        case .resumed: name = "resumed"
        case .unknown: name = "unknown"
        }
        RefreshDiagnostics.transcriptionOutcome(stage: "status", summary: "status=\(name) reason=\(reason)")
        guard kind == .failed || kind == .interrupted || kind == .stopped || kind == .started,
              transcriptStatusBeacons < Self.maxStatusBeaconsPerCall else { return }
        transcriptStatusBeacons += 1
        (transcriptService as? NetworkService)?.reportTranscriptionDiagnostic(
            stage: "status", summary: "status=\(name) reason=\(reason)")
    }

    func detachTranscriptRelay() -> TranscriptRelay? {
        meetingSession?.audioVideo.removeRealtimeTranscriptEventObserver?(observer: self)
        let relay = transcriptRelay
        transcriptRelay = nil
        transcriptionActive = false
        relay?.onStatus = nil
        return relay
    }

    // MARK: - Screen share (sending) ------------------------------------------

    /// Prepares the receiver for the broadcast extension. Returns true when the
    /// caller should present the system broadcast picker now. All failures are
    /// fail-soft (warm notice, nothing left running).
    @discardableResult
    func beginScreenShare(flagEnabled: Bool) -> Bool {
        let block = ScreenShareState.startBlock(
            flagEnabled: flagEnabled, isConnected: isConnected,
            someoneElseSharing: contentShareTileId != nil && !sharerIsSelf,
            phase: screenShare.phase)
        if let block {
            if block == .someoneElseSharing { showScreenShareNotice(ScreenShareMessages.someoneElse) }
            return false
        }
        guard let av = meetingSession?.audioVideo else { return false }
        let coordinator = ChimeScreenShareCoordinator(audioVideo: av) { [weak self] event in
            self?.handleScreenShare(event)
        }
        do {
            try coordinator.beginListening()
        } catch ScreenShareFrameReceiver.StartError.unavailable {
            showScreenShareNotice(ScreenShareMessages.unavailableBuild)
            return false
        } catch {
            showScreenShareNotice(ScreenShareMessages.couldNotStart)
            return false
        }
        shareCoordinator = coordinator
        screenShare.requestStart()
        // The user may dismiss the picker without starting: don't wait forever.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.screenShare.awaitTimedOut() else { return }
            self.shareCoordinator?.stop(); self.shareCoordinator = nil
        }
        shareAwaitTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
        return true
    }

    /// One-tap stop (pill, submenu row, minimized bar). Idempotent.
    func stopScreenShare() { stopScreenShare(notify: false) }

    private func stopScreenShare(notify: Bool) {
        shareAwaitTimeout?.cancel(); shareAwaitTimeout = nil
        let coordinator = shareCoordinator
        shareCoordinator = nil
        coordinator?.stop()
        let wasLive = screenShare.ended()
        if notify && wasLive { showScreenShareNotice(ScreenShareMessages.ended) }
    }

    private func handleScreenShare(_ event: ScreenShareEvent) {
        guard shareCoordinator != nil else { return }   // stale callback after stop
        switch event {
        case .broadcastConnected:
            screenShare.broadcastConnected()
        case .shareStarted:
            shareAwaitTimeout?.cancel(); shareAwaitTimeout = nil
            screenShare.shareStarted()
        case .shareStopped(let failed):
            stopScreenShare(notify: false)
            showScreenShareNotice(failed ? ScreenShareMessages.failedMidShare : ScreenShareMessages.ended)
        case .broadcastEnded:
            stopScreenShare(notify: true)
        }
    }

    private func showScreenShareNotice(_ text: String) {
        screenShareNotice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.screenShareNotice == text { self?.screenShareNotice = nil }
        }
    }

    func bindTile(tileId: Int, view: VideoRenderView) {
        meetingSession?.audioVideo.bindVideoView(videoView: view, tileId: tileId)
    }

    // MARK: - Backgrounding (task 20260916-call-background-persistence)
    //
    // Audio deliberately keeps running while backgrounded (that's the whole
    // point of this task -- see Info.plist's new `audio` UIBackgroundModes
    // entry) so neither of these touches the audio session or tears down
    // `meetingSession`. Only video, which iOS forbids capturing while
    // backgrounded regardless of any background mode, is handled here.

    private var wasCameraOnBeforeBackground = false

    /// Called when the app backgrounds during an active call. Explicitly
    /// stopping local video is a clean, deliberate stop rather than leaving
    /// AVCaptureSession running for iOS to yank out from under Chime via its
    /// own capture-session interruption, which would leave `isCameraOn` true
    /// with no capture actually happening.
    func handleAppBackgrounded() {
        guard isCameraOn else { return }
        wasCameraOnBeforeBackground = true
        meetingSession?.audioVideo.stopLocalVideo()
        isCameraOn = false
    }

    /// Called on return to the foreground. Only resumes video if the call is
    /// still actually connected -- silently resuming into a call that
    /// dropped while backgrounded would paper over exactly the ambiguous
    /// connectivity state this task's fail-closed requirement (Security
    /// Posture Q14) says must surface instead, not hide.
    func handleAppForegrounded() {
        defer { wasCameraOnBeforeBackground = false }
        guard wasCameraOnBeforeBackground, isConnected, let av = meetingSession?.audioVideo else { return }
        do { try av.startLocalVideo(); isCameraOn = true }
        catch { print("Camera resume error: \(error.localizedDescription)") }
    }
}

// MARK: - AudioVideoObserver

extension ChimeCallManager: AudioVideoObserver {
    func audioSessionDidStartConnecting(reconnecting: Bool) {}
    func audioSessionDidStart(reconnecting: Bool) {
        DispatchQueue.main.async {
            self.isConnected = true
            // Now that Chime's audio session is up, route output to the loudspeaker
            // through the SDK (not AVAudioSession) so remote audio is audible while
            // the outgoing mic keeps working.
            if let speaker = self.meetingSession?.audioVideo.listAudioDevices()
                .first(where: { $0.type == .audioBuiltInSpeaker }) {
                self.meetingSession?.audioVideo.chooseAudioDevice(mediaDevice: speaker)
            }
            // Re-apply intent carried across a room switch (see switchMeeting).
            if self.isMuted { _ = self.meetingSession?.audioVideo.realtimeLocalMute() }
            if self.pendingCameraRestore {
                self.pendingCameraRestore = false
                if let av = self.meetingSession?.audioVideo {
                    do { try av.startLocalVideo(); self.isCameraOn = true }
                    catch { print("Camera resume error: \(error.localizedDescription)") }
                }
            }
        }
    }
    // Task 20260916-call-background-persistence, Security Posture Q14
    // (fail-closed under ambiguity): these two used to be no-ops, which left
    // `isConnected` -- and therefore the "Connected" UI in callHeader/
    // waitingPlaceholder -- stuck showing stale success through an actual
    // audio drop or a reconnect attempt Chime itself gave up on. Both now
    // flip `isConnected` false immediately; `audioSessionDidStart(reconnecting:
    // true)` above already flips it back true if Chime does recover.
    func audioSessionDidDrop() {
        DispatchQueue.main.async { self.isConnected = false }
    }
    func audioSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {
        DispatchQueue.main.async { self.isConnected = false }
    }
    func videoSessionDidStartConnecting() {}
    func videoSessionDidStartWithStatus(sessionStatus: MeetingSessionStatus) {}
    func videoSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {}
    func audioSessionDidCancelReconnect() {
        DispatchQueue.main.async { self.isConnected = false }
    }
    // Added in newer AmazonChimeSDK — no-op implementations satisfy the protocol.
    func connectionDidRecover() {}
    func connectionDidBecomePoor() {}
    func cameraSendAvailabilityDidChange(available: Bool) {}
    func remoteVideoSourcesDidBecomeAvailable(sources: [RemoteVideoSource]) {}
    func remoteVideoSourcesDidBecomeUnavailable(sources: [RemoteVideoSource]) {}
}

// MARK: - VideoTileObserver

extension ChimeCallManager: VideoTileObserver {
    func videoTileDidAdd(tileState: VideoTileState) {
        let id = tileState.tileId; let isLocal = tileState.isLocalTile
        let isContent = tileState.isContent; let attendeeId = tileState.attendeeId
        DispatchQueue.main.async {
            // A content share is never a camera bubble (task 20261009-session-ui-redesign).
            if isContent { self.contentShare.tileAdded(tileId: id, attendeeId: attendeeId); return }
            if isLocal { self.localTileId = id }
            else {
                self.tileAttendeeIds[id] = attendeeId
                if !self.remoteTileIds.contains(id) { self.remoteTileIds.append(id) }
            }
        }
    }
    func videoTileDidRemove(tileState: VideoTileState) {
        let id = tileState.tileId; let isLocal = tileState.isLocalTile
        DispatchQueue.main.async {
            self.meetingSession?.audioVideo.unbindVideoView(tileId: id)
            if self.contentShare.tileId == id { self.contentShare.tileRemoved(tileId: id); return }
            if isLocal { self.localTileId = nil }
            else { self.remoteTileIds.removeAll { $0 == id }; self.tileAttendeeIds[id] = nil }
        }
    }
    // Added in newer AmazonChimeSDK — no-op implementations satisfy the protocol.
    func videoTileDidPause(tileState: VideoTileState) {}
    func videoTileDidResume(tileState: VideoTileState) {}
    func videoTileSizeDidChange(tileState: VideoTileState) {}
}

// MARK: - RealtimeObserver (roster / who's in the call)

extension ChimeCallManager: RealtimeObserver {
    func attendeesDidJoin(attendeeInfo: [AttendeeInfo]) {
        DispatchQueue.main.async {
            for a in attendeeInfo where a.attendeeId != self.myAttendeeId
                && !ContentShareAttendee.isContent(a.attendeeId) {
                self.externalUserIds[a.attendeeId] = a.externalUserId
                if !self.remoteAttendeeIds.contains(a.attendeeId) {
                    self.remoteAttendeeIds.append(a.attendeeId)
                }
            }
        }
    }
    func attendeesDidLeave(attendeeInfo: [AttendeeInfo]) {
        let ids = Set(attendeeInfo.map { $0.attendeeId })
        DispatchQueue.main.async { self.remoteAttendeeIds.removeAll { ids.contains($0) } }
    }
    func attendeesDidDrop(attendeeInfo: [AttendeeInfo]) { attendeesDidLeave(attendeeInfo: attendeeInfo) }
    func attendeesDidMute(attendeeInfo: [AttendeeInfo]) {}
    func attendeesDidUnmute(attendeeInfo: [AttendeeInfo]) {}
    func volumeDidChange(volumeUpdates: [VolumeUpdate]) {}
    func signalStrengthDidChange(signalUpdates: [SignalUpdate]) {}
}

// MARK: - TranscriptEventObserver (live transcript relay)
// Callbacks arrive on SDK threads: only value types leave this method, and no
// transcript text is logged. Every client receives events; the relay object
// ignores them unless this client is the server-designated relay.

extension ChimeCallManager: TranscriptEventObserver {
    func transcriptEventDidReceive(transcriptEvent: TranscriptEvent) {
        if let status = transcriptEvent as? TranscriptionStatus {
            // Only the type and a fixed reason class leave this method.
            let kind = Self.statusKind(status.type)
            let reason = TranscriptDiagnostics.reasonClass(status.message)
            DispatchQueue.main.async { [weak self] in self?.recordTranscriptionStatus(kind, reason: reason) }
            return
        }
        guard let transcript = transcriptEvent as? Transcript else { return }
        let inputs = transcript.results.map { r -> TranscriptResultInput in
            let alt = r.alternatives.first
            let speaker = alt?.items.first(where: { !$0.attendee.externalUserId.isEmpty })?.attendee.externalUserId
            return TranscriptResultInput(isPartial: r.isPartial, text: alt?.transcript ?? "", speakerId: speaker)
        }
        DispatchQueue.main.async { [weak self] in
            self?.recordTranscriptEvent(inputs)
            self?.transcriptRelay?.handle(inputs)
        }
    }

    private static func statusKind(_ type: TranscriptionStatusType) -> TranscriptionStatusKind {
        switch type {
        case .started:     return .started
        case .stopped:     return .stopped
        case .failed:      return .failed
        case .interrupted: return .interrupted
        case .resumed:     return .resumed
        default:           return .unknown
        }
    }
}

// MARK: - Video tile UIViewRepresentable

struct ChimeVideoTileView: UIViewRepresentable {
    let tileId:  Int
    let manager: ChimeCallManager
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> DefaultVideoRenderView {
        let v = DefaultVideoRenderView(); v.contentMode = contentMode; return v
    }
    func updateUIView(_ uiView: DefaultVideoRenderView, context: Context) {
        manager.bindTile(tileId: tileId, view: uiView)
    }
}

// MARK: - ChimeCallView

struct ChimeCallView: View {
    @ObservedObject private var call    = CallController.shared
    @ObservedObject var manager = CallController.shared.manager
    // Task 20261009-discussion-rooms: room-switch state (see CallRoomController).
    @ObservedObject private var rooms   = CallController.shared.rooms
    @Environment(\.fsCapabilities) private var capabilities
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Task 20260916-call-ring-members: presents RingMembersSheet (see
    // RingMembersSheet.swift), the member picker + multi-select ring action
    // this design spec's §2 describes.
    @State private var showRingSheet = false
    @State private var showRoomsSheet = false
    // Task 20261009-session-ui-redesign: submenu + prompts-panel state, names, and
    // on-screen tracking for the breathing background.
    @State private var interactions = CallInteractionsState()
    @State private var onScreen = true
    // Step 5: bumped to present the system broadcast picker (see BroadcastPickerLauncher).
    @State private var pickerTrigger = 0
    @StateObject var names = CallParticipantNames()
    // Task 20261016-call-maximize-tiles: the enlarged tile (local only, see ChimeCallView+Focus.swift).
    @State var focus: CallFocus?
    @ScaledMetric(relativeTo: .body) private var dockScale: CGFloat = 64

    let layoutSpring = Animation.spring(response: 0.45, dampingFraction: 0.86)

    var body: some View {
        ZStack {
            CallBreathingBackground(isVisible: call.isExpanded && onScreen)
            if let error = call.joinError ?? manager.startError {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44, weight: .light)).foregroundColor(.orange)
                    Text(error).foregroundColor(.white.opacity(0.75)).font(.inter(Theme.fontSM))
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                    HStack(spacing: 16) {
                        Button("Minimize") { call.minimize() }.foregroundColor(Theme.gold).font(.inter(Theme.fontBody))
                        Button("End Call") { call.end() }.foregroundColor(Theme.error).font(.inter(Theme.fontBody))
                    }
                }
            } else {
                callActiveBody
            }
        }
        .background(BroadcastPickerLauncher(trigger: pickerTrigger).frame(width: 1, height: 1).allowsHitTesting(false))
        .onAppear { onScreen = true; resolveNames() }
        .onDisappear { onScreen = false }
        .onReceive(manager.$externalUserIds) { _ in resolveNames() }
        .onReceive(rooms.$seedNames) { names.seed($0) }
        .onChange(of: manager.contentShareTileId) { old, new in
            // Announce share start/stop to VoiceOver.
            let who = manager.sharerIsSelf ? "You" : (sharerName ?? "Someone")
            if old == nil, new != nil { AccessibilityNotification.Announcement("\(who) started sharing").post() }
            // An enlarged share announces its own warm "stopped sharing" line instead.
            if old != nil, new == nil, focus?.tile != .share { AccessibilityNotification.Announcement("Sharing stopped").post() }
        }
        .onChange(of: activeFocus) { _, _ in reconcileFocus() }
        // Room switches and leaving the screen clear the enlarged tile silently.
        .onChange(of: rooms.state) { _, _ in focus = nil }
        .onDisappear { focus = nil }
        .sheet(isPresented: $showRingSheet) {
            if let session = call.session, let service = call.service {
                RingMembersSheet(session: session, service: service, userId: call.userId)
            }
        }
        .sheet(isPresented: $showRoomsSheet) {
            if let session = call.session {
                RoomsSheet(session: session, rooms: rooms, userId: call.userId, service: call.service)
            }
        }
    }

    // MARK: Derived state

    var layoutMode: CallLayoutMode {
        CallLayoutState.mode(promptsOpen: interactions.promptsOpen, contentShareTileId: manager.contentShareTileId)
    }

    private var contentKind: CallContentKind {
        CallLayoutState.contentKind(promptsOpen: interactions.promptsOpen, contentShareTileId: manager.contentShareTileId)
    }

    var bubbleItems: [CallBubbleItem] {
        CallBubbleRoster.items(
            localTileId: manager.localTileId, cameraOn: manager.isCameraOn,
            remoteTileIds: manager.remoteTileIds, tileAttendee: manager.tileAttendeeIds,
            remoteAttendeeIds: manager.remoteAttendeeIds, externalUserIds: manager.externalUserIds,
            names: names.names)
    }

    private func displayName(forTile tile: Int) -> String? {
        manager.tileAttendeeIds[tile].flatMap { manager.externalUserIds[$0] }.flatMap { names.names[$0] }
    }

    var sharerName: String? {
        manager.contentShare.sharerAttendeeId
            .flatMap { manager.externalUserIds[$0] }.flatMap { names.names[$0] }
    }

    private func resolveNames() {
        names.resolve(ids: Array(manager.externalUserIds.values), service: call.service, selfId: call.userId)
    }

    // MARK: Layout

    private var callActiveBody: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let compact = geo.size.height <= 667
            let dockSize = min(compact ? dockScale * 56 / 64 : dockScale, 80)
            let dockZone = dockSize + 32 + 12 + 16   // dock + padding + bottom gap + breathing room

            ZStack(alignment: .bottom) {
                Group {
                    if showsFieldLayout {
                        fieldLayout(geo: geo, dockZone: dockZone)
                            .transition(.opacity)
                    } else {
                        rowLayout(geo: geo, landscape: landscape, compact: compact, dockZone: dockZone)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .motionAwareAnimation(reduceMotion ? .easeInOut(duration: 0.15) : layoutSpring,
                                      value: showsFieldLayout, reduceMotion: false)

                dockStack(geo: geo, dockSize: dockSize, compact: compact)
            }
        }
    }

    private func fieldLayout(geo: GeometryProxy, dockZone: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if !manager.remoteTileIds.isEmpty {
                    RemoteCameraField(manager: manager, containerSize: geo.size,
                                      nameForTile: { displayName(forTile: $0) },
                                      onEnlarge: { focusCamera(id: "tile-\($0)") })
                } else if !manager.remoteAttendeeIds.isEmpty {
                    audioParticipantsView
                } else {
                    waitingPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if manager.isCameraOn, let localId = manager.localTileId {
                // Self-PiP stays its own fixed, non-randomized element (design-notes.md
                // §2) -- raised to clear the new dock.
                Button { focusCamera(id: "self") } label: {
                    ChimeVideoTileView(tileId: localId, manager: manager)
                        .frame(width: 96, height: 128)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 96, height: 128)
                    .background(Theme.bgPage.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold.opacity(0.40), lineWidth: 1))
                    .shadow(color: .black.opacity(0.60), radius: 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 16).padding(.bottom, dockZone + 8)
                    .accessibilityLabel("You, video on")
                    .accessibilityHint(CallFocusLogic.enlargeHint)
            }
            VStack { headerStack(topPadding: 56); Spacer() }
        }
    }

    private func rowLayout(geo: GeometryProxy, landscape: Bool, compact: Bool, dockZone: CGFloat) -> some View {
        let bubbleDiameter: CGFloat = compact ? 56 : 72
        let contentArea = CallContentArea(
            kind: contentKind, prompts: CallPromptsSource.prompts(from: call.session),
            shareTileId: manager.contentShareTileId, sharerName: sharerName, manager: manager,
            sharerIsSelf: manager.sharerIsSelf, onStopSharing: { manager.stopScreenShare() },
            onEnlargeShare: { focusShare() },
            isCompact: compact, onClosePrompts: { withMotionAwareAnimation(layoutSpring, reduceMotion: reduceMotion) { interactions.closePrompts() } },
            inheritedNote: rooms.state.showsBackToMain ? "From the main session" : nil)
        return VStack(spacing: 0) {
            headerStack(topPadding: compact || landscape ? 16 : 56)
            if landscape {
                HStack(alignment: .top, spacing: 12) {
                    bubbleStrip(diameter: bubbleDiameter, vertical: true)
                        .frame(width: max(geo.size.width * 0.30, bubbleDiameter + 40))
                    contentOrFocus(contentArea).padding(.trailing, 16)
                }
                .padding(.leading, 16)
                .padding(.bottom, dockZone)
            } else {
                if showsPortraitStrip(height: geo.size.height, diameter: bubbleDiameter, compact: compact, dockZone: dockZone) {
                    bubbleStrip(diameter: bubbleDiameter, vertical: false)
                        .padding(.vertical, 4)
                }
                contentOrFocus(contentArea)
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, dockZone)
            }
        }
    }

    // MARK: Dock + submenu

    private func dockStack(geo: GeometryProxy, dockSize: CGFloat, compact: Bool) -> some View {
        ZStack(alignment: .bottom) {
            if interactions.isExpanded {
                // Invisible scrim: outside tap dismisses the menu without dimming.
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { setMenu(expanded: false) }
                    .accessibilityHidden(true)
            }
            VStack(spacing: 12) {
                if interactions.isExpanded {
                    // Compact popover: trailing edge aligned with the ellipsis button
                    // (right button of the centered dock), small gap above the dock.
                    CallSubmenu(rows: menuRows(), isCompact: compact,
                                maxHeight: geo.size.height * (dynamicTypeSize.isAccessibilitySize ? 0.55 : 0.70),
                                onEscape: { setMenu(expanded: false) })
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, max((geo.size.width - CallDock.width(buttonSize: dockSize)) / 2 + CallDock.padding, 16))
                        // Reduce Motion: opacity only. Otherwise a short eased pop from the ellipsis corner.
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
                }
                CallDock(isMuted: manager.isMuted, isExpanded: interactions.isExpanded, buttonSize: dockSize,
                         onEnd: { call.end() },
                         onToggleMenu: { setMenu(expanded: !interactions.isExpanded) },
                         endHint: rooms.state.showsBackToMain ? "Leaves the room and the session" : "Leaves the session")
            }
            .padding(.bottom, 12)
        }
    }

    private func setMenu(expanded: Bool) {
        withMotionAwareAnimation(.easeOut(duration: 0.2), reduceMotion: reduceMotion) {
            interactions.isExpanded = expanded
        }
    }

    /// Share screen row in the popover; gated by the screen_share_enabled flag.
    private static let showsShareRow = true

    private func shareMenuRow() -> CallMenuRow? {
        // The row stays reachable while a share is active even if the server flag
        // flips off mid-call: stopping must always be possible.
        if ScreenShareFlag.isEnabled(capabilities) || manager.screenShare.isActive {
            let someoneElse = manager.contentShareTileId != nil && !manager.sharerIsSelf
            let phase = manager.screenShare.phase
            if phase == .sharing {
                return CallMenuRow(
                    id: "share", icon: "rectangle.on.rectangle.slash", title: "Stop sharing",
                    tint: Theme.error.opacity(0.45),
                    a11yLabel: "Stop sharing your screen",
                    action: { interactions.didTapActionItem(); manager.stopScreenShare() })
            } else if phase != .idle {
                return CallMenuRow(
                    id: "share", icon: "rectangle.on.rectangle", title: "Share screen",
                    caption: "Starting\u{2026}", enabled: false,
                    a11yLabel: "Share screen", a11yValue: "Starting",
                    action: { interactions.didTapActionItem() })
            } else {
                return CallMenuRow(
                    id: "share", icon: "rectangle.on.rectangle", title: "Share screen",
                    caption: someoneElse ? "\(sharerName ?? "Someone") is sharing" : nil,
                    enabled: ScreenShareFlag.sendingImplemented && !someoneElse && manager.isConnected,
                    a11yLabel: "Share screen",
                    a11yValue: someoneElse ? "\(sharerName ?? "Someone") is sharing" : nil,
                    a11yHint: "Shares your whole screen with everyone in the call",
                    action: {
                        interactions.didTapActionItem()
                        if manager.beginScreenShare(flagEnabled: ScreenShareFlag.isEnabled(capabilities)) {
                            pickerTrigger += 1
                        }
                    })
            }
        }
        return nil
    }

    /// Rooms row gate: server flag on AND not a DM session (fail-closed).
    private var roomsAvailable: Bool { RoomsFlag.isAvailable(capabilities, session: call.session) }

    /// "Back to main" is reachable whenever the user is away from main, even if
    /// the server flag flipped off mid-call: exits must always be reachable.
    private func backToMainRow() -> CallMenuRow? {
        guard rooms.state.showsBackToMain else { return nil }
        let name = rooms.state.currentRoomName ?? "the room"
        return CallMenuRow(
            id: "back-to-main", icon: "arrow.uturn.backward", title: "Back to main",
            caption: "Leaves \(name)", tint: Theme.goldDim.opacity(0.35),
            enabled: { if case .returning = rooms.state { return false } else { return true } }(),
            a11yLabel: "Back to main session", a11yHint: "Leaves \(name) and returns to the main audio",
            action: { interactions.didTapActionItem(); Task { await rooms.returnToMain() } })
    }

    private func roomsMenuRow() -> CallMenuRow? {
        guard roomsAvailable || rooms.state.showsBackToMain else { return nil }
        let inRoom = rooms.state.showsBackToMain
        let roomName = rooms.state.currentRoomName
        let ready = manager.isConnected || inRoom
        return CallMenuRow(
            id: "rooms", icon: "person.2.wave.2.fill", title: "Rooms",
            caption: inRoom ? "In \(roomName ?? "a room")" : (ready ? nil : "Connecting\u{2026}"),
            tint: inRoom ? Theme.gold.opacity(0.55) : Theme.goldDim.opacity(0.35),
            enabled: ready,
            a11yLabel: "Rooms", a11yValue: inRoom ? "In \(roomName ?? "a room")" : "Not in a room",
            a11yHint: "Opens the list of discussion rooms",
            action: { interactions.didTapActionItem(); showRoomsSheet = true })
    }

    private func menuRows() -> [CallMenuRow] {
        var rows: [CallMenuRow] = []
        if let back = backToMainRow() { rows.append(back) }
        if canRing {
            rows.append(CallMenuRow(
                id: "ring", icon: "bell", title: "Ring", a11yLabel: "Ring members",
                a11yHint: "Invites members to join the call",
                action: { interactions.didTapActionItem(); showRingSheet = true }))
        }
        // Rooms sits between Ring and Share (design-notes.md section 1). Screen
        // share is intentionally out of the menu for now; its row logic and flag
        // gating below are kept so re-enabling is a one-constant change.
        if let roomsRow = roomsMenuRow() { rows.append(roomsRow) }
        if Self.showsShareRow, let share = shareMenuRow() { rows.append(share) }
        rows.append(CallMenuRow(
            id: "prompts", icon: "text.bubble", title: "Prompts",
            tint: interactions.promptsOpen ? Theme.gold.opacity(0.55) : Theme.goldDim.opacity(0.35),
            a11yLabel: "Discussion prompts", a11yValue: interactions.promptsOpen ? "Showing" : "Hidden",
            a11yHint: "Shows the session's discussion prompts on your screen",
            action: { withMotionAwareAnimation(layoutSpring, reduceMotion: reduceMotion) { interactions.didTapPrompts() } }))
        rows.append(CallMenuRow(
            id: "camera", icon: manager.isCameraOn ? "video.fill" : "video.slash.fill",
            title: manager.isCameraOn ? "Camera on" : "Camera off",
            a11yLabel: "Camera", a11yValue: manager.isCameraOn ? "On" : "Off",
            a11yHint: "Toggles your camera",
            action: { interactions.didTapToggleItem(); manager.toggleCamera() }))
        rows.append(CallMenuRow(
            id: "mute", icon: manager.isMuted ? "mic.slash.fill" : "mic.fill",
            title: manager.isMuted ? "Unmute" : "Mute",
            tint: manager.isMuted ? Theme.error.opacity(0.45) : Theme.goldDim.opacity(0.35),
            a11yLabel: "Microphone", a11yValue: manager.isMuted ? "Muted" : "On",
            a11yHint: "Toggles your microphone",
            action: { interactions.didTapToggleItem(); manager.toggleMute() }))
        return rows
    }

    private var waitingPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: manager.isConnected ? "person.crop.circle.badge.clock" : "wifi")
                .font(.system(size: 52, weight: .ultraLight)).foregroundColor(Theme.textPrimary.opacity(0.30))
            Text(!manager.isConnected ? "Connecting…"
                 : (rooms.state.isInRoom ? "You\u{2019}re the first one here. Others can join from Rooms."
                                         : "Waiting for others to join…"))
                .foregroundColor(Theme.textPrimary.opacity(0.85)).font(.inter(Theme.fontSM))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Others are connected with audio but no camera. With resolved names we show
    // initial bubbles; otherwise the original waveform presence view is the fallback.
    @ViewBuilder
    private var audioParticipantsView: some View {
        let others = bubbleItems.filter { if case .audioOnly = $0.kind { return true } else { return false } }
        if others.contains(where: { $0.name != nil }) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16)], spacing: 16) {
                    ForEach(others) { CallBubbleView(item: $0, diameter: 84, manager: manager) }
                }
                .padding(.horizontal, 24).padding(.top, 140).padding(.bottom, 150)
            }
        } else {
            let count = manager.remoteAttendeeIds.count
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.14)).frame(width: 96, height: 96)
                    Image(systemName: "waveform").font(.system(size: 40, weight: .light)).foregroundColor(Theme.gold)
                }
                Text(count == 1 ? "1 person connected" : "\(count) people connected")
                    .foregroundColor(Theme.textPrimary).font(.inter(Theme.fontBody))
                Text("Audio call in progress")
                    .foregroundColor(Theme.textPrimary.opacity(0.85)).font(.inter(Theme.fontXS))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func callHeader(topPadding: CGFloat) -> some View {
        HStack(spacing: 12) {
            // Minimize — keep the call running and return to the app.
            Button { call.minimize() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.14)).clipShape(Circle())
            }
            .accessibilityLabel("Minimize call")

            VStack(alignment: .leading, spacing: 3) {
                Text(rooms.state.currentRoomName ?? call.session?.title ?? "Study Session")
                    .font(.inter(Theme.fontBody, weight: .semibold)).foregroundColor(Theme.textPrimary)
                if let sub = roomSubline {
                    Text(sub)
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textPrimary.opacity(0.85))
                        .lineLimit(1).truncationMode(.tail)
                        .accessibilityLabel(roomSublineA11y)
                }
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle().fill(headerConnected ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(headerConnectionText)
                            .font(.inter(Theme.fontXS)).foregroundColor(Theme.textPrimary.opacity(0.85))
                    }
                    if manager.isMuted {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.slash.fill").font(.system(size: 10))
                            Text("Muted").font(.inter(Theme.fontXS, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.error.opacity(0.85)))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Muted")
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, topPadding).padding(.bottom, 16)
        .background(LinearGradient(colors: [Theme.bgPage.opacity(0.80), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var headerConnected: Bool {
        if case .returnFailed = rooms.state { return false }
        return manager.isConnected
    }

    private var headerConnectionText: String {
        if case .returnFailed = rooms.state { return "Reconnecting…" }
        return manager.isConnected ? "Connected" : "Connecting…"
    }

    private var roomSubline: String? {
        if case .joining(_, let name) = rooms.state { return "Joining \(name)\u{2026}" }
        if rooms.state.showsBackToMain { return "In room \u{00B7} \(call.session?.title ?? "Session")" }
        return nil
    }

    private var roomSublineA11y: String {
        if case .joining(_, let name) = rooms.state { return "Joining \(name)" }
        return "In room \(rooms.state.currentRoomName ?? ""), session \(call.session?.title ?? "")"
    }

    /// Header plus the pinned "Sharing your screen" pill (design-notes.md section 5)
    /// and the fail-soft notice, so every layout shows them identically.
    private func headerStack(topPadding: CGFloat) -> some View {
        VStack(spacing: 0) {
            callHeader(topPadding: topPadding)
            OutgoingRingBanner(tracker: call.ring, onLeave: { call.end() })
            if manager.screenShare.showsIndicator {
                ScreenSharePill(onStop: { manager.stopScreenShare() })
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
            }
            if let notice = manager.screenShareNotice {
                ScreenShareNotice(text: notice).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
            }
            // Task 20261013-session-call-live-transcript-summary: persistent
            // consent banner for everyone while the main call is transcribed.
            if manager.transcriptionActive {
                TranscriptConsentBanner().padding(.bottom, 8)
                    .padding(.horizontal, 20)
            }
            // Task 20261009-discussion-rooms: Back to main pill, notices, return-failed card.
            if rooms.state.showsBackToMain {
                BackToMainPill(isReturning: { if case .returning = rooms.state { return true } else { return false } }(),
                               roomName: rooms.state.currentRoomName ?? "the room",
                               onTap: { Task { await rooms.returnToMain() } })
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            if case .returnFailed = rooms.state {
                RoomReturnFailedCard(onRetry: { Task { await rooms.returnToMain() } }, onEnd: { call.end() })
                    .padding(.bottom, 8).padding(.horizontal, 20)
            }
            if let notice = rooms.notice {
                ScreenShareNotice(text: notice).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
            }
            if rooms.state.isInRoom {
                // Subtle in-room cue without new colors: a 2pt goldLight hairline
                // directly above the participant bubbles.
                Rectangle().fill(Theme.goldLight).frame(height: 2)
                    .padding(.horizontal, 20).padding(.bottom, 6)
                    .accessibilityHidden(true)
            }
        }
    }

    // Task 20260916-call-ring-members, design-notes.md §1: the only
    // client-side precondition gating the Ring button itself -- a DM
    // session's own two-id "|" key always has exactly one other member
    // (is_authorized/resolve_members never permit fewer), so this only ever
    // disables the genuinely member-less edge case (e.g. a stale/malformed
    // DM key). A real group with zero *other* current members is rarer and
    // left to RingMembersSheet's own "No other members to ring." empty
    // state (§2) rather than requiring a roster prefetch just to gate one
    // button -- design-notes.md explicitly anticipates that fallback path.
    private var canRing: Bool {
        guard let session = call.session, !session.group_id.isEmpty else { return false }
        if session.group_id.contains("|") {
            return Set(session.group_id.split(separator: "|")).count > 1
        }
        return true
    }
}

#else

// MARK: - Stub (AmazonChimeSDK not installed) ─────────────────────────────────

struct ChimeCallView: View {
    @ObservedObject private var call = CallController.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "video.slash")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundColor(.white.opacity(0.28))
                Text("Live calls require the Amazon Chime SDK.")
                    .foregroundColor(.white.opacity(0.65))
                    .font(.inter(Theme.fontSM))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Close") { call.end() }
                    .foregroundColor(Theme.gold)
                    .font(.inter(Theme.fontBody))
                    .padding(.top, 8)
            }
        }
    }
}

#endif
