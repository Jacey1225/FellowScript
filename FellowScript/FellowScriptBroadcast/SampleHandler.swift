// ReplayKit Broadcast Upload Extension for whole-screen sharing in a session
// call (task 20261009-session-ui-redesign, step 5).
//
// Runs in its own process with a ~50 MB cap, so it does the minimum: take each
// video frame from ReplayKit, drop frames above the fps cap, downscale + JPEG
// it (CoreImage, no intermediate full-size copy), and write it to the Unix
// socket the main app is listening on inside the shared App Group container.
// It never touches audio (call audio stays in the app), the network, or any
// credential, and never logs frame contents.

import ReplayKit
import CoreImage
import CoreMedia
import Darwin
import ImageIO

class SampleHandler: RPBroadcastSampleHandler {

    private static let errorDomain = "FellowScript.ScreenShare"

    private var fd: Int32 = -1
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var lastSentAt: CFAbsoluteTime = 0
    private var finished = false
    private var liveness: DispatchSourceTimer?

    // MARK: Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let path = ScreenShareBridge.socketPath(),
              var addr = ScreenShareBridge.sockaddrUn(path: path) else {
            fail("Screen sharing isn't set up on this build yet.")
            return
        }
        // The app starts listening before it presents the picker, so a short
        // retry window is enough. Started from Control Center without the app
        // waiting -> clear message instead of a silent dead broadcast.
        for attempt in 0..<10 {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { break }
            var on: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 1, tv_usec: 0)   // never block the sample queue for long
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc == 0 { fd = s; break }
            close(s)
            if attempt < 9 { usleep(200_000) }
        }
        guard fd >= 0 else {
            fail("Start screen sharing from the call menu in FellowScript first.")
            return
        }
        observeStopRequest()
        startLivenessCheck()
    }

    override func broadcastFinished() {
        teardown()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Video only: call audio is carried by the app's Chime session.
        guard sampleBufferType == .video, fd >= 0, !finished else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSentAt >= 1.0 / ScreenShareBridge.maxFramesPerSecond else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSentAt = now

        autoreleasepool {
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            if let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                         attachmentModeOut: nil) as? NSNumber,
               let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
                image = image.oriented(orientation)
            }
            let longEdge = Double(max(image.extent.width, image.extent.height))
            if longEdge > ScreenShareBridge.maxLongEdge {
                let s = ScreenShareBridge.maxLongEdge / longEdge
                image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
                    ScreenShareBridge.jpegQuality
            ]
            guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options),
                  jpeg.count <= ScreenShareBridge.maxFrameBytes else { return }   // oversize: skip this frame
            if !send(jpeg) { fail("Screen sharing ended.") }
        }
    }

    // MARK: Socket write

    private func send(_ jpeg: Data) -> Bool {
        let header = ScreenShareBridge.header(forPayloadLength: jpeg.count)
        return writeAll(Data(header)) && writeAll(jpeg)
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var p = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false            // EPIPE (app gone), EAGAIN (1 s send timeout), ...
                }
                if n == 0 { return false }
                p += n; remaining -= n
            }
            return true
        }
    }

    // MARK: Ending

    /// Static screens deliver no frames, so a dead app is not noticed by writes
    /// alone. Peek the socket every 2 s: EOF means the app closed it (call
    /// ended, app killed) and the broadcast must stop rather than keep showing
    /// the system "recording" indicator.
    private func startLivenessCheck() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, self.fd >= 0, !self.finished else { return }
            var byte: UInt8 = 0
            let n = recv(self.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                self.fail("Screen sharing ended.")
            }
        }
        t.resume()
        liveness = t
    }

    private func observeStopRequest() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.fail("Screen sharing ended.")
            },
            ScreenShareBridge.stopNotificationName as CFString, nil, .deliverImmediately)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        teardown()
        finishBroadcastWithError(NSError(
            domain: Self.errorDomain, code: 1,
            userInfo: [NSLocalizedFailureReasonErrorKey: message]))
    }

    private func teardown() {
        finished = true
        liveness?.cancel(); liveness = nil
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                Unmanaged.passUnretained(self).toOpaque())
        if fd >= 0 { close(fd); fd = -1 }
    }
}
