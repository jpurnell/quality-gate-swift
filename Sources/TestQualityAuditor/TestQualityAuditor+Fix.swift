import Foundation
import QualityGateLogging
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// `--fix`: convert each file `xctest-import` flagged from XCTest to Swift Testing.
///
/// ## Why this rule may autofix
///
/// `doc-claims` forbids `--fix` because rewriting a documented number to match the program
/// launders a regression into a documentation update. Rewriting tests carries the same risk:
/// a test is what objects to a regression. So this fix performs only mappings that keep the
/// assertion's claim or tighten it, and it verifies every file before writing it (see
/// `XCTestMigration`). A file that would need a decision about meaning is left untouched, and
/// the construct that needed the decision is returned with its line.
///
/// ## A file is converted whole or not at all
///
/// The first version converted what it could and left the rest in place: an `XCTSkip`, an
/// expectation. The file it wrote no longer imported XCTest, so it did not compile. On
/// BusinessMathExcel that was three files, found by building. It also wrote assertions this
/// gate rejects (`#expect(x != nil)`, 84 times), so the run that fixed one finding created
/// another. And when it did decline, it said only how many diagnostics were left.
///
/// Now the converted text is audited by the same rules `check` runs. If it would gain a
/// finding the original did not have, it is not written, and the finding is the reason given.
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
            + "A file is written only if every test method comes out as an @Test function, the "
            + "result parses, and this gate's own test-quality rules report nothing on it that "
            + "they did not report before. A file holding something with no single Swift Testing "
            + "form (an expectation, a measure block, an XCTSkip in a helper, an @available "
            + "suite) is left untouched and listed with that construct and its line. Afterwards "
            + "run `swift build --build-tests` and `swift test`: Swift Testing runs tests in "
            + "parallel on threads with a 512 KiB stack, so deep recursion or shared state that "
            + "passed under XCTest can fail now, and no source check can see it."
    }

    /// Converts the files named by `xctest-import` findings.
    ///
    /// - Parameters:
    ///   - diagnostics: Findings from a prior `check`. Only `xctest-import` ones are acted on;
    ///     the rest are returned unfixed.
    ///   - configuration: Supplies the project root that relative paths resolve against, and
    ///     the rule settings the converted text is audited under.
    /// - Returns: One modification per rewritten file. For each file left alone, one finding
    ///   per construct that stopped it, at that construct's line.
    public func fix(
        diagnostics: [Diagnostic], configuration: Configuration
    ) async throws -> FixResult {
        convert(diagnostics: diagnostics, configuration: configuration, writing: true)
    }

    /// What ``fix(diagnostics:configuration:)`` would do, with no file written.
    ///
    /// The same conversion and the same checks, so the preview cannot promise a file the fix
    /// would then decline.
    public func previewFix(
        diagnostics: [Diagnostic], configuration: Configuration
    ) async throws -> FixResult? {
        convert(diagnostics: diagnostics, configuration: configuration, writing: false)
    }

    private func convert(diagnostics: [Diagnostic], configuration: Configuration, writing: Bool) -> FixResult {
        var modifications: [FileModification] = []
        var unfixed = diagnostics.filter { $0.ruleId != "xctest-import" }

        let paths = Set(diagnostics.filter { $0.ruleId == "xctest-import" }.compactMap(\.filePath))
        guard !paths.isEmpty else { return FixResult(modifications: [], unfixed: unfixed) }

        // `self-referential-expectation` compares an assertion against a body in `Sources/`,
        // so auditing the converted text needs the same index `check` builds.
        let implementations = SelfReferentialExpectation.buildIndex(
            projectRoot: configuration.resolvedProjectRoot.path)
        for path in paths.sorted() {
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : configuration.resolvedProjectRoot.appendingPathComponent(path)
            let file = MigratedFile(
                url: url, displayPath: path, configuration: configuration,
                implementations: implementations, writing: writing)
            switch migrate(file) {
            case .converted(let modification): modifications.append(modification)
            case .unchanged: break
            case .declined(let reasons): unfixed += reasons
            }
        }
        return FixResult(modifications: modifications, unfixed: unfixed)
    }

    /// One file on its way through the conversion.
    private struct MigratedFile {
        let url: URL
        let displayPath: String
        let configuration: Configuration
        let implementations: SelfReferentialExpectation.ImplementationIndex
        /// `false` for a preview.
        let writing: Bool
    }

    private enum FileOutcome {
        case converted(FileModification)
        case unchanged
        /// Not written, with one finding per reason.
        case declined([Diagnostic])
    }

    private func migrate(_ file: MigratedFile) -> FileOutcome {
        let path = file.displayPath
        let source: String
        do {
            source = try String(contentsOf: file.url, encoding: .utf8)
        } catch {
            Self.fixLogger.error("Could not read \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .declined([refusal(path, "could not be read: \(error.localizedDescription)")])
        }

        let outcome = XCTestMigration.migrate(source: source, fileName: path)
        guard outcome.declines.isEmpty else { return .declined(outcome.declines) }
        guard outcome.parses else {
            return .declined([refusal(path, "was not written: the converted file does not parse\(Self.firstParseError(in: outcome.output)). Convert it by hand, or fix the syntax error in the original first.")])
        }
        guard outcome.testsAfter == outcome.testsBefore else {
            return .declined([refusal(path, "was not written: \(outcome.testsBefore) test methods went in and \(outcome.testsAfter) @Test functions came out, and a test without @Test silently stops running.")])
        }
        guard outcome.output != source else { return .unchanged }

        let introduced = findingsIntroduced(by: outcome.output, over: source, in: file)
        guard introduced.isEmpty else { return .declined(introduced) }

        if file.writing {
            do {
                try outcome.output.write(to: file.url, atomically: true, encoding: .utf8)
            } catch {
                Self.fixLogger.error("Could not write \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .declined([refusal(path, "could not be written: \(error.localizedDescription)")])
            }
        }
        let converted = outcome.testsAfter == 1 ? "1 test" : "\(outcome.testsAfter) tests"
        return .converted(FileModification(
            filePath: path,
            description: "Converted to Swift Testing (\(converted))",
            linesChanged: Self.changedLineCount(source, outcome.output),
            backupPath: nil))
    }

    // MARK: - Self-consistency with the gate

    /// The findings this gate would report on `output` that it did not report on `source`.
    ///
    /// Counted per rule: a `try!` the original already had is still there afterwards and is
    /// not the conversion's doing. A `missing-assertion` on a test that only ever called
    /// `XCTFail` is new, because the rule reads `@Test` functions and the original had none.
    /// Notes are left out. `skipped-test-inventory` records that a skip exists, which was as
    /// true of the `XCTSkip` it replaces.
    private func findingsIntroduced(by output: String, over source: String, in file: MigratedFile) -> [Diagnostic] {
        func gating(_ text: String) -> [Diagnostic] {
            auditSourceCode(
                text, fileName: file.displayPath, configuration: file.configuration,
                implementations: file.implementations
            ).diagnostics.filter { $0.severity != .note && $0.ruleId != "xctest-import" }
        }
        var allowance: [String: Int] = [:]
        for finding in gating(source) { allowance[finding.ruleId ?? "", default: 0] += 1 }

        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var introduced: [Diagnostic] = []
        for finding in gating(output) {
            let rule = finding.ruleId ?? ""
            if let remaining = allowance[rule], remaining > 0 {
                allowance[rule] = remaining - 1
                continue
            }
            var written = ""
            if let line = finding.lineNumber, lines.indices.contains(line - 1) {
                written = " The converted line: `\(lines[line - 1].trimmingCharacters(in: .whitespaces))`."
            }
            introduced.append(Diagnostic(
                severity: .error,
                message: "Converted, this file would be reported as \(rule): \(finding.message)\(written) A fix that trades one finding for another is not written.",
                filePath: file.displayPath,
                lineNumber: nil,
                ruleId: "xctest-import",
                suggestedFix: "This file was not converted. Change the XCTest original so the conversion has nothing to report, then run --fix again."))
        }
        return introduced
    }

    /// `" at its line N: <that line>"` for the first place `source` fails to parse.
    private static func firstParseError(in source: String) -> String {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        guard let token = tree.tokens(viewMode: .all).first(where: {
            $0.presence == .missing || $0.parent?.is(UnexpectedNodesSyntax.self) == true
        }) else { return "" }
        let line = token.startLocation(converter: converter).line
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.indices.contains(line - 1) else { return " at its line \(line)" }
        return " at its line \(line): `\(lines[line - 1].trimmingCharacters(in: .whitespaces))`"
    }

    private func refusal(_ path: String, _ reason: String) -> Diagnostic {
        Diagnostic(
            severity: .error,
            message: "\((path as NSString).lastPathComponent) \(reason)",
            filePath: path,
            lineNumber: nil,
            ruleId: "xctest-import")
    }

    /// Lines removed plus lines inserted.
    ///
    /// Not a position-by-position comparison: `import XCTest` becomes two imports, which
    /// shifts every later line by one, and that count called a five-line change a
    /// whole-file one. The preview prints this number.
    private static func changedLineCount(_ before: String, _ after: String) -> Int {
        let old = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let new = after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return new.difference(from: old).count
    }

    private static let fixLogger = Logger(
        subsystem: "com.quality-gate", category: "TestQualityAuditor.fix")
}
