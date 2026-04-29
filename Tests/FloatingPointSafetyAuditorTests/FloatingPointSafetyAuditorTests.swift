import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

/// Parses a Swift source string and runs the floating-point safety visitor,
/// returning all collected diagnostics. Uses the visitor directly so tests
/// do not require filesystem access.
private func diagnose(
    _ source: String,
    filePath: String = "test.swift",
    checkDivisionGuards: Bool = true
) -> [Diagnostic] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: filePath, tree: tree)
    let visitor = FloatingPointSafetyVisitor(
        filePath: filePath,
        converter: converter,
        sourceLines: source.components(separatedBy: "\n"),
        checkDivisionGuards: checkDivisionGuards
    )
    visitor.walk(tree)
    return visitor.diagnostics
}

// MARK: - Identity Tests

@Suite("FloatingPointSafetyAuditor: Identity")
struct IdentityTests {
    @Test("Checker identity properties")
    func identity() {
        let auditor = FloatingPointSafetyAuditor()
        #expect(auditor.id == "fp-safety")
        #expect(auditor.name == "Floating-Point Safety Auditor")
    }
}

// MARK: - fp-equality Rule Tests

@Suite("FloatingPointSafetyAuditor: fp-equality")
struct FPEqualityTests {
    private let ruleId = "fp-equality"

    // MARK: - Must flag

