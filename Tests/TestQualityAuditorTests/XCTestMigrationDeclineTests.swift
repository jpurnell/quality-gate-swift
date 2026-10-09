import Foundation
import Testing
@testable import TestQualityAuditor
import QualityGateCore

/// The files `--fix` leaves alone, and what it says about each.
///
/// A declined file used to be reported as a count: "12 diagnostic(s) require manual
/// intervention". Each case here is a construct with no mechanical Swift Testing form, and
/// asserts the line it is reported at and the construct the reason opens with.
@Suite("xctest-import --fix declines with the construct that stopped it")
struct XCTestMigrationDeclineTests {

    private func declines(_ body: String, header: String = "final class ThingTests: XCTestCase {") -> [String] {
        let source = """
        import XCTest

        \(header)
        \(body)
        }

        """
        return XCTestMigration.migrate(source: source, fileName: "Tests/ThingTests/ThingTests.swift")
            .declines.map { "\($0.lineNumber ?? 0): \($0.message.prefix(while: { $0 != ":" }))" }
    }

    @Test("A suite marked @available: Swift Testing refuses @Suite on it (BusinessMathExcel: 4 files)")
    func availabilityOnTheSuite() {
        let found = declines("""
            func testOld() {
                XCTAssertEqual(legacy(), 1)
            }
        """, header: "@available(*, deprecated)\nfinal class ThingTests: XCTestCase {")
        #expect(found == ["3: @available(*, deprecated) on ThingTests"])
    }

    @Test("XCTSkip in a helper: a helper giving up is a failure or a trait, and only a person knows which")
    func skipInAHelper() {
        let found = declines("""
            private func fixture() throws -> Int {
                guard let value = load() else { throw XCTSkip("no fixture") }
                return value
            }
            func testFixture() throws {
                XCTAssertEqual(try fixture(), 3)
            }
        """)
        #expect(found == ["5: XCTSkip"])
    }

    @Test("A leading skip on the suite's own state cannot be a trait: a trait runs before the suite exists")
    func skipOnInstanceState() {
        let found = declines("""
            private let corpus: String? = nil
            func testCorpus() throws {
                try XCTSkipIf(corpus == nil, "no corpus")
                XCTAssertEqual(corpus, "a")
            }
        """)
        #expect(found == ["6: XCTSkipIf"])
    }

    @Test("XCTAssertNotNil in a closure: #require would need the closure to throw")
    func notNilInAClosure() {
        let found = declines("""
            func testAll() {
                items.forEach { XCTAssertNotNil($0.name) }
            }
        """)
        #expect(found == ["5: XCTAssertNotNil inside a closure"])
    }

    @Test("XCTAssertNotNil in a helper: #require would need the helper, and its callers, to throw")
    func notNilInAHelper() {
        let found = declines("""
            private func check(_ item: Item) {
                XCTAssertNotNil(item.name)
            }
            func testOne() {
                check(item)
                XCTAssertEqual(item.count, 1)
            }
        """)
        #expect(found == ["5: XCTAssertNotNil in `check`"])
    }

    @Test("A nil check on the error XCTAssertThrowsError hands over can never fail")
    func notNilOnTheThrownError() {
        let found = declines("""
            func testThrows() {
                XCTAssertThrowsError(try f()) { error in
                    XCTAssertNotNil(error)
                }
            }
        """)
        #expect(found == ["6: XCTAssertNotNil(error)"])
    }

    @Test("An unwrap in a closure inside an unwrap cannot be bound first, and cannot stay")
    func unwrapInAClosureInAnUnwrap() {
        let found = declines("""
            func testNested() throws {
                let first = try XCTUnwrap(try items.map { try XCTUnwrap($0.name) }.first)
                XCTAssertEqual(first, "a")
            }
        """)
        #expect(found == ["5: XCTUnwrap inside XCTUnwrap"])
    }

