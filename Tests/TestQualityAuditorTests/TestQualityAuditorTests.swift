import Testing
import TestQualityAuditor
import QualityGateCore

@Suite
struct TestQualityAuditorTests {

    private let auditor = TestQualityAuditor()
    private let config = Configuration()

    // MARK: - Exact Double Equality

    @Test
    func detectsExactDoubleEquality() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(result == 0.3989)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        #expect(result.status == .failed)

        let diag = try #require(result.diagnostics.first { $0.ruleId == "exact-double-equality" })
        #expect(diag.severity == .error)
    }

    @Test
    func allowsToleranceComparison() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(abs(result - 0.3989) < 1e-6)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let exactEqualityDiags = result.diagnostics.filter { $0.ruleId == "exact-double-equality" }
        #expect(exactEqualityDiags.isEmpty)
    }

    @Test
    func allowsExactIntegerEquality() async throws {
        let source = """
        import Testing

        @Test func testCount() {
            let count = items.count
            #expect(count == 5)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let exactEqualityDiags = result.diagnostics.filter { $0.ruleId == "exact-double-equality" }
        #expect(exactEqualityDiags.isEmpty)
    }

    // MARK: - Force Try

    @Test
    func detectsForceTryInTest() async throws {
        let source = """
        import Testing

        @Test func testParsing() {
            let data = try! loadTestData()
            #expect(data.count > 0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        #expect(result.status == .failed)

        let diag = try #require(result.diagnostics.first { $0.ruleId == "force-try-in-test" })
        #expect(diag.severity == .error)
    }

    @Test
    func allowsRegularTry() async throws {
        let source = """
        import Testing

        @Test func testParsing() throws {
            let data = try loadTestData()
            #expect(data.count > 0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let forceTryDiags = result.diagnostics.filter { $0.ruleId == "force-try-in-test" }
        #expect(forceTryDiags.isEmpty)
    }

    // MARK: - Unseeded Randomness

    @Test
    func detectsUnseededRandom() async throws {
        let source = """
        import Testing

        @Test func testRandomSample() {
            let value = Double.random(in: 0...1)
            #expect(value >= 0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = try #require(result.diagnostics.first { $0.ruleId == "unseeded-random" })
        #expect(diag.severity == .warning)
    }

    @Test
    func detectsSystemRandomNumberGenerator() async throws {
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
        // SystemRandomNumberGenerator reference flagged; .random(using:) is not flagged
        #expect(diags.count >= 1)
    }

    @Test
    func allowsSeededGenerator() async throws {
        let source = """
        import Testing

        @Test func testDeterministic() {
            var rng = SeededGenerator(state: 42)
            let value = Int.random(in: 1...10, using: &rng)
            #expect(value == 7)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        // .random(using: &rng) is seeded, so no unseeded-random diagnostics at all.
        let randomDiags = result.diagnostics.filter { $0.ruleId == "unseeded-random" }
        #expect(randomDiags.isEmpty, ".random(using:) with seeded generator should not be flagged")
    }

    @Test
    func allowsEnumCaseNamedRandom() async throws {
        let source = """
        import Testing

        enum PlayerType { case human, random, greedy }

        @Test func testPlayerTypes() {
            let type = PlayerType.random
            #expect(type == .random)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let randomDiags = result.diagnostics.filter { $0.ruleId == "unseeded-random" }
        #expect(randomDiags.isEmpty, "Enum case .random should not be flagged as unseeded randomness")
    }

    @Test
    func stillDetectsRandomMethodCall() async throws {
        let source = """
        import Testing

        @Test func testRandom() {
            let value = Int.random(in: 1...10)
            #expect(value >= 1)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = try #require(result.diagnostics.first { $0.ruleId == "unseeded-random" }, ".random() method call should still be flagged")
        #expect(diag.ruleId == "unseeded-random")
    }

    @Test
    func allowsRandomWithUsingParameter() async throws {
        let source = """
        import Testing

        @Test func testDeterministicRandom() {
            var rng = DeterministicRNG(seed: 42)
            let config = StrategicConfig.random(using: &rng)
            #expect(config.attackThreshold >= 0.8)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let randomDiags = result.diagnostics.filter { $0.ruleId == "unseeded-random" }
        #expect(randomDiags.isEmpty, ".random(using: &rng) with seeded generator should not be flagged")
    }

    // MARK: - Missing Assertions

    @Test
    func detectsMissingAssertions() async throws {
        let source = """
        import Testing

        @Test func testSomething() {
            let result = compute()
            print(result)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = try #require(result.diagnostics.first { $0.ruleId == "missing-assertion" })
        #expect(diag.severity == .warning)
    }

    @Test
    func noFalsePositiveForExpect() async throws {
        let source = """
        import Testing

        @Test func testSomething() {
            let result = compute()
            #expect(result > 0)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = result.diagnostics.first { $0.ruleId == "missing-assertion" }
        #expect(diag == nil)
    }

    @Test
    func noFalsePositiveForRequire() async throws {
        let source = """
        import Testing

        @Test func testSomething() throws {
            let result = try #require(compute())
            doSomething(result)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = result.diagnostics.first { $0.ruleId == "missing-assertion" }
        #expect(diag == nil)
    }

    // MARK: - Weak Assertions

    @Test
    func detectsWeakAssertionNotEqualZero() async throws {
        // Build source with a weak `!= 0` assertion for the auditor to flag
        let weakLine = "#expect(result != 0)"
        let source = """
        import Testing

        @Test func testCompute() {
            let result = compute()
            \(weakLine)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = try #require(result.diagnostics.first { $0.ruleId == "weak-assertion" })
        #expect(diag.severity == .warning)
    }

    @Test
    func detectsWeakAssertionNotEqualNil() async throws {
        // Build source with a weak `!= nil` assertion for the auditor to flag
        let weakLine = "#expect(result != nil)"
        let source = """
        import Testing

        @Test func testCompute() {
            let result = compute()
            \(weakLine)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = try #require(result.diagnostics.first { $0.ruleId == "weak-assertion" })
        #expect(diag.severity == .warning)
    }

    @Test
    func allowsStrongAssertion() async throws {
        let source = """
        import Testing

        @Test func testCompute() {
            let result = compute()
            #expect(result == 42)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let weakDiags = result.diagnostics.filter { $0.ruleId == "weak-assertion" }
        #expect(weakDiags.isEmpty)
    }

    // MARK: - Exemptions

    @Test
    func exemptionWithSafetyComment() async throws {
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
        #expect(exactEqualityDiags.isEmpty)
    }

    @Test
    func exemptionWithTestQualityComment() async throws {
        // Build source with a weak assertion preceded by a TEST-QUALITY exemption comment
        let weakLine = "#expect(result != nil)"
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            // TEST-QUALITY: nil check is intentional guard before further assertions
            \(weakLine)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let weakDiags = result.diagnostics.filter { $0.ruleId == "weak-assertion" }
        #expect(weakDiags.count == 0, "Expected TEST-QUALITY comment to exempt the weak assertion")
    }

    // MARK: - Hardcoded Date Detection

    @Test
    func detectsHardcodedDateInNilCoalescing() async throws {
        let source = """
        import Testing

        private func makeMetadata(timestamp: Date? = nil) -> String {
            let ts = timestamp ?? makeDate("2026-05-15")
            return ts.description
        }

        @Test func testMeta() {
            let meta = makeMetadata()
            #expect(!meta.isEmpty)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diag = try #require(result.diagnostics.first { $0.ruleId == "hardcoded-date" })
        #expect(diag.severity == .warning)
    }

    @Test
    func allowsHardcodedDateInDirectAssignment() async throws {
        let source = """
        import Testing

        @Test func testSomething() {
            let date = makeDate("2026-05-20")
            #expect(date?.description.isEmpty == false)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diags = result.diagnostics.filter { $0.ruleId == "hardcoded-date" }
        #expect(diags.isEmpty)
    }

    @Test
    func allowsDistantPastDateInNilCoalescing() async throws {
        let source = """
        import Testing

        private func helper(date: Date? = nil) -> Date {
            return date ?? makeDate("2020-01-01")
        }

        @Test func testFixture() {
            let date = helper()
            #expect(date?.description.isEmpty == false)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diags = result.diagnostics.filter { $0.ruleId == "hardcoded-date" }
        #expect(diags.isEmpty)
    }

    @Test
    func allowsNonDateString() async throws {
        let source = """
        import Testing

        @Test func testLabel() {
            let label = "hello-world"
            #expect(label == "hello-world")
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diags = result.diagnostics.filter { $0.ruleId == "hardcoded-date" }
        #expect(diags.isEmpty)
    }

    @Test
    func hardcodedDateExemption() async throws {
        let source = """
        import Testing

        private func helper(date: Date? = nil) -> Date {
            // TEST-QUALITY: fixed date for deterministic snapshot
            return date ?? makeDate("2026-05-20")
        }

        @Test func testSnapshot() {
            let date = helper()
            #expect(date?.description.isEmpty == false)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diags = result.diagnostics.filter { $0.ruleId == "hardcoded-date" }
        #expect(diags.isEmpty)
    }

    @Test
    func allowsWeekLabelString() async throws {
        let source = """
        import Testing

        @Test func testPulse() {
            let label = "2026-W17"
            #expect(label.contains("W"))
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        let diags = result.diagnostics.filter { $0.ruleId == "hardcoded-date" }
        #expect(diags.isEmpty)
    }

    // MARK: - Checker Identity

    @Test
    func checkerIdAndName() {
        #expect(auditor.id == "test-quality")
        #expect(auditor.name == "Test Quality Auditor")
    }

    // MARK: - Clean File Passes

    @Test
    func cleanFilePasses() async throws {
        let source = """
        import Testing

        @Test func testComputation() throws {
            let result = try compute()
            #expect(abs(result - 0.3989) < 1e-6)
            #expect(result > 0.39)
        }
        """

        let result = try await auditor.auditSource(source, fileName: "test.swift", configuration: config)
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test
    func emptyFilePasses() async throws {
        let source = """
        import Foundation
        // No tests here
        """

        let result = try await auditor.auditSource(source, fileName: "helper.swift", configuration: config)
        #expect(result.status == .passed)
    }
}
