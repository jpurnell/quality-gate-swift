import Foundation

/// Parsed state of a module from a Master Plan checkbox line.
public struct DocumentedModuleStatus: Sendable, Equatable {
    /// Module name as it appears in the document.
    public let name: String

    /// Whether the checkbox is marked complete `[x]` vs incomplete `[ ]`.
    public let isComplete: Bool

    /// The description text after the module name (e.g., "Stub only", "Protocol, models (54 tests)").
    public let description: String

    /// Test count parsed from the description, if present (e.g., "(54 tests)" → 54).
    public let claimedTestCount: Int?

    /// 1-based line number where this entry appears in the document.
    public let line: Int
}

/// Parsed state of a roadmap phase.
public struct DocumentedPhase: Sendable, Equatable {
    /// Phase name (e.g., "Phase 1: Foundation").
    public let name: String

    /// Phase label (e.g., "CURRENT", "COMPLETE").
    public let label: String?

    /// Items in this phase with their completion state.
    public let items: [(text: String, isComplete: Bool)]

    /// 1-based line number where this phase heading appears.
    public let line: Int

    /// Whether all items in this phase are marked complete.
    public var allItemsComplete: Bool {
        guard !items.isEmpty else { return false }
        return items.allSatisfy(\.isComplete)
    }

    /// Equatable conformance comparing name, label, line, and item count.
    public static func == (lhs: DocumentedPhase, rhs: DocumentedPhase) -> Bool {
        lhs.name == rhs.name
            && lhs.label == rhs.label
            && lhs.line == rhs.line
            && lhs.items.count == rhs.items.count
    }
}

/// Parses Master Plan markdown to extract module status, roadmap phases, and metadata.
public enum MasterPlanParser {

    /// Parse module status entries from "What's Working" checkbox section.
    ///
    /// Matches lines like:
    /// - `- [x] SafetyAuditor — Code safety + OWASP security (83 tests)`
    /// - `- [ ] FooChecker — Stub only`
    ///
    /// - Parameter content: The full Master Plan markdown content.
    /// - Returns: Array of documented module statuses.
    public static func parseModuleStatus(from content: String) -> [DocumentedModuleStatus] {
        let lines = content.components(separatedBy: .newlines)
        var results: [DocumentedModuleStatus] = []
        var inStatusSection = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect "What's Working" section
            if trimmed.contains("What's Working") || trimmed.contains("What's Working") {
                inStatusSection = true
                continue
            }

            // Exit on next heading
            if inStatusSection && trimmed.hasPrefix("###") && !trimmed.contains("What's Working") {
                inStatusSection = false
                continue
            }

            guard inStatusSection else { continue }

            // Match checkbox lines: - [x] Name — Description or - [ ] Name — Description
            guard let entry = parseCheckboxLine(trimmed, lineNumber: index + 1) else {
                continue
            }

            results.append(entry)
        }

