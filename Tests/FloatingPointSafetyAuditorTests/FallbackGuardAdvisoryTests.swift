import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

private func audit(
    _ source: String,
    filePath: String = "Sources/Statistics/kurt.swift"
) -> FallbackAuditResult {
    FallbackRules.audit(source: source, fileName: filePath)
}

private func advisories(_ source: String, filePath: String = "Sources/Statistics/kurt.swift") -> [Diagnostic] {
    audit(source, filePath: filePath).diagnostics
        .filter { $0.ruleId == FallbackRuleID.guardReturnsAValue }
}

// MARK: - The sites
//
// From BusinessMath at `464cf939`, reduced only by deleting what is not involved.

@Suite("fallback.guard-returns-a-value: the sites")
struct FallbackGuardAdvisorySiteTests {

    // kurt.swift:65-72. `stdDev` is declared in another file, so `s` has no
    // type of its own; it is compared with `T(0)`, and that is one.
    @Test("Kurtosis: the guard on the deviation is a question, the guard on the count is not")
    func kurtosisAsWritten() {
        let code = """
        public func kurtosisS<T: Real>(_ values: [T]) -> T {
            guard values.count >= 4 else { return T(0) }

            let n = T(values.count)
            let s = stdDev(values)

            guard s > T(0) else { return T(0) }
            return n / s
        }
        """
        let found = advisories(code)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 7)
        #expect(found.first?.severity == .note)
        #expect(found.first?.message.contains("'s'") == true)
        #expect(found.first?.message.contains("'T(0)'") == true)
    }

    // The Altman pair: two guards that read the same, of which one is right.
    // The checker cannot tell which. The documentation can.
    @Test("Two identical guards, one documented: exactly one finding")
    func documentedFallbackIsAContract() {
        let code = """
        /// The debt ratio.
        ///
        /// - Returns: Total debt over total value, or 0 if the structure has no value.
        func debtRatio(debt: Double, value: Double) -> Double {
            guard value > 0 else { return 0 }
            return debt / value
        }

        /// The equity ratio.
        ///
        /// - Returns: Total equity over total value.
        func equityRatio(equity: Double, value: Double) -> Double {
            guard value > 0 else { return 0 }
            return equity / value
        }
        """
        let found = advisories(code)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 13)
    }

    // The most expensive defect of the campaign sat behind a guard like this.
    @Test("An empty collection is an answer too")
    func emptyCollectionIsAClaim() {
        let code = """
        func outliers<T: Real>(in values: [T], scale: T) -> [Int] {
            guard scale > T.zero else { return [] }
            return values.indices.filter { values[$0] > scale }
        }
        """
        let found = advisories(code)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
    }

    @Test("So is false")
    func falseIsAClaim() {
        let code = """
        func isOutlier(score: Double, deviation: Double) -> Bool {
            guard deviation > 0 else { return false }
            return score / deviation > 3
        }
        """
        #expect(advisories(code).count == 1)
    }

    @Test("A fallback reached after logging is still a fallback")
    func lastStatementOfElse() {
        let code = """
        func ratio(numerator: Double, denominator: Double) -> Double {
            guard denominator > 0 else {
                record("no denominator")
                return 0
            }
            return numerator / denominator
        }
        """
        let found = advisories(code)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
    }
}

// MARK: - Refusals

@Suite("fallback.guard-returns-a-value: a refusal is not a claim")
struct FallbackGuardAdvisoryRefusalTests {

    @Test("nil, NaN, infinity and throw all decline to answer")
    func refusals() {
        let code = """
        func a(x: Double) -> Double? {
            guard x > 0 else { return nil }
            return 1 / x
        }
        func b(x: Double) -> Double {
            guard x > 0 else { return .nan }
            return 1 / x
        }
        func c<T: Real>(x: T) -> T {
            guard x > T(0) else { return T.nan }
            return T(1) / x
        }
        func d(x: Double) -> Double {
            guard x > 0 else { return .infinity }
            return 1 / x
        }
        func e(x: Double) throws -> Double {
            guard x > 0 else { throw Failure.notPositive }
            return 1 / x
        }
        """
        #expect(advisories(code).isEmpty)
    }

