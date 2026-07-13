// DiskCache — a small, generic on-disk cache for Codable values.
//
// Purpose: enable "stale-while-revalidate" loading. Views read the last-known
// value from disk and display it instantly, then fetch fresh data from the
// network and overwrite the cache. This makes data that changes infrequently
// (notes, groups, highlights, dashboard widgets, messages, account info) appear
// immediately on launch instead of showing a spinner every time.
//
// Values live in Library/Caches (the OS may purge them under storage pressure,
// which is fine — they're only a fast-path copy of server state). Keys should be
// namespaced by user id so one account never sees another's cached data.
//
// Implemented as an actor so all file I/O happens off the main thread and
// concurrent reads/writes are serialized safely.

import Foundation

actor DiskCache {
    static let shared = DiskCache()

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("FSCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for key: String) -> URL {
        // Map the key to a filesystem-safe, *deterministic* filename. (Avoid
        // String.hashValue — it's seeded randomly per process, so it would change
        // every launch and the cache would never be found on a cold start.)
        let safe = key.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "_"
        }
        return directory.appendingPathComponent("\(String(safe)).json")
    }

    /// Return the cached value for `key`, or nil if absent or undecodable.
    func load<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        let fileURL = url(for: key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Persist `value` under `key`, overwriting any previous entry.
    func save<T: Codable>(_ value: T, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    func remove(forKey key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    /// Wipe the entire cache — call on sign-out so a new account starts clean.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
