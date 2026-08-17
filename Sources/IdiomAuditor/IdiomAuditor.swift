import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Native style/idiom checker covering the head of SwiftLint usage
/// (Phase 4c §1 of the Major-Points Parity proposal).
///
/// Advisory posture: every finding is severity `.note` (escalatable to
/// `.warning` via ``IdiomConfig/escalateToWarning``) and the check status is
/// always `.passed` — the gate blocks on correctness, not style. An
/// `// idiom:exempt` comment on the flagged line suppresses the finding and
/// records a `DiagnosticOverride` — recorded, never silent.
public struct IdiomAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "IdiomAuditor")

    /// Unique identifier for this checker.
    public let id = "idiom"
    /// Human-readable name shown in quality-gate output.
    public let name = "Idiom Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Non-idiomatic Swift the language has a shorter form for; `// idiom:exempt` is recorded, never silent (advisory)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.codeHygiene

    /// What this checker's findings are about — see `CheckerKind`.
    /// `convention`: Swift idiom shades into taste, and taste is not a defect report.
    public let kind = CheckerKind.convention

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// The idiom configuration in effect for this instance.
    public let config: IdiomConfig
    /// Project root override (injectable for tests); nil means the current directory.
    public let root: String?

    /// Creates an idiom auditor.
    ///
    /// - Parameters:
    ///   - config: Rule thresholds and knobs; defaults throughout.
    ///   - root: Project root to walk; nil uses `FileManager.default.currentDirectoryPath`.
    public init(config: IdiomConfig = IdiomConfig(), root: String? = nil) {
        self.config = config
        self.root = root
    }

    /// The result of auditing a single source string.
    public struct SourceAudit: Sendable {
        /// Idiom diagnostics that survived exemption filtering.
        public let diagnostics: [Diagnostic]
        /// Findings suppressed by `// idiom:exempt` comments, recorded for the ledger.
        public let overrides: [DiagnosticOverride]
    }

    /// Whether `source` parses without syntax errors — used by fix round-trip tests.
    public static func parsesCleanly(_ source: String) -> Bool {
        !Parser.parse(source: source).hasError
    }

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or out-of-tree path
    /// among its inputs — so the same tree under the same gate binary yields the same verdict.
    /// `gateIdentityHash` folds in the binary's identity and the toolchain, so a rebuild or a
    /// compiler change invalidates every entry.
    ///
    /// `wholeSourceAndDocs` rather than `wholeSource`: it is the wider set, and over-including
    /// an input costs a cache miss while under-including one serves a stale pass.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configuration: configuration
        )
    }

    /// Walks all `.swift` files under `Sources/` and `Tests/` of the root
    /// (sorted, deterministic) and runs every idiom rule on each.
    ///
    /// - Parameter configuration: The quality-gate configuration for this run.
    /// - Returns: A check result that always reports `.passed` (advisory posture).
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let rootPath = root ?? fileManager.currentDirectoryPath

        var filePaths: [String] = []
        for topLevel in ["Sources", "Tests"] {
            let directory = (rootPath as NSString).appendingPathComponent(topLevel)
            guard fileManager.fileExists(atPath: directory), // SAFETY: CLI tool reads local project sources
                  let enumerator = fileManager.enumerator(atPath: directory) else { continue }
            while let relativePath = enumerator.nextObject() as? String {
                guard relativePath.hasSuffix(".swift") else { continue }
                filePaths.append((directory as NSString).appendingPathComponent(relativePath))
            }
        }
        filePaths.sort()

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        for filePath in filePaths {
            do {
                let source = try String(contentsOfFile: filePath, encoding: .utf8)
                let audit = auditSource(source, filePath: filePath)
                diagnostics.append(contentsOf: audit.diagnostics)
                overrides.append(contentsOf: audit.overrides)
            } catch {
                Self.logger.warning("Skipping unreadable source file: \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return CheckResult(
            checkerId: id,
            status: .passed,
            diagnostics: diagnostics,
            overrides: overrides,
            duration: ContinuousClock.now - startTime
        )
    }

    /// Runs every idiom rule over one source string.
    ///
    /// - Parameters:
    ///   - source: The Swift source text.
    ///   - filePath: The path recorded on each diagnostic.
    /// - Returns: Diagnostics plus any `// idiom:exempt` override records.
    public func auditSource(_ source: String, filePath: String) -> SourceAudit {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: filePath, tree: tree)

        let visitor = IdiomSyntaxVisitor(config: config, converter: converter)
        visitor.walk(tree)

        var findings = visitor.findings
        findings.append(contentsOf: todoFindings(tree: tree, converter: converter))
        findings.append(contentsOf: IdiomTextRules.run(source: source, config: config))
        findings.sort { lhs, rhs in
            if lhs.lineNumber != rhs.lineNumber { return lhs.lineNumber < rhs.lineNumber }
            if lhs.ruleId != rhs.ruleId { return lhs.ruleId < rhs.ruleId }
            return (lhs.columnNumber ?? 0) < (rhs.columnNumber ?? 0)
        }

        let lines = source.lines
        let severity: Diagnostic.Severity = config.escalateToWarning ? .warning : .note
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        for finding in findings {
            let lineIndex = finding.lineNumber - 1
            if lineIndex >= 0, lineIndex < lines.count, lines[lineIndex].contains("// idiom:exempt") {
                overrides.append(DiagnosticOverride(
                    ruleId: finding.ruleId,
                    justification: "// idiom:exempt",
                    filePath: filePath,
                    lineNumber: finding.lineNumber
                ))
            } else {
                diagnostics.append(Diagnostic(
                    severity: severity,
                    message: finding.message,
                    filePath: filePath,
                    lineNumber: finding.lineNumber,
                    columnNumber: finding.columnNumber,
                    ruleId: finding.ruleId,
                    suggestedFix: finding.suggestedFix
                ))
            }
        }
        return SourceAudit(diagnostics: diagnostics, overrides: overrides)
    }

    // MARK: - idiom.todo-policy (comment trivia)

    /// Scans comment trivia for TODO/FIXME markers lacking a ticket reference.
    private func todoFindings(
        tree: SourceFileSyntax,
        converter: SourceLocationConverter
    ) -> [IdiomFinding] {
        let regex = ticketRegex()
        var findings: [IdiomFinding] = []

        func inspect(_ piece: TriviaPiece, at position: AbsolutePosition) {
            let text: String
            switch piece {
            case .lineComment(let comment), .blockComment(let comment),
                 .docLineComment(let comment), .docBlockComment(let comment):
                text = comment
            default:
                return
            }
            guard text.contains("TODO") || text.contains("FIXME") else { return }
            if let regex {
                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil { return }
            }
            let location = converter.location(for: position)
            findings.append(IdiomFinding(
                ruleId: "idiom.todo-policy",
                message: "TODO without ticket — add a reference matching '\(config.todoTicketPattern)'.",
                lineNumber: location.line,
                columnNumber: location.column,
                suggestedFix: nil
            ))
        }

        for token in tree.tokens(viewMode: .sourceAccurate) {
            var position = token.position
            for piece in token.leadingTrivia {
                inspect(piece, at: position)
                position += piece.sourceLength
            }
            var trailingPosition = token.endPositionBeforeTrailingTrivia
            for piece in token.trailingTrivia {
                inspect(piece, at: trailingPosition)
                trailingPosition += piece.sourceLength
            }
        }
        return findings
    }

    /// Compiles the ticket pattern, falling back to the default on invalid config.
    private func ticketRegex() -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: config.todoTicketPattern)
        } catch {
            Self.logger.warning("Invalid todoTicketPattern '\(config.todoTicketPattern, privacy: .public)': \(error.localizedDescription, privacy: .public) — falling back to the default pattern")
            do {
                return try NSRegularExpression(pattern: IdiomConfig().todoTicketPattern)
            } catch {
                Self.logger.error("Default todo ticket pattern failed to compile: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}
