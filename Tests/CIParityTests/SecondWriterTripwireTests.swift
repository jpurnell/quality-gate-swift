import Foundation
import Testing
import CorpusKit

/// Phase 2 §4b — the tripwire end-to-end: a corpus seeded with a second
/// writer must surface the standing warning in the very next gate run's
/// output. Warning-only: the run's exit code is untouched.
@Suite("Second-writer tripwire acceptance", .serialized)
struct SecondWriterTripwireTests {

    private final class BundleToken {}

    private enum TripwireError: Error {
        case binaryNotFound
    }

    private static func gateBinary() throws -> URL {
        let productsDirectory = Bundle(for: BundleToken.self).bundleURL
            .deletingLastPathComponent()
        let candidate = productsDirectory.appendingPathComponent("quality-gate")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw TripwireError.binaryNotFound
        }
        return candidate
    }

    private func makeFixture(corpus: URL) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tripwire-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let sources = root.appendingPathComponent("Sources/Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Demo", targets: [.target(name: "Demo")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        /// A demo type.
        public struct Demo {}
        """.write(to: sources.appendingPathComponent("Demo.swift"), atomically: true, encoding: .utf8)
        try """
        legibility:
          useIndexStore: false
        consistency:
          corpusPath: "\(corpus.path)"
          projectID: "tripwire-fixture"
        """.write(to: root.appendingPathComponent(".quality-gate.yml"), atomically: true, encoding: .utf8)
        return root
    }

    private func seed(owner: String, corpus: CorpusPath, at timestamp: Date) async throws {
        let metadata = CheckResultMetadata(
            projectID: "tripwire-fixture",
            timestamp: timestamp,
            environment: .local,
            decisionOwner: owner,
            results: [],
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil,
            host: "\(owner)-machine.local")
        try await TelemetryWriter().write(metadata: metadata, calibrations: [], to: corpus)
    }

    private func runGate(cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = try Self.gateBinary()
        process.arguments = ["--check", "legibility", "--no-index-build"]
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("GIT_") }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// The owner identity the gate run itself will record (its own telemetry
    /// lands in the corpus too — seeds must not accidentally add a person).
    private var currentUser: String {
        ProcessInfo.processInfo.environment["USER"] ?? "local"
    }

    @Test("a seeded second writer trips the warning on the next gate run")
    func secondWriterTripsNextRun() async throws {
        let corpusDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tripwire-corpus-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let fixture = try makeFixture(corpus: corpusDir)
        let corpus = CorpusPath(basePath: corpusDir.path, projectID: "tripwire-fixture")

        // Seed history: the owner and a second person, both recent.
        try await seed(owner: currentUser, corpus: corpus, at: Date().addingTimeInterval(-3_600))
        try await seed(owner: "contributor", corpus: corpus, at: Date().addingTimeInterval(-7_200))

        let output = try runGate(cwd: fixture)
        #expect(output.contains("multi-writer activity detected"))
        #expect(output.contains("Phase 3"))
        // Warning-only: the gate itself still passes (legibility is advisory).
        #expect(output.contains("Quality Gate: PASSED"))
    }

    @Test("a single-writer corpus stays quiet")
    func singleWriterQuiet() async throws {
        let corpusDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tripwire-solo-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let fixture = try makeFixture(corpus: corpusDir)
        let corpus = CorpusPath(basePath: corpusDir.path, projectID: "tripwire-fixture")
        try await seed(owner: currentUser, corpus: corpus, at: Date().addingTimeInterval(-3_600))

        let output = try runGate(cwd: fixture)
        #expect(!output.contains("multi-writer activity detected"))
    }
}
