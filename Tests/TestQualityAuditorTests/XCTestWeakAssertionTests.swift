import Testing
import TestQualityAuditor
import QualityGateCore

/// `weak-assertion` — the same claim, written with XCTest.
///
/// `#expect(x != nil)` was reported and `XCTAssertNotNil(x)` was not, so a suite still on
/// XCTest reported no weak assertions at all. BusinessMathExcel reported 0 before its
/// migration and 84 after: the conversion wrote the same 84 claims in the only spelling the
/// rule could read.
///
/// The reference for what counts is the migration table, `AssertionMapping`. An XCTest call
/// is reported exactly when the `#expect` it converts to is reported, so a migration neither
/// adds nor removes a `weak-assertion` finding. The "must not flag" cases below are the
/// forms whose Swift Testing spelling the rule leaves alone: `>`, `==`, and a comparison
/// with `accuracy:`.
@Suite("weak-assertion, XCTest forms")
struct XCTestWeakAssertionTests {

    private let auditor = TestQualityAuditor()

    /// What a finding says, without the file it says it about.
    private struct Finding: Equatable {
        let line: Int?
        let column: Int?
        let severity: Diagnostic.Severity
        let message: String
        let fix: String?
    }

    private static let absentMessage =
        "Weak assertion: XCTAssertNotNil asserts != nil, which does not validate correctness. Assert quantitative bounds."
    private static let notEqualNilMessage =
        "Weak assertion: XCTAssertNotEqual asserts != nil, which does not validate correctness. Assert quantitative bounds."
    private static let notEqualZeroMessage =
        "Weak assertion: XCTAssertNotEqual asserts != 0, which does not validate correctness. Assert quantitative bounds."
    private static let conditionMessage =
        "Weak assertion: != 0 or != nil does not validate correctness. Assert quantitative bounds."

    private static let unwrapFix =
        "Unwrap the value with try XCTUnwrap(...) and assert a specific expected value or range check on it"
    private static let boundFix = "Replace != 0 with a specific expected value or range check"

