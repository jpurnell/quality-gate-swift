import Foundation
import QualityGateLogging
import QualityGateCore

/// `--fix`: convert each file `xctest-import` flagged from XCTest to Swift Testing.
///
/// ## Why this rule may autofix
///
/// `doc-claims` forbids `--fix` because rewriting a documented number to match the program
/// launders a regression into a documentation update. Rewriting tests carries the same risk:
/// a test is what objects to a regression. So this fix performs only mappings that keep the
/// assertion's claim, and it verifies every file before writing it (see `XCTestMigration`).
/// Anything that would need a decision about meaning is left in place and returned unfixed.
///
/// ## What it cannot verify
///
/// Whether the converted tests *pass*. Swift Testing runs tests in parallel, on the cooperative
/// thread pool, whose threads have 512 KiB of stack rather than the main thread's 8 MiB.
/// Shared mutable state that XCTest's serial runs hid, and recursion that fit the bigger
/// stack, both surface as failures or crashes the conversion did not cause. The
/// SwiftExcelFunctions migration lost eleven tests to `SIGBUS` this way. Building and
/// running the suite is the only check that sees it, and the fix does not execute project
/// code, so it says so instead.
extension TestQualityAuditor: FixableChecker {

    /// What `--fix` will do, and what to run afterwards.
    public var fixDescription: String {
        "Converts each test file flagged by xctest-import from XCTest to Swift Testing, in place. "
            + "A file is written only if every test method comes out as an @Test function and the "
            + "result parses. XCTSkip, expectations and measure blocks are left in place and "
            + "reported. Afterwards run `swift build --build-tests` and `swift test`: Swift Testing "
            + "runs tests in parallel on threads with a 512 KiB stack, so deep recursion or shared "
            + "state that passed under XCTest can fail now, and no source check can see it."
    }

    /// Converts the files named by `xctest-import` findings.
    ///
    /// - Parameters:
    ///   - diagnostics: Findings from a prior `check`. Only `xctest-import` ones are acted on;
    ///     the rest are returned unfixed.
    ///   - configuration: Supplies the project root that relative paths resolve against.
    /// - Returns: One modification per rewritten file, plus residue and anything refused.
    public func fix(
        diagnostics: [Diagnostic], configuration: Configuration
    ) async throws -> FixResult {
        var modifications: [FileModification] = []
        var unfixed = diagnostics.filter { $0.ruleId != "xctest-import" }

        let paths = Set(diagnostics.filter { $0.ruleId == "xctest-import" }.compactMap(\.filePath))
        for path in paths.sorted() {
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : configuration.resolvedProjectRoot.appendingPathComponent(path)
            switch migrateFile(at: url, displayPath: path) {
            case .written(let modification, let residue):
                modifications.append(modification)
                unfixed += residue
            case .unchanged(let residue):
                unfixed += residue
            case .refused(let reason):
                unfixed.append(reason)
            }
        }
        return FixResult(modifications: modifications, unfixed: unfixed)
    }

    private enum FileOutcome {
        case written(FileModification, residue: [Diagnostic])
        case unchanged(residue: [Diagnostic])
        case refused(Diagnostic)
    }

    private func migrateFile(at url: URL, displayPath: String) -> FileOutcome {
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            Self.fixLogger.error("Could not read \(displayPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .refused(refusal(displayPath, "could not be read: \(error.localizedDescription)"))
        }

        let outcome = XCTestMigration.migrate(source: source, fileName: displayPath)
        guard outcome.parses else {
            return .refused(refusal(displayPath, "was not written: the converted file does not parse. Convert it by hand, or fix the syntax error in the original first."))
        }
        guard outcome.testsAfter == outcome.testsBefore else {
            return .refused(refusal(displayPath, "was not written: \(outcome.testsBefore) test methods went in and \(outcome.testsAfter) @Test functions came out, and a test without @Test silently stops running."))
        }
        guard outcome.output != source else { return .unchanged(residue: outcome.residue) }

        do {
            try outcome.output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.fixLogger.error("Could not write \(displayPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .refused(refusal(displayPath, "could not be written: \(error.localizedDescription)"))
        }
        let converted = outcome.testsAfter == 1 ? "1 test" : "\(outcome.testsAfter) tests"
        return .written(
            FileModification(
                filePath: displayPath,
                description: "Converted to Swift Testing (\(converted))",
                linesChanged: Self.changedLineCount(source, outcome.output),
                backupPath: nil),
            residue: outcome.residue)
    }

    private func refusal(_ path: String, _ reason: String) -> Diagnostic {
        Diagnostic(
            severity: .error,
            message: "\((path as NSString).lastPathComponent) \(reason)",
            filePath: path,
            lineNumber: 1,
            ruleId: "xctest-import")
    }

    /// Lines that differ, position by position, plus any difference in length.
    private static func changedLineCount(_ before: String, _ after: String) -> Int {
        let old = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let new = after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let differing = zip(old, new).filter { $0 != $1 }.count
        return differing + abs(old.count - new.count)
    }

    private static let fixLogger = Logger(
        subsystem: "com.quality-gate", category: "TestQualityAuditor.fix")
}
