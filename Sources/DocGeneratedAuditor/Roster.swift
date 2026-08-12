import Foundation
import QualityGateCore

/// The merge that lets a generator own a checklist's *membership* without touching its state.
///
/// ## Why membership and state are split
///
/// `- [x]` means *this is done*, and no generator can know that. Deriving it from "a directory
/// exists" would make the checklist assert something nothing measured — a roster of 47 green
/// boxes that means only that 47 folders are present. But *which lines the list should have* is
/// a set, exactly, and it is the half that had drifted: sixteen real modules with no line at all.
///
/// So the generator adds and removes lines and never rewrites one. A surviving entry is emitted
/// byte-for-byte, tick-box and description included; a new member arrives unchecked with a
/// visible placeholder; a line whose subject is no longer a member is dropped.
///
/// This is also what makes two checkers writing one region safe. `StatusAuditor` owns the
/// tick-box column and already updates it; `doc-generated` owns the roster. The defect would be
/// two writers of the *same bytes*, and there are none — the columns do not overlap.
///
/// ## Struck entries are never dropped
///
/// `CLAUDE.md` requires completed roadmap items be struck through rather than deleted, with the
/// reasoning recorded at the time kept. A generator that dropped `~~DiskCleaner~~` because no
/// target answers to that name any more would destroy exactly the history the rule exists to
/// preserve — and it would be making §8.5's mistake, where a naive table generator would have
/// deleted the only line explaining where a feature went.
public enum Roster {

    /// Merges a region's current lines against the derived membership.
    ///
    /// - Parameters:
    ///   - body: The bytes currently between the delimiters.
    ///   - members: The derived membership, in declaration order.
    ///   - line: Builds the line for a member that has none yet.
    /// - Returns: The lines the region should contain.
    public static func merge(
        body: String, members: [String], line: (String) -> String
    ) -> [String] {
        var kept: [String] = []
        var claimed: Set<String> = []

        for text in body.lines {
            guard let subject = subject(of: text) else { continue }
            let isStruck = text.contains("~~")
            guard isStruck || members.contains(subject) else { continue }
            guard claimed.insert(subject).inserted else { continue }
            kept.append(text)
        }

        // Declaration order decides where a new member lands, and existing order is otherwise
        // untouched: re-sorting a hand-curated list would produce a diff nobody can read and
        // would churn again the next time a target is renamed.
        for member in members where !claimed.contains(member) {
            kept.append(line(member))
        }
        return kept
    }

    /// What a roster line is about: the first word after the bullet and any tick-box.
    ///
    /// Handles the three spellings one document uses — `- [x] Name — …`, `- \`Name\` — …`, and
    /// a struck `- [x] ~~Name~~ — …` — because the subject is the identity a line is matched on
    /// and a roster that matched three different keys would add every module twice.
    ///
    /// - Parameter text: One line, as the document holds it.
    /// - Returns: The subject, or `nil` when the line is not a list item or names nothing.
    public static func subject(of text: String) -> String? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("- ") || rest.hasPrefix("* ") else { return nil }
        rest = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        for box in ["[x] ", "[X] ", "[ ] "] where rest.hasPrefix(box) {
            rest = String(rest.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        guard let first = rest.split(separator: " ").first else { return nil }
        let subject = first.trimmingCharacters(in: CharacterSet(charactersIn: "`~*_"))
        return subject.isEmpty ? nil : subject
    }
}
