import Foundation
import Testing
@testable import DocCoverageChecker
@testable import QualityGateCore

/// Tests for DocCoverageIndexPass pure analysis functions.
///
/// All tests exercise the static analysis methods directly,
/// without requiring a live IndexStoreDB session.
@Suite("DocCoverageChecker: Index-backed Pass 2 rules")
struct DocCoverageIndexPassTests {

    // MARK: - Rule 1: Inherited documentation detection

    @Test("Inherited doc from protocol requirement emits doc-inherited info")
    func inheritedDocFromProtocolRequirement() {
        let undocumented = [
            DocCoverageIndexPass.UndocumentedAPI(
                name: "doSomething",
                apiType: "function",
                filePath: "MyExtension.swift",
                line: 10,
                usr: "s:4MyLib0A8ProtocolP11doSomethingyyF"
            )
        ]
        let protocolDocs: [String: Bool] = [
            "s:4MyLib0A8ProtocolP11doSomethingyyF": true
        ]

        let (inherited, remaining) = DocCoverageIndexPass.classifyInheritedDocs(
            undocumentedAPIs: undocumented,
            protocolRequirementDocs: protocolDocs
        )

        #expect(inherited.count == 1)
        #expect(inherited.first?.ruleId == "doc-inherited")
        #expect(inherited.first?.severity == .note)
        #expect(inherited.first?.message.contains("doSomething") == true)
        #expect(inherited.first?.message.contains("inherits documentation") == true)
        #expect(remaining.isEmpty)
    }

    @Test("No inherited doc when protocol requirement is also undocumented")
    func noInheritedDocWhenRequirementUndocumented() {
        let undocumented = [
            DocCoverageIndexPass.UndocumentedAPI(
                name: "doSomething",
                apiType: "function",
                filePath: "MyExtension.swift",
                line: 10,
                usr: "s:4MyLib0A8ProtocolP11doSomethingyyF"
            )
        ]
        let protocolDocs: [String: Bool] = [
            "s:4MyLib0A8ProtocolP11doSomethingyyF": false
        ]

        let (inherited, remaining) = DocCoverageIndexPass.classifyInheritedDocs(
            undocumentedAPIs: undocumented,
            protocolRequirementDocs: protocolDocs
        )

        #expect(inherited.isEmpty)
        #expect(remaining.count == 1)
        #expect(remaining.first?.name == "doSomething")
    }

    @Test("No inherited doc for non-protocol method (no USR match)")
    func noInheritedDocForNonProtocolMethod() {
        let undocumented = [
            DocCoverageIndexPass.UndocumentedAPI(
                name: "helperMethod",
                apiType: "function",
                filePath: "MyType.swift",
                line: 5,
                usr: "s:4MyLib0A4TypeC12helperMethodyyF"
            )
        ]
        let protocolDocs: [String: Bool] = [
            "s:4MyLib0A8ProtocolP11doSomethingyyF": true
        ]

        let (inherited, remaining) = DocCoverageIndexPass.classifyInheritedDocs(
            undocumentedAPIs: undocumented,
            protocolRequirementDocs: protocolDocs
        )

        #expect(inherited.isEmpty)
        #expect(remaining.count == 1)
    }

    @Test("No inherited doc for API without USR")
    func noInheritedDocWithoutUSR() {
        let undocumented = [
            DocCoverageIndexPass.UndocumentedAPI(
                name: "someFunction",
                apiType: "function",
                filePath: "File.swift",
                line: 3,
                usr: nil
            )
        ]
        let protocolDocs: [String: Bool] = [
            "s:4MyLib0A8ProtocolP11doSomethingyyF": true
        ]

        let (inherited, remaining) = DocCoverageIndexPass.classifyInheritedDocs(
            undocumentedAPIs: undocumented,
            protocolRequirementDocs: protocolDocs
        )

        #expect(inherited.isEmpty)
        #expect(remaining.count == 1)
    }

    @Test("Multiple APIs with mixed inheritance status")
    func mixedInheritanceStatus() {
        let undocumented = [
            DocCoverageIndexPass.UndocumentedAPI(
                name: "inherited1", apiType: "function",
                filePath: "A.swift", line: 1,
                usr: "usr:inherited1"
            ),
            DocCoverageIndexPass.UndocumentedAPI(
                name: "notInherited", apiType: "function",
                filePath: "B.swift", line: 2,
                usr: "usr:notInherited"
            ),
            DocCoverageIndexPass.UndocumentedAPI(
                name: "inherited2", apiType: "property",
                filePath: "C.swift", line: 3,
                usr: "usr:inherited2"
            ),
        ]
        let protocolDocs: [String: Bool] = [
            "usr:inherited1": true,
            "usr:inherited2": true,
            "usr:notInherited": false,
        ]

        let (inherited, remaining) = DocCoverageIndexPass.classifyInheritedDocs(
            undocumentedAPIs: undocumented,
            protocolRequirementDocs: protocolDocs
        )

        #expect(inherited.count == 2)
        #expect(remaining.count == 1)
        #expect(remaining.first?.name == "notInherited")
    }

