import Foundation
import Testing
@testable import TestQualityAuditor
import QualityGateCore

/// `--fix` for `xctest-import`: one XCTest file in, one Swift Testing file out.
///
/// Each mapping row in `plans/proposals/XCTestMigrationFix.md` §4 has a case here, and so has
/// every way the two hand-written converters that preceded this one went wrong. Those are
/// the cases that matter most: a converter that handles the table and fails on a fixture
/// string or a test named `testRepeat` has already been written twice.
@Suite("xctest-import --fix")
struct XCTestMigrationTests {

    private func migrate(_ source: String) -> XCTestMigration.Outcome {
        XCTestMigration.migrate(source: source, fileName: "Tests/ThingTests/ThingTests.swift")
    }

    private func output(_ source: String) -> String {
        migrate(source).output
    }

    /// A test file around `body`, so each case states only the part it is about.
    private func file(_ body: String) -> String {
        """
        import XCTest

        final class ThingTests: XCTestCase {
        \(body)
        }

        """
    }

    private func expected(_ body: String) -> String {
        """
        import Foundation
        import Testing

        @Suite struct ThingTests {
        \(body)
        }

        """
    }

    // MARK: - Shape

    @Test("The import, the class and a test method convert together")
    func shape() {
        let source = file("""
            func testItWorks() {
                XCTAssertTrue(true)
            }
        """)
        #expect(output(source) == expected("""
            @Test func itWorks() {
                #expect(true)
            }
        """))
    }

    @Test("A method that is not a test keeps its name and gains no attribute")
    func helpersAreLeftAlone() {
        let source = file("""
            private func make() -> Int { 1 }
            func testable(_ x: Int) {}
        """)
        #expect(output(source) == expected("""
            private func make() -> Int { 1 }
            func testable(_ x: Int) {}
        """))
    }

    @Test("A lowered name that is a keyword keeps its prefix (SwiftExcelFunctions: testRepeat)")
    func keywordNamesKeepThePrefix() {
        let source = file("""
            func testRepeat() {
                XCTAssertTrue(true)
            }
        """)
        #expect(output(source).contains("@Test func testRepeat()"))
    }

    @Test("A lowered name that collides with a member keeps its prefix")
    func collidingNamesKeepThePrefix() {
        let source = file("""
            private func value() -> Int { 1 }
            func testValue() {
                XCTAssertEqual(value(), 1)
            }
        """)
        #expect(output(source).contains("@Test func testValue()"))
    }

    @Test("An acronym lowers as a word: testURLParses becomes urlParses")
    func acronymsLowerAsAWord() {
        let source = file("""
            func testURLParses() {
                XCTAssertTrue(true)
            }
        """)
        #expect(output(source).contains("@Test func urlParses()"))
    }

    @Test("XCTest inside a string literal is never touched (1edc66e: fixture rewritten)")
    func fixtureStringsAreUntouched() {
        let fixture = #"""
            func testAuditsAFixture() {
                let source = """
                import XCTest
                final class T: XCTestCase {
                    func testX() { XCTAssertEqual(a, b) }
                }
                """
                XCTAssertFalse(source.isEmpty)
            }
        """#
        let result = output(file(fixture))
        #expect(result.contains("import XCTest\n        final class T: XCTestCase {"))
        #expect(result.contains("func testX() { XCTAssertEqual(a, b) }"))
        #expect(result.contains("#expect(!source.isEmpty)"))
    }

    // MARK: - Assertions

    @Test("Comparison assertions become operators, with the message kept")
    func comparisons() {
        let source = file("""
            func testCompare() {
                XCTAssertEqual(a, b, "same")
                XCTAssertNotEqual(a, b)
                XCTAssertGreaterThan(a, b)
                XCTAssertGreaterThanOrEqual(a, b)
                XCTAssertLessThan(a, b)
                XCTAssertLessThanOrEqual(a, b)
            }
        """)
        #expect(output(source) == expected("""
            @Test func compare() {
                #expect(a == b, "same")
                #expect(a != b)
                #expect(a > b)
                #expect(a >= b)
                #expect(a < b)
                #expect(a <= b)
            }
        """))
    }

    @Test("Truth and nil assertions; a not-nil check is a #require, and the test gains throws")
    func truthAndNil() {
        // `#expect(x != nil)` is what this gate's weak-assertion rule reports. A fixer that
        // wrote it handed back 84 new warnings on BusinessMathExcel.
        let source = file("""
            func testTruth() {
                XCTAssert(flag)
                XCTAssertTrue(flag)
                XCTAssertFalse(flag)
                XCTAssertFalse(a == b)
                XCTAssertNil(x)
                XCTAssertNotNil(x)
            }
        """)
        #expect(output(source) == expected("""
            @Test func truth() throws {
                #expect(flag)
                #expect(flag)
                #expect(!flag)
                #expect(!(a == b))
                #expect(x == nil)
                _ = try #require(x)
            }
        """))
    }

    @Test("accuracy: becomes an explicit tolerance, the same claim XCTest made")
    func accuracy() {
        let source = file("""
            func testClose() {
                XCTAssertEqual(x, 1.5, accuracy: 1e-9)
                XCTAssertNotEqual(x, 1.5, accuracy: 0.1, "apart")
            }
        """)
        #expect(output(source) == expected("""
            @Test func close() {
                #expect(abs(x - 1.5) <= 1e-9)
                #expect(abs(x - 1.5) > 0.1, "apart")
            }
        """))
    }

    @Test("try and await move to the front of the expectation")
    func effectsAreHoisted() {
        let source = file("""
            func testEffects() async throws {
                XCTAssertEqual(try f(), 1)
                XCTAssertEqual(1, try f())
                XCTAssertTrue(await g())
            }
        """)
        #expect(output(source) == expected("""
            @Test func effects() async throws {
                #expect(try f() == 1)
                #expect(try 1 == f())
                #expect(await g())
            }
        """))
    }

    @Test("An operand with a top-level operator is parenthesised")
    func operandsKeepTheirMeaning() {
        let source = file("""
            func testPrecedence() {
                XCTAssertEqual(flag ? 1 : 2, 1)
                XCTAssertEqual(a + b, c)
            }
        """)
        #expect(output(source) == expected("""
            @Test func precedence() {
                #expect((flag ? 1 : 2) == 1)
                #expect((a + b) == c)
            }
        """))
    }

    @Test("An array literal on the left compares with elementsEqual (SwiftExcelFunctions: ambiguous ==)")
    func arrayLiteralComparisons() {
        // XCTAssertEqual<T> fixed the type from both sides. #expect splits `==` into its own
        // overloads, and two untyped array literals are ambiguous there.
        let source = file("""
            func testDate() {
                XCTAssertEqual([year, month, day], [2026, 9, 30])
                XCTAssertNotEqual([month, day], [2, 29], "not a leap year")
            }
        """)
        let result = output(source)
        #expect(result.contains("#expect([year, month, day].elementsEqual([2026, 9, 30]))"))
        #expect(result.contains(#"#expect(![month, day].elementsEqual([2, 29]), "not a leap year")"#))
    }

    @Test("A message that is not a string literal is interpolated (SwiftExcelFunctions: row.date)")
    func nonLiteralMessages() {
        let source = file("""
            func testMessage() {
                XCTAssertEqual(a, b, row.date)
            }
        """)
        #expect(output(source).contains(#"#expect(a == b, "\(row.date)")"#))
    }

    @Test("XCTUnwrap becomes #require, and a call the file declares as throwing keeps its own try")
    func unwrap() {
        let source = file("""
            private func f() throws -> Int? { 1 }
            func testUnwrap() throws {
                let x = try XCTUnwrap(optional, "missing")
                let y = try XCTUnwrap(f())
            }
        """)
        #expect(output(source) == expected("""
            private func f() throws -> Int? { 1 }
            @Test func unwrap() throws {
                let x = try #require(optional, "missing")
                let y = try #require(try f())
            }
        """))
    }

    @Test("XCTFail records an issue, and `return XCTFail` becomes two statements")
    func fail() {
        let source = file("""
            func testFail() {
                guard ok else { return XCTFail("no") }
                XCTFail()
            }
        """)
        #expect(output(source) == expected("""
            @Test func fail() {
                guard ok else { Issue.record("no"); return }
                Issue.record()
            }
        """))
    }

    @Test("XCTAssertThrowsError, bare and with a named closure parameter")
    func throwsError() {
        let source = file("""
            func testThrowing() {
                XCTAssertThrowsError(try f())
                XCTAssertThrowsError(try f()) { error in
                    XCTAssertEqual(error as? E, .bad)
                }
            }
        """)
        #expect(output(source) == expected("""
            @Test func throwing() {
                #expect(throws: (any Error).self) { try f() }
                if let error = #expect(throws: (any Error).self, performing: { try f() }) {
                    #expect(error as? E == .bad)
                }
            }
        """))
    }

    @Test("A $0 closure on XCTAssertThrowsError binds a name, not $0 (SwiftExcelFunctions: compiler crash)")
    func throwsErrorDollarZero() {
        let source = file("""
            func testThrowsAgain() {
                XCTAssertThrowsError(try f()) {
                    XCTAssertEqual($0 as? E, .bad)
                    let inner = [1].map { $0 + 1 }
                }
            }
        """)
        let result = output(source)
        #expect(result.contains("if let error = #expect(throws: (any Error).self, performing: { try f() }) {"))
        #expect(result.contains("#expect(error as? E == .bad)"))
        #expect(result.contains("[1].map { $0 + 1 }"), "a nested closure's $0 is its own")
    }

    @Test("XCTAssertNoThrow expects Never")
    func noThrow() {
        let source = file("""
            func testNoThrow() {
                XCTAssertNoThrow(try f())
            }
        """)
        #expect(output(source).contains("#expect(throws: Never.self) { try f() }"))
    }

    @Test("Forwarded file/line become sourceLocation")
    func sourceLocation() {
        let source = file("""
            private func check(_ v: Int, file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertEqual(v, 1, file: file, line: line)
            }
        """)
        #expect(output(source) == expected("""
            private func check(_ v: Int, sourceLocation: SourceLocation = #_sourceLocation) {
                #expect(v == 1, sourceLocation: sourceLocation)
            }
        """))
    }

    // MARK: - Lifecycle

    @Test("setUp/tearDown make a final class with init and deinit")
    func lifecycle() {
        let source = """
        import XCTest

