// Screen-share bridge constants and wire format, compiled into BOTH the app
// target and the FellowScriptBroadcast (ReplayKit upload extension) target
// (task 20261009-session-ui-redesign, step 5).
//
// Transport: the extension cannot talk to Chime directly (it is a separate
// process with a hard ~50 MB memory cap, and the Chime media stack is far too
// heavy to load there). Instead it downscales frames and writes them to a
// Unix-domain socket that lives inside the shared App Group container; the
// main app listens on that socket, decodes the frames and feeds them to a
// Chime content-share video source. Stop is signalled both ways: socket
// close (either side) and a Darwin notification (app -> extension).
//
// Nothing here may import the Chime SDK, SwiftUI or anything heavy: this file
// is also built into the extension.

import Foundation
import Darwin

nonisolated enum ScreenShareBridge {
    // App Group shared by the app and the extension. Must exist in the Apple
    // Developer portal and be enabled on both App IDs (see step-5 portal list).
    static let appGroupId = "group.com.fellowscript.app"
    // Short on purpose: sockaddr_un.sun_path holds only 104 bytes on Darwin.
    static let socketFileName = "ss.sock"
    // Darwin notification (cross-process) the app posts to ask the extension to end.
    static let stopNotificationName = "com.fellowscript.app.screenshare.stop"

    /// Bundle id suffix of the upload extension (appended to the app's own bundle id).
    static let extensionBundleSuffix = ".BroadcastUpload"

    // Frame budget. The extension has ~50 MB; downscaling + a low JPEG quality
    // + a hard fps cap keep both memory and the local socket traffic small.
    static let maxLongEdge: Double = 1280
    static let maxFramesPerSecond: Double = 10
    static let jpegQuality: Double = 0.55
    /// Hard ceiling for one encoded frame; larger frames are dropped by the
    /// sender and treated as a protocol error by the receiver.
    static let maxFrameBytes = 1_500_000

    // MARK: Socket path

    /// `<app group container>/ss.sock`, or nil when the App Group is not
    /// provisioned for this build (unsigned/simulator builds) or the path would
    /// not fit in `sockaddr_un.sun_path`.
    static func socketPath() -> String? {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let path = dir.appendingPathComponent(socketFileName).path
        return fitsSockaddr(path) ? path : nil
    }

    static func fitsSockaddr(_ path: String) -> Bool {
        path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    /// Builds a `sockaddr_un` for `path`; nil if it does not fit.
    static func sockaddrUn(path: String) -> sockaddr_un? {
        guard fitsSockaddr(path) else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                _ = path.withCString { src in strlcpy(dst, src, capacity) }
            }
        }
        return addr
    }

    // MARK: Wire format  [magic u8][length u32 big-endian][JPEG bytes]

    static let frameMagic: UInt8 = 0xF5
    static let headerSize = 5

    static func header(forPayloadLength length: Int) -> [UInt8] {
        let n = UInt32(truncatingIfNeeded: length)
        return [frameMagic, UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    }
}

/// Incremental parser for the framed stream (receiver side; pure, unit-testable).
nonisolated struct ScreenShareFrameParser {
    enum ParseError: Error, Equatable { case badMagic, oversizedFrame }

    private var buffer = Data()
    init() {}

    /// Appends bytes and returns every complete frame payload now available.
    /// Throws on a malformed stream; the caller must drop the connection.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= ScreenShareBridge.headerSize {
            let b = [UInt8](buffer.prefix(ScreenShareBridge.headerSize))
            guard b[0] == ScreenShareBridge.frameMagic else { buffer.removeAll(); throw ParseError.badMagic }
            let length = Int(UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4]))
            guard length > 0, length <= ScreenShareBridge.maxFrameBytes else {
                buffer.removeAll(); throw ParseError.oversizedFrame
            }
            let total = ScreenShareBridge.headerSize + length
            guard buffer.count >= total else { break }
            frames.append(Data(buffer.subdata(in: ScreenShareBridge.headerSize..<total)))
            buffer = Data(buffer.dropFirst(total))
        }
        return frames
    }
}