    // MARK: - Rule 2: Usage-priority ranking

    @Test("Usage priority ranking sorts by reference count descending")
    func usagePrioritySortsByReferenceCount() {
        let undocumented = [
            DocCoverageIndexPass.UndocumentedAPI(
                name: "rarelyUsed", apiType: "function",
                filePath: "A.swift", line: 1
            ),
            DocCoverageIndexPass.UndocumentedAPI(
                name: "heavilyUsed", apiType: "function",
                filePath: "B.swift", line: 5
            ),
            DocCoverageIndexPass.UndocumentedAPI(
                name: "moderatelyUsed", apiType: "property",
                filePath: "C.swift", line: 10
            ),
        ]
        let referenceCounts: [String: Int] = [
            "rarelyUsed": 2,
            "heavilyUsed": 50,
            "moderatelyUsed": 15,
        ]

        let diagnostics = DocCoverageIndexPass.rankByUsage(
            undocumentedAPIs: undocumented,
            referenceCounts: referenceCounts,
            topN: 10
        )

        #expect(diagnostics.count == 3)
        #expect(diagnostics[0].message.contains("heavilyUsed") == true)
        #expect(diagnostics[0].message.contains("50 reference") == true)
        #expect(diagnostics[1].message.contains("moderatelyUsed") == true)
        #expect(diagnostics[2].message.contains("rarelyUsed") == true)
        #expect(diagnostics.allSatisfy { $0.ruleId == "doc-usage-priority" })
        #expect(diagnostics.allSatisfy { $0.severity == .note })
    }

    @Test("Usage priority respects topN limit")
    func usagePriorityRespectsTopN() {
        let undocumented = (1...5).map { idx in
            DocCoverageIndexPass.UndocumentedAPI(
                name: "func\(idx)", apiType: "function",
                filePath: "File.swift", line: idx
            )
        }
        let referenceCounts = Dictionary(uniqueKeysWithValues: (1...5).map { ("func\($0)", $0 * 10) })

        let diagnostics = DocCoverageIndexPass.rankByUsage(
            undocumentedAPIs: undocumented,
            referenceCounts: referenceCounts,
            topN: 3
        )

        #expect(diagnostics.count == 3)
        // Top 3 by count: func5 (50), func4 (40), func3 (30)
        #expect(diagnostics[0].message.contains("func5") == true)
        #expect(diagnostics[1].message.contains("func4") == true)
        #expect(diagnostics[2].message.contains("func3") == true)
    }

