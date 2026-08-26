import AccessibilityCore
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Namespaced rule identifiers for the CLI accessibility detector.
enum CLIAccessibilityRule {
    static let noColorNotRespected = "a11y.cli.no-color-not-respected"
    static let cursorControlNoTty = "a11y.cli.cursor-control-no-tty"
    static let colorOnlyMeaning = "a11y.cli.color-only-meaning"
}

/// Detects accessibility violations in command-line (terminal) output.
///
/// Rules:
/// - `a11y.cli.no-color-not-respected`: ANSI color emitted without honoring `NO_COLOR` /
///   `isatty` / `--no-color`.
/// - `a11y.cli.cursor-control-no-tty`: cursor/screen-control escapes emitted without a
///   terminal (isatty/TERM) check — they garble piped or redirected output.
/// - `a11y.cli.color-only-meaning`: a colored string whose visible content is only an
///   interpolated value (no descriptive text), so state is conveyed by color alone.
///
/// Grounded in the HIG "adapt to the user's settings" and "more than color alone"
/// principles; the CLI-native reference is the NO_COLOR convention (no-color.org).
public struct CLIAccessibilityDetector: AccessibilityDetector {

    /// This detector audits the command-line frontend.
    public let frontend: Frontend = .cli

    /// Creates a CLI accessibility detector.
    public init() {}

    /// Parse the unit's source and report CLI accessibility violations.
    public func detect(in unit: SourceUnit) -> DetectionResult {
        let tree = Parser.parse(source: unit.source)
        let visitor = CLIAccessibilityVisitor(
            fileName: unit.fileName,
            exemptionPatterns: unit.exemptionPatterns,
            source: unit.source,
            honorsPreference: Self.honorsColorPreference(in: unit.source),
            tree: tree
        )
        visitor.walk(tree)
        return DetectionResult(diagnostics: visitor.diagnostics, overrides: visitor.overrides)
    }

    /// Markers that mean the file consults the user's color/terminal preference.
    static let preferenceMarkers = ["NO_COLOR", "isatty", "no-color", "noColor", "TERM"]

    /// True when the source references a color/terminal-preference guard (`NO_COLOR`,
    /// `isatty`, `TERM`, or a `--no-color` / `noColor` flag).
    ///
    /// Matched at identifier boundaries rather than as bare substrings. A plain
    /// `contains` made `TERM` match the word `TERMINAL`, so a file that merely mentioned a
    /// terminal in a doc comment silently switched off all three `a11y.cli.*` rules for its
    /// entire length — the rule was defeated by prose about the thing it audits.
    ///
    /// The boundary is deliberately strict, which costs the compound spellings: a lone
    /// `noColorFlag` no longer registers. A file that consults the preference almost always
    /// names `NO_COLOR` or `isatty` somewhere too, and a marker that costs nothing to trip
    /// cannot be told apart from a considered decision.
    static func honorsColorPreference(in source: String) -> Bool {
        preferenceMarkers.contains { containsAtIdentifierBoundary(source, marker: $0) }
    }

    /// True when `marker` occurs in `source` without an identifier character on either side.
    static func containsAtIdentifierBoundary(_ source: String, marker: String) -> Bool {
        guard !marker.isEmpty else { return false }
        var searchStart = source.startIndex
        while let found = source.range(of: marker, range: searchStart..<source.endIndex) {
            let beforeIsIdentifier = found.lowerBound > source.startIndex
                && isIdentifierCharacter(source[source.index(before: found.lowerBound)])
            let afterIsIdentifier = found.upperBound < source.endIndex
                && isIdentifierCharacter(source[found.upperBound])
            if !beforeIsIdentifier && !afterIsIdentifier { return true }
            searchStart = found.lowerBound < source.endIndex
                ? source.index(after: found.lowerBound)
                : source.endIndex
            if searchStart >= source.endIndex { break }
        }
        return false
    }

    /// Characters that continue a Swift identifier, so a marker abutting one is part of a
    /// longer word rather than a reference to the marker itself.
    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

// MARK: - Syntax Visitor

final class CLIAccessibilityVisitor: SyntaxVisitor {
    let fileName: String
    let exemptionPatterns: [String]
    let sourceLines: [String]
    let honorsPreference: Bool
    let converter: SourceLocationConverter
    var diagnostics: [Diagnostic] = []
    var overrides: [DiagnosticOverride] = []
    private var flaggedColor = false
    private var flaggedCursor = false
    private var flaggedColorOnly = false

