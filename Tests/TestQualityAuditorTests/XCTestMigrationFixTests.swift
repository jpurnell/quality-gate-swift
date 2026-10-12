import Foundation
import Testing
import TestQualityAuditor
import QualityGateCore

/// `TestQualityAuditor` as a `FixableChecker`: the conversion, applied to files on disk.
///
/// `XCTestMigrationTests` covers what a file becomes. These cover what `--fix` does with that:
/// it writes only files that passed the checks, it reports what it left, and it does not
/// touch a file no `xctest-import` finding named.
@Suite("xctest-import --fix on disk")
final class XCTestMigrationFixTests {

    private let root: URL
    private let auditor = TestQualityAuditor()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-fix-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tests/ThingTests"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root) // silent: a temp directory left behind is harmless, and deinit cannot report
    }

    private func write(_ source: String, to name: String) throws -> URL {
        let url = root.appendingPathComponent("Tests/ThingTests/\(name)")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func finding(for url: URL) -> Diagnostic {
        Diagnostic(
            severity: .error, message: "Test file imports XCTest.", filePath: url.path,
            lineNumber: 1, columnNumber: 1, ruleId: "xctest-import")
    }

    @Test("A flagged file is rewritten in place and reported as a modification")
    func rewritesAFlaggedFile() async throws {
        let url = try write("""
        import XCTest

        final class ThingTests: XCTestCase {
            func testItWorks() {
                XCTAssertEqual(1 + 1, 2)
            }
        }

        """, to: "ThingTests.swift")

        let result = try await auditor.fix(diagnostics: [finding(for: url)], configuration: Configuration())

        let rewritten = try String(contentsOf: url, encoding: .utf8)
        #expect(rewritten.contains("@Test func itWorks()"))
        #expect(rewritten.contains("#expect((1 + 1) == 2)"))
        #expect(result.modifications.map(\.filePath) == [url.path])
        #expect(result.unfixed.isEmpty)
    }

    @Test("A file with a construct that needs a decision is left untouched, and the construct is the reason")
    func aDeclinedFileIsNotWritten() async throws {
        // It used to be half-converted: everything but the XCTSkip rewritten, the import
        // gone, and a file that no longer compiled.
        let source = """
        import XCTest

        final class ThingTests: XCTestCase {
            func testSkips() throws {
                throw XCTSkip("later")
            }
        }

        """
        let url = try write(source, to: "SkipTests.swift")

        let result = try await auditor.fix(diagnostics: [finding(for: url)], configuration: Configuration())

        #expect(try String(contentsOf: url, encoding: .utf8) == source)
        #expect(result.modifications.isEmpty)
        #expect(result.unfixed.map(\.lineNumber) == [5])
        #expect(result.unfixed.map(\.filePath) == [url.path])
        #expect(result.unfixed.first?.message.hasPrefix("XCTSkip: only a skip that is the first statement of a test") == true)
    }

    @Test("A conversion the gate itself would report is not written, and the finding is the reason")
    func aConversionTheGateWouldReportIsNotWritten() async throws {
        // `unasserted-optional-unwrap` reads `@Test` bodies. The XCTest original has none, so
        // the gate says nothing about this guard until the file is converted, and then it is
        // an error. Writing the conversion would trade one finding for another.
        let source = """
        import XCTest

        final class ThingTests: XCTestCase {
            func testLoads() {
                guard let value = load() else { return }
                XCTAssertEqual(value, 3)
            }
        }

        """
        let url = try write(source, to: "GuardTests.swift")

        let result = try await auditor.fix(diagnostics: [finding(for: url)], configuration: Configuration())

        #expect(try String(contentsOf: url, encoding: .utf8) == source)
        #expect(result.modifications.isEmpty)
        #expect(result.unfixed.map(\.message) == [
            "Converted, this file would be reported as unasserted-optional-unwrap: Guard binds an optional and returns without asserting. When the value is nil this test passes having run none of its assertions. The converted line: `guard let value = load() else { return }`. A fix that trades one finding for another is not written.",
        ])
        #expect(result.unfixed.map(\.filePath) == [url.path])
    }

    @Test("A test left with no assertion macro is not written: missing-assertion would report it")
    func aTestLeftWithoutAnAssertionIsNotWritten() async throws {
        let source = """
        import XCTest

        final class ThingTests: XCTestCase {
            func testDoesNotThrow() {
                do {
                    try run()
                } catch {
                    XCTFail("threw")
                }
            }
        }

        """
        let url = try write(source, to: "SilentTests.swift")

        let result = try await auditor.fix(diagnostics: [finding(for: url)], configuration: Configuration())

        #expect(try String(contentsOf: url, encoding: .utf8) == source)
        #expect(result.unfixed.map(\.message) == [
            "Converted, this file would be reported as missing-assertion: Test function 'doesNotThrow' has no #expect or #require assertions. The converted line: `@Test func doesNotThrow() {`. A fix that trades one finding for another is not written.",
        ])
    }

    @Test("A fallback the conversion cannot unwrap ahead is not written: coalesced-assertion would report it")
    func aFallbackThatCannotBeUnwrappedIsNotWritten() async throws {
        // Right of `&&` the fallback is only evaluated when `enabled` holds, so binding
        // `try #require(name)` on the line before would fail a test that never read it.
        let source = """
        import XCTest

        final class ThingTests: XCTestCase {
            func testGuarded() {
                XCTAssertTrue(enabled && (name ?? "").isEmpty)
            }
        }

        """
        let url = try write(source, to: "GuardedTests.swift")

        let result = try await auditor.fix(diagnostics: [finding(for: url)], configuration: Configuration())

        #expect(try String(contentsOf: url, encoding: .utf8) == source)
        #expect(result.unfixed.map(\.message) == [
            "Converted, this file would be reported as coalesced-assertion: Assertion falls back to '\"\"' when the optional is nil, so a missing value is asserted as if it were present. The converted line: `#expect(enabled && (name ?? \"\").isEmpty)`. A fix that trades one finding for another is not written.",
        ])
    }

    @Test("A finding the original already had does not stop the conversion")
    func anExistingFindingDoesNotStopTheConversion() async throws {
        // The force-try was there before and is there after. The conversion did not add it.
        let url = try write("""
        import XCTest

        final class ThingTests: XCTestCase {
            func testLoads() {
                let value = try! load()
                XCTAssertEqual(value, 3)
            }
        }

        """, to: "ForceTryTests.swift")

        let result = try await auditor.fix(diagnostics: [finding(for: url)], configuration: Configuration())

        #expect(result.modifications.map(\.filePath) == [url.path])
        #expect(result.unfixed.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("#expect(value == 3)"))
    }

    @Test("What --fix writes, the gate then passes: every fixture, converted on disk and audited again")
    func convertedFilesPassTheGate() async throws {
        var urls: [URL] = []
        for fixture in MigrationFixture.allCases {
            urls.append(try write(fixture.input, to: "\(fixture.rawValue)Tests.swift"))
        }

        let result = try await auditor.fix(diagnostics: urls.map(finding(for:)), configuration: Configuration())

        #expect(result.unfixed.map(\.message) == [])
        #expect(result.modifications.map(\.filePath) == urls.map(\.path).sorted())
        for url in urls {
            let audit = try await auditor.auditSource(
                try String(contentsOf: url, encoding: .utf8), fileName: url.path, configuration: Configuration())
            #expect(audit.diagnostics.filter { $0.severity != .note }.map(\.message) == [], "\(url.lastPathComponent)")
        }
    }

    @Test("A preview reports what the fix would do and writes nothing")
    func previewWritesNothing() async throws {
        let convertible = """
        import XCTest

        final class ThingTests: XCTestCase {
            func testItWorks() {
                XCTAssertEqual(1 + 1, 2)
            }
        }

        """
        let declined = """
        import XCTest

        final class WaitTests: XCTestCase {
            func testWaits() {
                let done = expectation(description: "done")
                wait(for: [done], timeout: 1)
            }
        }

        """
        let first = try write(convertible, to: "ATests.swift")
        let second = try write(declined, to: "BTests.swift")

        let preview = try #require(try await auditor.previewFix(
            diagnostics: [finding(for: first), finding(for: second)], configuration: Configuration()))

        #expect(try String(contentsOf: first, encoding: .utf8) == convertible)
        #expect(try String(contentsOf: second, encoding: .utf8) == declined)
        #expect(preview.modifications == [
            // Four lines replaced by five: the import becomes two.
            FileModification(filePath: first.path, description: "Converted to Swift Testing (1 test)", linesChanged: 9),
        ])
        #expect(preview.unfixed.map(\.lineNumber) == [5, 6])
        #expect(preview.unfixed.map(\.filePath) == [second.path, second.path])
    }

    @Test("A file whose conversion does not parse is left untouched and reported")
    func refusesAnUnsafeResult() async throws {
        let source = """
        import XCTest

        final class ThingTests: XCTestCase {
            func testBroken() {
                XCTAssertTrue(
        }

        """
        let url = try write(source, to: "BrokenTests.swift")

        let result = try await auditor.fix(diagnostics: [finding(for: url)], configuration: Configuration())

        #expect(try String(contentsOf: url, encoding: .utf8) == source)
        #expect(result.modifications.isEmpty)
        #expect(result.unfixed.contains { $0.message.contains("not written") })
    }

    @Test("Only xctest-import findings are acted on; other rules pass through unfixed")
    func otherRulesAreNotFixed() async throws {
        let url = try write("import Testing\n", to: "OtherTests.swift")
        let other = Diagnostic(
            severity: .warning, message: "weak", filePath: url.path, lineNumber: 1, ruleId: "weak-assertion")

        let result = try await auditor.fix(diagnostics: [other], configuration: Configuration())

        #expect(result.modifications.isEmpty)
        #expect(result.unfixed.map(\.ruleId) == ["weak-assertion"])
    }

    @Test("The fix description names the verification it cannot do itself")
    func describesWhatToRunAfterwards() {
        #expect(auditor.fixDescription.contains("swift test"))
        #expect(auditor.fixDescription.contains("stack"))
        #expect(auditor.fixDescription.contains("left untouched and listed with that construct and its line"))
    }
}
