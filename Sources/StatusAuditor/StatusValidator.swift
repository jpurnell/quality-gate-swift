import Foundation
import QualityGateCore

/// Cross-validates documented module status against actual project state.
public enum StatusValidator {

    /// Validate documented state against actual state and return diagnostics.
    ///
    /// - Parameters:
    ///   - documented: Module statuses parsed from Master Plan.
    ///   - actual: Module states collected from file system.
    ///   - phases: Roadmap phases parsed from Master Plan.
    ///   - lastUpdated: Last Updated date and line from Master Plan.
    ///   - masterPlanPath: Path to the Master Plan file (for diagnostic locations).
    ///   - configuration: StatusAuditor configuration with thresholds.
    /// - Returns: Array of diagnostics for any drift detected.
    public static func validate(
        documented: [DocumentedModuleStatus],
        actual: [String: ActualModuleState],
        phases: [DocumentedPhase],
        lastUpdated: (date: String, line: Int)?,
        masterPlanPath: String,
        configuration: StatusAuditorConfig
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        // Rule 1 & 2: Module completion vs reality
        for doc in documented {
            guard let state = actual[doc.name] else {
                // Only flag as missing if the entry looks like an SPM module name.
                // Feature descriptions ("Job analysis via LLM", "Docker + Redis")
                // aren't expected to have Sources/ directories.
                if doc.isComplete && looksLikeModuleName(doc.name) {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "'\(doc.name)' marked [x] (complete) but module directory not found in Sources/.",
                        filePath: masterPlanPath,
                        lineNumber: doc.line,
                        ruleId: "status.module-marked-complete-missing",
                        suggestedFix: "Remove the entry or uncheck it: - [ ] \(doc.name)"
                    ))
                }
                continue
            }

            // Rule 1: Module marked incomplete but has real code
            if !doc.isComplete && state.sourceLineCount >= configuration.stubThresholdLines {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "'\(doc.name)' marked [ ] (incomplete) but has \(state.sourceLineCount) lines of source code.",
                    filePath: masterPlanPath,
                    lineNumber: doc.line,
                    ruleId: "status.module-marked-incomplete",
                    suggestedFix: "Mark as complete: - [x] \(doc.name)"
                ))
            }

            // Rule 5: "Stub only" in description but module is implemented
            let descLower = doc.description.lowercased()
            if (descLower.contains("stub") || descLower.contains("not started") || descLower.contains("not implemented"))
                && state.sourceLineCount >= configuration.stubThresholdLines {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "'\(doc.name)' described as \"\(doc.description)\" but has \(state.sourceLineCount) lines of source code.",
                    filePath: masterPlanPath,
                    lineNumber: doc.line,
                    ruleId: "status.stub-description-mismatch",
                    suggestedFix: "Update description to reflect actual implementation"
                ))
            }

            // Rule 4: Test count drift
            if let claimed = doc.claimedTestCount, state.estimatedTestCount > 0 {
                let drift = abs(claimed - state.estimatedTestCount)
                let driftPercent = Double(drift) / max(Double(claimed), 1.0) * 100.0 // fp-safety:disable
                if Int(driftPercent) > configuration.testCountDriftPercent {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "'\(doc.name)' claims \(claimed) tests but estimated actual count is \(state.estimatedTestCount) (\(Int(driftPercent))% drift).",
                        filePath: masterPlanPath,
                        lineNumber: doc.line,
                        ruleId: "status.test-count-drift",
                        suggestedFix: "Update test count to (\(state.estimatedTestCount) tests)"
                    ))
                }
            }
        }

        // Rule 8: Phantom modules (in Package.swift but not documented)
        let documentedNames = Set(documented.map(\.name))
        for (name, state) in actual {
            if state.existsInPackageSwift
                && state.sourceLineCount >= configuration.stubThresholdLines
                && !documentedNames.contains(name)
                // Exclude test targets and plugins
                && !name.hasSuffix("Tests")
                && !name.hasSuffix("Plugin")
            {
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "'\(name)' exists in Package.swift with \(state.sourceLineCount) lines but is not documented in Master Plan.",
                    filePath: masterPlanPath,
                    ruleId: "status.phantom-module",
                    suggestedFix: "Add entry: - [x] \(name)"
                ))
            }
        }

        // Rule 6: Roadmap phase stale
        for phase in phases {
            if phase.label?.uppercased() == "CURRENT" && phase.allItemsComplete {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Phase '\(phase.name)' marked (CURRENT) but all \(phase.items.count) items are complete.",
                    filePath: masterPlanPath,
                    lineNumber: phase.line,
                    ruleId: "status.roadmap-phase-stale",
                    suggestedFix: "Update label to (COMPLETE)"
                ))
            }
        }

        // Rule 7: Last Updated staleness
        if let lastUpdated = lastUpdated {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            if let docDate = formatter.date(from: lastUpdated.date) {
                let daysSince = Calendar.current.dateComponents(
                    [.day], from: docDate, to: Date.now
                ).day ?? 0
                if daysSince > configuration.lastUpdatedStaleDays {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "Master Plan last updated \(lastUpdated.date) (\(daysSince) days ago, threshold: \(configuration.lastUpdatedStaleDays) days).",
                        filePath: masterPlanPath,
                        lineNumber: lastUpdated.line,
                        ruleId: "status.last-updated-stale",
                        suggestedFix: "Update to today's date"
                    ))
                }
            }
        }

        return diagnostics
    }

    // MARK: - Helpers

    /// Determines whether a "What's Working" entry name looks like an SPM module
    /// (e.g. "SafetyAuditor", "QualityGateCore") vs a feature description
    /// (e.g. "Job description analysis via LLM", "Docker + Redis").
    ///
    /// Module names are typically PascalCase identifiers without spaces or
    /// heavy punctuation. Feature descriptions contain spaces, sentence fragments,
    /// or special characters.
    static func looksLikeModuleName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // Feature descriptions almost always contain spaces
        // Allow single-space names like "All reporters" to be treated as features
        if trimmed.contains(" ") { return false }

        // Reject entries with punctuation common in descriptions but not module names
        let descriptionChars = CharacterSet(charactersIn: "()[]{}!?;:,+/")
        if trimmed.unicodeScalars.contains(where: { descriptionChars.contains($0) }) {
            return false
        }

        // Module names start with an uppercase letter (PascalCase) or are all lowercase
        guard let first = trimmed.first, first.isLetter else { return false }

        // Must be a plausible Swift identifier (letters, digits, underscores, hyphens)
        let identifierChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let allValid = trimmed.unicodeScalars.allSatisfy { identifierChars.contains($0) }

        return allValid
    }
}
