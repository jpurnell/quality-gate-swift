import Foundation
import Testing
@testable import DocLinter
@testable import QualityGateCore

// A DocC build stopped at its budget was `✗ [doc-lint] FAILED` and nothing else: the exit
// code failed the checker, and no line of a half-finished transcript is a DocC diagnostic.
// A failure with no diagnostic reads like a hang, and was retried like one.

// Justification: `recorded` is only touched under `lock`; the class holds no other state.
private final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ToolLauncher.Invocation] = []

    func record(_ invocation: ToolLauncher.Invocation) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(invocation)
    }

    var invocations: [ToolLauncher.Invocation] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

private let kernelNote =
    "\nprocess-kernel: `/usr/bin/swift` timed out after 1500s and was terminated."

@Suite("doc-lint: stopped at the budget, or failed without a DocC diagnostic")
struct DocLintExpiryTests {

    private func run(exitCode: Int32, stdout: String, stderr: String = "", elapsed: TimeInterval) -> ToolRun {
        ToolRun(
            checkerId: "doc-lint",
            command: "swift package generate-documentation --target Core",
            directory: "/work/pkg",
            stdout: stdout, stderr: stderr, exitCode: exitCode,
            budget: CheckerBudget.Allowance(checkerId: "doc-lint", seconds: 1_500, source: .lastSuccess(500)),
            elapsed: elapsed, load: MachineLoad(oneMinute: 150, activeProcessors: 12))
    }

    @Test("A cut-off DocC build is one error that names the budget, the elapsed time and the load")
    func expiryIsReported() throws {
        let cutOff = run(
            exitCode: 124,
            stdout: "Building for debugging...\nGenerating documentation for 'Core'...\n",
            stderr: kernelNote, elapsed: 1_504)

        let result = DocLinter.createResult(run: cutOff, duration: .seconds(1_504))

        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["doc-lint-timeout"])
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message == """
            `swift package generate-documentation --target Core` was stopped at its time \
            budget and did not finish. This run is incomplete: it is not a pass, and it is not \
            a finding about the code.
              checker: doc-lint
              budget:  1500s — three times the last successful run (500s), and never less than 900s
              elapsed: 1504s
              load:    1-minute load average 150.0 on 12 cores (12.5 per core)
              last 2 lines of output:
                | Building for debugging...
                | Generating documentation for 'Core'...
            """)
        #expect(diagnostic.suggestedFix == """
            Rerun this checker alone, when the load is lower: `quality-gate --check doc-lint`. \
            If it needs longer than 1500s on a quiet machine, raise its budget in \
            .quality-gate.yml — `budgets:` then `doc-lint: 3000` (seconds).
            """)
    }

    @Test("A failed DocC run with no error it could parse says what the tool printed")
    func unparsedFailureIsReported() throws {
        let crashed = run(
            exitCode: 1,
            stdout: "Building for debugging...\nsymbolgraph-extract: Segmentation fault: 11\n",
            elapsed: 48)

        let result = DocLinter.createResult(run: crashed, duration: .seconds(48))

        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["doc-lint-unparsed-failure"])
        let message = try #require(result.diagnostics.first?.message)
        #expect(message == """
            `swift package generate-documentation --target Core` exited 1 and nothing it \
            printed is a diagnostic this checker can parse. It was not stopped by its time \
            budget.
              checker: doc-lint
              budget:  1500s — three times the last successful run (500s), and never less than 900s
              elapsed: 48s
              load:    1-minute load average 150.0 on 12 cores (12.5 per core)
              last 2 lines of output:
                | Building for debugging...
                | symbolgraph-extract: Segmentation fault: 11
            """)
    }

    @Test("A failed DocC run that printed an error reports the error, and nothing about parsing")
    func parsedErrorNeedsNoExplanation() {
        let failed = run(exitCode: 1, stdout: "error: Unable to resolve topic reference\n", elapsed: 48)
        let result = DocLinter.createResult(run: failed, duration: .seconds(48))
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.message) == ["Unable to resolve topic reference"])
    }

    // MARK: - The checker, end to end, with nothing launched

    @Test("DocC runs under the checker's budget, and an expiry is in the result the checker returns")
    func expirySurvivesTheWholeCheck() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-doclint-expiry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
        let catalogue = root.appendingPathComponent("Sources/Core/Core.docc")
        try FileManager.default.createDirectory(at: catalogue, withIntermediateDirectories: true)
        try "# ``Core``\n\nA module.\n".write(
            to: catalogue.appendingPathComponent("Core.md"), atomically: true, encoding: .utf8)
        try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Core",
                products: [.library(name: "Core", targets: ["Core"])],
                targets: [.target(name: "Core")]
            )
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let seen = Launches()
        let linter = DocLinter(launcher: ToolLauncher(
            launch: { invocation in
                seen.record(invocation)
                return .init(stdout: "Building for debugging...\n", stderr: kernelNote, exitCode: 124)
            },
            monotonicSeconds: { 0 },
            load: { MachineLoad(oneMinute: 150, activeProcessors: 12) }))
        var configuration = Configuration(budgets: try CheckerBudgetsConfig(["doc-lint": 1_500]))
        configuration.projectRoot = root

        let result = try await linter.check(configuration: configuration)

        #expect(seen.invocations.map(\.timeout) == [1_500])
        #expect(seen.invocations.first?.arguments == ["package", "generate-documentation", "--target", "Core"])
        #expect(result.status == .failed)
        let expiry = try #require(result.diagnostics.first { $0.ruleId == "doc-lint-timeout" })
        #expect(expiry.severity == .error)
        #expect(expiry.message.contains("\n  budget:  1500s — set by `budgets.doc-lint` in .quality-gate.yml\n"))
        #expect(CheckerBudget.lastSuccess(named: "doc-lint", root: root.path) == nil)
    }
}