    private func weakAssertions(_ source: String) async throws -> [Finding] {
        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: Configuration())
        return result.diagnostics
            .filter { $0.ruleId == "weak-assertion" }
            .map {
                Finding(
                    line: $0.lineNumber, column: $0.columnNumber, severity: $0.severity,
                    message: $0.message, fix: $0.suggestedFix)
            }
    }

    /// One XCTest method whose body is `statements`, which start on line 5, column 9.
    private func suite(_ statements: String...) -> String {
        let body = statements.map { "        " + $0 }.joined(separator: "\n")
        return """
        import XCTest

        final class LedgerTests: XCTestCase {
            func testBalance() throws {
        \(body)
            }
        }
        """
    }

    // MARK: - Must flag

    @Test("XCTAssertNotNil is #expect(x != nil)")
    func flagsNotNil() async throws {
        let found = try await weakAssertions(suite("XCTAssertNotNil(ledger.balance)"))
        #expect(found == [
            Finding(line: 5, column: 9, severity: .warning, message: Self.absentMessage, fix: Self.unwrapFix)
        ])
    }

    @Test("XCTAssertNotNil with a message is still one finding")
    func flagsNotNilWithMessage() async throws {
        let found = try await weakAssertions(suite(
            "let balance = ledger.balance",
            "XCTAssertNotNil(balance, \"a posted ledger has a balance\")"))
        #expect(found == [
            Finding(line: 6, column: 9, severity: .warning, message: Self.absentMessage, fix: Self.unwrapFix)
        ])
    }

    @Test("XCTAssertNotEqual against a literal 0 is #expect(x != 0), on either side")
    func flagsNotEqualZero() async throws {
        let found = try await weakAssertions(suite(
            "XCTAssertNotEqual(ledger.total, 0)",
            "XCTAssertNotEqual(0, ledger.total)"))
        #expect(found == [
            Finding(line: 5, column: 9, severity: .warning, message: Self.notEqualZeroMessage, fix: Self.boundFix),
            Finding(line: 6, column: 9, severity: .warning, message: Self.notEqualZeroMessage, fix: Self.boundFix),
        ])
    }

    @Test("XCTAssertNotEqual against nil is #expect(x != nil)")
    func flagsNotEqualNil() async throws {
        let found = try await weakAssertions(suite("XCTAssertNotEqual(ledger.balance, nil)"))
        #expect(found == [
            Finding(line: 5, column: 9, severity: .warning, message: Self.notEqualNilMessage, fix: Self.unwrapFix)
        ])
    }

    @Test("XCTAssertTrue and XCTAssert carry their condition into #expect unchanged")
    func flagsWeakCondition() async throws {
        let found = try await weakAssertions(suite(
            "XCTAssertTrue(ledger.balance != nil)",
            "XCTAssert(ledger.total != 0, \"posted\")"))
        #expect(found == [
            Finding(line: 5, column: 9, severity: .warning, message: Self.conditionMessage, fix: Self.boundFix),
            Finding(line: 6, column: 9, severity: .warning, message: Self.conditionMessage, fix: Self.boundFix),
        ])
    }

    @Test("A compound condition is reported once per weak comparison, as #expect reports it")
    func compoundConditionMatchesExpect() async throws {
        let viaXCTest = try await weakAssertions(suite(
            "XCTAssertTrue(ledger.balance != nil && ledger.total != 0)"))
        let viaSwiftTesting = try await weakAssertions("""
        import Testing

        struct LedgerTests {
            @Test func balance() throws {
                #expect(ledger.balance != nil && ledger.total != 0)
            }
        }
        """)
        let expected = [
            Finding(line: 5, column: 9, severity: .warning, message: Self.conditionMessage, fix: Self.boundFix),
            Finding(line: 5, column: 9, severity: .warning, message: Self.conditionMessage, fix: Self.boundFix),
        ]
        #expect(viaXCTest == expected)
        #expect(viaSwiftTesting == expected)
    }

    @Test("An XCTest assertion outside an XCTestCase method is still read")
    func flagsInHelper() async throws {
        // A shared `assertPosted(_:)` helper is where a suite's weakest claim usually lives.
        let found = try await weakAssertions("""
        import XCTest

        func assertPosted(_ ledger: Ledger) {
            XCTAssertNotNil(ledger.balance)
        }
        """)
        #expect(found == [
            Finding(line: 4, column: 5, severity: .warning, message: Self.absentMessage, fix: Self.unwrapFix)
        ])
    }

    // MARK: - Must not flag

    @Test("Forms whose Swift Testing spelling is not reported are not reported here")
    func leavesUnreportedFormsAlone() async throws {
        // Each line converts to an `#expect` the rule does not flag: `== nil`, `> 0`,
        // `!x.isEmpty`, `!(x != nil)`, a tolerance, and a comparison with a real value.
        let found = try await weakAssertions(suite(
            "XCTAssertNil(ledger.error)",
            "XCTAssertGreaterThan(ledger.entries.count, 0)",
            "XCTAssert(ledger.entries.count > 0)",
            "XCTAssertTrue(!ledger.entries.isEmpty)",
            "XCTAssertFalse(ledger.error != nil)",
            "XCTAssertNotEqual(ledger.total, 0, accuracy: 0.01)",
            "XCTAssertNotEqual(ledger.total, previous.total)",
            "XCTAssertEqual(ledger.total, 0)",
            "XCTAssertNotEqual(ledger.total, 0.0)",
            "XCTAssertNotEqual([ledger.total], nil)"))
        #expect(found.isEmpty)
    }

    @Test("A comparison nested in a larger operand is not a top-level != 0")
    func leavesParenthesisedComparisonAlone() async throws {
        // `#expect((a != nil) == flag)` is not reported, so neither is its XCTest spelling.
        let found = try await weakAssertions(suite(
            "XCTAssertEqual(ledger.balance != nil, expectsBalance)",
            "XCTAssertTrue((ledger.balance != nil) == expectsBalance)"))
        #expect(found.isEmpty)
    }

    @Test("A call with no arguments, or one that is not XCTest's, is not an assertion")
    func leavesOtherCallsAlone() async throws {
        let found = try await weakAssertions(suite(
            "XCTAssertNotNil()",
            "ledger.XCTAssertNotNil(ledger.balance)",
            "assertNotNil(ledger.balance)"))
        #expect(found.isEmpty)
    }

    // MARK: - Suppression and coexistence

    @Test("A TEST-QUALITY marker records an override instead of a finding")
    func markerSuppresses() async throws {
        let source = suite(
            "// TEST-QUALITY: the contract is only that an id is issued",
            "XCTAssertNotNil(ledger.id)")
        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: Configuration())
        #expect(result.diagnostics.filter { $0.ruleId == "weak-assertion" }.isEmpty)
        let overrides = result.overrides.filter { $0.ruleId == "weak-assertion" }
        #expect(overrides.map(\.lineNumber) == [6])
        #expect(overrides.map(\.justification) == ["// TEST-QUALITY: the contract is only that an id is issued"])
    }

    @Test("The import and the weak assertion are two findings about two things")
    func reportedAlongsideTheImport() async throws {
        // `xctest-import` says which framework the file uses. `weak-assertion` says what one
        // claim in it is worth. Converting the file answers the first and not the second.
        let result = try await auditor.auditSource(
            suite("XCTAssertNotNil(ledger.balance)"),
            fileName: "SomeTests.swift", configuration: Configuration())
        let reported = result.diagnostics.map { "\($0.ruleId ?? ""):\($0.lineNumber ?? 0):\($0.severity)" }
        #expect(reported == ["xctest-import:1:error", "weak-assertion:5:warning"])
    }
}