        final class ThingTests: XCTestCase {
            private var root: URL!

            override func setUpWithError() throws {
                try super.setUpWithError()
                root = URL(fileURLWithPath: "/tmp")
            }

            override func tearDown() {
                root = nil
                super.tearDown()
            }

            func testRootIsSet() {
                XCTAssertNotNil(root)
            }
        }

        """
        #expect(output(source) == """
        import Foundation
        import Testing

        @Suite final class ThingTests {
            private var root: URL!

            init() throws {
                root = URL(fileURLWithPath: "/tmp")
            }

            deinit {
                root = nil
            }

            @Test func rootIsSet() throws {
                _ = try #require(root)
            }
        }

        """)
    }

    @Test("A suite with mutable stored state stays a class, so its tests can mutate it")
    func mutableStateStaysAClass() {
        let source = file("""
            private var count = 0
            func testCount() {
                count += 1
                XCTAssertEqual(count, 1)
            }
        """)
        #expect(output(source).contains("@Suite final class ThingTests {"))
    }

    // MARK: - Self-consistency with the gate

    @Test("An exact comparison of Doubles comes out named, not as a finding the gate would report")
    func floatsAreNamed() {
        let source = file("""
            func testDouble() {
                let x: Double = 1.5
                XCTAssertEqual(x, 1.5)
            }
        """)
        let result = output(source)
        #expect(result.contains("#expect(x.isEqual(to: 1.5))"))
    }

    @Test("try on a named comparison covers both sides (SwiftExcelFunctions: RANK.EQ)")
    func namedComparisonHoistsEffects() {
        let source = file("""
            private func number(_ name: String) throws -> Double { 1 }
            func testRanks() throws {
                XCTAssertEqual(try number("RANK.EQ"), try number("RANK"))
            }
        """)
        #expect(output(source).contains(#"#expect(try number("RANK.EQ").isEqual(to: number("RANK")))"#))
    }

    @Test("An optional float comparison stays exact and fails on nil (SwiftExcelFunctions: 5 sites)")
    func optionalFloatsAreNamedThroughTheOptional() {
        let source = file("""
            private func numbers(_ x: Int) -> [Double]? { nil }
            private func ratio(_ x: Int) -> Double? { nil }
            func testOptionals() {
                XCTAssertEqual(numbers(1), [1.5, 2.5])
                XCTAssertEqual(ratio(1), 0.5)
                XCTAssertEqual(model?.weights, [0.25])
            }
        """)
        let result = output(source)
        #expect(result.contains("#expect(numbers(1)?.elementsEqual([1.5, 2.5], by: { $0.isEqual(to: $1) }) == true)"))
        #expect(result.contains("#expect(ratio(1)?.isEqual(to: 0.5) == true)"))
        // Parenthesised: `model?.weights` is one optional whether or not `weights` is.
        #expect(result.contains("#expect((model?.weights)?.elementsEqual([0.25], by: { $0.isEqual(to: $1) }) == true)"))
    }

    // MARK: - Bindings

    @Test("A bound value's name is unique in its test, and starts again in the next one (SummerJams: ReviewQueueTests)")
    func boundNamesAreScopedToTheFunction() {
        let source = file("""
            func testFirst() {
                var q = Queue()
                XCTAssertTrue(q.next())
                XCTAssertFalse(q.next())
            }
            func testSecond() {
                var q = Queue()
                XCTAssertTrue(q.next())
            }
        """)
        #expect(output(source) == expected("""
            @Test func first() {
                var q = Queue()
                let next = q.next()
                #expect(next)
                let next2 = q.next()
                #expect(!next2)
            }
            @Test func second() {
                var q = Queue()
                let next = q.next()
                #expect(next)
            }
        """))
    }

    @Test("A name the file already uses is not taken for a binding")
    func boundNamesAvoidNamesInUse() {
        let source = file("""
            func testCursor() {
                var q = Queue()
                let next = 1
                XCTAssertTrue(q.next())
                XCTAssertEqual(next, 1)
            }
        """)
        #expect(output(source).contains("let next2 = q.next()\n        #expect(next2)"))
    }

    @Test("A method call on a let is left inside the assertion: it cannot be mutating")
    func callsOnConstantsAreNotBound() {
        let source = file("""
            func testReads() {
                let q = Queue()
                XCTAssertTrue(q.peek())
            }
        """)
        #expect(output(source).contains("#expect(q.peek())"))
    }

    @Test("Calls left of a mutating one are bound too, so they still run first")
    func earlierCallsAreBoundInOrder() {
        // `snapshot2`, not `snapshot`: a local cannot be initialised from a function it shadows.
        let source = file("""
            func testOrder() {
                var q = Queue()
                XCTAssertEqual(snapshot(), q.pop())
            }
        """)
        #expect(output(source).contains("""
                let snapshot2 = snapshot()
                let pop = q.pop()
                #expect(snapshot2 == pop)
        """))
    }

    @Test("A bare reference is bound as xValue, since x is taken by x")
    func bareReferencesAreBoundWithASuffix() {
        let source = file("""
            func testNames() throws {
                let row = try XCTUnwrap(rows[XCTUnwrap(key)])
                XCTAssertEqual(try XCTUnwrap(x).count, 3)
                XCTAssertTrue((name ?? "").isEmpty)
            }
        """)
        #expect(output(source) == expected("""
            @Test func names() throws {
                let keyValue = try #require(key)
                let row = try #require(rows[keyValue])
                let xValue = try #require(x)
                #expect(xValue.count == 3)
                let nameValue = try #require(name)
                #expect(nameValue.isEmpty)
            }
        """))
    }

    @Test("An unwrap under try? stays where it is: bound ahead, a nil would stop the test")
    func unwrapUnderOptionalTryIsNotBound() {
        let source = file("""
            func testMaybe() {
                XCTAssertEqual(try? XCTUnwrap(x), 3)
            }
        """)
        #expect(output(source).contains("#expect(try? #require(x) == 3)"))
    }

    @Test("A try that covered only the unwrap goes with it; one that covers another call stays")
    func tryIsKeptOnlyWhereSomethingStillThrows() {
        let source = file("""
            func testCounts() throws {
                XCTAssertEqual(try XCTUnwrap(x).count, try count())
            }
        """)
        #expect(output(source).contains("""
                let xValue = try #require(x)
                #expect(try xValue.count == count())
        """))
    }

    // MARK: - What stops a file

    @Test("An XCTSkip that is not a leading condition declines the file: choosing for it is judgement")
    func skipDeclinesTheFile() {
        let outcome = migrate(file("""
            func testSkipped() throws {
                throw XCTSkip("not here")
            }
        """))
        #expect(outcome.declines.map(\.lineNumber) == [5])
        #expect(outcome.declines.first?.message.hasPrefix("XCTSkip: only a skip that is the first statement of a test") == true)
        #expect(!outcome.isSafeToWrite)
    }

    @Test("A nil check on a value declared non-optional declines the file: it can never fail (SwiftExcelFunctions: compiler crash)")
    func vacuousNilCheckDeclinesTheFile() {
        // `#expect(x != nil)` on a non-optional is a compiler warning at best, and on an
        // existential (`any Sendable`) it crashed swift-frontend 6.4 in SILGen. XCTest took
        // `Any?`, which is why the original compiled and why it never tested anything.
        let outcome = migrate(file("""
            func testSendable() {
                let error: any Sendable = Failure.circular
                XCTAssertNotNil(error)
                let maybe: Int? = nil
                XCTAssertNil(maybe)
            }
        """))
        #expect(outcome.output.contains("XCTAssertNotNil(error)"))
        #expect(outcome.output.contains("#expect(maybe == nil)"))
        #expect(outcome.declines.map(\.lineNumber) == [6])
        #expect(outcome.declines.first?.message.hasPrefix("XCTAssertNotNil(error): `error` is not optional, so this can never fail.") == true)
    }

    @Test("Expectations and measure decline the file; async setUp does not, Swift Testing has async init")
    func otherConstructsDeclineTheFile() {
        let outcome = migrate(file("""
            override func setUp() async throws {}
            func testWaits() {
                let e = expectation(description: "x")
                wait(for: [e], timeout: 1)
                measure { _ = 1 }
            }
        """))
        #expect(outcome.declines.map(\.lineNumber) == [6, 7, 8])
        #expect(outcome.declines.map { String($0.message.prefix(while: { $0 != ":" })) } == ["expectation", "wait(for", "measure"])
        #expect(outcome.output.contains("init() async throws {}"))
    }

    // MARK: - Verification

    @Test("Every test method comes out as an @Test function (the silent trap)")
    func noOrphans() {
        let outcome = migrate(file("""
            func testOne() { XCTAssertTrue(true) }
            func testTwo() async throws { XCTAssertTrue(true) }
            func testThree() { XCTAssertTrue(true) }
        """))
        #expect(outcome.testsBefore == 3)
        #expect(outcome.testsAfter == 3)
        #expect(outcome.declines.isEmpty)
        #expect(outcome.isSafeToWrite)
    }

    @Test("Tests in an extension of the suite convert too (SwiftExcelFunctions: 5 of 12 missed)")
    func extensionsConvert() {
        let outcome = migrate("""
        import XCTest

