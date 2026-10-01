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

    @Test("Residue comes back unfixed, and the rest of the file is still converted")
    func residueIsReported() async throws {
        let url = try write("""
        import XCTest

        final class ThingTests: XCTestCase {
            func testSkips() throws {
                throw XCTSkip("later")
            }
        }

        """, to: "SkipTests.swift")

        let result = try await auditor.fix(diagnostics: [finding(for: url)], configuration: Configuration())

        #expect(try String(contentsOf: url, encoding: .utf8).contains("@Test func skips()"))
        #expect(result.unfixed.count == 1)
        #expect(result.unfixed.first?.lineNumber == 5)
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
    }
}
