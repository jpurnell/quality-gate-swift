import Foundation
import QualityGateCore
@testable import DependencyAdvisory

/// A throwaway project directory holding the lockfiles and snapshot a test asks for.
struct AdvisoryTestProject {

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-advisory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ text: String, to relativePath: String) throws {
        try write(Data(text.utf8), to: relativePath)
    }

    func write(_ data: Data, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // A leftover temporary directory is the system's to clean; the test's verdict is unaffected.
            print("could not remove \(root.path): \(error.localizedDescription)")
        }
    }

    /// The configuration a checker receives for this project.
    func configuration(_ dependencyAudit: DependencyAuditorConfig = .default) -> Configuration {
        var configuration = Configuration()
        configuration.projectRoot = root
        configuration.dependencyAudit = dependencyAudit
        return configuration
    }
}

/// A transport that answers from a closure and remembers what it was asked.
actor RecordingTransport: AdvisoryTransport {

    private let respond: @Sendable (AdvisoryRequest) throws -> Data
    private(set) var requests: [AdvisoryRequest] = []

    init(_ respond: @escaping @Sendable (AdvisoryRequest) throws -> Data) {
        self.respond = respond
    }

    func send(_ request: AdvisoryRequest) async throws -> Data {
        requests.append(request)
        return try respond(request)
    }
}

/// The error a transport raises when the network is not there.
struct OfflineError: Error, LocalizedError {
    var errorDescription: String? { "The Internet connection appears to be offline." }
}

extension AdvisoryEnvironment {
    /// An environment with nothing live in it: the given snapshot, a fixed day, and a transport
    /// that fails the test's expectations loudly if a hermetic checker ever reaches for it.
    static func fixed(
        bundled: SnapshotCandidate? = nil,
        today: String = "2026-10-06",
        transport: any AdvisoryTransport = RecordingTransport { _ in throw OfflineError() }
    ) -> AdvisoryEnvironment {
        // Noon UTC on `today`, so the UTC date is unambiguous.
        let day = AdvisoryDate(today)?.dayNumber ?? 0
        let instant = Date(timeIntervalSince1970: TimeInterval(day) * 86_400 + 43_200)
        return AdvisoryEnvironment(bundled: { bundled }, now: { instant }, transport: transport)
    }
}