        final class ThingTests: XCTestCase {
            func testInClass() { XCTAssertTrue(true) }
        }

        extension ThingTests {
            func testInExtension() { XCTAssertTrue(true) }
        }

        """)
        #expect(outcome.output.contains("@Test func inExtension()"))
        #expect(outcome.testsBefore == 2)
        #expect(outcome.testsAfter == 2)
    }

    @Test("The orphan check counts independently, so a blind spot in the conversion is caught")
    func orphanCountIsIndependent() {
        // A test method in a class that is not an XCTestCase subclass in this file — say, a
        // subclass of a project base class — is something XCTest may run and the conversion
        // does not touch. The independent count sees it; the file is refused.
        let outcome = migrate("""
        import XCTest

        final class ThingTests: XCTestCase {
            func testOne() { XCTAssertTrue(true) }
        }

        final class OtherTests: ProjectTestCase {
            func testTwo() { XCTAssertTrue(true) }
        }

        """)
        #expect(outcome.testsBefore == 2)
        #expect(outcome.testsAfter == 1)
        #expect(!outcome.isSafeToWrite)
    }

    @Test("tearDownWithError whose only try is the super call becomes deinit")
    func tearDownWithSuperTry() {
        let output = output("""
        import XCTest

        final class ThingTests: XCTestCase {
            override func tearDownWithError() throws {
                cleanUp()
                try super.tearDownWithError()
            }

            func testIt() { XCTAssertTrue(true) }
        }

        """)
        #expect(output.contains("deinit {\n        cleanUp()\n    }"))
        #expect(!output.contains("override"))
    }

    @Test("The output parses")
    func outputParses() {
        let outcome = migrate(file("""
            func testThrowsAgain() {
                XCTAssertThrowsError(try f()) { error in
                    XCTAssertNotNil(error)
                }
            }
        """))
        #expect(outcome.parses)
    }

    @Test("A file that is already Swift Testing is returned unchanged")
    func idempotent() {
        let source = expected("""
            @Test func itWorks() {
                #expect(true)
            }
        """)
        #expect(output(source) == source)
    }
}
