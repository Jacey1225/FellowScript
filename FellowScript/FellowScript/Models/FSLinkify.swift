// FSLinkify.swift -- task 20261124-clickable-message-links (iOS).
//
// Pure Foundation logic (no SwiftUI) that finds http/https URLs in chat text.
// This is a port of frontend/src/lib/linkify.js and must stay rule-for-rule
// identical: shared/linkify-fixtures.json is run by both test suites.
//
// Rules:
//   - A candidate starts with http:// or https:// (scheme case-insensitive) and
//     runs to the first whitespace, one of < > ", or a control character.
//   - Trailing . , ; : ! ? ' are stripped and left as plain text.
//   - A trailing ) ] } is stripped only while unbalanced inside the URL.
//   - The remainder must have a non-empty, well-formed host (and a valid port).
//   - Linear time. Text past `maxScanScalars` is never linked, and a URL cut off
//     by that cap is not linked.
// Nothing here ever builds HTML or runs a web view; callers make AttributedString
// link runs only for URLs this file accepts.

import Foundation

nonisolated enum Linkify {
    static let maxScanScalars = 20_000

    struct Segment: Equatable {
        let text: String
        let isLink: Bool
    }

    /// What a UI needs to open / warn about one link.
    struct Info: Equatable {
        /// ASCII (punycode) URL that is safe to hand to the system.
        let href: String
        /// ASCII host, plus ":port" when the port is not the scheme default.
        let host: String
        /// userinfo, raw IP host, non-default port, or non-ASCII (IDN) host.
        let suspicious: Bool
    }

    // MARK: Segmenting

    /// Splits `text` into runs whose concatenation equals `text`.
    static func segments(_ text: String) -> [Segment] {
        if text.isEmpty { return [Segment(text: "", isLink: false)] }
        let s = Array(text.unicodeScalars)
        let limit = min(s.count, maxScanScalars)
        var out: [Segment] = []
        var pos = 0
        var i = 0
        while i < limit {
            guard let schemeLen = schemeLength(s, at: i) else { i += 1; continue }
            let start = i
            let bodyStart = start + schemeLen
            var end = bodyStart
            var openParen = 0, openBracket = 0, openBrace = 0
            var closeParen = 0, closeBracket = 0, closeBrace = 0
            while end < limit && !isStop(s[end]) {
                switch s[end] {
                case "(": openParen += 1
                case "[": openBracket += 1
                case "{": openBrace += 1
                case ")": closeParen += 1
                case "]": closeBracket += 1
                case "}": closeBrace += 1
                default: break
                }
                end += 1
            }
            let capped = end >= limit && limit < s.count && !isStop(s[end])
            var e = end
            while e > bodyStart {
                let c = s[e - 1]
                if trailPunct.contains(c) { e -= 1; continue }
                if c == ")" && closeParen > openParen { closeParen -= 1; e -= 1; continue }
                if c == "]" && closeBracket > openBracket { closeBracket -= 1; e -= 1; continue }
                if c == "}" && closeBrace > openBrace { closeBrace -= 1; e -= 1; continue }
                break
            }
            i = max(end, start + 1)
            if capped || e <= bodyStart { continue }
            let url = string(s, start, e)
            guard info(url) != nil else { continue }
            if start > pos { out.append(Segment(text: string(s, pos, start), isLink: false)) }
            out.append(Segment(text: url, isLink: true))
            pos = e
        }
        if pos == 0 { return [Segment(text: text, isLink: false)] }
        if pos < s.count { out.append(Segment(text: string(s, pos, s.count), isLink: false)) }
        return out
    }

    private static let trailPunct: Set<Unicode.Scalar> = [".", ",", ";", ":", "!", "?", "'"]

    private static func string(_ s: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s[from..<to])
        return String(v)
    }

    /// 7 for "http://", 8 for "https://" (any case), else nil.
    private static func schemeLength(_ s: [Unicode.Scalar], at i: Int) -> Int? {
        func lower(_ x: Unicode.Scalar) -> UInt32 { (x.value >= 65 && x.value <= 90) ? x.value + 32 : x.value }
        let http: [UInt32] = [104, 116, 116, 112]       // h t t p
        guard i + 7 <= s.count else { return nil }
        for k in 0..<4 where lower(s[i + k]) != http[k] { return nil }
        var j = i + 4
        var len = 4
        if lower(s[j]) == 115 { j += 1; len += 1 }       // optional s
        guard j + 3 <= s.count, s[j] == ":", s[j + 1] == "/", s[j + 2] == "/" else { return nil }
        return len + 3
    }

    private static func isStop(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        if v < 0x20 || (v >= 0x7f && v <= 0x9f) || v == 0xFEFF { return true }
        if c == "<" || c == ">" || c == "\"" { return true }
        return c.properties.isWhitespace
    }

    // MARK: URL validation and display info

    /// nil unless `raw` is a linkable http(s) URL with a valid host.
    static func info(_ raw: String) -> Info? {
        let scalars = Array(raw.unicodeScalars)
        guard let schemeLen = schemeLength(scalars, at: 0) else { return nil }
        let isHttps = schemeLen == 8
        let rest = Array(scalars[schemeLen...])
        // Authority ends at the first / \ ? #
        var authEnd = rest.count
        for (k, c) in rest.enumerated() where c == "/" || c == "\\" || c == "?" || c == "#" { authEnd = k; break }
        let authority = Array(rest[..<authEnd])
        let tail = Array(rest[authEnd...])
        var userinfo: [Unicode.Scalar] = []
        var hostPort = authority
        if let at = authority.lastIndex(of: "@") {
            userinfo = Array(authority[..<at])
            hostPort = Array(authority[(at + 1)...])
        }
        // Split host and port (IPv6 literals keep their brackets).
        var hostScalars = hostPort
        var port = ""
        if hostPort.first == "[" {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            hostScalars = Array(hostPort[...close])
            let after = hostPort[(close + 1)...]
            if !after.isEmpty {
                guard after.first == ":" else { return nil }
                port = string(Array(after.dropFirst()), 0, after.count - 1)
            }
        } else if let colon = hostPort.lastIndex(of: ":") {
            hostScalars = Array(hostPort[..<colon])
            port = string(hostPort, colon + 1, hostPort.count)
        }
        guard !hostScalars.isEmpty else { return nil }
        if !port.isEmpty {
            guard port.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                  let n = Int(port), n <= 65535 else { return nil }
        }
        let isIPv6 = hostScalars.first == "["
        if !isIPv6 {
            let forbidden: Set<Unicode.Scalar> = [" ", "#", "/", ":", "<", ">", "?", "@", "[", "\\", "]", "^", "|", "%"]
            if hostScalars.contains(where: { forbidden.contains($0) }) { return nil }
        }
        let hostText = string(hostScalars, 0, hostScalars.count)
        guard let asciiHost = isIPv6 ? hostText.lowercased() : asciiHostName(hostText), !asciiHost.isEmpty else { return nil }
        let nonAscii = hostScalars.contains { $0.value > 0x7f }
        let defaultPort = isHttps ? "443" : "80"
        let keepPort = !port.isEmpty && port != defaultPort
        let hostDisplay = asciiHost + (keepPort ? ":\(Int(port) ?? 0)" : "")
        let hasPort = !port.isEmpty && port != defaultPort
        let suspicious = !userinfo.isEmpty || isIPv6 || looksLikeIPv4(asciiHost) || hasPort || nonAscii

        var href = isHttps ? "https://" : "http://"
        if !userinfo.isEmpty { href += percentEncode(string(userinfo, 0, userinfo.count)) + "@" }
        href += hostDisplay
        href += percentEncode(string(tail, 0, tail.count))
        guard URL(string: href) != nil else { return nil }
        return Info(href: href, host: hostDisplay, suspicious: suspicious)
    }

    private static func looksLikeIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// Characters left as-is when building the ASCII href: everything already
    /// valid in a URL (including existing %XX escapes). Non-ASCII is encoded.
    private static let urlSafe: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(UInt8(0))...Unicode.Scalar(UInt8(127))))
        set.insert(charactersIn: "-._~:/?#[]@!$&'()*+,;=%")
        return set
    }()

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: urlSafe) ?? s
    }

    // MARK: Hostname -> ASCII (punycode)

    /// Lowercased ASCII host; non-ASCII labels become "xn--" punycode.
    static func asciiHostName(_ host: String) -> String? {
        let mapped = host.precomposedStringWithCompatibilityMapping.lowercased()
        var labels: [String] = []
        for label in mapped.split(separator: ".", omittingEmptySubsequences: false) {
            let l = String(label)
            if l.unicodeScalars.allSatisfy({ $0.value < 0x80 }) { labels.append(l); continue }
            guard let enc = punycode(Array(l.unicodeScalars.map { $0.value })) else { return nil }
            labels.append("xn--" + enc)
        }
        return labels.joined(separator: ".")
    }

    /// RFC 3492 encoder.
    private static func punycode(_ input: [UInt32]) -> String? {
        let base: UInt32 = 36, tMin: UInt32 = 1, tMax: UInt32 = 26, skew: UInt32 = 38, damp: UInt32 = 700
        var n: UInt32 = 128
        var delta: UInt32 = 0
        var bias: UInt32 = 72
        var output = String.UnicodeScalarView()
        for c in input where c < 0x80 { output.append(Unicode.Scalar(c)!) }
        let b = UInt32(output.count)
        var h = b
        if b > 0 { output.append("-") }
        func digit(_ d: UInt32) -> Unicode.Scalar { Unicode.Scalar(d < 26 ? d + 97 : d - 26 + 48)! }
        func adapt(_ d: UInt32, _ numPoints: UInt32, _ first: Bool) -> UInt32 {
            var d = first ? d / damp : d / 2
            d += d / numPoints
            var k: UInt32 = 0
            while d > ((base - tMin) * tMax) / 2 { d /= base - tMin; k += base }
            return k + (base - tMin + 1) * d / (d + skew)
        }
        while h < UInt32(input.count) {
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            let (inc, o1) = (m - n).multipliedReportingOverflow(by: h + 1)
            let (nd, o2) = delta.addingReportingOverflow(inc)
            if o1 || o2 { return nil }
            delta = nd
            n = m
            for c in input {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, h + 1, h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }
}

// MARK: - Open policy

/// Decides what a tapped link may do. Only http/https ever open; suspicious
/// links ask first. Everything else is discarded.
nonisolated enum MessageLinkPolicy {
    enum Decision: Equatable {
        case open(URL)
        case confirm(url: URL, host: String)
        case reject
    }

    static func decide(_ url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let info = Linkify.info(url.absoluteString),
              let safe = URL(string: info.href) else { return .reject }
        return info.suspicious ? .confirm(url: safe, host: info.host) : .open(safe)
    }
}
