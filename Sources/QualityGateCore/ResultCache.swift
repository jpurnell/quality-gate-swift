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

    private func writeEntry(_ result: CheckResult, checkerId: String, fingerprint: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) // SAFETY: CLI tool creates its local cache directory
        let data = try JSONEncoder().encode(result)
        try data.write(to: entryURL(checkerId: checkerId, fingerprint: fingerprint))
    }
}
