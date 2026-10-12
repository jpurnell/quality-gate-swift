import Foundation
import QualityGateTestKit
import ProcessKernel
import QualityGateCore
import Testing
import CorpusKit
import GateCI

/// Phase 2 §4b — the tripwire end-to-end: a corpus seeded with a second
/// writer must surface the standing warning in the very next gate run's
/// output. Warning-only: the run's exit code is untouched.
@Suite("Second-writer tripwire acceptance", .serialized)
struct SecondWriterTripwireTests {


    private enum TripwireError: Error {
        case binaryNotFound
    }

    private static func gateBinary() throws -> URL {
        guard let binary = BuiltProducts.gateBinary else {

            throw TripwireError.binaryNotFound

        }

        return binary
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
        // The bounded runner, not a hand-rolled Process: this spawns the gate, whose output
        // exceeds the pipe buffer, and the old wait-then-read ordering could deadlock.
        // `ProcessKernel.ProcessRunner`, qualified: CorpusKit 1.16.0 added a public type of the
        // same name, and this file sees both. The ambiguity was invisible while `IJSSensor`
        // re-exported CorpusKit — the compiler silently picked one. Naming the module is the
        // fix; the import is explicit now, so the conflict is too.
        let result = try ProcessKernel.ProcessRunner.run(
            try Self.gateBinary().path,
            arguments: ["--check", "legibility", "--no-index-build"],
            currentDirectory: cwd.path,
            environment: ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") },
            mergeStderr: true,
            timeout: 300)
        return result.stdout
    }

    /// The person identity the gate run itself will record (its own telemetry
    /// lands in the corpus too — seeds must not accidentally add a person).
    ///
    /// Resolved the way ``WriterCensus`` resolves it, which is the whole point: the census
    /// counts `ciIdentity?.actor ?? decisionOwner`, so under a provider-verified run the
    /// gate's own record is filed under the CI actor and not under `USER`. This helper read
    /// `USER` alone, so on GitHub Actions the seed landed as `local` while the gate's record
    /// landed as the actor — two persons for one writer, and the single-writer fixture tripped
    /// the very warning it exists to prove absent.
    ///
    /// It passed everywhere it had ever run, because it had only ever run where `USER` and the
    /// configured owner happened to be the same string. Not a Linux defect: any GitHub Actions
    /// job would have shown it, and Linux CI was simply the first to run this suite.
    private var currentUser: String {
        let environment = ProcessInfo.processInfo.environment
        if let verified = CIIdentityProbe.detect(environment: environment) {
            return verified.actor
        }
        return environment["USER"] ?? "local"
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
