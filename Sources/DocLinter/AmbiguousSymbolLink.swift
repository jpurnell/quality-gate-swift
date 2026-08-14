import Foundation
import QualityGateCore

/// A bare symbol link — a name in double backticks — that is also a standard-library
/// type, in a package which declares its own.
///
/// ## Why this rule and not the wider one
///
/// `DocSymbolLink.md` proposed a checker for links that resolve to a symbol of the
/// *wrong kind* — a `Foo` called a struct in prose that is really a protocol.
/// Measured, that population is four in this repository and forty in BusinessMath,
/// under the fifty its own §9 set as the threshold to build. So it was not built.
///
/// This is the candidate that document flagged as outranking it: it needs no natural
/// language, no index store, and no judgement about what a sentence meant. A bare
/// link to `Result`, in a package that declares its own `Result`, is ambiguous
/// with the standard library's — and the repair is unambiguous: qualify it as
/// `Owner/Result`.
///
/// ## What it will not do
///
/// It fires only when the package **itself declares** a colliding type. A bare
/// `Result` link in a package with no `Result` of its own resolves exactly where the
/// reader expects, and flagging it would be noise about correct documentation.
///
/// It also stays silent on any reference that is already qualified, carries a
/// signature, or names a member path — those cannot be ambiguous with a bare
/// standard-library name.
public enum AmbiguousSymbolLink {

    /// The rule's identifier.
    public static let id = "doc-lint.ambiguous-symbol-link"

    /// Standard-library and Foundation names common enough that a bare reference
    /// reads as theirs.
    ///
    /// Deliberately short. Every entry is a name a Swift reader recognises without
    /// context, which is exactly what makes a same-named local type invisible.
    public static let stdlibNames: Set<String> = [
        "Result", "Error", "Task", "Duration", "Range", "Data", "URL", "Date",
        "Character", "String", "Array", "Dictionary", "Set", "Optional", "Never",
        "Comparable", "Equatable", "Hashable", "Sendable", "Codable", "Encoder",
        "Decoder", "Measurement", "Notification", "Operation", "Progress",
    ]

    /// A reference that could mean two things.
    public struct Finding: Sendable, Equatable {
        /// The bare name as written.
        public let name: String
        /// 1-indexed line it appears on.
        public let line: Int
        /// The type in this package that collides with the standard library's.
        public let localOwner: String
    }

    /// Finds ambiguous references in one document.
    ///
    /// - Parameters:
    ///   - text: The document — a `.docc` article, or a file whose `///` lines are scanned.
    ///   - declaredLocally: Types this package declares, mapped to their owning context.
    /// - Returns: Findings in line order.
    public static func findings(
        in text: String, declaredLocally: [String: String]
    ) -> [Finding] {
        var results: [Finding] = []
        for (index, line) in text.split(
            omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            for reference in references(in: String(line)) {
                // Qualified, signature-bearing or member-path references cannot be
                // ambiguous with a bare standard-library name.
                guard !reference.contains("/"), !reference.contains("("),
                      !reference.contains("-") else { continue }
                guard stdlibNames.contains(reference) else { continue }
                guard let owner = declaredLocally[reference] else { continue }
                results.append(Finding(name: reference, line: index + 1, localOwner: owner))
            }
        }
        return results
    }

    /// Double-backtick references on a line.
    static func references(in line: String) -> [String] {
        var found: [String] = []
        var remainder = Substring(line)
        while let open = remainder.range(of: "``") {
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.range(of: "``") else { break }
            let name = String(afterOpen[afterOpen.startIndex..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(" ") { found.append(name) }
            remainder = afterOpen[close.upperBound...]
        }
        return found
    }

    /// Turns a finding into a diagnostic.
    ///
    /// - Parameters:
    ///   - finding: The ambiguous reference.
    ///   - path: File it was found in.
    /// - Returns: A warning, because the link resolves — it just may not resolve to
    ///   what the sentence means, and that is a judgement the reader can make once
    ///   the ambiguity is pointed out.
    public static func diagnostic(for finding: Finding, path: String) -> Diagnostic {
        Diagnostic(
            severity: .warning,
            message: """
                `` `\(finding.name)` `` is ambiguous: this package declares \
                `\(finding.localOwner)`, and the standard library declares \
                `\(finding.name)` too. A reader cannot tell which one the link means, and \
                DocC will resolve it without asking.
                """,
            filePath: path,
            lineNumber: finding.line,
            ruleId: id,
            suggestedFix: """
                Qualify it — ``\(finding.localOwner)`` — if this package's type is meant. \
                If the standard library's is meant, say so in the prose rather than linking, \
                since a link to a type this package does not own tells the reader nothing \
                they can follow.
                """)
    }
}