    @Test("A computed fallback is somebody's decision, not a default")
    func computedFallback() {
        let code = """
        func ratio(x: Double, fallback: Double) -> Double {
            guard x > 0 else { return fallback }
            return 1 / x
        }
        """
        #expect(advisories(code).isEmpty)
    }
}

// MARK: - The question already asked

@Suite("fallback.guard-returns-a-value: the question already asked")
struct FallbackGuardAdvisoryAnsweredTests {

    // The shape of the campaign's own fix, `CapitalAllocationOptimizer.roi`.
    @Test("A NaN refused above the guard cannot reach it")
    func nanRefusedAbove() {
        let code = """
        func roi(npv: Double, capital: Double) -> Double {
            guard !capital.isNaN, !npv.isNaN else { return .nan }
            guard capital > 0 else { return 0 }
            return npv / capital
        }
        """
        #expect(advisories(code).isEmpty)
    }

    @Test("A property's documentation that names the fallback")
    func documentedProperty() {
        let code = """
        struct Project {
            let npv: Double
            let capital: Double

            /// Return on investment, or 0 when no capital is required.
            var roi: Double {
                guard capital > 0 else { return 0 }
                return npv / capital
            }

            /// Capital per unit of value.
            var intensity: Double {
                guard npv > 0 else { return 0 }
                return capital / npv
            }
        }
        """
        let found = advisories(code)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 13)
    }

    @Test("Documentation that mentions the number without making it a condition")
    func numberMentionedButNotAsAFallback() {
        let code = """
        /// The share of the total.
        ///
        /// - Returns: A proportion from 0 to 1.
        func share(part: Double, total: Double) -> Double {
            guard total > 0 else { return 0 }
            return part / total
        }
        """
        #expect(advisories(code).count == 1)
    }

    @Test("Documentation that names zero in words")
    func sentinelNamedInWords() {
        let code = """
        /// The share of the total.
        ///
        /// - Returns: The proportion, or zero when there is no total.
        func share<T: Real>(part: T, total: T) -> T {
            guard total > T.zero else { return T.zero }
            return part / total
        }
        """
        #expect(advisories(code).isEmpty)
    }

    @Test("The enclosing function's documentation does not describe a closure's return")
    func closureIsNotTheFunction() {
        let code = """
        /// Scales every value.
        ///
        /// - Returns: The scaled values, or 0 if the scale is not positive.
        func scaled(values: [Double], scale: Double) -> [Double] {
            return values.map { value in
                guard value > 0.0 else { return 0 }
                return value / scale
            }
        }
        """
        #expect(advisories(code).count == 1)
    }
}

// MARK: - Justification

@Suite("fallback.guard-returns-a-value: justification")
struct FallbackGuardAdvisoryJustificationTests {

    @Test("A justification on the line above is recorded, not dropped")
    func justificationIsRecorded() {
        let code = """
        func share(part: Double, total: Double) -> Double {
            // fallback-justified: a proportion of an empty total is zero
            guard total > 0 else { return 0 }
            return part / total
        }
        """
        let result = audit(code)
        #expect(result.diagnostics.isEmpty)
        #expect(result.overrides.count == 1)
        #expect(result.overrides.first?.ruleId == FallbackRuleID.guardReturnsAValue)
        #expect(result.overrides.first?.lineNumber == 3)
        #expect(result.overrides.first?.justification == "a proportion of an empty total is zero")
    }

