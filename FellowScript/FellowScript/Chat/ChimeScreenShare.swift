// Chime side of whole-screen sharing (task 20261009-session-ui-redesign,
// step 5): decodes the extension's JPEG frames into NV12 pixel buffers, feeds
// them to a Chime content-share video source, and owns the lifecycle
// (receiver, source, content-share start/stop). ChimeCallManager creates one
// coordinator per share and drops it on stop / call end.
//
// Frame data is never logged.

import Foundation
import CoreImage
import CoreVideo
import Darwin

#if canImport(AmazonChimeSDK)
import AmazonChimeSDK

// MARK: - Video source (extension frames -> Chime) ─────────────────────────────

nonisolated final class BroadcastVideoSource: NSObject, VideoSource {
    var videoContentHint: VideoContentHint = .text

    private let lock = NSLock()
    private var sinks: [VideoSink] = []
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)
    private var lastFrame: VideoFrame?
    private var lastEmit: UInt64 = 0

    func addVideoSink(sink: VideoSink) {
        lock.lock(); defer { lock.unlock() }
        sinks.append(sink)
    }

    func removeVideoSink(sink: VideoSink) {
        lock.lock(); defer { lock.unlock() }
        sinks.removeAll { $0 === sink }
    }

    /// Decode one JPEG from the extension and emit it. Bad frames are dropped.
    func push(jpeg: Data) {
        guard let image = CIImage(data: jpeg) else { return }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, let buffer = makeBuffer(width: w, height: h) else { return }
        ciContext.render(image, to: buffer)
        emit(VideoFrame(timestampNs: Int64(Self.nowNs()), rotation: .rotation0,
                        buffer: VideoFramePixelBuffer(pixelBuffer: buffer)))
    }

    /// A static screen produces no new frames, but Chime's receivers expect a
    /// steady stream; re-emit the last frame with a fresh timestamp.
    func repeatLastFrameIfIdle(afterNs: UInt64 = 1_000_000_000) {
        lock.lock()
        let frame = lastFrame
        let idleFor = Self.nowNs() &- lastEmit
        lock.unlock()
        guard let frame, idleFor >= afterNs else { return }
        emit(VideoFrame(timestampNs: Int64(Self.nowNs()), rotation: .rotation0, buffer: frame.buffer))
    }

    private func emit(_ frame: VideoFrame) {
        lock.lock()
        lastFrame = frame; lastEmit = Self.nowNs()
        let current = sinks
        lock.unlock()
        for sink in current { sink.onVideoFrameReceived(frame: frame) }
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        if pool == nil || poolSize.w != width || poolSize.h != height {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &newPool) == kCVReturnSuccess else { return nil }
            pool = newPool; poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

// MARK: - Coordinator ─────────────────────────────────────────────────────────

enum ScreenShareEvent {
    case broadcastConnected
    case shareStarted
    /// Chime reported the content share ended; `failed` = non-OK status.
    case shareStopped(failed: Bool)
    /// The extension went away (Control Center stop, crash, bad stream).
    case broadcastEnded
}

final class ChimeScreenShareCoordinator: NSObject, ContentShareObserver {
    private let audioVideo: AudioVideoFacade
    private let receiver = ScreenShareFrameReceiver()
    private let source = BroadcastVideoSource()
    /// Always invoked on the main queue.
    private let onEvent: (ScreenShareEvent) -> Void

    private let frameLock = NSLock()
    private var sawFirstFrame = false
    private var keepAlive: DispatchSourceTimer?
    private var contentShareStarted = false

    init(audioVideo: AudioVideoFacade, onEvent: @escaping (ScreenShareEvent) -> Void) {
        self.audioVideo = audioVideo
        self.onEvent = onEvent
        super.init()
    }

    /// Starts listening for the extension. Throws if the App Group / socket
    /// isn't available (caller shows a warm message and never presents the picker).
    func beginListening() throws {
        receiver.onEvent = { [weak self] event in self?.handle(event) }
        try receiver.start()
    }

    /// Full teardown; safe to call repeatedly and from any state.
    func stop() {
        receiver.onEvent = nil
        keepAlive?.cancel(); keepAlive = nil
        // Closing the socket ends the broadcast too; the Darwin notification
        // covers the case where the extension isn't currently reading.
        receiver.stop()
        Self.postStopNotification()
        if contentShareStarted {
            contentShareStarted = false
            audioVideo.stopContentShare()
        }
        audioVideo.removeContentShareObserver(observer: self)
    }

    // MARK: Receiver events (receiver queue)

    private func handle(_ event: ScreenShareFrameReceiver.Event) {
        switch event {
        case .connected:
            DispatchQueue.main.async { self.onEvent(.broadcastConnected) }
        case .frame(let jpeg):
            source.push(jpeg: jpeg)
            frameLock.lock()
            let first = !sawFirstFrame
            sawFirstFrame = true
            frameLock.unlock()
            if first { DispatchQueue.main.async { self.startContentShare() } }
        case .ended:
            DispatchQueue.main.async { self.onEvent(.broadcastEnded) }
        }
    }

    // MARK: Chime (main)

    private func startContentShare() {
        guard !contentShareStarted else { return }
        contentShareStarted = true
        audioVideo.addContentShareObserver(observer: self)
        let content = ContentShareSource()
        content.videoSource = source
        audioVideo.startContentShare(
            source: content,
            config: LocalVideoConfiguration(maxBitRateKbps: 1500, simulcastEnabled: false))
        startKeepAlive()
    }

    private func startKeepAlive() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [source] in source.repeatLastFrameIfIdle() }
        t.resume()
        keepAlive = t
    }

    // MARK: ContentShareObserver

    nonisolated func contentShareDidStart() {
        DispatchQueue.main.async { self.onEvent(.shareStarted) }
    }

    nonisolated func contentShareDidStop(status: ContentShareStatus) {
        let failed = status.statusCode != .ok
        DispatchQueue.main.async { self.onEvent(.shareStopped(failed: failed)) }
    }

    static func postStopNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(ScreenShareBridge.stopNotificationName as CFString),
            nil, nil, true)
    }
}

#endif
