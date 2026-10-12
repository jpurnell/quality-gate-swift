import Foundation
import Testing
@testable import QualityGateCore

// The key a timeout message tells the reader to set. If the message names it, it has to
// exist, it has to be obeyed exactly, and a mistake in it has to be loud — a budget that is
// written down and ignored is the same silent failure the message was added to end.

@Suite("budgets: the configured time budget for a checker")
struct CheckerBudgetsConfigTests {

    @Test("An absent key configures nothing")
    func absentKeyIsEmpty() throws {
        let configuration = try Configuration.from(yaml: "enabledCheckers: []\n")
        #expect(configuration.budgets == .default)
        #expect(configuration.budgets.seconds(for: "test") == nil)
        #expect(configuration.unknownKeys == nil)
    }

    @Test("A budget is read for each checker that has one, in seconds")
    func budgetsAreRead() throws {
        let configuration = try Configuration.from(yaml: """
            budgets:
              test: 1800
              build: 1200.5
              doc-lint: 2400
              xcode-build: 900
            """)
        #expect(configuration.budgets.seconds(for: "test") == 1_800)
        #expect(configuration.budgets.seconds(for: "build")?.isEqual(to: 1_200.5) == true)
        #expect(configuration.budgets.seconds(for: "doc-lint") == 2_400)
        #expect(configuration.budgets.seconds(for: "xcode-build") == 900)
        #expect(configuration.unknownKeys == nil)
    }

    @Test("A key that names no budgeted checker stops the run and lists the ones that exist")
    func unknownCheckerIsRefused() {
        let refusal = #expect(throws: CheckerBudgetsConfig.Invalid.unknownChecker("tests")) {
            try Configuration.from(yaml: "budgets:\n  tests: 1800\n")
        }
        #expect(refusal?.errorDescription
            == "`budgets.tests` names no checker that has a time budget. "
                + "Budgets apply to: build, doc-lint, test, xcode-build.")
    }

    @Test("A budget that is not a positive finite number of seconds is refused", arguments: [
        ("0", "0.0"), ("-30", "-30.0"), (".inf", "inf"), (".nan", "nan"), ("2000000000", "2000000000.0"),
    ])
    func nonsenseBudgetIsRefused(written: String, shown: String) {
        let refusal = #expect(throws: CheckerBudgetsConfig.Invalid.self) {
            try Configuration.from(yaml: "budgets:\n  test: \(written)\n")
        }
        #expect(refusal?.errorDescription
            == "`budgets.test` is \(shown), and a budget is a number of seconds greater than "
                + "zero and no more than 1000000000.")
    }

    @Test("A refused budget read from a file keeps its type, so the command line can stop on it")
    func refusalSurvivesLoadingFromAFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-budgets-\(UUID().uuidString).yml")
        try "budgets:\n  doc_lint: 900\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) } // silent: best-effort cleanup of a temporary fixture
        #expect(throws: CheckerBudgetsConfig.Invalid.unknownChecker("doc_lint")) {
            try Configuration.load(from: file.path)
        }
    }

    @Test("A configured budget survives encoding, so it is part of the configuration's identity")
    func roundTrips() throws {
        let budgets = try CheckerBudgetsConfig(["test": 1_800])
        let data = try JSONEncoder().encode(Configuration(budgets: budgets))
        let decoded = try JSONDecoder().decode(Configuration.self, from: data)
        #expect(decoded.budgets == budgets)
    }

    // MARK: - What a checker is allowed

    @Test("A configured budget is used exactly: not raised to the floor, not scaled")
    func configuredBudgetIsExact() {
        let allowance = CheckerBudget.allowance(for: "test", configured: 120, lastSuccess: 400)
        #expect(allowance == CheckerBudget.Allowance(checkerId: "test", seconds: 120, source: .configured))
        #expect(allowance.explanation == "set by `budgets.test` in .quality-gate.yml")
    }

    @Test("With nothing configured the budget follows the last successful run")
    func derivedBudgetFollowsHistory() {
        let allowance = CheckerBudget.allowance(for: "build", configured: nil, lastSuccess: 400)
        #expect(allowance == CheckerBudget.Allowance(checkerId: "build", seconds: 1_200, source: .lastSuccess(400)))
        #expect(allowance.explanation
            == "three times the last successful run (400s), and never less than 900s")
    }

    @Test("With nothing configured and nothing recorded, the first-run budget applies")
    func firstRunBudget() {
        let allowance = CheckerBudget.allowance(for: "build", configured: nil, lastSuccess: nil)
        #expect(allowance == CheckerBudget.Allowance(checkerId: "build", seconds: 3_600, source: .firstRun))
        #expect(allowance.explanation
            == "the first-run budget, because no successful run is recorded yet")
    }

    @Test("A recorded duration that is not a duration is no record, never an unbounded budget",
          arguments: [Double.infinity, -Double.infinity, Double.nan, 0, -5])
    func nonsenseHistoryIsNoHistory(recorded: Double) {
        let allowance = CheckerBudget.allowance(for: "test", configured: nil, lastSuccess: recorded)
        #expect(allowance == CheckerBudget.Allowance(checkerId: "test", seconds: 3_600, source: .firstRun))
        #expect(CheckerBudget.seconds(lastSuccess: recorded) == 3_600)
    }

    @Test("A record on disk that reads as infinity is no record")
    func infiniteRecordOnDiskIsIgnored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-budget-\(UUID().uuidString)")
        let build = root.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        try "inf\n".write(
            to: build.appendingPathComponent("quality-gate-duration-test"),
            atomically: true, encoding: .utf8)
        #expect(CheckerBudget.lastSuccess(named: "test", root: root.path) == nil)
    }

    @Test("A tool that keeps no history runs under the configured figure, or the runner's default")
    func fixedAllowance() throws {
        let unset = CheckerBudget.fixedAllowance(for: "xcode-build", configuration: Configuration())
        #expect(unset == CheckerBudget.Allowance(checkerId: "xcode-build", seconds: 600, source: .runnerDefault))
        #expect(unset.explanation == "the process runner's default; no `budgets.xcode-build` is set")

        let configured = Configuration(budgets: try CheckerBudgetsConfig(["xcode-build": 1_500]))
        #expect(CheckerBudget.fixedAllowance(for: "xcode-build", configuration: configured)
            == CheckerBudget.Allowance(checkerId: "xcode-build", seconds: 1_500, source: .configured))
    }
}
