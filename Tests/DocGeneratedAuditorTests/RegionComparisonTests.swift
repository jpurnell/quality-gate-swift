import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// Comparison behaviour: what counts as a match, what counts as stale, and what a
/// regeneration that never happened counts as.
@Suite("Region Comparison")
struct RegionComparisonTests {

    private static let errorEnum = """
    /// Errors that can occur during quality gate execution.
    public enum QualityGateError: Error {

        /// Swift build failed with the given exit code and output.
        case buildFailed(exitCode: Int32, output: String)
    }
    """

    private static let correctRow =
        "| `QualityGateError.buildFailed` | QualityGateCore | Swift build failed with the given exit code and output. |"

    private static func project(regionBody: String) throws -> URL {
        try TemporaryDocProject.make(
            masterPlan: """
            ## Error Registry

            | Error Case | Module | Description |
            |------------|--------|-------------|
            <!-- generated:error-registry -->
            \(regionBody)
            <!-- /generated:error-registry -->
            """,
            extras: ["Sources/QualityGateCore/QualityGateError.swift": errorEnum])
    }

    private static func run(_ root: URL) async throws -> CheckResult {
        try await DocGeneratedAuditor().check(
            projectRoot: root, configuration: TemporaryDocProject.configuration())
    }

    @Test("A region byte-identical to its generator's output passes")
    func identicalPasses() async throws {
        let root = try Self.project(regionBody: Self.correctRow)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(root)

        #expect(result.status == .passed)
        let coverage = try #require(result.diagnostics.first { $0.ruleId == "doc-generated.coverage" })
        #expect(coverage.message.contains("1 found"))
        #expect(coverage.message.contains("1 regenerated"))
    }

    @Test("A region differing by one character is stale")
    func oneCharacterIsStale() async throws {
        let root = try Self.project(
            regionBody: Self.correctRow.replacingOccurrences(of: "exit code", with: "exit-code"))
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(root)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "doc-generated.region-missing-line" })
        #expect(result.diagnostics.contains { $0.ruleId == "doc-generated.region-extra-line" })
    }

    @Test("A region differing only in trailing whitespace is stale, and says so")
    func trailingWhitespaceIsStale() async throws {
        // The comparator a reimplementation gets wrong first. "Close enough" is not the
        // claim: the claim is that the region *is* what the generator produced.
        let root = try Self.project(regionBody: Self.correctRow + "   ")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(root)

        #expect(result.status == .failed)
        let finding = try #require(result.diagnostics.first {
            $0.ruleId == "doc-generated.region-whitespace"
        })
        #expect(finding.severity == .error)
    }

    @Test("A region holding the right rows in the wrong order is stale, and says so")
    func reorderedRowsAreStale() async throws {
        // Found by `checker-table`, which produces rows in registry order against a README
        // whose rows a person had arranged. `missing` and `unexpected` are multiset
        // comparisons, so a permutation empties both while `matches` stays false — and
        // `staleness` returned no findings at all. A byte-mismatched region that reports
        // nothing is the one outcome this checker must never produce: it is indistinguishable
        // from a pass, in the exact place the whole design says silence is not allowed.
        let root = try TemporaryDocProject.make(
            masterPlan: """
            ## Error Registry

            | Error Case | Module | Description |
            |------------|--------|-------------|
            <!-- generated:error-registry -->
            | `QualityGateError.testsFailed` | QualityGateCore | One or more tests failed. |
            | `QualityGateError.buildFailed` | QualityGateCore | Swift build failed. |
            <!-- /generated:error-registry -->
            """,
            extras: ["Sources/QualityGateCore/QualityGateError.swift": """
            public enum QualityGateError: Error {

                /// Swift build failed.
                case buildFailed(exitCode: Int32)

                /// One or more tests failed.
                case testsFailed(count: Int)
            }
            """])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(root)

        #expect(result.status == .failed)
        let finding = try #require(result.diagnostics.first {
            $0.ruleId == "doc-generated.region-order"
        })
        #expect(finding.severity == .error)
    }

    @Test("A region that is byte-correct in a file whose generator threw is a finding, not a pass")
    func generatorThrowIsAFinding() async throws {
        // The `6bd6109` lesson restated: a compilation that never happened is not a pass, and
        // a regeneration that never happened is not a match. Here the enum the generator
        // derives from does not exist, so the region cannot be checked at all.
        let root = try TemporaryDocProject.make(masterPlan: """
        <!-- generated:error-registry -->
        | `QualityGateError.buildFailed` | QualityGateCore | anything at all |
        <!-- /generated:error-registry -->
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(root)

        let finding = try #require(result.diagnostics.first {
            $0.ruleId == "doc-generated.region-ungeneratable"
        })
        #expect(finding.severity == .error)
        #expect(result.status == .failed)
    }

    @Test("A registered generator that matches no region is counted, not silently unused")
    func unusedGeneratorsAreCounted() async throws {
        let root = try TemporaryDocProject.make(readme: "# No regions here\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(root)
        let coverage = try #require(result.diagnostics.first { $0.ruleId == "doc-generated.coverage" })

        #expect(coverage.message.contains("\(RegionGeneratorRegistry.ids.count) generators unused"))
    }

    @Test("Every finding names what the region is derived from, because sometimes it is the generator that is wrong")
    func findingsNameTheirSource() async throws {
        let root = try Self.project(regionBody: "| nonsense |")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(root)
        let stale = result.diagnostics.filter {
            $0.ruleId?.hasPrefix("doc-generated.region-") == true
        }
        #expect(!stale.isEmpty)
        #expect(stale.allSatisfy { $0.message.contains("derived from") })
    }
}
