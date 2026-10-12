import Foundation
import Testing
@testable import TestQualityAuditor
import QualityGateCore

/// The suite the fixer is expected to write for a fixture, read out of the file that compiles it.
enum CompiledConversion {

    /// The text between `// fixture: <name>` and `// end fixture` in
    /// `XCTestMigrationCompiledOutput.swift`.
    static func suite(named name: String, filePath: String = #filePath) throws -> String {
        let url = URL(fileURLWithPath: filePath).deletingLastPathComponent()
            .appendingPathComponent("XCTestMigrationCompiledOutput.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let opening = "// fixture: \(name)\n"
        let start = try #require(text.range(of: opening))
        let end = try #require(text.range(of: "// end fixture", range: start.upperBound..<text.endIndex))
        return String(text[start.upperBound..<end.lowerBound])
    }
}

/// One XCTest file per construct the fixer used to get wrong.
///
/// Each was found by running `--fix` on a real suite (SummerJams, 72 tests; BusinessMathExcel,
/// 572) and then repairing the result by hand until it built and the gate passed.
enum MigrationFixture: String, CaseIterable, Sendable {
    case mutatingCall
    case notNil
    case thrownErrorHandler
    case doCatch
    case coalesced
    case nestedUnwrap
    case closureProperty
    case skipTrait
    case multilineMessage

    /// The XCTest source handed to the fixer.
    var input: String {
        "import XCTest\n\n" + suite
    }

    /// Notes the gate records about the converted file. They do not gate, and a converted
    /// skip is still a skip, so the inventory lists it as it listed the `XCTSkip`.
    var expectedNotes: [String] {
        self == .skipTrait
            ? ["skipped-test-inventory", "skipped-test-inventory", "skipped-test-inventory"]
            : []
    }