    init(fileName: String, exemptionPatterns: [String], source: String, honorsPreference: Bool, tree: SourceFileSyntax) {
        self.fileName = fileName
        self.exemptionPatterns = exemptionPatterns
        self.sourceLines = source.lines
        self.honorsPreference = honorsPreference
        self.converter = SourceLocationConverter(fileName: fileName, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        // All three rules are about what a program *writes* to a terminal. A constant that
        // names an escape, or a function that returns one, writes nothing — the caller
        // decides whether to write it and whether to gate that on the user's preference.
        // Without this, every terminal library was a wall of findings for having a vocabulary.
        guard Self.reachesOutput(node) else { return .visitChildren }

        let literals = Self.stringSegments(of: node)
        let combined = literals.joined()

        // Rule: color-only-meaning — colored, interpolated, no descriptive text.
        if !flaggedColorOnly,
           Self.emitsANSIColor(combined),
           Self.hasInterpolation(node),
           !literals.contains(where: { Self.hasVisibleLetters($0) }) {
            emit(
                node: node,
                ruleId: CLIAccessibilityRule.colorOnlyMeaning,
                message: "Colored output conveys state by color alone (the visible content is only an interpolated value). — \(AccessibilityPrinciple.notColorAlone.higAnchor)",
                fix: "Include a text or symbol marker alongside the color (e.g. \"error: \\(value)\" or a ✓/✗), so meaning survives without color."
            )
            flaggedColorOnly = true
        }

        // The remaining rules are about honoring the user's terminal preference.
        if !honorsPreference {
            if !flaggedColor, Self.emitsANSIColor(combined) {
                emit(
                    node: node,
                    ruleId: CLIAccessibilityRule.noColorNotRespected,
                    message: "ANSI color output emitted without honoring the user's color preference. Users who pipe output, use screen readers, or set NO_COLOR will see raw escape codes or unreadable color. — \(AccessibilityPrinciple.respectVisualPrefs.higAnchor)",
                    fix: "Gate color on the user's preference: check ProcessInfo.processInfo.environment[\"NO_COLOR\"], isatty(STDOUT_FILENO), or a --no-color flag before emitting ANSI escapes."
                )
                flaggedColor = true
            }
            if !flaggedCursor, Self.emitsCursorControl(combined) {
                emit(
                    node: node,
                    ruleId: CLIAccessibilityRule.cursorControlNoTty,
                    message: "Cursor/screen-control escapes emitted without a terminal check — they garble piped or redirected output. — \(AccessibilityPrinciple.respectVisualPrefs.higAnchor)",
                    fix: "Guard cursor/screen control on isatty(STDOUT_FILENO) (or a TERM check) so non-interactive output stays clean."
                )
                flaggedCursor = true
            }
        }

        return .visitChildren
    }

    // MARK: - Emit

    private func emit(node: StringLiteralExprSyntax, ruleId: String, message: String, fix: String) {
        let location = node.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: ruleId) {
            overrides.append(override)
            return
        }
        diagnostics.append(Diagnostic(
            severity: .warning,
            message: message,
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: ruleId,
            suggestedFix: fix
        ))
    }

    // MARK: - Emission

    /// Functions whose whole job is to put bytes somewhere a user reads them.
    static let outputFunctions: Set<String> = [
        "print", "debugPrint", "puts", "fputs", "fwrite", "NSLog",
    ]

    /// True when `node` sits inside the arguments of a call that writes to output.
    ///
    /// Walks the ancestors rather than the operand, so a literal reaches output however it
    /// is dressed on the way — concatenated, interpolated, wrapped in `Data(_:)`. The check
    /// is syntactic and stops there: a literal assigned to a variable that is printed three
    /// statements later is not followed, because that is dataflow and this is a linter. The
    /// missed case is the quieter failure of the two, and it was the *opposite* error —
    /// treating every literal as output — that made these rules unusable.
    static func reachesOutput(_ node: StringLiteralExprSyntax) -> Bool {
        var child = Syntax(node)
        while let parent = child.parent {
            if let call = parent.as(FunctionCallExprSyntax.self),
               child.id == Syntax(call.arguments).id,
               writesOutput(call) {
                return true
            }
            child = parent
        }
        return false
    }

