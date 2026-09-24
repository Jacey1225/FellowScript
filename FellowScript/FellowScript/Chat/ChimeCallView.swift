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
        #if canImport(AmazonChimeSDK)
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

        #if canImport(AmazonChimeSDK)
        manager.leave()
        #endif
        session = nil; isExpanded = false; joinError = nil
        service = nil; userId = ""
        sentRingTargets = []

        maybeSummarize(session: endingSession, service: endingService, userId: endingUserId)
    }

    // Fire-and-forget: kicked off only after the synchronous teardown above
    // has already completed, so a slow or failing summarize call can never
    // block/delay leaving the call. Only the session's *creator* triggers a
    // summary -- a group call has no per-session uniqueness constraint on the
    // notes table, so letting every participant's own call.end() summarize
    // independently would mint one duplicate "Session Summary — {title}"
    // note per participant still on the call when it ends.
    private func maybeSummarize(session: FSSession?, service: DataServiceProtocol?, userId: String) {
        guard let session, session.summarize, let service, !userId.isEmpty,
              !session.creator_id.isEmpty, session.creator_id == userId else { return }
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
                try await service.summarizeSession(userId: userId, agentId: agentId,
                                                    session: session, groupId: session.group_id)
            } catch {
                RefreshDiagnostics.summarizeOutcome(stage: stage, errorClass: Self.summarizeErrorClass(error))
                self.showSummarizeNotice(
                    "We couldn't put together your session summary this time — check back in your notes in a bit."
                )
            }
        }
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
                        Text("Tap to return to call")
                            .font(.inter(Theme.fontXXS)).foregroundColor(.white.opacity(0.60))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return to call \(call.session?.title ?? "")")

            Spacer(minLength: 8)

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

    private var meetingSession: DefaultMeetingSession?
    private var myAttendeeId:   String = ""

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
        meetingSession?.audioVideo.stop()
        meetingSession = nil
        isConnected = false; isMuted = false; isCameraOn = false
        localTileId = nil;   remoteTileIds = []; remoteAttendeeIds = []
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
        DispatchQueue.main.async {
            if isLocal { self.localTileId = id }
            else if !self.remoteTileIds.contains(id) { self.remoteTileIds.append(id) }
        }
    }
    func videoTileDidRemove(tileState: VideoTileState) {
        let id = tileState.tileId; let isLocal = tileState.isLocalTile
        DispatchQueue.main.async {
            self.meetingSession?.audioVideo.unbindVideoView(tileId: id)
            if isLocal { self.localTileId = nil }
            else { self.remoteTileIds.removeAll { $0 == id } }
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
                && !self.remoteAttendeeIds.contains(a.attendeeId) {
                self.remoteAttendeeIds.append(a.attendeeId)
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

// MARK: - Video tile UIViewRepresentable

struct ChimeVideoTileView: UIViewRepresentable {
    let tileId:  Int
    let manager: ChimeCallManager

    func makeUIView(context: Context) -> DefaultVideoRenderView {
        let v = DefaultVideoRenderView(); v.contentMode = .scaleAspectFill; return v
    }
    func updateUIView(_ uiView: DefaultVideoRenderView, context: Context) {
        manager.bindTile(tileId: tileId, view: uiView)
    }
}

// MARK: - ChimeCallView

struct ChimeCallView: View {
    @ObservedObject private var call    = CallController.shared
    @ObservedObject private var manager = CallController.shared.manager
    // Task 20260916-call-ring-members: presents RingMembersSheet (see
    // RingMembersSheet.swift), the member picker + multi-select ring action
    // this design spec's §2 describes.
    @State private var showRingSheet = false

    var body: some View {
        ZStack {
            chimeBackground
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
        .sheet(isPresented: $showRingSheet) {
            if let session = call.session, let service = call.service {
                RingMembersSheet(session: session, service: service, userId: call.userId)
            }
        }
    }

    private var callActiveBody: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Group {
                    if !manager.remoteTileIds.isEmpty {
                        RemoteCameraField(manager: manager, containerSize: geo.size)
                    } else if !manager.remoteAttendeeIds.isEmpty {
                        audioParticipantsView
                    } else {
                        waitingPlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if manager.isCameraOn, let localId = manager.localTileId {
                    // Self-PiP stays its own fixed, non-randomized element (design-notes.md
                    // §2) -- only its fill changes, from flat black to the same glass tokens
                    // as the new backdrop, so it doesn't read as a leftover flat-black chip
                    // floating over the translucent field. Size/position/border/shadow unchanged.
                    ChimeVideoTileView(tileId: localId, manager: manager)
                        .frame(width: 96, height: 128)
                        .background(Theme.bgPage.opacity(0.34))
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold.opacity(0.40), lineWidth: 1))
                        .shadow(color: .black.opacity(0.60), radius: 8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 16).padding(.bottom, 152)
                }
                VStack { callHeader; Spacer() }
                controlBar
            }
        }
    }

    // Call-screen background (design-notes.md §1): a genuine `.ultraThinMaterial`
    // blur, extending the same native-blur family already used by
    // `DashboardComponents.glassCard` and `Theme.panelGlassTint` -- Ember Glass's
    // "drop native blur" decision (task 20260827-ember-glass-chat-rewrite) was
    // explicitly scoped to Chat surfaces ("Chat had zero native blur to begin
    // with"), not codebase-wide, so this isn't an exception to that precedent.
    // Built entirely from existing tokens/literals: `Theme.bgPage` as the warm
    // dark base, plus the exact gold-glow radial-gradient recipe already used by
    // `warmBloomBackground()` in Theme.swift (re-centered for a full-bleed call
    // screen rather than that helper's sheet-tuned geometry), so the "glow"
    // reads as on-brand gold bloom rather than the reference images' literal
    // rainbow palette.
    private var chimeBackground: some View {
        ZStack {
            Theme.bgPage
            RadialGradient(colors: [Theme.gold.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.18, y: 0.20), startRadius: 10, endRadius: 420)
            // "#B8761D" is the same literal warmBloomBackground() already uses for its
            // second gradient stop -- no Theme constant names it, so it's repeated here
            // rather than introducing a new color.
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.10), .clear],
                           center: UnitPoint(x: 0.85, y: 0.75), startRadius: 10, endRadius: 380)
        }
        .overlay(.ultraThinMaterial)
        .overlay(Theme.bgPage.opacity(0.34))
        .ignoresSafeArea()
    }

    private var waitingPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: manager.isConnected ? "person.crop.circle.badge.clock" : "wifi")
                .font(.system(size: 52, weight: .ultraLight)).foregroundColor(.white.opacity(0.22))
            Text(manager.isConnected ? "Waiting for others to join…" : "Connecting…")
                .foregroundColor(.white.opacity(0.42)).font(.inter(Theme.fontSM))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Others are connected with audio but no camera — show a simple presence view.
    private var audioParticipantsView: some View {
        let count = manager.remoteAttendeeIds.count
        return VStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.14)).frame(width: 96, height: 96)
                Image(systemName: "waveform").font(.system(size: 40, weight: .light)).foregroundColor(Theme.gold)
            }
            Text(count == 1 ? "1 person connected" : "\(count) people connected")
                .foregroundColor(.white.opacity(0.80)).font(.inter(Theme.fontBody))
            Text("Audio call in progress")
                .foregroundColor(.white.opacity(0.42)).font(.inter(Theme.fontXS))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var callHeader: some View {
        HStack(spacing: 12) {
            // Minimize — keep the call running and return to the app.
            Button { call.minimize() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14)).clipShape(Circle())
            }
            .accessibilityLabel("Minimize call")

            VStack(alignment: .leading, spacing: 3) {
                Text(call.session?.title ?? "Study Session")
                    .font(.inter(Theme.fontBody, weight: .semibold)).foregroundColor(.white)
                HStack(spacing: 5) {
                    Circle().fill(manager.isConnected ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(manager.isConnected ? "Connected" : "Connecting…")
                        .font(.inter(Theme.fontXS)).foregroundColor(.white.opacity(0.52))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 56).padding(.bottom, 16)
        .background(LinearGradient(colors: [.black.opacity(0.80), .clear], startPoint: .top, endPoint: .bottom))
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

    private var controlBar: some View {
        HStack(spacing: 28) {
            callButton(icon: "bell.fill", label: "Ring", active: true) { showRingSheet = true }
                .disabled(!canRing)
                .opacity(canRing ? 1 : 0.35)
            callButton(icon: manager.isMuted ? "mic.slash.fill" : "mic.fill",
                       label: manager.isMuted ? "Unmute" : "Mute",
                       active: !manager.isMuted) { manager.toggleMute() }
            callButton(icon: manager.isCameraOn ? "video.fill" : "video.slash.fill",
                       label: manager.isCameraOn ? "Camera" : "Camera Off",
                       active: manager.isCameraOn) { manager.toggleCamera() }
            Button { call.end() } label: {
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(Color.red).frame(width: 62, height: 62)
                        Image(systemName: "phone.down.fill").font(.system(size: 24)).foregroundColor(.white)
                    }
                    Text("End").font(.inter(Theme.fontXS)).foregroundColor(.white.opacity(0.65))
                }
            }
            .accessibilityLabel("End call")
        }
        .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 44).frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.90)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private func callButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(active ? Color.white.opacity(0.14) : Color.red.opacity(0.70)).frame(width: 58, height: 58)
                    Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundColor(.white)
                }
                Text(label).font(.inter(Theme.fontXS)).foregroundColor(.white.opacity(0.65))
            }
        }
        .accessibilityLabel(label)
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
