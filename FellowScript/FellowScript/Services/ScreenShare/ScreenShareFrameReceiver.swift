// Main-app end of the screen-share bridge (task 20261009-session-ui-redesign,
// step 5): listens on the Unix-domain socket inside the shared App Group
// container, accepts the broadcast extension's single connection, and hands
// each framed JPEG to `onEvent`. SDK-free; the Chime wiring is in
// ChimeScreenShare.swift. Frame bytes are never logged.
//
// Threading: everything runs on one private serial queue; `onEvent` is called
// on that queue.

import Foundation
import Darwin

nonisolated final class ScreenShareFrameReceiver {
    enum Event {
        case connected
        case frame(Data)
        /// The extension closed the connection (user stopped from Control
        /// Center / status bar, extension crashed) or sent a malformed stream.
        case ended
    }

    enum StartError: Error { case unavailable, socket }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "com.fellowscript.screenshare.receiver")
    private var listenFd: Int32 = -1
    private var connFd: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connSource: DispatchSourceRead?
    private var parser = ScreenShareFrameParser()
    private var path: String?

    init() {}
    deinit { stop() }

    /// Starts listening. Throws `.unavailable` when the App Group isn't
    /// provisioned for this build (the caller shows a warm "not available"
    /// message) and `.socket` for any POSIX failure.
    func start() throws {
        try queue.sync {
            guard listenFd < 0 else { return }
            guard let path = ScreenShareBridge.socketPath(),
                  var addr = ScreenShareBridge.sockaddrUn(path: path) else { throw StartError.unavailable }
            unlink(path)   // stale socket from a killed previous run

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw StartError.socket }
            Self.setNonBlocking(fd)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0, listen(fd, 1) == 0 else { close(fd); unlink(path); throw StartError.socket }

            self.path = path
            listenFd = fd
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptPending() }
            src.setCancelHandler { close(fd) }
            listenSource = src
            src.resume()
        }
    }

    /// Idempotent; closes the connection (which also tells the extension to
    /// end its broadcast) and removes the socket file.
    func stop() {
        queue.sync {
            connSource?.cancel(); connSource = nil; connFd = -1
            listenSource?.cancel(); listenSource = nil; listenFd = -1
            if let path { unlink(path); self.path = nil }
            parser = ScreenShareFrameParser()
        }
    }

    // MARK: Accept / read (on `queue`)

    private func acceptPending() {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { return }
        // Only one broadcast at a time: a new connection replaces a stale one.
        connSource?.cancel(); connSource = nil
        parser = ScreenShareFrameParser()
        Self.setNonBlocking(fd)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        connFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable(fd) }
        src.setCancelHandler { close(fd) }
        connSource = src
        src.resume()
        onEvent?(.connected)
    }

    private func readAvailable(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                do {
                    for frame in try parser.append(Data(chunk[0..<n])) { onEvent?(.frame(frame)) }
                } catch {
                    endConnection(fd); return
                }
            } else if n == 0 {
                endConnection(fd); return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                endConnection(fd); return
            }
        }
    }

    private func endConnection(_ fd: Int32) {
        guard connFd == fd else { return }
        connSource?.cancel(); connSource = nil; connFd = -1
        onEvent?(.ended)
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}