    @Test("Usage priority excludes APIs with zero references")
    func usagePriorityExcludesZeroReferences() {
        let undocumented = [
            DocCoverageIndexPass.UndocumentedAPI(
                name: "unused", apiType: "function",
                filePath: "A.swift", line: 1
            ),
            DocCoverageIndexPass.UndocumentedAPI(
                name: "used", apiType: "function",
                filePath: "B.swift", line: 5
            ),
        ]
        let referenceCounts: [String: Int] = [
            "unused": 0,
            "used": 3,
        ]

        let diagnostics = DocCoverageIndexPass.rankByUsage(
            undocumentedAPIs: undocumented,
            referenceCounts: referenceCounts,
            topN: 10
        )

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains("used") == true)
    }

    @Test("Usage priority returns empty for all-zero references")
    func usagePriorityEmptyForAllZero() {
        let undocumented = [
            DocCoverageIndexPass.UndocumentedAPI(
                name: "func1", apiType: "function",
                filePath: "A.swift", line: 1
            ),
        ]
        let referenceCounts: [String: Int] = [:]

        let diagnostics = DocCoverageIndexPass.rankByUsage(
            undocumentedAPIs: undocumented,
            referenceCounts: referenceCounts,
            topN: 10
        )

        #expect(diagnostics.isEmpty)
    }

    // MARK: - Adjusted summary

    @Test("Adjusted summary reports explicit and effective percentages")
    func adjustedSummaryReportsPercentages() {
        let summary = DocCoverageIndexPass.adjustedSummary(
            totalAPIs: 100,
            explicitlyDocumented: 70,
            inheritedCount: 10,
            threshold: nil
        )

        #expect(summary.ruleId == "doc-coverage-summary")
        #expect(summary.message.contains("70% explicit") == true)
        #expect(summary.message.contains("80% effective") == true)
        #expect(summary.message.contains("10 inherited") == true)
    }

    @Test("Effective coverage used for threshold evaluation — above effective means pass")
    func effectiveCoveragePassesThreshold() {
        // Explicit: 70%, effective: 80%, threshold: 75%
        // Should pass because effective >= threshold
        let summary = DocCoverageIndexPass.adjustedSummary(
            totalAPIs: 100,
            explicitlyDocumented: 70,
            inheritedCount: 10,
            threshold: 75
        )

        #expect(summary.severity == .note)
    }

    @Test("Effective coverage below threshold reports warning")
    func effectiveCoverageBelowThresholdWarns() {
        // Explicit: 50%, effective: 60%, threshold: 75%
        let summary = DocCoverageIndexPass.adjustedSummary(
            totalAPIs: 100,
            explicitlyDocumented: 50,
            inheritedCount: 10,
            threshold: 75
        )

        #expect(summary.severity == .warning)
    }

    @Test("Adjusted summary with zero total APIs shows 100%")
    func adjustedSummaryZeroAPIs() {
        let summary = DocCoverageIndexPass.adjustedSummary(
            totalAPIs: 0,
            explicitlyDocumented: 0,
            inheritedCount: 0,
            threshold: nil
        )

        #expect(summary.message.contains("100% explicit") == true)
        #expect(summary.message.contains("100% effective") == true)
        #expect(summary.severity == .note)
    }

    // MARK: - Graceful degradation

    @Test("Emits note diagnostic when index store is unavailable")
    func gracefulDegradationWhenNoIndex() {
        let diagnostic = DocCoverageIndexPass.unavailableNote()
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.ruleId == "doc-coverage.index-pass.skipped")
        #expect(diagnostic.message.contains("Pass 2 skipped") == true)
    }

    // MARK: - Zero undocumented APIs

    @Test("Zero undocumented APIs: inherited classification is no-op")
    func zeroUndocumentedAPIsClassification() {
        let (inherited, remaining) = DocCoverageIndexPass.classifyInheritedDocs(
            undocumentedAPIs: [],
            protocolRequirementDocs: ["usr:1": true]
        )
        #expect(inherited.isEmpty)
        #expect(remaining.isEmpty)
    }

    @Test("Zero undocumented APIs: usage ranking is no-op")
    func zeroUndocumentedAPIsRanking() {
        let diagnostics = DocCoverageIndexPass.rankByUsage(
            undocumentedAPIs: [],
            referenceCounts: ["func1": 10],
            topN: 10
        )
        #expect(diagnostics.isEmpty)
    }

    // MARK: - Configuration

    @Test("Config defaults useIndexStore to true")
    func configDefaultsUseIndexStore() {
        let config = DocCoverageConfig.default
        #expect(config.useIndexStore == true)
    }

    @Test("Config defaults includeTestReferences to false")
    func configDefaultsIncludeTestReferences() {
        let config = DocCoverageConfig.default
        #expect(config.includeTestReferences == false)
    }

    @Test("Config decodes docCoverage from YAML")
    func configDecodesDocCoverage() throws {
        let yaml = """
        docCoverage:
          useIndexStore: false
          includeTestReferences: true
        """
        let config = try Configuration.from(yaml: yaml)
        #expect(config.docCoverage.useIndexStore == false)
        #expect(config.docCoverage.includeTestReferences == true)
    }

    @Test("Config defaults docCoverage when missing from YAML")
    func configDefaultsDocCoverageWhenMissing() throws {
        let yaml = """
        enabledCheckers:
          - doc-coverage
        """
        let config = try Configuration.from(yaml: yaml)
        #expect(config.docCoverage.useIndexStore == true)
        #expect(config.docCoverage.includeTestReferences == false)
    }

    // MARK: - Data type equality

    @Test("UndocumentedAPI equality works correctly")
    func undocumentedAPIEquality() {
        let api1 = DocCoverageIndexPass.UndocumentedAPI(
            name: "func1", apiType: "function",
            filePath: "A.swift", line: 1, usr: "usr:1"
        )
        let api2 = DocCoverageIndexPass.UndocumentedAPI(
            name: "func1", apiType: "function",
            filePath: "A.swift", line: 1, usr: "usr:1"
        )
        let api3 = DocCoverageIndexPass.UndocumentedAPI(
            name: "func2", apiType: "function",
            filePath: "B.swift", line: 2, usr: "usr:2"
        )
        #expect(api1 == api2)
        #expect(api1 != api3)
    }
}
