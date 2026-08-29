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

    #if canImport(AmazonChimeSDK)
    let manager = ChimeCallManager()
    #endif

    var inCall: Bool { session != nil }

    func start(session: FSSession, service: DataServiceProtocol, userId: String) {
        if self.session?.id == session.id { isExpanded = true; return }  // already joined
        self.session    = session
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
        #if canImport(AmazonChimeSDK)
        manager.leave()
        #endif
        session = nil; isExpanded = false; joinError = nil
    }
}

// MARK: - Minimized call bar (shown while in a call but not expanded) ───────────

struct MinimizedCallBar: View {
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
    func audioSessionDidDrop() {}
    func audioSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {
        DispatchQueue.main.async { self.isConnected = false }
    }
    func videoSessionDidStartConnecting() {}
    func videoSessionDidStartWithStatus(sessionStatus: MeetingSessionStatus) {}
    func videoSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {}
    // Added in newer AmazonChimeSDK — no-op implementations satisfy the protocol.
    func audioSessionDidCancelReconnect() {}
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
    }

    private var callActiveBody: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Group {
                    if !manager.remoteTileIds.isEmpty {
                        remoteGrid(containerHeight: geo.size.height)
                    } else if !manager.remoteAttendeeIds.isEmpty {
                        audioParticipantsView
                    } else {
                        waitingPlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if manager.isCameraOn, let localId = manager.localTileId {
                    ChimeVideoTileView(tileId: localId, manager: manager)
                        .frame(width: 96, height: 128).background(Color.black)
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

    private func remoteGrid(containerHeight: CGFloat) -> some View {
        let count   = manager.remoteTileIds.count
        let columns = count > 1
            ? [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
            : [GridItem(.flexible())]
        let tileH: CGFloat = count > 2 ? (containerHeight - 180) / 2 : (containerHeight - 180)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(manager.remoteTileIds, id: \.self) { id in
                    ChimeVideoTileView(tileId: id, manager: manager)
                        .frame(height: tileH).background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 8).padding(.top, 76)
        }
        .scrollDisabled(count <= 2)
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

    private var controlBar: some View {
        HStack(spacing: 28) {
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
