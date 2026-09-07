import Foundation
#if canImport(os)
import os
#endif

/// On-disk cache of checker results keyed by `(checkerId, fingerprint)`.
///
/// The cache is best-effort and corruption-safe: an unreadable or malformed entry is
/// treated as a miss, never a crash, and a write failure never fails the gate. Reusing
/// an entry is safe because the fingerprint captures the checker's complete input set
/// (see ``CheckerFingerprint``) — an identical fingerprint means an identical result.
///
/// **Best-effort is not the same as unobservable.** An absent entry is the ordinary
/// case — every first run, every changed fingerprint — and is not reported. An entry
/// that exists but cannot be read or decoded, a write that fails, an eviction that
/// fails: each of those returns the same outcome to the caller and means something has
/// gone wrong. They are logged, because a cache that silently never populates looks
/// exactly like a cache that is working and always missing.
public struct ResultCache: Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "ResultCache")

    private let directory: URL

    /// Creates a cache backed by `directory`.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The default cache location under the project's `.build`.
    public static func standard(projectRoot: URL) -> ResultCache {
        ResultCache(
            directory: projectRoot
                .appendingPathComponent(".build")
                .appendingPathComponent("quality-gate-cache")
        )
    }

    private func entryURL(checkerId: String, fingerprint: String) -> URL {
        let safeChecker = checkerId.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safeChecker)-\(fingerprint).json")
    }

    /// Reads and decodes one entry, separating an ordinary miss from a damaged entry.
    ///
    /// Both return `nil`; only the second is reported. A file that is absent says
    /// nothing — that is what a cold cache looks like. A file that is present and
    /// unusable says the cache is damaged, and every run from here pays full price for
    /// work it believes it has already done.
    private func decodeEntry<T: Decodable>(_ type: T.Type, at url: URL, id: String) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil } // SAFETY: read-only probe of our own cache path
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Present a moment ago and unreadable now: a permissions change, a truncated
            // write, or eviction racing this read. Any of those is worth knowing.
            Self.logger.warning(
                "cache entry unreadable for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.logger.warning(
                "cache entry corrupt for \(id, privacy: .public), treating as a miss: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Returns the cached result for the key, or nil on a miss or unreadable/corrupt entry.
    public func load(checkerId: String, fingerprint: String) -> CheckResult? {
        decodeEntry(
            CheckResult.self,
            at: entryURL(checkerId: checkerId, fingerprint: fingerprint),
            id: checkerId)
    }

    /// Stores a result under the key. Failures never fail the gate, but they are logged:
    /// a cache that cannot write is indistinguishable from one that always misses.
    public func store(_ result: CheckResult, checkerId: String, fingerprint: String) {
        do {
            try writeEntry(result, checkerId: checkerId, fingerprint: fingerprint)
        } catch {
            Self.logger.warning(
                "cache write failed for \(checkerId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// When the entry for the key was written, or nil if there is none.
    ///
    /// The run that produced a cached result is the fact a reader most needs and the
    /// one the result itself does not carry: `CheckResult` records a duration, not a
    /// date. Taken from the entry's modification time, which is when the run that
    /// produced it finished.
    public func entryDate(checkerId: String, fingerprint: String) -> Date? {
        let url = entryURL(checkerId: checkerId, fingerprint: fingerprint)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil } // SAFETY: read-only probe of our own cache path
        do {
            return try FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        } catch {
            // The entry exists but will not describe itself — the caller loses the "as of"
            // date it uses to explain a replayed result, so this is not merely cosmetic.
            Self.logger.warning(
                "cache entry date unreadable for \(checkerId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Removes the entry for the key, if one exists.
    ///
    /// Used to evict a result that must never be replayed. Best-effort, like every
    /// other cache operation: a failed removal must never fail the gate, and the
    /// worst case is that the entry is re-evicted on the next read.
    public func remove(checkerId: String, fingerprint: String) {
        let url = entryURL(checkerId: checkerId, fingerprint: fingerprint)
        guard FileManager.default.fileExists(atPath: url.path) else { return } // SAFETY: read-only probe of our own cache path
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Eviction exists to stop a result being replayed. A failure here means it
            // *will* be replayed, which is the one outcome the caller was avoiding.
            Self.logger.warning(
                "cache eviction failed for \(checkerId, privacy: .public), entry may be replayed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns a cached derived artifact, or nil on a miss or unreadable/corrupt entry.
    ///
    /// Artifacts are expensive values *derived from* checker inputs but produced outside
    /// `check()` — e.g. the telemetry sidecar reports, which used to re-scan the whole
    /// tree on every run even when every checker hit the cache. The same safety contract
    /// applies: key with a `CheckerFingerprint` over the complete input set, and an
    /// identical fingerprint guarantees an identical artifact.
    ///
    /// - Parameters:
    ///   - type: The artifact's concrete type.
    ///   - artifactId: Namespaced id, e.g. `"telemetry-complexity"` — must never collide
    ///     with a checker id, since entries share the cache directory.
    ///   - fingerprint: A `CheckerFingerprint` over the artifact's complete input set.
    /// - Returns: The decoded artifact, or `nil` as a miss.
    public func loadArtifact<T: Decodable>(_ type: T.Type, artifactId: String, fingerprint: String) -> T? {
        decodeEntry(
            type,
            at: entryURL(checkerId: artifactId, fingerprint: fingerprint),
            id: artifactId)
    }

    /// Stores a derived artifact under the key. Failures never fail the gate, but they
    /// are logged: an artifact that will not cache is re-derived on every run, which is
    /// the expense this cache exists to avoid.
    public func storeArtifact<T: Encodable>(_ value: T, artifactId: String, fingerprint: String) {
        do {
            try writeArtifactEntry(value, artifactId: artifactId, fingerprint: fingerprint)
        } catch {
            Self.logger.warning(
                "artifact cache write failed for \(artifactId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeArtifactEntry<T: Encodable>(_ value: T, artifactId: String, fingerprint: String) throws {
        try WriteGuard.validate(path: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) // SAFETY: CLI tool creates its local cache directory
        let data = try JSONEncoder().encode(value)
        try data.write(to: entryURL(checkerId: artifactId, fingerprint: fingerprint))
    }

    private func writeEntry(_ result: CheckResult, checkerId: String, fingerprint: String) throws {
        // WriteGuard backstop (Phase 1): in foreign mode the CLI points the
        // cache at the overlay; a directory still inside the analyzed repo is
        // a bug, and store() degrades it to a silent cache miss.
        try WriteGuard.validate(path: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) // SAFETY: CLI tool creates its local cache directory
        let data = try JSONEncoder().encode(result)
        try data.write(to: entryURL(checkerId: checkerId, fingerprint: fingerprint))
    }
}
