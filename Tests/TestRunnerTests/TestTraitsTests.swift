import Foundation
import Synchronization
import Testing
@testable import TestRunner
@testable import QualityGateCore

// `swift test` has to run the suite the `build` checker compiled. Without `--traits`, every
// test behind `#if OAuth` in SwiftKeychain was compiled out and never ran — and a run that
// differs in traits from `build` also rebuilds what `build` just built.

private func scratchPackage() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("qg-test-traits-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Tests/PkgTests"), withIntermediateDirectories: true)
    try "// swift-tools-version: 6.1\n".write(
        to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    return root
}

/// What the launcher was asked to run, in order. Checked `Sendable`: the one stored property
/// is a `Mutex`.
private final class Commands: Sendable {
    private let recorded = Mutex<[[String]]>([])

    func record(_ arguments: [String]) {
        recorded.withLock { $0.append(arguments) }
    }

    var all: [[String]] {
        recorded.withLock { $0 }
    }
}

private func recordingRunner(_ seen: Commands) -> TestRunner {
    TestRunner(launcher: ToolLauncher(
        launch: { invocation in
            seen.record(invocation.arguments)
            return .init(
                stdout: "􁁛  Test run with 1 test in 1 suite passed after 0.1 seconds.\n",
                stderr: "", exitCode: 0)
        },
        monotonicSeconds: { 0 },
        load: { nil }))
}

/// Removes a temporary fixture, recording a failure instead of discarding it.
private func removeFixture(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("could not remove the fixture at \(url.path): \(error)")
    }
}

@Suite("test: the configured package traits reach every swift test")
struct TestTraitsTests {

    @Test("The suite runs with the configured traits")
    func suiteRunsWithTraits() async throws {
        let root = try scratchPackage()
        defer { removeFixture(root) }
        let seen = Commands()
        var configuration = Configuration(traits: ["OAuth"])
        configuration.projectRoot = root
        configuration.flipDetector.enabled = false

        _ = try await recordingRunner(seen).check(configuration: configuration)

        #expect(seen.all == [["test", "--parallel", "--traits", "OAuth"]])
    }

    @Test("Stress re-runs use the same traits as the suite they re-run")
    func stressRunsWithTraits() async throws {
        let root = try scratchPackage()
        defer { removeFixture(root) }
        try """
            import Testing
            // TIMING:
            @Test func settles() async {}
            """.write(
                to: root.appendingPathComponent("Tests/PkgTests/SettleTests.swift"),
                atomically: true, encoding: .utf8)
        let seen = Commands()
        var configuration = Configuration(traits: ["OAuth"])
        configuration.projectRoot = root
        configuration.flipDetector.enabled = false
        configuration.stress = StressTestConfig(runs: 2)

        _ = try await recordingRunner(seen).check(configuration: configuration)

        #expect(seen.all.count == 3)
        for command in seen.all {
            #expect(command.contains("--traits"), "\(command)")
            #expect(command.firstIndex(of: "--traits").map { command[$0 + 1] } == "OAuth")
        }
    }

    @Test("A change of traits is a change of package, never a scheduler flip")
    func traitsAreInTheFlipFingerprint() throws {
        let root = try scratchPackage()
        defer { removeFixture(root) }
        let plain = TestRunner.packageFingerprint(projectRoot: root.path, traits: [])
        let traited = TestRunner.packageFingerprint(projectRoot: root.path, traits: ["OAuth"])
        #expect(plain != traited)
        #expect(plain == TestRunner.packageFingerprint(projectRoot: root.path, traits: []))
    }
}
