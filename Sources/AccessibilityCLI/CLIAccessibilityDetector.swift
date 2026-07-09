import AccessibilityCore
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Namespaced rule identifiers for the CLI accessibility detector.
enum CLIAccessibilityRule {
    static let noColorNotRespected = "a11y.cli.no-color-not-respected"
}

/// Detects accessibility violations in command-line (terminal) output.
///
/// v1 enforces one HIG-grounded rule:
/// - `a11y.cli.no-color-not-respected`: the file emits ANSI color escapes but never honors
///   the user's color preference (`NO_COLOR` / `isatty` / a `--no-color` flag). Screen-reader
///   and low-vision users, and anyone piping output, rely on color being suppressible.
///   Grounded in the HIG "adapt to the user's settings" principle; the CLI-native reference
///   is the NO_COLOR convention (no-color.org).
public struct CLIAccessibilityDetector: AccessibilityDetector {

    /// This detector audits the command-line frontend.
    public let frontend: Frontend = .cli

    /// Creates a CLI accessibility detector.
    public init() {}

    /// Parse the unit's source and report CLI accessibility violations.
    public func detect(in unit: SourceUnit) -> DetectionResult {
        // Coarse, low-false-positive guard: if the file honors color preference anywhere,
        // trust it and don't flag its color emissions.
        if Self.honorsColorPreference(in: unit.source) {
            return DetectionResult(diagnostics: [], overrides: [])
        }

        let tree = Parser.parse(source: unit.source)
        let visitor = CLIAccessibilityVisitor(
            fileName: unit.fileName,
            exemptionPatterns: unit.exemptionPatterns,
            source: unit.source,
            tree: tree
        )
        visitor.walk(tree)
        return DetectionResult(diagnostics: visitor.diagnostics, overrides: visitor.overrides)
    }

    /// True when the source references a color-preference guard (`NO_COLOR`, `isatty`,
    /// or a `--no-color` / `noColor` flag).
    static func honorsColorPreference(in source: String) -> Bool {
        let markers = ["NO_COLOR", "isatty", "no-color", "noColor"]
        return markers.contains { source.contains($0) }
    }
}

// MARK: - Syntax Visitor

final class CLIAccessibilityVisitor: SyntaxVisitor {
    let fileName: String
    let exemptionPatterns: [String]
    let sourceLines: [String]
    let converter: SourceLocationConverter
    var diagnostics: [Diagnostic] = []
    var overrides: [DiagnosticOverride] = []
    private var flagged = false

    init(fileName: String, exemptionPatterns: [String], source: String, tree: SourceFileSyntax) {
        self.fileName = fileName
        self.exemptionPatterns = exemptionPatterns
        self.sourceLines = source.components(separatedBy: .newlines)
        self.converter = SourceLocationConverter(fileName: fileName, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard !flagged else { return .skipChildren }

        let hasColor = node.segments.contains { segment in
            if case .stringSegment(let seg) = segment {
                return CLIAccessibilityVisitor.emitsANSIColor(seg.content.text)
            }
            return false
        }
        guard hasColor else { return .visitChildren }

        let location = node.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: CLIAccessibilityRule.noColorNotRespected) {
            overrides.append(override)
            flagged = true
            return .skipChildren
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "ANSI color output emitted without honoring the user's color preference. Users who pipe output, use screen readers, or set NO_COLOR will see raw escape codes or unreadable color. — \(AccessibilityPrinciple.respectVisualPrefs.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: CLIAccessibilityRule.noColorNotRespected,
            suggestedFix: "Gate color on the user's preference: check ProcessInfo.processInfo.environment[\"NO_COLOR\"], isatty(STDOUT_FILENO), or a --no-color flag before emitting ANSI escapes."
        ))
        flagged = true
        return .skipChildren
    }

    // MARK: - Helpers

    /// True when a string segment contains an ANSI CSI color (SGR) escape.
    ///
    /// Requires both a CSI introducer (real ESC byte or its Swift source spellings) and a
    /// color SGR code, so cursor-control-only escapes (e.g. clear screen) are not flagged.
    static func emitsANSIColor(_ text: String) -> Bool {
        let introducers = ["\u{001B}[", "\\u{1B}[", "\\u{1b}[", "\\u{001B}[", "\\u{001b}[", "\\u{01B}[", "\\u{01b}["]
        guard introducers.contains(where: { text.contains($0) }) else { return false }
        return containsColorSGR(text)
    }

    private static func containsColorSGR(_ text: String) -> Bool {
        let colorNeedles = [
            "[30m", "[31m", "[32m", "[33m", "[34m", "[35m", "[36m", "[37m", "[39m",
            "[90m", "[91m", "[92m", "[93m", "[94m", "[95m", "[96m", "[97m",
            "[40m", "[41m", "[42m", "[43m", "[44m", "[45m", "[46m", "[47m", "[49m",
            "[100m", "[101m", "[102m", "[103m", "[104m", "[105m", "[106m", "[107m",
            ";30m", ";31m", ";32m", ";33m", ";34m", ";35m", ";36m", ";37m", ";39m",
            ";90m", ";91m", ";92m", ";93m", ";94m", ";95m", ";96m", ";97m",
            "38;5;", "48;5;", "38;2;", "48;2;",
            "[0;3", "[1;3", "[0;9", "[1;9", "[0;4", "[1;4",
        ]
        return colorNeedles.contains { text.contains($0) }
    }

    private func overrideIfExempted(line: Int, ruleId: String) -> DiagnosticOverride? {
        let linesToCheck = [line - 1, line]
            .filter { $0 >= 1 && $0 <= sourceLines.count }
        for lineNum in linesToCheck {
            let lineContent = sourceLines[lineNum - 1]
            for pattern in exemptionPatterns where lineContent.contains(pattern) {
                return DiagnosticOverride(
                    ruleId: ruleId,
                    justification: lineContent.trimmingCharacters(in: .whitespaces),
                    filePath: fileName,
                    lineNumber: line
                )
            }
        }
        return nil
    }
}
