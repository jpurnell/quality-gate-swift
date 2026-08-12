import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// `--fix`, held to §5.4's four constraints — one test each, plus the boundary with `status`.
@Suite("Region Fix")
struct RegionFixTests {

    private static let errorEnum = """
    public enum QualityGateError: Error {

        /// Swift build failed.
        case buildFailed(exitCode: Int32)

        /// One or more tests failed.
        case testsFailed(count: Int)
    }
    """

    private static let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "example",
        targets: [
            .target(name: "Alpha"),
            .target(name: "Beta"),
        ]
    )
    """

    private static func plan(registry: String, roster: String = "") -> String {
        """
        # Plan

        Prose above that must not move.

        ## Error Registry

        | Error Case | Module | Description |
        |------------|--------|-------------|
        <!-- generated:error-registry -->
        \(registry)
        <!-- /generated:error-registry -->

        ### What's Working
        <!-- generated:status-roster -->
        \(roster)
        <!-- /generated:status-roster -->

        Prose below that must not move.
        """
    }

    private static func project(_ plan: String) throws -> URL {
        try TemporaryDocProject.make(
            masterPlan: plan,
            packageManifest: manifest,
            extras: ["Sources/QualityGateCore/QualityGateError.swift": errorEnum])
    }

    private static func fix(_ root: URL) async throws -> FixResult {
        try await DocGeneratedAuditor().fix(
            projectRoot: root, configuration: TemporaryDocProject.configuration())
    }

    private static func check(_ root: URL) async throws -> CheckResult {
        try await DocGeneratedAuditor().check(
            projectRoot: root, configuration: TemporaryDocProject.configuration())
    }

    private static func planText(_ root: URL) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent("project/master_plan.md"), encoding: .utf8)
    }

    /// One region only, so "everything after the closing delimiter" is genuinely untouched
    /// content rather than a second region that legitimately changed.
    private static func singleRegionPlan(registry: String) -> String {
        """
        # Plan

        Prose above that must not move.

        ## Error Registry

        | Error Case | Module | Description |
        |------------|--------|-------------|
        <!-- generated:error-registry -->
        \(registry)
        <!-- /generated:error-registry -->

        Prose below that must not move.
        """
    }

    @Test("Constraint 1: not one byte outside the delimiters changes")
    func onlyTheBodyChanges() async throws {
        let root = try Self.project(Self.singleRegionPlan(registry: "| stale | row | here |"))
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try Self.planText(root)
        _ = try await Self.fix(root)
        let after = try Self.planText(root)

        let marker = "<!-- generated:error-registry -->"
        let closing = "<!-- /generated:error-registry -->"
        let beforePrefix = try #require(before.range(of: marker)).upperBound
        let afterPrefix = try #require(after.range(of: marker)).upperBound

        #expect(String(before[..<beforePrefix]) == String(after[..<afterPrefix]))
        let beforeSuffix = try #require(before.range(of: closing)).lowerBound
        let afterSuffix = try #require(after.range(of: closing)).lowerBound
        #expect(String(before[beforeSuffix...]) == String(after[afterSuffix...]))
        #expect(after.contains("Prose above that must not move."))
        #expect(after.contains("Prose below that must not move."))
    }

    @Test("Constraint 2: a roster gains its missing module and nothing else is rewritten")
    func rosterFixChangesExactlyOneLine() async throws {
        let root = try Self.project(Self.plan(
            registry: "| stale |", roster: "- [x] Alpha — done, and this sentence is the author's"))
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await Self.fix(root)
        let after = try Self.planText(root)
        let roster = try #require(after.range(of: "<!-- generated:status-roster -->"))
        let close = try #require(after.range(of: "<!-- /generated:status-roster -->"))
        let body = String(after[roster.upperBound..<close.lowerBound])
            .lines.filter { !$0.isEmpty }

        #expect(body.count == 2)
        // The tick-box and the description survive verbatim; only `Beta` is new.
        #expect(body[0] == "- [x] Alpha — done, and this sentence is the author's")
        #expect(body[1].hasPrefix("- [ ] Beta"))
    }

    @Test("Constraint 3: fixing twice is fixing once")
    func idempotent() async throws {
        let root = try Self.project(Self.plan(registry: "| stale | row | here |"))
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await Self.fix(root)
        let afterFirst = try Self.planText(root)
        let second = try await Self.fix(root)
        let afterSecond = try Self.planText(root)

        #expect(afterFirst == afterSecond)
        #expect(!second.hasChanges)
    }

    @Test("The fix makes the check pass, which is how its correctness is verified")
    func fixMakesTheCheckPass() async throws {
        let root = try Self.project(Self.plan(registry: "| stale | row | here |"))
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try await Self.check(root)
        #expect(before.status == .failed)

        _ = try await Self.fix(root)

        let after = try await Self.check(root)
        #expect(after.status == .passed)
        #expect(!after.diagnostics.contains { $0.severity == .error })
    }

    @Test("A region whose generator cannot run is left alone, and stays reported")
    func ungeneratableRegionIsNotTouched() async throws {
        // No `QualityGateError` anywhere, so `error-registry` throws. Writing *something* here
        // would be inventing content; the region keeps its bytes and keeps its finding.
        let root = try TemporaryDocProject.make(
            masterPlan: Self.plan(registry: "| a row nobody can regenerate |"),
            packageManifest: Self.manifest)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.fix(root)
        let after = try Self.planText(root)

        #expect(after.contains("| a row nobody can regenerate |"))
        #expect(result.unfixed.contains { $0.ruleId == "doc-generated.region-ungeneratable" })
    }

    @Test("A file with no stale region is not rewritten at all")
    func cleanFileIsNotTouched() async throws {
        let root = try Self.project(Self.plan(registry: "| stale |"))
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await Self.fix(root)
        let settled = try Self.planText(root)

        let second = try await Self.fix(root)

        #expect(!second.hasChanges)
        #expect(second.modifications.isEmpty)
        #expect(try Self.planText(root) == settled)
    }

    @Test("CRLF line endings outside the region survive the fix")
    func crlfIsPreserved() async throws {
        // The reason this does not split the file into lines and join it back: that would
        // rewrite every line ending in the document while repairing three rows.
        let root = try Self.project(
            Self.plan(registry: "| stale |").replacingOccurrences(of: "\n", with: "\r\n"))
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await Self.fix(root)
        let after = try Self.planText(root)

        #expect(after.contains("Prose above that must not move.\r\n"))
        // The generated rows carry the file's own ending too, so the document does not end up
        // with two conventions in it.
        #expect(after.contains("\r\n<!-- /generated:error-registry -->"))
        #expect(!after.contains("|\n"))
    }

    @Test("The declared fix description says which files it will rewrite")
    func fixDescriptionIsHonest() {
        let description = DocGeneratedAuditor().fixDescription
        #expect(description.contains("region"))
        #expect(!description.isEmpty)
    }
}