    /// True when `call` names a function that writes.
    ///
    /// Matches the known output functions exactly, plus any callee whose name reads as a
    /// write (`writeEscape`, `handle.write`, `emitLine`) — a terminal library's own writer
    /// is the case that matters most and it never has a standard-library name.
    static func writesOutput(_ call: FunctionCallExprSyntax) -> Bool {
        let name = calleeBaseName(call)
        guard !name.isEmpty else { return false }
        if outputFunctions.contains(name) { return true }
        let lowered = name.lowercased()
        return lowered.contains("write") || lowered.contains("emit")
    }

    /// The bare name of whatever `call` calls: `print` for `print(…)`, `write` for
    /// `handle.write(…)`. Empty when the callee is some other expression shape.
    static func calleeBaseName(_ call: FunctionCallExprSyntax) -> String {
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return ""
    }

    // MARK: - ANSI helpers

    /// The literal (non-interpolation) segment texts of a string literal.
    static func stringSegments(of node: StringLiteralExprSyntax) -> [String] {
        node.segments.compactMap { segment in
            if case .stringSegment(let seg) = segment { return seg.content.text }
            return nil
        }
    }

    static func hasInterpolation(_ node: StringLiteralExprSyntax) -> Bool {
        node.segments.contains { if case .expressionSegment = $0 { return true }; return false }
    }

    private static let introducers = ["\u{001B}[", "\\u{1B}[", "\\u{1b}[", "\\u{001B}[", "\\u{001b}[", "\\u{01B}[", "\\u{01b}["]

    /// True when the text contains an ANSI CSI color (SGR) escape.
    static func emitsANSIColor(_ text: String) -> Bool {
        guard introducers.contains(where: { text.contains($0) }) else { return false }
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

    /// True when the text contains a cursor/screen-control escape (CSI ending in a
    /// non-`m` letter, e.g. clear screen, cursor move, hide cursor).
    static func emitsCursorControl(_ text: String) -> Bool {
        guard introducers.contains(where: { text.contains($0) }) else { return false }
        let cursorNeedles = [
            "[2J", "[0J", "[1J", "[3J", "[H", "[f", "[K", "[0K", "[1K", "[2K",
            "[s", "[u", "[?25l", "[?25h", "[?1049h", "[?1049l", "[G", "[E", "[F",
        ]
        if cursorNeedles.contains(where: { text.contains($0) }) { return true }
        // Cursor movement: [<digits>A/B/C/D
        for terminator in ["A", "B", "C", "D"] {
            var searchStart = text.startIndex
            while let openBracket = text.range(of: "[", range: searchStart..<text.endIndex) {
                var idx = openBracket.upperBound
                var sawDigit = false
                while idx < text.endIndex, text[idx].isNumber { idx = text.index(after: idx); sawDigit = true }
                if sawDigit, idx < text.endIndex, String(text[idx]) == terminator { return true }
                searchStart = openBracket.upperBound
            }
        }
        return false
    }

    /// True when a string-literal segment contains descriptive letters after removing
    /// ANSI escape sequences (so the SGR/CSI codes themselves don't count as text).
    static func hasVisibleLetters(_ text: String) -> Bool {
        removingEscapes(text).contains { $0.isLetter }
    }

    /// Strips `\u{...}` unicode escapes, real ESC chars, and leftover CSI bodies
    /// (`[<params><letter>`) so only genuinely visible characters remain.
    static func removingEscapes(_ text: String) -> String {
        // Pass 1: drop \u{...} spelled escapes and real ESC control chars.
        let chars = Array(text)
        var pass1 = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "u" {
                var j = i + 2
                while j < chars.count, chars[j] != "}" { j += 1 }
                i = (j < chars.count) ? j + 1 : chars.count
                continue
            }
            if chars[i] == "\u{001B}" { i += 1; continue }
            pass1.append(chars[i])
            i += 1
        }
        // Pass 2: drop leftover CSI bodies "[<digits/;/?>*<letter>".
        let p = Array(pass1)
        var out = ""
        var k = 0
        while k < p.count {
            if p[k] == "[" {
                var j = k + 1
                while j < p.count, p[j].isNumber || p[j] == ";" || p[j] == "?" { j += 1 }
                if j < p.count, p[j].isLetter {
                    k = j + 1
                    continue
                }
            }
            out.append(p[k])
            k += 1
        }
        return out
    }

    // MARK: - Exemptions

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
