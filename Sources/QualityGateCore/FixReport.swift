import Foundation

/// What `--fix` prints about one checker's result.
///
/// Kept apart from the CLI so it can be tested: the previous output was a list of rewritten
/// files followed by "12 diagnostic(s) require manual intervention", which named neither the
/// files that were left alone nor what stopped them. Twelve files of a fifty-file migration
/// were declined that way, and the reason had to be found by bisecting one of them.
public enum FixReport {

    /// The lines for a fix that was applied.
    ///
    /// - Parameters:
    ///   - result: What the checker's `fix` returned.
    ///   - diagnostics: What it was given. Anything in `result.unfixed` that is not among
    ///     these was written by the fixer, and is an explanation, not a pass-through.
    /// - Returns: One line per changed file; then each file left alone, with its reasons under
    ///   it; then a count of the findings the fixer never attempts.
    public static func applied(_ result: FixResult, given diagnostics: [Diagnostic]) -> [String] {
        lines(result, given: diagnostics, changed: "✓", declined: "✗", declinedSuffix: "not changed:")
    }

    /// The lines for `--fix --dry-run`: the same facts, in the conditional.
    ///
    /// - Parameters:
    ///   - result: What the checker's `previewFix` returned.
    ///   - diagnostics: What it was given.
    public static func preview(_ result: FixResult, given diagnostics: [Diagnostic]) -> [String] {
        lines(
            result, given: diagnostics, changed: "would change", declined: "would not change",
            declinedSuffix: "")
    }

    private static func lines(
        _ result: FixResult, given diagnostics: [Diagnostic],
        changed: String, declined: String, declinedSuffix: String
    ) -> [String] {
        var lines: [String] = []
        for modification in result.modifications {
            let backup = modification.backupPath.map { " (backup: \($0))" } ?? ""
            let count = modification.linesChanged == 1 ? "1 line" : "\(modification.linesChanged) lines"
            lines.append("  \(changed) \(modification.filePath) — \(modification.description), \(count)\(backup)")
        }

        let explanations = result.unfixed.filter { !diagnostics.contains($0) }
        var order: [String] = []
        var byFile: [String: [Diagnostic]] = [:]
        for explanation in explanations {
            let file = explanation.filePath ?? ""
            if byFile[file] == nil { order.append(file) }
            byFile[file, default: []].append(explanation)
        }
        for file in order {
            let name = file.isEmpty ? "(no file)" : file
            let suffix = declinedSuffix.isEmpty ? ":" : " — \(declinedSuffix)"
            lines.append("  \(declined) \(name)\(suffix)")
            for explanation in byFile[file] ?? [] {
                let line = explanation.lineNumber.map { "line \($0): " } ?? ""
                lines.append("      \(line)\(explanation.message)")
            }
        }

        let untouched = result.unfixed.count - explanations.count
        if untouched > 0 {
            let noun = untouched == 1 ? "finding is" : "findings are"
            lines.append("  ℹ  \(untouched) other \(noun) not auto-fixable; see the report below")
        }
        return lines
    }
}