        return results
    }

    /// Parse roadmap phases with their items and labels.
    ///
    /// Matches headings like:
    /// - `### Phase 1: Foundation (COMPLETE)`
    /// - `### Phase 2: Checker Modules (CURRENT)`
    ///
    /// - Parameter content: The full Master Plan markdown content.
    /// - Returns: Array of documented phases.
    public static func parseRoadmapPhases(from content: String) -> [DocumentedPhase] {
        let lines = content.components(separatedBy: .newlines)
        var phases: [DocumentedPhase] = []
        var currentPhase: (name: String, label: String?, line: Int, items: [(String, Bool)])?
        var inRoadmap = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect Roadmap section
            if trimmed.hasPrefix("## Roadmap") {
                inRoadmap = true
                continue
            }

            // Exit on next top-level section
            if inRoadmap && trimmed.hasPrefix("## ") && !trimmed.contains("Roadmap") {
                if let phase = currentPhase {
                    phases.append(DocumentedPhase(
                        name: phase.name, label: phase.label,
                        items: phase.items, line: phase.line
                    ))
                }
                break
            }

            guard inRoadmap else { continue }

            // Match phase headings: ### Phase N: Name (LABEL)
            if trimmed.hasPrefix("### Phase") || trimmed.hasPrefix("### Future") {
                // Save previous phase
                if let phase = currentPhase {
                    phases.append(DocumentedPhase(
                        name: phase.name, label: phase.label,
                        items: phase.items, line: phase.line
                    ))
                }

                let (name, label) = parsePhaseHeading(trimmed)
                currentPhase = (name: name, label: label, line: index + 1, items: [])
                continue
            }

            // Match phase items: - [x] or - [ ]
            if let current = currentPhase, trimmed.hasPrefix("- [") {
                let isComplete = trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")
                let text = extractCheckboxText(trimmed)
                currentPhase = (
                    name: current.name, label: current.label,
                    line: current.line,
                    items: current.items + [(text, isComplete)]
                )
            }
        }

        // Save last phase
        if let phase = currentPhase {
            phases.append(DocumentedPhase(
                name: phase.name, label: phase.label,
                items: phase.items, line: phase.line
            ))
        }

        return phases
    }

    /// Parse the "Last Updated" date from the Master Plan.
    ///
    /// Matches lines like: `**Last Updated:** 2026-04-14`
    ///
    /// - Parameter content: The full Master Plan markdown content.
    /// - Returns: Tuple of (date string, line number) or nil.
    public static func parseLastUpdated(from content: String) -> (date: String, line: Int)? {
        let lines = content.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("Last Updated") else { continue }

            // Extract date: look for YYYY-MM-DD pattern
            let pattern = #"(\d{4}-\d{2}-\d{2})"#
            guard let range = trimmed.range(of: pattern, options: .regularExpression) else {
                continue
            }

            return (date: String(trimmed[range]), line: index + 1)
        }

        return nil
    }

    // MARK: - Private Helpers

    static func parseCheckboxLine(_ line: String, lineNumber: Int) -> DocumentedModuleStatus? {
        // Match: - [x] Name — Description  OR  - [ ] Name — Description
        guard line.hasPrefix("- [") else { return nil }

        let isComplete = line.hasPrefix("- [x]") || line.hasPrefix("- [X]")

        // Extract text after checkbox
        let afterCheckbox: String
        if isComplete {
            afterCheckbox = String(line.dropFirst("- [x] ".count))
        } else {
            guard line.hasPrefix("- [ ]") else { return nil }
            afterCheckbox = String(line.dropFirst("- [ ] ".count))
        }

        // Split on " — " (em dash) or " - " (hyphen) for name/description
        let separators = [" — ", " — ", " - "]
        var name = afterCheckbox
        var description = ""

        for sep in separators {
            if let range = afterCheckbox.range(of: sep) {
                name = String(afterCheckbox[afterCheckbox.startIndex..<range.lowerBound])
                description = String(afterCheckbox[range.upperBound...])
                break
            }
        }

        name = name.trimmingCharacters(in: .whitespaces)
        description = description.trimmingCharacters(in: .whitespaces)

        // Extract test count from description: "(N tests)"
        let testCount = parseTestCount(from: description)

        return DocumentedModuleStatus(
            name: name,
            isComplete: isComplete,
            description: description,
            claimedTestCount: testCount,
            line: lineNumber
        )
    }

    static func parseTestCount(from description: String) -> Int? {
        let pattern = #"\((\d+)\s+tests?\)"#
        guard let range = description.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let match = description[range]
        let digits = match.filter(\.isNumber)
        return Int(digits)
    }

    static func parsePhaseHeading(_ line: String) -> (name: String, label: String?) {
        // Match: ### Phase N: Name (LABEL)
        var name = line
        if name.hasPrefix("###") {
            name = String(name.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        // Extract label from parentheses at end
        let pattern = #"\(([A-Z]+)\)\s*$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else {
            return (name: name, label: nil)
        }

        let label = String(name[range])
            .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        let cleanName = String(name[name.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)

        return (name: cleanName, label: label)
    }

    static func extractCheckboxText(_ line: String) -> String {
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            return String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("- [ ] ") {
            return String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}
