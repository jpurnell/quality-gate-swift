import Foundation
import Testing
import QualityGateCore
@testable import XcodeBuildChecker

// `xcodebuild` terminated at its budget exits 124 like any failure, so it was reported as
// whatever the failing step would otherwise be called: a scheme listing that "exited 124",
// or a build whose output "matched no diagnostic". Neither says the tool was stopped.

// Justification: `recorded` is only touched under `lock`; the class holds no other state.
private final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [XcodeBuildChecker.Invocation] = []

    func record(_ invocation: XcodeBuildChecker.Invocation) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(invocation)
    }

    var invocations: [XcodeBuildChecker.Invocation] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

private let kernelNote =
    "\nprocess-kernel: `/usr/bin/xcodebuild` timed out after 600s and was terminated."

private func scratchPackage() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("xcode-expiry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\n".write(
        to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    return directory
}

@Suite("Xcode build: stopped at the budget is reported as that")
struct XcodeBuildExpiryTests {

    @Test("A scheme listing stopped at its budget is a timeout, not a listing failure")
    func listExpiryIsNamed() async throws {
        let directory = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: directory) } // silent: best-effort cleanup of a temporary fixture
        let seen = Launches()
        let checker = XcodeBuildChecker(
            parentEnvironment: { ["PATH": "/usr/bin:/bin"] },
            launcher: { invocation in
                seen.record(invocation)
                return .init(
                    stdout: "", stderr: "Resolve Package Graph\n" + kernelNote, exitCode: 124,
                    elapsed: 601, load: MachineLoad(oneMinute: 240, activeProcessors: 12))
            })
        var configuration = Configuration()
        configuration.projectRoot = directory

        let result = try await checker.check(configuration: configuration)

        #expect(seen.invocations.map(\.budget) == [
            CheckerBudget.Allowance(checkerId: "xcode-build", seconds: 600, source: .runnerDefault),
        ])
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["xcode-build-timeout"])
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.message == """
            `xcodebuild -list -json` was stopped at its time budget and did not finish. This \
            run is incomplete: it is not a pass, and it is not a finding about the code.
              checker: xcode-build
              budget:  600s — the process runner's default; no `budgets.xcode-build` is set
              elapsed: 601s
              load:    1-minute load average 240.0 on 12 cores (20.0 per core)
              last 1 line of output:
                | Resolve Package Graph
            """)
        #expect(diagnostic.suggestedFix == """
            Rerun this checker alone, when the load is lower: `quality-gate --check xcode-build`. \
            If it needs longer than 600s on a quiet machine, raise its budget in \
            .quality-gate.yml — `budgets:` then `xcode-build: 1200` (seconds).
            """)
    }

    @Test("A build stopped at its budget is a timeout, not an unexplained failure, and runs under the configured budget")
    func buildExpiryIsNamed() async throws {
        let directory = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: directory) } // silent: best-effort cleanup of a temporary fixture
        let seen = Launches()
        let checker = XcodeBuildChecker(
            parentEnvironment: { ["PATH": "/usr/bin:/bin"] },
            launcher: { invocation in
                seen.record(invocation)
                guard invocation.arguments.first == "build" else {
                    return .init(stdout: "", stderr: "", exitCode: 0)
                }
                return .init(
                    stdout: "CompileSwift normal arm64\n", stderr: kernelNote, exitCode: 124,
                    elapsed: 1_502, load: MachineLoad(oneMinute: 240, activeProcessors: 12))
            })
        var configuration = Configuration(
            xcodeBuild: XcodeBuildCheckerConfig(scheme: "App", destinations: ["generic/platform=macOS"]),
            budgets: try CheckerBudgetsConfig(["xcode-build": 1_500]))
        configuration.projectRoot = directory

        let result = try await checker.check(configuration: configuration)

        #expect(seen.invocations.map(\.budget.seconds) == [1_500])
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["xcode-build-timeout"])
        let message = try #require(result.diagnostics.first?.message)
        #expect(message.hasPrefix(
            "`xcodebuild build -scheme App -destination generic/platform=macOS -quiet` was stopped at its time budget"))
        #expect(message.contains("\n  budget:  1500s — set by `budgets.xcode-build` in .quality-gate.yml\n"))
        #expect(message.contains("\n  elapsed: 1502s\n"))
    }
}