    @Test("Flags float literal == float literal")
    func flagsFloatLiteralEquality() {
        let code = """
        let x = 1.0
        if x == 1.0 {}
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags float literal != comparison")
    func flagsFloatLiteralInequality() {
        let code = """
        let x = 1.5
        if x != 2.5 {}
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags typed Double variable in equality")
    func flagsTypedDoubleEquality() {
        let code = """
        let x: Double = 1.0
        if x == 1.0 {}
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags typed Float variable in equality")
    func flagsTypedFloatEquality() {
        let code = """
        let x: Float = 1.0
        if x == 1.0 {}
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags typed CGFloat variable in equality")
    func flagsTypedCGFloatEquality() {
        let code = """
        let x: CGFloat = 1.0
        if x == 1.0 {}
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags two float literals compared")
    func flagsTwoFloatLiterals() {
        let code = """
        if 3.14 == 3.14 {}
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must NOT flag (exempt patterns)

    @Test("Does NOT flag comparison to literal 0.0")
    func exemptZeroPointZero() {
        let code = """
        let x = 1.0
        if x == 0.0 {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag comparison to .zero")
    func exemptDotZero() {
        let code = """
        let x: Double = 1.0
        if x == .zero {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag comparison to .nan")
    func exemptDotNan() {
        let code = """
        let x: Double = 1.0
        if x == .nan {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag comparison to .infinity")
    func exemptDotInfinity() {
        let code = """
        let x: Double = 1.0
        if x == .infinity {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag comparison to .greatestFiniteMagnitude")
    func exemptGreatestFiniteMagnitude() {
        let code = """
        let x: Double = 1.0
        if x == .greatestFiniteMagnitude {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag comparison to .leastNormalMagnitude")
    func exemptLeastNormalMagnitude() {
        let code = """
        let x: Double = 1.0
        if x == .leastNormalMagnitude {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag comparison to .leastNonzeroMagnitude")
    func exemptLeastNonzeroMagnitude() {
        let code = """
        let x: Double = 1.0
        if x == .leastNonzeroMagnitude {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag comparison to .pi")
    func exemptDotPi() {
        let code = """
        let x: Double = 1.0
        if x == .pi {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag comparison to .ulpOfOne")
    func exemptDotUlpOfOne() {
        let code = """
        let x: Double = 1.0
        if x == .ulpOfOne {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag integer comparison")
    func exemptIntegerComparison() {
        let code = """
        let x: Int = 5
        if x == 3 {}
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag line with fp-safety:disable comment")
    func exemptLineDisable() {
        let code = """
        let x = 1.0
        if x == 2.0 {} // fp-safety:disable
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Diagnostics have warning severity")
    func warningSeverity() {
        let code = """
        if 1.5 == 2.5 {}
        """
        let results = diagnose(code)
        let fpDiags = results.filter { $0.ruleId == ruleId }
        for diag in fpDiags {
            #expect(diag.severity == .warning)
        }
    }
}

// MARK: - fp-division-unguarded Rule Tests

@Suite("FloatingPointSafetyAuditor: fp-division-unguarded")
struct FPDivisionTests {
    private let ruleId = "fp-division-unguarded"

    // MARK: - Must flag

    @Test("Flags unguarded division by float literal")
    func flagsUnguardedDivision() {
        let code = """
        let divisor = 2.5
        let result = value / divisor
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags /= with float literal divisor")
    func flagsCompoundDivisionAssignment() {
        let code = """
        var x = 10.0
        let d = 2.5
        x /= d
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags typed Double divisor without guard")
    func flagsTypedDoubleDivisor() {
        let code = """
        func compute(divisor: Double) -> Double {
            return 100.0 / divisor
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must NOT flag

    @Test("Does NOT flag guarded division with != 0 check")
    func exemptGuardedNotEqualZero() {
        let code = """
        func compute(divisor: Double) -> Double {
            if divisor != 0 {
                return 100.0 / divisor
            }
            return 0
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag guarded division with > 0 check")
    func exemptGuardedGreaterThanZero() {
        let code = """
        func compute(divisor: Double) -> Double {
            if divisor > 0 {
                return 100.0 / divisor
            }
            return 0
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag guarded division with != .zero check")
    func exemptGuardedNotEqualDotZero() {
        let code = """
        func compute(divisor: Double) -> Double {
            if divisor != .zero {
                return 100.0 / divisor
            }
            return 0
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag division when checkDivisionGuards is disabled")
    func exemptWhenConfigDisabled() {
        let code = """
        let divisor = 2.5
        let result = value / divisor
        """
        let results = diagnose(code, checkDivisionGuards: false)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag integer division")
    func exemptIntegerDivision() {
        let code = """
        let x: Int = 10
        let y: Int = 3
        let result = x / y
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does NOT flag line with fp-safety:disable comment")
    func exemptLineDisable() {
        let code = """
        let divisor = 2.5
        let result = value / divisor // fp-safety:disable
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Diagnostics have warning severity")
    func warningSeverity() {
        let code = """
        let divisor = 2.5
        let result = value / divisor
        """
        let results = diagnose(code)
        let fpDiags = results.filter { $0.ruleId == ruleId }
        for diag in fpDiags {
            #expect(diag.severity == .warning)
        }
    }
}

// MARK: - File Filtering Tests

@Suite("FloatingPointSafetyAuditor: File Filtering")
struct FileFilteringTests {
    @Test("Skips files in Tests/ directory")
    func skipsTestFiles() {
        let code = """
        if 1.5 == 2.5 {}
        """
        let results = diagnose(code, filePath: "Tests/MyTests/SomeTest.swift")
        #expect(results.isEmpty)
    }

    @Test("Audits files in Sources/ directory")
    func auditsSourceFiles() {
        let code = """
        if 1.5 == 2.5 {}
        """
        let results = diagnose(code, filePath: "Sources/MyModule/Something.swift")
        #expect(!results.isEmpty)
    }
}

// MARK: - Integration Tests

@Suite("FloatingPointSafetyAuditor: Integration")
struct IntegrationTests {
    @Test("Full auditor returns passed when no issues")
    func passedWhenClean() async throws {
        let auditor = FloatingPointSafetyAuditor()
        let config = Configuration()
        let result = try await auditor.auditSource(
            "let x: Int = 5\nif x == 3 {}\n",
            fileName: "test.swift",
            configuration: config
        )
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
        #expect(result.checkerId == "fp-safety")
    }

    @Test("Full auditor returns warning status when issues found")
    func warningWhenIssues() async throws {
        let auditor = FloatingPointSafetyAuditor()
        let config = Configuration()
        let result = try await auditor.auditSource(
            "if 1.5 == 2.5 {}\n",
            fileName: "test.swift",
            configuration: config
        )
        #expect(result.status == .warning)
        #expect(!result.diagnostics.isEmpty)
    }
}
