import Foundation
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

// Justification: `recorded` is only touched under `lock`; the class holds no other state.
private final class Commands: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    func record(_ arguments: [String]) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(arguments)
    }

    var all: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
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

@Suite("test: the configured package traits reach every swift test")
struct TestTraitsTests {

    @Test("The suite runs with the configured traits")
    func suiteRunsWithTraits() async throws {
        let root = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
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
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
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
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
        let plain = TestRunner.packageFingerprint(projectRoot: root.path, traits: [])
        let traited = TestRunner.packageFingerprint(projectRoot: root.path, traits: ["OAuth"])
        #expect(plain != traited)
        #expect(plain == TestRunner.packageFingerprint(projectRoot: root.path, traits: []))
    }
}
