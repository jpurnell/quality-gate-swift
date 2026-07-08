import Foundation

/// On-disk store of the most recent test roster per package key.
///
/// Mirrors ``ResultCache``'s safety posture: best-effort and corruption-safe — an
/// unreadable or malformed entry is treated as "no prior data" (never a crash), and a
/// write failure never fails the gate. The stored record lets the flip detector compare
/// the current run against the last one (see ``FlipDetector``).
public struct TestOutcomeStore: Sendable {

    private let directory: URL

    /// Creates a store backed by `directory`.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The default store location under the project's `.build`.
    public static func standard(projectRoot: URL) -> TestOutcomeStore {
        TestOutcomeStore(
            directory: projectRoot
                .appendingPathComponent(".build")
                .appendingPathComponent("quality-gate-cache")
                .appendingPathComponent("test-outcomes")
        )
    }

    private func entryURL(key: String) -> URL {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safeKey).json")
    }

    /// Exposed for tests to corrupt a specific entry.
    func entryURLForTesting(key: String) -> URL { entryURL(key: key) }

    /// Returns the most recent record for `key`, or nil on a miss or unreadable/corrupt entry.
    public func loadLatest(key: String) -> TestRunRecord? {
        let url = entryURL(key: key)
        // silent: an absent or unreadable entry is intentionally treated as no prior data
        guard let data = try? Data(contentsOf: url) else { return nil }
        // silent: a corrupt/malformed entry is intentionally no prior data, never a crash
        return try? JSONDecoder().decode(TestRunRecord.self, from: data)
    }

    /// Stores `record` as the latest for `key`. Failures are ignored — persisting the
    /// roster must never fail the gate.
    public func storeLatest(_ record: TestRunRecord, key: String) {
        // silent: roster persistence is best-effort; a write failure must never fail the gate
        try? writeEntry(record, key: key)
    }

    private func writeEntry(_ record: TestRunRecord, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) // SAFETY: CLI tool creates its local state directory
        let data = try JSONEncoder().encode(record)
        try data.write(to: entryURL(key: key))
    }
}
