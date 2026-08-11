import Foundation
import QualityGateCore

/// One tick-box line in a markdown checklist.
public struct ChecklistItem: Sendable, Equatable {

    /// 1-based line number in the governed file.
    public let line: Int

    /// The artifact the line is about, normalised: the text before the first separator, with
    /// backticks, emphasis and strike-through markers removed.
    public let label: String

    /// Whether the tick-box is ticked.
    public let isComplete: Bool

    /// Whether the item is struck through, which this project's housekeeping rule uses to
    /// keep a completed item and the reasoning recorded at the time.
    public let isStruck: Bool

    /// Creates an item.
    public init(line: Int, label: String, isComplete: Bool, isStruck: Bool) {
        self.line = line
        self.label = label
        self.isComplete = isComplete
        self.isStruck = isStruck
    }
}

/// One artifact about which a document asserts both P and ¬P.
public struct SelfContradiction: Sendable, Equatable {

    /// The artifact named on both sides.
    public let label: String

    /// Lines where the item is unticked.
    public let incompleteLines: [Int]

    /// Lines where the item is ticked.
    public let completeLines: [Int]

    /// Creates a contradiction.
    public init(label: String, incompleteLines: [Int], completeLines: [Int]) {
        self.label = label
        self.incompleteLines = incompleteLines
        self.completeLines = completeLines
    }

    /// The rule id reported to the gate.
    public var ruleId: String { "doc-generated.self-contradiction" }

    /// The line the finding is reported at: the first mention, in document order.
    public var line: Int { (incompleteLines + completeLines).min() ?? 1 }

    /// A message naming both sides, because either one may be the wrong one.
    public var message: String {
        let incomplete = incompleteLines.map(String.init).joined(separator: ", ")
        let complete = completeLines.map(String.init).joined(separator: ", ")
        return "`\(label)` is unchecked at line \(incomplete) and checked at line \(complete) "
            + "— this document disagrees with itself; no generator is involved."
    }
}

/// Extracts markdown tick-box items from a document.
///
/// The label is the *artifact*, not the line: `- [x] XcodeReporter — --format xcode output`
/// and `- [ ] XcodeReporter — --format xcode for Xcode Build Phases` are two claims about one
/// thing, and a comparator keyed on the whole line would never notice. So the label stops at
/// the first separator — an em dash, an en dash, a spaced hyphen, or a colon followed by
/// whitespace — and drops the markdown that decorates it.
public enum ChecklistParser {

    private static let itemPattern = #"^\s*[-*+]\s+\[([ xX])\]\s*(.*)$"#
    private static let separatorPattern = #"\s+[—–]\s+|\s+--?\s+|:\s"#

    /// Every `- [ ]` / `- [x]` line outside a fenced code block, in document order.
    ///
    /// Fenced content is excluded because a template showing the checklist syntax is
    /// documentation about the form, not a claim in it.
    ///
    /// - Parameter content: The document's full text.
    /// - Returns: The items found.
    public static func items(in content: String) -> [ChecklistItem] {
        guard let item = try? NSRegularExpression(pattern: itemPattern) else { // silent: a compile-time constant pattern; an empty result is the correct degradation and the caller's tests would fail loudly
            return []
        }
        var found: [ChecklistItem] = []
        var inFence = false
        var fenceMarker: Character = "`"

        for (index, line) in content.lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~",
               trimmed.prefix(while: { $0 == first }).count >= 3 {
                if inFence {
                    if first == fenceMarker { inFence = false }
                } else {
                    inFence = true
                    fenceMarker = first
                }
                continue
            }
            guard !inFence else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let hit = item.firstMatch(in: line, range: range),
                  hit.numberOfRanges > 2,
                  let boxRange = Range(hit.range(at: 1), in: line),
                  let textRange = Range(hit.range(at: 2), in: line) else {
                continue
            }
            let text = String(line[textRange])
            found.append(ChecklistItem(
                line: index + 1,
                label: label(from: text),
                isComplete: line[boxRange].lowercased() == "x",
                isStruck: text.contains("~~")))
        }
        return found
    }

    /// The artifact name a checklist line is about.
    static func label(from text: String) -> String {
        var head = text
        if let separator = try? NSRegularExpression(pattern: separatorPattern) { // silent: a compile-time constant pattern; falling through leaves the whole line as the label, which only ever makes the comparison stricter
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let hit = separator.firstMatch(in: text, range: range),
               let cut = Range(hit.range, in: text) {
                head = String(text[text.startIndex..<cut.lowerBound])
            }
        }
        return head
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Finds items a document asserts to be both done and not done.
///
/// This is the whole checker's cheapest true rule: it needs no source of truth, only the
/// file. A document that asserts P and ¬P about one named artifact is wrong regardless of
/// which side turns out to be right, and pointing at both lines is the entire finding.
public enum SelfContradictionRule {

    /// Contradictions in one document.
    ///
    /// Struck-through items are excluded. `CLAUDE.md` requires completed roadmap items to be
    /// struck rather than deleted so the reasoning recorded at the time survives, which
    /// deliberately leaves a finished item beside its live successor; reading that pair as a
    /// contradiction would penalise the housekeeping rule for being followed.
    ///
    /// - Parameter content: The document's full text.
    /// - Returns: One entry per contradicted artifact, ordered by first mention.
    public static func contradictions(in content: String) -> [SelfContradiction] {
        var byLabel: [String: (incomplete: [Int], complete: [Int])] = [:]
        var order: [String] = []

        for item in ChecklistParser.items(in: content) where !item.isStruck && !item.label.isEmpty {
            if byLabel[item.label] == nil {
                byLabel[item.label] = ([], [])
                order.append(item.label)
            }
            if item.isComplete {
                byLabel[item.label]?.complete.append(item.line)
            } else {
                byLabel[item.label]?.incomplete.append(item.line)
            }
        }

        return order.compactMap { label in
            guard let lines = byLabel[label],
                  !lines.incomplete.isEmpty, !lines.complete.isEmpty else { return nil }
            return SelfContradiction(
                label: label,
                incompleteLines: lines.incomplete.sorted(),
                completeLines: lines.complete.sorted())
        }
    }
}
