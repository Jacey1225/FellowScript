// Amazon Chime audio/video call screen.
//
// To enable live calls, add the package in Xcode:
//   File → Add Package Dependencies
//   https://github.com/aws/amazon-chime-sdk-ios.git
//   Select targets: AmazonChimeSDK + AmazonChimeSDKMedia
//
// Without the package the project builds normally and shows a
// "SDK not installed" placeholder instead of the call screen.

import SwiftUI
import AVFoundation

// ── Response types live in ChimeModels.swift (no SDK dependency) ─────────────

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

    private var meetingSession: DefaultMeetingSession?

    func join(response: ChimeJoinResponse) {
        let credentials = MeetingSessionCredentials(
            attendeeId:     response.Attendee.AttendeeId,
            externalUserId: response.Attendee.ExternalUserId,
            joinToken:      response.Attendee.JoinToken
        )
        let urls = MediaPlacement(
            audioFallbackUrl: response.Meeting.MediaPlacement.AudioFallbackUrl,
            audioHostUrl:     response.Meeting.MediaPlacement.AudioHostUrl,
            signalingUrl:     response.Meeting.MediaPlacement.SignalingUrl,
            turnControlUrl:   response.Meeting.MediaPlacement.TurnControlUrl,
            ingestionUrl:     response.Meeting.MediaPlacement.IngestionUrl
        )
        let config = MeetingSessionConfiguration(
            meetingId:         response.Meeting.MeetingId,
            externalMeetingId: response.Meeting.ExternalMeetingId,
            credentials:       credentials,
            urls:              urls
        )
        meetingSession = DefaultMeetingSession(
            configuration: config,
            logger: ConsoleLogger(name: "ChimeCall")
        )
        meetingSession?.audioVideo.addAudioVideoObserver(observer: self)
        meetingSession?.audioVideo.addVideoTileObserver(observer: self)
        do {
            try meetingSession?.audioVideo.start()
            meetingSession?.audioVideo.startRemoteVideo()
        } catch {
            print("Chime start error: \(error)")
        }
    }

    func toggleMute() {
        guard let av = meetingSession?.audioVideo else { return }
        if isMuted { av.realtimeUnmuteLocalAudio(); isMuted = false }
        else        { av.realtimeMuteLocalAudio();   isMuted = true  }
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
        localTileId = nil;   remoteTileIds = []
    }

    func bindTile(tileId: Int, view: VideoRenderView) {
        meetingSession?.audioVideo.bindVideoView(videoView: view, tileId: tileId)
    }
}

// MARK: - AudioVideoObserver

extension ChimeCallManager: AudioVideoObserver {
    func audioSessionDidStartConnecting(reconnecting: Bool) {}
    func audioSessionDidStart(reconnecting: Bool) {
        DispatchQueue.main.async { self.isConnected = true }
    }
    func audioSessionDidDrop() {}
    func audioSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {
        DispatchQueue.main.async { self.isConnected = false }
    }
    func videoSessionDidStartConnecting() {}
    func videoSessionDidStartWithStatus(sessionStatus: MeetingSessionStatus) {}
    func videoSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {}
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
    @StateObject private var callManager = ChimeCallManager()
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let session: FSSession

    @State private var isJoining  = true
    @State private var joinError: String? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isJoining {
                VStack(spacing: 16) {
                    ProgressView().tint(.white)
                    Text("Joining call…").foregroundColor(.white.opacity(0.70)).font(.lora(Theme.fontSM))
                }
            } else if let error = joinError {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44, weight: .light)).foregroundColor(.orange)
                    Text(error).foregroundColor(.white.opacity(0.75)).font(.lora(Theme.fontSM))
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                    Button("Dismiss") { dismiss() }.foregroundColor(Theme.gold).font(.lora(Theme.fontBody))
                }
            } else {
                callActiveBody
            }
        }
        .task { await joinCall() }
        .onDisappear { callManager.leave() }
    }

    private var callActiveBody: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Group {
                    if callManager.remoteTileIds.isEmpty { waitingPlaceholder }
                    else { remoteGrid(containerHeight: geo.size.height) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if callManager.isCameraOn, let localId = callManager.localTileId {
                    ChimeVideoTileView(tileId: localId, manager: callManager)
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
            Image(systemName: callManager.isConnected ? "video.slash" : "wifi")
                .font(.system(size: 52, weight: .ultraLight)).foregroundColor(.white.opacity(0.22))
            Text(callManager.isConnected ? "Waiting for others to join…" : "Connecting…")
                .foregroundColor(.white.opacity(0.42)).font(.lora(Theme.fontSM))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func remoteGrid(containerHeight: CGFloat) -> some View {
        let count   = callManager.remoteTileIds.count
        let columns = count > 1
            ? [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
            : [GridItem(.flexible())]
        let tileH: CGFloat = count > 2 ? (containerHeight - 180) / 2 : (containerHeight - 180)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(callManager.remoteTileIds, id: \.self) { id in
                    ChimeVideoTileView(tileId: id, manager: callManager)
                        .frame(height: tileH).background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 8).padding(.top, 76)
        }
        .scrollDisabled(count <= 2)
    }

    private var callHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.lora(Theme.fontBody, weight: .semibold)).foregroundColor(.white)
                HStack(spacing: 5) {
                    Circle().fill(callManager.isConnected ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(callManager.isConnected ? "Connected" : "Connecting…")
                        .font(.lora(Theme.fontXS)).foregroundColor(.white.opacity(0.52))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 56).padding(.bottom, 16)
        .background(LinearGradient(colors: [.black.opacity(0.80), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var controlBar: some View {
        HStack(spacing: 28) {
            callButton(icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                       label: callManager.isMuted ? "Unmute" : "Mute",
                       active: !callManager.isMuted) { callManager.toggleMute() }
            callButton(icon: callManager.isCameraOn ? "video.fill" : "video.slash.fill",
                       label: callManager.isCameraOn ? "Camera" : "Camera Off",
                       active: callManager.isCameraOn) { callManager.toggleCamera() }
            Button { callManager.leave(); dismiss() } label: {
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(Color.red).frame(width: 62, height: 62)
                        Image(systemName: "phone.down.fill").font(.system(size: 24)).foregroundColor(.white)
                    }
                    Text("End").font(.lora(Theme.fontXS)).foregroundColor(.white.opacity(0.65))
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
                Text(label).font(.lora(Theme.fontXS)).foregroundColor(.white.opacity(0.65))
            }
        }
        .accessibilityLabel(label)
    }

    private func joinCall() async {
        let userId = appState.currentUser?.user_id ?? ""
        do {
            let response = try await appState.service.joinCall(userId: userId, sessionId: session.id)
            callManager.join(response: response)
        } catch {
            joinError = error.localizedDescription
        }
        isJoining = false
    }
}

#else

// MARK: - Stub (AmazonChimeSDK not installed) ─────────────────────────────────

struct ChimeCallView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let session: FSSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "video.slash")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundColor(.white.opacity(0.28))
                Text("Live calls require the Amazon Chime SDK.")
                    .foregroundColor(.white.opacity(0.65))
                    .font(.lora(Theme.fontSM))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text("In Xcode: File → Add Package Dependencies\nhttps://github.com/aws/amazon-chime-sdk-ios.git")
                    .foregroundColor(.white.opacity(0.35))
                    .font(.lora(Theme.fontXS))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Dismiss") { dismiss() }
                    .foregroundColor(Theme.gold)
                    .font(.lora(Theme.fontBody))
                    .padding(.top, 8)
            }
        }
    }
}

#endif
