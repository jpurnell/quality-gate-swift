import Foundation
import Testing
@testable import TestRunner

@Suite("TestRunner: // TIMING: marker scanner")
struct TimingTestScannerTests {

    @Test("Finds a Swift Testing function tagged on the line above")
    func findsSwiftTestingTagged() {
        let source = """
        import Testing
        struct S {
            // TIMING: teardown liveness bound
            @Test func teardownIsPrompt() {}
        }
        """
        #expect(TimingTestScanner.timingTests(in: source) == ["teardownIsPrompt"])
    }

    @Test("Finds an XCTest test method tagged on the line above")
    func findsXCTestTagged() {
        let source = """
        import XCTest
        final class T: XCTestCase {
            // TIMING: reconnect budget
            func testReconnects() {}
        }
        """
        #expect(TimingTestScanner.timingTests(in: source) == ["testReconnects"])
    }

    @Test("Ignores // TIMING: inside a string literal")
    func ignoresStringLiteral() {
        let source = """
        import Testing
        struct S {
            @Test("Respects // TIMING: on the assertion line") func plain() {}
        }
        """
        #expect(TimingTestScanner.timingTests(in: source).isEmpty)
    }

    @Test("Ignores a trailing // TIMING: comment inside a body")
    func ignoresBodyTrailingComment() {
        let source = """
        import Testing
        struct S {
            @Test func plain() {
                let elapsed = measure()
                _ = elapsed // TIMING: intentional load benchmark
            }
        }
        """
        #expect(TimingTestScanner.timingTests(in: source).isEmpty)
    }

    @Test("Does not tag a non-test function even with the marker")
    func ignoresNonTestFunction() {
        let source = """
        struct S {
            // TIMING: not a test
            func helper() {}
        }
        """
        #expect(TimingTestScanner.timingTests(in: source).isEmpty)
    }

    @Test("Finds multiple tagged tests")
    func findsMultiple() {
        let source = """
        import Testing
        struct S {
            // TIMING: one
            @Test func a() {}
            @Test func untagged() {}
            // TIMING: two
            @Test func b() {}
        }
        """
        #expect(TimingTestScanner.timingTests(in: source).sorted() == ["a", "b"])
    }

    @Test("Honors a custom marker")
    func customMarker() {
        let source = """
        import Testing
        struct S {
            // STRESS: custom
            @Test func c() {}
        }
        """
        #expect(TimingTestScanner.timingTests(in: source, marker: "// STRESS:") == ["c"])
        #expect(TimingTestScanner.timingTests(in: source).isEmpty)
    }
}