    @Test("A justification with no reason is a finding, and justifies nothing")
    func emptyJustification() {
        let code = """
        func share(part: Double, total: Double) -> Double {
            // fallback-justified:
            guard total > 0 else { return 0 }
            return part / total
        }
        """
        let result = audit(code)
        #expect(result.overrides.isEmpty)
        let empty = result.diagnostics.filter { $0.ruleId == FallbackRuleID.justificationEmpty }
        #expect(empty.count == 1)
        #expect(empty.first?.severity == .warning)
        #expect(empty.first?.lineNumber == 2)
        #expect(result.diagnostics.filter { $0.ruleId == FallbackRuleID.guardReturnsAValue }.count == 1)
    }

    @Test("A justification two lines up belongs to something else")
    func justificationMustBeAdjacent() {
        let code = """
        func share(part: Double, total: Double) -> Double {
            // fallback-justified: a proportion of an empty total is zero
            let scaled = part * 100
            guard total > 0 else { return 0 }
            return scaled / total
        }
        """
        #expect(advisories(code).count == 1)
    }
}

// MARK: - What is not a finding

@Suite("fallback.guard-returns-a-value: what is not a finding")
struct FallbackGuardAdvisoryExclusionTests {

    @Test("An integer cannot be NaN")
    func integerQuantity() {
        let code = """
        func mean(total: Double, count: Int) -> Double {
            guard count > 0 else { return 0 }
            return total / Double(count)
        }
        """
        #expect(advisories(code).isEmpty)
    }

    @Test("A let converted from an integer cannot be NaN")
    func convertedInteger() {
        let code = """
        func mean(total: Double, count: Int) -> Double {
            let n = Double(count)
            guard n > 0 else { return 0 }
            return total / n
        }
        """
        #expect(advisories(code).isEmpty)
    }

    @Test("A name with no type, compared with a bare 0, is skipped")
    func untypedAgainstBareLiteral() {
        let code = """
        func ratio() -> Double {
            let volatility = measure()
            guard volatility > 0 else { return 0 }
            return 1 / volatility
        }
        """
        #expect(advisories(code).isEmpty)
    }

    // `nan != 0` is true, so this guard lets a NaN through. Whatever that is,
    // it is not a fallback given for one.
    @Test("An inequality passes a NaN, so its fallback is not given for one")
    func inequalityGuard() {
        let code = """
        func ratio(part: Double, total: Double) -> Double {
            guard total != 0 else { return 0 }
            return part / total
        }
        """
        #expect(advisories(code).isEmpty)
    }

    // BusinessMath `distributionGeneral.swift`. Outside its support a density
    // is zero, and that is the definition rather than a default.
    @Test("A guard on a range is a domain, not a degenerate case")
    func rangeGuard() {
        let code = """
        func density(x: Double, lower: Double, upper: Double) -> Double {
            guard x >= lower, x <= upper else { return 0 }
            return 1 / (upper - lower)
        }
        """
        #expect(advisories(code).isEmpty)
    }

    @Test("A threshold that stands for zero is zero")
    func nearZeroThreshold() {
        let code = """
        func concordance<T: Real>(s: T, denominator: T) -> T {
            guard abs(denominator) > T.ulpOfOne else { return T(0) }
            return s / denominator
        }
        """
        #expect(advisories(code).count == 1)
    }

    @Test("Test files are not production code")
    func skipsTestFiles() {
        let code = """
        func ratio(part: Double, total: Double) -> Double {
            guard total > 0 else { return 0 }
            return part / total
        }
        """
        #expect(advisories(code, filePath: "Tests/StatsTests/RatioTests.swift").isEmpty)
    }
}

// MARK: - An advisory does not gate

@Suite("fallback.guard-returns-a-value: it is a question, not a verdict")
struct FallbackGuardAdvisoryStatusTests {

    @Test("A file holding only advisories passes")
    func advisoryPasses() async throws {
        let code = """
        func ratio(part: Double, total: Double) -> Double {
            guard total > 0 else { return 0 }
            return part / total
        }
        """
        let result = try await FallbackAuditor().auditSource(
            code,
            fileName: "Sources/Ratio.swift",
            configuration: Configuration()
        )
        #expect(result.status == .passed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.severity == .note)
    }
}