    private var suite: String {
        switch self {
        case .mutatingCall:
            return """
            final class MutatingCallFixture: XCTestCase {
                func testNavigation() {
                    var q = FixtureQueue([1, 2])
                    XCTAssertTrue(q.next())
                    XCTAssertFalse(q.next())
                    XCTAssertEqual(q.position, 1)
                }
            }

            """
        case .notNil:
            return """
            final class NotNilFixture: XCTestCase {
                func testLookup() {
                    let table = ["a": 1]
                    XCTAssertNotNil(table["a"], "present")
                    XCTAssertEqual(table["a"], 1)
                }

                func testAsyncLookup() async {
                    let table = ["a": 1]
                    for key in ["a"] {
                        XCTAssertNotNil(table[key])
                    }
                }
            }

            """
        case .thrownErrorHandler:
            return #"""
            final class ThrownErrorHandlerFixture: XCTestCase {
                func testHandlerAsArgument() {
                    XCTAssertThrowsError(try FixtureFailure.raise(.bad), "raises", { error in
                        XCTAssertEqual(error as? FixtureFailure, .bad)
                    })
                }

                func testPatternGuard() {
                    XCTAssertThrowsError(try FixtureFailure.raise(.bad)) { error in
                        guard case FixtureFailure.bad = error else {
                            return XCTFail("expected .bad, got \(error)")
                        }
                    }
                }
            }

            """#
        case .doCatch:
            return #"""
            final class DoCatchFixture: XCTestCase {
                func testTypedCatch() async {
                    do {
                        _ = try await FixtureFailure.raiseLater(.bad)
                        XCTFail("expected error to propagate")
                    } catch is FixtureFailure {
                        // expected
                    } catch {
                        XCTFail("unexpected error: \(error)")
                    }
                }

                func testAnyCatch() {
                    do {
                        try FixtureFailure.raise(.worse)
                        XCTFail("expected a failure")
                    } catch {
                    }
                }
            }

            """#
        case .coalesced:
            return """
            final class CoalescedFixture: XCTestCase {
                func testFallback() {
                    let request: FixtureRequest? = FixtureRequest(path: "/search_query=a")
                    XCTAssertTrue((request?.path ?? "").contains("search_query="))
                    XCTAssertFalse(request?.path.isEmpty ?? true, "has a path")
                }
            }

            """
        case .nestedUnwrap:
            return """
            final class NestedUnwrapFixture: XCTestCase {
                func testLookup() throws {
                    let keys: [String: Int] = ["a": 1]
                    let rows: [Int: String] = [1: "first"]
                    let row = try XCTUnwrap(rows[XCTUnwrap(keys["a"])])
                    XCTAssertEqual(row, "first")
                    XCTAssertEqual(try XCTUnwrap(rows[1]).count, 5)
                    XCTAssertEqual(row, try XCTUnwrap(rows[1]))
                }
            }

            """
        case .closureProperty:
            return """
            final class ClosurePropertyFixture: XCTestCase {
                func testFirstFormula() throws {
                    let sheet = FixtureSheet()
                    let ast = try XCTUnwrap(sheet.references.compactMap { sheet.cell(at: $0)?.formula }.first)
                    XCTAssertEqual(ast, "=A1")
                    XCTAssertFalse(sheet.references.map { sheet.cell(at: $0)?.formula }.isEmpty)
                }
            }

            """
        case .skipTrait:
            return """
            final class SkipTraitFixture: XCTestCase {
                func testOnlyWithCorpus() throws {
                    try XCTSkipUnless(FixtureEnvironment.hasCorpus, "the corpus is private")
                    XCTAssertEqual(FixtureEnvironment.corpusName, "corpus")
                }

                func testNotOnCI() throws {
                    guard !FixtureEnvironment.isCI else { throw XCTSkip("not on CI") }
                    XCTAssertEqual(FixtureEnvironment.corpusName, "corpus")
                }

                func testNeverOnCI() throws {
                    try XCTSkipIf(FixtureEnvironment.isCI)
                    XCTAssertEqual(FixtureEnvironment.corpusName, "corpus")
                }
            }

            """
        case .multilineMessage:
            return """
            final class MultilineMessageFixture: XCTestCase {
                func testLongMessage() {
                    let formats = ["B2": "General"]
                    XCTAssertEqual(
                        formats["B2"], "General",
                        "carried rather than dropped: 'General' is what the file says, and "
                            + "deciding it means nothing is the next stage's job"
                    )
                }
            }

            """
        }
    }
}

/// The fixer's output compiles, and this gate has nothing to say about it.
///
/// Both halves are the acceptance condition for `--fix`: a fix that leaves a file that does
/// not build has not fixed it, and a fix whose output the same gate run then reports has
/// only moved the finding.
@Suite("xctest-import --fix writes code that builds and that the gate accepts")
struct XCTestMigrationValidOutputTests {

    private static let fileName = "Tests/FixtureTests/FixtureTests.swift"

    @Test("The conversion is the suite this target compiles", arguments: MigrationFixture.allCases)
    func outputIsTheCompiledSuite(_ fixture: MigrationFixture) throws {
        let outcome = XCTestMigration.migrate(source: fixture.input, fileName: Self.fileName)

        #expect(outcome.declines.map(\.message) == [])
        #expect(outcome.parses)
        #expect(outcome.testsAfter == outcome.testsBefore)
        let expected = try CompiledConversion.suite(named: fixture.rawValue)
        #expect(outcome.output == "import Foundation\nimport Testing\n\n" + expected)
    }

    @Test("The gate's own test-quality rules report nothing on the conversion", arguments: MigrationFixture.allCases)
    func gateReportsNothingOnTheOutput(_ fixture: MigrationFixture) async throws {
        let outcome = XCTestMigration.migrate(source: fixture.input, fileName: Self.fileName)

        let audit = try await TestQualityAuditor().auditSource(
            outcome.output, fileName: Self.fileName, configuration: Configuration())

        let findings = audit.diagnostics.filter { $0.severity != .note }
        #expect(findings.map { "\($0.ruleId ?? ""): \($0.message)" } == [])
        #expect(audit.diagnostics.filter { $0.severity == .note }.compactMap(\.ruleId) == fixture.expectedNotes)
        #expect(audit.status == .passed)
    }

    @Test("Every fixture has a compiled suite, and every compiled suite has a fixture")
    func fixturesAndCompiledSuitesCorrespond() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("XCTestMigrationCompiledOutput.swift")
        let compiled = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("// fixture: ") }
            .map { String($0.dropFirst("// fixture: ".count)) }

        #expect(compiled == MigrationFixture.allCases.map(\.rawValue))
    }
}
