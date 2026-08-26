import Foundation

/// On-disk cache of checker results keyed by `(checkerId, fingerprint)`.
///
/// The cache is best-effort and corruption-safe: an unreadable or malformed entry is
/// treated as a miss, never a crash, and a write failure never fails the gate. Reusing
/// an entry is safe because the fingerprint captures the checker's complete input set
/// (see ``CheckerFingerprint``) — an identical fingerprint means an identical result.
public struct ResultCache: Sendable {

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

    /// Returns the cached result for the key, or nil on a miss or unreadable/corrupt entry.
    public func load(checkerId: String, fingerprint: String) -> CheckResult? {
        let url = entryURL(checkerId: checkerId, fingerprint: fingerprint)
        // silent: an unreadable or absent cache entry is intentionally treated as a miss
        guard let data = try? Data(contentsOf: url) else { return nil }
        // silent: a corrupt/malformed entry is intentionally a miss, never a crash
        return try? JSONDecoder().decode(CheckResult.self, from: data)
    }

    /// Stores a result under the key. Failures are ignored — a cache write must never
    /// fail the gate.
    public func store(_ result: CheckResult, checkerId: String, fingerprint: String) {
        // silent: cache writes are best-effort; a write failure must never fail the gate
        try? writeEntry(result, checkerId: checkerId, fingerprint: fingerprint)
    }

    /// When the entry for the key was written, or nil if there is none.
    ///
    /// The run that produced a cached result is the fact a reader most needs and the
    /// one the result itself does not carry: `CheckResult` records a duration, not a
    /// date. Taken from the entry's modification time, which is when the run that
    /// produced it finished.
    public func entryDate(checkerId: String, fingerprint: String) -> Date? {
        let url = entryURL(checkerId: checkerId, fingerprint: fingerprint)
        // silent: a missing or unreadable attribute is simply "no date to report"
        return try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Removes the entry for the key, if one exists.
    ///
    /// Used to evict a result that must never be replayed. Best-effort, like every
    /// other cache operation: a failed removal must never fail the gate, and the
    /// worst case is that the entry is re-evicted on the next read.
    public func remove(checkerId: String, fingerprint: String) {
        // silent: eviction is best-effort; a removal failure must never fail the gate
        try? FileManager.default.removeItem(
            at: entryURL(checkerId: checkerId, fingerprint: fingerprint)
        )
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
        let url = entryURL(checkerId: artifactId, fingerprint: fingerprint)
        // silent: an unreadable or absent cache entry is intentionally treated as a miss
        guard let data = try? Data(contentsOf: url) else { return nil }
        // silent: a corrupt/malformed entry is intentionally a miss, never a crash
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Stores a derived artifact under the key. Failures are ignored — a cache write
    /// must never fail the gate.
    public func storeArtifact<T: Encodable>(_ value: T, artifactId: String, fingerprint: String) {
        // silent: cache writes are best-effort; a write failure must never fail the gate
        try? writeArtifactEntry(value, artifactId: artifactId, fingerprint: fingerprint)
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
