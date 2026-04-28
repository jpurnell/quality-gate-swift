import XCTest
import TestQualityAuditor
import QualityGateCore

final class TestQualityAuditorTests: XCTestCase {

    private let auditor = TestQualityAuditor()
    private let config = Configuration()

    // MARK: - Exact Double Equality

    func testDetectsExactDoubleEquality() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(result == 0.3989)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        XCTAssertEqual(result.status, .failed)

        let diag = result.diagnostics.first { $0.ruleId == "exact-double-equality" }
        XCTAssertNotNil(diag)
        XCTAssertEqual(diag?.severity, .error)
    }

    func testAllowsToleranceComparison() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(abs(result - 0.3989) < 1e-6)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let exactEqualityDiags = result.diagnostics.filter { $0.ruleId == "exact-double-equality" }
        XCTAssertTrue(exactEqualityDiags.isEmpty)
    }

    func testAllowsExactIntegerEquality() async throws {
        let source = """
        import Testing

        @Test func testCount() {
            let count = items.count
            #expect(count == 5)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let exactEqualityDiags = result.diagnostics.filter { $0.ruleId == "exact-double-equality" }
        XCTAssertTrue(exactEqualityDiags.isEmpty)
    }

    // MARK: - Force Try

    func testDetectsForceTryInTest() async throws {
        let source = """
        import Testing

        @Test func testParsing() {
            let data = try! loadTestData()
            #expect(data.count > 0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        XCTAssertEqual(result.status, .failed)

        let diag = result.diagnostics.first { $0.ruleId == "force-try-in-test" }
        XCTAssertNotNil(diag)
        XCTAssertEqual(diag?.severity, .error)
    }

    func testAllowsRegularTry() async throws {
        let source = """
        import Testing

        @Test func testParsing() throws {
            let data = try loadTestData()
            #expect(data.count > 0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let forceTryDiags = result.diagnostics.filter { $0.ruleId == "force-try-in-test" }
        XCTAssertTrue(forceTryDiags.isEmpty)
    }

    // MARK: - Unseeded Randomness

    func testDetectsUnseededRandom() async throws {
        let source = """
        import Testing

        @Test func testRandomSample() {
            let value = Double.random(in: 0...1)
            #expect(value >= 0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = result.diagnostics.first { $0.ruleId == "unseeded-random" }
        XCTAssertNotNil(diag)
        XCTAssertEqual(diag?.severity, .warning)
    }

    func testDetectsSystemRandomNumberGenerator() async throws {
        let source = """
        import Testing

        @Test func testRandom() {
            var rng = SystemRandomNumberGenerator()
            let value = Int.random(in: 1...10, using: &rng)
            #expect(value >= 1)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diags = result.diagnostics.filter { $0.ruleId == "unseeded-random" }
        // SystemRandomNumberGenerator reference + .random call
        XCTAssertGreaterThanOrEqual(diags.count, 1)
    }

    func testAllowsSeededGenerator() async throws {
        let source = """
        import Testing

        @Test func testDeterministic() {
            var rng = SeededGenerator(state: 42)
            let value = Int.random(in: 1...10, using: &rng)
            #expect(value == 7)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        // SeededGenerator is fine, but .random will still flag.
        // The key is that SystemRandomNumberGenerator is not used.
        let sysRngDiags = result.diagnostics.filter {
            $0.ruleId == "unseeded-random" && $0.message.contains("SystemRandomNumberGenerator")
        }
        XCTAssertTrue(sysRngDiags.isEmpty)
    }

    // MARK: - Missing Assertions

    func testDetectsMissingAssertions() async throws {
        let source = """
        import Testing

        @Test func testSomething() {
            let result = compute()
            print(result)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = result.diagnostics.first { $0.ruleId == "missing-assertion" }
        XCTAssertNotNil(diag)
        XCTAssertEqual(diag?.severity, .warning)
    }

    func testNoFalsePositiveForExpect() async throws {
        let source = """
        import Testing

        @Test func testSomething() {
            let result = compute()
            #expect(result > 0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = result.diagnostics.first { $0.ruleId == "missing-assertion" }
        XCTAssertNil(diag)
    }

    func testNoFalsePositiveForRequire() async throws {
        let source = """
        import Testing

        @Test func testSomething() throws {
            let result = try #require(compute())
            doSomething(result)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = result.diagnostics.first { $0.ruleId == "missing-assertion" }
        XCTAssertNil(diag)
    }

    // MARK: - Weak Assertions

    func testDetectsWeakAssertionNotEqualZero() async throws {
        let source = """
        import Testing

        @Test func testCompute() {
            let result = compute()
            #expect(result != 0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = result.diagnostics.first { $0.ruleId == "weak-assertion" }
        XCTAssertNotNil(diag)
        XCTAssertEqual(diag?.severity, .warning)
    }

    func testDetectsWeakAssertionNotEqualNil() async throws {
        let source = """
        import Testing

        @Test func testCompute() {
            let result = compute()
            #expect(result != nil)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = result.diagnostics.first { $0.ruleId == "weak-assertion" }
        XCTAssertNotNil(diag)
    }

    func testAllowsStrongAssertion() async throws {
        let source = """
        import Testing

        @Test func testCompute() {
            let result = compute()
            #expect(result == 42)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let weakDiags = result.diagnostics.filter { $0.ruleId == "weak-assertion" }
        XCTAssertTrue(weakDiags.isEmpty)
    }

    // MARK: - Exemptions

    func testExemptionWithSafetyComment() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            // SAFETY: exact comparison intentional for integer-valued double
            #expect(result == 0.0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let exactEqualityDiags = result.diagnostics.filter { $0.ruleId == "exact-double-equality" }
        XCTAssertTrue(exactEqualityDiags.isEmpty)
    }

    func testExemptionWithTestQualityComment() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            // TEST-QUALITY: nil check is intentional guard before further assertions
            #expect(result != nil)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let weakDiags = result.diagnostics.filter { $0.ruleId == "weak-assertion" }
        XCTAssertTrue(weakDiags.isEmpty)
    }

    // MARK: - Checker Identity

    func testCheckerIdAndName() {
        XCTAssertEqual(auditor.id, "test-quality")
        XCTAssertEqual(auditor.name, "Test Quality Auditor")
    }

    // MARK: - Clean File Passes

    func testCleanFilePasses() async throws {
        let source = """
        import Testing

        @Test func testComputation() throws {
            let result = try compute()
            #expect(abs(result - 0.3989) < 1e-6)
            #expect(result > 0.39)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testEmptyFilePasses() async throws {
        let source = """
        import Foundation
        // No tests here
        """

        let result = try await auditor.auditSource(source, fileName: "helper.swift", configuration: config)
        XCTAssertEqual(result.status, .passed)
    }
}
