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
    ///
    /// Every failure path here still degrades to nil (best-effort cache, per
    /// this type's own doc comment above) -- only the diagnostic trail is
    /// new (dependency-errors #12, 20260904-frontend-arch-sweep), so a
    /// systematic failure (disk full, sandbox permissions change) leaves a
    /// log line instead of zero signal anywhere, matching the logging
    /// standard NetworkService.swift already applies to its own
    /// best-effort failures.
    func load<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        let fileURL = url(for: key)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil // expected: no cache entry yet, not a failure worth logging
        } catch {
            print("[DiskCache] load(forKey: \(key)) failed to read file: \(error)")
            return nil
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            print("[DiskCache] load(forKey: \(key)) failed to decode \(T.self): \(error)")
            return nil
        }
    }

    /// Persist `value` under `key`, overwriting any previous entry.
    ///
    /// Cached content includes private notes and message history, so writes
    /// get an explicit file-protection class rather than relying on
    /// whatever the OS default happens to be — `.completeUntilFirstUserAuthentication`
    /// keeps the file encrypted at rest until the device's first unlock after
    /// boot, matching the protection level appropriate for background-
    /// refreshable cache data (unlike `.complete`, it stays readable if this
    /// actor writes/reads again while the device is locked but has already
    /// been unlocked once since boot).
    func save<T: Codable>(_ value: T, forKey key: String) {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            print("[DiskCache] save(forKey: \(key)) failed to encode \(T.self): \(error)")
            return
        }
        let fileURL = url(for: key)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[DiskCache] save(forKey: \(key)) failed to write file: \(error)")
            return
        }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
        } catch {
            print("[DiskCache] save(forKey: \(key)) failed to set file protection: \(error)")
        }
    }

    func remove(forKey key: String) {
        do {
            try FileManager.default.removeItem(at: url(for: key))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // expected: nothing cached under this key
        } catch {
            print("[DiskCache] remove(forKey: \(key)) failed: \(error)")
        }
    }

    /// Wipe the entire cache — call on sign-out so a new account starts clean.
    func clear() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // expected: nothing cached yet
        } catch {
            print("[DiskCache] clear() failed to remove cache directory: \(error)")
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
