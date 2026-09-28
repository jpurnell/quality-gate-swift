import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

private func classificationFindings(
    _ source: String,
    filePath: String = "Sources/TVM/NPV.swift"
) -> [Diagnostic] {
    FallbackRules.audit(source: source, fileName: filePath)
        .diagnostics
        .filter { $0.ruleId == FallbackRuleID.classificationOmitsNaN }
}

// MARK: - The sites that answered
//
// From BusinessMath at `464cf939`.

@Suite("fallback.classification-omits-nan: the sites that answered")
struct FallbackClassificationSiteTests {

    // `profitabilityIndex`. A NaN cash flow was dropped, and the project still
    // got a verdict.
    @Test("Two arms and no else: a NaN is dropped")
    func flagsTwoArmsWithoutElse() {
        let code = """
        func profitabilityIndex<T: Real>(rate: T, cashFlows: [T]) -> T {
            var pvPositive = T.zero
            var pvNegative = T.zero
            for flow in cashFlows {
                if flow > T.zero {
                    pvPositive = pvPositive + flow
                } else if flow < T.zero {
                    pvNegative = pvNegative + flow
                }
            }
            return pvPositive + pvNegative
        }
        """
        let findings = classificationFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 5)
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.message.contains("'flow'") == true)
        #expect(findings.first?.message.contains("neither arm") == true)
    }

    // `detectTrend`. A NaN slope was reported as a downward trend.
    @Test("A trailing else inherits the NaN, through abs()")
    func flagsTrailingElse() {
        let code = """
        func direction(slope: Double) -> String {
            if abs(slope) < 0.1 {
                return "flat"
            } else if slope > 0 {
                return "upward"
            } else {
                return "downward"
            }
        }
        """
        let findings = classificationFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 2)
        #expect(findings.first?.message.contains("trailing else") == true)
    }

    // The proposal's own test 3.
    @Test("if slope > 0.1, else if slope > 0, else")
    func flagsProposalFixture() {
        let code = """
        func direction(slope: Double) -> Int {
            if slope > 0.1 { return 2 } else if slope > 0 { return 1 } else { return 0 }
        }
        """
        #expect(classificationFindings(code).count == 1)
    }

    @Test("A chain of three arms is reported once, at its head")
    func reportsChainOnce() {
        let code = """
        func grade(score: Double) -> String {
            if score >= 0.9 {
                return "A"
            } else if score >= 0.8 {
                return "B"
            } else if score >= 0.7 {
                return "C"
            } else {
                return "F"
            }
        }
        """
        let findings = classificationFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 2)
    }
}

// MARK: - What answers the question

@Suite("fallback.classification-omits-nan: what answers the question")
struct FallbackClassificationGuardTests {

    @Test("An arm of the chain tests isNaN: no finding")
    func acceptsIsNaNArm() {
        let code = """
        func direction(slope: Double) -> String {
            if slope.isNaN {
                return "unknown"
            } else if slope > 0 {
                return "upward"
            } else if slope < 0 {
                return "downward"
            } else {
                return "flat"
            }
        }
        """
        #expect(classificationFindings(code).isEmpty)
    }

    @Test("An isFinite guard before the chain: no finding")
    func acceptsGuardBeforeChain() {
        let code = """
        func direction(slope: Double) -> String {
            guard slope.isFinite else { return "unknown" }
            if slope > 0 { return "upward" } else if slope < 0 { return "downward" } else { return "flat" }
        }
        """
        #expect(classificationFindings(code).isEmpty)
    }

    @Test("A test after the chain answers nothing")
    func flagsTestAfterChain() {
        let code = """
        func direction(slope: Double) -> String {
            var label = "flat"
            if slope > 0 { label = "upward" } else if slope < 0 { label = "downward" }
            if slope.isNaN { label = "unknown" }
            return label
        }
        """
        let findings = classificationFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 3)
    }
}

// MARK: - What is not a finding

@Suite("fallback.classification-omits-nan: what is not a finding")
struct FallbackClassificationExclusionTests {

    @Test("One comparison and an else is a test, not a classification")
    func ignoresSingleComparison() {
        let code = """
        func sign(value: Double) -> Int {
            if value > 0 { return 1 } else { return 0 }
        }
        """
        #expect(classificationFindings(code).isEmpty)
    }

    @Test("An integer classified")
    func ignoresInteger() {
        let code = """
        func sign(count: Int) -> Int {
            if count > 0 { return 1 } else if count < 0 { return -1 } else { return 0 }
        }
        """
        #expect(classificationFindings(code).isEmpty)
    }

    // BusinessMath `CreditMetrics.swift:275`. Two different quantities, and
    // `nan != 0` is true.
    @Test("Arms that test different values are not a classification of one")
    func ignoresDifferentSubjects() {
        let code = """
        func component(totalLiabilities: Double, marketValue: Double) -> Double {
            if totalLiabilities != 0 {
                return marketValue / totalLiabilities
            } else if marketValue > 0 {
                return .infinity
            } else {
                return 0
            }
        }
        """
        #expect(classificationFindings(code).isEmpty)
    }

    @Test("An arm that tests something else as well is not a plain classification")
    func ignoresCompoundCondition() {
        let code = """
        func direction(slope: Double, enabled: Bool) -> Int {
            if slope > 0, enabled { return 1 } else if slope < 0 { return -1 } else { return 0 }
        }
        """
        #expect(classificationFindings(code).isEmpty)
    }

    @Test("A name whose type is not known is skipped")
    func ignoresUnknownName() {
        let code = """
        func direction() -> Int {
            if somethingElsewhere > 0 { return 1 } else if somethingElsewhere < 0 { return -1 } else { return 0 }
        }
        """
        #expect(classificationFindings(code).isEmpty)
    }

    @Test("Test files are not production code")
    func skipsTestFiles() {
        let code = """
        func direction(slope: Double) -> Int {
            if slope > 0 { return 1 } else if slope < 0 { return -1 } else { return 0 }
        }
        """
        #expect(classificationFindings(code, filePath: "Tests/TVMTests/NPVTests.swift").isEmpty)
    }
}
