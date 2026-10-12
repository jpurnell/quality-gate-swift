import Foundation
import QualityGateCore

/// One raw idiom finding before severity/exemption processing.
struct IdiomFinding {
    let ruleId: String
    let message: String
    let lineNumber: Int
    let columnNumber: Int?
    let suggestedFix: String?
    /// Last line of the region the rule objects to.
    ///
    /// Every idiom rule reports one. `nil` is reserved for a rule that genuinely has no region,
    /// so a consumer counting flagged lines can exclude it and name it rather than assume one
    /// line — and there is currently no such rule here.
    let endLine: Int?
}

/// Pure-text whitespace and length rules, where line text is the honest
/// representation (no AST involved): `idiom.file-length`, `idiom.line-length`,
/// `idiom.trailing-whitespace`, `idiom.trailing-newline`,
/// and `idiom.vertical-whitespace`.
enum IdiomTextRules {

    /// Runs all text rules over `source` and returns raw findings.
    static func run(source: String, config: IdiomConfig) -> [IdiomFinding] {
        guard !source.isEmpty else { return [] }
        var findings: [IdiomFinding] = []
        var lines = source.lines
        if lines.last == "" { lines.removeLast() } // final newline produces a phantom empty component

        if lines.count > config.maxFileLength {
            findings.append(IdiomFinding(
                ruleId: "idiom.file-length",
                message: "File spans \(lines.count) lines (max \(config.maxFileLength)) — consider splitting it.",
                lineNumber: config.maxFileLength + 1,
                columnNumber: 1,
                suggestedFix: nil,
                // The lines *past* the limit are what the rule objects to. Spanning the whole
                // file would make a long file read as almost entirely flagged to anything
                // counting flagged lines, while the lines within the limit are not the defect.
                endLine: lines.count
            ))
        }

        var blankRun = 0
        // Set when a run passes the limit, cleared when the run ends. The finding is emitted at
        // the end rather than at the threshold, because the region it covers is the whole excess
        // run and its extent is not known until the run closes.
        var excessBlankStart: Int?
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1

            if line.count > config.maxLineLength, !isURLOnly(line) {
                findings.append(IdiomFinding(
                    ruleId: "idiom.line-length",
                    message: "Line is \(line.count) characters (max \(config.maxLineLength)).",
                    lineNumber: lineNumber,
                    columnNumber: config.maxLineLength + 1,
                    suggestedFix: nil,
                    endLine: lineNumber
                ))
            }

            if let last = line.last, last == " " || last == "\t" {
                let trimmed = trimTrailingWhitespace(line)
                findings.append(IdiomFinding(
                    ruleId: "idiom.trailing-whitespace",
                    message: "Line has trailing whitespace.",
                    lineNumber: lineNumber,
                    columnNumber: trimmed.count + 1,
                    suggestedFix: trimmed,
                    endLine: lineNumber
                ))
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun == config.maxConsecutiveBlankLines + 1 {
                    excessBlankStart = lineNumber
                }
            } else {
                if let start = excessBlankStart {
                    findings.append(verticalWhitespaceFinding(
                        start: start, end: lineNumber - 1, config: config))
                    excessBlankStart = nil
                }
                blankRun = 0
            }
        }

        // A blank run that reaches the end of the file never sees a non-blank line to close it.
        if let start = excessBlankStart {
            findings.append(verticalWhitespaceFinding(
                start: start, end: max(start, lines.count), config: config))
        }

        if !source.hasSuffix("\n") {
            findings.append(IdiomFinding(
                ruleId: "idiom.trailing-newline",
                message: "File must end with exactly one trailing newline (none found).",
                lineNumber: max(1, lines.count),
                columnNumber: nil,
                suggestedFix: "\n",
                endLine: max(1, lines.count)
            ))
        } else if source.hasSuffix("\n\n") {
            findings.append(IdiomFinding(
                ruleId: "idiom.trailing-newline",
                message: "File must end with exactly one trailing newline (multiple found).",
                lineNumber: max(1, lines.count),
                columnNumber: nil,
                suggestedFix: "\n",
                endLine: max(1, lines.count)
            ))
        }

        return findings
    }

    /// One `idiom.vertical-whitespace` finding covering an entire excess blank run.
    private static func verticalWhitespaceFinding(
        start: Int,
        end: Int,
        config: IdiomConfig
    ) -> IdiomFinding {
        IdiomFinding(
            ruleId: "idiom.vertical-whitespace",
            message: "More than \(config.maxConsecutiveBlankLines) consecutive blank lines.",
            lineNumber: start,
            columnNumber: 1,
            suggestedFix: nil,
            endLine: max(start, end)
        )
    }

    /// Removes trailing spaces and tabs from a line.
    static func trimTrailingWhitespace(_ line: String) -> String {
        var result = line
        while let last = result.last, last == " " || last == "\t" {
            result.removeLast()
        }
        return result
    }

    /// True when the line's content (after stripping comment markers) is a single URL token.
    static func isURLOnly(_ line: String) -> Bool {
        var text = line.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("/") || text.hasPrefix("*") {
            text.removeFirst()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && !text.contains(" ") && text.contains("://")
    }
}