    @Test("An unwrap in the second clause of an if is only reached when the first holds")
    func unwrapInALaterCondition() {
        let found = declines("""
            func testGuarded() throws {
                if ready, let row = try XCTUnwrap(rows[XCTUnwrap(key)]) {
                    XCTAssertEqual(row, 1)
                }
            }
        """)
        #expect(found == ["5: XCTUnwrap inside XCTUnwrap"])
    }

    @Test("An unwrap in a one-expression closure: a line before it would need a return")
    func unwrapInAnImplicitReturn() {
        let found = declines("""
            func testLazy() throws {
                let row = { try XCTUnwrap(rows[XCTUnwrap(key)]) }
                XCTAssertEqual(try row(), 1)
            }
        """)
        #expect(found == ["5: XCTUnwrap inside XCTUnwrap"])
    }

    @Test("A return in an XCTAssertThrowsError closure, with more of the test after it")
    func returnInAHandlerThatIsNotLast() {
        let found = declines("""
            func testThrows() {
                XCTAssertThrowsError(try f()) { error in
                    guard error is Failure else { return }
                    XCTAssertEqual(error as? Failure, .bad)
                }
                XCTAssertEqual(count, 1)
            }
        """)
        #expect(found == ["5: XCTAssertThrowsError"])
    }

    @Test("A fallback inside a closure: unwrapping it would need the closure to throw")
    func coalescedOperandInAClosure() {
        let found = declines("""
            func testNames() {
                items.forEach { XCTAssertTrue(($0.name ?? "").isEmpty) }
            }
        """)
        #expect(found == ["5: An assertion on `($0.name ?? \"\")` inside a closure"])
    }

    @Test("An expectation is reported once, where it is made, however often its name appears")
    func anExpectationIsReportedOnce() {
        // BusinessMathExcel named the local `expectation`. Every later mention of it was
        // reported as another expectation: four reasons for one construct.
        let found = declines("""
            func testSendable() {
                let expectation = self.expectation(description: "sendable")
                Task {
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 1)
                clock.measure { work() }
            }
        """)
        #expect(found == ["5: expectation", "9: wait(for"])
    }

    @Test("Every reason says the file was not converted, and how to get it converted")
    func everyDeclineCarriesTheSameAdvice() {
        let outcome = XCTestMigration.migrate(source: """
        import XCTest

        final class ThingTests: XCTestCase {
            func testWaits() {
                let done = expectation(description: "done")
                wait(for: [done], timeout: 1)
            }
        }

        """, fileName: "Tests/ThingTests/ThingTests.swift")
        #expect(outcome.declines.map(\.suggestedFix) == [
            "This file was not converted. Resolve this by hand, then run --fix again.",
            "This file was not converted. Resolve this by hand, then run --fix again.",
        ])
        #expect(outcome.declines.map(\.ruleId) == ["xctest-import", "xctest-import"])
        #expect(outcome.declines.map(\.message) == [
            "expectation: Swift Testing waits with `await` or `confirmation { }`, and which one depends on whether the event is awaited or counted.",
            "wait(for:): replace the expectations it waits for with `await` or `confirmation { }`.",
        ])
    }

    @Test("A message built across lines no longer breaks the file (BusinessMathExcel: all 12 declined files)")
    func aMessageAcrossLinesParses() {
        // Interpolated into a one-line literal, the newline inside it ended the literal, and
        // the file was refused for not parsing. With no reason given, that took a bisection.
        let outcome = XCTestMigration.migrate(source: """
        import XCTest

        final class ThingTests: XCTestCase {
            func testDrift() {
                XCTAssertEqual(
                    emitted, onDisk,
                    "the golden file has drifted. "
                        + "Read the diff before regenerating it.")
                XCTFail(
                    "first "
                        + "second")
            }
        }

        """, fileName: "Tests/ThingTests/ThingTests.swift")
        #expect(outcome.parses)
        #expect(outcome.declines.isEmpty)
        #expect(outcome.output.contains("""
                #expect(emitted == onDisk, Comment(rawValue: "the golden file has drifted. "
                        + "Read the diff before regenerating it."))
        """))
        #expect(outcome.output.contains("""
                Issue.record(Comment(rawValue: "first "
                        + "second"))
        """))
    }
}
