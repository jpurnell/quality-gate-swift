import Foundation
import QualityGateCore

/// Generates and applies surgical patches to Master Plan based on diagnostics.
public enum StatusRemediator {

    /// Apply fixes from diagnostics to the Master Plan file.
    ///
    /// Creates a timestamped backup before modifying any file.
    /// Only patches provably-wrong content — preserves human-authored prose.
    ///
    /// - Parameters:
    ///   - diagnostics: Diagnostics from a prior StatusValidator run.
    ///   - masterPlanPath: Path to the Master Plan file.
    ///   - configuration: Project configuration.
    /// - Returns: Fix result describing changes made and unfixed diagnostics.
    public static func apply(
        diagnostics: [Diagnostic],
        masterPlanPath: String,
        configuration: Configuration
    ) throws -> FixResult {
        guard let content = try? String(contentsOfFile: masterPlanPath, encoding: .utf8) else {
            return FixResult(modifications: [], unfixed: diagnostics)
        }

        var lines = content.components(separatedBy: "\n")
        var linesChanged = 0
        var unfixed: [Diagnostic] = []

        for diag in diagnostics {
            guard let ruleId = diag.ruleId else {
                unfixed.append(diag)
                continue
            }

            switch ruleId {
            case "status.module-marked-incomplete":
                // Flip [ ] to [x]
                if let line = diag.line, line >= 1, line <= lines.count {
                    let original = lines[line - 1]
                    let patched = original
                        .replacingOccurrences(of: "- [ ]", with: "- [x]")
                    if patched != original {
                        lines[line - 1] = patched
                        linesChanged += 1
                    }
                } else {
                    unfixed.append(diag)
                }

            case "status.stub-description-mismatch":
                // Remove "Stub only" or "Not started" from description
                if let line = diag.line, line >= 1, line <= lines.count {
                    let original = lines[line - 1]
                    var patched = original
                    for stub in ["Stub only", "stub only", "Not started", "not started", "Not implemented", "not implemented"] {
                        patched = patched.replacingOccurrences(of: stub, with: "Implemented")
                    }
                    if patched != original {
                        lines[line - 1] = patched
                        linesChanged += 1
                    }
                } else {
                    unfixed.append(diag)
                }

            case "status.test-count-drift":
                // Update test count in parentheses
                if let line = diag.line, line >= 1, line <= lines.count,
                   let suggestedFix = diag.suggestedFix {
                    let original = lines[line - 1]
                    // Extract new count from suggestedFix: "Update test count to (N tests)"
                    let pattern = #"\((\d+)\s+tests?\)"#
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let range = regex.firstMatch(
                        in: original,
                        range: NSRange(original.startIndex..., in: original)
                       ) {
                        // Find the new count from suggestedFix
                        if let newMatch = regex.firstMatch(
                            in: suggestedFix,
                            range: NSRange(suggestedFix.startIndex..., in: suggestedFix)
                        ),
                           let newRange = Range(newMatch.range, in: suggestedFix),
                           let oldRange = Range(range.range, in: original) {
                            var patched = original
                            patched.replaceSubrange(oldRange, with: String(suggestedFix[newRange]))
                            lines[line - 1] = patched
                            linesChanged += 1
                        }
                    }
                } else {
                    unfixed.append(diag)
                }

            case "status.roadmap-phase-stale":
                // Replace (CURRENT) with (COMPLETE)
                if let line = diag.line, line >= 1, line <= lines.count {
                    let original = lines[line - 1]
                    let patched = original
                        .replacingOccurrences(of: "(CURRENT)", with: "(COMPLETE)")
                    if patched != original {
                        lines[line - 1] = patched
                        linesChanged += 1
                    }
                } else {
                    unfixed.append(diag)
                }

            case "status.last-updated-stale":
                // Update date to today
                if let line = diag.line, line >= 1, line <= lines.count {
                    let original = lines[line - 1]
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withFullDate]
                    let today = formatter.string(from: Date.now)
                    let datePattern = #"\d{4}-\d{2}-\d{2}"#
                    if let regex = try? NSRegularExpression(pattern: datePattern),
                       let match = regex.firstMatch(
                        in: original,
                        range: NSRange(original.startIndex..., in: original)
                       ),
                       let range = Range(match.range, in: original) {
                        var patched = original
                        patched.replaceSubrange(range, with: today)
                        lines[line - 1] = patched
                        linesChanged += 1
                    }
                } else {
                    unfixed.append(diag)
                }

            case "status.module-marked-complete-missing",
                 "status.phantom-module",
                 "status.doc-doc-conflict":
                // These require human judgment — can't safely auto-fix
                unfixed.append(diag)

            default:
                unfixed.append(diag)
            }
        }

        guard linesChanged > 0 else {
            return FixResult(modifications: [], unfixed: unfixed)
        }

        // Create timestamped backup
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let timestamp = formatter.string(from: Date.now)
            .replacingOccurrences(of: ":", with: "-")
        let backupPath = "\(masterPlanPath).\(timestamp).backup"
        try content.write(toFile: backupPath, atomically: true, encoding: .utf8)

        // Write patched content
        let patchedContent = lines.joined(separator: "\n")
        try patchedContent.write(toFile: masterPlanPath, atomically: true, encoding: .utf8)

        let modification = FileModification(
            filePath: masterPlanPath,
            description: "Applied \(linesChanged) patches",
            linesChanged: linesChanged,
            backupPath: backupPath
        )

        return FixResult(modifications: [modification], unfixed: unfixed)
    }
}
